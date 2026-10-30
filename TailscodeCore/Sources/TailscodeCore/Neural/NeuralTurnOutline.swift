import CodingAgentKit
import Foundation

/// What a client needs to place a turn's brain among its rows, read without building a single step:
/// whether the turn is a brain, the part its row goes before, the parts the row consumes, how it
/// ended. A transcript asks this of every turn when a chat opens, so it is one pass over the
/// parts that classifies them and builds no detail line, output excerpt or diff tally, and names
/// only the few parts the brain leaves to the client; the steps (`NeuralTurn.steps`) are read only
/// for a turn somebody looks at.
///
/// For every conversation `NeuralTurns.outline(messages:running:awaiting:)` agrees with the turn
/// `NeuralTurns.partition` reads from the same messages on everything they share, and
/// `consumes(_:)` answers `memberPartIDs.contains` for every part of the turn.
public struct NeuralTurnOutline: Sendable, Hashable {
    /// The id of the turn's first assistant message.
    public let id: String
    /// How many steps the turn has. A turn with none is not a brain.
    public let stepCount: Int
    /// The part id (`"messageID:partID"`) the turn's brain row goes before: the first step that is
    /// a member, or the first step where every step is a card the client also draws itself.
    public let anchor: String?
    /// The message that holds the anchor part.
    public let anchorMessageID: String?
    public let answerPartIDs: [String]
    /// The calls the task board is built from; the board card keeps the last and the others are
    /// nodes of the brain.
    public let boardPartIDs: [String]
    /// The parts of the turn's messages the brain does not consume and the client keeps its own
    /// rows for: the answer, the cards, and a file handed back after the answer.
    public let keptPartIDs: Set<String>
    /// The turn's messages, in order.
    public let messageIDs: [String]
    /// How many parts the turn's messages hold.
    public let partCount: Int
    public let outcome: NeuralOutcome
    public let startedAt: Date?
    public let endedAt: Date?
    public let modelID: String?
    public let effort: String?

    public init(
        id: String, stepCount: Int, anchor: String?, anchorMessageID: String?,
        answerPartIDs: [String], boardPartIDs: [String], keptPartIDs: Set<String>,
        messageIDs: [String], partCount: Int, outcome: NeuralOutcome, startedAt: Date?,
        endedAt: Date?, modelID: String?, effort: String?
    ) {
        self.id = id
        self.stepCount = stepCount
        self.anchor = anchor
        self.anchorMessageID = anchorMessageID
        self.answerPartIDs = answerPartIDs
        self.boardPartIDs = boardPartIDs
        self.keptPartIDs = keptPartIDs
        self.messageIDs = messageIDs
        self.partCount = partCount
        self.outcome = outcome
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.modelID = modelID
        self.effort = effort
    }

    /// A turn with at least one step is a brain.
    public var isBrain: Bool { stepCount > 0 }

    /// Whether the brain consumes the part `partID` (`"messageID:partID"`), so the client builds no
    /// row of its own for it. Only a part of this turn's own messages may be asked about: every
    /// part of those messages is consumed except the ones the client keeps.
    public func consumes(_ partID: String) -> Bool { !keptPartIDs.contains(partID) }
}

extension NeuralTurn {
    /// The part this turn's brain row goes before: its first member step, or its first step when
    /// every step is one the client also draws as a card.
    public var anchor: String? { anchorIndex.map { steps[$0].id } }

    private var anchorIndex: Int? {
        steps.indices.first { memberPartIDs.contains(steps[$0].id) } ?? steps.indices.first
    }

    private var boardPartIDs: [String] {
        var found: [String] = []
        for index in steps.indices
        where steps[index].isCard && TaskBoard.isBoardCall(steps[index].title) {
            found.append(steps[index].id)
        }
        return found
    }

    private var cardPartIDs: [String] {
        var found: [String] = []
        for index in steps.indices where steps[index].isCard { found.append(steps[index].id) }
        return found
    }

    /// The outline of a turn read without its messages, for a turn made by hand. Where the messages
    /// are held `NeuralTurns.outline(messages:outcome:)` knows the parts the turn does not name:
    /// this one keeps the answer and the cards, and a file handed back after the answer is not
    /// among them.
    var outline: NeuralTurnOutline {
        let anchored = anchorIndex
        return NeuralTurnOutline(
            id: id, stepCount: steps.count, anchor: anchored.map { steps[$0].id },
            anchorMessageID: anchored.map { steps[$0].messageID },
            answerPartIDs: answerPartIDs, boardPartIDs: boardPartIDs,
            keptPartIDs: Set(answerPartIDs + cardPartIDs), messageIDs: Array(memberMessageIDs),
            partCount: memberPartIDs.count + answerPartIDs.count + cardPartIDs.count,
            outcome: outcome, startedAt: startedAt, endedAt: endedAt, modelID: modelID,
            effort: effort)
    }
}

