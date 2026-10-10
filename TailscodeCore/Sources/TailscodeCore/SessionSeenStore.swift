import Foundation

/// Local record of when each conversation was last opened, so Home can badge
/// sessions that changed after you last looked. Sessions never opened on this
/// device fall back to an install-time baseline, which keeps pre-existing
/// history from lighting up all at once on first launch.
public enum SessionSeenStore {
    nonisolated(unsafe) private static let defaults = UserDefaults.standard
    static let seenKey = "tailscode.seen.sessions"
    static let baselineKey = "tailscode.seen.baseline"
    private static let capacity = 300

    /// Posted when another device's read marks arrive through a server, so a screen that draws
    /// unread state can draw it again without being asked to redraw for every chat opened here.
    public static let didSync = Notification.Name("tailscode.seen.didSync")

    public static func bootstrapIfNeeded() {
        guard defaults.object(forKey: baselineKey) == nil else { return }
        defaults.set(Date().timeIntervalSince1970, forKey: baselineKey)
    }

    #if DEBUG
        /// Backdates the "last looked" mark so a filmed board opens carrying the unread
        /// state a real one has after an evening away, rather than the blank slate a
        /// clean install always produces.
        public static func tourRewindBaseline(_ seconds: TimeInterval) {
            defaults.set(
                Date().addingTimeInterval(-seconds).timeIntervalSince1970, forKey: baselineKey)
        }
    #endif

    public static func markSeen(_ sessionID: String) {
        var seen = defaults.dictionary(forKey: seenKey) as? [String: Double] ?? [:]
        seen[sessionID] = Date().timeIntervalSince1970
        if seen.count > capacity {
            let cutoff = seen.values.sorted(by: >)[capacity - 1]
            seen = seen.filter { $0.value >= cutoff }
        }
        defaults.set(seen, forKey: seenKey)
        MarkIntentStore.note(
            sessionID: sessionID, profileID: SessionOwners.profile(of: sessionID), mark: .read,
            on: true)
    }

    /// Rewinds the "last looked" mark to just before the session's latest change, so the row
    /// badges as unread again — the inverse of ``markSeen(_:)``, for a chat set aside for later.
    public static func markUnread(_ sessionID: String, updatedAt: Date) {
        var seen = defaults.dictionary(forKey: seenKey) as? [String: Double] ?? [:]
        seen[sessionID] = updatedAt.timeIntervalSince1970 - 2
        defaults.set(seen, forKey: seenKey)
        MarkIntentStore.note(
            sessionID: sessionID, profileID: SessionOwners.profile(of: sessionID), mark: .read,
            on: false)
    }

    /// Every mark this device holds, by the clock it was made on.
    public static func values() -> [String: Double] {
        defaults.dictionary(forKey: seenKey) as? [String: Double] ?? [:]
    }

    /// Takes the read marks a server holds. They are in the server's own clock, which is the one a
    /// chat's last change is read on, and nothing here records them as a decision of this device's.
    public static func adopt(_ marks: [String: Double]) {
        guard !marks.isEmpty else { return }
        var seen = values()
        for (id, value) in marks { seen[id] = value }
        if seen.count > capacity {
            let cutoff = seen.values.sorted(by: >)[capacity - 1]
            seen = seen.filter { $0.value >= cutoff }
        }
        defaults.set(seen, forKey: seenKey)
        NotificationCenter.default.post(name: didSync, object: nil)
    }

    /// One snapshot of the store per list render: returns a closure judging
    /// `(sessionID, updatedAt)` so callers don't hit `UserDefaults` per row.
    public static func unreadEvaluator() -> (String, Date) -> Bool {
        let seen = defaults.dictionary(forKey: seenKey) as? [String: Double] ?? [:]
        let baseline = defaults.double(forKey: baselineKey)
        return { sessionID, updatedAt in
            let reference = seen[sessionID] ?? baseline
            guard reference > 0 else { return false }
            return updatedAt.timeIntervalSince1970 > reference + 1
        }
    }
}
