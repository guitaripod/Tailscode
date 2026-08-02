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
    static var windowSize: (width: Int32, height: Int32) {
        let width = defaults.integer(forKey: "tailscode.window.width")
        let height = defaults.integer(forKey: "tailscode.window.height")
        return width > 200 && height > 200 ? (Int32(width), Int32(height)) : (1400, 900)
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

    /// Whether a run of tool calls collapses to one line instead of taking one line each.
    static var compactTools: Bool {
        flag("tailscode.compactTools", environment: "TAILSCODE_COMPACT")
    }

    static func setCompactTools(_ value: Bool) {
        write(value, forKey: "tailscode.compactTools")
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

    /// Which palette the canvas wears: the system's own preference by default — Rosé Pine when
    /// the desktop is dark, Solarized Light when it is light — or pinned to one.
    enum Appearance: String, CaseIterable {
        case system
        case light
        case dark

        var title: String {
            switch self {
            case .system: return Localized.text("System")
            case .light: return Localized.text("Light · Solarized")
            case .dark: return Localized.text("Dark · Rosé Pine")
            }
        }
    }

    static var appearance: Appearance {
        Appearance(rawValue: defaults.string(forKey: "tailscode.appearance") ?? "") ?? .system
    }

    static func setAppearance(_ value: Appearance) {
        write(value == .system ? nil : value.rawValue, forKey: "tailscode.appearance")
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
enum SettingsDialog {
    static func present(
        parent: UnsafeMutablePointer<GtkWidget>?,
        onLayoutChanged: @escaping @Sendable () -> Void
    ) {
        let (window, content) = Dialogs.window(
            title: Localized.text("Settings"), parent: parent, width: 620)
        gtk_window_set_default_size(ptr(window), 620, 720)

        section(content, Localized.text("APPEARANCE"))
        gtk_box_append(ptr(content), appearanceRow(onLayoutChanged: onLayoutChanged))

        section(content, Localized.text("TYPE SIZE"))
        for area in Preferences.Area.allCases {
            gtk_box_append(
                ptr(content),
                slider(
                    title: area.title, value: Preferences.scale(area), lower: 0.6, upper: 2.5,
                    step: 0.05, format: { String(format: "%.0f%%", $0 * 100) }
                ) { value in
                    Preferences.setScale(value, for: area)
                    MatrixTheme.install()
                })
        }
        gtk_box_append(
            ptr(content),
            slider(
                title: Localized.text("Terminal"), value: Preferences.terminalScale, lower: 0.6,
                upper: 2.5, step: 0.05, format: { String(format: "%.0f%%", $0 * 100) }
            ) { value in
                Preferences.setTerminalScale(value)
                onLayoutChanged()
            })
        gtk_box_append(
            ptr(content),
            Gtk.button(Localized.text("Reset every size")) {
                Preferences.resetScales()
                Preferences.setTerminalScale(1.0)
                MatrixTheme.install()
                onLayoutChanged()
            })

        section(content, Localized.text("COMPOSER"))
        gtk_box_append(
            ptr(content),
            toggle(
                title: Localized.text("Return sends the message"),
                detail: Localized.text("Shift+Return writes a new line either way"),
                value: Preferences.sendOnReturn
            ) { Preferences.setSendOnReturn($0) })
        gtk_box_append(
            ptr(content),
            toggle(
                title: Localized.text("Vim mode in the prompt box"),
                detail: Localized.text(
                    "Normal, visual and visual-line modes: motions, operators, text objects, registers, undo"),
                value: Preferences.vimComposer
            ) { value in
                Preferences.setVimComposer(value)
                onLayoutChanged()
            })
        gtk_box_append(
            ptr(content),
            slider(
                title: Localized.text("Prompt box grows to (lines)"),
                detail: Localized.text("It starts one line tall and grows with what you type"),
                value: Double(Preferences.composerLines), lower: 1, upper: 20, step: 1,
                format: { String(format: "%.0f", $0) }
            ) { value in
                Preferences.setComposerLines(Int(value))
                onLayoutChanged()
            })

        section(content, Localized.text("TRANSCRIPT"))
        gtk_box_append(
            ptr(content),
            toggle(
                title: Localized.text("Compact tool calls"),
                detail: Localized.text(
                    "A run of tool calls becomes one line you can open, instead of one line each"),
                value: Preferences.compactTools
            ) { value in
                Preferences.setCompactTools(value)
                onLayoutChanged()
            })
        gtk_box_append(
            ptr(content),
            toggle(
                title: Localized.text("Tighter rows"),
                detail: Localized.text("Less air between parts and turns"),
                value: Preferences.denseRows
            ) { value in
                Preferences.setDenseRows(value)
                MatrixTheme.install()
                onLayoutChanged()
            })
        gtk_box_append(
            ptr(content),
            slider(
                title: Localized.text("Rows kept on screen"),
                detail: Localized.text("Older rows wait behind one button — this is what keeps a huge chat fast"),
                value: Double(Preferences.transcriptWindow), lower: 50, upper: 5000, step: 50,
                format: { String(format: "%.0f", $0) }
            ) { value in
                Preferences.setTranscriptWindow(Int(value))
                onLayoutChanged()
            })

        section(content, Localized.text("LAYOUT"))
        gtk_box_append(
            ptr(content),
            Gtk.label(
                Localized.text(
                    "Drag any divider to size a pane; the position is remembered. ^b ^e ^t show or hide the chat list, the file tree and the terminal."),
                css: "row-detail", wrap: true, selectable: false))
        gtk_box_append(
            ptr(content),
            Gtk.button(Localized.text("Reset the pane sizes")) {
                Preferences.resetDividers()
                onLayoutChanged()
            })

        let windowBits = UInt(bitPattern: window)
        let close = Gtk.button(Localized.text("Done"), css: ["suggested-action"]) {
            guard let raw = UnsafeMutableRawPointer(bitPattern: windowBits) else { return }
            gtk_window_destroy(ptr(raw))
        }
        gtk_widget_set_halign(close, GTK_ALIGN_END)
        gtk_box_append(ptr(content), close)
        gtk_window_present(ptr(window))
    }

    /// Three choices, one highlighted: picking one restyles the running window immediately —
    /// libadwaita flips the chrome, `notify::dark` flips the canvas palette behind it.
    private static func appearanceRow(
        onLayoutChanged: @escaping @Sendable () -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        Gtk.addClass(row, "settings-group")
        var bits: [UInt] = []
        for choice in Preferences.Appearance.allCases {
            let button = gtk_button_new_with_label(choice.title)!
            if choice == Preferences.appearance { Gtk.addClass(button, "suggested-action") }
            bits.append(UInt(bitPattern: button))
            gtk_box_append(ptr(row), button)
        }
        for (index, choice) in Preferences.Appearance.allCases.enumerated() {
            guard let raw = UnsafeMutableRawPointer(bitPattern: bits[index]) else { continue }
            let all = bits
            Gtk.connect(raw, "clicked") {
                Preferences.setAppearance(choice)
                Preferences.applyAppearance()
                MatrixTheme.install()
                for (which, other) in all.enumerated() {
                    guard let otherRaw = UnsafeMutableRawPointer(bitPattern: other) else { continue }
                    let widget: UnsafeMutablePointer<GtkWidget> = ptr(otherRaw)
                    if which == index {
                        Gtk.addClass(widget, "suggested-action")
                    } else {
                        gtk_widget_remove_css_class(widget, "suggested-action")
                    }
                }
                onLayoutChanged()
            }
        }
        return row
    }

    private static func section(_ content: UnsafeMutablePointer<GtkWidget>, _ title: String) {
        let label = Gtk.label(title, css: "section-header", selectable: false)
        gtk_widget_set_halign(label, GTK_ALIGN_START)
        gtk_box_append(ptr(content), label)
    }

    private static func slider(
        title: String, detail: String? = nil, value: Double, lower: Double, upper: Double,
        step: Double, format: @escaping @Sendable (Double) -> String,
        onChange: @escaping @Sendable (Double) -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        Gtk.addClass(column, "settings-group")
        let header = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        let label = Gtk.label(title, css: "row-title", selectable: false)
        gtk_widget_set_hexpand(label, 1)
        gtk_widget_set_halign(label, GTK_ALIGN_START)
        let readout = Gtk.label(format(value), css: "row-detail", selectable: false)
        gtk_box_append(ptr(header), label)
        gtk_box_append(ptr(header), readout)
        gtk_box_append(ptr(column), header)
        if let detail {
            let hint = Gtk.label(detail, css: "row-detail", wrap: true, selectable: false)
            gtk_widget_set_halign(hint, GTK_ALIGN_START)
            gtk_box_append(ptr(column), hint)
        }

        let scale = gtk_scale_new_with_range(GTK_ORIENTATION_HORIZONTAL, lower, upper, step)!
        gtk_range_set_value(ptr(scale), value)
        gtk_scale_set_draw_value(ptr(scale), 0)
        gtk_widget_set_hexpand(scale, 1)
        let readoutBits = UInt(bitPattern: readout)
        let scaleBits = UInt(bitPattern: scale)
        Gtk.connect(UnsafeMutableRawPointer(scale), "value-changed") {
            guard let scaleRaw = UnsafeMutableRawPointer(bitPattern: scaleBits),
                let readoutRaw = UnsafeMutableRawPointer(bitPattern: readoutBits)
            else { return }
            let current = gtk_range_get_value(ptr(scaleRaw) as UnsafeMutablePointer<GtkRange>)
            gtk_label_set_text(op(readoutRaw), format(current))
            onChange(current)
        }
        gtk_box_append(ptr(column), scale)
        return column
    }

    private static func toggle(
        title: String, detail: String?, value: Bool, onChange: @escaping @Sendable (Bool) -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        Gtk.addClass(row, "settings-group")
        let lines = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        let label = Gtk.label(title, css: "row-title", selectable: false)
        gtk_widget_set_halign(label, GTK_ALIGN_START)
        gtk_box_append(ptr(lines), label)
        if let detail {
            let hint = Gtk.label(detail, css: "row-detail", wrap: true, selectable: false)
            gtk_widget_set_halign(hint, GTK_ALIGN_START)
            gtk_box_append(ptr(lines), hint)
        }
        gtk_widget_set_hexpand(lines, 1)
        gtk_box_append(ptr(row), lines)

        let toggle = gtk_check_button_new()!
        gtk_check_button_set_active(ptr(toggle), value ? 1 : 0)
        gtk_widget_set_valign(toggle, GTK_ALIGN_CENTER)
        let bits = UInt(bitPattern: toggle)
        Gtk.connect(UnsafeMutableRawPointer(toggle), "toggled") {
            guard let raw = UnsafeMutableRawPointer(bitPattern: bits) else { return }
            onChange(gtk_check_button_get_active(ptr(raw) as UnsafeMutablePointer<GtkCheckButton>) != 0)
        }
        gtk_box_append(ptr(row), toggle)
        return row
    }
}
