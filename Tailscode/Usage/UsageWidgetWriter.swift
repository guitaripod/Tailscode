import CodingAgentKit
import Foundation
import TailscodeCore
import WidgetKit

extension UsageWidgetStore {
    static let opencodeProviderName = "opencode go"

    static func writeLive(_ quotas: [UsageQuota], reload: Bool = true) {
        for quota in quotas {
            let gauges = quota.gauges.prefix(storedGaugeLimit).map { gauge in
                var caption = UsageGaugeFormat.resetCaption(
                    resetsAt: gauge.resetsAt, trustedReset: gauge.trustedReset)
                if let used = gauge.usedUSD, let limit = gauge.limitUSD {
                    let spend = "\(currency(used)) / \(currency(limit))"
                    caption = caption.isEmpty ? spend : spend + " · " + caption
                }
                return UsageWidgetEntry.GaugeSnapshot(
                    label: gauge.label,
                    fraction: gauge.fraction,
                    percentText: UsageGaugeFormat.percentText(fraction: gauge.fraction),
                    caption: caption,
                    resetsAt: gauge.resetsAt,
                    usedUSD: gauge.usedUSD,
                    limitUSD: gauge.limitUSD,
                    currency: gauge.currency)
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
                        resetsAt: gauge.resetsAt, trustedReset: provider.isLive,
                        usedUSD: gauge.usedUSD, limitUSD: gauge.limitUSD,
                        currency: gauge.currency)
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

    private static func currency(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }
}

extension UsageWidgetEntry {
    /// The stored snapshot as the shared reading takes it. The widget process has no backend to
    /// ask, so every family renders from this and from nothing else.
    var widgetQuotas: [WidgetQuota] {
        providers.map { provider in
            WidgetQuota(
                providerName: provider.providerName,
                subtitle: provider.subtitle,
                isLive: provider.isLive,
                gauges: provider.gauges.map { gauge in
                    WidgetQuota.Gauge(
                        label: gauge.label,
                        fraction: gauge.fraction,
                        resetsAt: gauge.resetsAt,
                        trustedReset: provider.isLive,
                        usedUSD: gauge.usedUSD,
                        limitUSD: gauge.limitUSD,
                        currency: gauge.currency,
                        note: gauge.caption)
                })
        }
    }

    func glance(
        grouping: WidgetGrouping = .automatic, detail: WidgetDetail = .automatic,
        providerFilter: Set<String>? = nil, now: Date = Date()
    ) -> WidgetGlance {
        WidgetGlance.make(
            quotas: widgetQuotas, updatedAt: date, now: now, grouping: grouping, detail: detail,
            providerFilter: providerFilter)
    }
}
