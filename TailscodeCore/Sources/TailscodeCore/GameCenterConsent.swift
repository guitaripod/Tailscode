import Foundation

/// Whether this device asked to take part in Game Center.
///
/// Asking GameKit to authenticate is what makes iOS raise its own "Sign in to Game Center"
/// banner, over whatever is on screen, and it raises it again whenever the app returns to the
/// front. A person who never opened the trophy case has no use for either, so nothing
/// authenticates until the person asks. Anyone who had already reported to Game Center before
/// this existed is counted as having asked, so no trophy that was being sent stops being sent.
public struct GameCenterConsent: @unchecked Sendable {
    public static let shared = GameCenterConsent()

    public static let key = "tailscode.gamecenter.consent"

    /// Set by the coordinators the first time a player reports, which is how a person who was
    /// already signed in before the choice existed is recognised.
    public static let reportedPlayerKey = "tailscode.gamecenter.player"

    private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// A choice that was made wins; with none, having reported before means yes.
    public var isOn: Bool {
        if let chosen = defaults.object(forKey: Self.key) as? Bool { return chosen }
        return defaults.string(forKey: Self.reportedPlayerKey) != nil
    }

    public func turnOn() {
        defaults.set(true, forKey: Self.key)
    }

    public func turnOff() {
        defaults.set(false, forKey: Self.key)
    }
}
