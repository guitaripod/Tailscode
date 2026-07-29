import UIKit

/// User-facing app preferences, backed by `UserDefaults`.
enum AppPreferences {
    nonisolated(unsafe) private static let defaults = UserDefaults.standard

    /// `UserDefaults.bool(forKey:)` reports false for an absent key, which would
    /// silently opt every existing install out of a preference that ships on.
    private static func flag(_ key: String, default fallback: Bool) -> Bool {
        defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
    }

    enum Appearance: String, CaseIterable {
        case system, light, dark
        var title: String {
            switch self {
            case .system: return String(localized: "System")
            case .light: return String(localized: "Light")
            case .dark: return String(localized: "Dark")
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
        get { flag("pref.haptics", default: true) }
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

    /// opencode go's monthly dollar cap. The first subscription month runs on a
    /// promotional $40 ceiling while the published figure is $60, so the estimate
    /// has to be told which one applies.
    static var goMonthlyCap: Double {
        get {
            let stored = defaults.double(forKey: "pref.go.monthlyCap")
            return stored > 0 ? stored : 40
        }
        set { defaults.set(newValue, forKey: "pref.go.monthlyCap") }
    }

    /// Day of the month the opencode go subscription renews; `0` means infer it
    /// from the oldest Go request on record.
    static var goBillingDay: Int {
        get { defaults.integer(forKey: "pref.go.billingDay") }
        set { defaults.set(newValue, forKey: "pref.go.billingDay") }
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
