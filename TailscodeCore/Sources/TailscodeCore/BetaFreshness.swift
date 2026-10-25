import Foundation

/// Whether a beta mark has something to announce. A fresh mark is announced once; a settled one
/// holds perfectly still.
public enum BetaFreshness: Sendable, Equatable {
    case unseen
    case changed
    case settled

    public var isFresh: Bool { self != .settled }

    public static func read(seen: SoftwareVersion?, current: SoftwareVersion, card: BetaCard) -> BetaFreshness {
        guard let seen else { return .unseen }
        guard let newest = card.changes.map(\.since).max(), seen < newest, newest <= current else {
            return .settled
        }
        return .changed
    }
}

/// The version each feature's card was last opened at, one key per feature under the shared defaults.
public enum BetaSeenStore {
    public static let keyPrefix = "tailscode.beta.seen."
    public static let didChange = Notification.Name("tailscode.beta.didChange")

    public static func key(_ feature: BetaFeature) -> String { keyPrefix + feature.rawValue }

    public static func seen(_ feature: BetaFeature, defaults: UserDefaults = .standard) -> SoftwareVersion? {
        defaults.string(forKey: key(feature)).flatMap(SoftwareVersion.init)
    }

    public static func markSeen(
        _ feature: BetaFeature, at version: SoftwareVersion, defaults: UserDefaults = .standard
    ) {
        guard defaults.string(forKey: key(feature)) != version.raw else { return }
        defaults.set(version.raw, forKey: key(feature))
        StoreNotice.post(didChange)
    }

    public static func freshness(
        _ feature: BetaFeature, current: SoftwareVersion, defaults: UserDefaults = .standard
    ) -> BetaFreshness {
        BetaFreshness.read(seen: seen(feature, defaults: defaults), current: current, card: feature.card)
    }
}
