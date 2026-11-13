import Foundation

/// What Pro is, in one place, so the phone and the Mac sell the same thing.
///
/// Tailscode is GPL-3.0 and every screen is in the free app, so Pro is not a wall around the product. It is what a
/// person gets once one machine is no longer enough: every machine on their tailnet in one session list, a Live
/// Activity for every running session, Delegate, on iPhone and Mac for one purchase. That decides the shape of it:
/// one honest gate on adding a second server, every word about what the buyer gets and none about what the app
/// needs, and no countdown, no trial that expires, no screen that nags on launch.
///
/// The store record is shared with iOS, so the product identifiers are the same on both and one
/// purchase covers both. That is worth saying out loud rather than leaving somebody to discover it.
public enum ProOffer: Sendable {
    public static let productID = "com.guitaripod.tailscode.pro"

    /// The tips an earlier version sold. Nothing offers them any more, because a tip gave the buyer nothing; the
    /// store still knows the products so a purchase made in that version, or approved after an update, is finished
    /// and reported instead of left hanging.
    public static let retiredTipIDs = [
        "com.guitaripod.tailscode.tip.small",
        "com.guitaripod.tailscode.tip.medium",
        "com.guitaripod.tailscode.tip.large",
    ]

    /// How many servers the free app connects. The second machine is the moment the app stops
    /// being a client and starts being the thing that holds a tailnet's worth of work together,
    /// which is the honest place to ask for money.
    public static let freeServerLimit = 1

    public static var title: String { Localized.text("Tailscode Pro") }

    /// What the sheet leads with when this copy knows nothing about the person yet.
    public static var headline: String {
        Localized.text("Every machine on your tailnet, in one session list")
    }

    /// What the buyer gets and keeps, said under the headline.
    public static var pitch: String {
        Localized.text(
            "Pay once and Pro is yours on iPhone and Mac. No subscription, no ads, no tracking, and no server between you and your agents.")
    }

    public struct Perk: Sendable, Equatable {
        public let symbol: String
        public let text: String
        public init(symbol: String, text: String) {
            self.symbol = symbol
            self.text = text
        }
    }

    /// What Pro gives, in the order the sheet lists it, Delegate last.
    /// - Parameter liveActivities: whether this client has Live Activities to offer, which only the phone does.
    public static func perks(liveActivities: Bool = false) -> [Perk] {
        let servers = Perk(
            symbol: "server.rack",
            text: Localized.text(
                "Connect unlimited servers — one unified session list across every machine on your tailnet"))
        let activities = Perk(
            symbol: "bolt.badge.clock",
            text: Localized.text("Concurrent Live Activities for every running session, not just one"))
        let devices = Perk(
            symbol: "macbook.and.iphone",
            text: Localized.text("One purchase covers iPhone and Mac, on the same Apple Account"))
        return [servers] + (liveActivities ? [activities] : []) + [devices, DelegateProGate.perk]
    }

    /// What the app says at the gate. It names the limit and what lifting it costs, and it never
    /// pretends the refusal came from anywhere but a price.
    public static var requirement: String {
        Localized.text("Connecting more than one server requires Tailscode Pro.")
    }

    public static var restoreTitle: String { Localized.text("Restore purchases") }

    /// What a copy that holds Pro says where the purchase would be: what the person has.
    public static var owned: String { Localized.text("Tailscode Pro is yours on iPhone and Mac") }

    /// The same, where the line stands under the name of the unlock.
    public static var ownedDetail: String { Localized.text("Yours on iPhone and Mac") }

    /// Whether adding one more server is something this copy of the app will do.
    /// - Parameters:
    ///   - existing: how many servers are already configured.
    ///   - isPro: whether the unlock is held.
    public static func allowsAnotherServer(existing: Int, isPro: Bool) -> Bool {
        isPro || existing < freeServerLimit
    }
}
