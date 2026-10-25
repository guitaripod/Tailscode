import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// Everything about the window a person is allowed to decide, in one store. Sizes are per area
/// rather than one global slider, because a chat list you glance at and a transcript you read want
/// different type; pane positions are remembered because a window someone shaped once should open
/// that way.
enum Preferences {
    enum Area: String, CaseIterable {
        case chrome
        case prose
        case mono

        var title: String {
            switch self {
            case .chrome: return Localized.text("Chat list and pills")
            case .prose: return Localized.text("Transcript prose")
            case .mono: return Localized.text("Code, tools and composer")
            }
        }
    }

    enum Divider: String {
        case sidebar
        case project
        case terminal
    }

    private static var defaults: UserDefaults { .standard }

    /// Every setting is written through the file, not merely to the defaults: the defaults are
    /// where readers look, the file is what survives a reinstall.
    private static func write(_ value: Any?, forKey key: String) {
        SettingsFile.set(value, forKey: key)
    }

    /// Window geometry, so the app opens the size and place it was left — including maximized,
    /// which is not a size and has to be remembered separately.
    /// The size to open at, never larger than the screen it opens on. 1400x900 is a good desktop
    /// default and a bad one on a 1280x800 handheld or a small laptop, where it asks for a window
    /// wider and taller than the whole display; the same clamp catches a size remembered from a
    /// monitor that is no longer plugged in.
    static var windowSize: (width: Int32, height: Int32) {
        let width = defaults.integer(forKey: "tailscode.window.width")
        let height = defaults.integer(forKey: "tailscode.window.height")
        let wanted: (Int32, Int32) =
            width > 200 && height > 200 ? (Int32(width), Int32(height)) : (1400, 900)
        let screen = Int32(tailscode_monitor_workarea_height(nil))
        guard screen > 400 else { return wanted }
        // Only the height is knowable from this call, and it is the one that actually traps people:
        // a window taller than the display puts its own composer under the panel.
        return (wanted.0, min(wanted.1, Int32(Double(screen) * 0.94)))
    }

    static func setWindowSize(width: Int32, height: Int32) {
        guard width > 200, height > 200 else { return }
        guard windowSize != (width, height) else { return }
        write(Int(width), forKey: "tailscode.window.width")
        write(Int(height), forKey: "tailscode.window.height")
    }

    static var windowMaximized: Bool {
        defaults.bool(forKey: "tailscode.window.maximized")
    }

    static func setWindowMaximized(_ value: Bool) {
        guard value != windowMaximized else { return }
        write(value, forKey: "tailscode.window.maximized")
    }

    /// The conversation that was open, reopened on the next launch.
    static var lastSession: String? {
        defaults.string(forKey: "tailscode.lastSession")
    }

    static func setLastSession(_ id: String?) {
        guard id != lastSession else { return }
        write(id, forKey: "tailscode.lastSession")
    }

    /// The page Settings was left on, so it opens where the last visit ended.
    static var settingsPage: String? {
        defaults.string(forKey: "tailscode.settings.page")
    }

    static func setSettingsPage(_ name: String) {
        guard name != settingsPage else { return }
        write(name, forKey: "tailscode.settings.page")
    }

    static func scale(_ area: Area) -> Double {
        let stored = defaults.double(forKey: "tailscode.scale.\(area.rawValue)")
        return stored == 0 ? 1.0 : stored
    }

    static func setScale(_ value: Double, for area: Area) {
        write(
            min(2.5, max(0.6, (value * 20).rounded() / 20)),
            forKey: "tailscode.scale.\(area.rawValue)")
    }

    static func stepScale(_ delta: Double, for area: Area) {
        setScale(scale(area) + delta, for: area)
    }

    static func resetScales() {
        for area in Area.allCases { write(nil, forKey: "tailscode.scale.\(area.rawValue)") }
    }

    /// Terminal type is VTE's own business — it scales its font rather than its CSS.
    static var terminalScale: Double {
        let stored = defaults.double(forKey: "tailscode.scale.terminal")
        return stored == 0 ? 1.0 : stored
    }

    static func setTerminalScale(_ value: Double) {
        write(min(2.5, max(0.6, (value * 20).rounded() / 20)), forKey: "tailscode.scale.terminal")
    }

    /// Whether the presence orb lives at the foot of the sidebar. The choice itself is Core's
    /// (`PresenceOrbSetting`, one key on every client); this end makes the write durable and lets
    /// the harness light the orb with an environment variable instead of a click.
    static var presenceOrb: Bool {
        if let raw = ProcessInfo.processInfo.environment["TAILSCODE_ORB"] { return raw == "1" }
        return PresenceOrbSetting.isEnabled
    }