extension NeuralTurns {
    /// How a part counts toward the turn, found once and read twice.
    private enum Class: UInt8 {
        case other, file, step, card, words
    }

    /// The outline of one turn's messages, in one pass over their parts.
    public static func outline(
        messages: [ChatMessage], running: Bool, awaiting: NeuralAwaiting = .none
    ) -> NeuralTurnOutline {
        outline(messages: messages) { stopped in
            readOutcome(
                of: messages, hasStoppedStep: stopped, running: running, awaiting: awaiting)
        }
    }

    /// The outline of messages whose turn has been read already and so knows how it ended.
    static func outline(messages: [ChatMessage], outcome: NeuralOutcome) -> NeuralTurnOutline {
        outline(messages: messages) { _ in outcome }
    }

    private static func outline(
        messages: [ChatMessage], outcome decide: (_ hasStoppedStep: Bool) -> NeuralOutcome
    ) -> NeuralTurnOutline {
        var classes: [Class] = []
        let partCount = messages.reduce(0) { $0 + $1.parts.count }
        classes.reserveCapacity(partCount)
        var lastStep = -1
        var stopped = false
        var trailingBytes = 0
        for message in messages {
            for part in message.parts {
                let found: Class
                switch part.kind {
                case .reasoning(let words):
                    found = hasWords(words) ? .step : .other
                case .tool(let call):
                    if call.status == .stopped { stopped = true }
                    found = isCard(call, kind: call.cachedKind, message: message) ? .card : .step
                case .text(let words):
                    found = hasWords(words) ? .words : .other
                    if found == .words { trailingBytes += words.utf8.count }
                case .file:
                    found = .file
                case .compaction, .note, .unknown:
                    found = .other
                }
                if found == .step || found == .card {
                    lastStep = classes.count
                    trailingBytes = 0
                }
                classes.append(found)
            }
        }
        let outcome = decide(stopped)
        let holding = holdsTrailingWords(
            running: outcome == .running, hasSteps: lastStep >= 0, bytes: trailingBytes)

        var stepCount = 0
        var firstStep: (id: String, message: String)?
        var firstMember: (id: String, message: String)?
        var answers: [String] = []
        var boards: [String] = []
        var kept = Set<String>()
        var lastAnswer = -1
        var position = 0
        for message in messages {
            for part in message.parts {
                defer { position += 1 }
                let found = classes[position]
                switch found {
                case .step, .card:
                    stepCount += 1
                    if found == .card {
                        let id = partID(message, part)
                        kept.insert(id)
                        if case .tool(let call) = part.kind, TaskBoard.isBoardCall(call.name) {
                            boards.append(id)
                        }
                    }
                    noteStep(found == .card, message, part, &firstStep, &firstMember)
                case .words:
                    if position < lastStep {
                        stepCount += 1
                        noteStep(false, message, part, &firstStep, &firstMember)
                    } else if !holding {
                        let id = partID(message, part)
                        answers.append(id)
                        kept.insert(id)
                        lastAnswer = position
                    }
                case .other, .file:
                    break
                }
            }
        }
        if lastAnswer >= 0 {
            position = 0
            for message in messages {
                for part in message.parts {
                    defer { position += 1 }
                    if classes[position] == .file, position > lastAnswer {
                        kept.insert(partID(message, part))
                    }
                }
            }
        }

        let first = messages[0]
        let last = messages[messages.count - 1]
        return NeuralTurnOutline(
            id: first.id, stepCount: stepCount, anchor: (firstMember ?? firstStep)?.id,
            anchorMessageID: (firstMember ?? firstStep)?.message, answerPartIDs: answers,
            boardPartIDs: boards, keptPartIDs: kept, messageIDs: messages.map(\.id),
            partCount: partCount, outcome: outcome, startedAt: first.createdAt,
            endedAt: outcome == .running ? nil : last.completedAt,
            modelID: messages.reversed().lazy.compactMap(\.modelID).first,
            effort: messages.reversed().lazy.compactMap(\.reasoningEffort).first)
    }

    private static func noteStep(
        _ isCard: Bool, _ message: ChatMessage, _ part: MessagePart,
        _ firstStep: inout (id: String, message: String)?,
        _ firstMember: inout (id: String, message: String)?
    ) {
        guard firstStep == nil || (firstMember == nil && !isCard) else { return }
        let made = (id: partID(message, part), message: message.id)
        if firstStep == nil { firstStep = made }
        if !isCard, firstMember == nil { firstMember = made }
    }

    @inline(__always)
    private static func partID(_ message: ChatMessage, _ part: MessagePart) -> String {
        message.id + ":" + part.id
    }
}
