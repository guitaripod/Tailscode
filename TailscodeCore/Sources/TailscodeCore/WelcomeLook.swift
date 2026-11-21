import Foundation

/// The look a newcomer starts in, and the one small choice the welcome offers about it.
///
/// Someone opening the app for the first time is dressed in Outer Rim, the theme that is a place
/// as well as a palette, because a first screen in the system's plain colours says nothing about
/// what the app can look like. It is a start and not a rule: the welcome names it in one line with
/// the plain look beside it, one press apart, and Settings has every other theme. Nobody who was
/// here before is repainted: a client that already holds servers, or a choice, is only marked as
/// welcomed.
public struct WelcomeLook: Sendable, Equatable {
    public struct Choice: Sendable, Equatable, Identifiable {
        public let id: String
        public let title: String
        public let isChosen: Bool
    }

    public let title: String
    public let caption: String
    public let choices: [Choice]

    /// The theme a first launch wears.
    public static let newcomerID = AppTheme.outerRim.id

    /// Set once a client has decided whether its person is new, so the decision is made once.
    public static let welcomedKey = "tailscode.theme.welcomed"

    /// The theme to store for this launch, or nil to leave everything as it is: only somebody
    /// new, who has chosen nothing, is dressed.
    public static func themeForNewcomer(isNewcomer: Bool, stored: String?) -> String? {
        isNewcomer && stored == nil ? newcomerID : nil
    }

    /// The row the welcome draws: the newcomer's look and the look this client wore before there
    /// was one (`plain`: the system's own colours on the platforms that have them, a theme on the
    /// desktop that paints itself).
    public static func reading(wearing: String, plain: String) -> WelcomeLook {
        let ids = plain == newcomerID ? [newcomerID] : [newcomerID, plain]
        return WelcomeLook(
            title: Localized.text("Look"),
            caption: Localized.text("Every other theme is in Settings."),
            choices: ids.map { id in
                Choice(
                    id: id,
                    title: id == ThemeSelection.systemID ? Localized.text("System") : AppTheme.named(id).name,
                    isChosen: wearing == id)
            })
    }
}

extension ThemeSelection {
    /// Decides, once, whether this is somebody's first launch, and dresses a newcomer. A client
    /// calls it at the point where it knows whether anything was here before, which is never
    /// before saved state can be read. True when it changed what the app wears.
    @discardableResult
    public static func welcome(newcomer: Bool) -> Bool {
        let store = UserDefaults.standard
        guard !store.bool(forKey: WelcomeLook.welcomedKey) else { return false }
        store.set(true, forKey: WelcomeLook.welcomedKey)
        guard
            let id = WelcomeLook.themeForNewcomer(
                isNewcomer: newcomer, stored: store.string(forKey: themeKey))
        else { return false }
        setThemeID(id)
        return true
    }

    /// The look this client wears when nothing is stored, as the welcome names it.
    public static var plainID: String { fallbackID }

    /// The welcome's row as things stand.
    public static var welcomeLook: WelcomeLook {
        WelcomeLook.reading(wearing: themeID, plain: plainID)
    }
}
