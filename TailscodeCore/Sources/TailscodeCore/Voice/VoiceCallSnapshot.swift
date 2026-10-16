import CodingAgentKit
import Foundation

public struct VoiceCallLine: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable, Equatable {
        case you
        case voice
    }

    public let id: String
    public let kind: Kind
    public var text: String
    public var final: Bool

    public init(id: String, kind: Kind, text: String, final: Bool) {
        self.id = id
        self.kind = kind
        self.text = text
        self.final = final
    }
}

public struct VoiceCallDegradation: Sendable, Equatable {
    public let reason: VoiceDegradedReason
    public let recovering: Bool

    public init(reason: VoiceDegradedReason, recovering: Bool) {
        self.reason = reason
        self.recovering = recovering
    }

    public var line: String { VoiceCallReading.degraded(reason, recovering: recovering) }
}

public enum VoiceCallEnd: Sendable, Equatable {
    case hungUp
    case replaced
    case lost
    case couldNotConnect(String)
    case microphoneDenied
    case audioUnavailable(String)
    case gateway(code: String, message: String)
}

/// Everything a client draws of a call at one instant. The stream of these is latest-wins, so a
/// slow screen skips frames and never falls behind; `finishedChimes` is a counter for that reason,
/// a client plays its sound whenever the number it last saw is lower than this one.
public struct VoiceCallSnapshot: Sendable, Equatable {
    public static let lineLimit = 6

    public var face: VoiceCallFace
    public var lines: [VoiceCallLine]
    public var startedAt: Date?
    public var degraded: VoiceCallDegradation?
    public var reconnecting: Bool
    public var muted: Bool
    public var agentBusy: Bool
    public var finishedChimes: Int
    public var end: VoiceCallEnd?
    public var endLine: String?
    public var engine: VoiceEngineState?
    public var engineProgress: Double?

    public init(
        face: VoiceCallFace = .connecting, lines: [VoiceCallLine] = [], startedAt: Date? = nil,
        degraded: VoiceCallDegradation? = nil, reconnecting: Bool = false, muted: Bool = false,
        agentBusy: Bool = false, finishedChimes: Int = 0, end: VoiceCallEnd? = nil,
        endLine: String? = nil, engine: VoiceEngineState? = nil, engineProgress: Double? = nil
    ) {
        self.face = face
        self.lines = lines
        self.startedAt = startedAt
        self.degraded = degraded
        self.reconnecting = reconnecting
        self.muted = muted
        self.agentBusy = agentBusy
        self.finishedChimes = finishedChimes
        self.end = end
        self.endLine = endLine
        self.engine = engine
        self.engineProgress = engineProgress
    }

    /// Whether the call is connecting only because the gateway is bringing its voice model up, which
    /// is the one wait of a call that takes minutes and deserves its own words.
    public var isStartingEngine: Bool {
        guard face == .connecting, !reconnecting, end == nil else { return false }
        return engine == .loading || engine == .stopped
    }

    /// The face's word, except while the line is being redialled, which the face cannot say, and
    /// while the voice model is being started, which it can say with how far it has got.
    public var word: String {
        if reconnecting { return VoiceCallReading.reconnecting }
        if isStartingEngine { return VoiceCallReading.startingTheModel(progress: engineProgress) }
        return face.word
    }

    public var spoken: String {
        if reconnecting { return VoiceCallReading.reconnecting }
        if isStartingEngine { return VoiceCallReading.startingTheModelSpoken }
        return face.spoken
    }

    public var isOpen: Bool { end == nil }
}
