import Foundation

/// What the way in to video says about the render, as light round its own edge.
///
/// A clip is minutes of another machine's card and the person is somewhere else while it is made,
/// so the one control that is always on screen has to answer the only questions they have: is it
/// working, how far has it got, is it waiting on something, did it land, did it break. Seven faces
/// answer them and no more, each in the vocabulary the rest of the app already speaks — work is
/// live and fills, a wake sweeps, a queue holds still, saving breathes, and anything that ended
/// holds perfectly still until somebody has looked at it, because an ending is news until it is
/// read and stillness is how a reader tells a stopped render from a slow one.
public enum ForgeLight: Sendable, Equatable {
    /// Nothing to say: no render is out and nothing that ended is waiting to be read.
    case dark
    /// The graph is on its way, or the machine is loading its models before the first step.
    case waking
    /// Behind other jobs on the machine, which is shared.
    case waiting(ahead: Int)
    /// Painting, with how far along it is.
    case rendering(Double)
    /// Every step is done and the file is being written.
    case saving
    /// A clip is ready and nobody has seen it yet.
    case landed
    /// The render broke and nobody has read why.
    case failed

    /// The face a job wears. `seen` is whether the person has looked at how it ended — the clip on
    /// a stage, the failure on a card — which the runner of each client knows and the job does not.
    public static func read(job: ForgeJob, seen: Bool) -> ForgeLight {
        switch job.phase {
        case .drafting, .cancelled:
            return .dark
        case .submitting:
            return .waking
        case .queued(let ahead):
            return ahead > 0 ? .waiting(ahead: ahead) : .waking
        case .running(let fraction):
            return fraction >= 1 ? .saving : .rendering(min(max(fraction, 0), 1))
        case .done:
            return seen ? .dark : .landed
        case .failed:
            return seen ? .dark : .failed
        }
    }

    public var isLit: Bool { self != .dark }

    /// Whether the other machine is working on it, as opposed to a clip or a failure that is
    /// waiting to be looked at.
    public var isOut: Bool {
        switch self {
        case .waking, .waiting, .rendering, .saving: return true
        case .dark, .landed, .failed: return false
        }
    }

    /// The colour slot, one of the four meanings the app has. Dark has none to wear and answers
    /// quiet so a caller never has to unwrap one.
    public var tone: ActivityTone {
        switch self {
        case .dark, .waking, .waiting: return .quiet
        case .rendering, .saving, .landed: return .live
        case .failed: return .danger
        }
    }

    /// How it moves, which is part of what it means: a wake sweeps, work travels along what it has
    /// done, saving breathes, and everything else holds still.
    public var motion: ActivityMotion {
        switch self {
        case .waking: return .sweep(period: ForgeRing.cometPeriod)
        case .rendering: return .sweep(period: ForgeRing.sheenPeriod)
        case .saving: return .working
        case .dark, .waiting, .landed, .failed: return .still
        }
    }

    /// The sentence for a screen reader and a tooltip, which say it because the ring can only say
    /// it to somebody who can see it. Nil when the control has nothing to add to its own name.
    public var spoken: String? {
        switch self {
        case .dark:
            return nil
        case .waking:
            return Localized.text("Video — waking the renderer")
        case .waiting(let ahead):
            return Localized.text("Video — %@ ahead in the queue", "\(ahead)")
        case .rendering(let fraction):
            return Localized.text("Video — rendering, %@%%", "\(Int((fraction * 100).rounded()))")
        case .saving:
            return Localized.text("Video — saving the file")
        case .landed:
            return Localized.text("Video — a clip is ready")
        case .failed:
            return Localized.text("Video — the last render failed")
        }
    }

    /// The ring as it is drawn at an instant. `displayed` is the fraction the arc has been eased
    /// to (`ForgeRing.follow`), which the caller keeps because the machine reports progress in
    /// jumps and a ring that jumps with it reads as a fault; it defaults to the true one. Reduced
    /// motion drops the movement and nothing else: the comet becomes the arc it was travelling,
    /// the travelling light is dropped from the progress, and saving stops breathing.
    public func frame(
        at time: TimeInterval, displayed: Double? = nil, reduceMotion: Bool = false
    ) -> ForgeRingFrame {
        switch self {
        case .dark:
            return ForgeRingFrame(tone: .quiet, track: 0, strokes: [])
        case .waking:
            guard !reduceMotion else {
                return ForgeRingFrame(
                    tone: .quiet, track: ForgeRing.faintTrack,
                    strokes: ForgeRing.pieces(start: 0, length: 0.25, intensity: 0.9))
            }
            let head = ForgeRing.phase(of: time, period: ForgeRing.cometPeriod)
            return ForgeRingFrame(
                tone: .quiet, track: ForgeRing.faintTrack, strokes: ForgeRing.comet(head: head))
        case .waiting:
            return ForgeRingFrame(
                tone: .quiet, track: 0, strokes: ForgeRing.pieces(start: 0, length: 1, intensity: 0.5))
        case .rendering(let fraction):
            let reached = max(displayed ?? fraction, ForgeRing.leastArc)
            var strokes = ForgeRing.pieces(
                start: 0, length: reached, intensity: reduceMotion ? 1 : ForgeRing.arcIntensity)
            if !reduceMotion, reached > ForgeRing.sheenLength * 0.4 {
                strokes += ForgeRing.sheen(
                    within: reached, phase: ForgeRing.phase(of: time, period: ForgeRing.sheenPeriod))
            }
            return ForgeRingFrame(tone: .live, track: ForgeRing.faintTrack, strokes: strokes)
        case .saving:
            let light = reduceMotion ? 0.85 : ActivityMotion.working.intensity(at: time)
            return ForgeRingFrame(
                tone: .live, track: ForgeRing.faintTrack,
                strokes: ForgeRing.pieces(start: 0, length: 1, intensity: light))
        case .landed:
            return ForgeRingFrame(
                tone: .live, track: 0, strokes: ForgeRing.pieces(start: 0, length: 1, intensity: 1))
        case .failed:
            return ForgeRingFrame(
                tone: .danger, track: 0, strokes: ForgeRing.pieces(start: 0, length: 1, intensity: 1))
        }
    }
}

