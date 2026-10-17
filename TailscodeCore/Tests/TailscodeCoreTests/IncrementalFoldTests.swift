import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

private struct SplitMix: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Streams a conversation the way a server does and breaks it the ways a server does: a message
/// added, the last one growing, a tool changing state in the middle, one dropped, two swapped, the
/// whole transcript fetched again into buffers of its own.
private struct Conversation {
    var rng: SplitMix
    var messages: [ChatMessage] = []
    private var serial = 0
    private var clock = Date(timeIntervalSince1970: 1_780_000_000)

    init(seed: UInt64) { rng = SplitMix(state: seed) }

    private mutating func tick() -> Date {
        clock = clock.addingTimeInterval(Double(Int.random(in: 1...40, using: &rng)))
        return clock
    }

    mutating func append() {
        serial += 1
        let at = tick()
        switch Int.random(in: 0..<7, using: &rng) {
        case 0:
            messages.append(
                ChatMessage(
                    id: "u\(serial)", role: .user, agentType: .claudeCode,
                    parts: [MessagePart(id: "t", kind: .text("prompt \(serial) " + Self.filler(&rng)))],
                    createdAt: at))
        case 1:
            let task = "task\(serial)"
            messages.append(
                ChatMessage(
                    id: "a\(serial)", role: .assistant, agentType: .claudeCode,
                    parts: [
                        MessagePart(
                            id: "wf",
                            kind: .tool(
                                ToolCall(
                                    id: "wf-\(serial)", name: "Workflow",
                                    status: Bool.random(using: &rng) ? .running : .completed,
                                    input: .object(["name": .string("flow \(serial)")]),
                                    output: "Workflow launched in background. Task ID: \(task)\n")))
                    ],
                    createdAt: at))
        case 2:
            let task = "task\(max(1, serial - Int.random(in: 1...6, using: &rng)))"
            messages.append(
                ChatMessage(
                    id: "n\(serial)", role: .user, agentType: .claudeCode,
                    parts: [
                        MessagePart(
                            id: "t",
                            kind: .text(
                                "<task-notification>\n<task-id>\(task)</task-id>\n"
                                    + "<result>\"done \(serial)\"</result>\n</task-notification>"))
                    ],
                    createdAt: at))
        case 3:
            messages.append(
                ChatMessage(
                    id: "a\(serial)", role: .assistant, agentType: .claudeCode,
                    parts: [
                        MessagePart(
                            id: "bash",
                            kind: .tool(
                                ToolCall(
                                    id: "b-\(serial)", name: "Bash",
                                    status: Self.status(&rng), input: .object([:]),
                                    output: Bool.random(using: &rng) ? "ok" : nil)))
                    ],
                    createdAt: at, isStreaming: Bool.random(using: &rng)))
        default:
            messages.append(
                ChatMessage(
                    id: "a\(serial)", role: .assistant, agentType: .claudeCode,
                    parts: [MessagePart(id: "t", kind: .text(Self.filler(&rng)))],
                    createdAt: at,
                    completedAt: Bool.random(using: &rng) ? at.addingTimeInterval(5) : nil,
                    isStreaming: Bool.random(using: &rng),
                    costUSD: Bool.random(using: &rng) ? Double.random(in: 0.001...2, using: &rng) : nil,
                    modelID: ["opus", "sonnet", nil].randomElement(using: &rng) ?? nil,
                    totalTokens: Int.random(in: 10...5000, using: &rng)))
        }
    }

    mutating func growLast() {
        guard !messages.isEmpty else { return }
        let last = messages.count - 1
        grow(at: last)
    }

    mutating func growSomewhere(after floor: Int = 0) {
        guard messages.count > floor else { return }
        grow(at: Int.random(in: floor..<messages.count, using: &rng))
    }

    private mutating func grow(at index: Int) {
        let suffix = Self.filler(&rng)
        let flip = Self.status(&rng)
        if messages[index].parts.isEmpty {
            messages[index].parts.append(MessagePart(id: "t", kind: .text(suffix)))
            return
        }
        let part = messages[index].parts.count - 1
        switch messages[index].parts[part].kind {
        case .text, .reasoning:
            messages[index].parts[part].appendText(suffix)
        case .tool(var call):
            call.status = flip
            if Bool.random(using: &rng) { call.output = (call.output ?? "") + suffix }
            messages[index].parts[part].kind = .tool(call)
        default:
            messages[index].isStreaming.toggle()
        }
        if Int.random(in: 0..<4, using: &rng) == 0 {
            messages[index].completedAt = clock
            messages[index].costUSD = Double.random(in: 0.001...1, using: &rng)
        }
    }

    mutating func drop(after floor: Int = 0) {
        guard messages.count > floor else { return }
        messages.remove(at: Int.random(in: floor..<messages.count, using: &rng))
    }

    mutating func truncate() {
        guard !messages.isEmpty else { return }
        messages.removeLast(Int.random(in: 1...min(5, messages.count), using: &rng))
    }

