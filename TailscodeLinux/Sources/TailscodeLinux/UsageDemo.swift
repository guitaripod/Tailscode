import CodingAgentKit
import Foundation
import TailscodeCore

/// The strip's states, on demand. A footer that reports an account can only be looked at in the
/// state that account happens to be in, and the states worth checking are the ones nobody can
/// arrange — every window at the wall, a balance run dry, a poll that stopped answering. These
/// are the same reports a server would hand over, so what the driver renders is the real strip
/// rather than a picture of one.
enum UsageDemo {
    static func glance(named name: String) -> QuotaGlance? {
        let now = Date()
        switch name {
        case "checking":
            return QuotaGlance.make(from: [], answeredAt: nil, now: now)
        case "none":
            return QuotaGlance.make(from: [], answeredAt: now, now: now)
        case "clear":
            return QuotaGlance.make(
                from: [
                    ("arch", claude(session: 0.12, weekly: 0.31, now: now)),
                    ("arch", grok(0.2, now: now)),
                    ("", balance(9.41)),
                ], answeredAt: now, now: now)
        case "warm":
            return QuotaGlance.make(
                from: [
                    ("arch", claude(session: 0.72, weekly: 0.88, now: now)),
                    ("arch", grok(0.64, now: now)),
                    ("", balance(9.41)),
                ], answeredAt: now, now: now)
        case "wall":
            return QuotaGlance.make(
                from: [
                    ("arch", claude(session: 0.41, weekly: 1.0, now: now)),
                    ("arch", grok(0.35, now: now)),
                    ("", balance(9.41)),
                ], answeredAt: now, now: now)
        case "walls":
            return QuotaGlance.make(
                from: [
                    ("arch", claude(session: 1.0, weekly: 1.0, now: now)),
                    ("arch", grok(1.0, now: now)),
                    ("macbook", opencode(1.0, now: now)),
                    ("", balance(0)),
                ], answeredAt: now, now: now)
        case "stale":
            return QuotaGlance.make(
                from: [("arch", claude(session: 0.44, weekly: 0.52, now: now))],
                answeredAt: now.addingTimeInterval(-2_700), now: now)
        case "long":
            return QuotaGlance.make(
                from: [
                    ("arch", named("Anthropic Claude Max 20x", session: 0.99, weekly: 1.0, now: now))
                ], answeredAt: now, now: now)
        default:
            return nil
        }
    }

    private static func claude(session: Double, weekly: Double, now: Date) -> UsageQuota {
        named("Claude", session: session, weekly: weekly, now: now)
    }

    private static func named(_ provider: String, session: Double, weekly: Double, now: Date)
        -> UsageQuota
    {
        UsageQuota(
            providerName: provider, subtitle: "Max 20x", source: "claude.ai", live: true,
            gauges: [
                UsageQuota.Gauge(
                    key: "session", label: "5-hour session", fraction: session,
                    resetsAt: now.addingTimeInterval(7_200), trustedReset: true),
                UsageQuota.Gauge(
                    key: "weekly", label: "Weekly", fraction: weekly,
                    resetsAt: now.addingTimeInterval(190_000), trustedReset: true),
            ],
            details: [])
    }

    private static func grok(_ fraction: Double, now: Date) -> UsageQuota {
        UsageQuota(
            providerName: "Grok", subtitle: "SuperGrok", source: "x.ai", live: true,
            gauges: [
                UsageQuota.Gauge(
                    key: "weekly", label: "Weekly credits", fraction: fraction,
                    resetsAt: now.addingTimeInterval(100_000), trustedReset: true)
            ],
            details: [])
    }

    private static func opencode(_ fraction: Double, now: Date) -> UsageQuota {
        UsageQuota(
            providerName: "opencode go", subtitle: "$10/mo", source: "estimated · opencode.db",
            live: false,
            gauges: [
                UsageQuota.Gauge(
                    key: "weekly", label: "Weekly", fraction: fraction,
                    resetsAt: now.addingTimeInterval(230_000), trustedReset: false,
                    usedUSD: 30, limitUSD: 30)
            ],
            details: [])
    }

    private static func balance(_ total: Double) -> UsageQuota {
        UsageQuota(
            providerName: "DeepSeek", subtitle: "", source: "api.deepseek.com", live: true,
            gauges: [
                UsageQuota.Gauge(
                    key: "balance", label: "Balance", fraction: total > 0 ? 0 : 1, resetsAt: nil,
                    trustedReset: false, usedUSD: total, limitUSD: nil, currency: "USD")
            ],
            details: [])
    }
}
