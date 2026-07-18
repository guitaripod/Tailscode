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

    /// `reload: false` is for writes made from inside the widget's own timeline
    /// provider, where a `reloadTimelines` call would loop.
    static func upsertProvider(_ provider: UsageWidgetEntry.ProviderSnapshot, reload: Bool = true) {
        withProvidersLock {
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
        }
        if reload { WidgetCenter.shared.reloadTimelines(ofKind: kind) }
    }

    /// The app, the widget, and the notification service extension all
    /// read-modify-write the provider list from separate processes; an exclusive
    /// flock on a file in the shared container keeps a concurrent writer from
    /// dropping another's provider. Runs unlocked if the container is unavailable.
    private static func withProvidersLock(_ body: () -> Void) {
        guard
            let container = FileManager.default.containerURL(
                forSecurityApplicationGroupIdentifier: suiteName)
        else {
            body()
            return
        }
        let lockPath = container.appendingPathComponent("usage_providers.lock").path
        let descriptor = open(lockPath, O_CREAT | O_WRONLY, 0o644)
        guard descriptor >= 0 else {
            body()
            return
        }
        let locked = flock(descriptor, LOCK_EX) == 0
        body()
        if locked { flock(descriptor, LOCK_UN) }
        close(descriptor)
    }

    private static let lastThrottledReloadKey = "usage_push_last_reload"
    private static let throttledReloadInterval: TimeInterval = 1800

    /// Budget-friendly reload for background paths (pushes, `BGAppRefreshTask`):
    /// the system grants widgets only a few dozen reloads a day, so unattended
    /// refreshes coalesce through a shared app-group timestamp.
    static func reloadTimelinesThrottled() {
        let defaults = UserDefaults(suiteName: suiteName)
        let last = defaults?.double(forKey: lastThrottledReloadKey) ?? 0
        let now = Date().timeIntervalSince1970
        guard now - last >= throttledReloadInterval else { return }
        defaults?.set(now, forKey: lastThrottledReloadKey)
        WidgetCenter.shared.reloadTimelines(ofKind: kind)
    }
}
