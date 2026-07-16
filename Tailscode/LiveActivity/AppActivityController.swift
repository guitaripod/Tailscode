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
        var lastToolCount = 0
        var lastState: ChatActivityAttributes.ContentState?
        var lastPushedAt = Date()
        var latestTitle: String?
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
            startedAt: startedAt, endedAt: nil, title: nil)
        do {
            let activity = try Activity.request(
                attributes: attr,
                content: .init(state: state, staleDate: Date().addingTimeInterval(1800)))
            entries[sessionID] = Entry(
                activity: activity, startedAt: startedAt, lastPhase: .thinking, lastState: state)
            AppLogger.chat.info("Live Activity started for \(sessionID)")
            return true
        } catch {
            AppLogger.chat.error("Live Activity failed to start: \(error)")
            return false
        }
    }

    func update(
        sessionID: String, phase: Phase, statusText: String, lastTool: String?, toolCount: Int,
        title: String? = nil
    ) {
        guard var entry = entries[sessionID] else { return }
        let becameApproval = phase == .approval && entry.lastPhase != .approval
        entry.lastPhase = phase
        entry.lastToolCount = max(entry.lastToolCount, toolCount)
        if let title, !title.isEmpty { entry.latestTitle = title }
        let newState = ChatActivityAttributes.ContentState(
            phase: phase, statusText: statusText, lastTool: lastTool,
            toolCount: entry.lastToolCount, startedAt: entry.startedAt, endedAt: nil,
            title: entry.latestTitle)
        let staleSoon = Date().timeIntervalSince(entry.lastPushedAt) > 600
        guard becameApproval || staleSoon || newState != entry.lastState else {
            entries[sessionID] = entry
            return
        }
        entry.lastState = newState
        entry.lastPushedAt = Date()
        entries[sessionID] = entry
        let alert: AlertConfiguration? =
            becameApproval
            ? AlertConfiguration(
                title: "Approval needed",
                body: "\(entry.latestTitle ?? entry.activity.attributes.sessionTitle) is waiting for you.",
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
        let endedAt = Date()
        let final = ChatActivityAttributes.ContentState(
            phase: outcome,
            statusText: statusText
                ?? Self.summary(
                    outcome: outcome, toolCount: entry.lastToolCount,
                    duration: endedAt.timeIntervalSince(entry.startedAt)),
            lastTool: nil, toolCount: entry.lastToolCount, startedAt: entry.startedAt,
            endedAt: endedAt, title: entry.latestTitle)
        enqueue(sessionID, entry.activity) { act in
            await act.end(
                ActivityContent(state: final, staleDate: .now),
                dismissalPolicy: .after(.now.addingTimeInterval(30)))
        }
        AppLogger.chat.info("Live Activity ended for \(sessionID) (\(outcome.rawValue))")
    }

    private static func summary(outcome: Phase, toolCount: Int, duration: TimeInterval) -> String {
        guard outcome != .error else { return "Something went wrong" }
        var parts = ["Done in \(Self.compactDuration(duration))"]
        if toolCount > 0 { parts.append("\(toolCount) tool\(toolCount == 1 ? "" : "s")") }
        return parts.joined(separator: " · ")
    }

    private static func compactDuration(_ interval: TimeInterval) -> String {
        let seconds = Int(interval.rounded())
        if seconds < 60 { return "\(max(seconds, 1))s" }
        if seconds < 3600 { return "\(seconds / 60)m \(seconds % 60)s" }
        return "\(seconds / 3600)h \((seconds % 3600) / 60)m"
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
