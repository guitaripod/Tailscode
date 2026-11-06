import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("What a roomy tile says beyond its line")
struct AgentWallBriefTests {
    private static let epoch = Date(timeIntervalSince1970: 1_800_000_000)

    private static func prompt() -> ChatMessage {
        ChatMessage(
            id: "u", role: .user, agentType: .claudeCode,
            parts: [MessagePart(id: "p", kind: .text("fix the flaky test"))],
            createdAt: epoch.addingTimeInterval(-300))
    }

    private static func edit(_ id: String, _ path: String, old: String, new: String) -> ToolCall {
        ToolCall(
            id: id, name: "Edit", status: .completed,
            input: .object([
                "file_path": .string(path), "old_string": .string(old), "new_string": .string(new),
            ]))
    }

    private static func todos(_ items: [(String, String)]) -> ToolCall {
        ToolCall(
            id: "todo", name: "TodoWrite", status: .completed,
            input: .object([
                "todos": .array(
                    items.map {
                        .object([
                            "content": .string($0.0), "status": .string($0.1),
                            "activeForm": .string("Doing " + $0.0.lowercased()),
                        ])
                    })
            ]))
    }

    private static func state(_ parts: [MessagePart], status: BackendStatus = .running) -> ConversationState {
        ConversationState(
            messages: [
                prompt(),
                ChatMessage(
                    id: "a", role: .assistant, agentType: .claudeCode, parts: parts,
                    createdAt: epoch.addingTimeInterval(-200), isStreaming: status == .running),
            ],
            status: status, hasLoadedTranscript: true)
    }

    private static func tool(_ call: ToolCall) -> MessagePart {
        MessagePart(id: "p-" + call.id, kind: .tool(call))
    }

    @Test("The counts, the files and the last words come from the turn")
    func factsFilesAndWords() {
        let parts = [
            Self.tool(Self.edit("e1", "/r/Backoff.swift", old: "a", new: "b\nc")),
            Self.tool(Self.edit("e2", "/r/Tests.swift", old: "", new: "x\ny\nz")),
            Self.tool(Self.edit("e3", "/r/Backoff.swift", old: "d\ne", new: "f")),
            MessagePart(id: "t", kind: .text("Found it: the **retry timer** fires twice.")),
        ]
        let facts = AgentFacts.read(state: Self.state(parts), agents: [], now: Self.epoch)
        #expect(facts.said == "Found it: the retry timer fires twice.")
        #expect(facts.edits.map(\.name) == ["Backoff.swift", "Tests.swift"])
        #expect(facts.edits.first == WallFile(name: "Backoff.swift", added: 3, removed: 3))
        let brief = WallBrief.read(facts)
        #expect(brief.facts == "3 tools · edited 2 files +6 \u{2212}3")
        #expect(brief.filesLine == "Backoff.swift +3 \u{2212}3  ·  Tests.swift +3")
    }

    @Test("A plan in hand reads as how far through, the item it is on and what is next")
    func plan() {
        let board = Self.todos([
            ("Read the code", "completed"), ("Fix the timer", "in_progress"),
            ("Run the suite", "pending"), ("Write it up", "pending"),
        ])
        let state = Self.state([Self.tool(board)])
        let read = AgentLine.plan(in: state)
        let plan = read.flatMap(WallPlan.init(board:))
        #expect(plan?.done == 1 && plan?.total == 4)
        #expect(plan?.lines == ["▸ Doing fix the timer", "○ Run the suite", "○ Write it up"])
        #expect(plan?.headline.hasSuffix("1 of 4") == true)
        let finished = Self.todos([("Read the code", "completed")])
        #expect(AgentLine.plan(in: Self.state([Self.tool(finished)])).flatMap(WallPlan.init(board:)) == nil)
    }

