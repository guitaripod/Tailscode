import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

private struct OutlineRandom {
    var state: UInt64

    mutating func next() -> Int {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int(truncatingIfNeeded: state >> 33)
    }

    mutating func below(_ bound: Int) -> Int { next() % bound }
}

enum OutlineFixtures {
    static func conversations() -> [[ChatMessage]] {
        [
            NeuralDemo.conversation(),
            NeuralDemo.buildFix(prefix: "x-", answer: false),
            NeuralDemo.turn(prefix: "y-", answer: false),
            NeuralDemo.writing(prefix: "w-"),
            NeuralDemo.largeTurn(steps: 24, prefix: "l1-"),
            NeuralDemo.largeTurn(steps: 174, prefix: "l2-"),
            NeuralDemo.largeTurn(steps: 60, prefix: "l3-", answer: false),
            TurnBenchFixtures.conversation(turns: 12) + TurnBenchFixtures.settledTail(),
            TurnBenchFixtures.conversation(turns: 4) + TurnBenchFixtures.settledTail()
                + [TurnBenchFixtures.streaming("w w w")],
            ColdOpenFixtures.conversation(turns: 20),
            ColdOpenFixtures.heavy(turns: 6),
        ]
    }

    static func random(seed: Int) -> [ChatMessage] {
        var random = OutlineRandom(state: UInt64(seed) &* 2_654_435_761 &+ 7)
        var messages: [ChatMessage] = []
        let tools = [
            "Bash", "Read", "Edit", "Write", "Grep", "Task", "TodoWrite", "AskUserQuestion",
            "WebFetch", "Skill", "mcp__thing",
        ]
        for message in 0..<(1 + random.below(5)) {
            var parts: [MessagePart] = []
            for part in 0..<random.below(7) {
                let id = "p\(part)"
                switch random.below(8) {
                case 0: parts.append(MessagePart(id: id, kind: .reasoning("thinking \(part)")))
                case 1: parts.append(MessagePart(id: id, kind: .reasoning(random.below(2) == 0 ? "" : "  \n")))
                case 2, 3:
                    let name = tools[random.below(tools.count)]
                    let status: ToolStatus = [.pending, .running, .completed, .error, .stopped][random.below(5)]
                    var input: [String: JSONValue] = ["command": .string("run \(part)")]
                    if name == "Write" || name == "Edit" {
                        input["file_path"] = .string(
                            random.below(2) == 0 ? ".tailscode/design/a/board.json" : "src/f\(part).swift")
                    }
                    parts.append(
                        MessagePart(
                            id: id,
                            kind: .tool(
                                ToolCall(
                                    id: "c\(message)-\(part)", name: name, status: status,
                                    input: .object(input), output: random.below(2) == 0 ? "ok\nmore" : nil))))
                case 4, 5: parts.append(MessagePart(id: id, kind: .text("words \(part)")))
                case 6: parts.append(MessagePart(id: id, kind: .text(random.below(2) == 0 ? "" : "   ")))
                default:
                    parts.append(
                        random.below(2) == 0
                            ? MessagePart(id: id, kind: .file(FileReference(path: "/tmp/a.png")))
                            : MessagePart(id: id, kind: .unknown(type: "step-start")))
                }
            }
            let streaming = random.below(6) == 0
            messages.append(
                ChatMessage(
                    id: "m\(message)", role: random.below(7) == 0 ? .system : .assistant,
                    agentType: .claudeCode, parts: parts, createdAt: NeuralTurnFixtures.date(message),
                    completedAt: streaming ? nil : NeuralTurnFixtures.date(message + 1),
                    isStreaming: streaming, error: random.below(9) == 0 ? "boom" : nil,
                    modelID: random.below(3) == 0 ? "claude-fable-5" : nil,
                    reasoningEffort: random.below(4) == 0 ? "high" : nil,
                    finishReason: [nil, "stop", "aborted", "end_turn"][random.below(4)]))
        }
        if let first = messages.first, first.role == .system {
            messages[0] = ChatMessage(
                id: first.id, role: .assistant, agentType: .claudeCode, parts: first.parts,
                createdAt: first.createdAt, completedAt: first.completedAt,
                isStreaming: first.isStreaming, error: first.error, modelID: first.modelID,
                reasoningEffort: first.reasoningEffort, finishReason: first.finishReason)
        }
        return messages
    }
}

