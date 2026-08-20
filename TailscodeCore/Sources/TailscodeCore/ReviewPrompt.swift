import Foundation

/// The whole of the review-ask doctrine, in three defaults. The question the policy answers is
/// *when* an ask is due, never how the ask looks — that is the platform's own store-review call,
/// which reports no dismissal back, so the policy does not pretend to know one; the cooldown and
/// the system's own annual cap are the whole of "never nag".
public enum ReviewPromptPolicy {
    nonisolated(unsafe) private static let defaults = UserDefaults.standard

    public static let installedAtKey = "tailscode.review.installedAt"
    public static let turnsKey = "tailscode.review.successfulTurns"
    public static let lastAskedKey = "tailscode.review.lastAsked"

    /// A review is earned, not stumbled into: this many turns completed with content.
    public static let minimumTurns = 3

    /// An install has to have been lived in before an opinion of it counts.
    public static let minimumAge: TimeInterval = 7 * 24 * 60 * 60

    /// One ask per window; the system's own 3-per-year cap sits on top.
    public static let askCooldown: TimeInterval = 7 * 24 * 60 * 60

    public static var successfulTurns: Int {
        defaults.integer(forKey: turnsKey)
    }

    public static var installedAt: Date? {
        guard defaults.object(forKey: installedAtKey) != nil else { return nil }
        return Date(timeIntervalSince1970: defaults.double(forKey: installedAtKey))
    }

    public static var lastAsked: Date? {
        guard defaults.object(forKey: lastAskedKey) != nil else { return nil }
        return Date(timeIntervalSince1970: defaults.double(forKey: lastAskedKey))
    }

    /// Counts one turn that finished with content and failed at nothing, then says whether the
    /// moment is due. The first successful turn anchors the install date, so an install that was
    /// never used earns nothing from its calendar age.
    @discardableResult
    public static func recordSuccessfulTurn(now: Date = Date()) -> Bool {
        if installedAt == nil {
            defaults.set(now.timeIntervalSince1970, forKey: installedAtKey)
        }
        defaults.set(successfulTurns + 1, forKey: turnsKey)
        return isDue(now: now, requireTurns: true)
    }

    /// A trophy earned is the deepest usage signal there is, so it waives the turn count — but
    /// never the age gate: a fresh install that farms its first trophy still owes the week.
    @discardableResult
    public static func noteTrophyEarned(now: Date = Date()) -> Bool {
        isDue(now: now, requireTurns: false)
    }

    public static func markAsked(now: Date = Date()) {
        defaults.set(now.timeIntervalSince1970, forKey: lastAskedKey)
    }

    private static func isDue(now: Date, requireTurns: Bool) -> Bool {
        guard let installedAt else { return false }
        guard now.timeIntervalSince(installedAt) >= minimumAge else { return false }
        if requireTurns, successfulTurns < minimumTurns { return false }
        if let lastAsked, now.timeIntervalSince(lastAsked) < askCooldown { return false }
        return true
    }
}
