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
                continue
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

    private static func read(
        _ messages: [ChatMessage], running: Bool, awaiting: NeuralAwaiting
    ) -> NeuralTurn {
        let totalStepParts = countStepParts(in: messages)
        var steps: [NeuralStep] = []
        var answers: [String] = []
        var members = Set<String>()
        var seenStepParts = 0
        for (group, message) in messages.enumerated() {
            for part in message.parts {
                let id = "\(message.id):\(part.id)"
                switch part.kind {
                case .reasoning(let words):
                    guard hasWords(words) else { continue }
                    seenStepParts += 1
                    members.insert(id)
                    steps.append(
                        NeuralStep(
                            id: id, index: steps.count, zone: .think, group: group,
                            messageID: message.id, at: message.createdAt, title: thinkingTitle,
                            text: words))
                case .tool(let call):
                    seenStepParts += 1
                    let step = toolStep(
                        call, part: part, id: id, index: steps.count, group: group,
                        message: message, awaiting: awaiting)
                    if !step.isCard { members.insert(id) }
                    steps.append(step)
                case .text(let words):
                    guard hasWords(words) else { continue }
                    if seenStepParts < totalStepParts {
                        members.insert(id)
                        steps.append(
                            NeuralStep(
                                id: id, index: steps.count, zone: .say, group: group,
                                messageID: message.id, at: message.createdAt, title: saidTitle,
                                text: words))
                    } else {
                        answers.append(id)
                    }
                case .file, .compaction, .note, .unknown:
                    continue
                }
            }
        }
        if running, answers.isEmpty, let tail = steps.last, tail.zone == .think {
            steps[steps.count - 1].status = .running
        }
        markRecovered(&steps)
        let first = messages[0]
        let last = messages[messages.count - 1]
        let outcome = readOutcome(
            of: messages, steps: steps, answers: answers, running: running, awaiting: awaiting)
        return NeuralTurn(
            id: first.id, steps: steps, answerPartIDs: answers, memberPartIDs: members,
            outcome: outcome, startedAt: first.createdAt,
            endedAt: outcome == .running ? nil : last.completedAt,
            modelID: messages.reversed().lazy.compactMap(\.modelID).first,
            effort: messages.reversed().lazy.compactMap(\.reasoningEffort).first)
    }

    /// How many parts of the turn are work rather than words: a call, or a thought with words in it.
    private static func countStepParts(in messages: [ChatMessage]) -> Int {
        var count = 0
        for message in messages {
            for part in message.parts {
                switch part.kind {
                case .tool: count += 1
                case .reasoning(let words): if hasWords(words) { count += 1 }
                default: continue
                }
            }
        }
        return count
    }

    private static func hasWords(_ text: String) -> Bool {
        text.contains { !$0.isWhitespace }
    }

    private static func readOutcome(
        of messages: [ChatMessage], steps: [NeuralStep], answers: [String], running: Bool,
        awaiting: NeuralAwaiting
    ) -> NeuralOutcome {
        if running { return .running }
        let last = messages[messages.count - 1]
        if last.error != nil { return .failed }
        if !awaiting.interrupted.isEmpty,
            messages.contains(where: { awaiting.interrupted.contains($0.id) })
        {
            return .interrupted
        }
        if haltedByHand.contains(last.finishReason?.lowercased() ?? "")
            || steps.contains(where: { $0.status == .stopped })
        {
            return .stopped
        }
        if messages.allSatisfy(\.isAnswerless) { return .answerless }
        return .settled
    }

    private static func toolStep(
        _ call: ToolCall, part: MessagePart, id: String, index: Int, group: Int,
        message: ChatMessage, awaiting: NeuralAwaiting
    ) -> NeuralStep {
        let kind = call.summaryKind
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
    private static func isCard(
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
            raw = field("name") ?? field("script")
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
            let key = oneLine(command, limit: Int.max)
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
    private static func markRecovered(_ steps: inout [NeuralStep]) {
        var passedLater = Set<String>()
        for index in steps.indices.reversed() {
            let step = steps[index]
            guard step.tieIsCommand, let key = step.tieKey else { continue }
            if step.status == .ok {
                passedLater.insert(key)
            } else if step.status == .failed, passedLater.contains(key) {
                steps[index].recovered = true
            }
        }
    }
}
