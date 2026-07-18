import Foundation

enum UsageGaugeFormat {
    static func percentText(fraction: Double) -> String {
        "\(Int((fraction * 100).rounded()))%"
    }

    static func resetCaption(resetsAt: Date?, trustedReset: Bool) -> String {
        guard let resetsAt else { return "" }
        let prefix = trustedReset ? "resets " : "~resets "
        let seconds = max(0, resetsAt.timeIntervalSinceNow)
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(prefix)\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(prefix)\(hours)h \(minutes % 60)m" }
        return "\(prefix)\(hours / 24)d \(hours % 24)h"
    }
}

/// Decodes the bridge's push `usage` payload without CodingAgentKit, so the
/// notification service extension can refresh the usage widget from a push
/// alone. The snapshot shape mirrors the bridge's `/usage` response.
enum UsagePushPayload {
    struct Snapshot: Codable {
        struct Gauge: Codable {
            var key: String
            var label: String
            var fraction: Double
            var resetsAt: Date?
            var trustedReset: Bool
        }
        struct Detail: Codable {
            var key: String
            var value: String
        }
        var providerName: String
        var subtitle: String
        var source: String
        var live: Bool
        var gauges: [Gauge]
        var details: [Detail]
    }

    private struct Payload: Codable {
        var claude: Snapshot?
        var grok: Snapshot?
    }

    static func providers(from userInfo: [AnyHashable: Any]) -> [UsageWidgetEntry.ProviderSnapshot] {
        guard let usage = userInfo["usage"],
            JSONSerialization.isValidJSONObject(usage),
            let data = try? JSONSerialization.data(withJSONObject: usage)
        else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let payload = try? decoder.decode(Payload.self, from: data) else { return [] }
        return [payload.claude, payload.grok]
            .compactMap { $0 }
            .filter { $0.live && !$0.gauges.isEmpty }
            .map { snapshot in
                UsageWidgetEntry.ProviderSnapshot(
                    providerName: snapshot.providerName,
                    subtitle: snapshot.subtitle,
                    isLive: snapshot.live,
                    gauges: snapshot.gauges.prefix(3).map { gauge in
                        UsageWidgetEntry.GaugeSnapshot(
                            label: gauge.label,
                            fraction: gauge.fraction,
                            percentText: UsageGaugeFormat.percentText(fraction: gauge.fraction),
                            caption: UsageGaugeFormat.resetCaption(
                                resetsAt: gauge.resetsAt, trustedReset: gauge.trustedReset),
                            resetsAt: gauge.resetsAt)
                    })
            }
    }

    /// Writes any pushed snapshots to the widget store; the timeline reload is
    /// throttled through app-group defaults because the notification service
    /// process dies between pushes.
    @discardableResult
    static func apply(userInfo: [AnyHashable: Any]) -> Int {
        let providers = providers(from: userInfo)
        guard !providers.isEmpty else { return 0 }
        for provider in providers {
            UsageWidgetStore.upsertProvider(provider, reload: false)
        }
        UsageWidgetStore.reloadTimelinesThrottled()
        return providers.count
    }
}
