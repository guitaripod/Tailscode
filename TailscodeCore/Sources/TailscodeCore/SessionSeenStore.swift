import Foundation

/// Local record of when each conversation was last opened, so Home can badge
/// sessions that changed after you last looked. Sessions never opened on this
/// device fall back to an install-time baseline, which keeps pre-existing
/// history from lighting up all at once on first launch.
public enum SessionSeenStore {
    nonisolated(unsafe) private static let defaults = UserDefaults.standard
    static let seenKey = "tailscode.seen.sessions"
    static let baselineKey = "tailscode.seen.baseline"
    static let decidedKey = "tailscode.seen.decided"
    private static let capacity = 300

    /// Posted after every write, this device's or the cloud's: the sync listens here so a mark
    /// made on a phone is on its way before the chat is closed.
    public static let didChange = Notification.Name("tailscode.seen.didChange")

    /// Posted only when marks arrive from another device, so a screen that draws unread state can
    /// draw it again without being asked to redraw on every chat a person opens.
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
        let now = Date().timeIntervalSince1970
        seen[sessionID] = now
        if seen.count > capacity {
            let cutoff = seen.values.sorted(by: >)[capacity - 1]
            seen = seen.filter { $0.value >= cutoff }
        }
        defaults.set(seen, forKey: seenKey)
        decide(sessionID, at: now)
    }

    /// Rewinds the "last looked" mark to just before the session's latest change, so the row
    /// badges as unread again — the inverse of ``markSeen(_:)``, for a chat set aside for later.
    public static func markUnread(_ sessionID: String, updatedAt: Date) {
        var seen = defaults.dictionary(forKey: seenKey) as? [String: Double] ?? [:]
        seen[sessionID] = updatedAt.timeIntervalSince1970 - 2
        defaults.set(seen, forKey: seenKey)
        decide(sessionID, at: Date().timeIntervalSince1970)
    }

    private static func decide(_ sessionID: String, at: Double) {
        var decided = defaults.dictionary(forKey: decidedKey) as? [String: Double] ?? [:]
        decided[sessionID] = at
        if decided.count > capacity * 2 {
            let cutoff = decided.values.sorted(by: >)[capacity - 1]
            decided = decided.filter { $0.value >= cutoff }
        }
        defaults.set(decided, forKey: decidedKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    /// Every mark this device holds with the moment the person made it, which is what lets a
    /// mark made here be weighed against one made on another device.
    public static func marks() -> [String: CloudSeen] {
        let seen = defaults.dictionary(forKey: seenKey) as? [String: Double] ?? [:]
        let decided = defaults.dictionary(forKey: decidedKey) as? [String: Double] ?? [:]
        return seen.reduce(into: [:]) { out, pair in
            out[pair.key] = CloudSeen(value: pair.value, decidedAt: decided[pair.key])
        }
    }

    /// Takes marks another device made. Nothing is stamped as a decision of this device's own.
    public static func adopt(_ marks: [String: CloudSeen]) {
        guard !marks.isEmpty else { return }
        var seen = defaults.dictionary(forKey: seenKey) as? [String: Double] ?? [:]
        var decided = defaults.dictionary(forKey: decidedKey) as? [String: Double] ?? [:]
        for (id, mark) in marks {
            seen[id] = mark.value
            if let at = mark.decidedAt { decided[id] = at }
        }
        if seen.count > capacity {
            let cutoff = seen.values.sorted(by: >)[capacity - 1]
            seen = seen.filter { $0.value >= cutoff }
        }
        defaults.set(seen, forKey: seenKey)
        defaults.set(decided, forKey: decidedKey)
        NotificationCenter.default.post(name: didChange, object: nil)
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
