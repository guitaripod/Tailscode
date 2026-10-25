import CodingAgentKit
import Foundation

/// The board the design shows, built the way the real one is: synthetic sessions and conversations
/// read through `AgentBoard.read`, `AgentFacts.read` and `AgentHourLog`, so a screenshot, a tour
/// and a self-test of any client exercise the same readings the live tower feeds it. Fictional
/// throughout: nothing here is a real machine or a real chat.
public enum AgentDemo {
    public static let studio = "demo-studio"
    public static let homelab = "demo-homelab"

    static func entry(
        _ id: String, _ title: String, profile: String, machine: String, now: Date,
        active: Bool = false, agents: Int? = nil, task: String? = nil, work: BackgroundWork? = nil,
        updated: TimeInterval = 0, model: String? = nil
    ) -> SessionEntry {
        var session = AgentSession(
            id: id, agentType: .claudeCode, title: title, createdAt: now.addingTimeInterval(-7200),
            updatedAt: now.addingTimeInterval(-updated), isActive: active, model: model)
        session.activeAgents = agents
        session.agentTask = task
        session.backgroundWork = work
        return SessionEntry(
            profileID: profile, profileName: machine, host: machine, backendType: .claudeCode,
            session: session)
    }

    static func user(_ text: String, now: Date, ago: TimeInterval) -> ChatMessage {
        ChatMessage(
            id: "u-" + text, role: .user, agentType: .claudeCode,
            parts: [MessagePart(id: "p", kind: .text(text))], createdAt: now.addingTimeInterval(-ago))
    }

    static func turn(_ calls: [ToolCall], now: Date, ago: TimeInterval) -> ChatMessage {
        ChatMessage(
            id: "a-" + (calls.first?.id ?? "x"), role: .assistant, agentType: .claudeCode,
            parts: calls.map { MessagePart(id: "p-" + $0.id, kind: .tool($0)) },
            createdAt: now.addingTimeInterval(-ago), isStreaming: true, providerID: "anthropic",
            modelID: "claude-opus-5", reasoningEffort: "xhigh")
    }

    static func call(
        _ id: String, _ name: String, _ input: [String: JSONValue], _ status: ToolStatus
    ) -> ToolCall {
        ToolCall(id: id, name: name, status: status, input: .object(input))
    }

    /// The conversation of the working agent the peek opens on.
    public static func state(now: Date) -> ConversationState {
        let calls = [
            call("c1", "Grep", ["pattern": .string("jitter")], .completed),
            call("c2", "Read", ["file_path": .string("/repo/Tests/ReconnectTests.swift")], .completed),
            call("c3", "Bash", ["command": .string("swift test")], .error),
            call(
                "c4", "Edit",
                [
                    "file_path": .string("/repo/Sources/Reconnect/Backoff.swift"),
                    "old_string": .string("a\nb\nc"),
                    "new_string": .string("1\n2\n3\n4\n5\n6\n7\n8\n9"),
                ], .running),
        ]
        return ConversationState(
            messages: [user("why does the reconnect test flake?", now: now, ago: 252), turn(calls, now: now, ago: 240)],
            status: .running, hasLoadedTranscript: true,
            backgroundWork: BackgroundWork(tasks: 1, task: "swift test", since: now.addingTimeInterval(-120)))
    }

    public static func agents(now: Date) -> [SubagentSummary] {
        [
            SubagentSummary(
                id: "explore", title: "Explore", updatedAt: now, isActive: true,
                startedAt: now.addingTimeInterval(-90), toolCount: 12, currentTool: "Read",
                todosDone: 4, todosTotal: 6, currentTodo: "reading the retry paths")
        ]
    }

    public static func facts(now: Date) -> AgentFacts {
        let stamps = (0..<40).map { now.addingTimeInterval(-Double($0) * 1.4) }
        return AgentFacts.read(
            state: state(now: now), agents: agents(now: now),
            seen: ["c1": now.addingTimeInterval(-60), "c2": now.addingTimeInterval(-28), "c3": now.addingTimeInterval(-14), "c4": now.addingTimeInterval(-2)],
            stamps: stamps, now: now)
    }

