import Foundation

/// The one invitation to Pro that is not a gate, and it gives rather than asks.
///
/// Most people run one machine, so they never meet the second-server gate and never learn what Pro is. `ProOffer`'s
/// stance still binds (no wall, no countdown, nothing on launch), so this is a single dismissible card, earned by
/// use rather than by time: it appears once at least ten turns have finished well, never while Pro is open, and
/// never again after it is set aside, taken up or a purchase lands. A copy that can still start its Pro week is
/// handed the week; one whose week is spent is told what Pro does for it. Only the *when* and the words live here;
/// each client draws the card its own way.
public enum ProInvitation: Sendable {
    nonisolated(unsafe) private static let defaults = UserDefaults.standard

    public static let turnsKey = "tailscode.proInvitation.successfulTurns"
    public static let settledKey = "tailscode.proInvitation.settled"

    static let legacyTurnsKey = "tailscode.supporter.successfulTurns"
    static let legacySettledKey = "tailscode.supporter.settled"

    /// Ten good turns is enough use to know what a second machine would be worth.
    public static let minimumTurns = 10

    public static let didChange = Notification.Name("tailscode.proInvitation.didChange")

    public static var successfulTurns: Int {
        carryOverEarlierAnswer()
        return defaults.integer(forKey: turnsKey)
    }

    /// Whether the invitation has been answered (by "Not now", by starting the week or by a purchase) and so is over.
    public static var isSettled: Bool {
        carryOverEarlierAnswer()
        return defaults.bool(forKey: settledKey)
    }

    /// Counts one turn that finished with content and failed at nothing. This count only decides when the card is due,
    /// so nothing is written once the invitation is settled; the number the card shows is the one that never stops
    /// (`ProPersonalDetails.Facts.turns`).
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

    /// The week taken up, a purchase, a restore, or a dismissal: anything after which the card has nothing left to say.
    public static func settle() {
        guard !isSettled else { return }
        defaults.set(true, forKey: settledKey)
        post()
    }

    /// The card was kept under other keys before it had anything to give. Whoever set it aside then has still set it
    /// aside, and turns counted then still count, so both move to the keys read now and the old ones go. Runs before
    /// every read and does nothing once they are gone.
    static func carryOverEarlierAnswer() {
        if let turns = defaults.object(forKey: legacyTurnsKey) as? Int {
            if defaults.object(forKey: turnsKey) == nil { defaults.set(turns, forKey: turnsKey) }
            defaults.removeObject(forKey: legacyTurnsKey)
        }
        if defaults.object(forKey: legacySettledKey) != nil {
            if defaults.bool(forKey: legacySettledKey), defaults.object(forKey: settledKey) == nil {
                defaults.set(true, forKey: settledKey)
            }
            defaults.removeObject(forKey: legacySettledKey)
        }
    }

    private static func post() {
        StoreNotice.post(didChange)
    }

    /// What the card hands the person.
    public enum Gift: Sendable, Equatable {
        /// The Pro week, started by their own press on the card: nothing is charged and nothing renews.
        case week
        /// What Pro does for them, with the way to the unlock.
        case pro
    }

    /// The week while this copy can still start one, else Pro itself.
    public static func gift(canStartWeek: Bool) -> Gift {
        canStartWeek ? .week : .pro
    }

    /// The card's title: the turns the person's agents have finished here, or what Pro is when the running count
    /// is not there to read.
    public static func title(_ facts: ProPersonalDetails.Facts) -> String {
        ProPersonalDetails.headline(facts)
    }

    /// The week said whole, with what happens after it, since the card's own button starts it; or what Pro gives.
    public static func body(_ gift: Gift) -> String {
        switch gift {
        case .week:
            return ProWeek.offerBody
        case .pro:
            return Localized.text(
                "Pro puts every machine on your tailnet in one session list, with a Live Activity for every running session and Delegate. One purchase, yours on iPhone and Mac, no subscription.")
        }
    }

    /// The week's own start button, or the unlock by name with its price once the store has answered.
    public static func primaryAction(_ gift: Gift, price: String?) -> String {
        switch gift {
        case .week:
            return ProWeek.startTitle
        case .pro:
            guard let price else { return ProOffer.title }
            return Localized.text("%1$@ · %2$@", ProOffer.title, price)
        }
    }

    public static var secondaryAction: String { Localized.text("Not now") }
}
