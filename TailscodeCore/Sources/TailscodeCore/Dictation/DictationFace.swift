import Foundation

/// The one picture of dictation, the same on every desk: what the microphone control looks like,
/// whether the box's edge is lit, and whether the control is the live capsule with its bars. Motion
/// means the microphone is open; everything else holds still.
public enum DictationFace: Sendable, Equatable {
    case hidden
    case ready
    case needsModel
    case preparing(Double?)
    case blocked(DictationProblem)
    case waking
    case listening(DictationMode, DictationArm)
    case settling

    /// Read from what the engine can do and what the take is doing. A take in progress always wins:
    /// a microphone that is open is shown open whatever else is true.
    public static func read(readiness: DictationReadiness?, snapshot: DictationSnapshot, available: Bool = true)
        -> DictationFace
    {
        switch snapshot.phase {
        case .waking: return snapshot.mode == .held ? .listening(.held, snapshot.arm) : .waking
        case .listening: return .listening(snapshot.mode, snapshot.arm)
        case .settling: return .settling
        case .idle: break
        }
        guard available, let readiness else { return available ? .ready : .hidden }
        switch readiness {
        case .ready: return .ready
        case .needsDownload: return .needsModel
        case .downloading(let progress): return .preparing(progress)
        case .unavailable(let problem): return .blocked(problem)
        }
    }

    /// The SF Symbol an Apple client draws when the control is a glyph.
    public var symbol: String {
        switch self {
        case .blocked: return "mic.slash"
        default: return "mic"
        }
    }

    /// A small download mark on the glyph: the first press fetches what the engine needs.
    public var wearsDownloadBadge: Bool { self == .needsModel }

    /// The GTK icon name for the same.
    public var iconName: String {
        switch self {
        case .blocked: return "microphone-disabled-symbolic"
        default: return "audio-input-microphone-symbolic"
        }
    }

    public var isOpen: Bool {
        switch self {
        case .waking, .listening: return true
        default: return false
        }
    }

    /// The control is the capsule with level bars: from the touch until the last word settles.
    public var showsBars: Bool {
        switch self {
        case .waking, .listening, .settling: return true
        default: return false
        }
    }

    /// The box wears the lit edge.
    public var litEdge: Bool { isOpen }

    public var tone: ActivityTone {
        switch self {
        case .listening(_, .cancel): return .danger
        case .blocked: return .attention
        case .waking, .listening, .preparing: return .live
        default: return .quiet
        }
    }

    public var motion: ActivityMotion {
        switch self {
        case .waking: return .turning
        case .listening(_, .none): return .working
        default: return .still
        }
    }

    public var progress: Double? {
        if case .preparing(let value) = self { return value }
        return nil
    }

    public var isPreparing: Bool {
        if case .preparing = self { return true }
        return false
    }

    public var isEnabled: Bool { self != .hidden }

    /// A press here opens the microphone; anything else it opens is the sheet or popover that says
    /// what stands in the way.
    public var isTakeable: Bool {
        switch self {
        case .ready, .waking, .listening, .settling: return true
        case .hidden, .needsModel, .preparing, .blocked: return false
        }
    }
}

/// The level bars, the same five on every desk: each bar's height in `0...1` from the smoothed
/// voice level and a phase that walks along them, so a steady voice still reads as alive and
/// silence settles to a low even row.
public enum DictationBars {
    public static let count = 5
    public static let floor = 0.18
    private static let shape: [Double] = [0.55, 0.85, 1.0, 0.75, 0.45]

    public static func heights(level: Double, time: TimeInterval, reduceMotion: Bool = false) -> [Double] {
        let clamped = min(max(level.isFinite ? level : 0, 0), 1)
        return (0..<count).map { index in
            let wobble = reduceMotion ? 1 : 0.78 + 0.22 * sin(time * 9 + Double(index) * 1.3)
            let height = floor + (1 - floor) * clamped * shape[index] * wobble
            return min(1, max(floor, height))
        }
    }

    /// How far the edge is lit, from the smoothed level.
    public static func edgeOpacity(level: Double) -> Double {
        0.45 + 0.55 * min(max(level.isFinite ? level : 0, 0), 1)
    }
}
