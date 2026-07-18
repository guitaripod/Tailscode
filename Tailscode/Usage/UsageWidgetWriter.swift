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

    static func writeOpencode(gauges: [UsageWidgetEntry.GaugeSnapshot], reload: Bool = true) {
        let provider = UsageWidgetEntry.ProviderSnapshot(
            providerName: opencodeProviderName,
            subtitle: "$10/mo · estimated",
            isLive: false,
            gauges: gauges)
        upsertProvider(provider, reload: reload)
    }
}