    static func setPresenceOrb(_ value: Bool) {
        PresenceOrbSetting.setEnabled(value)
        write(value ? true : nil, forKey: PresenceOrbSetting.defaultsKey)
    }

    /// Whether a message a spent window stopped is sent again when the window reopens. The choice
    /// is Core's (`AutoResumeSetting`, one key on every client); this end makes the write durable
    /// on a desktop whose defaults are keyed to the executable path.
    static var autoResume: Bool {
        if let raw = ProcessInfo.processInfo.environment["TAILSCODE_RESUME"] { return raw == "1" }
        return AutoResumeSetting.isEnabled
    }

    static func setAutoResume(_ value: Bool) {
        AutoResumeSetting.setEnabled(value)
        write(value ? nil : false, forKey: AutoResumeSetting.defaultsKey)
    }

    static var sendOnReturn: Bool {
        defaults.object(forKey: "tailscode.sendOnReturn") as? Bool ?? true
    }

    static func setSendOnReturn(_ value: Bool) {
        write(value, forKey: "tailscode.sendOnReturn")
    }

    /// An environment override for a switch, so a setting can be tried — or screenshotted, or
    /// asserted in a headless run — without a click.
    private static func flag(_ key: String, environment: String) -> Bool {
        if let raw = ProcessInfo.processInfo.environment[environment] { return raw == "1" }
        return defaults.bool(forKey: key)
    }

    /// Whether the agent's thoughts and tool calls between two prompts fold to one line. On by
    /// default, like the iOS app, so a turn reads as ask → answer until opened.
    static var compactTools: Bool {
        if let raw = ProcessInfo.processInfo.environment["TAILSCODE_COMPACT"] { return raw == "1" }
        if defaults.object(forKey: "tailscode.compactTools") == nil { return true }
        return defaults.bool(forKey: "tailscode.compactTools")
    }

    static func setCompactTools(_ value: Bool) {
        write(value, forKey: "tailscode.compactTools")
    }

    /// Whether an answer wears what it took. The choice itself is Core's (`ResponseStatsSetting`,
    /// one key on every client); this end makes the write durable on a desktop whose defaults are
    /// keyed to the executable path.
    static var responseStats: Bool {
        if let raw = ProcessInfo.processInfo.environment["TAILSCODE_STATS"] { return raw == "1" }
        return ResponseStatsSetting.isEnabled
    }

    static func setResponseStats(_ value: Bool) {
        ResponseStatsSetting.setEnabled(value)
        write(value ? true : nil, forKey: ResponseStatsSetting.defaultsKey)
    }

    /// Whether an address the agent mentions wears a preview card under its paragraph. The choice
    /// is Core's (`LinkEmbedsSetting`, one key on every client, on until turned off); this end makes
    /// the write durable on a desktop whose defaults are keyed to the executable path.
    static var linkEmbeds: Bool {
        if let raw = ProcessInfo.processInfo.environment["TAILSCODE_LINKS"] { return raw == "1" }
        return LinkEmbedsSetting.isEnabled
    }

    static func setLinkEmbeds(_ value: Bool) {
        LinkEmbedsSetting.setEnabled(value)
        write(value ? nil : false, forKey: LinkEmbedsSetting.defaultsKey)
    }

    /// How close the transcript sets its rows. The choice is Core's (`ChatDensitySetting`, one key
    /// on every client); `TAILSCODE_DENSE` is the harness's override of it — `1` is compact, `0`
    /// comfortable — so a density can be shot or asserted without a click, and it is the old
    /// switch's name kept working rather than a second setting.
    static var chatDensity: ChatDensity {
        if let raw = ProcessInfo.processInfo.environment["TAILSCODE_DENSE"] {
            return raw == "1" ? .compact : .comfortable
        }
        return ChatDensitySetting.current
    }

    static func setChatDensity(_ value: ChatDensity) {
        write(value.rawValue, forKey: ChatDensitySetting.key)
        ChatDensitySetting.set(value)
    }

    /// How a turn's thinking and working is drawn: one head, or the flat rows. The choice is Core's
    /// (`ActivityStyleSetting`, one key on every client); `TAILSCODE_ACTIVITY_STYLE` is the
    /// harness's override of it so a style can be shot or asserted without a click.
    static var activityStyle: ActivityStyle {
        if let raw = ProcessInfo.processInfo.environment["TAILSCODE_ACTIVITY_STYLE"],
            let style = ActivityStyle(rawValue: raw)
        {
            return style
        }
        return ActivityStyleSetting.current
    }