    @Test("The tower's plan reaches the board and the wall")
    func briefReachesTheTile() {
        var facts = AgentFacts.read(
            state: Self.state([Self.tool(Self.edit("e1", "/r/A.swift", old: "a", new: "b"))]),
            agents: [], now: Self.epoch)
        facts.plan = TaskBoard.fold([Self.todos([("One", "in_progress"), ("Two", "pending")])])
        let session = AgentSession(
            id: "s", agentType: .claudeCode, title: "Fix", createdAt: Self.epoch,
            updatedAt: Self.epoch, isActive: true)
        let entry = SessionEntry(
            profileID: "p", profileName: "studio", host: "studio", backendType: .claudeCode,
            session: session)
        let board = AgentBoard.read(
            sources: [AgentSource(entry: entry, facts: facts, reachable: true, unread: false)],
            now: Self.epoch)
        #expect(board.working.first?.brief.plan?.total == 2)
        let wall = AgentWall.read(board: board, hour: nil, now: Self.epoch, aspect: 16 / 9, previous: nil)
        #expect(wall.tiles.first?.brief.files.map(\.name) == ["A.swift"])
        #expect(wall.tiles.first?.brief.plan?.current == "Doing one")
    }

    @Test("Room goes to the latest step first, then the plan, the words, the counts, the earlier steps and the files")
    func fill() {
        let offers = [
            WallBriefFill.Offer(part: .facts, lineHeight: 10, lines: 1),
            WallBriefFill.Offer(part: .plan, lineHeight: 10, lines: 4),
            WallBriefFill.Offer(part: .said, lineHeight: 10, lines: 3),
            WallBriefFill.Offer(part: .steps, lineHeight: 10, lines: 5),
            WallBriefFill.Offer(part: .files, lineHeight: 10, lines: 2),
        ]
        #expect(WallBriefFill.choose(offers, room: 5, gap: 2).isEmpty)
        #expect(WallBriefFill.choose(offers, room: 12, gap: 2) == [.steps: 1])
        #expect(WallBriefFill.choose(offers, room: 32, gap: 2) == [.steps: 1, .facts: 1])
        #expect(WallBriefFill.choose(offers, room: 54, gap: 2) == [.steps: 1, .plan: 4])
        #expect(WallBriefFill.choose(offers, room: 86, gap: 2) == [.steps: 1, .plan: 4, .said: 3])
        #expect(WallBriefFill.choose(offers, room: 98, gap: 2) == [.steps: 1, .plan: 4, .said: 3, .facts: 1])
        let roomy = WallBriefFill.choose(offers, room: 1000, gap: 2)
        #expect(roomy == [.facts: 1, .plan: 4, .said: 3, .steps: 5, .files: 2])
        let more = WallBriefFill.choose(offers, room: 118, gap: 2)
        #expect(more[.steps] == 3 && more[.files] == nil)
        let noSteps = WallBriefFill.choose(offers.filter { $0.part != .steps }, room: 40, gap: 2)
        #expect(noSteps == [.plan: 3])
    }

    @Test("Every finished edit counts, a file is kept by its path, and a failed edit changed nothing")
    func editCounting() {
        var parts = (0..<14).map {
            Self.tool(Self.edit("e\($0)", "/r/F\($0).swift", old: "a", new: "b"))
        }
        parts.append(Self.tool(Self.edit("dupA", "/r/A/Model.swift", old: "a", new: "b")))
        parts.append(Self.tool(Self.edit("dupB", "/r/B/Model.swift", old: "a", new: "b")))
        var failed = Self.edit("bad", "/r/Broken.swift", old: "x", new: "y")
        failed.status = .error
        parts.append(Self.tool(failed))
        let facts = AgentFacts.read(state: Self.state(parts), agents: [], now: Self.epoch)
        #expect(facts.edits.count == 16)
        #expect(facts.edits.filter { $0.name == "Model.swift" }.count == 2)
        #expect(!facts.edits.contains { $0.name == "Broken.swift" })
        #expect(WallBrief.read(facts).facts?.contains("edited 16 files") == true)
    }
}
