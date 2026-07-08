import ActivityKit
import CodingAgentKit
import Foundation

@MainActor
final class AppActivityController {
    static let shared = AppActivityController()

    private var activity: Activity<ChatActivityAttributes>?

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
        guard let act = activity else { return }
        let final = ChatActivityAttributes.ContentState(
            status: "Done", lastTool: nil, textSummary: nil)
        self.activity = nil
        endDetached(act, final: final)
        AppLogger.chat.info("Live Activity ended")
    }

    private func endDetached(_ act: sending Activity<ChatActivityAttributes>, final: ChatActivityAttributes.ContentState) {
        Task.detached {
            await act.end(
                ActivityContent(state: final, staleDate: .now), dismissalPolicy: .immediate)
        }
    }

    func update(status: String, lastTool: String? = nil, textSummary: String? = nil) {
        guard let act = activity else { return }
        let newState = ChatActivityAttributes.ContentState(
            status: status, lastTool: lastTool, textSummary: textSummary)
        updateDetached(act, state: newState)
    }

    private func updateDetached(_ act: sending Activity<ChatActivityAttributes>, state: ChatActivityAttributes.ContentState) {
        Task.detached {
            await act.update(
                ActivityContent(state: state, staleDate: Date().addingTimeInterval(600)))
        }
    }
}
