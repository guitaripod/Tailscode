import ActivityKit
import CodingAgentKit
import Foundation

@MainActor
final class AppActivityController {
    static let shared = AppActivityController()

    nonisolated(unsafe) private var activity: Activity<ChatActivityAttributes>?

    func start(sessionTitle: String, serverName: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            AppLogger.chat.info("Live Activity not authorized")
            return
        }
        let attr = ChatActivityAttributes(
            sessionTitle: sessionTitle, serverName: serverName)
        let state = ChatActivityAttributes.ContentState(
            status: "Thinking\u{2026}", lastTool: nil, textSummary: nil)
        do {
            activity = try Activity.request(
                attributes: attr,
                content: .init(state: state, staleDate: Date().addingTimeInterval(600)))
            AppLogger.chat.info("Live Activity started")
        } catch {
            AppLogger.chat.error("Live Activity failed to start: \(error)")
        }
    }

    func end() {
        guard let activity else { return }
        nonisolated(unsafe) let act = activity
        let final = ChatActivityAttributes.ContentState(
            status: "Done", lastTool: nil, textSummary: nil)
        Task { @MainActor in
            await act.end(
                ActivityContent(state: final, staleDate: .now), dismissalPolicy: .immediate)
        }
        AppLogger.chat.info("Live Activity ended")
        self.activity = nil
    }
}
