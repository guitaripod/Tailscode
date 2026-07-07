import Foundation

/// Tracks the live status of sessions across the app so the list can show pills and completion
/// notifications fire even after you leave the chat. Keeps an in-flight conversation's view model
/// alive until its turn settles, then releases it.
@MainActor
final class SessionActivity {
    static let shared = SessionActivity()

    enum Status: Equatable {
        case idle, running, awaitingApproval
    }

    private(set) var statuses: [String: Status] = [:]
    private var retained: [String: ChatViewModel] = [:]
    var onChange: (() -> Void)?

    func status(for sessionID: String) -> Status {
        statuses[sessionID] ?? .idle
    }

    func update(sessionID: String, title: String, status: Status, keepAlive: ChatViewModel) {
        switch status {
        case .running, .awaitingApproval:
            retained[sessionID] = keepAlive
        case .idle:
            retained[sessionID] = nil
        }
        let previous = statuses[sessionID] ?? .idle
        guard previous != status else { return }
        statuses[sessionID] = status
        if status == .idle, previous == .running {
            NotificationManager.notify(
                title: title, body: "Your agent finished.", identifier: "done:\(sessionID)")
        }
        onChange?()
    }
}
