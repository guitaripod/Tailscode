import CodingAgentKit
import Foundation

/// What the conversation knows about a turn that the transcript alone cannot say. Every set holds
/// identities a client already has, and each is matched against a call's own id, its part's id or
/// the step's `"messageID:partID"`, so a client passes whichever it holds.
public struct NeuralAwaiting: Sendable, Hashable {
    /// Calls stopped on a permission the person has not answered.
    public var approvals: Set<String>
    /// Calls that put a question to the person and wait for the reply.
    public var answers: Set<String>
    /// Calls the machine found stuck.
    public var stalled: Set<String>
    /// Turns, or messages of a turn, the machine cut off rather than the person or the model.
    public var interrupted: Set<String>

    public static let none = NeuralAwaiting()

    public init(
        approvals: Set<String> = [], answers: Set<String> = [], stalled: Set<String> = [],
        interrupted: Set<String> = []
    ) {
        self.approvals = approvals
        self.answers = answers
        self.stalled = stalled
        self.interrupted = interrupted
    }

    var isEmpty: Bool {
        approvals.isEmpty && answers.isEmpty && stalled.isEmpty && interrupted.isEmpty
    }
}

/// Reads a conversation into brains: one turn per run of assistant messages, each turn's work as
/// steps and its final words as the answer. The walk is one pass over the parts and reads a tool
/// call by its name and its input only, never its summary, because a transcript is rebuilt for
/// every token that streams in.
public enum NeuralTurns {
    /// Splits `messages` into turns and reads each one. A turn with nothing to draw (an answer and
    /// no work) is still returned, with no steps; the client draws a brain only for one that has
    /// steps. `running` says the conversation is mid-turn, which is true of the last turn only.
    public static func partition(
        messages: [ChatMessage], running: Bool, awaiting: NeuralAwaiting = .none
    ) -> [NeuralTurn] {
        var turns: [[ChatMessage]] = []
        var current: [ChatMessage] = []
        var seen = Set<String>()
        for message in messages {
            guard seen.insert(message.id).inserted else { continue }
            switch message.role {
            case .user:
                if !current.isEmpty {
                    turns.append(current)
                    current = []
                }
            case .assistant:
                current.append(message)
            case .system:
                if !current.isEmpty { current.append(message) }
            }
        }
        if !current.isEmpty { turns.append(current) }
        let last = turns.count - 1
        return turns.enumerated().map { index, turn in
            read(turn, running: running && index == last, awaiting: awaiting)
        }
    }

    static let maxOutputLines = 4
    static let maxOutputLineLength = 160
    static let maxDetailLength = 300

    private static let thinkingTitle = Localized.text("Thinking")
    private static let saidTitle = Localized.text("Said")

    private static let haltedByHand: Set<String> = [
        "abort", "aborted", "cancel", "cancelled", "canceled", "interrupt", "interrupted",
        "stop-by-user",
    ]

    /// One message read on its own: what each of its parts is, before the turn it belongs to says
    /// which of its words are the answer. A message that has not changed has the same reading, so a
    /// turn that grows by one message reads that message and assembles the rest.
    struct MessageReading {
        enum Kind { case reasoning, tool, text }

        struct Item {
            /// The step as read; its index and group are set when the turn is assembled.
            var step: NeuralStep
            let kind: Kind
            /// Whether the step is one of the parts the brain consumes.
            let member: Bool
        }

        var items: [Item]
        /// How many of its parts are work rather than words: a call, or a thought with words in it.
        var stepParts: Int
        /// How many parts were looked at.
        var parts: Int
    }

