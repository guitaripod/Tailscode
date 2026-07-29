import CodingAgentKit
import Foundation
import WidgetKit

extension UsageWidgetStore {
    static let opencodeProviderName = "opencode go"

    static func writeLive(_ quotas: [UsageQuota], reload: Bool = true) {
        for quota in quotas {
            let gauges = quota.gauges.prefix(3).map { gauge in
                UsageWidgetEntry.GaugeSnapshot(
                    label: gauge.label,
                    fraction: gauge.fraction,
                    percentText: UsageGaugeFormat.percentText(fraction: gauge.fraction),
                    caption: UsageGaugeFormat.resetCaption(
                        resetsAt: gauge.resetsAt, trustedReset: gauge.trustedReset),
                    resetsAt: gauge.resetsAt)
            }
            let provider = UsageWidgetEntry.ProviderSnapshot(
                providerName: quota.providerName,
                subtitle: quota.subtitle,
                isLive: quota.live,
                gauges: Array(gauges))
            upsertProvider(provider, reload: reload)
        }
    }

    /// The last numbers any surface landed — the background refresh, a silent
    /// push, the widget, or an earlier foreground pass — rebuilt as quotas. Every
    /// screen seeds from this before fetching, so usage is never blank while a
    /// scan that takes seconds (or a whole rate-limited minute) runs.
    static func cachedQuotas() -> [UsageQuota] {
        guard let entry = read() else { return [] }
        return entry.providers.map { provider in
            UsageQuota(
                providerName: provider.providerName,
                subtitle: provider.subtitle,
                source: "last snapshot",
                live: provider.isLive,
                gauges: provider.gauges.map { gauge in
                    UsageQuota.Gauge(
                        key: gauge.label, label: gauge.label, fraction: gauge.fraction,
                        resetsAt: gauge.resetsAt, trustedReset: provider.isLive)
                },
                details: [])
        }
    }

    static func writeOpencode(gauges: [UsageWidgetEntry.GaugeSnapshot], reload: Bool = true) {
        let provider = UsageWidgetEntry.ProviderSnapshot(
            providerName: opencodeProviderName,
            subtitle: String(localized: "$10/mo · estimated"),
            isLive: false,
            gauges: gauges)
        upsertProvider(provider, reload: reload)
    }
}
