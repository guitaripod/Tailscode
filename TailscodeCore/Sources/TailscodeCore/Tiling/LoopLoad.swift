import Foundation

/// What the UI loop was doing over a span: running work, or waiting for something to do.
public enum LoopSlice: Sendable {
    case busy
    case idle
}

/// How loaded the UI loop is, over the last second and the last two, from the slices the platform
/// reports: Linux wraps `g_poll` (busy is wall time minus time inside it), the Mac observes the run
/// loop's before-waiting and after-waiting.
///
/// Time is kept in fixed 50 ms buckets rather than a list of slices, so a loop that iterates a
/// thousand times a second costs the same memory as one that iterates once.
public struct LoopLoad: Sendable, Equatable {
    public static let bucketWidth: TimeInterval = 0.05
    public static let bucketCount = 40

    private struct Bucket: Sendable, Equatable {
        var index: Int64 = .min
        var busy: TimeInterval = 0
        var covered: TimeInterval = 0
        var worst: TimeInterval = 0
    }

    private var buckets = [Bucket](repeating: Bucket(), count: LoopLoad.bucketCount)

    public init() {}

    /// Records a slice that ran from `start` to `end` on the monotonic clock. A slice longer than
    /// the whole window is clipped to it; its full length still counts as the worst busy slice.
    public mutating func record(_ slice: LoopSlice, from start: TimeInterval, to end: TimeInterval) {
        guard end > start else { return }
        let width = Self.bucketWidth
        let windowStart = end - width * Double(Self.bucketCount)
        var cursor = max(start, windowStart)
        var lastSlot: Int?
        while cursor < end {
            var index = Int64((cursor / width).rounded(.down))
            if Double(index + 1) * width <= cursor { index += 1 }
            let stop = min(end, max(Double(index + 1) * width, cursor.nextUp))
            let slot = Self.slot(index)
            if buckets[slot].index != index { buckets[slot] = Bucket(index: index) }
            let span = stop - cursor
            buckets[slot].covered += span
            if slice == .busy { buckets[slot].busy += span }
            lastSlot = slot
            cursor = stop
        }
        if slice == .busy, let lastSlot {
            buckets[lastSlot].worst = max(buckets[lastSlot].worst, end - start)
        }
    }

    private static func slot(_ index: Int64) -> Int {
        let count = Int64(bucketCount)
        return Int(((index % count) + count) % count)
    }

    /// The share of reported time spent busy over the last `window` seconds before `now`, 0 when
    /// nothing was reported.
    public func busy(over window: TimeInterval, now: TimeInterval) -> Double {
        var busy: TimeInterval = 0
        var covered: TimeInterval = 0
        for bucket in live(over: window, now: now) {
            busy += bucket.busy
            covered += bucket.covered
        }
        guard covered > 0 else { return 0 }
        return min(1, busy / covered)
    }

    /// The longest busy slice that ended in the last `window` seconds.
    public func worstSlice(over window: TimeInterval, now: TimeInterval) -> TimeInterval {
        live(over: window, now: now).map(\.worst).max() ?? 0
    }

    public func reading(now: TimeInterval) -> LoopReading {
        LoopReading(
            busy1: busy(over: 1, now: now), busy2: busy(over: 2, now: now),
            worst1: worstSlice(over: 1, now: now), worst2: worstSlice(over: 2, now: now))
    }

    private func live(over window: TimeInterval, now: TimeInterval) -> [Bucket] {
        let width = Self.bucketWidth
        let last = Int64((now / width).rounded(.down))
        let span = Int64(min(Double(Self.bucketCount), (window / width).rounded(.up)))
        let first = last - span + 1
        return buckets.filter { $0.index >= first && $0.index <= last }
    }
}

/// One look at the loop: busy share and worst slice over one and two seconds.
public struct LoopReading: Sendable, Equatable {
    public var busy1: Double
    public var busy2: Double
    public var worst1: TimeInterval
    public var worst2: TimeInterval

    public init(busy1: Double, busy2: Double, worst1: TimeInterval, worst2: TimeInterval) {
        self.busy1 = busy1
        self.busy2 = busy2
        self.worst1 = worst1
        self.worst2 = worst2
    }
}

/// The watchdog's thresholds as decisions. A helper thread pings the UI loop every `ping`; no
/// answer for `stall` writes a stall record and asks for level 4 the moment the loop resumes; no
/// answer for `deep` writes the deep record. Each happens once per episode.
public struct StallPolicy: Sendable, Equatable {
    public var ping: TimeInterval
    public var stall: TimeInterval
    public var deep: TimeInterval

    public init(ping: TimeInterval = 0.5, stall: TimeInterval = 3, deep: TimeInterval = 10) {
        self.ping = ping
        self.stall = stall
        self.deep = deep
    }

    public enum Verdict: Sendable, Equatable {
        case healthy
        case stalled(TimeInterval)
        case deep(TimeInterval)
    }

    /// How long the loop has not answered, as a verdict.
    public func verdict(lastAnswer: TimeInterval, now: TimeInterval) -> Verdict {
        let silent = now - lastAnswer
        if silent >= deep { return .deep(silent) }
        if silent >= stall { return .stalled(silent) }
        return .healthy
    }
}

/// One stall episode followed through: what the watchdog should write, each thing once.
public struct StallWatch: Sendable, Equatable {
    public enum Event: Sendable, Equatable {
        /// The loop has been silent past the stall threshold: write a stall record, set the hint.
        case stall(TimeInterval)
        /// Silent past the deep threshold: write the deep record.
        case deep(TimeInterval)
        /// The loop answered again after a stall; the episode lasted this long.
        case recovered(TimeInterval)
    }

    public let policy: StallPolicy
    private var stallWritten = false
    private var deepWritten = false
    private var episodeStart: TimeInterval?

    public init(policy: StallPolicy = StallPolicy()) {
        self.policy = policy
    }

    /// Whether a stall episode is open: the hint the loop applies as level 4 when it resumes.
    public var isStalled: Bool { stallWritten }

    /// Called on the watchdog thread every ping with when the loop last answered.
    public mutating func check(lastAnswer: TimeInterval, now: TimeInterval) -> Event? {
        switch policy.verdict(lastAnswer: lastAnswer, now: now) {
        case .healthy:
            guard stallWritten, let start = episodeStart else { return nil }
            stallWritten = false
            deepWritten = false
            episodeStart = nil
            return .recovered(lastAnswer - start)
        case .stalled(let silent):
            guard !stallWritten else { return nil }
            stallWritten = true
            episodeStart = lastAnswer
            return .stall(silent)
        case .deep(let silent):
            if !stallWritten {
                stallWritten = true
                episodeStart = lastAnswer
                return .stall(silent)
            }
            guard !deepWritten else { return nil }
            deepWritten = true
            return .deep(silent)
        }
    }
}
