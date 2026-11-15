import CodingAgentKit
import Foundation

/// A window whose stated reset is behind us has opened again, whatever the last reading of it
/// said.
///
/// A reading is a photograph of a moment. A week photographed at 100 % with a reset at 21:00 is
/// not still used up at 21:01 because no machine has been asked since: the provider said when it
/// would open, that moment has passed, and the photograph is of a window that has ended. Every
/// surface draws readings through here, so none of them goes on saying "Used up" until the next
/// poll lands; the reset window reads empty, opened at the reset it passed, with no reset of its
/// own until a reading names one. A balance has no window and is left alone.
public enum QuotaReset {
    public static func settled(_ quota: UsageQuota, now: Date = Date()) -> UsageQuota {
        guard quota.gauges.contains(where: { hasReset($0.resetsAt, $0.usedUSD, $0.limitUSD, now) })
        else { return quota }
        var result = quota
        result.gauges = quota.gauges.map { settled($0, now: now) }
        return result
    }

    public static func settled(_ gauge: UsageQuota.Gauge, now: Date = Date()) -> UsageQuota.Gauge {
        guard hasReset(gauge.resetsAt, gauge.usedUSD, gauge.limitUSD, now), let reset = gauge.resetsAt
        else { return gauge }
        var result = gauge
        result.fraction = 0
        result.startsAt = reset
        result.resetsAt = nil
        result.refused = nil
        if result.limitUSD != nil { result.usedUSD = 0 }
        return result
    }

    public static func settled(_ quota: WidgetQuota, now: Date = Date()) -> WidgetQuota {
        guard quota.gauges.contains(where: { hasReset($0.resetsAt, $0.usedUSD, $0.limitUSD, now) })
        else { return quota }
        var result = quota
        result.gauges = quota.gauges.map { gauge in
            guard hasReset(gauge.resetsAt, gauge.usedUSD, gauge.limitUSD, now) else { return gauge }
            var reset = gauge
            reset.fraction = 0
            reset.resetsAt = nil
            if reset.limitUSD != nil { reset.usedUSD = 0 }
            return reset
        }
        return result
    }

    /// Whether this gauge is a window read as reset here: opened at a reset that has passed, and
    /// with no reset of its own until a reading names one.
    public static func isReopened(_ gauge: UsageQuota.Gauge) -> Bool {
        gauge.resetsAt == nil && gauge.startsAt != nil
            && !(gauge.usedUSD != nil && gauge.limitUSD == nil)
    }

    private static func hasReset(
        _ resetsAt: Date?, _ usedUSD: Double?, _ limitUSD: Double?, _ now: Date
    ) -> Bool {
        guard let resetsAt, resetsAt <= now else { return false }
        return !(usedUSD != nil && limitUSD == nil)
    }
}
