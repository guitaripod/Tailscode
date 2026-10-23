import CodingAgentKit
import Foundation

/// What a client needs to place a turn's brain among its rows, read without building a single step:
/// whether the turn is a brain, the part its row goes before, the parts the row consumes, how it
/// ended. A transcript asks this of every turn when a chat opens, so it is one pass over the
/// parts that classifies them and builds no detail line, output excerpt or diff tally; the steps
/// (`NeuralTurn.steps`) are read only for a turn somebody looks at.
///
/// For every conversation `NeuralTurns.outline(messages:running:awaiting:)` equals the outline of
/// the turn `NeuralTurns.partition` reads from the same messages.
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
    public let memberPartIDs: Set<String>
    public let memberMessageIDs: Set<String>
    public let outcome: NeuralOutcome
    public let startedAt: Date?
    public let endedAt: Date?
    public let modelID: String?
    public let effort: String?

    public init(
        id: String, stepCount: Int, anchor: String?, anchorMessageID: String?,
        answerPartIDs: [String], memberPartIDs: Set<String>, memberMessageIDs: Set<String>,
        outcome: NeuralOutcome, startedAt: Date?, endedAt: Date?, modelID: String?,
        effort: String?
    ) {
        self.id = id
        self.stepCount = stepCount
        self.anchor = anchor
        self.anchorMessageID = anchorMessageID
        self.answerPartIDs = answerPartIDs
        self.memberPartIDs = memberPartIDs
        self.memberMessageIDs = memberMessageIDs
        self.outcome = outcome
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.modelID = modelID
        self.effort = effort
    }

    /// A turn with at least one step is a brain.
    public var isBrain: Bool { stepCount > 0 }
}

extension NeuralTurn {
    /// The part this turn's brain row goes before: its first member step, or its first step when
    /// every step is one the client also draws as a card.
    public var anchor: String? { anchorStep?.id }

    private var anchorStep: NeuralStep? {
        steps.first { memberPartIDs.contains($0.id) } ?? steps.first
    }

    public var outline: NeuralTurnOutline {
        NeuralTurnOutline(
            id: id, stepCount: steps.count, anchor: anchor, anchorMessageID: anchorStep?.messageID,
            answerPartIDs: answerPartIDs,
            memberPartIDs: memberPartIDs, memberMessageIDs: memberMessageIDs, outcome: outcome,
            startedAt: startedAt, endedAt: endedAt, modelID: modelID, effort: effort)
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
        var classes: [Class] = []
        classes.reserveCapacity(messages.reduce(0) { $0 + $1.parts.count })
        var lastStep = -1
        var stopped = false
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
                case .file:
                    found = .file
                case .compaction, .note, .unknown:
                    found = .other
                }
                if found == .step || found == .card { lastStep = classes.count }
                classes.append(found)
            }
        }

        var stepCount = 0
        var firstStep: (id: String, message: String)?
        var firstMember: (id: String, message: String)?
        var answers: [String] = []
        var lastAnswer = -1
        var position = 0
        for message in messages {
            for part in message.parts {
                defer { position += 1 }
                let found = classes[position]
                let isStep: Bool
                switch found {
                case .step, .card: isStep = true
                case .words: isStep = position < lastStep
                case .other, .file: isStep = false
                }
                if isStep {
                    stepCount += 1
                    if firstStep == nil || (firstMember == nil && found != .card) {
                        let made = (id: partID(message, part), message: message.id)
                        if firstStep == nil { firstStep = made }
                        if found != .card, firstMember == nil { firstMember = made }
                    }
                } else if found == .words {
                    answers.append(partID(message, part))
                    lastAnswer = position
                }
            }
        }

        var members = Set<String>()
        members.reserveCapacity(classes.count)
        position = 0
        for message in messages {
            for part in message.parts {
                defer { position += 1 }
                switch classes[position] {
                case .card: continue
                case .words: if position > lastStep { continue }
                case .file: if position > lastAnswer, lastAnswer >= 0 { continue }
                case .step, .other: break
                }
                members.insert(partID(message, part))
            }
        }

        let first = messages[0]
        let last = messages[messages.count - 1]
        let outcome = readOutcome(
            of: messages, hasStoppedStep: stopped, running: running, awaiting: awaiting)
        return NeuralTurnOutline(
            id: first.id, stepCount: stepCount, anchor: (firstMember ?? firstStep)?.id,
            anchorMessageID: (firstMember ?? firstStep)?.message, answerPartIDs: answers, memberPartIDs: members,
            memberMessageIDs: Set(messages.map(\.id)), outcome: outcome,
            startedAt: first.createdAt, endedAt: outcome == .running ? nil : last.completedAt,
            modelID: messages.reversed().lazy.compactMap(\.modelID).first,
            effort: messages.reversed().lazy.compactMap(\.reasoningEffort).first)
    }

    @inline(__always)
    private static func partID(_ message: ChatMessage, _ part: MessagePart) -> String {
        message.id + ":" + part.id
    }
}