    mutating func swap(after floor: Int = 0) {
        guard messages.count - floor >= 2 else { return }
        let a = Int.random(in: floor..<messages.count, using: &rng)
        let b = Int.random(in: floor..<messages.count, using: &rng)
        messages.swapAt(a, b)
    }

    mutating func refetch() {
        let again = try? JSONDecoder().decode(
            [ChatMessage].self, from: JSONEncoder().encode(messages))
        if let again { messages = again }
    }

    var firstOpenIndex: Int {
        messages.lastIndex { $0.role == .user }.map { $0 + 1 } ?? 0
    }

    private static func status(_ rng: inout SplitMix) -> ToolStatus {
        [.pending, .running, .completed, .error, .stopped].randomElement(using: &rng) ?? .running
    }

    private static func filler(_ rng: inout SplitMix) -> String {
        String(repeating: "word ", count: Int.random(in: 1...30, using: &rng))
    }
}

@Suite("Incremental folds answer what the fold from scratch answers")
struct IncrementalFoldTests {
    private static func agents(_ rng: inout SplitMix, at clock: Date) -> [SubagentSummary] {
        (0..<Int.random(in: 0...4, using: &rng)).map { index in
            SubagentSummary(
                id: "agent-\(index)", title: "agent \(index)",
                agentType: WorkflowRunAssembly.agentType,
                updatedAt: clock.addingTimeInterval(Double(index * 7)),
                isActive: Bool.random(using: &rng), isCompleted: Bool.random(using: &rng),
                startedAt: clock.addingTimeInterval(Double(index * 5)))
        }
    }

    @Test("Workflow runs, over a conversation that grows, edits, loses and reorders messages")
    func workflowFoldMatchesAssembly() {
        var withRuns = 0
        for seed in 0..<60 as Range<UInt64> {
            var conversation = Conversation(seed: seed)
            let fold = WorkflowRunFold()
            var agents: [SubagentSummary] = []
            for step in 0..<160 {
                switch Int.random(in: 0..<14, using: &conversation.rng) {
                case 0...4: conversation.append()
                case 5...7: conversation.growLast()
                case 8: conversation.growSomewhere()
                case 9: conversation.drop()
                case 10: conversation.swap()
                case 11: conversation.truncate()
                case 12: conversation.refetch()
                default:
                    agents = Self.agents(
                        &conversation.rng, at: Date(timeIntervalSince1970: 1_780_000_000))
                }
                let folded = fold.runs(messages: conversation.messages, agents: agents)
                let expected = WorkflowRunAssembly.runs(
                    messages: conversation.messages, agents: agents)
                #expect(folded == expected, "seed \(seed) step \(step)")
                #expect(
                    fold.runs(messages: conversation.messages, agents: agents) == expected,
                    "seed \(seed) step \(step) asked twice")
                if !expected.isEmpty { withRuns += 1 }
            }
        }
        #expect(withRuns > 1000)
    }

    @Test("A message memo reads a message again only when it is not the message it read")
    func memoReadsOnlyWhatChanged() {
        var conversation = Conversation(seed: 7)
        for _ in 0..<40 { conversation.append() }
        var memo = MessageMemo<Int>()
        var reads = 0
        func refresh() -> MessageMemo<Int>.Change {
            memo.refresh(conversation.messages) { _ in
                reads += 1
                return reads
            }
        }

        #expect(refresh() == .resized)
        #expect(reads == 40)

        #expect(refresh() == .none)
        #expect(reads == 40)

        conversation.growLast()
        #expect(refresh() == .readings)
        #expect(reads == 41)

        conversation.append()
        #expect(refresh() == .resized)
        #expect(reads == 42)

        conversation.refetch()
        #expect(refresh() == .none)
        #expect(reads == 42)

        conversation.messages.swapAt(3, 9)
        #expect(refresh() == .reordered)
        #expect(reads == 42)

        conversation.messages.remove(at: 5)
        #expect(refresh() == .reordered)
        #expect(reads == 42)
        #expect(memo.count == conversation.messages.count)
    }

    @Test("The spend a transcript has run up, folded a prompt at a time, is the spend folded whole")
    func settledTurnsMatchTheWholeFold() {
        for seed in 0..<60 as Range<UInt64> {
            var conversation = Conversation(seed: seed &+ 1000)
            var settled = SettledTurns()
            for step in 0..<160 {
                switch Int.random(in: 0..<13, using: &conversation.rng) {
                case 0...5: conversation.append()
                case 6...8: conversation.growLast()
                case 9: conversation.growSomewhere(after: conversation.firstOpenIndex)
                case 10: conversation.drop()
                case 11: conversation.swap(after: conversation.firstOpenIndex)
                default:
                    if Bool.random(using: &conversation.rng) {
                        conversation.truncate()
                    } else {
                        conversation.refetch()
                    }
                }
                let folded = settled.turns(of: conversation.messages)
                let expected = SessionSpend.fold(conversation.messages[...])
                #expect(folded == expected, "seed \(seed) step \(step)")
            }
        }
    }

    @Test("A reading kept between states shows the same spend as one made from the whole transcript")
    func spendReadingMatchesTheSpendOfTheWholeTranscript() {
        for seed in 0..<30 as Range<UInt64> {
            var conversation = Conversation(seed: seed &+ 2000)
            var reading = SpendReading()
            for step in 0..<120 {
                if Int.random(in: 0..<8, using: &conversation.rng) == 0 {
                    conversation.truncate()
                } else {
                    conversation.append()
                }
                reading.note(messages: conversation.messages, for: "chat")
                let expected = SessionSpend(messages: conversation.messages)
                if let expected {
                    #expect(reading.value == expected, "seed \(seed) step \(step)")
                }
            }
        }
    }

    @Test("The prompts counted by adding to a tally are the prompts counted again")
    func tallyMatchesACount() {
        for seed in 0..<60 as Range<UInt64> {
            var conversation = Conversation(seed: seed &+ 3000)
            var tally = UserMessageTally()
            for step in 0..<160 {
                switch Int.random(in: 0..<12, using: &conversation.rng) {
                case 0...5: conversation.append()
                case 6, 7: conversation.growLast()
                case 8: conversation.drop()
                case 9: conversation.truncate()
                case 10: conversation.swap()
                default: conversation.refetch()
                }
                let counted = tally.users(in: conversation.messages)
                let expected = conversation.messages.count { $0.role == .user }
                if !conversation.messages.isEmpty {
                    #expect(counted == expected, "seed \(seed) step \(step)")
                }
            }
        }
    }
}

