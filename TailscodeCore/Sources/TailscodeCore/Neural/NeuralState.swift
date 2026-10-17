import CodingAgentKit
import Foundation

/// What the whole head does besides lighting a zone.
public enum NeuralEffect: Sendable, Equatable {
    case none
    /// The galaxies draw in while a compaction runs and the ribs drop to what was kept.
    case crunch
    /// A satellite circles the dome while work continues between turns.
    case orbit
    /// The machine is down: zones, seams and eye off.
    case dark
    /// Held back to this level, so a state that is waiting rather than working reads as waiting.
    case dim(Float)
}

/// The head's whole-body state, read from the same ``ActivityKind`` the header, the orb and the
/// rows read, and from how a turn ended where the app has no activity for it. It adds no state
/// the app lacks: stopped, interrupted and answerless have no face and the head stays neutral.
public struct NeuralState: Sendable, Equatable {
    /// A stable key, never shown to a person: the state's name in `docs/neural-trace-states.md`.
    public let label: String
    /// The tone the eye and the lit zone wear. `identity` means the state has none: the eye then
    /// wears who answered and how hard.
    public let tone: NeuralTone
    public let motion: NeuralMotion
    /// The zone that is lit; nil for a state that belongs to the whole head.
    public let zone: NeuralZone?
    public let effect: NeuralEffect
    /// A failed turn: its zone holds danger and the rest steps back to a tenth.
    public let failure: Bool
    /// False for the three endings the app gives no face: stopped, interrupted, answerless.
    public let hasFace: Bool

    public init(
        label: String, tone: NeuralTone, motion: NeuralMotion, zone: NeuralZone? = nil,
        effect: NeuralEffect = .none, failure: Bool = false, hasFace: Bool = true
    ) {
        self.label = label
        self.tone = tone
        self.motion = motion
        self.zone = zone
        self.effect = effect
        self.failure = failure
        self.hasFace = hasFace
    }

    public var wearsIdentity: Bool { tone == .identity }

    /// Whether this state keeps a loop going: a breath, a beat, a sweep, a compaction's crunch or
    /// the background satellite. Reduced motion stops all of them.
    public func isAnimated(reduceMotion: Bool = false) -> Bool {
        guard !reduceMotion else { return false }
        if motion.isAnimated { return true }
        return effect == .crunch || effect == .orbit
    }

    public static let idle = NeuralState(label: "idle", tone: .quiet, motion: .still)
    public static let settled = NeuralState(label: "settled", tone: .identity, motion: .still)
    public static let neutral = NeuralState(
        label: "stopped", tone: .quiet, motion: .still, effect: .dim(0.4), hasFace: false)

    /// The reading, with the zone of a waiting or stalled step where the activity does not name
    /// one. Both nil is a conversation with nothing going on.
    public static func make(
        activity: ActivityKind?, outcome: NeuralOutcome? = nil, waitingZone: NeuralZone? = nil
    ) -> NeuralState {
        if let activity { return state(for: activity, waitingZone: waitingZone) }
        switch outcome {
        case .none: return idle
        case .running:
            return NeuralState(label: "working", tone: .live, motion: .breath)
        case .settled: return settled
        case .failed:
            return failed(zone: waitingZone ?? .shell)
        case .stopped, .interrupted, .answerless: return neutral
        }
    }

    private static func failed(zone: NeuralZone) -> NeuralState {
        NeuralState(label: "failed", tone: .danger, motion: .still, zone: zone, failure: true)
    }

    private static func state(for activity: ActivityKind, waitingZone: NeuralZone?) -> NeuralState {
        switch activity {
        case .working:
            return NeuralState(label: "working", tone: .live, motion: .breath)
        case .thinking:
            return NeuralState(label: "thinking", tone: .live, motion: .breath, zone: .think)
        case .writing:
            return NeuralState(label: "writing", tone: .live, motion: .breath, zone: .say)
        case .usingTool(_, let kind):
            let zone = NeuralZone.zone(for: kind)
            return NeuralState(label: word(for: zone), tone: .live, motion: .breath, zone: zone)
        case .delegating:
            return NeuralState(
                label: "delegating", tone: .live, motion: .breath, zone: .delegate)
        case .inBackground:
            return NeuralState(label: "background", tone: .live, motion: .breath, effect: .orbit)
        case .stalled:
            return NeuralState(
                label: "stalled", tone: .attention, motion: .still, zone: waitingZone ?? .shell)
        case .retrying:
            return NeuralState(label: "retrying", tone: .attention, motion: .sweep)
        case .compacting:
            return NeuralState(
                label: "compacting", tone: .attention, motion: .sweep, effect: .crunch)
        case .needsApproval:
            return NeuralState(
                label: "approval", tone: .attention, motion: .heartbeat,
                zone: waitingZone ?? .shell)
        case .needsAnswer:
            return NeuralState(
                label: "question", tone: .attention, motion: .heartbeat, zone: .think)
        case .queued:
            return NeuralState(label: "queued", tone: .quiet, motion: .still, effect: .dim(0.35))
        case .connecting:
            return NeuralState(
                label: "connecting", tone: .quiet, motion: .sweep, effect: .dim(0.4))
        case .reconnecting:
            return NeuralState(
                label: "reconnecting", tone: .attention, motion: .sweep, effect: .dim(0.4))
        case .failed:
            return failed(zone: waitingZone ?? .shell)
        case .offline:
            return NeuralState(label: "offline", tone: .quiet, motion: .still, effect: .dark)
        }
    }

    private static func word(for zone: NeuralZone) -> String {
        switch zone {
        case .think: return "planning"
        case .sense: return "reading"
        case .act: return "editing"
        case .shell: return "running"
        case .delegate: return "delegating"
        case .say: return "writing"
        }
    }
}
