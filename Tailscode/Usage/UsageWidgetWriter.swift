import CodingAgentKit
import Foundation
import WidgetKit

extension UsageWidgetStore {
    static func writeLive(_ quotas: [UsageQuota]) {
        for quota in quotas {
            let gauges = quota.gauges.prefix(3).map { gauge in
                UsageWidgetEntry.GaugeSnapshot(
                    label: gauge.label,
                    fraction: gauge.fraction,
                    percentText: "\(Int((gauge.fraction * 100).rounded()))%",
                    caption: resetCaption(gauge),
                    resetsAt: gauge.resetsAt)
            }
            let provider = UsageWidgetEntry.ProviderSnapshot(
                providerName: quota.providerName,
                subtitle: quota.subtitle,
                isLive: quota.live,
                gauges: Array(gauges))
            upsertProvider(provider)
        }
    }

    static func writeOpencode(gauges: [UsageWidgetEntry.GaugeSnapshot]) {
        let provider = UsageWidgetEntry.ProviderSnapshot(
            providerName: "opencode go",
            subtitle: "$10/mo · estimated",
            isLive: false,
            gauges: gauges)
        upsertProvider(provider)
    }

    private static func resetCaption(_ gauge: UsageQuota.Gauge) -> String {
        guard let resetsAt = gauge.resetsAt else { return "" }
        let prefix = gauge.trustedReset ? "resets " : "~resets "
        let seconds = max(0, resetsAt.timeIntervalSinceNow)
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(prefix)\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(prefix)\(hours)h \(minutes % 60)m" }
        return "\(prefix)\(hours / 24)d \(hours % 24)h"
    }
}
