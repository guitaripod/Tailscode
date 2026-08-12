import Foundation

/// What this device already knew about everyone's software, kept across launches.
///
/// An update mark that only appears once a check has come back is a mark that flickers on every
/// cold start and is missing exactly when the network is worst. So the last answer from every
/// machine is written down: the surface renders from memory the instant it opens, and the check
/// that follows corrects it. Device-local like the pins and the archive — what this screen has
/// been told is a fact about this screen.
///
/// Nothing here dismisses anything. Setting an update aside is recorded against *what was being
/// offered* — the target, and the obstacle in the way of it — so the mark comes back the moment
/// the world changes in a way the person could act on: a newer release, a different obstacle, an
/// obstacle that cleared, a failure that is not the same corpse. There is no `dismiss`, and the
/// absence is the design.
public enum UpdateLedger {
    nonisolated(unsafe) private static let defaults = UserDefaults.standard
    /// The whole ledger is one blob, so recording a row is a read, an edit and a write — and the
    /// three clients ask their machines concurrently, from tasks with no shared isolation. Without
    /// this, two servers answering at the same moment each write a picture that predates the other
    /// and one of them silently loses its row, which on this surface means a machine's update
    /// quietly stops existing.
    private static let lock = NSLock()
    public static let storagePrefix = "tailscode.updates."
    static let readingsKey = "tailscode.updates.readings"
    static let acknowledgedKey = "tailscode.updates.acknowledged"
    static let lastCheckKey = "tailscode.updates.lastCheck"

    public static let didChange = Notification.Name("tailscode.updates.didChange")

    /// Every remembered reading, decayed to what it is still allowed to claim.
    public static func remembered(now: Date = Date()) -> [UpdateReading] {
        stored().map { reading in
            let verdict = UpdateFreshness.decayed(reading, now: now)
            guard verdict != reading.verdict else { return reading }
            return UpdateReading(
                component: reading.component, title: reading.title, subtitle: reading.subtitle,
                installed: reading.installed, available: reading.available, verdict: verdict,
                invitation: reading.invitation, manager: reading.manager, log: reading.log,
                checkedAt: reading.checkedAt, note: reading.note, automation: reading.automation)
        }
    }

    /// The whole picture as a client draws it: what is remembered, and what has been set aside.
    public static func rollup(now: Date = Date()) -> UpdateRollup {
        UpdateRollup(readings: remembered(now: now), acknowledged: acknowledgements())
    }

    public static func remembered(_ component: UpdateComponent, now: Date = Date())
        -> UpdateReading?
    {
        remembered(now: now).first { $0.component == component }
    }

    public static func record(_ reading: UpdateReading) {
        record([reading])
    }

    public static func record(_ readings: [UpdateReading]) {
        guard !readings.isEmpty else { return }
        mutate { all in
            let replaced = Set(readings.map(\.component))
            return all.filter { !replaced.contains($0.component) } + readings
        }
    }

    /// Drops a machine nobody is talking to any more, so a deleted server stops holding the mark up.
    public static func forget(_ component: UpdateComponent) {
        mutate { $0.filter { $0.component != component } }
        lock.lock()
        var acknowledged = acknowledgements()
        acknowledged.removeValue(forKey: component.key)
        defaults.set(acknowledged, forKey: acknowledgedKey)
        lock.unlock()
    }

    /// Keeps only the machines still configured. Called from wherever the profile list changes,
    /// because a removed server that kept its row would keep its mark forever.
    public static func keep(_ components: [UpdateComponent]) {
        let live = Set(components.map(\.key))
        lock.lock()
        var acknowledged = acknowledgements()
        let stale = acknowledged.keys.filter { !live.contains($0) }
        for key in stale { acknowledged.removeValue(forKey: key) }
        if !stale.isEmpty { defaults.set(acknowledged, forKey: acknowledgedKey) }
        lock.unlock()
        mutate { $0.filter { live.contains($0.component.key) } }
    }

    /// Read, edit and write as one step. Every path that changes the ledger goes through here, and
    /// the notification is posted after the lock is dropped so an observer that reads the ledger
    /// back cannot deadlock against the write that woke it.
    private static func mutate(_ change: ([UpdateReading]) -> [UpdateReading]) {
        lock.lock()
        let before = stored()
        let after = change(before)
        let changed = after.count != before.count || after != before
        if changed, let data = try? JSONEncoder().encode(after) {
            defaults.set(data, forKey: readingsKey)
        }
        lock.unlock()
        guard changed else { return }
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    public static func lastCheck() -> Date? {
        let stamp = defaults.double(forKey: lastCheckKey)
        return stamp > 0 ? Date(timeIntervalSince1970: stamp) : nil
    }

    public static func noteCheck(at date: Date = Date()) {
        defaults.set(date.timeIntervalSince1970, forKey: lastCheckKey)
    }

    public static func isDue(now: Date = Date()) -> Bool {
        UpdateFreshness.isDue(lastCheck: lastCheck(), now: now)
    }

    /// Sets this exact offer aside. The row keeps its place and its whole sentence in the update
    /// surface; it stops holding the standing mark up, and only until what is offered changes.
    public static func acknowledge(_ reading: UpdateReading) {
        guard let identity = reading.acknowledgeableIdentity else { return }
        var acknowledged = acknowledgements()
        acknowledged[reading.component.key] = identity
        defaults.set(acknowledged, forKey: acknowledgedKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    public static func isAcknowledged(_ reading: UpdateReading) -> Bool {
        guard let identity = reading.acknowledgeableIdentity else { return false }
        return acknowledgements()[reading.component.key] == identity
    }

    public static func acknowledgements() -> [String: String] {
        defaults.dictionary(forKey: acknowledgedKey) as? [String: String] ?? [:]
    }

    /// Read one row at a time. A whole-array decode means a single renamed case wipes every mark on
    /// the next launch — which is exactly the moment the persistence exists to survive.
    private static func stored() -> [UpdateReading] {
        guard let data = defaults.data(forKey: readingsKey),
            let rows = try? JSONDecoder().decode([FailableReading].self, from: data)
        else { return [] }
        return rows.compactMap(\.reading)
    }

    private struct FailableReading: Decodable {
        let reading: UpdateReading?

        init(from decoder: any Decoder) throws {
            reading = try? UpdateReading(from: decoder)
        }
    }
}
