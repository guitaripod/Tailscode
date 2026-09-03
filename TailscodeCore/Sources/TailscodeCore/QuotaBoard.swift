import CodingAgentKit
import Foundation

/// Which providers the account's quota picture shows, in what order, and whether the tightest
/// window leads it. The reading is the account's; the arrangement is the person's.
///
/// A board that re-sorts itself by pressure on every poll is a board whose cards move while
/// they are being read, so the default order is the person's own and it changes only when they
/// change it. A provider nobody spends against — a Grok login on a machine that never runs Grok,
/// a reseller whose window is a curiosity — is hidden here rather than scrolled past on every
/// visit, and the hiding follows the account wherever the account is glanced at, never where a
/// wall is in the way of a send: a hidden provider's used-up window still speaks above the chat
/// that would spend against it, because that is a fact about the next send rather than a card.
public struct QuotaBoardPreferences: Codable, Sendable, Equatable {
    /// The rule the visible cards are laid out by.
    public enum Arrangement: String, Codable, Sendable, CaseIterable {
        /// The person's own order — the default, because a card that stays put can be found.
        case custom
        /// The window closest to its wall first, re-sorted as the numbers move.
        case tightestFirst
        /// Alphabetical by provider.
        case byName

        public var title: String {
            switch self {
            case .custom: return Localized.text("My order")
            case .tightestFirst: return Localized.text("Tightest first")
            case .byName: return Localized.text("By name")
            }
        }
    }

    /// Provider keys the board leaves out.
    public var hidden: Set<String>
    /// Provider keys in the order the person put them; a key not listed follows in the catalog's
    /// own order, so a provider that appears for the first time lands where it belongs.
    public var order: [String]
    public var arrangement: Arrangement
    /// Whether the tightest window across the visible providers leads the board.
    public var leadsWithTightest: Bool

    public init(
        hidden: Set<String> = [], order: [String] = [], arrangement: Arrangement = .custom,
        leadsWithTightest: Bool = true
    ) {
        self.hidden = hidden
        self.order = order
        self.arrangement = arrangement
        self.leadsWithTightest = leadsWithTightest
    }

    public static let `default` = QuotaBoardPreferences()

    public func isHidden(_ key: String) -> Bool { hidden.contains(key) }

    public mutating func setHidden(_ key: String, _ value: Bool) {
        if value { hidden.insert(key) } else { hidden.remove(key) }
    }

    /// Moves a provider one place toward the front or the back of the person's order. A move is
    /// a decision that the board is the person's, so it also switches the arrangement to custom —
    /// dragging a card while the list sorts itself by pressure would be a move nobody could see.
    public mutating func move(_ key: String, by offset: Int, among keys: [String]) {
        var ordered = QuotaBoard.customOrder(keys, preferences: self)
        guard let index = ordered.firstIndex(of: key) else { return }
        let target = min(max(index + offset, 0), ordered.count - 1)
        guard target != index else { return }
        ordered.remove(at: index)
        ordered.insert(key, at: target)
        order = ordered
        arrangement = .custom
    }
}

/// Where the board's preferences live: one JSON value under the shared defaults, so the strip, the
/// panel and Home all read the same board, and a change anywhere is announced to all of them.
public enum QuotaBoardStore {
    public static let defaultsKey = "tailscode.quotaBoard"
    public static let didChange = Notification.Name("tailscode.quotaBoard.didChange")

    public static var current: QuotaBoardPreferences {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
            let stored = try? JSONDecoder().decode(QuotaBoardPreferences.self, from: data)
        else { return .default }
        return stored
    }

    public static func save(_ preferences: QuotaBoardPreferences) {
        if preferences == .default {
            UserDefaults.standard.removeObject(forKey: defaultsKey)
        } else if let data = try? JSONEncoder().encode(preferences) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
        NotificationCenter.default.post(name: didChange, object: nil)
    }

    public static func update(_ change: (inout QuotaBoardPreferences) -> Void) {
        var preferences = current
        change(&preferences)
        save(preferences)
    }
}

/// The board's arithmetic: which providers a reader can choose between, which of them are shown,
/// in what order, and which window leads. Every client draws from these and decides nothing.
public enum QuotaBoard {
    /// A provider's identity on the board — the brand where the name has one, else the name
    /// itself in lower case, so two servers spelling one house differently are one card and one
    /// switch.
    public static func key(providerName: String) -> String {
        ProviderBrand.slug(providerName) ?? providerName.lowercased()
    }

    public static func key(_ holding: QuotaHolding) -> String {
        key(providerName: holding.providerName)
    }

    /// The order the houses are listed in when the person has expressed none: the account
    /// subscriptions people actually run agents on, then the metered doors, then anything else
    /// a server reports, by name.
    public static let catalogOrder = ["claude", "opencode", "grok", "ollama-cloud", "deepseek"]

