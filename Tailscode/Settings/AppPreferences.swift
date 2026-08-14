import TailscodeCore
import UIKit

/// User-facing app preferences, backed by `UserDefaults`.
enum AppPreferences {
    nonisolated(unsafe) private static let defaults = UserDefaults.standard

    /// `UserDefaults.bool(forKey:)` reports false for an absent key, which would
    /// silently opt every existing install out of a preference that ships on.
    private static func flag(_ key: String, default fallback: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }

    typealias Appearance = ThemeAppearance

    /// Light or dark is half of one choice, and the theme is the other half — both belong to
    /// `ThemeSelection`, under the two keys every client reads. The phone got here first with a key
    /// of its own, so an install that already pinned an appearance keeps it.
    static var appearance: Appearance {
        get { ThemeSelection.appearance }
        set { ThemeSelection.setAppearance(newValue) }
    }

    static var theme: AppTheme? {
        ThemeSelection.usesSystemPalette ? nil : ThemeSelection.theme
    }

    /// Called once before any window exists: the client's own default is the system's own colours,
    /// and a pin written under the old key is carried across.
    static func adoptThemeDefaults() {
        ThemeSelection.fallbackID = ThemeSelection.systemID
        ThemeSelection.mirrorSuiteName = UsageWidgetStore.suiteName
        ThemeSelection.mirror()
        guard let legacy = defaults.string(forKey: "pref.appearance") else { return }
        defaults.removeObject(forKey: "pref.appearance")
        guard defaults.string(forKey: ThemeSelection.appearanceKey) == nil,
            let pinned = ThemeAppearance(rawValue: legacy)
        else { return }
        ThemeSelection.setAppearance(pinned)
    }

    static var autoExpandThinking: Bool {
        get { defaults.bool(forKey: "pref.autoExpandThinking") }
        set { defaults.set(newValue, forKey: "pref.autoExpandThinking") }
    }

    /// A collapsed run of agent steps renders as a slim line instead of a card;
    /// ships on so transcripts stay out of the way unless someone asks to see
    /// the roomier collapsed form.
    static var compactActivity: Bool {
        get { flag("pref.compactActivity", default: true) }
        set { defaults.set(newValue, forKey: "pref.compactActivity") }
    }

    static var hapticsEnabled: Bool {
        get { flag("pref.haptics", default: true) }
        set { defaults.set(newValue, forKey: "pref.haptics") }
    }

    /// How hard every cue lands, 0…1. Ships at the hardware's ceiling: the setting exists to be
    /// dialled down by someone who finds it too much, not discovered by someone who finds the
    /// phone too quiet.
    static var hapticIntensity: Double {
        get {
            guard defaults.object(forKey: "pref.hapticIntensity") != nil else {
                return HapticStrength.standard
            }
            return HapticStrength.clamped(defaults.double(forKey: "pref.hapticIntensity"))
        }
        set { defaults.set(HapticStrength.clamped(newValue), forKey: "pref.hapticIntensity") }
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
        get { flag("pref.promptEnhancement", default: true) }
        set { defaults.set(newValue, forKey: "pref.promptEnhancement") }
    }

    /// A ping when a turn this device was watching reaches idle.
    static var notifyTurnComplete: Bool {
        get { flag("pref.notify.turnComplete", default: true) }
        set { defaults.set(newValue, forKey: "pref.notify.turnComplete") }
    }

    /// A ping when an agent stops to ask for permission or a decision.
    static var notifyApprovals: Bool {
        get { flag("pref.notify.approvals", default: true) }
        set { defaults.set(newValue, forKey: "pref.notify.approvals") }
    }

    /// A ping the first time a usage window crosses `UsageWarnings.threshold`
    /// within its reset period.
    static var notifyUsageWarnings: Bool {
        get { flag("pref.notify.usage", default: false) }
        set { defaults.set(newValue, forKey: "pref.notify.usage") }
    }

    /// Whether this device stays registered with claude-bridge for server-sent
    /// pushes. Off unregisters the APNs token, which is the only thing that
    /// actually stops a server pushing — a local preference cannot suppress an
    /// alert the bridge already sent.
    static var pushAlertsEnabled: Bool {
        get { flag("pref.notify.serverPush", default: true) }
        set { defaults.set(newValue, forKey: "pref.notify.serverPush") }
    }

    static var liveActivitiesEnabled: Bool {
        get { flag("pref.liveActivities", default: true) }
        set { defaults.set(newValue, forKey: "pref.liveActivities") }
    }

    @MainActor
    static func applyAppearance() {
        Theme.Chrome.apply()
    }
}
