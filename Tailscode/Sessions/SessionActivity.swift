import CodingAgentKit
import TailscodeCore
import UIKit

/// Tracks the live status of sessions across the app so the list can show pills and completion
/// notifications fire even after you leave the chat. Keeps an in-flight conversation's view model
/// alive until its turn settles, then releases it.
@MainActor
final class SessionActivity {
    static let shared = SessionActivity()

    enum Status: Equatable {
        case idle, running, awaitingApproval
    }

    static let didChange = Notification.Name("SessionActivity.didChange")

    private(set) var statuses: [String: Status] = [:]
    private var retained: [String: ChatViewModel] = [:]

    private init() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                for viewModel in SessionActivity.shared.retained.values {
                    viewModel.resync()
                }
            }
        }
    }

    func status(for sessionID: String) -> Status {
        statuses[sessionID] ?? .idle
    }

    /// The view model kept alive for an in-flight turn, so reopening the chat
    /// reuses it instead of building a fresh one — otherwise queued messages
    /// and optimistic echoes, which live only on the view model, are lost.
    func retainedViewModel(for sessionID: String, contextID: String) -> ChatViewModel? {
        guard let viewModel = retained[sessionID], viewModel.contextID == contextID else {
            return nil
        }
        return viewModel
    }

    /// What a session this device is driving is doing right now ("Running
    /// Edit"), for Home's live cards. Nil for sessions running elsewhere — their
    /// transcripts aren't streaming here, so nothing beyond liveness is known.
    func liveDetail(for sessionID: String) -> String? {
        guard let viewModel = retained[sessionID] else { return nil }
        return ChatViewModel.liveStatus(for: viewModel.state).text
    }

    /// How many turns this device is driving on one server right now — which is exactly what a
    /// restart of that server would stop, and so what a person is owed before pressing it.
    func workingCount(onProfile profileID: String) -> Int {
        retained.values.filter { $0.contextID == profileID }.count
    }

    /// What a conversation this device is driving has told it, in the vocabulary the row and the
    /// desktop bands share. A reading nobody has answered yet says nothing at all: it leaves the
    /// last thing a witness did say standing, because settling on the gap between two witnesses
    /// drops the retained view model and announces a turn nobody watched finish.
    func update(
        sessionID: String, profileID: String, title: String, presence: SessionPresence,
        keepAlive: ChatViewModel
    ) {
        guard let status = Self.status(for: presence) else { return }
        switch status {
        case .running, .awaitingApproval:
            retained[sessionID] = keepAlive
        case .idle:
            retained[sessionID] = nil
        }
        let previous = statuses[sessionID] ?? .idle
        guard previous != status else {
            if status != .idle { postLiveTick() }
            return
        }
        statuses[sessionID] = status
        if status == .idle, previous != .idle {
            let body = String(localized: "Your agent finished.")
            if remotePushCovers(profileID: profileID) {
                recordMissed(
                    identifier: "done:\(sessionID)", profileID: profileID, sessionID: sessionID,
                    title: title, body: body)
            } else {
                NotificationManager.notify(
                    kind: .turnComplete,
                    title: title, body: body,
                    identifier: "done:\(sessionID)",
                    sessionID: sessionID, profileID: profileID, activity: .turnEnded)
            }
        }
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// Nil for a witness that has not been told anything yet — the one reading this list must not
    /// act on. A failure and a turn nothing here can see any more are both idle: the pill says
    /// what is running, and neither of them is.
    private static func status(for presence: SessionPresence) -> Status? {
        switch presence {
        case .unsettled: return nil
        case .running: return .running
        case .awaitingApproval: return .awaitingApproval
        case .failed, .unobserved: return .idle
        }
    }

    /// A turn the bridge's own push already announced still happened, and is still something that
    /// can be missed — the notification came from somewhere else, but it lasts exactly as long.
    /// Only while the app is away: a turn that ends under your eyes is not news.
    private func recordMissed(
        identifier: String, profileID: String, sessionID: String, title: String, body: String
    ) {
        guard AppPreferences.notifyTurnComplete,
            UIApplication.shared.applicationState != .active
        else { return }
        ActivityInbox.record([
            MissedActivity(
                identifier: identifier, profileID: profileID, sessionID: sessionID, title: title,
                body: body, reason: .turnEnded)
        ])
    }

    private var lastLiveTick: Date = .distantPast

    /// A running turn changes its detail line ("Thinking", "Running Edit") many
    /// times a second. Home shows that at a glance, so ticks are rate limited to
    /// one every two seconds — enough to look alive, cheap enough to ignore.
    private func postLiveTick() {
        guard Date().timeIntervalSince(lastLiveTick) > 2 else { return }
        lastLiveTick = Date()
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// Drops a session whose observing stream died without reaching idle — the
    /// turn may still be running server-side, but nothing on this device can
    /// see it finish, so keeping the pill and the retained view model would
    /// show "working" forever. No completion notification: the agent didn't
    /// finish, we just lost sight of it.
    func markUnobserved(sessionID: String) {
        retained[sessionID] = nil
        guard let current = statuses[sessionID], current != .idle else { return }
        statuses[sessionID] = .idle
        NotificationCenter.default.post(name: Self.didChange, object: nil)
    }

    /// A bridge that acked this launch's device token pushes its own turn-end
    /// alert, so the local one would duplicate it; opencode servers and bridges
    /// that never acked still rely on the local notification.
    private func remotePushCovers(profileID: String) -> Bool {
        guard
            let profile = ConnectionController.shared.profiles.first(where: { $0.id == profileID }),
            profile.backend == .claudeCode
        else { return false }
        return PushRegistrar.ackedBridgeURLs.contains(profile.baseURL)
    }
}