    /// What the transcript actually draws: the choice, unless the layers the head is made of are
    /// not on this machine, in which case the lines stand in and the log says so once.
    static var effectiveActivityStyle: ActivityStyle {
        guard activityStyle == .brain else { return .lines }
        guard NeuralAssetFiles.isAvailable else {
            NeuralAssetFiles.reportMissingOnce()
            return .lines
        }
        return .brain
    }

    static func setActivityStyle(_ value: ActivityStyle) {
        write(value.rawValue, forKey: ActivityStyleSetting.key)
        ActivityStyleSetting.set(value)
    }

    /// The old "Tighter rows" switch becomes the density setting once, at launch. All it ever said
    /// was "tighter", which is now the default, so whatever it held — on, off or never touched —
    /// arrives at the density Core says (`ChatDensitySetting.migrate`) unless the person has
    /// already chosen one, and the retired key is let go of so it is never read again.
    static func migrateLegacyDensity() {
        let legacyKey = "tailscode.denseRows"
        guard SettingsFile.stored(forKey: legacyKey) != nil || defaults.object(forKey: legacyKey) != nil
        else { return }
        let legacy = defaults.object(forKey: legacyKey) as? Bool
        if SettingsFile.stored(forKey: ChatDensitySetting.key) == nil,
            defaults.object(forKey: ChatDensitySetting.key) == nil
        {
            write(ChatDensitySetting.migrate(legacyDenseRows: legacy).rawValue, forKey: ChatDensitySetting.key)
        }
        write(nil, forKey: legacyKey)
    }

    static var vimComposer: Bool {
        defaults.bool(forKey: "tailscode.vimComposer")
    }

    static func setVimComposer(_ value: Bool) {
        write(value, forKey: "tailscode.vimComposer")
    }

    /// How tall the prompt box is allowed to get before it scrolls instead of growing.
    static var composerLines: Int {
        let stored = defaults.integer(forKey: "tailscode.composerLines")
        return stored == 0 ? 12 : min(20, max(1, stored))
    }

    static func setComposerLines(_ value: Int) {
        write(min(20, max(1, value)), forKey: "tailscode.composerLines")
    }

    static var transcriptWindow: Int {
        let stored = defaults.integer(forKey: "tailscode.transcriptWindow")
        return stored == 0 ? 400 : min(5000, max(50, stored))
    }

    static func setTranscriptWindow(_ value: Int) {
        write(min(5000, max(50, value)), forKey: "tailscode.transcriptWindow")
    }

    static func divider(_ divider: Divider) -> Int32? {
        let stored = defaults.integer(forKey: "tailscode.divider.\(divider.rawValue)")
        return stored == 0 ? nil : Int32(stored)
    }

    static func setDivider(_ divider: Divider, position: Int32) {
        guard position > 0 else { return }
        write(Int(position), forKey: "tailscode.divider.\(divider.rawValue)")
    }

    static func resetDividers() {
        for divider in [Divider.sidebar, .project, .terminal] {
            write(nil, forKey: "tailscode.divider.\(divider.rawValue)")
        }
    }

    /// Which theme the canvas wears, and which of its two faces. The choice itself belongs to
    /// `ThemeSelection` so all three clients read the same two keys; this end only makes the write
    /// durable, because a desktop's defaults do not survive a reinstall.
    static var themeID: String { ThemeSelection.themeID }

    static var theme: AppTheme { ThemeSelection.theme }

    static func setTheme(_ theme: AppTheme) {
        ThemeSelection.setTheme(theme)
        write(theme.id == AppTheme.fallback.id ? nil : theme.id, forKey: ThemeSelection.themeKey)
    }

    typealias Appearance = ThemeAppearance

    static var appearance: Appearance { ThemeSelection.appearance }

    static func setAppearance(_ value: Appearance) {
        ThemeSelection.setAppearance(value)
        write(value == .system ? nil : value.rawValue, forKey: ThemeSelection.appearanceKey)
    }

    /// Tells libadwaita which scheme to run, which restyles the chrome and flips
    /// `AdwStyleManager.dark` — the one fact the canvas palette is derived from.
    static func applyAppearance() {
        guard let manager = adw_style_manager_get_default() else { return }
        let scheme: AdwColorScheme
        switch appearance {
        case .system: scheme = ADW_COLOR_SCHEME_DEFAULT
        case .light: scheme = ADW_COLOR_SCHEME_FORCE_LIGHT
        case .dark: scheme = ADW_COLOR_SCHEME_FORCE_DARK
        }
        adw_style_manager_set_color_scheme(manager, scheme)
    }
}