    static func readMessage(_ message: ChatMessage, awaiting: NeuralAwaiting) -> MessageReading {
        var items: [MessageReading.Item] = []
        var stepParts = 0
        for part in message.parts {
            let id = "\(message.id):\(part.id)"
            switch part.kind {
            case .reasoning(let words):
                guard hasWords(words) else { continue }
                stepParts += 1
                items.append(
                    MessageReading.Item(
                        step: NeuralStep(
                            id: id, index: 0, zone: .think, group: 0, messageID: message.id,
                            at: message.createdAt, title: thinkingTitle, text: words),
                        kind: .reasoning, member: true))
            case .tool(let call):
                stepParts += 1
                let step = toolStep(
                    call, part: part, id: id, index: 0, group: 0, message: message,
                    awaiting: awaiting)
                items.append(MessageReading.Item(step: step, kind: .tool, member: !step.isCard))
            case .text(let words):
                guard hasWords(words) else { continue }
                items.append(
                    MessageReading.Item(
                        step: NeuralStep(
                            id: id, index: 0, zone: .say, group: 0, messageID: message.id,
                            at: message.createdAt, title: saidTitle, text: words),
                        kind: .text, member: true))
            case .file, .compaction, .note, .unknown:
                continue
            }
        }
        return MessageReading(items: items, stepParts: stepParts, parts: message.parts.count)
    }

    /// Puts a turn together from its messages and their readings: which words are the answer, which
    /// parts the brain consumes, and how the turn ended. The same turn however the readings were
    /// come by.
    static func assemble(
        _ messages: [ChatMessage], readings: [MessageReading], running: Bool,
        awaiting: NeuralAwaiting
    ) -> NeuralTurn {
        var totalStepParts = 0
        var count = 0
        for reading in readings {
            totalStepParts += reading.stepParts
            count += reading.items.count
        }
        var steps: [NeuralStep] = []
        steps.reserveCapacity(count)
        var answers: [String] = []
        var members = Set<String>()
        var seenStepParts = 0
        let (shown, trailingBytes) = shownNotes(in: readings)
        let holding = holdsTrailingWords(
            running: running, hasSteps: totalStepParts > 0, bytes: trailingBytes)
        for (group, reading) in readings.enumerated() {
            for item in reading.items {
                switch item.kind {
                case .reasoning, .tool:
                    seenStepParts += 1
                    append(item, group: group, to: &steps, members: &members)
                case .text:
                    if seenStepParts < totalStepParts {
                        append(
                            item, group: group, to: &steps, members: &members,
                            inChat: shown.contains(item.step.id))
                    } else if !holding {
                        answers.append(item.step.id)
                    }
                }
            }
        }
        if running, answers.isEmpty, let tail = steps.last, tail.zone == .think, tail.status == .ok {
            steps[steps.count - 1].status = .running
        }
        markRecovered(&steps)
        regroup(&steps)
        let answersSet = Set(answers)
        let cards = Set(steps.filter(\.isCard).map(\.id))
        for message in messages {
            for part in message.parts {
                let id = "\(message.id):\(part.id)"
                if answersSet.contains(id) || cards.contains(id) || shown.contains(id) { continue }
                if Self.isSeen(part) { continue }
                members.insert(id)
            }
        }
        let total = price(messages, onto: &steps)
        let first = messages[0]
        let last = messages[messages.count - 1]
        let outcome = readOutcome(
            of: messages, hasStoppedStep: steps.contains { $0.status == .stopped }, running: running,
            awaiting: awaiting)
        return NeuralTurn(
            id: first.id, steps: steps, answerPartIDs: answers, memberPartIDs: members,
            memberMessageIDs: Set(messages.map(\.id)),
            outcome: outcome, startedAt: first.createdAt,
            endedAt: outcome == .running ? nil : last.completedAt,
            modelID: messages.reversed().lazy.compactMap(\.modelID).first,
            effort: messages.reversed().lazy.compactMap(\.reasoningEffort).first, costUSD: total)
    }

