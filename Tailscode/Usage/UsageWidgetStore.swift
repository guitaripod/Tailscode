import Foundation
import WidgetKit

struct UsageWidgetEntry: Codable, TimelineEntry {
    var date: Date
    var providers: [ProviderSnapshot]
    var isStale: Bool

    var relevance: TimelineEntryRelevance? {
        let maxFrac = providers.flatMap(\.gauges).map(\.fraction).max() ?? 0
        guard maxFrac > 0 else { return nil }
        return TimelineEntryRelevance(score: Float(maxFrac), duration: 900)
    }

    struct ProviderSnapshot: Codable, Hashable {
        var providerName: String
        var subtitle: String
        var isLive: Bool
        var gauges: [GaugeSnapshot]
    }

    struct GaugeSnapshot: Codable, Hashable {
        var label: String
        var fraction: Double
        var percentText: String
        var caption: String
        var resetsAt: Date?
    }
}

enum UsageWidgetStore {
    static let suiteName = "group.com.guitaripod.tailscode"
    private static let providersKey = "usage_providers"
    private static let pendingRouteKey = "pending_control_route"
    static let kind = "UsageWidget"

    /// Written by the Top Usage control's App Intent; read+cleared by the app on foreground.
    static func setPendingControlRoute(_ route: String) {
        UserDefaults(suiteName: suiteName)?.set(route, forKey: pendingRouteKey)
    }

    static func takePendingControlRoute() -> String? {
        let defaults = UserDefaults(suiteName: suiteName)
        guard let route = defaults?.string(forKey: pendingRouteKey) else { return nil }
        defaults?.removeObject(forKey: pendingRouteKey)
        return route
    }

    static func read() -> UsageWidgetEntry? {
        guard let data = UserDefaults(suiteName: suiteName)?.data(forKey: providersKey),
            let stored = try? JSONDecoder().decode(Storage.self, from: data),
            !stored.providers.isEmpty
        else { return nil }
        let age = Date().timeIntervalSince(stored.updatedAt)
        return UsageWidgetEntry(
            date: stored.updatedAt, providers: stored.providers, isStale: age > 300)
    }

    static func previewEntry() -> UsageWidgetEntry {
        let now = Date()
        return UsageWidgetEntry(
            date: now,
            providers: [
                UsageWidgetEntry.ProviderSnapshot(
                    providerName: "Claude Code",
                    subtitle: "Max 20x",
                    isLive: true,
                    gauges: [
                        UsageWidgetEntry.GaugeSnapshot(label: "Token input", fraction: 0.47, percentText: "47%", caption: "resets 1h 15m", resetsAt: now.addingTimeInterval(4500)),
                        UsageWidgetEntry.GaugeSnapshot(label: "Token output", fraction: 0.32, percentText: "32%", caption: "resets 4h", resetsAt: now.addingTimeInterval(14400)),
                        UsageWidgetEntry.GaugeSnapshot(label: "Cache write", fraction: 0.18, percentText: "18%", caption: "resets 12h", resetsAt: now.addingTimeInterval(43200)),
                    ]),
                UsageWidgetEntry.ProviderSnapshot(
                    providerName: "Grok",
                    subtitle: "X Premium+",
                    isLive: true,
                    gauges: [
                        UsageWidgetEntry.GaugeSnapshot(label: "Chat messages", fraction: 0.12, percentText: "12%", caption: "resets 45m", resetsAt: now.addingTimeInterval(2700)),
                        UsageWidgetEntry.GaugeSnapshot(label: "Reasoning", fraction: 0.05, percentText: "5%", caption: "resets 45m", resetsAt: now.addingTimeInterval(2700)),
                    ]),
                UsageWidgetEntry.ProviderSnapshot(
                    providerName: "opencode go",
                    subtitle: "$10/mo \u{00b7} estimated",
                    isLive: false,
                    gauges: [
                        UsageWidgetEntry.GaugeSnapshot(label: "5-hour", fraction: 0.28, percentText: "28%", caption: "$3.42 / $12 \u{00b7} 12 req", resetsAt: nil),
                        UsageWidgetEntry.GaugeSnapshot(label: "Weekly", fraction: 0.14, percentText: "14%", caption: "$4.20 / $30 \u{00b7} 12 req", resetsAt: nil),
                        UsageWidgetEntry.GaugeSnapshot(label: "Monthly", fraction: 0.05, percentText: "5%", caption: "$3.00 / $60 \u{00b7} 12 req", resetsAt: nil),
                    ]),
            ],
            isStale: false)
    }

    private struct Storage: Codable {
        var providers: [UsageWidgetEntry.ProviderSnapshot]
        var updatedAt: Date
    }

    static func upsertProvider(_ provider: UsageWidgetEntry.ProviderSnapshot) {
        var providers: [UsageWidgetEntry.ProviderSnapshot] = []
        if let data = UserDefaults(suiteName: suiteName)?.data(forKey: providersKey),
            let stored = try? JSONDecoder().decode(Storage.self, from: data)
        {
            providers = stored.providers.filter { $0.providerName != provider.providerName }
        }
        providers.append(provider)
        let storage = Storage(providers: providers, updatedAt: Date())
        guard let data = try? JSONEncoder().encode(storage) else { return }
        UserDefaults(suiteName: suiteName)?.set(data, forKey: providersKey)
        WidgetCenter.shared.reloadTimelines(ofKind: kind)
    }
}
