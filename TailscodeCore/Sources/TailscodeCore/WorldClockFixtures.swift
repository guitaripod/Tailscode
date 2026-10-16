import CodingAgentKit
import Foundation

/// A world clock with something to say, for a debug launch with no tailnet and no pins:
/// `TAILSCODE_CLOCK_FIXTURES=1` pins Tokyo and San Francisco, puts three machines on the glance (one
/// of them a minute off) and a quota window about to reopen. It is how the glance and the sheet
/// are looked at without a fleet, the way `UpdateFixtures` does for updates.
public enum WorldClockFixtures {
    public static let environmentKey = "TAILSCODE_CLOCK_FIXTURES"

    public static var isOn: Bool {
        ProcessInfo.processInfo.environment[environmentKey] == "1"
    }

    public static var preferences: WorldClockPreferences {
        WorldClockPreferences(pins: ["tokyo", "san-francisco"], style: .h24)
    }

    public static let machines: [MachineClock] = [
        MachineClock(name: "arch", skew: 0.2),
        MachineClock(name: "macbook", skew: 1.8),
        MachineClock(name: "box", skew: -47),
    ]

    public static func holdings(now: Date) -> [QuotaHolding] {
        let gauge = UsageQuota.Gauge(
            key: "5-hour", label: "5-hour", fraction: 0.92,
            resetsAt: now.addingTimeInterval(2 * 3600 + 45 * 60), trustedReset: true,
            usedUSD: nil, limitUSD: nil)
        return [
            QuotaHolding(
                quota: UsageQuota(
                    providerName: "Claude", subtitle: "", source: "fixture", live: true,
                    gauges: [gauge], details: []),
                machines: ["arch"])
        ]
    }
}
