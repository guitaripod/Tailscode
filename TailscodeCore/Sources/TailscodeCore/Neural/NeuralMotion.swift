import Foundation

/// How the head moves, as pure functions of absolute time. The periods and floors are
/// ``ActivityTuning``'s, and the clock arithmetic is ``ActivityPulse``'s, so the head breathes in
/// time with every badge and row on screen; what is added here is only the head's own wave shape,
/// authored in the browser mock (`hero2.js`, `MOTION`): a breath that sits at its floor at phase
/// zero and a heartbeat made of two gaussian beats rather than two cosine bumps.
public enum NeuralMotion: Sendable, Equatable {
    case breath
    case heartbeat
    case sweep
    case still

    private static let breathPulse = ActivityPulse(
        period: ActivityTuning.breathPeriod, floor: ActivityTuning.breathFloor)
    private static let heartbeatPulse = ActivityPulse(
        period: ActivityTuning.heartbeatPeriod, floor: ActivityTuning.heartbeatFloor, beats: 2)
    private static let sweepClock = ActivityPulse(period: ActivityTuning.sweepPeriod, floor: 0)

    public static let firstBeat = (centre: 0.08, width: 0.045, strength: 1.0)
    public static let secondBeat = (centre: 0.25, width: 0.05, strength: 0.85)

    /// The shared raised cosine, shifted half a period so phase zero is the dimmest point and the
    /// brightest is half a period later, as the mock's `breath` is. Inside `breathFloor...1`.
    public static func breathLevel(at time: TimeInterval) -> Double {
        breathPulse.intensity(at: time + breathPulse.period / 2)
    }

    /// Two beats and a rest: gaussians at phase 0.08 and 0.25, the second at 0.85 strength, over
    /// the floor. Inside `heartbeatFloor...1`.
    public static func heartbeatLevel(at time: TimeInterval) -> Double {
        let phase = heartbeatPulse.phase(at: time)
        let floor = ActivityTuning.heartbeatFloor
        let first = gaussian(phase, firstBeat.centre, firstBeat.width) * firstBeat.strength
        let second = gaussian(phase, secondBeat.centre, secondBeat.width) * secondBeat.strength
        return floor + (1 - floor) * max(first, second)
    }

    /// Where the band is on its crossing, `0..<1`, one cycle every `sweepPeriod`.
    public static func sweepPhase(at time: TimeInterval) -> Double {
        sweepClock.phase(at: time)
    }

    private static func gaussian(_ phase: Double, _ centre: Double, _ width: Double) -> Double {
        let distance = (phase - centre) / width
        return exp(-distance * distance)
    }

    public var isAnimated: Bool { self != .still }

    /// How lit the thing this motion drives is. A sweep and a rest are fully lit, and reduced
    /// motion maps every motion to a rest.
    public func level(at time: TimeInterval, reduceMotion: Bool = false) -> Double {
        guard !reduceMotion else { return 1 }
        switch self {
        case .breath: return Self.breathLevel(at: time)
        case .heartbeat: return Self.heartbeatLevel(at: time)
        case .sweep, .still: return 1
        }
    }

    /// The band's position, held at the start while motion is reduced or the motion is not a sweep.
    public func sweepPhase(at time: TimeInterval, reduceMotion: Bool = false) -> Double {
        guard !reduceMotion, self == .sweep else { return 0 }
        return Self.sweepPhase(at: time)
    }

    public func honoring(reduceMotion: Bool) -> NeuralMotion {
        reduceMotion ? .still : self
    }
}