    /// Sets what each message cost on the first step that arrived in it and answers with the
    /// turn's whole price, the answer's message included; nil when the server priced none of it.
    private static func price(_ messages: [ChatMessage], onto steps: inout [NeuralStep]) -> Double? {
        var total = 0.0
        var priced = false
        var firstStep: [String: Int]?
        for message in messages {
            guard let cost = message.costUSD, cost > 0 else { continue }
            priced = true
            total += cost
            if firstStep == nil {
                var map: [String: Int] = [:]
                for (index, step) in steps.enumerated() where map[step.messageID] == nil { map[step.messageID] = index }
                firstStep = map
            }
            if let index = firstStep?[message.id] { steps[index].costUSD = cost }
        }
        return priced ? total : nil
    }

    /// A picture or file in a turn is something the reader is meant to see: an agent shows a
    /// person a screenshot or a chart by looking at it, so the picture it read mid-turn is the one
    /// its answer then talks about. It keeps its row in the chat, wherever in the turn it arrived,
    /// instead of disappearing into the brain with the step that read it.
    static func isSeen(_ part: MessagePart) -> Bool {
        if case .file = part.kind { return true }
        return false
    }

    /// The most calls one answer of a model makes together. A longer run of calls in one message
    /// is a server having handed several answers over as one, never a fan-out.
    public static let largestFanOut = 8

    /// Gives each step the group it fired in, message by message. Where the wire keeps a model's
    /// answers apart a message is one answer and its calls were made together, which is what a
    /// group has always been. A bridge that hands a whole turn over as one message (Claude
    /// Code's) folds hundreds of answers into it: every call of the turn then read as made at
    /// once, a list drew one bracket down all of them and a replay was over in a second.
    private static func regroup(_ steps: inout [NeuralStep]) {
        var next = 0
        var begin = 0
        while begin < steps.count {
            var end = begin
            while end < steps.count, steps[end].messageID == steps[begin].messageID { end += 1 }
            next = regroup(&steps, in: begin..<end, from: next)
            begin = end
        }
    }

    /// Groups one message's steps from `first` on and answers with the next free group. A
    /// message is several answers when words follow a call in it, because an answer leads with
    /// what it says, or when a run of calls is too long to be a fan-out. Words then begin a
    /// group, a short run of calls after them joins it, and a long run is told as calls made one
    /// after another, which is what it nearly always was.
    private static func regroup(_ steps: inout [NeuralStep], in range: Range<Int>, from first: Int) -> Int {
        var folded = false
        var seenCall = false
        var run = 0
        for index in range {
            if NeuralReading.isTool(steps[index]) {
                seenCall = true
                run += 1
                if run > largestFanOut { folded = true }
            } else {
                if seenCall { folded = true }
                run = 0
            }
        }
        guard folded else {
            for index in range { steps[index].group = first }
            return first + 1
        }
        var group = first - 1
        var afterCall = true
        var index = range.lowerBound
        while index < range.upperBound {
            guard NeuralReading.isTool(steps[index]) else {
                if afterCall { group += 1 }
                afterCall = false
                steps[index].group = group
                index += 1
                continue
            }
            var end = index
            while end < range.upperBound, NeuralReading.isTool(steps[end]) { end += 1 }
            let together = end - index <= largestFanOut
            if afterCall, together { group += 1 }
            for member in index..<end {
                if !together { group += 1 }
                steps[member].group = group
            }
            afterCall = true
            index = end
        }
        return group + 1
    }

    private static func append(
        _ item: MessageReading.Item, group: Int, to steps: inout [NeuralStep],
        members: inout Set<String>, inChat: Bool = false
    ) {
        var step = item.step
        step.index = steps.count
        step.group = group
        step.inChat = inChat
        if item.member, !inChat { members.insert(step.id) }
        steps.append(step)
    }

