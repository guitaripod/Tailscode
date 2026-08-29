import Foundation

/// The one invitation to buy Pro that is not a gate.
///
/// Most people run one machine, so they never meet the second-server gate and never learn the
/// unlock exists. `ProOffer`'s stance still binds — no wall, no trial, nothing on launch — so
/// this is a single dismissible card, earned by use rather than by time: it appears once at
/// least ten turns have finished well, never while Pro is held, and never again after it is set
/// aside or a purchase lands. Only the *when* lives here; each client draws the card its own way.
public enum SupporterInvitation: Sendable {
    nonisolated(unsafe) private static let defaults = UserDefaults.standard

    public static let turnsKey = "tailscode.supporter.successfulTurns"
    public static let settledKey = "tailscode.supporter.settled"

    /// Ten good turns is enough use to have an opinion about whether the app is worth funding.
    public static let minimumTurns = 10

    public static let didChange = Notification.Name("tailscode.supporter.didChange")

    public static var successfulTurns: Int {
        defaults.integer(forKey: turnsKey)
    }

    /// Whether the invitation has been answered — by "Not now" or by a purchase — and so is over.
    public static var isSettled: Bool {
        defaults.bool(forKey: settledKey)
    }

    /// Counts one turn that finished with content and failed at nothing. Counting stops mattering
    /// once the invitation is settled, so nothing is written past that point.
    public static func recordSuccessfulTurn() {
        guard !isSettled else { return }
        let turns = successfulTurns + 1
        defaults.set(turns, forKey: turnsKey)
        if turns == minimumTurns { post() }
    }

    public static func isDue(isPro: Bool) -> Bool {
        !isPro && !isSettled && successfulTurns >= minimumTurns
    }

    /// "Not now", and it means it: the card never returns.
    public static func dismiss() {
        settle()
    }

    /// A purchase, a restore, or a dismissal — anything after which asking would be rude.
    public static func settle() {
        guard !isSettled else { return }
        defaults.set(true, forKey: settledKey)
        post()
    }

    private static func post() {
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    public static var title: String { Localized.text("Tailscode is free and open source") }

    public static var body: String {
        Localized.text(
            "No ads, no tracking, no server between you and your agents. One purchase covers iPhone and Mac, unlocks unlimited servers, and funds the work.")
    }

    /// The primary action names the unlock and, when the store has answered, its price.
    public static func primaryAction(price: String?) -> String {
        guard let price else { return ProOffer.title }
        return Localized.text("%1$@ · %2$@", ProOffer.title, price)
    }

    public static var secondaryAction: String { Localized.text("Not now") }
}
