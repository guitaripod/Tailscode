import CodingAgentKit
import Foundation
import TailscodeCore

/// A conversation started a moment before it is asked for.
///
/// Opening a chat began when the click finished: the conversation was made, its transcript read
/// from disk and asked for over the tailnet, and every message drawn as rows, with the pane saying
/// so for as long as that took. A pointer resting on a row is most of the way to a click, and a
/// button going down on one is a click that has not finished, so either starts all of it there and
/// then — a glance-interest lease on the process's one conversation for the chat, and the rows of
/// its tail made into the memo every build reads — and the pane that opens it a moment later finds
/// the words in memory and every message drawn. A warm chat nobody takes lets go of its server
/// after a while, and only a few are held at once.
final class ConversationWarmer: @unchecked Sendable {
    private final class Held: @unchecked Sendable {
        let lease: LiveLease
        init(lease: LiveLease) { self.lease = lease }
    }

    /// Enough for a pointer that wavers between two rows and settles on a third.
    static let limit = 3

    /// Long enough for a hesitation, short enough that a list skimmed on the way to somewhere else
    /// leaves nothing listening to its servers.
    static let patience: UInt32 = 20_000

    /// The messages whose rows are made: what a pane builds when it opens a chat.
    static let tail = 300

    private let hub: ConversationHub
    private let lock = NSLock()
    private var held: [LiveKey: Held] = [:]
    private var order: [LiveKey] = []
    private let work = DispatchQueue(label: "tailscode.warm", qos: .utility)

    init(hub: ConversationHub) {
        self.hub = hub
    }

    func warm(_ entry: SessionEntry) {
        let key = LiveKey(entry)
        guard hub.leaseCount(key) == 0 else { return }
        lock.lock()
        guard held[key] == nil else {
            lock.unlock()
            return
        }
        let profileID = entry.profileID
        let lease = hub.lease(key, interest: .glance) { [weak self] in
            self?.arrived(key, profileID: profileID)
        }
        Trace.mark("warm \(key.sessionID.prefix(8))")
        let record = Held(lease: lease)
        held[key] = record
        order.append(key)
        let overflow = order.count > Self.limit ? order.removeFirst() : nil
        let dropped = overflow.flatMap { held.removeValue(forKey: $0) }
        lock.unlock()
        dropped?.lease.cancel()
        Gtk.after(Self.patience) { [weak self] in
            Gtk.onMain { [weak self] in self?.drop(key, ifStill: record) }
        }
    }

    /// The pane that opened this chat holds it now. The warm lease goes at once: the pane's own
    /// lease is already keeping the stream, so the conversation never has nobody listening.
    func handOver(_ key: LiveKey) {
        drop(key, ifStill: nil)
    }

    func isWarm(_ key: LiveKey) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return held[key] != nil
    }

    private func drop(_ key: LiveKey, ifStill record: Held?) {
        lock.lock()
        guard let current = held[key], record == nil || current === record else {
            lock.unlock()
            return
        }
        held[key] = nil
        order.removeAll { $0 == key }
        lock.unlock()
        current.lease.cancel()
    }

    private func arrived(_ key: LiveKey, profileID: String) {
        work.async { [weak self] in self?.read(key, profileID: profileID) }
    }

    private func read(_ key: LiveKey, profileID: String) {
        lock.lock()
        let record = held[key]
        lock.unlock()
        guard let record, let frame = record.lease.take(), frame.state.hasLoadedTranscript else {
            return
        }
        let began = ContinuousClock.now
        TranscriptRowBuilder.warm(
            Array(frame.state.messages.suffix(Self.tail)), turnOpen: frame.state.status == .running
        ) { selection in
            ModelCatalogStore.cached(profileID).first { $0.selection == selection }?.name
        }
        Trace.mark(
            "warm rows \(key.sessionID.prefix(8)) \(frame.state.messages.count) messages in "
                + "\(OpenTimer.milliseconds(since: began))ms")
    }
}