    /// The notes the chat shows where they were read, and the size of the words after the turn's
    /// last step. Words before a turn's first step are shown at once (nothing holds them), and words
    /// after a step once they outgrow `heldAnswerBytes`; either way a call that follows makes them a
    /// note, and taking a line the person has read back into the brain with nothing in its place is
    /// what reads as output that vanished. Shorter words after a step were held and never shown, so
    /// they go into the brain unseen. A shown note keeps its place only until the agent writes a
    /// newer account of the work (`supersedes(bytes:)`): the chat keeps one account per turn, so
    /// every note before it folds into the brain, where it is still a SAY step.
    static func shownNotes(in readings: [MessageReading]) -> (ids: Set<String>, trailing: Int) {
        var shown = Set<String>()
        var run: [String] = []
        var bytes = 0
        var sawStep = false
        for reading in readings {
            for item in reading.items {
                switch item.kind {
                case .reasoning, .tool:
                    if !run.isEmpty {
                        if supersedes(bytes: bytes) { shown.removeAll(keepingCapacity: true) }
                        if wasShown(bytes: bytes, afterStep: sawStep) { shown.formUnion(run) }
                    }
                    run.removeAll(keepingCapacity: true)
                    bytes = 0
                    sawStep = true
                case .text:
                    run.append(item.step.id)
                    bytes += item.step.text.utf8.count
                }
            }
        }
        if supersedes(bytes: bytes) { shown.removeAll() }
        return (shown, bytes)
    }

    /// Whether a run of words is a newer account of the turn's work than every note before it, so
    /// those notes fold into the brain: words that reach `heldAnswerBytes` are a report or the answer
    /// being written, never a line on the way to the next call. A long turn the harness wakes again
    /// and again writes a fresh report at each wake, and each one restates the last.
    static func supersedes(bytes: Int) -> Bool {
        bytes >= heldAnswerBytes
    }

    /// Whether a run of words that a step followed had reached the chat before that step came:
    /// the opening words always had, later words only past `heldAnswerBytes`.
    static func wasShown(bytes: Int, afterStep: Bool) -> Bool {
        !afterStep || bytes >= heldAnswerBytes
    }

    private static func read(
        _ messages: [ChatMessage], running: Bool, awaiting: NeuralAwaiting
    ) -> NeuralTurn {
        assemble(
            messages, readings: messages.map { readMessage($0, awaiting: awaiting) },
            running: running, awaiting: awaiting)
    }

    /// How many bytes of trailing words a running turn with work behind it keeps out of the answer
    /// until they have grown past it. A note the agent writes before its next call is a line or
    /// two; the words that outgrow this are the answer being written.
    static let heldAnswerBytes = 320

    /// Whether the words after a turn's last step are held back: not the answer yet, and not a step
    /// either, so the chat shows nothing for them and the brain counts nothing for them. Showing
    /// them at once is what put a line in the chat for as long as it took the next call to arrive
    /// and then took it away into the brain. Held words become the answer when they outgrow
    /// `heldAnswerBytes` or the turn ends, and a note when a call follows, and the steps only ever
    /// grow. Words that were shown stay shown when a call follows, until newer words of substance
    /// take their place (`shownNotes`).
    static func holdsTrailingWords(running: Bool, hasSteps: Bool, bytes: Int) -> Bool {
        running && hasSteps && bytes > 0 && bytes < heldAnswerBytes
    }

    static func hasWords(_ text: String) -> Bool {
        text.contains { !$0.isWhitespace }
    }

    static func readOutcome(
        of messages: [ChatMessage], hasStoppedStep: Bool, running: Bool, awaiting: NeuralAwaiting
    ) -> NeuralOutcome {
        if running { return .running }
        let last = messages[messages.count - 1]
        if last.error != nil { return .failed }
        if !awaiting.interrupted.isEmpty,
            messages.contains(where: { awaiting.interrupted.contains($0.id) })
        {
            return .interrupted
        }
        if haltedByHand.contains(last.finishReason?.lowercased() ?? "") || hasStoppedStep {
            return .stopped
        }
        if messages.allSatisfy(\.isAnswerless) { return .answerless }
        return .settled
    }

