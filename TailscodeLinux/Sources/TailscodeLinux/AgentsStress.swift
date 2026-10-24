import CodingAgentKit
import Foundation
import TailscodeCore

/// A board built to be worse than any real one: a command a thousand characters long, titles two
/// hundred, a machine named at fifty, a one-line summary that runs to six. What a layout is
/// measured against when it has to wrap and not clip, in the check and in the harness alike.
enum AgentsStress {
    static let machine = String(repeating: "homelab-machine-", count: 3)

    static func command(parts: Int = 14) -> String {
        (0..<parts).map { "swift build --configuration release --product tailscode-tool-\($0)" }
            .joined(separator: " &&\n")
    }

    static func board(now: Date, askCommand: String? = nil) -> AgentBoard {
        func entry(_ id: String, _ title: String, task: String? = nil) -> SessionEntry {
            var session = AgentSession(
                id: id, agentType: .claudeCode, title: title, createdAt: now.addingTimeInterval(-900),
                updatedAt: now, isActive: true)
            session.agentTask = task
            session.activeAgents = 2
            return SessionEntry(
                profileID: AgentDemo.homelab, profileName: machine, host: "homelab",
                backendType: .claudeCode, session: session)
        }
        let asking = AgentSource(
            entry: entry(
                "ask",
                String(repeating: "Migrate the continuous integration pipeline to self hosted runners ", count: 3)),
            facts: DemoAgentsSource.asking(now: now, command: askCommand ?? command()), reachable: true, unread: false)
        let busy = AgentSource(
            entry: entry(
                "busy", String(repeating: "Refactor everything in sight ", count: 8),
                task: String(repeating: "Searching the footer for the thing that was moved ", count: 6)),
            facts: nil, reachable: true, unread: false)
        let away = AgentSource(
            entry: entry("away", "A chat on a machine that stopped answering"), facts: nil,
            reachable: false, unread: true)
        return AgentBoard.read(sources: [asking, busy, away], now: now)
    }
}