@Suite("One walk back through a turn answers what four walks did")
struct TurnScanTests {
    private static func referenceTurnStart(_ state: ConversationState) -> Date? {
        guard state.status == .running || state.compaction?.isRunning == true else { return nil }
        var opener: ChatMessage?
        for message in state.messages.reversed() {
            if message.role == .assistant, isSettled(message, before: opener) { break }
            if message.role == .user { opener = message }
        }
        return (opener ?? state.messages.last(where: { $0.role == .user }))?.createdAt
    }

    private static func isSettled(_ message: ChatMessage, before later: ChatMessage?) -> Bool {
        if message.completedAt != nil { return true }
        return !message.isStreaming && later != nil
    }

    private static func referenceRunningTool(_ state: ConversationState) -> String? {
        for message in state.messages.reversed() {
            for part in message.parts.reversed() {
                if case .tool(let call) = part.kind, call.status == .running { return call.name }
            }
            if message.role == .user { break }
        }
        return nil
    }

    private static func referenceInFlight(_ state: ConversationState) -> ActivityKind? {
        if state.compaction?.isRunning == true { return .compacting }
        if !state.pendingPermissions.isEmpty { return .needsApproval }
        if !state.pendingQuestions.isEmpty { return .needsAnswer }
        guard state.status == .running else { return nil }
        if let retry = state.retry { return .retrying(attempt: retry.attempt) }
        var running: ToolCall?
        search: for message in state.messages.reversed() {
            for part in message.parts.reversed() {
                if case .tool(let call) = part.kind, call.status == .running {
                    running = call
                    break search
                }
            }
            if message.role == .user { break }
        }
        if let call = running { return .usingTool(name: call.name, kind: call.summaryKind) }
        if let last = state.messages.last, last.role == .assistant, last.completedAt == nil,
            case .text(let text)? = last.parts.last?.kind, !text.isEmpty
        {
            return .writing
        }
        return .thinking
    }

    @Test("Turn start, running tool, last prompt and activity match the walks they replace")
    func scanMatchesReferences() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        for seed in 0..<80 as Range<UInt64> {
            var conversation = Conversation(seed: seed &+ 4000)
            for step in 0..<120 {
                switch Int.random(in: 0..<10, using: &conversation.rng) {
                case 0...5: conversation.append()
                case 6...8: conversation.growLast()
                default: conversation.growSomewhere()
                }
                var state = ConversationState(
                    messages: conversation.messages,
                    status: [.running, .idle, .running].randomElement(using: &conversation.rng)
                        ?? .idle,
                    connection: .live)
                if Int.random(in: 0..<10, using: &conversation.rng) == 0 {
                    state.retry = TurnRetry(attempt: 2, reason: "slow")
                }
                let facts = StatusFacts.from(
                    state: state, agents: [], usage: nil, attachments: 0, now: now)
                let label = "seed \(seed) step \(step)"
                #expect(StatusFacts.turnStart(in: state) == Self.referenceTurnStart(state), "\(label)")
                #expect(facts.runningTool == Self.referenceRunningTool(state), "\(label)")
                #expect(
                    facts.lastPromptAt == state.messages.last(where: { $0.role == .user })?.createdAt,
                    "\(label)")
                #expect(ActivityKind.inFlight(in: state) == Self.referenceInFlight(state), "\(label)")
                let elapsed = Self.referenceTurnStart(state).map { max(0, now.timeIntervalSince($0)) }
                #expect(facts.elapsed == elapsed, "\(label)")
            }
        }
    }
}
