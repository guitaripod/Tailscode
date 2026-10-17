import CodingAgentKit
import Foundation

/// How long a provider's quota window is, which is what turns "62%" into a pace.
///
/// A gauge carries how much is used and when the window opens again, but not how long the window
/// is — that lives in its key and its label (`five_hour`, "5-hour session", "Weekly · Opus",
/// opencode's `monthly`). Reading it from them is a parse rather than a table for the reason
/// `QuotaBinding` is one: the window that ships tomorrow is named by the same words. A window the
/// words do not name, or one that is *rolling* — where the reset is when the oldest spend expires
/// and not a moment the window ends — has no span, and a window with no span has no pace.
public enum QuotaWindowSpan {
    private static let hour: TimeInterval = 3600

    /// The window's length, or nil when it cannot be told. A calendar month is the only span that
    /// depends on the date, so it is the one that needs the reset to measure back from.
    public static func read(
        key: String, label: String, resetsAt: Date?, calendar: Calendar = .current
    ) -> TimeInterval? {
        let words = tokens(key + " " + label)
        guard !words.contains("rolling") else { return nil }
        if words.contains("monthly") || words.contains("month") {
            return month(endingAt: resetsAt, calendar: calendar)
        }
        if words.contains("weekly") || words.contains("week")
            || follows(["seven", "7"], by: "day", in: words)
        {
            return 7 * 24 * hour
        }
        if words.contains("daily") || words.contains("24h") || follows(["24"], by: "hour", in: words) {
            return 24 * hour
        }
        if words.contains("session") || words.contains("5h") || follows(["five", "5"], by: "hour", in: words) {
            return 5 * hour
        }
        if words.contains("hourly") || follows(["1", "one"], by: "hour", in: words) {
            return hour
        }
        return nil
    }

    public static func read(
        _ gauge: UsageQuota.Gauge, calendar: Calendar = .current
    ) -> TimeInterval? {
        read(key: gauge.key, label: gauge.label, resetsAt: gauge.resetsAt, calendar: calendar)
    }

    private static func tokens(_ text: String) -> [String] {
        text.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// Whether any of `heads` is immediately followed by `tail` — "5-hour" and "five_hour" are two
    /// words and "5h" is one, and all three name the same window.
    private static func follows(_ heads: [String], by tail: String, in words: [String]) -> Bool {
        zip(words, words.dropFirst()).contains { heads.contains($0) && $1 == tail }
    }

    private static func month(endingAt end: Date?, calendar: Calendar) -> TimeInterval? {
        guard let end, let start = calendar.date(byAdding: .month, value: -1, to: end) else {
            return nil
        }
        return end.timeIntervalSince(start)
    }
}

/// Where a quota window is heading, read from how much of it is used against how much of its time
/// has gone.
///
/// A percentage alone says how full the window is, and the same 62% is a quiet morning with four
/// hours left and a wall in eighty minutes with two. The pace is the missing half: the fill is
/// compared with an *even* burn (the tick — how much of the window's time has elapsed), and the
/// rate so far is carried forward to the reset to say where the fill lands (the tail). Nothing here
/// is a measurement of the future, so nothing here states one as fact: a window that has barely
/// begun says so instead of extrapolating a few minutes of work, a reset the provider only
/// estimates makes every figure *about*, and a window with no span or no reset has no pace at all.
public struct QuotaPace: Sendable, Equatable {
    public enum Basis: Sendable, Equatable {
        /// The average over the whole window so far.
        case sinceStart
        /// The rate over the last stretch, which a long window's average would hide: a bursty
        /// Monday is not the Thursday that follows it.
        case recent(TimeInterval)
    }

    public enum Verdict: Sendable, Equatable {
        /// Not enough of the window has passed to say anything.
        case tooEarly
        case onPace
        /// The tail lands in the last stretch below the limit, or reaches it a moment before the
        /// reset — worth a glance, not worth a wall.
        case closeToTheLine
        /// At this pace the limit is reached at `at`, a meaningful time before the reset.
        case willRunOut(at: Date)
        /// Used up; sends resume when the window opens.
        case wall(resumesAt: Date)
    }

    public let used: Double
    public let span: TimeInterval
    public let resetsAt: Date
    /// How much of the window's time has passed, `0...1`.
    public let elapsed: Double
    /// The reset is the provider's estimate, so every figure derived from it is approximate.
    public let approximate: Bool
    /// Where the fill lands at the reset if the rate holds. Above 1 means the limit comes first.
    /// Nil while there is no pace to carry forward.
    public let landing: Double?
    public let wallAt: Date?
    /// How long before the reset the limit is reached, when it is reached before it.
    public let slack: TimeInterval?
    public let basis: Basis
    public let verdict: Verdict

