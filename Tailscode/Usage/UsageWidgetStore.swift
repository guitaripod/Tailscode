import Foundation
import Synchronization
import WidgetKit

/// Keeps a process from being suspended while it holds the usage providers lock.
///
/// iOS kills an app that is suspended holding a lock on a file in the shared container
/// (0xDEAD10CC), because any other process that then asks for the lock would wait forever. Only
/// the app installs one: an extension takes the lock only before it calls the completion that
/// keeps it running, and a Mac process is never suspended.
protocol UsageLockSuspensionGuard: Sendable {
    /// Starts holding the process awake, or nil when the system will not, because the process is
    /// already on its way to being suspended.
    func holdAwake(reason: String) -> (any UsageLockHold)?
}

/// One hold on the process, begun before the providers flock is asked for and released after it
/// is let go.
protocol UsageLockHold: Sendable {
    /// Whether the hold still keeps the process awake. A writer still waiting for the flock gives
    /// up once it does not.
    var isHolding: Bool { get }
    /// Records that the flock is now held, so that an expiration landing before ``release()``
    /// waits for the flock to be let go instead of letting the process be suspended with it.
    /// False when the hold has already ended, and the flock must be let go at once.
    func flockTaken() -> Bool
    /// Ends the hold, once, after the flock is let go.
    func release()
}

struct UsageWidgetEntry: Codable, TimelineEntry {
    var date: Date
    var providers: [ProviderSnapshot]

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
        var source: String? = nil
        var accountID: String? = nil
        var schema: Int? = nil
        /// When this provider was last actually read. A failed read leaves the snapshot alone, so
        /// the snapshot's own clock cannot speak for it; nil on a snapshot written before this
        /// existed, which is then as old as the file.
        var readAt: Date? = nil

        init(
            providerName: String, subtitle: String, isLive: Bool, gauges: [GaugeSnapshot],
            source: String? = nil, accountID: String? = nil, schema: Int? = nil,
            readAt: Date? = nil
        ) {
            self.providerName = providerName
            self.subtitle = subtitle
            self.isLive = isLive
            self.gauges = gauges
            self.source = source
            self.accountID = accountID
            self.schema = schema
            self.readAt = readAt
        }

        /// Whether this snapshot is the account named: the same provider and, when both name an
        /// account, the same account. A snapshot or a report that names none is the provider's
        /// only one.
        func covers(providerName other: String, accountID otherAccount: String?) -> Bool {
            providerName == other
                && ((accountID ?? "").isEmpty || (otherAccount ?? "").isEmpty
                    || accountID == otherAccount)
        }
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
    private static let lockFileName = "usage_providers.lock"
    static let kind = "UsageWidget"

    private static let suspensionGuard = Mutex<(any UsageLockSuspensionGuard)?>(nil)
    private static let inProcessLock = NSLock()

    /// Installs what keeps the process awake while it holds the providers lock. The app installs
    /// one at launch, before anything writes the snapshot.
    static func installSuspensionGuard(_ keeper: any UsageLockSuspensionGuard) {
        suspensionGuard.withLock { $0 = keeper }
    }

    /// How many windows one provider keeps in the snapshot. The large family draws every one it is
    /// given, and a provider that meters four windows (a session, a week, a week per model) used to
    /// lose its fourth on the way in — before any widget got to decide whether it had room.
    static let storedGaugeLimit = 5

    /// Posted on the main queue each time a control's intent leaves a route. Only the app listens:
    /// its intent may run while the app is already in front, where no foreground comes to read it.
    static let controlRouteDidPark = Notification.Name("tailscode.controlRoute.didPark")