enum OutlineAgreement {
    static func agrees(_ outline: NeuralTurnOutline, with turn: NeuralTurn, group: [ChatMessage]) -> Bool {
        let anchored = turn.steps.first { turn.memberPartIDs.contains($0.id) } ?? turn.steps.first
        guard outline.id == turn.id, outline.stepCount == turn.steps.count,
            outline.anchor == anchored?.id, outline.anchorMessageID == anchored?.messageID,
            outline.answerPartIDs == turn.answerPartIDs,
            outline.boardPartIDs
                == turn.steps.filter { $0.isCard && TaskBoard.isBoardCall($0.title) }.map(\.id),
            outline.outcome == turn.outcome, outline.startedAt == turn.startedAt,
            outline.endedAt == turn.endedAt, outline.modelID == turn.modelID,
            outline.effort == turn.effort, outline.messageIDs == group.map(\.id),
            Set(outline.messageIDs) == turn.memberMessageIDs,
            outline.partCount == group.reduce(0, { $0 + $1.parts.count })
        else { return false }
        for message in group {
            for part in message.parts {
                let id = "\(message.id):\(part.id)"
                if outline.consumes(id) != turn.memberPartIDs.contains(id) { return false }
            }
        }
        return true
    }
}

@Suite("Neural turn outline: the placement of a brain without reading its steps")
struct NeuralTurnOutlineTests {
    private func turnGroups(_ messages: [ChatMessage]) -> [[ChatMessage]] {
        NeuralTurnCache.groups(of: messages)
    }

