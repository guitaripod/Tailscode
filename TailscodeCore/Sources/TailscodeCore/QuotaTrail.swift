import CodingAgentKit
import Foundation

/// What this device has seen each quota window read, over the last week, so that a pace can be
/// measured over the last stretch instead of averaged over the whole window.
///
/// A window's average hides how it is being spent: a weekly allowance burned down on Monday and
/// left alone since is on pace *now*, and one that has barely moved all week and is being drained
/// this afternoon is not. A trail is a handful of `(time, fraction)` samples per window, kept only
/// as dense as the reading moved, and it forgets a window the moment its fill drops — which is a
/// reset, whatever the clock said — so a sample from last week's allowance never explains this
/// week's.
public struct QuotaTrail: Sendable, Equatable, Codable {
    public struct Sample: Sendable, Equatable, Codable {
        public let at: Date
        /// A window's used fraction, or a prepaid balance's dollars: what the series is of.
        public let value: Double

        public init(at: Date, value: Double) {
            self.at = at
            self.value = value
        }
    }

    public private(set) var series: [String: [Sample]]

    public static let keep: TimeInterval = 7 * 86400
    /// A reading is kept when it moved this much, or when this long has passed since the last one,
    /// so a still window leaves an anchor without leaving a sample per poll.
    public static let minStep = 0.01
    public static let anchorEvery: TimeInterval = 3600
    /// A fall this large between two readings is a window that reset.
    public static let resetDrop = 0.2
    public static let capPerSeries = 800
    /// A recent rate is measured against a point no more than this many window-lengths away from
    /// the nearest sample either side of it; a hole wider than that is a trail nobody was
    /// watching, and interpolating across it would invent a rate.
    public static let widestHole = 2.0
    /// A balance must have been watched this long before its spend is read as a rate.
    public static let minBalanceSpan: TimeInterval = 86400
    public static let minDollars = 0.01
    /// A balance rising by more than this between two readings was topped up.
    public static let topUp = 0.5

    public init(series: [String: [Sample]] = [:]) {
        self.series = series
    }

    public var isEmpty: Bool { series.isEmpty }

    /// The identity a window is kept under: the provider and the window's own key and label, so
    /// two models' weekly windows on one provider are two series.
    public static func identity(provider: String, gauge: UsageQuota.Gauge) -> String {
        "\(provider.lowercased())/\(gauge.key)/\(gauge.label.lowercased())"
    }

    /// Records one reading.
    ///
    /// - Returns: whether the trail changed, so a store writes only when there is something new.
    @discardableResult
    public mutating func note(_ fraction: Double, id: String, at: Date) -> Bool {
        guard fraction.isFinite else { return false }
        let value = min(1, max(0, fraction))
        var samples = series[id] ?? []
        let horizon = at.addingTimeInterval(-Self.keep)
        var changed = samples.contains { $0.at < horizon }
        samples.removeAll { $0.at < horizon }
        if let last = samples.last {
            guard at > last.at else { return commit(samples, id: id, changed: changed) }
            if value < last.value - Self.resetDrop {
                samples.removeAll()
                changed = true
            }
        }
        if let last = samples.last, abs(value - last.value) < Self.minStep,
            at.timeIntervalSince(last.at) < Self.anchorEvery
        {
            return commit(samples, id: id, changed: changed)
        }
        samples.append(Sample(at: at, value: value))
        if samples.count > Self.capPerSeries {
            samples.removeFirst(samples.count - Self.capPerSeries)
        }
        return commit(samples, id: id, changed: true)
    }

    /// Records every window of every provider in a report, and every prepaid balance beside them.
    @discardableResult
    public mutating func note(quotas: [UsageQuota], at: Date) -> Bool {
        var changed = false
        for quota in quotas {
            for gauge in quota.gauges {
                let id = Self.identity(provider: quota.providerName, gauge: gauge)
                if gauge.usedUSD != nil, gauge.limitUSD == nil {
                    if noteBalance(gauge.usedUSD ?? 0, id: id, at: at) { changed = true }
                } else if note(gauge.fraction, id: id, at: at) {
                    changed = true
                }
            }
        }
        return changed
    }

    /// Records a prepaid balance in dollars. A balance only goes down by being spent, so a rise is
    /// a top-up and starts the series again; a few cents is below what is worth keeping.
    @discardableResult
    public mutating func noteBalance(_ dollars: Double, id: String, at: Date) -> Bool {
        guard dollars.isFinite, dollars >= 0 else { return false }
        var samples = series[id] ?? []
        let horizon = at.addingTimeInterval(-Self.keep)
        var changed = samples.contains { $0.at < horizon }
        samples.removeAll { $0.at < horizon }
        if let last = samples.last {
            guard at > last.at else { return commit(samples, id: id, changed: changed) }
            if dollars > last.value + Self.topUp {
                samples.removeAll()
                changed = true
            }
        }
        if let last = samples.last, abs(dollars - last.value) < Self.minDollars,
            at.timeIntervalSince(last.at) < Self.anchorEvery
        {
            return commit(samples, id: id, changed: changed)
        }
        samples.append(Sample(at: at, value: dollars))
        if samples.count > Self.capPerSeries {
            samples.removeFirst(samples.count - Self.capPerSeries)
        }
        return commit(samples, id: id, changed: true)
    }

    /// How fast a prepaid balance has been spent, in dollars a day over the stretch the trail
    /// covers, and how long a stretch that was. Nil until a day has passed and something was
    /// spent: an hour of work is not a rate a balance's runway should be read from.
    public func spendPerDay(id: String, balance: Double, now: Date) -> (perDay: Double, over: TimeInterval)? {
        guard let first = series[id]?.first, first.at < now else { return nil }
        let over = now.timeIntervalSince(first.at)
        guard over >= Self.minBalanceSpan else { return nil }
        let spent = first.value - balance
        guard spent >= Self.minDollars else { return nil }
        return (spent / (over / 86400), over)
    }

    /// The rate the window has been filling at over the last `window`, in fraction per second, and
    /// how long a stretch it was measured over; nil when the trail does not reach back far enough
    /// to say, when the window filled backwards (it reset), or when nobody was watching for too
    /// long a stretch of it to interpolate.
    public func recentRate(
        id: String, now: Date, current: Double, within window: TimeInterval
    ) -> (rate: Double, over: TimeInterval)? {
        guard let samples = series[id], let newest = samples.last, newest.at <= now, window > 0
        else { return nil }
        let start = now.addingTimeInterval(-window)
        let anchor: (at: Date, value: Double)
        if let before = samples.last(where: { $0.at <= start }),
            let after = samples.first(where: { $0.at > start }),
            after.at.timeIntervalSince(before.at) <= window * Self.widestHole
        {
            let span = after.at.timeIntervalSince(before.at)
            let share = span > 0 ? start.timeIntervalSince(before.at) / span : 0
            anchor = (start, before.value + (after.value - before.value) * share)
        } else if let first = samples.first(where: { $0.at > start }) {
            anchor = (first.at, first.value)
        } else {
            return nil
        }
        let over = now.timeIntervalSince(anchor.at)
        guard over >= QuotaPace.minRecent else { return nil }
        let rise = current - anchor.value
        guard rise >= 0 else { return nil }
        return (rise / over, over)
    }

    private mutating func commit(_ samples: [Sample], id: String, changed: Bool) -> Bool {
        series[id] = samples.isEmpty ? nil : samples
        return changed
    }
}
