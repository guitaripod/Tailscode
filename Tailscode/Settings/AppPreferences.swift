import UIKit

/// User-facing app preferences, backed by `UserDefaults`.
enum AppPreferences {
    nonisolated(unsafe) private static let defaults = UserDefaults.standard

    enum Appearance: String, CaseIterable {
        case system, light, dark
        var title: String {
            switch self {
            case .system: return "System"
            case .light: return "Light"
            case .dark: return "Dark"
            }
        }
        var style: UIUserInterfaceStyle {
            switch self {
            case .system: return .unspecified
            case .light: return .light
            case .dark: return .dark
            }
        }
    }

    static var appearance: Appearance {
        get { Appearance(rawValue: defaults.string(forKey: "pref.appearance") ?? "") ?? .system }
        set { defaults.set(newValue.rawValue, forKey: "pref.appearance") }
    }

    static var autoExpandThinking: Bool {
        get { defaults.bool(forKey: "pref.autoExpandThinking") }
        set { defaults.set(newValue, forKey: "pref.autoExpandThinking") }
    }

    static var hapticsEnabled: Bool {
        get { defaults.object(forKey: "pref.haptics") == nil ? true : defaults.bool(forKey: "pref.haptics") }
        set { defaults.set(newValue, forKey: "pref.haptics") }
    }

    static var sendOnReturn: Bool {
        get { defaults.bool(forKey: "pref.sendOnReturn") }
        set { defaults.set(newValue, forKey: "pref.sendOnReturn") }
    }

    /// Where the Home composer's next message goes: the last server and
    /// project the user explicitly aimed at or sent to.
    static var lastComposeTarget: (profileID: String, directory: String?)? {
        get {
            guard let profileID = defaults.string(forKey: "pref.composeTarget.profile") else {
                return nil
            }
            return (profileID, defaults.string(forKey: "pref.composeTarget.directory"))
        }
        set {
            defaults.set(newValue?.profileID, forKey: "pref.composeTarget.profile")
            defaults.set(newValue?.directory, forKey: "pref.composeTarget.directory")
        }
    }

    static var promptEnhancement: Bool {
        get {
            defaults.object(forKey: "pref.promptEnhancement") == nil
                ? true : defaults.bool(forKey: "pref.promptEnhancement")
        }
        set { defaults.set(newValue, forKey: "pref.promptEnhancement") }
    }

    @MainActor
    static func applyAppearance() {
        let style = appearance.style
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.overrideUserInterfaceStyle = style
            }
        }
    }
}
