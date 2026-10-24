import CodingAgentKit
import Foundation
import TailscodeCore

/// Where the agents board gets everything it shows and where its buttons go: the live tower on a
/// real desk, a fixed fiction in demo mode, a scripted one in a check. The window never learns
/// which, so a screenshot of the demo board exercises the same views the real one does.
protocol AgentsSource: Sendable {
    func open() async
    func close() async
    func current() async -> AgentBoard
    func boards() async -> AsyncStream<AgentBoard>
    func facts(for key: String) async -> AsyncStream<AgentFacts?>
    func hour() async -> AgentHour
    func approve(_ key: String, allow: Bool) async -> AgentTower.Reply
    func answer(_ key: String, option: String) async -> AgentTower.Reply
    func stop(_ key: String) async -> AgentTower.Reply
    func nudge(_ key: String, text: String) async -> AgentTower.Reply
    func watch(_ key: String) async
}

/// The app's one tower, opened and closed with the window that shows it.
struct TowerSource: AgentsSource {
    let tower: AgentTower

    func open() async { await tower.open() }
    func close() async { await tower.close() }
    func current() async -> AgentBoard { await tower.current }
    func boards() async -> AsyncStream<AgentBoard> { await tower.boards() }
    func facts(for key: String) async -> AsyncStream<AgentFacts?> { await tower.facts(for: key) }
    func hour() async -> AgentHour { await tower.hour() }
    func approve(_ key: String, allow: Bool) async -> AgentTower.Reply {
        await tower.approve(key, allow: allow)
    }
    func answer(_ key: String, option: String) async -> AgentTower.Reply {
        await tower.answer(key, option: option)
    }
    func stop(_ key: String) async -> AgentTower.Reply { await tower.stop(key) }
    func nudge(_ key: String, text: String) async -> AgentTower.Reply {
        await tower.nudge(key, text: text)
    }
    func watch(_ key: String) async { await tower.watch(key) }
}

/// The fictional board of `--demo`: Core's own `AgentDemo`, read once at a fixed moment so the
/// clocks tick forward from what a screenshot shows, with no tower and no network. Its answers
/// arrive after a beat so a button is seen in flight.
final class DemoAgentsSource: AgentsSource, @unchecked Sendable {
    private let now: Date
    private let board: AgentBoard

    init(now: Date = Date()) {
        self.now = now
        board = AgentDemo.board(now: now)
    }

    func open() async {}
    func close() async {}
    func current() async -> AgentBoard { board }

    func boards() async -> AsyncStream<AgentBoard> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: AgentBoard.self, bufferingPolicy: .bufferingNewest(1))
        continuation.yield(board)
        return stream
    }

    func facts(for key: String) async -> AsyncStream<AgentFacts?> {
        let (stream, continuation) = AsyncStream.makeStream(
            of: AgentFacts?.self, bufferingPolicy: .bufferingNewest(1))
        continuation.yield(Self.facts(for: key, now: now))
        return stream
    }

    func hour() async -> AgentHour { AgentDemo.hour(now: Date()) }

    func approve(_ key: String, allow: Bool) async -> AgentTower.Reply { await settle() }
    func answer(_ key: String, option: String) async -> AgentTower.Reply { await settle() }
    func stop(_ key: String) async -> AgentTower.Reply { await settle() }
    func nudge(_ key: String, text: String) async -> AgentTower.Reply { await settle() }
    func watch(_ key: String) async {}

    private func settle() async -> AgentTower.Reply {
        try? await Task.sleep(for: .milliseconds(600))
        return .sent
    }

    /// What the tower would know of a demo session it watches: the working one reads Core's own
    /// conversation, the one waiting on the person reads the ask it holds; the sessions the demo
    /// only lists are not watched, so they have no facts.
    static func facts(for key: String, now: Date) -> AgentFacts? {
        switch key {
        case AgentDemo.studio + "/w": return working(now: now)
        case AgentDemo.homelab + "/ask": return asking(now: now)
        default: return nil
        }
    }

    /// Core's working conversation with what a real one carries once a turn has been paid for: the
    /// tokens it took and the API-equivalent estimate of them, so the peek's meters have figures.
    private static func working(now: Date) -> AgentFacts {
        var state = AgentDemo.state(now: now)
        if let index = state.messages.lastIndex(where: { $0.role == .assistant }) {
            state.messages[index].costUSD = 0.42
            state.messages[index].totalTokens = 38_000
        }
        let seen = [
            "c1": now.addingTimeInterval(-60), "c2": now.addingTimeInterval(-28),
            "c3": now.addingTimeInterval(-14), "c4": now.addingTimeInterval(-2),
        ]
        return AgentFacts.read(
            state: state, agents: AgentDemo.agents(now: now), seen: seen,
            stamps: (0..<40).map { now.addingTimeInterval(-Double($0) * 1.4) }, now: now)
    }

    static func asking(now: Date, command: String = "rm -rf build && swift build -c release")
        -> AgentFacts
    {
        func call(_ id: String, _ name: String, _ input: [String: JSONValue], _ status: ToolStatus)
            -> ToolCall
        {
            ToolCall(id: id, name: name, status: status, input: .object(input))
        }
        let calls = [
            call("a1", "Read", ["file_path": .string("/repo/.github/workflows/ci.yml")], .completed),
            call("a2", "Edit", ["file_path": .string("/repo/.github/workflows/ci.yml")], .completed),
            call("a3", "Bash", ["command": .string(command)], .pending),
        ]
        let message = ChatMessage(
            id: "a-ask", role: .assistant, agentType: .claudeCode,
            parts: calls.map { MessagePart(id: "p-" + $0.id, kind: .tool($0)) },
            createdAt: now.addingTimeInterval(-130), isStreaming: true, providerID: "anthropic",
            modelID: "claude-sonnet-5", reasoningEffort: "high")
        let prompt = ChatMessage(
            id: "u-ask", role: .user, agentType: .claudeCode,
            parts: [MessagePart(id: "p", kind: .text("migrate the CI"))],
            createdAt: now.addingTimeInterval(-300))
        let permission = PermissionRequest(id: "perm", sessionID: "ask", title: "Bash", toolName: "Bash")
        let state = ConversationState(
            messages: [prompt, message], status: .running, pendingPermissions: [permission],
            hasLoadedTranscript: true)
        return AgentFacts.read(
            state: state, agents: [],
            seen: [
                "a1": now.addingTimeInterval(-250), "a2": now.addingTimeInterval(-180),
                "perm": now.addingTimeInterval(-120),
            ],
            stamps: (0..<14).map { now.addingTimeInterval(-Double($0) * 4) }, now: now)
    }
}
