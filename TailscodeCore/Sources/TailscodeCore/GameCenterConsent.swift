import Foundation

/// Whether this device asked to take part in Game Center.
///
/// Asking GameKit to authenticate is what makes iOS raise its own "Sign in to Game Center"
/// banner, over whatever is on screen, and it raises it again whenever the app returns to the
/// front. A person who never opened the trophy case has no use for either, so nothing
/// authenticates until the person asks, and having reported before is not asking.
public struct GameCenterConsent: @unchecked Sendable {
    public static let shared = GameCenterConsent()

    public static let key = "tailscode.gamecenter.consent"

    /// Set by the coordinators the first time a player reports, so a different player's cache
    /// never stands in for this one's.
    public static let reportedPlayerKey = "tailscode.gamecenter.player"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    public var isOn: Bool {
        defaults.bool(forKey: Self.key)
    }

    public func turnOn() {
        defaults.set(true, forKey: Self.key)
    }

    public func turnOff() {
        defaults.set(false, forKey: Self.key)
    }
}
