import Foundation

/// Local record of when each conversation was last opened, so Home can badge
/// sessions that changed after you last looked. Sessions never opened on this
/// device fall back to an install-time baseline, which keeps pre-existing
/// history from lighting up all at once on first launch.
///
/// The record is bounded, and a mark that falls off its end takes the baseline with it: a chat
/// read long ago whose mark was dropped would otherwise be judged against the day the app was
/// installed and light up again, which is how a list fills with old chats nobody has touched.
public enum SessionSeenStore {
    nonisolated(unsafe) private static let defaults = UserDefaults.standard
    static let seenKey = "tailscode.seen.sessions"
    static let baselineKey = "tailscode.seen.baseline"
    static let liftedKey = "tailscode.seen.lifted"
    static let capacity = 1000

    /// Posted when another device's read marks arrive through a server, so a screen that draws
    /// unread state can draw it again without being asked to redraw for every chat opened here.
    public static let didSync = Notification.Name("tailscode.seen.didSync")

    /// Posted when this device marks a chat read or unread. A list that keeps its reading of the
    /// marks between draws drops it on this, or the row it was asked to redraw stays bold until a
    /// server echoes the mark back seconds later, and a chat on a server that keeps no marks
    /// (opencode) until something else happens to move.
    public static let didMark = Notification.Name("tailscode.seen.didMark")

    public static func bootstrapIfNeeded() {
        if defaults.object(forKey: baselineKey) == nil {
            defaults.set(Date().timeIntervalSince1970, forKey: baselineKey)
        }
        liftOnce()
    }

    /// Repairs a record that was trimmed before a trim moved the baseline. The marks it dropped
    /// were all older than the oldest one it kept, so a record that was full takes that one as its
    /// baseline, once.
    private static func liftOnce() {
        guard !defaults.bool(forKey: liftedKey) else { return }
        defaults.set(true, forKey: liftedKey)
        let seen = values()
        guard seen.count >= retiredCapacity, let oldest = seen.values.min() else { return }
        lift(to: oldest)
    }

    private static let retiredCapacity = 300

    private static func lift(to mark: Double) {
        guard mark > defaults.double(forKey: baselineKey) else { return }
        defaults.set(mark, forKey: baselineKey)
    }

    /// Holds the record to its bound, newest marks kept, and moves the baseline up to the newest
    /// mark dropped so no chat it forgets reads as changed since.
    private static func trimmed(_ seen: [String: Double]) -> [String: Double] {
        guard seen.count > capacity else { return seen }
        let cutoff = seen.values.sorted(by: >)[capacity - 1]
        if let dropped = seen.values.filter({ $0 < cutoff }).max() { lift(to: dropped) }
        return seen.filter { $0.value >= cutoff }
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
        markSeen([sessionID])
    }

    /// Marks every one of these read in one write, each told to its server like a single press.
    public static func markSeen(_ sessionIDs: [String]) {
        guard !sessionIDs.isEmpty else { return }
        var seen = values()
        let now = Date().timeIntervalSince1970
        for sessionID in sessionIDs { seen[sessionID] = now }
        defaults.set(trimmed(seen), forKey: seenKey)
        for sessionID in sessionIDs {
            MarkIntentStore.note(
                sessionID: sessionID, profileID: SessionOwners.profile(of: sessionID), mark: .read,
                on: true)
            DeskLooks.note(sessionID)
        }
        StoreNotice.post(didMark)
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
        StoreNotice.post(didMark)
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
        defaults.set(trimmed(seen), forKey: seenKey)
        StoreNotice.post(didSync)
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
