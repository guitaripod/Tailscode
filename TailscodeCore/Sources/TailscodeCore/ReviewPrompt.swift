import Foundation

/// The whole of the review-ask doctrine. The question the policy answers is *when* an ask is
/// due, never how the ask looks — that is the platform's own store-review call, which reports no
/// dismissal back, so the policy does not pretend to know one; the cooldown and the system's own
/// annual cap are the whole of "never nag".
///
/// Three signals, strongest first: coming back to an answer that finished while the person was
/// away is the app's whole pitch and is due after two successful turns; a trophy earned waives
/// the turn count outright; and an ordinary turn read to its end is due after five. There is no
/// install-age gate — a funnel of dozens of installs a month never reached one, and a week of
/// calendar time says nothing a completed turn does not.
public enum ReviewPromptPolicy {
    nonisolated(unsafe) private static let defaults = UserDefaults.standard

    public static let turnsKey = "tailscode.review.successfulTurns"
    public static let lastAskedKey = "tailscode.review.lastAsked"

    /// A review is earned, not stumbled into: this many turns completed with content.
    public static let minimumTurns = 5

    /// Leaving mid-turn and returning to a finished answer is the core promise kept, so it needs
    /// only this many successful turns behind it.
    public static let minimumTurnsForReturn = 2

    /// One ask per window; the system's own 3-per-year cap sits on top.
    public static let askCooldown: TimeInterval = 7 * 24 * 60 * 60

    public static var successfulTurns: Int {
        defaults.integer(forKey: turnsKey)
    }

    public static var lastAsked: Date? {
        guard defaults.object(forKey: lastAskedKey) != nil else { return nil }
        return Date(timeIntervalSince1970: defaults.double(forKey: lastAskedKey))
    }

    /// Counts one turn that finished with content and failed at nothing, then says whether the
    /// moment is due.
    @discardableResult
    public static func recordSuccessfulTurn(now: Date = Date()) -> Bool {
        defaults.set(successfulTurns + 1, forKey: turnsKey)
        return isDue(now: now, requiredTurns: minimumTurns)
    }

    /// A trophy earned is the deepest usage signal there is, so it waives the turn count.
    @discardableResult
    public static func noteTrophyEarned(now: Date = Date()) -> Bool {
        isDue(now: now, requiredTurns: 0)
    }

    /// The person left while a turn was running and came back to a finished answer — the
    /// strongest moment there is, due once a couple of turns have already succeeded.
    @discardableResult
    public static func noteReturnedToFinishedWork(now: Date = Date()) -> Bool {
        isDue(now: now, requiredTurns: minimumTurnsForReturn)
    }

    public static func markAsked(now: Date = Date()) {
        defaults.set(now.timeIntervalSince1970, forKey: lastAskedKey)
    }

    private static func isDue(now: Date, requiredTurns: Int) -> Bool {
        guard successfulTurns >= requiredTurns else { return false }
        if let lastAsked, now.timeIntervalSince(lastAsked) < askCooldown { return false }
        return true
    }
}
