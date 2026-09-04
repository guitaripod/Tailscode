import Foundation

/// What Pro is, in one place, so the phone and the Mac sell the same thing.
///
/// Tailscode is GPL-3.0 and every screen is in the free app: the unlock is a convenience and a way
/// to fund the work, not a wall around the product. That decides the shape of it — one honest gate
/// on the one thing that costs the project real effort to keep working (many machines, many live
/// sessions), a tip jar that unlocks nothing at all, and no countdown, no trial that expires, no
/// screen that nags on launch.
///
/// The store record is shared with iOS, so the product identifiers are the same on both and one
/// purchase covers both. That is worth saying out loud rather than leaving somebody to discover it.
public enum ProOffer: Sendable {
    public static let productID = "com.guitaripod.tailscode.pro"
    public static let tipIDs = [
        "com.guitaripod.tailscode.tip.small",
        "com.guitaripod.tailscode.tip.medium",
        "com.guitaripod.tailscode.tip.large",
    ]

    /// How many servers the free app connects. The second machine is the moment the app stops
    /// being a client and starts being the thing that holds a tailnet's worth of work together,
    /// which is the honest place to ask for money.
    public static let freeServerLimit = 1

    public static var title: String { Localized.text("Tailscode Pro") }

    public static var pitch: String {
        Localized.text(
            "Tailscode is open source, with no ads, no tracking, and no server between you and your agents. The one-time Pro unlock funds development.")
    }

    public struct Perk: Sendable, Equatable {
        public let symbol: String
        public let text: String
        public init(symbol: String, text: String) {
            self.symbol = symbol
            self.text = text
        }
    }

    public static var perks: [Perk] {
        [
            Perk(
                symbol: "server.rack",
                text: Localized.text(
                    "Connect unlimited servers — one unified session list across every machine on your tailnet")),
            DelegateProGate.perk,
            Perk(
                symbol: "iphone.and.macbook",
                text: Localized.text(
                    "One purchase covers iPhone and Mac, on the same Apple Account")),
            Perk(
                symbol: "heart.fill",
                text: Localized.text("Supporter badge, and a say in what gets built next")),
        ]
    }

    /// What the app says at the gate. It names the limit and what lifting it costs, and it never
    /// pretends the refusal came from anywhere but a price.
    public static var requirement: String {
        Localized.text("Connecting more than one server requires Tailscode Pro.")
    }

    public static var tipHeading: String {
        Localized.text("Or leave a tip — no unlock, just thanks")
    }

    public static var restoreTitle: String { Localized.text("Restore purchases") }

    public static var thanks: String { Localized.text("You're a supporter — thank you ♥") }

    /// Whether adding one more server is something this copy of the app will do.
    /// - Parameters:
    ///   - existing: how many servers are already configured.
    ///   - isPro: whether the unlock is held.
    public static func allowsAnotherServer(existing: Int, isPro: Bool) -> Bool {
        isPro || existing < freeServerLimit
    }
}
