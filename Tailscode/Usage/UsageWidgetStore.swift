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
        /// Money actually spent / the window's ceiling when the provider reports them. `usedUSD`
        /// without `limitUSD` marks a balance rather than a window — the renderers skip the bar
        /// and show the money itself.
        var usedUSD: Double? = nil
        var limitUSD: Double? = nil
        /// ISO code of the money when it is not USD (a prepaid balance may report CNY).
        var currency: String? = nil
    }
}

enum UsageWidgetStore {
    static let suiteName = "group.com.guitaripod.tailscode"
    private static let providersKey = "usage_providers"
    private static let pendingRouteKey = "pending_control_route"
    static let kind = "UsageWidget"

    /// How many windows one provider keeps in the snapshot. The large family draws every one it is
    /// given, and a provider that meters four windows (a session, a week, a week per model) used to
    /// lose its fourth on the way in — before any widget got to decide whether it had room.
    static let storedGaugeLimit = 5

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
                        previewGauge("Token input", 0.47, "47%", resetsIn: 4500, from: now),
                        previewGauge("Token output", 0.32, "32%", resetsIn: 14400, from: now),
                        previewGauge("Cache write", 0.18, "18%", resetsIn: 43200, from: now),
                    ]),
                UsageWidgetEntry.ProviderSnapshot(
                    providerName: "Grok",
                    subtitle: "X Premium+",
                    isLive: true,
                    gauges: [
                        previewGauge("Chat messages", 0.12, "12%", resetsIn: 2700, from: now),
                        previewGauge("Reasoning", 0.05, "5%", resetsIn: 2700, from: now),
                    ]),
                UsageWidgetEntry.ProviderSnapshot(
                    providerName: "opencode go",
                    subtitle: "$10/mo",
                    isLive: true,
                    gauges: [
                        previewSpendGauge("5-hour", 0.28, "28%", spend: "$3.42", cap: "$12", resetsIn: 5400, from: now),
                        previewSpendGauge("Weekly", 0.14, "14%", spend: "$4.20", cap: "$30", resetsIn: 14400, from: now),
                        previewSpendGauge("Monthly", 0.08, "8%", spend: "$4.80", cap: "$60", resetsIn: 43200, from: now),
                    ]),
                UsageWidgetEntry.ProviderSnapshot(
                    providerName: "DeepSeek",
                    subtitle: "Prepaid balance · direct API",
                    isLive: true,
                    gauges: [
                        UsageWidgetEntry.GaugeSnapshot(
                            label: "Balance", fraction: 0, percentText: "$104.32",
                            caption: "Topped up $100.00 · granted $4.32", resetsAt: nil,
                            usedUSD: 104.32, limitUSD: nil)
                    ]),
            ],
            isStale: false)
    }

    private static func previewGauge(
        _ label: String, _ fraction: Double, _ percentText: String,
        resetsIn: TimeInterval, from: Date
    ) -> UsageWidgetEntry.GaugeSnapshot {
        let resetsAt = from.addingTimeInterval(resetsIn)
        return UsageWidgetEntry.GaugeSnapshot(
            label: label, fraction: fraction, percentText: percentText,
            caption: UsageGaugeFormat.resetCaption(resetsAt: resetsAt, trustedReset: true),
            resetsAt: resetsAt)
    }

    private static func previewSpendGauge(
        _ label: String, _ fraction: Double, _ percentText: String, spend: String, cap: String,
        resetsIn: TimeInterval, from: Date
    ) -> UsageWidgetEntry.GaugeSnapshot {
        var gauge = previewGauge(label, fraction, percentText, resetsIn: resetsIn, from: from)
        gauge.caption = String(localized: "\(spend) / \(cap)") + " · " + gauge.caption
        return gauge
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

    /// Drops any provider whose numbers this device worked out for itself rather than read from
    /// the account. The phone used to replay opencode sessions against guessed windows and store
    /// the result beside the real readings, where it was indistinguishable from one; nothing writes
    /// an estimate any more, but an install that has one keeps rendering it until it is dropped.
    static func dropEstimates(reload: Bool = true) {
        var removed = false
        withProvidersLock {
            guard let data = UserDefaults(suiteName: suiteName)?.data(forKey: providersKey),
                let stored = try? JSONDecoder().decode(Storage.self, from: data)
            else { return }
            let remaining = stored.providers.filter {
                !$0.subtitle.lowercased().contains("estimated")
            }
            guard remaining.count != stored.providers.count else { return }
            let storage = Storage(providers: remaining, updatedAt: stored.updatedAt)
            guard let encoded = try? JSONEncoder().encode(storage) else { return }
            UserDefaults(suiteName: suiteName)?.set(encoded, forKey: providersKey)
            removed = true
        }
        if removed, reload { WidgetCenter.shared.reloadTimelines(ofKind: kind) }
    }

    /// Drops a provider's stored gauges, for when the thing behind them is gone — a DeepSeek key
    /// the user just deleted has no balance to report, and showing yesterday's is worse than
    /// showing nothing.
    static func removeProvider(named name: String, reload: Bool = true) {
        var removed = false
        withProvidersLock {
            guard let data = UserDefaults(suiteName: suiteName)?.data(forKey: providersKey),
                let stored = try? JSONDecoder().decode(Storage.self, from: data),
                stored.providers.contains(where: { $0.providerName == name })
            else { return }
            let remaining = stored.providers.filter { $0.providerName != name }
            let storage = Storage(providers: remaining, updatedAt: stored.updatedAt)
            guard let encoded = try? JSONEncoder().encode(storage) else { return }
            UserDefaults(suiteName: suiteName)?.set(encoded, forKey: providersKey)
            removed = true
        }
        if removed, reload { WidgetCenter.shared.reloadTimelines(ofKind: kind) }
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