    @Test("it equals the outline of the turn the partition reads, for every demo conversation")
    func demos() {
        for messages in OutlineFixtures.conversations() {
            for (index, group) in turnGroups(messages).enumerated() {
                let running = index == turnGroups(messages).count - 1
                for awaiting in [NeuralAwaiting.none, NeuralAwaiting(approvals: ["x"])] {
                    let turn = NeuralTurns.partition(messages: group, running: running, awaiting: awaiting)[0]
                    #expect(
                        OutlineAgreement.agrees(
                            NeuralTurns.outline(messages: group, running: running, awaiting: awaiting),
                            with: turn, group: group))
                }
            }
        }
    }

    @Test("it equals the outline of the partitioned turn for thousands of random turns")
    func fuzz() {
        var brains = 0
        var cards = 0
        for seed in 0..<4_000 {
            let messages = OutlineFixtures.random(seed: seed)
            for group in turnGroups(messages) {
                for running in [false, true] {
                    let awaiting =
                        seed % 5 == 0
                        ? NeuralAwaiting(approvals: ["c0-1"], interrupted: [group[0].id]) : .none
                    let turn = NeuralTurns.partition(
                        messages: group, running: running, awaiting: awaiting)[0]
                    let outline = NeuralTurns.outline(
                        messages: group, running: running, awaiting: awaiting)
                    #expect(
                        OutlineAgreement.agrees(outline, with: turn, group: group),
                        "seed \(seed) running \(running)")
                    if outline.isBrain { brains += 1 }
                    if turn.steps.contains(where: \.isCard) { cards += 1 }
                }
            }
        }
        #expect(brains > 2_000)
        #expect(cards > 200)
    }

    @Test("a turn with no step is not a brain and an answer alone is not a step")
    func answerOnly() {
        let group = [
            NeuralTurnFixtures.message(1, [.text("Just words.")]),
            NeuralTurnFixtures.message(2, [.text("More words.")]),
        ]
        let outline = NeuralTurns.outline(messages: group, running: false)
        #expect(!outline.isBrain && outline.stepCount == 0 && outline.anchor == nil)
        #expect(outline.answerPartIDs == ["m1:p0", "m2:p0"] && !outline.consumes("m1:p0"))
    }

    @Test("the anchor is the first member step and falls back to the first step when all are cards")
    func anchors() {
        let task = NeuralTurnFixtures.task("sub", out: ["done"])
        let cards = [NeuralTurnFixtures.message(1, [task, .text("Answer.")])]
        let onlyCards = NeuralTurns.outline(messages: cards, running: false)
        #expect(onlyCards.isBrain && onlyCards.anchor == "m1:p0" && !onlyCards.consumes("m1:p0"))
        let mixed = [
            NeuralTurnFixtures.message(1, [task, NeuralTurnFixtures.bash("make"), .text("Answer.")])
        ]
        let outline = NeuralTurns.outline(messages: mixed, running: false)
        #expect(outline.anchor == "m1:p1" && outline.consumes("m1:p1") && !outline.consumes("m1:p0"))
    }

    @Test("a streamed list's outlines read no step, and indexing a turn reads that turn alone")
    func lazy() {
        let messages = ColdOpenFixtures.conversation(turns: 300)
        let cache = NeuralTurnCache()
        let list = cache.partitionList(messages: messages, running: false)
        #expect(list.count == 300 && cache.turnPartitions == 0)
        var anchors = 0
        for index in 0..<list.count where list.outline(at: index).anchor != nil { anchors += 1 }
        #expect(anchors == 300 && cache.turnPartitions == 0)
        #expect((0..<300).allSatisfy { !list.isRead(at: $0) })
        let turn = list[150]
        #expect(cache.turnPartitions == 1 && list.isRead(at: 150) && !list.isRead(at: 149))
        #expect(turn == NeuralTurns.partition(messages: turnGroups(messages)[150], running: false)[0])
        _ = list[150]
        #expect(cache.turnPartitions == 1)
        #expect(list.array == NeuralTurns.partition(messages: messages, running: false))
        #expect(cache.turnPartitions == 300)
    }

    @Test("a lazy list is the eager partition for every demo conversation, turn by turn")
    func sameAsPartition() {
        for messages in OutlineFixtures.conversations() {
            for running in [false, true] {
                let cache = NeuralTurnCache()
                let list = cache.partitionList(messages: messages, running: running)
                let eager = NeuralTurns.partition(messages: messages, running: running)
                #expect(list.count == eager.count)
                for index in eager.indices {
                    #expect(
                        OutlineAgreement.agrees(
                            list.outline(at: index), with: eager[index],
                            group: turnGroups(messages)[index]))
                    #expect(list[index] == eager[index])
                }
            }
        }
    }

    @Test("a streamed token keeps every earlier turn unread and its generation unchanged")
    func streamedTokensLeaveHistoryAlone() {
        var messages = TurnBenchFixtures.conversation(turns: 400) + TurnBenchFixtures.settledTail()
        messages.append(TurnBenchFixtures.streaming("w"))
        let cache = NeuralTurnCache()
        var list = cache.partitionList(messages: messages, running: true)
        let generations = (0..<list.count - 1).map { list.generation(at: $0) }
        let before = cache.turnPartitions
        let tokens = TurnBenchFixtures.tokens(30)
        var tailGenerations = Set<Int>()
        for token in tokens {
            messages[messages.count - 1] = token
            list = cache.partitionList(messages: messages, running: true, stablePrefix: messages.count - 4)
            tailGenerations.insert(list.generation(at: list.count - 1))
        }
        #expect(cache.turnPartitions - before == tokens.count)
        #expect((0..<list.count - 1).allSatisfy { list.generation(at: $0) == generations[$0] })
        #expect(tailGenerations.count == tokens.count)
        #expect((0..<list.count - 1).allSatisfy { !list.isRead(at: $0) })
        #expect(list.array == NeuralTurns.partition(messages: messages, running: true))
    }

    @Test("a slot knows its messages and the question that began the turn, read cold or streamed")
    func slotsCarryTheirQuestion() {
        var messages = TurnBenchFixtures.conversation(turns: 30) + TurnBenchFixtures.settledTail()
        messages.append(TurnBenchFixtures.streaming("w"))
        let cache = NeuralTurnCache()
        var list = cache.partitionList(messages: messages, running: true)
        for index in 0..<30 {
            let slot = list.slot(at: index)
            #expect(slot.asked?.id == "u\(index)" && slot.messages.map(\.id) == ["a\(index)"])
        }
        for token in TurnBenchFixtures.tokens(5) {
            messages[messages.count - 1] = token
            list = cache.partitionList(messages: messages, running: true, stablePrefix: messages.count - 4)
            let tail = list.slot(at: list.count - 1)
            #expect(tail.asked?.id == "ulast" && tail.messages.last?.id == "live")
        }
        #expect(list.slot(at: 7).asked?.id == "u7")
    }

    @Test("a message changed deep in a long conversation changes only its turn's generation")
    func changedMiddle() {
        var messages = TurnBenchFixtures.conversation(turns: 100)
        let cache = NeuralTurnCache()
        let first = cache.partitionList(messages: messages, running: false)
        messages[81].parts[0] = MessagePart(
            id: "p0", kind: NeuralTurnFixtures.bash("different", out: ["ok"]))
        let second = cache.partitionList(messages: messages, running: false)
        let changed = (0..<second.count).filter { second.generation(at: $0) != first.generation(at: $0) }
        #expect(changed == [40])
        #expect(second.array == NeuralTurns.partition(messages: messages, running: false))
    }
}