    /// A window must be this far through its time, and this many seconds into it, before its pace
    /// means anything.
    public static let minElapsed = 0.10
    public static let minElapsedSeconds: TimeInterval = 900
    /// A landing at or past this share of the limit is worth a glance.
    public static let closeFloor = 0.85
    /// A wall closer to the reset than this is not news: the window is about to open anyway.
    public static let minSlack: TimeInterval = 600
    public static let minSlackShare = 0.10
    /// The shortest stretch a recent rate may be measured over.
    public static let minRecent: TimeInterval = 1200

    public var tone: ContextFill.Tone {
        switch verdict {
        case .wall: return .danger
        case .willRunOut, .closeToTheLine: return .attention
        case .tooEarly, .onPace: return .quiet
        }
    }

    /// Whether the tail has something to say — what a glance surface draws and a quiet row omits.
    public var isNews: Bool {
        switch verdict {
        case .closeToTheLine, .willRunOut, .wall: return true
        case .tooEarly, .onPace: return false
        }
    }

    /// Where the hatched tail ends on the bar, `used...1`, or nil when there is no projection.
    public var tailEnd: Double? {
        guard let landing else { return nil }
        return min(1, max(used, landing))
    }

    public static func recentWindow(span: TimeInterval) -> TimeInterval {
        min(24 * 3600, max(3600, span * 0.15))
    }

    /// The pace of one window, or nil when it has none: no reset, a reset already behind us (a
    /// photograph of a moment that ended), a window whose length cannot be told, or a reset further
    /// away than the window is long, which means the length was guessed wrong.
    public static func read(
        _ gauge: UsageQuota.Gauge, provider: String = "", now: Date = Date(),
        trail: QuotaTrail? = nil, calendar: Calendar = .current
    ) -> QuotaPace? {
        guard gauge.usedUSD == nil || gauge.limitUSD != nil else { return nil }
        guard let resetsAt = gauge.resetsAt, resetsAt > now else { return nil }
        guard let span = QuotaWindowSpan.read(gauge, calendar: calendar), span > 0 else { return nil }
        let remaining = resetsAt.timeIntervalSince(now)
        guard remaining <= span * 1.1 else { return nil }

        let elapsedSeconds = max(0, span - remaining)
        let elapsed = min(1, elapsedSeconds / span)
        let used = min(1, max(0, gauge.fraction))
        let approximate = !gauge.trustedReset

        if gauge.fraction >= QuotaSurface.exhaustedFloor {
            return QuotaPace(
                used: used, span: span, resetsAt: resetsAt, elapsed: elapsed,
                approximate: approximate, landing: nil, wallAt: nil, slack: nil,
                basis: .sinceStart, verdict: .wall(resumesAt: resetsAt))
        }
        guard elapsed >= minElapsed, elapsedSeconds >= minElapsedSeconds else {
            return QuotaPace(
                used: used, span: span, resetsAt: resetsAt, elapsed: elapsed,
                approximate: approximate, landing: nil, wallAt: nil, slack: nil,
                basis: .sinceStart, verdict: .tooEarly)
        }

        var rate = used / elapsedSeconds
        var basis = Basis.sinceStart
        if let trail,
            let recent = trail.recentRate(
                id: QuotaTrail.identity(provider: provider, gauge: gauge), now: now,
                current: used, within: recentWindow(span: span))
        {
            rate = recent.rate
            basis = .recent(recent.over)
        }

        let landing = used + rate * remaining
        var wallAt: Date?
        var slack: TimeInterval?
        if landing > 1, rate > 0 {
            let at = now.addingTimeInterval((1 - used) / rate)
            wallAt = at
            slack = max(0, resetsAt.timeIntervalSince(at))
        }

        let verdict: Verdict
        if let wallAt, let slack, slack >= max(minSlack, remaining * minSlackShare) {
            verdict = .willRunOut(at: wallAt)
        } else if landing >= closeFloor {
            verdict = .closeToTheLine
        } else {
            verdict = .onPace
        }
        return QuotaPace(
            used: used, span: span, resetsAt: resetsAt, elapsed: elapsed,
            approximate: approximate, landing: landing, wallAt: wallAt, slack: slack,
            basis: basis, verdict: verdict)
    }
}
