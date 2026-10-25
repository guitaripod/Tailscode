import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// Type size in Settings: what each part of the window is set in, seen before it is chosen. A
/// preview made of the window's own roles sits over one slider per area, presets for the person
/// who wants bigger type and not four decisions, the window zoom, and a way back at every level.
/// The preview answers every notch; the window itself answers as the hand pauses, because
/// restyling a whole window for each of forty notches of a drag is the cost a slider should not
/// have.
final class SettingsTypeSection: @unchecked Sendable {
    private struct Line {
        let slider: UnsafeMutablePointer<GtkWidget>
        let value: UnsafeMutablePointer<GtkWidget>
        let reset: UnsafeMutablePointer<GtkWidget>
    }

    private enum Scope: Hashable {
        case area(Preferences.Area)
        case terminal
    }

    private let context: SettingsContext
    private var lines: [Scope: Line] = [:]
    private var preset: UnsafeMutablePointer<GtkWidget>?
    private var zoomValue: UnsafeMutablePointer<GtkWidget>?
    private var zoomReset: UnsafeMutablePointer<GtkWidget>?
    private var syncing = false
    private var generation = 0

    private static let presets: [TypePreset] = TypePreset.allCases

    private init(context: SettingsContext) {
        self.context = context
    }

    static func install(on page: UnsafeMutablePointer<GtkWidget>, context: SettingsContext) {
        let section = SettingsTypeSection(context: context)
        SettingsRows.keep(section, alive: page)
        section.build(on: page)
    }

    private func build(on page: UnsafeMutablePointer<GtkWidget>) {
        let sample = SettingsRows.group(
            Localized.text("Type size"), on: page,
            description: Localized.text(
                "Percent of the normal size. The sample is set the way the window sets its own text."))
        SettingsRows.add(Self.previewCard(), to: sample)
        let group = SettingsRows.group(nil, on: page)

        let titles = Self.presets.map(\.title) + [Localized.text("Custom")]
        let presetRow = SettingsRows.comboRow(
            title: Localized.text("Preset"),
            subtitle: Localized.text("All the areas at once; the sliders below set one"),
            options: titles, selected: currentPresetIndex
        ) { [weak self] index in
            self?.choose(presetAt: index)
        }
        preset = presetRow
        SettingsRows.add(presetRow, to: group)

        for area in Preferences.Area.allCases {
            SettingsRows.add(
                areaRow(
                    scope: .area(area), title: area.title, detail: Self.detail(of: area),
                    value: Preferences.scale(area)),
                to: group)
        }
        SettingsRows.add(
            areaRow(
                scope: .terminal, title: Localized.text("Terminal"),
                detail: Localized.text("The shell under the conversation"),
                value: Preferences.terminalScale),
            to: group)
        SettingsRows.add(zoomRow(), to: group)
        SettingsRows.add(
            SettingsRows.buttonRow(
                Localized.text("Reset type"), subtitle: Localized.text("Every area and the window zoom back to normal"),
                label: Localized.text("Reset")
            ) { [weak self] in self?.resetEverything() },
            to: group)
    }

    private static func detail(of area: Preferences.Area) -> String {
        switch area {
        case .chrome:
            return Localized.text("The chat list, pills, menus and every label around the conversation")
        case .prose:
            return Localized.text("What you type and what the agent writes back: answers, thinking and tables")
        case .mono: return Localized.text("Code blocks, tool calls and their output, and the prompt box")
        }
    }

