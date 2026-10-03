import Foundation

/// The question that comes before the system's own, and the rule for when it may be asked.
///
/// The system prompt can be answered once and never shown again, so spending it on a person who
/// has not yet watched an agent finish a turn wastes the only chance there is. The ask therefore
/// waits for the first real turn that ended, says in the app's own words what the alerts are
/// for, and is made once — a "Not now" is final, and Settings keeps the way back. The demo is a
/// scripted world with nothing to be alerted about, so it never asks.
public enum NotificationPrimer: Sendable {
    nonisolated(unsafe) private static let defaults = UserDefaults.standard

    public static let offeredKey = "tailscode.notificationPrimer.offered"

    /// Whether the question has already been put to this person, whatever they answered.
    public static var hasOffered: Bool {
        defaults.bool(forKey: offeredKey)
    }

    public static func shouldOffer(systemAnswerPending: Bool, isDemo: Bool) -> Bool {
        systemAnswerPending && !isDemo && !hasOffered
    }

    public static func markOffered() {
        defaults.set(true, forKey: offeredKey)
    }

    public static var title: String { Localized.text("Get a nudge when your agent is done") }

    public static var body: String {
        Localized.text(
            "Tailscode can alert you on the Lock Screen and in a Live Activity when the agent finishes or has a question, so you can leave it working.")
    }

    public static var acceptAction: String { Localized.text("Turn on alerts") }

    public static var declineAction: String { Localized.text("Not now") }
}
