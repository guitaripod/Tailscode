import CodingAgentKit
import Foundation

/// The wall the design shows, one scene per mood, read through the same `AgentBoard.read`,
/// `AgentFacts.read` and `AgentWall.read` the live tower feeds. Fictional throughout.
extension AgentDemo {
    public static let attic = "demo-attic"

    static let wallAspect = 16.0 / 9.0

    /// Every scene the wall can be in, for a screenshot, a tour or a self-test.
    public static func wallScenes(now: Date) -> [(name: String, wall: AgentWall)] {
        [
            ("calm", calmWall(now: now)),
            ("busy", busyWall(now: now)),
            ("attention", attentionWall(now: now)),
            ("alarm", alarmWall(now: now)),
            ("finishing", finishingWall(now: now)),
            ("crowded", crowdedWall(now: now)),
        ]
    }

    /// The wall with the most going wrong: the alarm scene.
    public static func wall(now: Date) -> AgentWall { alarmWall(now: now) }

    private static func read(
        _ sources: [AgentSource], finished: [AgentFinish] = [], hour: AgentHour? = nil, now: Date,
        previous: AgentWall? = nil
    ) -> AgentWall {
        let board = AgentBoard.read(
            sources: sources, finished: finished.filter { $0.endedAt <= now }, now: now)
        return AgentWall.read(
            board: board, hour: hour, now: now, aspect: wallAspect, previous: previous)
    }

    private static func pulse(_ now: Date) -> [Date] {
        (0..<40).map { now.addingTimeInterval(-Double($0) * 1.4) }
    }

    private static func conversation(
        _ ask: String, _ calls: [ToolCall], status: BackendStatus = .running, now: Date,
        permissions: [PermissionRequest] = [], retry: TurnRetry? = nil, fill: Double = 0.4
    ) -> ConversationState {
        var messages = [user(ask, now: now, ago: 400)]
        if !calls.isEmpty {
            var answer = turn(calls, now: now, ago: 380)
            answer.context = MessageUsage(cacheRead: Int(fill * 200_000))
            messages.append(answer)
        }
        return ConversationState(
            messages: messages, status: status, pendingPermissions: permissions,
            hasLoadedTranscript: true, retry: retry)
    }

    private static func source(
        _ id: String, _ title: String, profile: String = studio, machine: String = "studio",
        state: ConversationState, agents: [SubagentSummary] = [], beating: Bool = true,
        seen: [String: Date] = [:], reachable: Bool = true, unread: Bool = false, idleFor: TimeInterval = 0,
        now: Date, anchor: Date? = nil
    ) -> AgentSource {
        let entry = entry(
            id, title, profile: profile, machine: machine, now: anchor ?? now,
            active: state.status == .running, updated: idleFor, model: "claude-opus-5")
        let facts = AgentFacts.read(
            state: state, agents: agents, seen: seen, stamps: beating ? pulse(now) : [], now: now)
        return AgentSource(entry: entry, facts: facts, reachable: reachable, unread: unread)
    }

    private static func listed(
        _ id: String, _ title: String, profile: String, machine: String, task: String, now: Date
    ) -> AgentSource {
        AgentSource(
            entry: entry(id, title, profile: profile, machine: machine, now: now, active: true, task: task),
            facts: nil, reachable: true, unread: false)
    }

    private static func background(
        _ id: String, _ title: String, task: String, ago: TimeInterval, stalled: Bool = false,
        now: Date, anchor: Date
    ) -> AgentSource {
        source(
            id, title,
            state: ConversationState(
                messages: [user("run the whole suite", now: anchor, ago: ago + 60)], status: .idle,
                hasLoadedTranscript: true,
                backgroundWork: BackgroundWork(
                    tasks: 1, task: task, since: anchor.addingTimeInterval(-ago), stalled: stalled)),
            now: now, anchor: anchor)
    }

