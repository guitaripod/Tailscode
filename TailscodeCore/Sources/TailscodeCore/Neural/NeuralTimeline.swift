import Foundation

/// Maps a turn's real message times onto the clock a replay plays on. Minutes of waiting for a
/// build become a beat, a turn of eight minutes plays in about twelve seconds, and the order of
/// the messages is never disturbed. A turn whose steps carry no times plays at a fixed pace per
/// message instead, because nothing may be invented from a clock the wire did not carry.
public struct NeuralTimeline: Sendable, Equatable {
    /// How long a replay takes by default.
    public static let defaultTarget: TimeInterval = 12
    /// A gap between two messages longer than this is a wait, and is shortened.
    public static let gapThreshold: TimeInterval = 20
    /// What a wait is shortened to.
    public static let compressedGap: TimeInterval = 1.2
    /// The pace of a turn with no times, per message.
    public static let fallbackGroupStep: TimeInterval = 0.62
    /// The shortest beat between two messages, so a burst of quick ones is still seen as many.
    public static let minimumGap: TimeInterval = 0.15
    /// How long the last node stays lit before the replay ends.
    public static let tail: TimeInterval = 0.9
    /// The largest a quick turn is slowed to reach the target.
    public static let maximumStretch: Double = 3
    /// The delay between the calls of one message, which fire together.
    public static let stagger: TimeInterval = 0.04
    /// The room a message's staggered calls may take in all, always less than `minimumGap`.
    public static let staggerBudget: TimeInterval = 0.12

    /// When each step fires, in replay seconds, in the order the steps were given.
    public let fireTimes: [TimeInterval]
    /// The wall clock each step was stamped with, where the wire carried one.
    public let stamps: [Date?]
    /// The replay's length: the last step's time plus the hold on it.
    public let duration: TimeInterval
    /// Whether any step carried a time. A turn without any plays at the fixed pace.
    public let isTimed: Bool

    public init(fireTimes: [TimeInterval], stamps: [Date?], duration: TimeInterval, isTimed: Bool) {
        self.fireTimes = fireTimes
        self.stamps = stamps
        self.duration = duration
        self.isTimed = isTimed
    }

    public static func make(steps: [NeuralStep], target: TimeInterval = defaultTarget) -> NeuralTimeline {
        guard !steps.isEmpty else {
            return NeuralTimeline(fireTimes: [], stamps: [], duration: 0, isTimed: false)
        }
        let groups = grouped(steps)
        let stamps = steps.map(\.at)
        let starts = groups.map { range in steps[range].compactMap(\.at).min() }
        let timed = starts.contains { $0 != nil }
        let groupTimes = timed
            ? fitted(starts: starts, target: target)
            : groups.indices.map { Double($0) * fallbackGroupStep }
        var fire = [TimeInterval](repeating: 0, count: steps.count)
        for (index, range) in groups.enumerated() {
            let each = range.count > 1
                ? min(stagger, staggerBudget / Double(range.count - 1)) : 0
            for (member, step) in range.enumerated() {
                fire[step] = groupTimes[index] + Double(member) * each
            }
        }
        let last = fire.max() ?? 0
        return NeuralTimeline(
            fireTimes: fire, stamps: stamps, duration: last + tail, isTimed: timed)
    }

    /// The replay second a position along the scrubber stands for.
    public func time(forFraction fraction: Double) -> TimeInterval {
        min(max(fraction, 0), 1) * duration
    }

    public func fraction(forTime time: TimeInterval) -> Double {
        guard duration > 0 else { return 1 }
        return min(max(time / duration, 0), 1)
    }

    /// The index of the latest step that has fired by `time`, nil before the first.
    public func activeStep(at time: TimeInterval) -> Int? {
        var found: Int?
        for (index, fired) in fireTimes.enumerated() where fired <= time { found = index }
        return found
    }

    /// How many steps have fired by `time`: the nodes a renderer lights.
    public func litCount(at time: TimeInterval) -> Int {
        fireTimes.reduce(0) { $0 + ($1 <= time ? 1 : 0) }
    }

    /// The wall clock of the message the replay has reached, "14:02:52", nil where no time was
    /// carried or nothing has fired yet.
    public func clockLabel(at time: TimeInterval, timeZone: TimeZone = .current) -> String? {
        guard let index = activeStep(at: time), let stamp = stamps[index] else { return nil }
        return NeuralReading.clock(stamp, timeZone: timeZone)
    }

    private static func grouped(_ steps: [NeuralStep]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var begin = 0
        for index in 1...steps.count {
            if index == steps.count || steps[index].group != steps[begin].group {
                out.append(begin..<index)
                begin = index
            }
        }
        return out
    }

    /// Group times from real gaps: a wait becomes `compressedGap`, quick gaps are scaled together
    /// so the whole fits `target`, and nothing is shorter than `minimumGap`.
    private static func fitted(starts: [Date?], target: TimeInterval) -> [TimeInterval] {
        var gaps: [TimeInterval] = []
        var previous: Date?
        for (index, start) in starts.enumerated() {
            guard index > 0 else {
                previous = start
                continue
            }
            if let start, let before = previous {
                gaps.append(max(0, start.timeIntervalSince(before)))
            } else {
                gaps.append(0)
            }
            previous = start ?? previous
        }
        let waits = gaps.filter { $0 > gapThreshold }.count
        let quickTotal = gaps.filter { $0 <= gapThreshold }.reduce(0, +)
        let budget = max(target - tail, 0)
        let fixed = Double(waits) * compressedGap
        var quickScale = 1.0
        var waitGap = compressedGap
        if fixed + quickTotal > 0 {
            if fixed >= budget * 0.8 {
                let scale = budget / (fixed + quickTotal)
                quickScale = scale
                waitGap = compressedGap * scale
            } else if quickTotal > 0 {
                quickScale = min((budget - fixed) / quickTotal, maximumStretch)
            }
        }
        var times: [TimeInterval] = [0]
        for gap in gaps {
            let shown = gap > gapThreshold ? waitGap : gap * quickScale
            times.append(times[times.count - 1] + max(shown, minimumGap))
        }
        return times
    }
}
