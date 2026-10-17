import CodingAgentKit
import Foundation

/// How one step of a turn stands. A waiting step is the turn stopped for the person; a stalled one
/// is work the machine found stuck.
public enum NeuralStatus: Sendable, Hashable {
    case ok
    case running
    case failed
    case stopped
    case waitingApproval
    case waitingAnswer
    case stalled
}

/// How a turn ended, or that it has not.
public enum NeuralOutcome: Sendable, Hashable {
    case running
    case settled
    case failed
    case stopped
    case interrupted
    case answerless
}

/// One node of the brain: a thought, a tool call, or something the agent said on the way.
public struct NeuralStep: Identifiable, Sendable, Hashable {
    /// `"messageID:partID"`, the part's own identity, so a step survives a rebuild.
    public let id: String
    /// Its place in the turn, from zero.
    public var index: Int
    public var zone: NeuralZone
    public var status: NeuralStatus
    /// The ordinal of the message it arrived in: steps sharing one are calls made together.
    public var group: Int
    public var messageID: String
    public var at: Date?
    /// The tool's name, or "Thinking" or "Said".
    public var title: String
    /// The argument in one line: a command, a path, a pattern.
    public var detail: String
    /// The words of a thought or a note.
    public var text: String
    /// The first lines of what the call printed, at most four.
    public var outputLines: [String]
    public var added: Int?
    public var removed: Int?
    /// The file path or command another step may share.
    public var tieKey: String?
    public var tieIsCommand: Bool
    /// A glyph worn inside a waiting node: a pause for an approval, a question mark.
    public var mark: Character?
    /// A failure a later step retried to success.
    public var recovered: Bool
    /// The call also draws a card of its own (a subagent, a board), which the client keeps.
    public var isCard: Bool

    public init(
        id: String, index: Int, zone: NeuralZone, status: NeuralStatus = .ok, group: Int,
        messageID: String, at: Date? = nil, title: String, detail: String = "", text: String = "",
        outputLines: [String] = [], added: Int? = nil, removed: Int? = nil, tieKey: String? = nil,
        tieIsCommand: Bool = false, mark: Character? = nil, recovered: Bool = false,
        isCard: Bool = false
    ) {
        self.id = id
        self.index = index
        self.zone = zone
        self.status = status
        self.group = group
        self.messageID = messageID
        self.at = at
        self.title = title
        self.detail = detail
        self.text = text
        self.outputLines = outputLines
        self.added = added
        self.removed = removed
        self.tieKey = tieKey
        self.tieIsCommand = tieIsCommand
        self.mark = mark
        self.recovered = recovered
        self.isCard = isCard
    }
}

/// Everything an agent did before its final message, and where its final message is.
public struct NeuralTurn: Identifiable, Sendable, Hashable {
    /// The id of the turn's first assistant message.
    public let id: String
    public var steps: [NeuralStep]
    /// The trailing text parts after the last tool or reasoning part: the answer, never a step.
    public var answerPartIDs: [String]
    /// The parts the brain consumes. A client skips their own rows.
    public var memberPartIDs: Set<String>
    public var outcome: NeuralOutcome
    public var startedAt: Date?
    public var endedAt: Date?
    public var modelID: String?
    public var effort: String?

    public init(
        id: String, steps: [NeuralStep] = [], answerPartIDs: [String] = [],
        memberPartIDs: Set<String> = [], outcome: NeuralOutcome = .settled, startedAt: Date? = nil,
        endedAt: Date? = nil, modelID: String? = nil, effort: String? = nil
    ) {
        self.id = id
        self.steps = steps
        self.answerPartIDs = answerPartIDs
        self.memberPartIDs = memberPartIDs
        self.outcome = outcome
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.modelID = modelID
        self.effort = effort
    }
}

/// The thirteen things the masks light. The order is the shader's.
public enum NeuralChannel: Int, CaseIterable, Sendable {
    case think, sense, act, shell, delegate, say, link, star, seam, eye, rib, ear, visor

    public static let count = 13

    public init(zone: NeuralZone) {
        self = NeuralChannel(rawValue: zone.rawValue) ?? .think
    }
}

public struct NeuralRGB: Sendable, Hashable {
    public var r: Float
    public var g: Float
    public var b: Float

    public init(_ r: Float, _ g: Float, _ b: Float) {
        self.r = r
        self.g = g
        self.b = b
    }
}

/// What a renderer needs to draw one instant of the head: every number a shader reads, computed
/// once in Core so Metal and the CPU compositor cannot disagree.
public struct NeuralFrame: Sendable, Equatable {
    public static let restIntensity: [Float] = [
        0.5, 0.5, 0.5, 0.5, 0.5, 0.5, 0.55, 0.6, 0.3, 0.5, 0.62, 0.15, 0.25,
    ]

    public var intensity: [Float] = NeuralFrame.restIntensity
    public var toneOverride: [NeuralTone?] = Array(repeating: nil, count: NeuralChannel.count)
    public var sweep: Float = 0
    public var sweepAmount: Float = 0
    public var sweepTone: NeuralTone = .quiet
    public var crunch: Float = 0
    /// How many of the five visor bars are lit; the server's choice lights none and sets `hollow`.
    public var effort: Float = 5
    public var hollow: Bool = false
    public var rainbow: Bool = false
    /// How many of the six neck ribs are lit, from the bottom, fractions allowed.
    public var ribs: Float = 0
    /// Whether the fibres carry the outward ripple.
    public var ripple: Float = 0
    /// Where the work is, for the ripple's centre.
    public var active: NeuralPoint?
    /// Whether the head carries the background-work satellite; a settled frame holds it still.
    public var orbit: Bool = false
    /// True when nothing in this frame will change on its own, so no further frame is needed.
    public var settled: Bool = true

    public init() {}
}