    private static func asking(
        _ id: String, _ title: String, command: String, waited: TimeInterval, now: Date, anchor: Date
    ) -> AgentSource {
        let bash = call("b-" + id, "Bash", ["command": .string(command)], .pending)
        let request = PermissionRequest(id: "perm-" + id, sessionID: id, title: "Bash", toolName: "Bash")
        return source(
            id, title, profile: homelab, machine: "homelab",
            state: conversation("migrate the CI", [bash], now: anchor, permissions: [request]),
            seen: [request.id: anchor.addingTimeInterval(-waited)], now: now, anchor: anchor)
    }

    private static func working(
        _ id: String, _ title: String, profile: String = studio, machine: String = "studio",
        calls: [ToolCall], beating: Bool = true, fill: Double = 0.4, now: Date, anchor: Date
    ) -> AgentSource {
        source(
            id, title, profile: profile, machine: machine,
            state: conversation(title.lowercased(), calls, now: anchor, fill: fill),
            beating: beating, now: now, anchor: anchor)
    }

    private static func ended(
        _ id: String, _ title: String, machine: String = "studio", _ outcome: AgentFinish.Outcome,
        at: Date, tools: Int = 9, reason: String? = nil
    ) -> AgentFinish {
        AgentFinish(
            id: (machine == "homelab" ? homelab : studio) + "/" + id,
            profileID: machine == "homelab" ? homelab : studio, sessionID: id, title: title,
            machine: machine, outcome: outcome,
            line: AgentFinish.line(
                outcome: outcome, duration: 372, tools: tools, files: 2, failure: reason),
            endedAt: at, unread: outcome != .stopped, reason: reason)
    }

    private static func reading(_ path: String, _ id: String) -> ToolCall {
        call(id, "Read", ["file_path": .string(path)], .completed)
    }

    private static func editing(_ path: String, _ id: String) -> ToolCall {
        call(id, "Edit", ["file_path": .string(path), "old_string": .string("a"), "new_string": .string("b\nc")], .running)
    }

    private static func running(_ command: String, _ id: String) -> ToolCall {
        call(id, "Bash", ["command": .string(command)], .running)
    }

    private static func calmWall(now: Date) -> AgentWall {
        var log = AgentHourLog()
        log.beginObserving(at: now.addingTimeInterval(-3500))
        let outcomes: [AgentFinish.Outcome] = [
            .done, .done, .stopped, .done, .done, .failed, .done, .stopped, .done,
        ]
        var ledger: [AgentFinish] = []
        for (index, outcome) in outcomes.enumerated() {
            let id = "c\(index)"
            let at = now.addingTimeInterval(-Double(3300 - index * 300))
            log.note(
                id: studio + "/" + id, profileID: studio, sessionID: id, title: "Chat \(id)",
                machine: "studio", phase: .working, at: at.addingTimeInterval(-200))
            log.note(
                id: studio + "/" + id, profileID: studio, sessionID: id, title: "Chat \(id)",
                machine: "studio", phase: nil, at: at)
            log.end(id: studio + "/" + id, outcome: outcome, at: at)
            ledger.append(
                ended(
                    id, ["Deploy check", "Auth flow", "Lint sweep", "Docs pass", "Icon export", "Schema diff", "Typo hunt", "Cache warm", "Release notes"][index],
                    outcome, at: at, reason: outcome == .failed ? "swift build exited with status 1" : nil))
        }
        return read([], finished: Array(ledger.suffix(5)), hour: log.hour(now: now), now: now)
    }

    private static func fixing(now: Date) -> ConversationState {
        var fixing = state(now: now)
        fixing.messages[fixing.messages.count - 1].context = MessageUsage(cacheRead: 96_000)
        return fixing
    }

    private static func busyWall(now: Date) -> AgentWall {
        read(
            [
                source(
                    "w", "Fix reconnect test", state: fixing(now: now), agents: agents(now: now),
                    now: now),
                working(
                    "l", "Landing page refresh", profile: homelab, machine: "homelab",
                    calls: [
                        reading("/site/index.html", "l1"),
                        editing("/site/styles/footer.css", "l2"),
                    ], now: now, anchor: now),
                source(
                    "t", "Draft changelog",
                    state: conversation("draft the changelog", [], now: now), now: now),
                background(
                    "r", "Release notes", task: "swift test --parallel", ago: 1320, now: now, anchor: now),
            ], now: now)
    }

