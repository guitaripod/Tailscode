import CodingAgentKit
import Foundation
import TailscodeCore

/// The work that belongs to a conversation rather than to a pane showing it, run by the hub once
/// per state per conversation on its stream task: the notification edges, the send-queue drain and
/// the presence a background watch publishes to the chat list.
///
/// Each used to run wherever a stream happened to be — in every pane's apply and again in the
/// window's background watch — so a chat shown in two panes, or a pane beside a watch, notified
/// twice and could send the queue's head twice. Here it runs once. Nothing in `observe` touches the
/// main context unless there is news: a notification to raise, a watched chat whose reading
/// changed, or a queue that may drain now, and the drain is asked for once until it is answered.
final class LiveEdgeService: LiveEdges, @unchecked Sendable {
    weak var hub: ConversationHub?
    weak var window: MainWindow?

    private struct Record {
        var entry: SessionEntry?
        var handoff = TurnHandoff()
        var sending = false
        var drainAsked = false
        var presence: SessionPresence = .running(nil)
        var watched = false
    }

    private let lock = NSLock()
    private var records: [LiveKey: Record] = [:]

    /// Names a conversation, so its notifications carry its title. Any thread.
    func note(_ entry: SessionEntry) {
        let key = LiveKey(entry)
        lock.lock()
        records[key, default: Record()].entry = entry
        lock.unlock()
    }

    /// Whether the window is watching a conversation nobody shows. A watch starts from a reading of
    /// running, as the window's own watch always did, so the first settled state is news.
    func setWatched(_ key: LiveKey, _ watched: Bool) {
        lock.lock()
        var record = records[key] ?? Record()
        if watched, !record.watched { record.presence = .running(nil) }
        record.watched = watched
        records[key] = record
        lock.unlock()
    }

    /// A pane sent into the conversation: the queue holds until the server shows the turn.
    func beganSend(_ key: LiveKey, after state: ConversationState?) {
        lock.lock()
        records[key, default: Record()].handoff.begin(after: state)
        lock.unlock()
    }

    /// A pane's send never left: the handoff it opened is over.
    func endedSend(_ key: LiveKey) {
        lock.lock()
        records[key, default: Record()].handoff.end()
        lock.unlock()
    }

    /// The main loop answered a drain request, whatever it decided.
    func drainHandled(_ key: LiveKey) {
        lock.lock()
        records[key, default: Record()].drainAsked = false
        lock.unlock()
    }

    func observe(_ key: LiveKey, _ state: ConversationState) {
        lock.lock()
        var record = records[key] ?? Record()
        record.handoff.observe(state, sendsInFlight: record.sending)
        let reading = SessionPresence.reading(state, step: nil)
        let changed = reading != record.presence
        record.presence = reading
        var askDrain = false
        if !record.drainAsked, !record.sending,
            SendQueueDrain.mayDrain(state, handoff: record.handoff),
            !SendQueueStore.queue(profileID: key.profileID, sessionID: key.sessionID).isEmpty
        {
            record.drainAsked = true
            askDrain = true
        }
        let watched = record.watched
        let entry = record.entry
        records[key] = record
        lock.unlock()
        if let entry {
            Notifier.shared.observeConversationAnywhere(
                profileID: key.profileID, sessionID: key.sessionID,
                title: MissedActivity.name(
                    title: entry.session.title,
                    latestPrompt: state.messages.last { $0.role == .user }?
                        .parts.compactMap(\.text).joined(separator: "\n")),
                state: state)
        }
        if watched, changed {
            Gtk.onMain { [weak self] in self?.window?.watchedPresenceChanged(key, reading) }
        }
        if askDrain {
            Gtk.onMain { [weak self] in
                guard let self else { return }
                guard let window = self.window else {
                    self.drainHandled(key)
                    return
                }
                window.drainLive(key, state)
            }
        }
    }

    func needsStream(_ key: LiveKey) -> Bool {
        lock.lock()
        let inFlight = records[key]?.presence.isInFlight ?? false
        let sending = records[key]?.sending ?? false
        lock.unlock()
        return inFlight || sending
            || !SendQueueStore.queue(profileID: key.profileID, sessionID: key.sessionID).isEmpty
    }

    /// Sends the queue's head for a conversation no pane is showing, taken atomically from the
    /// store so no other surface or process can send the same message. A send that fails goes back
    /// to the head of the queue and the handoff it opened ends.
    func drainInBackground(_ key: LiveKey, after state: ConversationState) {
        guard let next = SendQueueStore.takeFirst(profileID: key.profileID, sessionID: key.sessionID)
        else { return }
        lock.lock()
        records[key, default: Record()].handoff.begin(after: state)
        records[key, default: Record()].sending = true
        lock.unlock()
        let hub = self.hub
        Task { [weak self] in
            do {
                guard let conversation = await hub?.conversation(for: key) else {
                    throw CancellationError()
                }
                switch next.kind {
                case .prompt:
                    try await conversation.send(
                        next.text, model: next.model, reasoningEffort: next.effort,
                        attachments: next.attachments)
                case .command(let name, let arguments):
                    try await conversation.run(
                        AgentCommand(name: name, details: "", source: .builtin),
                        arguments: arguments.isEmpty ? nil : arguments, model: next.model,
                        reasoningEffort: next.effort)
                }
                self?.finishedBackgroundSend(key, failed: nil)
            } catch {
                self?.finishedBackgroundSend(key, failed: next)
            }
        }
    }

    private func finishedBackgroundSend(_ key: LiveKey, failed: QueuedSend?) {
        lock.lock()
        records[key, default: Record()].sending = false
        if failed != nil { records[key, default: Record()].handoff.end() }
        lock.unlock()
        if let failed {
            var held = SendQueueStore.queue(profileID: key.profileID, sessionID: key.sessionID)
            held.requeueAtHead(failed)
            SendQueueStore.save(held, profileID: key.profileID, sessionID: key.sessionID)
        }
        Gtk.onMain { [weak self] in self?.window?.liveQueueChanged(key) }
        hub?.reevaluate(key)
    }

    /// Forgets a conversation nothing holds any more.
    func forget(_ key: LiveKey) {
        lock.lock()
        if let record = records[key], !record.watched, !record.sending { records[key] = nil }
        lock.unlock()
    }
}