    private static func toolStep(
        _ call: ToolCall, part: MessagePart, id: String, index: Int, group: Int,
        message: ChatMessage, awaiting: NeuralAwaiting
    ) -> NeuralStep {
        let kind = call.cachedKind
        let (status, mark) = readStatus(of: call, part: part, id: id, awaiting: awaiting)
        var step = NeuralStep(
            id: id, index: index, zone: NeuralZone.zone(for: kind), status: status, group: group,
            messageID: message.id, at: message.createdAt, title: call.name,
            detail: detail(of: call, kind: kind), outputLines: outputLines(of: call), mark: mark,
            isCard: isCard(call, kind: kind, message: message), call: NeuralStepCall(call))
        if kind == .fileEdit || kind == .fileWrite {
            let tally = ToolDiff.tally([call])
            if tally.added > 0 || tally.removed > 0 {
                step.added = tally.added
                step.removed = tally.removed
            }
        }
        if let tie = tie(of: call, kind: kind) {
            step.tieKey = tie.key
            step.tieIsCommand = tie.isCommand
        }
        return step
    }

    private static func readStatus(
        of call: ToolCall, part: MessagePart, id: String, awaiting: NeuralAwaiting
    ) -> (NeuralStatus, Character?) {
        switch call.status {
        case .completed: return (.ok, nil)
        case .error: return (.failed, nil)
        case .stopped: return (.stopped, nil)
        case .pending, .running:
            if !awaiting.isEmpty {
                let names = [call.id, part.id, id]
                if names.contains(where: { awaiting.approvals.contains($0) }) {
                    return (.waitingApproval, "⏸")
                }
                if names.contains(where: { awaiting.answers.contains($0) }) {
                    return (.waitingAnswer, "?")
                }
                if names.contains(where: { awaiting.stalled.contains($0) }) { return (.stalled, nil) }
            }
            return (.running, nil)
        }
    }

    /// Whether the client also draws this call as a card of its own: a subagent, a workflow, the
    /// task board, a question, or the manifest of a design board.
    static func isCard(
        _ call: ToolCall, kind: ToolCallSummary.Kind, message: ChatMessage
    ) -> Bool {
        switch kind {
        case .subagent, .workflow, .question: return true
        case .fileWrite, .fileEdit:
            return DesignReading.sighting(of: call, in: message) != nil
        case .taskTracking: return TaskBoard.isBoardCall(call.name)
        default: return false
        }
    }

    private static func detail(of call: ToolCall, kind: ToolCallSummary.Kind) -> String {
        func field(_ key: String) -> String? {
            guard let value = call.input?[key]?.stringValue, !value.isEmpty else { return nil }
            return value
        }
        func path() -> String? {
            field("file_path") ?? field("filePath") ?? field("path") ?? field("notebook_path")
        }
        let raw: String?
        switch kind {
        case .shell:
            raw = field("command") ?? field("description")
        case .fileRead, .fileEdit, .fileWrite:
            raw = path()
        case .fileSearch:
            let words = [field("pattern") ?? field("query"), field("path")].compactMap { $0 }
            raw = words.isEmpty ? nil : words.joined(separator: " ")
        case .webSearch:
            raw = field("query")
        case .webFetch:
            raw = field("url")
        case .subagent:
            raw = field("description") ?? field("prompt")
        case .workflow:
            raw = field("name") ?? field("script").flatMap(WorkflowMeta.scriptName)
        case .skill:
            raw = [field("skill"), field("args")].compactMap { $0 }.joined(separator: " ")
        case .taskTracking:
            raw = field("subject") ?? field("taskId") ?? field("status")
        case .question:
            raw = firstQuestion(of: call)
        case .other:
            raw = path() ?? field("url") ?? field("query") ?? field("pattern") ?? field("command")
        }
        return oneLine(raw ?? "", limit: maxDetailLength)
    }

