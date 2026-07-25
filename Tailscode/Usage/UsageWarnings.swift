import CodingAgentKit
import Foundation

/// Warns once when a usage window is nearly spent, on whichever surface lands
/// the numbers first — the foreground fetch, the background refresh, or a silent
/// push. Running out of quota mid-task is the failure a phone user can do
/// something about (switch model, wait for the reset), but only if they hear
/// about it before the agent stops.
@MainActor
enum UsageWarnings {
    static let threshold = 0.9

    private static let firedKey = "usage_warning_fired"
    private static let horizon: TimeInterval = 14 * 24 * 3600

    private struct Gauge {
        let provider: String
        let label: String
        let fraction: Double
        let resetsAt: Date?
    }

    static func evaluate(quotas: [UsageQuota]) {
        evaluate(
            quotas.flatMap { quota in
                quota.gauges.map {
                    Gauge(
                        provider: quota.providerName, label: $0.label, fraction: $0.fraction,
                        resetsAt: $0.resetsAt)
                }
            })
    }

    static func evaluate(providers: [UsageWidgetEntry.ProviderSnapshot]) {
        evaluate(
            providers.flatMap { provider in
                provider.gauges.map {
                    Gauge(
                        provider: provider.providerName, label: $0.label, fraction: $0.fraction,
                        resetsAt: $0.resetsAt)
                }
            })
    }

    private static func evaluate(_ gauges: [Gauge]) {
        guard AppPreferences.notifyUsageWarnings else { return }
        guard let hottest = gauges.filter({ $0.fraction >= threshold })
            .max(by: { $0.fraction < $1.fraction })
        else { return }
        let key = identity(for: hottest)
        var fired = firedWindows()
        guard fired[key] == nil else { return }
        fired[key] = Date().timeIntervalSince1970
        store(fired)
        let percent = Int((hottest.fraction * 100).rounded())
        let reset = hottest.resetsAt.map {
            " · " + UsageGaugeFormat.resetCaption(resetsAt: $0, trustedReset: true)
        } ?? ""
        NotificationManager.notify(
            kind: .usage,
            title: "\(hottest.provider) is \(percent)% used",
            body: "\(hottest.label)\(reset)",
            identifier: "usage:\(key)")
        AppLogger.session.info("usage warning raised for \(key) at \(percent)%")
    }

    /// One warning per window, not per fetch: a gauge sits above the threshold
    /// for hours, and every refresh in between must stay silent. The reset time
    /// makes each window distinct, so the next one warns again; an estimated
    /// gauge with no reset falls back to one warning per calendar day.
    private static func identity(for gauge: Gauge) -> String {
        let window =
            gauge.resetsAt.map { String(Int($0.timeIntervalSince1970)) }
            ?? String(Int(Date().timeIntervalSince1970 / 86400))
        return "\(gauge.provider)|\(gauge.label)|\(window)"
    }

    private static func firedWindows() -> [String: Double] {
        let defaults = UserDefaults(suiteName: UsageWidgetStore.suiteName)
        return defaults?.dictionary(forKey: firedKey) as? [String: Double] ?? [:]
    }

    private static func store(_ fired: [String: Double]) {
        let cutoff = Date().timeIntervalSince1970 - horizon
        let pruned = fired.filter { $0.value > cutoff }
        UserDefaults(suiteName: UsageWidgetStore.suiteName)?.set(pruned, forKey: firedKey)
    }
}
