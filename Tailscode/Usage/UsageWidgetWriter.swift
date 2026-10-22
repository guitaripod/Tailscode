import CodingAgentKit
import Foundation
import TailscodeCore
import WidgetKit

extension UsageWidgetStore {

    /// What a poll leaves in the snapshot. A measured reading replaces the one held for its
    /// account; a read that failed, or came back as an estimate, leaves the last good numbers
    /// where they are — the widget then wears them as cached — until they are too old to keep.
    static func writeLive(_ quotas: [UsageQuota], reload: Bool = true) {
        let now = Date()
        for quota in QuotaReports.admitted(quotas) {
            let heldAt = held(providerName: quota.providerName, accountID: quota.accountID)?.readAt
            switch QuotaKeeping.move(for: quota, heldAt: heldAt, now: now) {
            case .keep: continue
            case .drop:
                removeProvider(
                    providerName: quota.providerName, accountID: quota.accountID, reload: reload)
                continue
            case .write: break
            }
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
                gauges: Array(gauges),
                source: quota.source,
                accountID: quota.accountID,
                schema: quota.schema,
                readAt: now)
            upsertProvider(provider, reload: reload)
        }
    }

    /// The last numbers any surface landed — the background refresh, a silent
    /// push, the widget, or an earlier foreground pass — rebuilt as quotas. Every
    /// screen seeds from this before fetching, so usage is never blank while the
    /// live fetch is still out.
    static func cachedQuotas() -> [UsageQuota] {
        guard let entry = read() else { return [] }
        return entry.providers.map { provider in
            let readAt = provider.readAt ?? entry.date
            return UsageQuota(
                providerName: provider.providerName,
                subtitle: provider.subtitle,
                source: provider.source ?? "last snapshot",
                live: provider.isLive
                    && !QuotaFreshness.isStale(age: Date().timeIntervalSince(readAt)),
                gauges: provider.gauges.map { gauge in
                    UsageQuota.Gauge(
                        key: gauge.label, label: gauge.label, fraction: gauge.fraction,
                        resetsAt: gauge.resetsAt, trustedReset: provider.isLive,
                        usedUSD: gauge.usedUSD, limitUSD: gauge.limitUSD,
                        currency: gauge.currency)
                },
                details: [],
                accountID: provider.accountID,
                schema: provider.schema)
        }
    }

    /// The last good readings, with when each was taken, for a screen to serve while a poll fails.
    static func heldReadings() -> [HeldReading] {
        guard let entry = read() else { return [] }
        let quotas = cachedQuotas()
        return zip(quotas, entry.providers).map { quota, provider in
            HeldReading(server: "", quota: quota, readAt: provider.readAt ?? entry.date)
        }
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
                },
                readAt: provider.readAt)
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
