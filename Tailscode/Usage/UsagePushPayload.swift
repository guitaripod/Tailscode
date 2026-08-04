import Foundation

enum UsageGaugeFormat {
    static func percentText(fraction: Double) -> String {
        if fraction >= 1.0 { return String(localized: "Used up") }
        return "\(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
    }

    static func resetCaption(resetsAt: Date?, trustedReset: Bool) -> String {
        guard let resetsAt else { return "" }
        let remaining = remaining(until: resetsAt)
        return trustedReset
            ? String(localized: "resets \(remaining)")
            : String(localized: "~resets \(remaining)")
    }

    /// The caption under a Go gauge, whose numbers are dollars rather than a
    /// percentage of a plan the server can report.
    static func spendCaption(spend: String, cap: String, requests: Int) -> String {
        String(localized: "\(spend) / \(cap) · \(requests) req")
    }

    /// A gauge label as a person reads it. The Go window names travel English
    /// between the app, the widget and the notification service, which match on
    /// them; only the rendered form is translated. Labels a server sent are its
    /// own and pass through untouched.
    static func gaugeLabel(_ label: String) -> String {
        switch label {
        case "5-hour": return String(localized: "5-hour")
        case "Weekly": return String(localized: "Weekly")
        case "Monthly": return String(localized: "Monthly")
        default: return label
        }
    }

    private static func remaining(until date: Date) -> String {
        let minutes = Int(max(0, date.timeIntervalSinceNow) / 60)
        if minutes < 60 { return "\(minutes)m" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h \(minutes % 60)m" }
        return "\(hours / 24)d \(hours % 24)h"
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