    public static func board(now: Date) -> AgentBoard {
        let working = entry(
            "w", "Fix reconnect test", profile: studio, machine: "studio", now: now, active: true,
            model: "claude-opus-5")
        let asking = entry("ask", "CI migration", profile: homelab, machine: "homelab", now: now, active: true)
        let landing = entry(
            "l", "Landing page refresh", profile: homelab, machine: "homelab", now: now, active: true,
            agents: 2, task: "Searching the footer")
        let release = entry(
            "r", "Release notes", profile: studio, machine: "studio", now: now,
            work: BackgroundWork(tasks: 1, task: "swift test --parallel", since: now.addingTimeInterval(-1320)))
        let deploy = entry("d", "Deploy check", profile: studio, machine: "studio", now: now, updated: 720)
        let bash = call("b", "Bash", ["command": .string("rm -rf build && swift build -c release")], .pending)
        let ask = PermissionRequest(id: "perm", sessionID: "ask", title: "Bash", toolName: "Bash")
        let asked = AgentFacts.read(
            state: ConversationState(
                messages: [user("migrate the CI", now: now, ago: 300), turn([bash], now: now, ago: 130)],
                status: .running, pendingPermissions: [ask], hasLoadedTranscript: true),
            agents: [], seen: ["perm": now.addingTimeInterval(-120)], now: now)
        let done = AgentFinish(
            id: studio + "/d", profileID: studio, sessionID: "d", title: "Deploy check",
            machine: "studio", outcome: .done,
            line: AgentFinish.line(outcome: .done, duration: 372, tools: 14, files: 3),
            endedAt: now.addingTimeInterval(-720), unread: true)
        return AgentBoard.read(
            sources: [
                AgentSource(entry: working, facts: facts(now: now), reachable: true, unread: false),
                AgentSource(entry: asking, facts: asked, reachable: true, unread: false),
                AgentSource(entry: landing, facts: nil, reachable: true, unread: false),
                AgentSource(entry: release, facts: nil, reachable: true, unread: false),
                AgentSource(entry: deploy, facts: nil, reachable: true, unread: true),
            ], finished: [done], now: now)
    }

    public static func hour(now: Date) -> AgentHour {
        var log = AgentHourLog()
        func at(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }
        func note(
            _ id: String, _ title: String, _ machine: String, _ phase: AgentHourPhase?, _ minutes: Double,
            parent: String? = nil
        ) {
            let profile = machine == "homelab" ? homelab : studio
            let session = id.split(separator: "#").first.map(String.init) ?? id
            log.note(
                id: profile + "/" + id, parentID: parent.map { profile + "/" + $0 },
                profileID: profile, sessionID: session, title: title, machine: machine, phase: phase,
                at: at(minutes))
        }
        log.beginObserving(at: at(52))
        note("w", "Fix reconnect test", "studio", .working, 52)
        note("w", "Fix reconnect test", "studio", nil, 38)
        log.end(id: studio + "/w", outcome: .done, at: at(38))
        note("w", "Fix reconnect test", "studio", .working, 21)
        note("w#x", "Explore", "studio", .working, 11, parent: "w")
        note("w#x", "Explore", "studio", nil, 3, parent: "w")
        note("w#b", "swift test", "studio", .background, 4, parent: "w")
        note("ask", "CI migration", "homelab", .working, 35)
        note("ask", "CI migration", "homelab", .needsYou, 12)
        note("l", "Landing page refresh", "homelab", .working, 18)
        note("f", "Auth flow", "studio", .working, 28)
        note("f", "Auth flow", "studio", nil, 16)
        log.end(id: studio + "/f", outcome: .failed, at: at(16))
        note("d", "Deploy check", "studio", .working, 16)
        note("d", "Deploy check", "studio", nil, 10)
        log.end(id: studio + "/d", outcome: .done, at: at(10))
        note("r", "Release notes", "studio", .background, 32)
        return log.hour(now: now)
    }
}