/// One drawing of the ring: a colour slot, how visible the faint full-circle track beneath is, and
/// the strokes laid along the perimeter. Positions are fractions of the way round the control's
/// edge, from the top centre and clockwise, and no stroke ever crosses the top — a stroke that
/// would is already two — so a client never wraps anything, whatever it draws with.
public struct ForgeRingFrame: Sendable, Equatable {
    public struct Stroke: Sendable, Equatable {
        public let start: Double
        public let length: Double
        /// The ink's worth, `0...1`, which a client multiplies into the colour's own alpha.
        public let intensity: Double

        public init(start: Double, length: Double, intensity: Double) {
            self.start = start
            self.length = length
            self.intensity = intensity
        }

        public var end: Double { start + length }
    }

    public let tone: ActivityTone
    public let track: Double
    public let strokes: [Stroke]

    public init(tone: ActivityTone, track: Double, strokes: [Stroke]) {
        self.tone = tone
        self.track = track
        self.strokes = strokes
    }

    public var isEmpty: Bool { track <= 0 && strokes.isEmpty }
}

/// The ring's arithmetic, read from absolute time like every other motion here, so a ring that
/// misses frames stays in step with the rest of the screen instead of falling behind it.
public enum ForgeRing {
    /// One lap of the wake's comet.
    public static let cometPeriod: TimeInterval = 1.6
    /// One pass of the light that travels along what has been painted. Slower than the comet: it
    /// says "alive", not "looking".
    public static let sheenPeriod: TimeInterval = 2.6
    /// How long the arc takes to close most of the distance to the machine's latest word.
    public static let easing: TimeInterval = 0.35
    public static let faintTrack = 0.16
    /// The progress arc's own ink, left room under the light that travels along it.
    public static let arcIntensity = 0.8
    public static let sheenLength = 0.10
    /// What a render that has begun is always given, so it is never an empty ring.
    public static let leastArc = 0.02

    /// The comet's tail, longest and faintest first, every piece ending at the head.
    private static let tail: [(length: Double, intensity: Double)] = [
        (0.22, 0.16), (0.15, 0.34), (0.09, 0.62), (0.04, 1),
    ]

    /// How far round a time is, `0..<1`.
    public static func phase(of time: TimeInterval, period: TimeInterval) -> Double {
        let turns = time / max(0.05, period)
        return turns - turns.rounded(.down)
    }

    /// The comet whose head is at `head`.
    public static func comet(head: Double) -> [ForgeRingFrame.Stroke] {
        tail.flatMap { piece in
            pieces(start: head - piece.length, length: piece.length, intensity: piece.intensity)
        }
    }

    /// The light travelling along an arc that runs from the top to `reached`: it leaves the top,
    /// eases toward the end and rests there a moment before leaving again.
    public static func sheen(within reached: Double, phase: Double) -> [ForgeRingFrame.Stroke] {
        let travel = min(1, phase / 0.7)
        let eased = travel * travel * (3 - 2 * travel)
        let head = eased * reached
        let length = min(sheenLength, reached)
        return pieces(start: max(0, head - length), length: min(length, head), intensity: 1)
    }

    /// A stretch of the perimeter as the strokes that draw it, none of them crossing the top.
    public static func pieces(
        start: Double, length: Double, intensity: Double
    ) -> [ForgeRingFrame.Stroke] {
        let span = min(max(length, 0), 1)
        guard span > 0 else { return [] }
        let from = start - start.rounded(.down)
        if from + span <= 1 {
            return [ForgeRingFrame.Stroke(start: from, length: span, intensity: intensity)]
        }
        return [
            ForgeRingFrame.Stroke(start: from, length: 1 - from, intensity: intensity),
            ForgeRingFrame.Stroke(start: 0, length: from + span - 1, intensity: intensity),
        ]
    }

    /// Where the arc is drawn after `elapsed` seconds of heading for the machine's latest answer.
    /// It closes the distance smoothly and never retreats on its own; a target that is lower than
    /// where the arc stands is a new render, and the arc starts over from it.
    public static func follow(
        displayed: Double, target: Double, elapsed: TimeInterval
    ) -> Double {
        let goal = min(max(target, 0), 1)
        guard goal > displayed else { return goal }
        let closed = 1 - exp(-max(0, elapsed) / easing)
        return displayed + (goal - displayed) * closed
    }
}

extension ForgeEntryPoint {
    /// What the control is called for a screen reader: its own name, or the state it is in.
    public static func accessibilityLabel(light: ForgeLight) -> String {
        light.spoken ?? title
    }

    /// What the control promises on hover. While there is something to report it reports that:
    /// a promise to describe a video is no use to a person whose question is how far it has got.
    public static func tooltip(configured: Bool, light: ForgeLight) -> String {
        light.spoken ?? tooltip(configured: configured)
    }
}
