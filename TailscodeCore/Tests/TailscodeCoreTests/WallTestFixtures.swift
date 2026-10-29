import CodingAgentKit
import Foundation

@testable import TailscodeCore

enum WallFixtures {
    static let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    static func crewman(_ id: String, started: TimeInterval = 100, moved: TimeInterval = 2) -> SubagentSummary {
        SubagentSummary(
            id: id, title: id.capitalized, updatedAt: epoch.addingTimeInterval(-moved), isActive: true,
            startedAt: epoch.addingTimeInterval(-started), toolCount: 6, currentTool: "Read")
    }

    static func session(
        _ id: String, crew: [SubagentSummary] = [], asking: Bool = false, at now: Date = epoch
    ) -> AgentSource {
        let said = ChatMessage(
            id: "u-" + id, role: .user, agentType: .claudeCode,
            parts: [MessagePart(id: "p", kind: .text("go"))], createdAt: now.addingTimeInterval(-300))
        var messages = [said]
        var permissions: [PermissionRequest] = []
        if asking {
            let bash = ToolCall(
                id: "b", name: "Bash", status: .pending, input: .object(["command": .string("make")]))
            messages.append(
                ChatMessage(
                    id: "a-" + id, role: .assistant, agentType: .claudeCode,
                    parts: [MessagePart(id: "pb", kind: .tool(bash))],
                    createdAt: now.addingTimeInterval(-200), isStreaming: true))
            permissions = [PermissionRequest(id: "perm-" + id, sessionID: id, title: "Bash", toolName: "Bash")]
        }
        let state = ConversationState(
            messages: messages, status: .running, pendingPermissions: permissions,
            hasLoadedTranscript: true)
        let listing = AgentSession(
            id: id, agentType: .claudeCode, title: "Chat \(id)", createdAt: now, updatedAt: now,
            isActive: true)
        let stamps = (0..<40).map { now.addingTimeInterval(-Double($0) * 1.4) }
        return AgentSource(
            entry: SessionEntry(
                profileID: "p1", profileName: "studio", host: "studio", backendType: .claudeCode,
                session: listing),
            facts: AgentFacts.read(
                state: state, agents: crew,
                seen: asking ? ["perm-" + id: now.addingTimeInterval(-30)] : [:], stamps: stamps, now: now),
            reachable: true, unread: false)
    }

    static func board(sessions: Int, crew: Int = 0, asking: Bool = false, now: Date = epoch) -> AgentBoard {
        let sources = (0..<sessions).map { index -> AgentSource in
            let workers = index == 0 ? (0..<crew).map { crewman("w\($0)", started: Double(500 - $0)) } : []
            return session("s\(index)", crew: workers, asking: asking && index == sessions - 1, at: now)
        }
        return AgentBoard.read(sources: sources, now: now)
    }

    static func wall(
        sessions: Int, crew: Int = 0, asking: Bool = false, now: Date = epoch,
        reading: (aspect: Double, gridAspect: Double, pages: Bool) = (16.0 / 9.0, 16.0 / 9.0, false)
    ) -> AgentWall {
        AgentWall.read(
            board: board(sessions: sessions, crew: crew, asking: asking, now: now), hour: nil, now: now,
            aspect: reading.aspect, gridAspect: reading.gridAspect, pages: reading.pages, previous: nil)
    }
}
