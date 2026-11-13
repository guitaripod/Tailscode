import Foundation

/// The Pro sheet and the invitation told about the person, where this copy of the app knows enough to say something
/// true: the turns their agents have finished on this device, the server they connect to, the servers resting since
/// their Pro week. Every figure is one the app already keeps on the device and none of it is sent anywhere. Below its
/// threshold a line keeps the general wording, and `ProOffer`'s stance binds here too: a fact about their own use and
/// what they would get, never a countdown, never a reproach, and never a word about what the app needs.
public enum ProPersonalDetails: Sendable {
    /// What a copy of the app knows about the person it is shown to.
    public struct Facts: Sendable, Equatable {
        /// Turns that finished with an answer on this device. Clients read `ReviewPromptPolicy.successCount`, the count
        /// that never stops, and not the invitation's own, which is frozen once the card is settled.
        public var turns: Int
        /// The names of the saved servers this copy connects, in the order they were saved, the demo world's left out.
        public var connected: [String]
        /// The names of the saved servers resting since the Pro week.
        public var resting: [String]

        public init(turns: Int = 0, connected: [String] = [], resting: [String] = []) {
            self.turns = turns
            self.connected = connected
            self.resting = resting
        }
    }

    /// Finished turns before a line counts them: the invitation's own measure of enough use to know what a second
    /// machine would be worth.
    public static let turnsWorthCounting = ProInvitation.minimumTurns

    /// "142 turns finished with your agents", once there are enough to count.
    public static func turnsLine(_ facts: Facts) -> String? {
        guard facts.turns >= turnsWorthCounting else { return nil }
        return Localized.text("%lld turns finished with your agents", facts.turns)
    }

    /// What the sheet leads with: the person's own turns, or what Pro is.
    public static func headline(_ facts: Facts) -> String {
        turnsLine(facts) ?? ProOffer.headline
    }

    /// The unlimited-servers perk told with the person's own servers: the ones resting since the Pro week first, else
    /// the one server the free copy connects. Nothing to say with no server saved, or with several and none resting.
    public static func serversLine(_ facts: Facts) -> String? {
        if !facts.resting.isEmpty {
            return Localized.text(
                "Resting now: %@. Pro keeps every server connected, in one session list across your tailnet.",
                facts.resting.formatted(.list(type: .and)))
        }
        guard facts.connected.count == ProOffer.freeServerLimit, let name = facts.connected.first else { return nil }
        return Localized.text(
            "You connect to %@. Pro adds every other machine on your tailnet to the same session list.", name)
    }

    /// `ProOffer.perks` with the servers perk told about the person where there is something to tell.
    public static func perks(_ facts: Facts, liveActivities: Bool = false) -> [ProOffer.Perk] {
        let general = ProOffer.perks(liveActivities: liveActivities)
        guard let servers = serversLine(facts), let first = general.first else { return general }
        return [ProOffer.Perk(symbol: first.symbol, text: servers)] + general.dropFirst()
    }
}
