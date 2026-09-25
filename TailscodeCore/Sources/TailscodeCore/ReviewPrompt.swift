import Foundation

/// The whole of the review-ask doctrine. The question the policy answers is *when* an ask is
/// due, never how the ask looks — that is the platform's own store-review call, which reports
/// no dismissal back, so the policy does not pretend to know one; the cooldown, the per-ask
/// success floor and the system's own rolling-year cap are the whole of "never nag".
///
/// A success is the app's core value moment — an agent turn finishing with an answer, in a
/// session on a server this device is connected to — and nothing else feeds the count. The
/// first ask is early, due the moment a second success lands, because getting real value twice
/// already argues for itself. Every ask after the first waits for both a fortnight and three
/// fresh successes since the one before it, and no ask is ever due once three already sit inside
/// the trailing year — Apple's own ceiling on how often the system will even show the sheet.
public enum ReviewPromptPolicy {
    nonisolated(unsafe) private static let defaults = UserDefaults.standard

    public static let successCountKey = "tailscode.review.successCount"
    public static let askDatesKey = "tailscode.review.askDates"
    public static let successCountAtLastAskKey = "tailscode.review.successCountAtLastAsk"

    private static let legacyTurnsKey = "tailscode.review.successfulTurns"
    private static let legacyLastAskedKey = "tailscode.review.lastAsked"

    /// The first ask needs only two successes: value delivered twice is the earliest an ask
    /// reads as earned rather than presumptuous.
    public static let firstAskThreshold = 2

    /// Every later ask needs this many successes since the one before it.
    public static let successesBetweenAsks = 3

    /// Every later ask also needs this much calendar time since the one before it.
    public static let minimumIntervalBetweenAsks: TimeInterval = 14 * 24 * 60 * 60

    /// Apple's own ceiling: never a fourth ask inside one rolling year.
    public static let maximumAsksPerRollingYear = 3
    public static let rollingYear: TimeInterval = 365 * 24 * 60 * 60

    public static var successCount: Int {
        defaults.integer(forKey: successCountKey)
    }

    public static var askDates: [Date] {
        (defaults.array(forKey: askDatesKey) as? [Double] ?? [])
            .map { Date(timeIntervalSince1970: $0) }
    }

    private static var successCountAtLastAsk: Int {
        defaults.integer(forKey: successCountAtLastAskKey)
    }

    /// Counts one success, then says whether the moment is due.
    @discardableResult
    public static func recordSuccess(now: Date = Date()) -> Bool {
        let count = successCount + 1
        defaults.set(count, forKey: successCountKey)
        return isDue(
            successCount: count, askDates: askDates,
            successCountAtLastAsk: successCountAtLastAsk, now: now)
    }

    /// Whether an ask is due right now, without recording a new success — the check a return to
    /// the foreground repeats for a success that landed while nobody was there to be asked.
    public static func isDue(now: Date = Date()) -> Bool {
        isDue(
            successCount: successCount, askDates: askDates,
            successCountAtLastAsk: successCountAtLastAsk, now: now)
    }

    public static func markAsked(now: Date = Date()) {
        var dates = askDates
        dates.append(now)
        defaults.set(dates.map(\.timeIntervalSince1970), forKey: askDatesKey)
        defaults.set(successCount, forKey: successCountAtLastAskKey)
    }

    /// The pure decision, taking every input by value so it can be tested without touching
    /// `UserDefaults`: the rolling-year cap first, then either the first-ask floor with no prior
    /// ask, or both the cooldown and the fresh-success floor measured since the one before.
    static func isDue(
        successCount: Int, askDates: [Date], successCountAtLastAsk: Int, now: Date
    ) -> Bool {
        let askedWithinRollingYear = askDates.filter { now.timeIntervalSince($0) < rollingYear }
        guard askedWithinRollingYear.count < maximumAsksPerRollingYear else { return false }
        guard let lastAsked = askDates.max() else {
            return successCount >= firstAskThreshold
        }
        guard now.timeIntervalSince(lastAsked) >= minimumIntervalBetweenAsks else { return false }
        return successCount - successCountAtLastAsk >= successesBetweenAsks
    }

    /// The mechanism this replaced counted every turn the same way and kept one last-asked date;
    /// an ordinary successful turn meant the same thing then as a success means now, so its count
    /// carries over unchanged, and its one date becomes the sole entry in the new ask history —
    /// prior ask dates count toward the rolling-year cap. The success count at migration time is
    /// recorded against that date so the fresh-success floor still applies going forward rather
    /// than reading everything already accumulated as new. Safe to call on every launch: once the
    /// new keys hold anything, the old ones are gone and there is nothing left to migrate.
    public static func migrateIfNeeded() {
        if defaults.object(forKey: legacyTurnsKey) != nil,
            defaults.object(forKey: successCountKey) == nil
        {
            defaults.set(defaults.integer(forKey: legacyTurnsKey), forKey: successCountKey)
        }
        if defaults.object(forKey: legacyLastAskedKey) != nil,
            defaults.object(forKey: askDatesKey) == nil
        {
            defaults.set([defaults.double(forKey: legacyLastAskedKey)], forKey: askDatesKey)
            defaults.set(successCount, forKey: successCountAtLastAskKey)
        }
        defaults.removeObject(forKey: legacyTurnsKey)
        defaults.removeObject(forKey: legacyLastAskedKey)
    }
}
