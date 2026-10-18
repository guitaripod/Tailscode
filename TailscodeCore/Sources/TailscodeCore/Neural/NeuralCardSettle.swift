import Foundation

/// A running card ending, as one 400 ms move: the lights and the head cross-fade to their settled
/// strengths on an ease-out cubic, the live headline leaves in 170 ms lifting 6 points while the
/// settled one arrives from 130 to 360 ms rising 6 points, the NOW line and its output are gone by
/// 140 ms, the agent's first words fade in from 170 ms, and the edge stops pulsing at once and
/// holds at full. At 200 ms the card has already said everything it will say; the rest is the
/// picture catching up, which is what makes it read as the end of a sentence rather than a swap.
///
/// A card that settles off screen is simply settled when it arrives (`settled`), and reduced
/// motion lands at once.
public struct NeuralCardSettle: Sendable, Equatable {
    public static let duration: TimeInterval = 0.400
    public static let liveHeadlineOutMs = 170.0
    public static let settledHeadlineMs = (start: 130.0, end: 360.0)
    public static let nowLineOutMs = 140.0
    public static let firstWordsMs = (start: 170.0, end: 360.0)
    /// How far a headline lifts away or rises into place, in points.
    public static let headlineTravel = 6.0

    /// How far the move has run, `0...1`.
    public let progress: Double
    /// The lights and the eye easing from the live strengths to the settled ones, and the eye
    /// from the live tone to the model's colour.
    public let lights: Double
    public let eye: Double
    /// The live headline: out in 170 ms, lifting (the offset is negative, upward).
    public let liveHeadlineAlpha: Double
    public let liveHeadlineOffsetY: Double
    /// The settled headline: in from 130 to 360 ms, rising from below.
    public let settledHeadlineAlpha: Double
    public let settledHeadlineOffsetY: Double
    /// The NOW line with its output: gone by 140 ms.
    public let nowLineAlpha: Double
    /// The agent's first words (or the digest) fading in.
    public let firstWordsAlpha: Double
    /// Whether the edge still pulses: never once the move has begun.
    public let edgePulses: Bool

    public var isDone: Bool { progress >= 1 }

    /// The card as it is when nothing is settling: the settled headline, no NOW line.
    public static let settled = NeuralCardSettle(progress: 1, running: false)

    /// The card at the instant the turn ends, before the move has run.
    public static let live = NeuralCardSettle(progress: 0, running: true)

    public static func at(_ elapsed: TimeInterval, reduceMotion: Bool = false) -> NeuralCardSettle {
        if reduceMotion { return .settled }
        let progress = NeuralTransition.clamp(elapsed / duration)
        return NeuralCardSettle(progress: progress, running: false)
    }

    private init(progress: Double, running: Bool) {
        let ms = progress * Self.duration * 1000
        func window(_ start: Double, _ end: Double) -> Double {
            NeuralTransition.clamp((ms - start) / (end - start))
        }
        let out = NeuralTransition.easeOutCubic(window(0, Self.liveHeadlineOutMs))
        let rise = NeuralTransition.easeOutCubic(window(Self.settledHeadlineMs.start, Self.settledHeadlineMs.end))
        self.progress = progress
        lights = NeuralTransition.easeOutCubic(progress)
        eye = lights
        liveHeadlineAlpha = 1 - window(0, Self.liveHeadlineOutMs)
        liveHeadlineOffsetY = -Self.headlineTravel * out
        settledHeadlineAlpha = window(Self.settledHeadlineMs.start, Self.settledHeadlineMs.end)
        settledHeadlineOffsetY = Self.headlineTravel * (1 - rise)
        nowLineAlpha = 1 - window(0, Self.nowLineOutMs)
        firstWordsAlpha = window(Self.firstWordsMs.start, Self.firstWordsMs.end)
        edgePulses = running
    }
}

/// When a card settled, on the client's clock: the client tells it each time it learns whether the
/// turn runs, and reads how far the move has run. A card first seen settled has no move.
public struct NeuralCardSettleClock: Sendable, Equatable {
    public private(set) var wasRunning: Bool?
    public private(set) var settleStartedAt: TimeInterval?

    public init() {}

    /// Notes that the turn is running or not at `now` (the display's clock); returns whether this
    /// is the moment it settled.
    @discardableResult
    public mutating func observe(running: Bool, now: TimeInterval) -> Bool {
        defer { wasRunning = running }
        if running {
            settleStartedAt = nil
            return false
        }
        guard wasRunning == true else { return false }
        settleStartedAt = now
        return true
    }

    /// Whether the move is still running at `now`.
    public func isSettling(now: TimeInterval) -> Bool {
        guard let started = settleStartedAt else { return false }
        return now - started < NeuralCardSettle.duration
    }

    /// The settle at `now`: the card as it arrived when no move ever began.
    public func settle(now: TimeInterval, reduceMotion: Bool = false) -> NeuralCardSettle {
        guard let started = settleStartedAt else { return .settled }
        return .at(now - started, reduceMotion: reduceMotion)
    }
}