    private static func firstQuestion(of call: ToolCall) -> String? {
        guard case .array(let items)? = call.input?["questions"] else {
            return call.input?["question"]?.stringValue
        }
        return items.lazy.compactMap { $0["question"]?.stringValue }.first
    }

    /// The argument folded onto one line: runs of whitespace and line breaks become one space.
    private static func oneLine(_ text: String, limit: Int) -> String {
        var out = ""
        var pendingSpace = false
        var count = 0
        for character in text {
            if character.isWhitespace {
                pendingSpace = !out.isEmpty
                continue
            }
            if pendingSpace {
                out.append(" ")
                count += 1
                pendingSpace = false
            }
            out.append(character)
            count += 1
            if count >= limit { break }
        }
        return out
    }

    /// A command with every run of whitespace folded to one space, compared byte by byte. Two
    /// steps are tied when they ran the same command, and the whole command — a heredoc can be a
    /// script of thousands of lines — was walked a grapheme at a time for every step of the turn on
    /// every streamed token, which was most of what a Live Activity's update cost on an iPhone XS.
    /// Only ASCII whitespace folds; a command differing in some other space is a different command.
    static func collapsed(_ text: String) -> String {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(text.utf8.count)
        var pendingSpace = false
        for byte in text.utf8 {
            switch byte {
            case 0x20, 0x09, 0x0A, 0x0B, 0x0C, 0x0D:
                pendingSpace = !bytes.isEmpty
            default:
                if pendingSpace {
                    bytes.append(0x20)
                    pendingSpace = false
                }
                bytes.append(byte)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func outputLines(of call: ToolCall) -> [String] {
        guard let output = call.output, !output.isEmpty else { return [] }
        var lines: [String] = []
        var cursor = output.startIndex
        while cursor < output.endIndex, lines.count < maxOutputLines {
            let end = output[cursor...].firstIndex(of: "\n") ?? output.endIndex
            let line = output[cursor..<end].trimmingCharacters(in: .whitespacesAndNewlines)
            if !line.isEmpty { lines.append(String(line.prefix(maxOutputLineLength))) }
            cursor = end < output.endIndex ? output.index(after: end) : end
        }
        return lines
    }

    private static func tie(
        of call: ToolCall, kind: ToolCallSummary.Kind
    ) -> (key: String, isCommand: Bool)? {
        switch kind {
        case .shell:
            guard let command = call.input?["command"]?.stringValue else { return nil }
            let key = collapsed(command)
            return key.isEmpty ? nil : (key, true)
        case .fileRead, .fileEdit, .fileWrite:
            guard
                let path = call.input?["file_path"]?.stringValue
                    ?? call.input?["filePath"]?.stringValue ?? call.input?["path"]?.stringValue
                    ?? call.input?["notebook_path"]?.stringValue,
                !path.isEmpty
            else { return nil }
            return (path, false)
        case .fileSearch:
            guard let path = call.input?["path"]?.stringValue, !path.isEmpty else { return nil }
            return (path, false)
        default:
            return nil
        }
    }

    /// A command that failed and was later run again, word for word, and passed: the failure was
    /// part of getting there, and a brain says so rather than wearing it as a wound.
    /// A step that failed and was later done again, word for word, and passed: the failure was
    /// part of getting there, and a brain says so rather than wearing it as a wound. A command
    /// is the same command; a file step is the same tool on the same file.
    private static func markRecovered(_ steps: inout [NeuralStep]) {
        var passedLater = Set<String>()
        for index in steps.indices.reversed() {
            let step = steps[index]
            guard let key = step.tieKey else { continue }
            let identity = step.tieIsCommand ? "c\u{1}" + key : "f\u{1}" + step.title + "\u{1}" + key
            if step.status == .ok {
                passedLater.insert(identity)
            } else if step.status == .failed, passedLater.contains(identity) {
                steps[index].recovered = true
            }
        }
    }
}