    private static func previewCard() -> UnsafeMutablePointer<GtkWidget> {
        let card = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
        gtk_widget_add_css_class(card, "type-preview")
        let chat = Gtk.label(
            Localized.text("Fix the flaky reconnect test"), css: "type-sample-chat", selectable: false)
        let detail = Gtk.label("Fable high · studio · 9m", css: "type-sample-chat-detail", selectable: false)
        let rule = gtk_separator_new(GTK_ORIENTATION_HORIZONTAL)!
        let prompt = Gtk.label(
            Localized.text("Why does the build fail on CI?"), css: "type-sample-prompt", wrap: true,
            selectable: false)
        let answer = Gtk.label(
            Localized.text(
                "The linker cannot find the Kit on the runner. Pinning the checkout fixes it, and the test passes locally."),
            css: "type-sample-answer", wrap: true, selectable: false)
        let tool = Gtk.label("▸ Bash  swift test --filter Type", css: "type-sample-tool", selectable: false)
        let code = Gtk.label("let size = base * ratio * scale", css: "type-sample-code", selectable: false)
        let shell = Gtk.label("$ swift build", css: "type-sample-shell", selectable: false)
        for part in [chat, detail, rule, prompt, answer, tool, code, shell] {
            gtk_box_append(ptr(card), part)
        }
        return card
    }

    private func areaRow(
        scope: Scope, title: String, detail: String, value: Double
    ) -> UnsafeMutablePointer<GtkWidget> {
        let row = adw_action_row_new()!
        adw_preferences_row_set_title(ptr(row), title)
        adw_action_row_set_subtitle(ptr(row), detail)
        let slider = gtk_scale_new_with_range(
            GTK_ORIENTATION_HORIZONTAL, TypeScale.lowest * 100, TypeScale.highest * 100,
            TypeScale.step * 100)!
        gtk_scale_set_draw_value(ptr(slider), 0)
        gtk_range_set_value(ptr(slider), (value * 100).rounded())
        gtk_widget_set_size_request(slider, 180, -1)
        gtk_widget_set_valign(slider, GTK_ALIGN_CENTER)
        tailscode_set_accessible_label(slider, title)
        let valueLabel = Gtk.label("", css: "type-value", selectable: false)
        gtk_label_set_xalign(op(valueLabel), 1)
        gtk_widget_set_valign(valueLabel, GTK_ALIGN_CENTER)
        let reset = gtk_button_new_from_icon_name("edit-undo-symbolic")!
        gtk_widget_add_css_class(reset, "flat")
        gtk_widget_set_valign(reset, GTK_ALIGN_CENTER)
        gtk_widget_set_tooltip_text(reset, Localized.text("Back to normal size"))
        Gtk.connect(UnsafeMutableRawPointer(reset), "clicked") { [weak self] in
            self?.set(scope, to: 1.0)
            self?.sync()
        }
        adw_action_row_add_suffix(ptr(row), slider)
        adw_action_row_add_suffix(ptr(row), valueLabel)
        adw_action_row_add_suffix(ptr(row), reset)
        lines[scope] = Line(slider: slider, value: valueLabel, reset: reset)
        let bits = UInt(bitPattern: slider)
        Gtk.connect(UnsafeMutableRawPointer(slider), "value-changed") { [weak self] in
            guard let self, !self.syncing,
                let raw = UnsafeMutableRawPointer(bitPattern: bits)
            else { return }
            self.set(scope, to: gtk_range_get_value(ptr(raw)) / 100)
            self.refreshLabels()
        }
        refreshLabels()
        return row
    }

