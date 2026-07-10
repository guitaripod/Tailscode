import ActivityKit
import CodingAgentKit
import Foundation

@MainActor
final class AppActivityController {
    typealias Phase = ChatActivityAttributes.ContentState.Phase

    static let shared = AppActivityController()

    private struct Entry {
        let activity: Activity<ChatActivityAttributes>
        let startedAt: Date
        var lastPhase: Phase
    }

    private var entries: [String: Entry] = [:]
    private var pendingWork: [String: Task<Void, Never>] = [:]

    /// Ends Live Activities left on the Lock Screen by a previous process
    /// (crash, jetsam) that this launch no longer tracks.
    func endOrphanedActivities() {
        Task.detached {
            for act in Activity<ChatActivityAttributes>.activities {
                await act.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    @discardableResult
    func start(sessionID: String, sessionTitle: String, serverName: String) -> Bool {
        guard entries[sessionID] == nil else { return true }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            AppLogger.chat.info("Live Activity not authorized")
            return false
        }
        if !entries.isEmpty, !ProStore.shared.isPro {
            AppLogger.chat.info("second concurrent Live Activity gated (free tier)")
            return false
        }
        let attr = ChatActivityAttributes(
            sessionID: sessionID,
            sessionTitle: sessionTitle.isEmpty ? "Agent session" : sessionTitle,
            serverName: serverName)
        let startedAt = Date()
        let state = ChatActivityAttributes.ContentState(
            phase: .thinking, statusText: "Thinking\u{2026}", lastTool: nil, toolCount: 0,
            startedAt: startedAt)
        do {
            let activity = try Activity.request(
                attributes: attr,
                content: .init(state: state, staleDate: Date().addingTimeInterval(1800)))
            entries[sessionID] = Entry(activity: activity, startedAt: startedAt, lastPhase: .thinking)
            AppLogger.chat.info("Live Activity started for \(sessionID)")
            return true
        } catch {
            AppLogger.chat.error("Live Activity failed to start: \(error)")
            return false
        }
    }

    func update(
        sessionID: String, phase: Phase, statusText: String, lastTool: String?, toolCount: Int
    ) {
        guard var entry = entries[sessionID] else { return }
        let becameApproval = phase == .approval && entry.lastPhase != .approval
        entry.lastPhase = phase
        entries[sessionID] = entry
        let newState = ChatActivityAttributes.ContentState(
            phase: phase, statusText: statusText, lastTool: lastTool, toolCount: toolCount,
            startedAt: entry.startedAt)
        let alert: AlertConfiguration? =
            becameApproval
            ? AlertConfiguration(
                title: "Approval needed",
                body: "\(entry.activity.attributes.sessionTitle) is waiting for you.",
                sound: .default)
            : nil
        enqueue(sessionID, entry.activity) { act in
            await act.update(
                ActivityContent(state: newState, staleDate: Date().addingTimeInterval(1800)),
                alertConfiguration: alert)
        }
    }

    /// Ends with a visible terminal state that lingers briefly, so glancing at
    /// the Lock Screen right after a turn finishes still shows the outcome.
    func end(sessionID: String, outcome: Phase = .done, statusText: String? = nil) {
        guard let entry = entries.removeValue(forKey: sessionID) else { return }
        let final = ChatActivityAttributes.ContentState(
            phase: outcome,
            statusText: statusText ?? (outcome == .error ? "Something went wrong" : "Finished"),
            lastTool: nil, toolCount: 0, startedAt: entry.startedAt)
        enqueue(sessionID, entry.activity) { act in
            await act.end(
                ActivityContent(state: final, staleDate: .now),
                dismissalPolicy: .after(.now.addingTimeInterval(8)))
        }
        AppLogger.chat.info("Live Activity ended for \(sessionID) (\(outcome.rawValue))")
    }

    /// Serializes ActivityKit calls per session so a slow earlier update can
    /// never land after a later one (or after end).
    private var pendingTokens: [String: UUID] = [:]

    private func enqueue(
        _ sessionID: String, _ act: sending Activity<ChatActivityAttributes>,
        _ op: @escaping @Sendable (Activity<ChatActivityAttributes>) async -> Void
    ) {
        let previous = pendingWork[sessionID]
        let token = UUID()
        pendingTokens[sessionID] = token
        pendingWork[sessionID] = Task.detached {
            await previous?.value
            await op(act)
            await MainActor.run { [weak self] in
                guard let self, self.pendingTokens[sessionID] == token else { return }
                self.pendingWork[sessionID] = nil
                self.pendingTokens[sessionID] = nil
            }
        }
    }
}
