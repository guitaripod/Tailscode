import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("What a turn's card says beyond its line")
struct LiveActivityBriefTests {
    private static let now = Date(timeIntervalSince1970: 3_000_000)

    private static func prompt(_ words: String = "fix it") -> ChatMessage {
        ChatMessage(
            id: "u", role: .user, agentType: .claudeCode,
            parts: [MessagePart(id: "u-t", kind: .text(words))], createdAt: now)
    }

    private static func call(
        _ id: String, _ name: String, _ status: ToolStatus, _ input: [String: String]
    ) -> ToolCall {
        ToolCall(
            id: id, name: name, status: status,
            input: .object(input.mapValues { JSONValue.string($0) }))
    }

    private static func answer(_ parts: [MessagePart], done: Bool = false) -> ChatMessage {
        ChatMessage(
            id: "a", role: .assistant, agentType: .claudeCode, parts: parts, createdAt: now,
            completedAt: done ? now : nil, isStreaming: !done, modelID: "claude-opus-4-5")
    }

    private static func state(_ status: BackendStatus, _ messages: [ChatMessage]) -> ConversationState {
        ConversationState(messages: messages, status: status, connection: .live, hasLoadedTranscript: true)
    }

    @Test("The brief's keys are the ones claude-bridge writes, and a step's too")
    func wireKeys() throws {
        let brief = LiveActivityBrief(
            steps: [LiveActivityStep(id: "x", tool: "Bash", input: ["command": "ls"], state: .done)],
            plan: LiveActivityPlan(done: 1, total: 3, current: "a", next: "b"), said: "ok", files: 2,
            added: 4, removed: 1, beat: String(repeating: "0", count: AgentBeat.buckets),
            moved: Self.now, model: "opus", ultra: true, fill: 0.4, ask: "rm -rf build")
        let object = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(brief)) as? [String: Any])
        #expect(
            Set(object.keys) == [
                "steps", "plan", "said", "files", "added", "removed", "beat", "moved", "model",
                "ultra", "fill", "ask",
            ])
        let step = try #require((object["steps"] as? [[String: Any]])?.first)
        #expect(Set(step.keys) == ["id", "tool", "input", "state"])
        #expect(step["state"] as? String == "done")
        let plan = try #require(object["plan"] as? [String: Any])
        #expect(Set(plan.keys) == ["done", "total", "current", "next"])
        #expect(
            ["running", "done", "failed", "stopped"]
                == [LiveActivityStep.State.running, .done, .failed, .stopped].map(\.rawValue))
    }

    @Test("A card written before the brief existed decodes with none")
    func absentDecodes() throws {
        let empty = try JSONDecoder().decode(LiveActivityBrief.self, from: Data("{}".utf8))
        #expect(empty.isEmpty)
        #expect(empty.beats.isEmpty)
    }

    @Test("A step reads in exactly the words the wall gives the call it came from")
    func stepWords() {
        let calls = [
            Self.call("1", "Bash", .running, ["command": "swift test --parallel", "description": "Run tests"]),
            Self.call("2", "Edit", .completed, ["file_path": "/src/Backoff.swift", "old_string": "a", "new_string": "b"]),
            Self.call("3", "Grep", .completed, ["pattern": "jitter", "path": "Sources"]),
            Self.call("4", "Read", .error, ["file_path": "/src/Missing.swift"]),
            Self.call("5", "WebFetch", .running, ["url": "https://example.com/page", "prompt": "summarise"]),
            Self.call("6", "mcp__zvec_grep__search", .completed, ["query": "x"]),
        ]
        for call in calls {
            #expect(LiveActivityStep(call).words == AgentPlain.words(for: call).text, "\(call.name)")
        }
    }

    @Test("A step carries the fields its reading needs and never an edit's text or a prompt")
    func stepFields() {
        let step = LiveActivityStep(
            Self.call(
                "toolu_0123456789abcdef", "Edit", .completed,
                [
                    "file_path": "/src/Backoff.swift", "old_string": "secret", "new_string": "more",
                    "content": "body", "prompt": "do it",
                ]))
        #expect(step.input == ["file_path": "/src/Backoff.swift"])
        #expect(step.id == "0123456789abcdef".suffix(12).description)
        let long = LiveActivityStep(
            Self.call("1", "Bash", .running, ["command": String(repeating: "x", count: 900)]))
        #expect(long.input?["command"]?.count == LiveActivityStep.inputLimit)
    }

    @Test("A running turn's brief: its latest steps, its words, its files, who answers, and its pulse")
    func readsTurn() {
        var parts: [MessagePart] = []
        for index in 0..<6 {
            parts.append(
                MessagePart(
                    id: "p\(index)",
                    kind: .tool(Self.call("c\(index)", "Read", .completed, ["file_path": "/f\(index).swift"]))))
        }
        parts.append(
            MessagePart(
                id: "e",
                kind: .tool(
                    Self.call("edit", "Edit", .completed, ["file_path": "/src/A.swift", "old_string": "a", "new_string": "b\nc"]))))
        parts.append(MessagePart(id: "t", kind: .text("I changed the **retry** timer.")))
        let state = Self.state(.running, [Self.prompt(), Self.answer(parts)])
        let stamps = [Self.now.addingTimeInterval(-3), Self.now.addingTimeInterval(-1)]
        let brief = LiveActivityBrief.read(state, stamps: stamps, now: Self.now)
        #expect(brief.steps?.count == LiveActivityStep.limit)
        #expect(brief.steps?.last?.tool == "Edit")
        #expect(brief.files == 1)
        #expect(brief.added == 2)
        #expect(brief.removed == 1)
        #expect(brief.said == nil, "a running card's words wait for the ending")
        let settled = LiveActivityBrief.read(state, stamps: stamps, now: Self.now, settled: true)
        #expect(settled.said == "I changed the retry timer.")
        #expect(settled.beat == nil)
        #expect(settled.moved == nil)
        #expect(settled.plan == nil)
        #expect(settled.ask == nil)
        #expect(settled.steps?.count == LiveActivityStep.limit)
        #expect(LiveActivityBrief.read(state, stamps: stamps, now: Self.now).fill == nil)
        #expect(brief.model == "claude-opus-4-5")
        #expect(brief.modelWord == ModelBadge.shortName("claude-opus-4-5"))
        #expect(brief.moved == Self.now.addingTimeInterval(-1))
        #expect(brief.beats.count == AgentBeat.buckets)
        #expect(brief.beats.reduce(0, +) == 2)
        #expect(brief.ultra == nil)
    }

    @Test("A turn summoned with the word runs at ultracode on its card")
    func ultracode() {
        let state = Self.state(.running, [Self.prompt("ultracode: refactor it"), Self.answer([])])
        #expect(LiveActivityBrief.read(state, stamps: [], now: Self.now).ultra == true)
        let plain = Self.state(.running, [Self.prompt(), Self.answer([])])
        #expect(LiveActivityBrief.read(plain, stamps: [], now: Self.now, effort: "ultracode").ultra == true)
        #expect(LiveActivityBrief.read(plain, stamps: [], now: Self.now).ultra == nil)
    }

    @Test("A brief too big for the card gives up its least useful parts first and always fits")
    func budget() {
        let huge = String(repeating: "word ", count: 400)
        let steps = (0..<4).map { index in
            LiveActivityStep(
                id: "s\(index)", tool: "Bash",
                input: Dictionary(
                    uniqueKeysWithValues: LiveActivityStep.inputKeys.map { ($0, String(huge.prefix(160))) }),
                state: .done)
        }
        let brief = LiveActivityBrief(
            steps: steps, plan: LiveActivityPlan(done: 1, total: 9, current: huge, next: huge),
            said: huge, files: 3, beat: String(repeating: "4", count: AgentBeat.buckets),
            moved: Self.now, model: "claude-opus-4-5", ask: huge)
        let fitted = brief.fitted()
        #expect(fitted.encodedSize <= LiveActivityBrief.byteBudget)
        #expect(fitted.moved == Self.now)
        let small = LiveActivityBrief(said: "short", moved: Self.now)
        #expect(small.fitted() == small)
        let tight = brief.fitted(budget: 120)
        #expect(tight.encodedSize <= 120)
    }

    @Test("A pulse keeps a stamp a quarter second at most and nothing older than its minute")
    func pulse() {
        var pulse = LiveActivityPulse()
        for tenth in 0..<20 { pulse.note(Self.now.addingTimeInterval(Double(tenth) / 10)) }
        #expect(pulse.stamps.count == 7)
        pulse.note(Self.now.addingTimeInterval(120))
        #expect(pulse.stamps == [Self.now.addingTimeInterval(120)])
        #expect(LiveActivityBrief.beatDigits(stamps: [], now: Self.now) == nil)
    }

    @Test("A digit string of the wrong length is no pulse at all")
    func beats() {
        #expect(LiveActivityBrief(beat: "123").beats.isEmpty)
        #expect(LiveActivityBrief(beat: String(repeating: "9", count: AgentBeat.buckets)).beats.allSatisfy { $0 == AgentBeat.ceiling })
    }

    @Test("Each detail wears the wall's state, mark and word")
    func faces() {
        let fallback = LiveActivityFace(symbol: "brain", tone: .live)
        func look(_ detail: LiveActivityDetail, settled: Bool, background: Int = 0, quiet: Date? = nil) -> LiveActivityLook {
            LiveActivityLook.read(
                detail: detail, settled: settled, background: background, tool: "Bash", quietSince: quiet,
                fallback: fallback)
        }
        #expect(look(.thinking, settled: false).state == .thinking)
        #expect(look(.tool, settled: false).state == .working)
        #expect(look(.tool, settled: false).mark == .orb)
        #expect(look(.approval, settled: false).mark == .ask)
        #expect(look(.question, settled: true).state.isNeedsYou)
        #expect(look(.finished, settled: true).mark == .check)
        #expect(look(.finished, settled: true, background: 2).mark == .background)
        #expect(look(.failed, settled: true).mark == .cross)
        #expect(look(.interrupted, settled: true).state == .finished(.failed))
        #expect(look(.cancelled, settled: true).mark == .stop)
        #expect(look(.lost, settled: true).mark == .unknown)
        #expect(look(.tool, settled: false, quiet: Self.now).mark == .quiet)
        #expect(look(.approval, settled: false, quiet: Self.now).mark == .ask, "an ask is never read as quiet")
        #expect(look(.finished, settled: true, quiet: Self.now).mark == .check)
        for detail in LiveActivityDetail.allCases {
            #expect(!look(detail, settled: detail.phase == "done" || detail.phase == "error").word.isEmpty)
        }
    }

    @Test("A live card is redrawn as quiet once nothing has moved for the wall's threshold")
    func quiet() {
        let moved = Self.now.addingTimeInterval(-10)
        #expect(LiveActivityQuiet.since(moved: moved, now: Self.now) == nil)
        #expect(LiveActivityQuiet.since(moved: moved, now: Self.now.addingTimeInterval(40)) == moved)
        #expect(
            LiveActivityQuiet.staleDate(moved: moved, now: Self.now, ceiling: 1800)
                == moved.addingTimeInterval(LiveActivityQuiet.after))
        #expect(
            LiveActivityQuiet.staleDate(moved: Self.now.addingTimeInterval(-600), now: Self.now, ceiling: 1800)
                == Self.now.addingTimeInterval(1))
        #expect(
            LiveActivityQuiet.staleDate(moved: nil, now: Self.now, ceiling: 1800)
                == Self.now.addingTimeInterval(LiveActivityQuiet.after))
    }

    @Test("The ending's wire words are the ones claude-bridge reads")
    func endingWire() {
        #expect(LiveActivityEnding.expand.wire == "silent")
        #expect(LiveActivityEnding.expandWithSound.wire == "sound")
        #expect(LiveActivityEnding.stay.wire == nil)
        #expect(LiveActivityEnding.allCases.filter(\.alerts) == [.expand, .expandWithSound])
    }

    @Test("A brief exactly as claude-bridge 1.29 pushes it decodes and reads")
    func bridgeWire() throws {
        let pushed = #"{"added":2,"beat":"000000000000000000000001","files":1,"model":"claude-opus-4-5","moved":821692800,"plan":{"current":"Doing b","done":1,"next":"c","total":3},"removed":1,"steps":[{"id":"456789abcdef","input":{"command":"swift test","description":"Run tests"},"state":"running","tool":"Bash"},{"id":"p","state":"done","tool":"TodoWrite"},{"id":"e","input":{"file_path":"/x.swift"},"state":"done","tool":"Edit"}],"ultra":true}"#
        let brief = try JSONDecoder().decode(LiveActivityBrief.self, from: Data(pushed.utf8))
        #expect(brief.steps?.map(\.tool) == ["Bash", "TodoWrite", "Edit"])
        #expect(brief.steps?.first?.words == AgentPlain.command("swift test", tense: .running).text)
        #expect(brief.steps?[1].words == AgentPlain.words(for: ToolCall(id: "p", name: "TodoWrite", status: .completed)).text)
        #expect(brief.plan == LiveActivityPlan(done: 1, total: 3, current: "Doing b", next: "c"))
        #expect(brief.files == 1)
        #expect(brief.added == 2)
        #expect(brief.removed == 1)
        #expect(brief.beats.count == AgentBeat.buckets)
        #expect(brief.moved == Date(timeIntervalSinceReferenceDate: 821_692_800))
        #expect(brief.ultra == true)
        #expect(brief.modelWord == ModelBadge.shortName("claude-opus-4-5"))
    }

    @Test("A long path is cut from its start, so the file's own name survives")
    func pathSuffix() {
        let path = "/" + String(repeating: "deep/", count: 60) + "Backoff.swift"
        let step = LiveActivityStep(Self.call("r", "Read", .completed, ["file_path": path]))
        #expect(step.input?["file_path"]?.hasSuffix("Backoff.swift") == true)
        #expect(step.words == AgentPlain.words(for: Self.call("r", "Read", .completed, ["file_path": path])).text)
    }

    @Test("The line and the list agree on the step that is out, even beside parallel calls")
    func lineAndList() {
        let brief = LiveActivityBrief(steps: [
            LiveActivityStep(id: "a", tool: "Bash", input: ["command": "swift test"], state: .running),
            LiveActivityStep(id: "b", tool: "Read", input: ["file_path": "/A.swift"], state: .done),
        ])
        let line = LiveActivityHeadline.line(
            detail: .tool, statusText: "", brief: brief, tool: "Bash", toolCount: 2, background: 0,
            settled: false)
        #expect(line == brief.steps?[0].words)
        let listed = LiveActivityHeadline.listed(brief: brief, detail: .tool, settled: false, limit: 3)
        #expect(listed.map(\.id) == ["b"])
        #expect(LiveActivityHeadline.listed(brief: brief, detail: .tool, settled: true, limit: 3).map(\.id) == ["b", "a"])
    }

    @Test("A finished line counts the work and leaves the time to the clock beside it")
    func finishedLine() {
        let line = LiveActivityHeadline.line(
            detail: .finished, statusText: "", brief: LiveActivityBrief(files: 2), tool: nil,
            toolCount: 14, background: 0, settled: true)
        #expect(line == AgentFinish.line(outcome: .done, duration: nil, tools: 14, files: 2))
        #expect(!line.contains("6m"))
    }

    @Test("Running chats get cards waiting-on-you first, then the latest, never muted or twice, within the room left")
    func follow() {
        let older = Self.now.addingTimeInterval(-60)
        let running = [
            LiveActivityFollow.Candidate(sessionID: "a", movedAt: older),
            LiveActivityFollow.Candidate(sessionID: "b", movedAt: Self.now),
            LiveActivityFollow.Candidate(sessionID: "c", movedAt: older, waitsOnYou: true),
            LiveActivityFollow.Candidate(sessionID: "d", movedAt: Self.now),
            LiveActivityFollow.Candidate(sessionID: "e", movedAt: Self.now),
            LiveActivityFollow.Candidate(sessionID: "b", movedAt: Self.now),
        ]
        #expect(
            LiveActivityFollow.choose(running, following: ["d"], muted: ["e"], standing: 1, limit: 4)
                == ["c", "b", "a"])
        #expect(LiveActivityFollow.choose(running, following: [], muted: [], standing: 4).isEmpty)
        #expect(LiveActivityFollow.choose([], following: [], muted: [], standing: 0).isEmpty)
    }

    @Test("A full Lock Screen gives up its oldest ending first, and a followed card only to one the person asked for")
    func room() {
        let early = Self.now.addingTimeInterval(-3600)
        let late = Self.now.addingTimeInterval(-60)
        let followedOld = LiveActivityRoom.Standing(
            sessionID: "followed-old", claim: .followed, endedAt: nil, movedAt: early)
        let followedNew = LiveActivityRoom.Standing(
            sessionID: "followed-new", claim: .followed, endedAt: nil, movedAt: late)
        let followedAsking = LiveActivityRoom.Standing(
            sessionID: "followed-asking", claim: .followed, endedAt: nil, movedAt: early - 60,
            waitsOnYou: true)
        let asked = LiveActivityRoom.Standing(
            sessionID: "asked", claim: .asked, endedAt: nil, movedAt: early - 120)
        let endedQuestion = LiveActivityRoom.Standing(
            sessionID: "ended-question", claim: .asked, endedAt: early - 600, movedAt: early,
            waitsOnYou: true)
        let endedLate = LiveActivityRoom.Standing(
            sessionID: "ended-late", claim: .asked, endedAt: late, movedAt: late)
        let endedEarly = LiveActivityRoom.Standing(
            sessionID: "ended-early", claim: .followed, endedAt: early, movedAt: early)

        let full = [followedOld, followedNew, followedAsking, asked, endedQuestion, endedLate, endedEarly]
        #expect(LiveActivityRoom.yielding(full, to: .followed) == "ended-early")
        #expect(LiveActivityRoom.yielding(full, to: .asked) == "ended-early")
        #expect(LiveActivityRoom.yielding([endedQuestion, endedLate], to: .followed) == "ended-late")
        #expect(LiveActivityRoom.yielding([endedQuestion], to: .asked) == "ended-question")

        let running = [followedOld, followedNew, followedAsking, asked]
        #expect(LiveActivityRoom.yielding(running, to: .asked) == "followed-old")
        #expect(LiveActivityRoom.yielding(running, to: .followed) == nil)
        #expect(LiveActivityRoom.yielding([followedAsking, asked], to: .asked) == nil)
        #expect(LiveActivityRoom.yielding([], to: .asked) == nil)
    }

    @Test("A card opens by itself only while the listing still says the turn is running")
    func listedRunning() {
        func session(
            active: Bool?, turnOpen: Bool? = nil, tasks: Int = 0, agents: Int? = nil
        ) -> AgentSession {
            var session = AgentSession(
                id: "s", agentType: .claudeCode, title: "Chat", createdAt: Self.now,
                updatedAt: Self.now, isActive: active)
            session.turnOpen = turnOpen
            session.backgroundWork = tasks > 0 ? BackgroundWork(tasks: tasks) : nil
            session.activeAgents = agents
            return session
        }
        #expect(LiveActivityRoom.listedRunning(session(active: true)))
        #expect(!LiveActivityRoom.listedRunning(session(active: false)))
        #expect(!LiveActivityRoom.listedRunning(session(active: nil)))
        #expect(!LiveActivityRoom.listedRunning(session(active: true, tasks: 2)))
        #expect(!LiveActivityRoom.listedRunning(session(active: true, agents: 1)))
        #expect(LiveActivityRoom.listedRunning(session(active: true, turnOpen: true, tasks: 2, agents: 1)))
        #expect(!LiveActivityRoom.listedRunning(session(active: true, turnOpen: false)))
        #expect(LiveActivityRoom.listedRunning(session(active: false, turnOpen: true)))
    }
}
