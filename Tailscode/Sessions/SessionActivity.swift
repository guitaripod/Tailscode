import CodingAgentKit
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

    func update(
        sessionID: String, profileID: String, title: String, status: Status,
        keepAlive: ChatViewModel
    ) {
        switch status {
        case .running, .awaitingApproval:
            retained[sessionID] = keepAlive
        case .idle:
            retained[sessionID] = nil
        }
        let previous = statuses[sessionID] ?? .idle
        guard previous != status else { return }
        statuses[sessionID] = status
        if status == .idle, previous != .idle, !remotePushCovers(profileID: profileID) {
            NotificationManager.notify(
                title: title, body: "Your agent finished.", identifier: "done:\(sessionID)",
                sessionID: sessionID)
        }
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
