import CodingAgentKit
import Foundation

/// Whether the call's socket is up, in the three words the face needs.
public enum VoiceCallConnection: Sendable, Equatable {
    case connecting
    case live
    case reconnecting
    case ended
}

/// The one picture of a call, the same on every desk. It is the gateway's phase, whether the agent
/// is busy and whether the line is up, read down to seven faces that wear the vocabulary the rest
/// of the app speaks: connecting sweeps, listening and working breathe, hearing is lit steady,
/// and degraded and ended hold perfectly still. `speaking`, which breathes with a voice's level, is
/// kept for a model that talks again; the session never reads it while the call is ear only.
public enum VoiceCallFace: Sendable, Equatable {
    case connecting
    case listening
    case hearing
    case speaking
    case working
    case degraded(VoiceDegradedReason)
    case ended

    public static let everyFace: [VoiceCallFace] = [
        .connecting, .listening, .hearing, .speaking, .working, .degraded(.engineError), .ended,
    ]

    /// `working` is listening while the agent is busy: the call is still open to the person and the
    /// agent is building, and the chat's own status line keeps the finer word.
    public static func read(
        phase: VoicePhase, agentBusy: Bool, connection: VoiceCallConnection,
        degraded: VoiceDegradedReason? = nil
    ) -> VoiceCallFace {
        switch connection {
        case .ended: return .ended
        case .connecting, .reconnecting: return .connecting
        case .live: break
        }
        switch phase {
        case .connecting: return .connecting
        case .listening: return agentBusy ? .working : .listening
        case .hearing: return .hearing
        case .speaking: return .speaking
        case .degraded: return .degraded(degraded ?? .engineError)
        }
    }

    public var icon: ActivityIcon {
        switch self {
        case .connecting:
            return ActivityKind.connecting.icon
        case .listening:
            return ActivityIcon(
                symbol: "mic.fill", glyph: "◉", tone: .live, motion: .breath(Self.listeningPulse))
        case .hearing:
            return ActivityIcon(symbol: "waveform", glyph: "▮", tone: .live, motion: .still)
        case .speaking:
            return ActivityIcon(
                symbol: "speaker.wave.2.fill", glyph: "♪", tone: .live, motion: .working)
        case .working:
            return ActivityIcon(symbol: "gearshape.fill", glyph: "●", tone: .live, motion: .working)
        case .degraded:
            return ActivityIcon(
                symbol: "exclamationmark.triangle", glyph: "⚠", tone: .danger, motion: .still)
        case .ended:
            return ActivityIcon(symbol: "phone.down.fill", glyph: "■", tone: .quiet, motion: .still)
        }
    }

    public var symbol: String { icon.symbol }
    public var glyph: String { icon.glyph }
    public var tone: ActivityTone { icon.tone }
    public var motion: ActivityMotion { icon.motion }

    public var isOpen: Bool { self != .ended }

    public var word: String { VoiceCallReading.word(for: self) }

    public var spoken: String { VoiceCallReading.spoken(for: self) }

    /// The slow swell of a call that is waiting for the person, slower than work so the two read
    /// as different states when they sit side by side.
    public static let listeningPulse = ActivityPulse(period: 3.2, floor: 0.5)

    /// How lit the face is at an instant. Speaking breathes with the voice: the swell is the floor
    /// and the level lifts it, so a quiet word still moves and a loud one visibly leans in.
    /// Reduced motion keeps the steady light and nothing else.
    public func intensity(at time: TimeInterval, level: Double = 0, reduceMotion: Bool = false) -> Double {
        guard !reduceMotion else { return 1 }
        guard case .speaking = self else { return motion.intensity(at: time) }
        let swell = ActivityMotion.working.intensity(at: time)
        let lean = min(max(level, 0), 1)
        let blend = 0.35 * swell + 0.65 * lean
        return ActivityTuning.breathFloor + (1 - ActivityTuning.breathFloor) * min(blend, 1)
    }
}