    private func zoomRow() -> UnsafeMutablePointer<GtkWidget> {
        let row = adw_action_row_new()!
        adw_preferences_row_set_title(ptr(row), Localized.text("Window zoom"))
        adw_action_row_set_subtitle(
            ptr(row),
            Localized.text("Ctrl+plus and Ctrl+minus scale everything in the window, on top of the sizes above"))
        let value = Gtk.label("", css: "type-value", selectable: false)
        gtk_label_set_xalign(op(value), 1)
        gtk_widget_set_valign(value, GTK_ALIGN_CENTER)
        let strip = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        gtk_widget_add_css_class(strip, "linked")
        gtk_widget_set_valign(strip, GTK_ALIGN_CENTER)
        let smaller = gtk_button_new_from_icon_name("zoom-out-symbolic")!
        let larger = gtk_button_new_from_icon_name("zoom-in-symbolic")!
        let reset = gtk_button_new_from_icon_name("edit-undo-symbolic")!
        gtk_widget_set_tooltip_text(reset, Localized.text("Back to normal size"))
        for button in [smaller, larger] { gtk_box_append(ptr(strip), button) }
        Gtk.connect(UnsafeMutableRawPointer(smaller), "clicked") { [weak self] in
            UIScale.step(-0.1)
            self?.refreshLabels()
        }
        Gtk.connect(UnsafeMutableRawPointer(larger), "clicked") { [weak self] in
            UIScale.step(0.1)
            self?.refreshLabels()
        }
        Gtk.connect(UnsafeMutableRawPointer(reset), "clicked") { [weak self] in
            UIScale.reset()
            self?.refreshLabels()
        }
        gtk_widget_add_css_class(reset, "flat")
        gtk_widget_set_valign(reset, GTK_ALIGN_CENTER)
        adw_action_row_add_suffix(ptr(row), value)
        adw_action_row_add_suffix(ptr(row), strip)
        adw_action_row_add_suffix(ptr(row), reset)
        zoomValue = value
        zoomReset = reset
        return row
    }

    private func value(of scope: Scope) -> Double {
        switch scope {
        case .area(let area): return Preferences.scale(area)
        case .terminal: return Preferences.terminalScale
        }
    }

    private func set(_ scope: Scope, to value: Double) {
        switch scope {
        case .area(let area): Preferences.setScale(value, for: area)
        case .terminal: Preferences.setTerminalScale(value)
        }
        scheduleApply()
    }

    /// The sizes as Core's presets say them. The desktop's prose area carries what you type as
    /// well as what the agent writes, so one number answers both of the presets' areas.
    private var current: TypeScale {
        TypeScale([
            .chrome: Preferences.scale(.chrome), .answer: Preferences.scale(.prose),
            .prompt: Preferences.scale(.prose), .mono: Preferences.scale(.mono),
            .terminal: Preferences.terminalScale,
        ])
    }

    private var currentPresetIndex: Int {
        current.preset.flatMap { Self.presets.firstIndex(of: $0) } ?? Self.presets.count
    }

    private func choose(presetAt index: Int) {
        guard !syncing, index < Self.presets.count else { return }
        let scale = Self.presets[index].scale
        Preferences.setScale(scale[.chrome], for: .chrome)
        Preferences.setScale(scale[.answer], for: .prose)
        Preferences.setScale(scale[.mono], for: .mono)
        Preferences.setTerminalScale(scale[.terminal])
        sync()
        scheduleApply()
    }

    private func resetEverything() {
        Preferences.resetScales()
        Preferences.setTerminalScale(1.0)
        UIScale.reset()
        sync()
        scheduleApply()
    }

    /// Puts every slider, label and the preset where the stores say they are, without those
    /// controls answering as though a hand had moved them.
    private func sync() {
        syncing = true
        for (scope, line) in lines {
            gtk_range_set_value(ptr(line.slider), (value(of: scope) * 100).rounded())
        }
        syncing = false
        refreshLabels()
    }

    private func refreshLabels() {
        for (scope, line) in lines {
            let percent = Int((value(of: scope) * 100).rounded())
            gtk_label_set_text(op(line.value), TypeScale.reading(percent))
            gtk_widget_set_visible(line.reset, percent == 100 ? 0 : 1)
        }
        let zoom = Int((UIScale.factor * 100).rounded())
        if let zoomValue { gtk_label_set_text(op(zoomValue), TypeScale.reading(zoom)) }
        if let zoomReset { gtk_widget_set_visible(zoomReset, zoom == 100 ? 0 : 1) }
        if let preset {
            syncing = true
            adw_combo_row_set_selected(ptr(preset), guint(currentPresetIndex))
            syncing = false
        }
    }

    private func scheduleApply() {
        generation &+= 1
        let mine = generation
        Gtk.after(140) { [weak self] in
            guard let self, self.generation == mine else { return }
            MatrixTheme.install()
            self.context.onLayoutChanged()
        }
    }
}