    /// One switch on the board: a provider the person can show or hide, whether the account
    /// reported numbers for it, and where its colour comes from.
    public struct Choice: Sendable, Equatable, Identifiable {
        public let key: String
        public let name: String
        public let isHidden: Bool
        /// Whether a card exists to show. A provider the client only knows how to ask for — a
        /// balance behind a key nobody has set — is offered so the invitation can be hidden too.
        public let isReported: Bool

        public var id: String { key }

        public init(key: String, name: String, isHidden: Bool, isReported: Bool) {
            self.key = key
            self.name = name
            self.isHidden = isHidden
            self.isReported = isReported
        }
    }

    /// A provider a client can offer the board without a reading: it exists as an invitation to
    /// add a key, and the person may not want to be invited.
    public struct Offer: Sendable, Equatable {
        public let key: String
        public let name: String

        public init(key: String, name: String) {
            self.key = key
            self.name = name
        }
    }

    /// Every provider the board could show, in the person's order — the reported ones and the
    /// offered ones together — so the switches are one row that does not rearrange itself as
    /// readings arrive.
    public static func choices(
        holdings: [QuotaHolding], offers: [Offer] = [], preferences: QuotaBoardPreferences
    ) -> [Choice] {
        var names: [String: String] = [:]
        var reported: Set<String> = []
        var keys: [String] = []
        for holding in holdings {
            let key = key(holding)
            if names[key] == nil {
                names[key] = holding.providerName
                keys.append(key)
            }
            reported.insert(key)
        }
        for offer in offers where names[offer.key] == nil {
            names[offer.key] = offer.name
            keys.append(offer.key)
        }
        return customOrder(keys, preferences: preferences).map { key in
            Choice(
                key: key, name: names[key] ?? key, isHidden: preferences.isHidden(key),
                isReported: reported.contains(key))
        }
    }

    /// The holdings a reader sees, in the order the board says.
    public static func arrange(
        _ holdings: [QuotaHolding], preferences: QuotaBoardPreferences
    ) -> [QuotaHolding] {
        let visible = holdings.filter { !preferences.isHidden(key($0)) }
        switch preferences.arrangement {
        case .custom:
            let keys = customOrder(visible.map(key), preferences: preferences)
            return visible.sorted { lhs, rhs in
                (keys.firstIndex(of: key(lhs)) ?? .max) < (keys.firstIndex(of: key(rhs)) ?? .max)
            }
        case .tightestFirst:
            return visible.enumerated().sorted { lhs, rhs in
                lhs.element.peak == rhs.element.peak
                    ? lhs.offset < rhs.offset : lhs.element.peak > rhs.element.peak
            }.map(\.element)
        case .byName:
            return visible.sorted {
                $0.providerName.localizedCaseInsensitiveCompare($1.providerName)
                    == .orderedAscending
            }
        }
    }

    /// Whether an offer is shown: hidden switches it off like any card.
    public static func shows(_ offer: Offer, preferences: QuotaBoardPreferences) -> Bool {
        !preferences.isHidden(offer.key)
    }

    /// The window that leads the board: across the visible providers, the one closest to its
    /// wall. A balance never leads on its own account — money with no ceiling is not a window
    /// and has no countdown — except an empty one, which is a wall like any other. Nil when the
    /// person has switched the lead off or nothing is visible.
    public static func lead(
        _ visible: [QuotaHolding], preferences: QuotaBoardPreferences
    ) -> (holding: QuotaHolding, gauge: UsageQuota.Gauge)? {
        guard preferences.leadsWithTightest else { return nil }
        let candidates = visible.flatMap { holding in
            holding.gauges
                .filter { !isBalance($0) || $0.fraction >= QuotaSurface.exhaustedFloor }
                .map { (holding, $0) }
        }
        return candidates.max { $0.1.fraction < $1.1.fraction }
    }

    /// Money with no ceiling is a balance rather than a window — the same rule every renderer
    /// recognises one by.
    public static func isBalance(_ gauge: UsageQuota.Gauge) -> Bool {
        gauge.usedUSD != nil && gauge.limitUSD == nil
    }

    /// The person's order over a set of keys: the ones they placed first, in their order, then
    /// the rest in the catalog's, then anything the catalog does not know by name.
    public static func customOrder(_ keys: [String], preferences: QuotaBoardPreferences)
        -> [String]
    {
        var seen: Set<String> = []
        var out: [String] = []
        for key in preferences.order where keys.contains(key) && seen.insert(key).inserted {
            out.append(key)
        }
        for key in catalogOrder where keys.contains(key) && seen.insert(key).inserted {
            out.append(key)
        }
        for key in keys.sorted() where seen.insert(key).inserted {
            out.append(key)
        }
        return out
    }
}