    private static func attentionWall(now: Date) -> AgentWall {
        read(
            [
                asking(
                    "ask", "CI migration", command: "rm -rf build && swift build -c release", waited: 20,
                    now: now, anchor: now),
                working(
                    "w", "Fix reconnect test",
                    calls: [
                        reading("/repo/Tests/ReconnectTests.swift", "w1"),
                        editing("/repo/Sources/Reconnect/Backoff.swift", "w2"),
                    ], now: now, anchor: now),
            ], now: now)
    }

    private static func alarmSources(now: Date, anchor: Date) -> [AgentSource] {
        let retry = TurnRetry(attempt: 2, reason: "The provider is rate limiting requests")
        return [
            asking(
                "ask", "CI migration", command: "rm -rf build && swift build -c release",
                waited: 420, now: now, anchor: anchor),
            source(
                "doc", "Docs translation", profile: homelab, machine: "homelab",
                state: conversation(
                    "translate the docs", [reading("/docs/guide.md", "d1")], now: anchor, retry: retry),
                now: now, anchor: anchor),
            working(
                "idx", "Index rebuild", calls: [running("swift test --filter Index", "i1")],
                beating: false, fill: 0.88, now: now, anchor: anchor),
            source(
                "bak", "Nightly backup", profile: attic, machine: "attic",
                state: conversation(
                    "back up the photos", [running("rsync -a photos/ vault/", "k1")], now: anchor),
                reachable: false, idleFor: 240, now: now, anchor: anchor),
            background(
                "rel", "Release notes", task: "swift test --parallel", ago: 2700, stalled: true,
                now: now, anchor: anchor),
        ]
    }

    private static func alarmWall(now: Date) -> AgentWall {
        let failed = ended(
            "auth", "Auth flow", .failed, at: now.addingTimeInterval(-90),
            reason: "swift build exited with status 1")
        let earlier = now.addingTimeInterval(-135)
        let before = read(
            alarmSources(now: earlier, anchor: now), finished: [failed], now: earlier)
        return read(alarmSources(now: now, anchor: now), finished: [failed], now: now, previous: before)
    }

    private static func finishingWall(now: Date) -> AgentWall {
        read(
            [],
            finished: [
                ended("dep", "Deploy check", .done, at: now.addingTimeInterval(-30), tools: 14),
                ended("lint", "Lint sweep", .stopped, at: now.addingTimeInterval(-50)),
                ended("docs", "Docs pass", .done, at: now.addingTimeInterval(-300)),
                ended("icon", "Icon export", .done, at: now.addingTimeInterval(-780), tools: 6),
                ended(
                    "schema", "Schema diff", machine: "homelab", .stopped,
                    at: now.addingTimeInterval(-1500)),
            ], now: now)
    }

    private static func crowdedWall(now: Date) -> AgentWall {
        let sources = [
            working(
                "a", "Fix reconnect test",
                calls: [editing("/repo/Sources/Reconnect/Backoff.swift", "a1")], now: now, anchor: now),
            working(
                "b", "Landing page refresh", profile: homelab, machine: "homelab",
                calls: [editing("/site/styles/footer.css", "b1")], now: now, anchor: now),
            working(
                "c", "Auth flow", calls: [running("swift build", "c1")], now: now, anchor: now),
            working(
                "d", "Docs translation", profile: homelab, machine: "homelab",
                calls: [reading("/docs/guide.md", "d1")], now: now, anchor: now),
            source(
                "e", "Draft changelog", state: conversation("draft the changelog", [], now: now),
                now: now),
            working(
                "f", "Icon export", calls: [running("make icons", "f1")], now: now, anchor: now),
            listed("g", "Schema diff", profile: homelab, machine: "homelab", task: "Comparing tables", now: now),
            listed("h", "Cache warm", profile: studio, machine: "studio", task: "Fetching pages", now: now),
            listed("i", "Typo hunt", profile: studio, machine: "studio", task: "Searching “teh”", now: now),
            listed("j", "Lint sweep", profile: homelab, machine: "homelab", task: "Reading Sources", now: now),
        ]
        return read(sources, now: now)
    }
}
