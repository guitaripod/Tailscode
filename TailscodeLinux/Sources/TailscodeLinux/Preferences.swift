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

    /// Tighter vertical rhythm everywhere in the canvas.
    static var denseRows: Bool {
        flag("tailscode.denseRows", environment: "TAILSCODE_DENSE")
    }

    static func setDenseRows(_ value: Bool) {
        write(value, forKey: "tailscode.denseRows")
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

/// The settings window: every knob the app has, live. Nothing here needs an OK — a size change
/// restyles the running window as the slider moves, which is the only honest way to pick one.
/// The settings window, in the desktop's own furniture: an Adwaita preferences window of grouped
/// rows — a theme picker, spin rows for every size, switches for every mode — every one applying
/// live, because the only honest way to pick a size is to watch it change.
enum SettingsDialog {
    static func present(
        parent: UnsafeMutablePointer<GtkWidget>?,
        onLayoutChanged: @escaping @Sendable () -> Void,
        onReloadShortcuts: @escaping @Sendable () -> Void,
        onOrbChanged: @escaping @Sendable () -> Void,
        onDeepSeekChanged: @escaping @Sendable () -> Void
    ) {
        let window = adw_preferences_window_new()!
        gtk_window_set_title(ptr(window), Localized.text("Settings"))
        gtk_window_set_default_size(ptr(window), 560, 720)
        if let parent { gtk_window_set_transient_for(ptr(window), ptr(parent)) }
        gtk_window_set_modal(ptr(window), 0)

        let page = adw_preferences_page_new()!
        adw_preferences_window_add(ptr(window), ptr(page))

        if DemoMode.isActive {
            let demo = group(Localized.text("Demo"), on: page)
            let windowBits = UInt(bitPattern: window)
            adw_preferences_group_add(
                ptr(demo),
                buttonRow(Localized.text("Leave the demo world")) {
                    DemoMode.leave()
                    Task {
                        await ServerDirectory.shared.reload()
                        Gtk.onMain {
                            onLayoutChanged()
                            if let raw = UnsafeMutableRawPointer(bitPattern: windowBits) {
                                gtk_window_close(ptr(raw))
                            }
                        }
                    }
                })
        }

        let appearance = group(Localized.text("Appearance"), on: page)
        let themes = AppTheme.all
        adw_preferences_group_add(
            ptr(appearance),
            comboRow(
                title: Localized.text("Theme"),
                subtitle: Localized.text("The canvas, the terminal and the chrome, together"),
                options: themes.map { "\($0.name) — \($0.blurb)" },
                selected: themes.firstIndex { $0.id == Preferences.themeID } ?? 0
            ) { index in
                Preferences.setTheme(themes[index])
                MatrixTheme.install()
                onLayoutChanged()
            })
        let appearances = Preferences.Appearance.allCases
        adw_preferences_group_add(
            ptr(appearance),
            comboRow(
                title: Localized.text("Light or dark"),
                subtitle: Localized.text("Which of the theme's two faces it wears"),
                options: appearances.map(\.title),
                selected: appearances.firstIndex(of: Preferences.appearance) ?? 0
            ) { index in
                Preferences.setAppearance(appearances[index])
                Preferences.applyAppearance()
                MatrixTheme.install()
                onLayoutChanged()
            })

        let type = group(
            Localized.text("Type size"), on: page,
            description: Localized.text("Percent of the normal size, applied as you change it"))
        for area in Preferences.Area.allCases {
            adw_preferences_group_add(
                ptr(type),
                spinRow(
                    title: area.title, value: Preferences.scale(area) * 100, lower: 60,
                    upper: 250, step: 5
                ) { value in
                    Preferences.setScale(value / 100, for: area)
                    MatrixTheme.install()
                })
        }
        adw_preferences_group_add(
            ptr(type),
            spinRow(
                title: Localized.text("Terminal"), value: Preferences.terminalScale * 100,
                lower: 60, upper: 250, step: 5
            ) { value in
                Preferences.setTerminalScale(value / 100)
                onLayoutChanged()
            })

        let composer = group(Localized.text("Prompt box"), on: page)
        adw_preferences_group_add(
            ptr(composer),
            switchRow(
                title: Localized.text("Return sends the message"),
                subtitle: Localized.text("Shift+Return writes a new line either way"),
                value: Preferences.sendOnReturn
            ) { Preferences.setSendOnReturn($0) })
        adw_preferences_group_add(
            ptr(composer),
            switchRow(
                title: Localized.text("Vim mode"),
                subtitle: Localized.text(
                    "Normal, visual and visual-line: motions, operators, text objects, registers, undo"),
                value: Preferences.vimComposer
            ) { value in
                Preferences.setVimComposer(value)
                onLayoutChanged()
            })
        adw_preferences_group_add(
            ptr(composer),
            spinRow(
                title: Localized.text("Grows to (lines)"),
                subtitle: Localized.text("Starts one line tall; scrolls past this height"),
                value: Double(Preferences.composerLines), lower: 1, upper: 20, step: 1
            ) { value in
                Preferences.setComposerLines(Int(value))
                onLayoutChanged()
            })

        let transcript = group(Localized.text("Transcript"), on: page)
        adw_preferences_group_add(
            ptr(transcript),
            switchRow(
                title: Localized.text("Compact agent steps"),
                subtitle: Localized.text(
                    "Thinking and tool calls between prompts fold to one line you can open"),
                value: Preferences.compactTools
            ) { value in
                Preferences.setCompactTools(value)
                onLayoutChanged()
            })
        adw_preferences_group_add(
            ptr(transcript),
            switchRow(
                title: ResponseStatsSetting.title,
                subtitle: ResponseStatsSetting.explanation,
                value: Preferences.responseStats
            ) { value in
                Preferences.setResponseStats(value)
                onLayoutChanged()
            })
        adw_preferences_group_add(
            ptr(transcript),
            switchRow(
                title: Localized.text("Tighter rows"),
                subtitle: Localized.text("Less air between parts and turns"),
                value: Preferences.denseRows
            ) { value in
                Preferences.setDenseRows(value)
                MatrixTheme.install()
                onLayoutChanged()
            })
        adw_preferences_group_add(
            ptr(transcript),
            spinRow(
                title: Localized.text("Rows kept on screen"),
                subtitle: Localized.text(
                    "Older rows wait behind one button — this keeps a huge chat fast"),
                value: Double(Preferences.transcriptWindow), lower: 50, upper: 5000, step: 50
            ) { value in
                Preferences.setTranscriptWindow(Int(value))
                onLayoutChanged()
            })

        let layout = group(
            Localized.text("Layout"), on: page,
            description: Localized.text(
                "Drag any divider to size a pane — positions are remembered. ^b ^e ^t show or hide the chat list, the file tree and the terminal."))
        adw_preferences_group_add(
            ptr(layout),
            buttonRow(Localized.text("Reset the pane sizes")) {
                Preferences.resetDividers()
                onLayoutChanged()
            })
        adw_preferences_group_add(
            ptr(layout),
            buttonRow(Localized.text("Reset every type size")) {
                Preferences.resetScales()
                Preferences.setTerminalScale(1.0)
                MatrixTheme.install()
                onLayoutChanged()
            })

        let alerts = group(
            Localized.text("Notifications"), on: page,
            description: Localized.text(
                "Raised only while the window is not focused, and withdrawn once a request is answered."))
        adw_preferences_group_add(
            ptr(alerts),
            switchRow(
                title: Localized.text("A turn finishes"),
                subtitle: Localized.text("Any chat, not only the open one"),
                value: Notifier.notifyTurnComplete
            ) { value in
                Notifier.setNotifyTurnComplete(value)
            })
        adw_preferences_group_add(
            ptr(alerts),
            switchRow(
                title: Localized.text("An agent needs you"),
                subtitle: Localized.text("An approval to give or a question to answer"),
                value: Notifier.notifyNeedsYou
            ) { value in
                Notifier.setNotifyNeedsYou(value)
            })
        adw_preferences_group_add(
            ptr(alerts),
            buttonRow(
                Localized.text("Prove the path"),
                subtitle: Localized.text("Sends one notification right now"),
                label: Localized.text("Test")
            ) {
                Notifier.shared.sendTest()
            })

        let watch = group(WatchAccounts.heading, on: page, description: WatchAccounts.description)
        renderWatchAccounts(into: watch, parent: page)

        let usage = group(
            Localized.text("Usage"), on: page,
            description: Localized.text(
                "The full quota picture lives at the foot of the chat list; the DeepSeek key is the one account fact this machine keeps."))
        let deepseekRow = DeepSeekRowHeld()
        let refreshDeepseekRow: @Sendable () -> Void = {
            guard let raw = UnsafeMutableRawPointer(bitPattern: deepseekRow.bits) else { return }
            adw_action_row_set_subtitle(
                ptr(raw),
                DeepSeekCredentials.hasToken
                    ? Localized.text("Saved in the app's secret store")
                    : Localized.text("Not set"))
        }
        let pageBits = UInt(bitPattern: page)
        let deepseek = buttonRow(
            Localized.text("DeepSeek API key"),
            subtitle: DeepSeekCredentials.hasToken
                ? Localized.text("Saved in the app's secret store")
                : Localized.text("Not set"),
            label: Localized.text("Edit")
        ) {
            guard let pageRaw = UnsafeMutableRawPointer(bitPattern: pageBits) else { return }
            DeepSeekKeyDialog.present(parent: ptr(pageRaw)) {
                refreshDeepseekRow()
                onDeepSeekChanged()
            }
        }
        deepseekRow.bits = UInt(bitPattern: deepseek)
        adw_preferences_group_add(ptr(usage), deepseek)

        SummonRows.install(on: page, window: window)

        let keyboard = group(
            Localized.text("Keyboard"), on: page,
            description: Localized.text(
                "? shows every shortcut. Rebind any of them by id in the file below; unknown keys and conflicts are reported rather than guessed at."))
        adw_preferences_group_add(
            ptr(keyboard),
            buttonRow(
                Localized.text("Shortcuts file"), subtitle: ShortcutSet.configURL.path,
                label: Localized.text("Edit")
            ) {
                ShortcutSet.ensureConfigFile()
                let editor = Process()
                editor.executableURL = URL(fileURLWithPath: "/usr/bin/xdg-open")
                editor.arguments = [ShortcutSet.configURL.path]
                try? editor.run()
            })
        adw_preferences_group_add(
            ptr(keyboard),
            buttonRow(
                Localized.text("Apply changes from the file"),
                label: Localized.text("Reload")
            ) {
                onReloadShortcuts()
            })

        let alpha = group(
            Localized.text("Alpha"), on: page,
            description: Localized.text(
                "Early work, off by default: it may cost battery, change shape, or leave"))
        adw_preferences_group_add(
            ptr(alpha),
            switchRow(
                title: Localized.text("Presence orb"),
                subtitle: Localized.text(
                    "A GPU-rendered creature at the foot of the chat list, breathing what every conversation is doing"),
                value: Preferences.presenceOrb
            ) { value in
                Preferences.setPresenceOrb(value)
                onOrbChanged()
            })

        gtk_window_present(ptr(window))
    }

    /// The two video accounts, drawn and redrawn in place. A row's whole content changes the moment
    /// somebody signs in or out, and the settings window is built once — so the group takes back
    /// exactly the rows it put there and adds fresh ones, rather than the window being rebuilt.
    private static func renderWatchAccounts(
        into group: UnsafeMutablePointer<GtkWidget>, parent: UnsafeMutablePointer<GtkWidget>,
        added: WatchRowsHeld = WatchRowsHeld()
    ) {
        for bits in added.rows {
            guard let raw = UnsafeMutableRawPointer(bitPattern: bits) else { continue }
            adw_preferences_group_remove(ptr(group), ptr(raw))
        }
        added.rows = []

        let groupBits = UInt(bitPattern: group)
        let parentBits = UInt(bitPattern: parent)
        let refill: @Sendable () -> Void = {
            Gtk.onMain {
                guard let groupRaw = UnsafeMutableRawPointer(bitPattern: groupBits),
                    let parentRaw = UnsafeMutableRawPointer(bitPattern: parentBits)
                else { return }
                renderWatchAccounts(into: ptr(groupRaw), parent: ptr(parentRaw), added: added)
            }
        }
        for row in WatchAccounts.rows() {
            let source = row.source
            let note = row.note
            let subtitle = note.map { "\(row.detail)\n\($0)" } ?? row.detail
            let built = buttonRow(row.title, subtitle: subtitle, label: row.actionTitle) {
                switch row.action {
                case .signIn:
                    Gtk.onMain {
                        guard let raw = UnsafeMutableRawPointer(bitPattern: parentBits) else {
                            return
                        }
                        WatchSignInDialog.present(
                            parent: ptr(raw), source: source, onFinished: refill)
                    }
                case .signOut:
                    MediaAccounts.signOut(source)
                    SettingsFile.capture()
                    refill()
                case .configure:
                    Gtk.onMain {
                        guard let raw = UnsafeMutableRawPointer(bitPattern: parentBits) else {
                            return
                        }
                        YouTubeSetupDialog.present(parent: ptr(raw), onSaved: refill)
                    }
                }
            }
            adw_action_row_set_subtitle_lines(ptr(built), 0)
            adw_preferences_group_add(ptr(group), ptr(built))
            added.rows.append(UInt(bitPattern: built))
        }
    }

    private static func group(
        _ title: String, on page: UnsafeMutablePointer<GtkWidget>, description: String? = nil
    ) -> UnsafeMutablePointer<GtkWidget> {
        let group = adw_preferences_group_new()!
        adw_preferences_group_set_title(ptr(group), title)
        if let description { adw_preferences_group_set_description(ptr(group), description) }
        adw_preferences_page_add(ptr(page), ptr(group))
        return group
    }

    private static func comboRow(
        title: String, subtitle: String?, options: [String], selected: Int,
        onChange: @escaping @Sendable (Int) -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let row = adw_combo_row_new()!
        adw_preferences_row_set_title(ptr(row), title)
        if let subtitle { adw_action_row_set_subtitle(ptr(row), subtitle) }
        let model = gtk_string_list_new(nil)!
        for option in options { gtk_string_list_append(model, option) }
        adw_combo_row_set_model(ptr(UnsafeMutableRawPointer(row)), OpaquePointer(UnsafeMutableRawPointer(model)))
        adw_combo_row_set_selected(ptr(UnsafeMutableRawPointer(row)), guint(selected))
        let bits = UInt(bitPattern: row)
        Gtk.onNotify(UnsafeMutableRawPointer(row), property: "selected") {
            guard let raw = UnsafeMutableRawPointer(bitPattern: bits) else { return }
            onChange(Int(adw_combo_row_get_selected(ptr(raw))))
        }
        return row
    }

    private static func switchRow(
        title: String, subtitle: String?, value: Bool,
        onChange: @escaping @Sendable (Bool) -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let row = adw_switch_row_new()!
        adw_preferences_row_set_title(ptr(row), title)
        if let subtitle { adw_action_row_set_subtitle(ptr(row), subtitle) }
        adw_switch_row_set_active(OpaquePointer(row), value ? 1 : 0)
        let bits = UInt(bitPattern: row)
        Gtk.onNotify(UnsafeMutableRawPointer(row), property: "active") {
            guard let raw = UnsafeMutableRawPointer(bitPattern: bits) else { return }
            onChange(adw_switch_row_get_active(op(raw)) != 0)
        }
        return row
    }

    private static func spinRow(
        title: String, subtitle: String? = nil, value: Double, lower: Double, upper: Double,
        step: Double, onChange: @escaping @Sendable (Double) -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let row = adw_spin_row_new_with_range(lower, upper, step)!
        adw_preferences_row_set_title(ptr(row), title)
        if let subtitle { adw_action_row_set_subtitle(ptr(row), subtitle) }
        adw_spin_row_set_value(OpaquePointer(row), value)
        let bits = UInt(bitPattern: row)
        Gtk.onNotify(UnsafeMutableRawPointer(row), property: "value") {
            guard let raw = UnsafeMutableRawPointer(bitPattern: bits) else { return }
            onChange(adw_spin_row_get_value(op(raw)))
        }
        return row
    }

    private static func buttonRow(
        _ title: String, subtitle: String? = nil, label: String? = nil,
        onClick: @escaping @Sendable () -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let row = adw_action_row_new()!
        adw_preferences_row_set_title(ptr(row), title)
        if let subtitle { adw_action_row_set_subtitle(ptr(row), subtitle) }
        let button = Gtk.button(label ?? Localized.text("Reset"), css: ["flat"], onClick: onClick)
        gtk_widget_set_valign(button, GTK_ALIGN_CENTER)
        adw_action_row_add_suffix(ptr(row), button)
        return row
    }
}

/// The account rows the settings group currently owns, so a refill takes back exactly what it put
/// there. Adwaita's group keeps its rows in an internal list box, so walking children to find them
/// finds the wrong widgets.
final class WatchRowsHeld: @unchecked Sendable {
    var rows: [UInt] = []
}

/// The DeepSeek key row's pointer, so the subtitle can restate the key's presence after the editor
/// changes it — the settings window is built once and the row must answer honestly in place.
final class DeepSeekRowHeld: @unchecked Sendable {
    var bits: UInt = 0
}
