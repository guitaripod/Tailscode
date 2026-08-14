import Foundation

/// Which of a theme's two faces the app wears: the system's own preference by default, or pinned.
///
/// Independent of *which* theme, because picking Gruvbox should not also decide whether it is
/// night, and pinning light should not throw the theme away.
public enum ThemeAppearance: String, CaseIterable, Sendable {
    case system
    case light
    case dark

    public var title: String {
        switch self {
        case .system: return Localized.text("Follow the system")
        case .light: return Localized.text("Always light")
        case .dark: return Localized.text("Always dark")
        }
    }

    /// The appearance to render, given what the system is currently doing. `nil` from the system
    /// case is the point: nothing is pinned, so nothing is overridden.
    public var pinnedDark: Bool? {
        switch self {
        case .system: return nil
        case .light: return false
        case .dark: return true
        }
    }
}

/// The one place any client asks which theme it is wearing.
///
/// Stored by id rather than by index, so reordering the catalog or dropping a theme cannot
/// silently repaint someone's window — an unknown id falls back. Both keys are the ones the Linux
/// desktop has always written, so a tailnet full of clients agrees on the vocabulary even though
/// each one draws it with its own toolkit.
public enum ThemeSelection {
    nonisolated(unsafe) private static let defaults = UserDefaults.standard
    public static let themeKey = "tailscode.theme"
    public static let appearanceKey = "tailscode.appearance"
    /// Posted when the choice changes. Every client redraws off this rather than polling, because
    /// a theme is picked while its result is on screen behind the picker.
    public static let didChange = Notification.Name("tailscode.theme.didChange")

    /// The id that means "no palette of ours": the platform paints in its own colours and
    /// materials. It is a choice rather than an absence, because on a system whose chrome is a
    /// live material — Liquid Glass — the honest default is the one the OS drew, and a client that
    /// forced a canvas on every install would repaint an app nobody asked to have repainted.
    public static let systemID = "system"

    /// What this client wears when nothing is stored. The desktop that owns its own chrome starts
    /// on a theme; the two that borrow the system's start on the system.
    public nonisolated(unsafe) static var fallbackID: String = AppTheme.fallback.id

    public static var themeID: String {
        defaults.string(forKey: themeKey) ?? fallbackID
    }

    /// Whether the platform's own colours are in force. Clients with no palette of their own to
    /// fall back to — the desktop that paints every pixel itself — never ask.
    public static var usesSystemPalette: Bool { themeID == systemID }

    public static var theme: AppTheme { AppTheme.named(themeID) }

    public static func setTheme(_ theme: AppTheme) {
        setThemeID(theme.id)
    }

    public static func setThemeID(_ id: String) {
        write(id == fallbackID ? nil : id, forKey: themeKey)
    }

    public static var appearance: ThemeAppearance {
        ThemeAppearance(rawValue: defaults.string(forKey: appearanceKey) ?? "") ?? .system
    }

    public static func setAppearance(_ value: ThemeAppearance) {
        write(value == .system ? nil : value.rawValue, forKey: appearanceKey)
    }

    /// The palette as the app will actually draw it: the chosen theme's own face for this
    /// appearance, every slot walked to its contrast floor.
    public static func palette(dark: Bool) -> Palette {
        theme.palette(dark: dark).corrected()
    }

    /// The choice with no stored state in it, so the one step that turns a saved id into colours
    /// can be asserted without a display or a defaults domain.
    public static func palette(themeID: String?, dark: Bool) -> Palette {
        AppTheme.named(themeID).palette(dark: dark).corrected()
    }

    /// Where the choice is repeated for processes that are not the app.
    ///
    /// A widget draws in an extension with its own defaults domain, so it cannot see a theme picked
    /// in the app it belongs to — and a Home Screen that stays Rosé Pine while the app it opens is
    /// Gruvbox reads as two apps. The app names a shared suite once and every later write lands in
    /// both, which is the whole mechanism: the extension reads a copy, never the app's own domain.
    public nonisolated(unsafe) static var mirrorSuiteName: String?

    /// Repeats the current choice into the mirror. Called once at launch, because a choice made
    /// before there was a mirror is still the choice.
    public static func mirror() {
        guard let suite = mirrorSuiteName, let shared = UserDefaults(suiteName: suite) else {
            return
        }
        shared.set(defaults.string(forKey: themeKey), forKey: themeKey)
        shared.set(defaults.string(forKey: appearanceKey), forKey: appearanceKey)
    }

    /// The theme another process picked, read from the mirror. `fallbackID` is not consulted: an
    /// extension that has never been told anything wears what the app last wrote, and the absence
    /// of a write is itself the answer — the platform's own colours.
    public static func mirrored(suiteName: String) -> (themeID: String, appearance: ThemeAppearance)
    {
        let shared = UserDefaults(suiteName: suiteName)
        let id = shared?.string(forKey: themeKey) ?? systemID
        let appearance =
            ThemeAppearance(rawValue: shared?.string(forKey: appearanceKey) ?? "") ?? .system
        return (id, appearance)
    }

    private static func write(_ value: String?, forKey key: String) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
        if let suite = mirrorSuiteName, let shared = UserDefaults(suiteName: suite) {
            shared.set(value, forKey: key)
        }
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}