    /// Written by the Top Usage and Quick Ask controls' App Intents; read+cleared by the app on
    /// foreground, or at once when the app is the process that ran the intent.
    static func setPendingControlRoute(_ route: String) {
        UserDefaults(suiteName: suiteName)?.set(route, forKey: pendingRouteKey)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: controlRouteDidPark, object: nil)
        }
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
        return UsageWidgetEntry(date: stored.updatedAt, providers: stored.providers)
    }

    static func previewEntry() -> UsageWidgetEntry {
        let now = Date()
        return UsageWidgetEntry(
            date: now,
            providers: [
                UsageWidgetEntry.ProviderSnapshot(
                    providerName: "Claude Code",
                    subtitle: "Ultra",
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
            ])
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
                providers = stored.providers.filter {
                    !$0.covers(providerName: provider.providerName, accountID: provider.accountID)
                }
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
    /// an estimate any more. An opencode snapshot written before the usage schema is dropped too,
    /// because it cannot carry the account identity or exact windows the current bridge sends; the
    /// next refresh puts the live card back.
    static func dropEstimates(reload: Bool = true) {
        guard storedProviders().contains(where: isEstimate) else { return }
        var removed = false
        withProvidersLock {
            guard let data = UserDefaults(suiteName: suiteName)?.data(forKey: providersKey),
                let stored = try? JSONDecoder().decode(Storage.self, from: data)
            else { return }
            let remaining = stored.providers.filter { !isEstimate($0) }
            guard remaining.count != stored.providers.count else { return }
            let storage = Storage(providers: remaining, updatedAt: stored.updatedAt)
            guard let encoded = try? JSONEncoder().encode(storage) else { return }
            UserDefaults(suiteName: suiteName)?.set(encoded, forKey: providersKey)
            removed = true
        }
        if removed, reload { WidgetCenter.shared.reloadTimelines(ofKind: kind) }
    }

    /// Whether a snapshot is one ``dropEstimates(reload:)`` drops: worked out on this device, or
    /// an opencode snapshot from before the usage schema.
    private static func isEstimate(_ provider: UsageWidgetEntry.ProviderSnapshot) -> Bool {
        let fromEstimate =
            provider.subtitle.lowercased().contains("estimated")
            || provider.source?.lowercased().contains("estimated") == true
        let oldOpenCode =
            provider.providerName.lowercased().contains("opencode") && provider.schema == nil
        return fromEstimate || oldOpenCode
    }

    /// The stored providers, read without the lock. Only the removals use it, to skip the lock
    /// when there is nothing to remove: a removal that loses a race to a writer adding the same
    /// provider back ends the same as one that ran before it.
    private static func storedProviders() -> [UsageWidgetEntry.ProviderSnapshot] {
        guard let data = UserDefaults(suiteName: suiteName)?.data(forKey: providersKey),
            let stored = try? JSONDecoder().decode(Storage.self, from: data)
        else { return [] }
        return stored.providers
    }

    /// The stored snapshot of an account and when it was read.
    static func held(
        providerName: String, accountID: String?
    ) -> (snapshot: UsageWidgetEntry.ProviderSnapshot, readAt: Date)? {
        guard let data = UserDefaults(suiteName: suiteName)?.data(forKey: providersKey),
            let stored = try? JSONDecoder().decode(Storage.self, from: data),
            let snapshot = stored.providers.first(where: {
                $0.covers(providerName: providerName, accountID: accountID)
            })
        else { return nil }
        return (snapshot, snapshot.readAt ?? stored.updatedAt)
    }

    /// Drops the stored snapshot of an account, once it is too old to keep.
    static func removeProvider(providerName: String, accountID: String?, reload: Bool = true) {
        guard
            storedProviders().contains(where: {
                $0.covers(providerName: providerName, accountID: accountID)
            })
        else { return }
        var removed = false
        withProvidersLock {
            guard let data = UserDefaults(suiteName: suiteName)?.data(forKey: providersKey),
                let stored = try? JSONDecoder().decode(Storage.self, from: data)
            else { return }
            let remaining = stored.providers.filter {
                !$0.covers(providerName: providerName, accountID: accountID)
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
        guard storedProviders().contains(where: { $0.providerName == name }) else { return }
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

    /// The app, the widget, and the notification service extension all read-modify-write the
    /// provider list from separate processes; an exclusive flock on a file in the shared container
    /// keeps a concurrent writer from dropping another's provider.
    private static func withProvidersLock(_ body: () -> Void) {
        withProvidersLock(
            lockFile: providersLockFile, keeper: suspensionGuard.withLock { $0 }, body)
    }

    /// The file the providers flock is taken on, in the shared container; nil where the process
    /// has no shared container.
    static var providersLockFile: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: suiteName)?
            .appending(path: lockFileName, directoryHint: .notDirectory)
    }

    /// How long a writer waits for another process to let the flock go before it writes without it.
    /// Every holder keeps it for one read and one write of the snapshot, a few milliseconds.
    static let flockPatience: Duration = .seconds(2)

    /// Runs `body` under the in-process lock and, when there is a lock file, its flock. Both locks
    /// are only ever held inside the keeper's hold, taken after it begins and let go before it
    /// ends, so the process cannot be suspended holding the flock and no thread waits on the
    /// in-process lock while another is inside UIKit. When there is no hold to be had, or the
    /// flock does not come in time, the write goes ahead under the in-process lock alone: a
    /// snapshot another process overwrites is put back by the next poll, while a flock held into
    /// suspension gets the app killed.
    static func withProvidersLock(
        lockFile: URL?, keeper: (any UsageLockSuspensionGuard)?, _ body: () -> Void
    ) {
        guard let lockFile else { return inProcessLock.withLock(body) }
        var hold: (any UsageLockHold)?
        if let keeper {
            guard let granted = keeper.holdAwake(reason: "Usage snapshot write") else {
                return inProcessLock.withLock(body)
            }
            hold = granted
        }
        defer { hold?.release() }
        inProcessLock.lock()
        defer { inProcessLock.unlock() }
        let descriptor = open(lockFile.path, O_CREAT | O_WRONLY | O_CLOEXEC, 0o644)
        guard descriptor >= 0 else { return body() }
        defer { close(descriptor) }
        guard takeFlock(descriptor, while: { hold?.isHolding ?? true }) else { return body() }
        guard hold?.flockTaken() ?? true else {
            flock(descriptor, LOCK_UN)
            return body()
        }
        defer { flock(descriptor, LOCK_UN) }
        body()
    }

    /// Takes the flock without ever sleeping in the kernel on it: a non-blocking request, asked
    /// again every few milliseconds until it is granted, `holding` turns false, or
    /// ``flockPatience`` runs out.
    private static func takeFlock(_ descriptor: Int32, while holding: () -> Bool) -> Bool {
        let deadline = ContinuousClock.now + flockPatience
        while holding() {
            if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return true }
            guard errno == EWOULDBLOCK || errno == EINTR, ContinuousClock.now < deadline else {
                return false
            }
            usleep(5_000)
        }
        return false
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
