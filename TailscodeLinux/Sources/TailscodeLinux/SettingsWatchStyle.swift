import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The wall's style as Settings shows it: Core's `WallStyle` row for row, the same names the
/// iPhone, iPad and Mac use. Every change is stored at once and put on an open wall at once; a
/// preset sets every row, and changing any one row by hand shows the preset as Custom.
final class WatchStyleRows: @unchecked Sendable {
    private(set) var style: WallStyle
    private var syncing = false
    private(set) var presetRow: UnsafeMutablePointer<GtkWidget>?
    private(set) var effectsStrip: UnsafeMutablePointer<GtkWidget>?
    private(set) var fieldStrip: UnsafeMutablePointer<GtkWidget>?
    private(set) var lightRow: UnsafeMutablePointer<GtkWidget>?
    private(set) var dimStrip: UnsafeMutablePointer<GtkWidget>?
    private(set) var nightStrip: UnsafeMutablePointer<GtkWidget>?
    private(set) var awakeStrip: UnsafeMutablePointer<GtkWidget>?
    private(set) var stillRow: UnsafeMutablePointer<GtkWidget>?
    private(set) var approvalStrip: UnsafeMutablePointer<GtkWidget>?
    private(set) var eventRows: [UnsafeMutablePointer<GtkWidget>] = []
    private(set) var wallRows: [UnsafeMutablePointer<GtkWidget>] = []

    init(style: WallStyle) {
        self.style = style
    }

    static let presets = [
        Localized.text("Studio"), Localized.text("Night desk"), Localized.text("Showcase"),
        Localized.text("Custom"),
    ]

    static var moves: [(title: String, edit: (inout WallStyle.Moves, Bool) -> Void, read: (WallStyle.Moves) -> Bool)] {
        [
            (Localized.text("Steps"), { $0.steps = $1 }, { $0.steps }),
            (Localized.text("Sub-agents"), { $0.agents = $1 }, { $0.agents }),
            (Localized.text("Endings"), { $0.endings = $1 }, { $0.endings }),
            (Localized.text("Needs you"), { $0.asks = $1 }, { $0.asks }),
            (Localized.text("Failures"), { $0.failures = $1 }, { $0.failures }),
            (Localized.text("Retries and silence"), { $0.retries = $1 }, { $0.retries }),
            (Localized.text("Compaction"), { $0.compaction = $1 }, { $0.compaction }),
            (Localized.text("Arrivals and departures"), { $0.arrivals = $1 }, { $0.arrivals }),
        ]
    }

    static var stands: [(title: String, edit: (inout WallStyle, Bool) -> Void, read: (WallStyle) -> Bool)] {
        [
            (Localized.text("Clock"), { $0.showsClock = $1 }, { $0.showsClock }),
            (Localized.text("Last hour"), { $0.showsHour = $1 }, { $0.showsHour }),
            (Localized.text("Recent and also running"), { $0.showsRails = $1 }, { $0.showsRails }),
            (Localized.text("Sub-agent tiles"), { $0.showsSquads = $1 }, { $0.showsSquads }),
        ]
    }

    static func dimWords(_ choice: TimeInterval?) -> String {
        guard let choice else { return Localized.text("Never") }
        return Localized.text("%d min", Int(choice / 60))
    }

    static func dimIndex(_ style: WallStyle) -> Int {
        let choices = WallStyle.dimChoices
        if let exact = choices.firstIndex(where: { $0 == style.dimAfter }) { return exact }
        guard let asked = style.dimAfter else { return choices.count - 1 }
        let timed = choices.enumerated().compactMap { entry in entry.element.map { (entry.offset, $0) } }
        return timed.min { abs($0.1 - asked) < abs($1.1 - asked) }?.0 ?? 1
    }

    /// Stores a change made by hand, which makes the preset Custom unless the change chose one.
    func change(_ edit: (inout WallStyle) -> Void) {
        guard !syncing else { return }
        let next = style.with(edit)
        guard next != style else { return }
        store(next)
    }

    func choose(_ preset: WallStyle.Preset) {
        guard !syncing else { return }
        if preset == .custom {
            var next = style
            next.preset = .custom
            store(next)
        } else {
            store(WallStyle.preset(preset))
        }
    }

    private func store(_ next: WallStyle) {
        style = next
        Preferences.setAgentsWatchStyle(next)
        refresh()
        AgentsWindow.current?.styleChanged()
    }

    /// Writes the style into every control, without any of them answering back.
    func refresh() {
        syncing = true
        defer { syncing = false }
        if let presetRow, let index = WallStyle.Preset.allCases.firstIndex(of: style.preset) {
            adw_combo_row_set_selected(ptr(presetRow), guint(index))
        }
        Self.select(effectsStrip, WallStyle.Effects.allCases.firstIndex(of: style.effects))
        Self.select(fieldStrip, WallStyle.Field.allCases.firstIndex(of: style.field))
        Self.set(lightRow, style.light)
        Self.select(dimStrip, Self.dimIndex(style))
        Self.select(nightStrip, WallStyle.Night.allCases.firstIndex(of: style.night))
        Self.select(awakeStrip, WallStyle.KeepAwake.allCases.firstIndex(of: style.keepAwake))
        Self.set(stillRow, style.still)
        Self.select(approvalStrip, WallStyle.Approvals.allCases.firstIndex(of: style.approvals))
        for (row, move) in zip(eventRows, Self.moves) { Self.set(row, move.read(style.moves)) }
        for (row, stand) in zip(wallRows, Self.stands) { Self.set(row, stand.read(style)) }
    }

    private static func set(_ row: UnsafeMutablePointer<GtkWidget>?, _ on: Bool) {
        guard let row else { return }
        adw_switch_row_set_active(OpaquePointer(row), on ? 1 : 0)
    }

    private static func select(_ strip: UnsafeMutablePointer<GtkWidget>?, _ index: Int?) {
        guard let strip, let index else { return }
        var child = gtk_widget_get_first_child(strip)
        var at = 0
        while let button = child {
            if at == index { gtk_toggle_button_set_active(ptr(button), 1) }
            child = gtk_widget_get_next_sibling(button)
            at += 1
        }
    }

    func build(into group: UnsafeMutablePointer<GtkWidget>) {
        let preset = SettingsRows.comboRow(
            title: Localized.text("Preset"),
            subtitle: Localized.text("Studio, Night desk and Showcase set every row below"),
            options: Self.presets, selected: WallStyle.Preset.allCases.firstIndex(of: style.preset) ?? 0
        ) { [weak self] index in
            guard WallStyle.Preset.allCases.indices.contains(index) else { return }
            self?.choose(WallStyle.Preset.allCases[index])
        }
        presetRow = preset
        SettingsRows.add(preset, to: group)

        effectsStrip = addStrip(
            to: group, title: Localized.text("Effects"),
            subtitle: Localized.text("One gesture for what happens, never longer than two seconds"),
            options: [Localized.text("Off"), Localized.text("Subtle"), Localized.text("Lively")],
            selected: WallStyle.Effects.allCases.firstIndex(of: style.effects) ?? 1
        ) { [weak self] index in
            self?.change { $0.effects = WallStyle.Effects.allCases[index] }
        }
        fieldStrip = addStrip(
            to: group, title: Localized.text("Field"), subtitle: nil,
            options: [
                Localized.text("Motes"), Localized.text("Currents"), Localized.text("Aurora"),
                Localized.text("None"),
            ],
            selected: WallStyle.Field.allCases.firstIndex(of: style.field) ?? 0
        ) { [weak self] index in
            self?.change { $0.field = WallStyle.Field.allCases[index] }
        }
        lightRow = addSwitch(
            to: group, title: Localized.text("Light from tiles"),
            subtitle: Localized.text("Each tile spills a little of its colour on the ground"), on: style.light
        ) { [weak self] on in self?.change { $0.light = on } }

        let events = adw_expander_row_new()!
        adw_preferences_row_set_title(ptr(events), Localized.text("Events that move"))
        adw_expander_row_set_subtitle(ptr(events), Localized.text("Which kinds of event get a gesture"))
        for (index, move) in Self.moves.enumerated() {
            let row = SettingsRows.switchRow(title: move.title, subtitle: nil, value: move.read(style.moves)) {
                [weak self] on in
                self?.change { Self.moves[index].edit(&$0.moves, on) }
            }
            adw_expander_row_add_row(ptr(events), row)
            eventRows.append(row)
        }
        SettingsRows.add(events, to: group)

        dimStrip = addStrip(
            to: group, title: Localized.text("Dim when calm for"), subtitle: nil,
            options: WallStyle.dimChoices.map(Self.dimWords), selected: Self.dimIndex(style)
        ) { [weak self] index in
            self?.change { $0.dimAfter = WallStyle.dimChoices[index] }
        }
        nightStrip = addStrip(
            to: group, title: Localized.text("Night"),
            subtitle: Localized.text("Warmer and dimmer, and the field fainter"),
            options: [Localized.text("Off"), Localized.text("22:00–07:00"), Localized.text("Always")],
            selected: WallStyle.Night.allCases.firstIndex(of: style.night) ?? 0
        ) { [weak self] index in
            self?.change { $0.night = WallStyle.Night.allCases[index] }
        }
        awakeStrip = addStrip(
            to: group, title: Localized.text("Keep the screen on"),
            subtitle: Localized.text("In fullscreen. The k key still decides for itself"),
            options: [Localized.text("While charging"), Localized.text("Always"), Localized.text("Never")],
            selected: WallStyle.KeepAwake.allCases.firstIndex(of: style.keepAwake) ?? 0
        ) { [weak self] index in
            self?.change { $0.keepAwake = WallStyle.KeepAwake.allCases[index] }
        }
        stillRow = addSwitch(
            to: group, title: Localized.text("Still"),
            subtitle: Localized.text("Crossfades, and nothing breathes or drifts. Also on when the desk reduces motion"),
            on: style.still
        ) { [weak self] on in self?.change { $0.still = on } }

        let stands = adw_expander_row_new()!
        adw_preferences_row_set_title(ptr(stands), Localized.text("On the wall"))
        adw_expander_row_set_subtitle(ptr(stands), Localized.text("What stands on it besides the tiles"))
        for (index, stand) in Self.stands.enumerated() {
            let row = SettingsRows.switchRow(title: stand.title, subtitle: nil, value: stand.read(style)) {
                [weak self] on in
                self?.change { Self.stands[index].edit(&$0, on) }
            }
            adw_expander_row_add_row(ptr(stands), row)
            wallRows.append(row)
        }
        SettingsRows.add(stands, to: group)

        approvalStrip = addStrip(
            to: group, title: Localized.text("Approve from the wall"), subtitle: nil,
            options: [Localized.text("Hold to approve"), Localized.text("Open the chat")],
            selected: WallStyle.Approvals.allCases.firstIndex(of: style.approvals) ?? 0
        ) { [weak self] index in
            self?.change { $0.approvals = WallStyle.Approvals.allCases[index] }
        }
    }

    private func addStrip(
        to group: UnsafeMutablePointer<GtkWidget>, title: String, subtitle: String?, options: [String],
        selected: Int, onChange: @escaping @Sendable (Int) -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let row = adw_action_row_new()!
        adw_preferences_row_set_title(ptr(row), title)
        if let subtitle {
            adw_action_row_set_subtitle(ptr(row), subtitle)
            adw_action_row_set_subtitle_lines(ptr(row), 0)
        }
        let strip = SettingsRows.segmented(options: options, selected: selected) { [weak self] index in
            guard self?.syncing == false else { return }
            onChange(index)
        }
        adw_action_row_add_suffix(ptr(row), strip)
        SettingsRows.add(row, to: group)
        return strip
    }

    private func addSwitch(
        to group: UnsafeMutablePointer<GtkWidget>, title: String, subtitle: String?, on: Bool,
        onChange: @escaping @Sendable (Bool) -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let row = SettingsRows.switchRow(title: title, subtitle: subtitle, value: on, onChange: onChange)
        if subtitle != nil { adw_action_row_set_subtitle_lines(ptr(row), 0) }
        SettingsRows.add(row, to: group)
        return row
    }
}

/// The Watch group of Settings, on the page beside Plain words: the wall's style, which the wall's own
/// Style button brings the person to.
enum SettingsWatchStyle {
    nonisolated(unsafe) private static var anchor: Gtk.WeakWidget?
    nonisolated(unsafe) private static var heading: Gtk.WeakWidget?

    @discardableResult
    static func add(to page: UnsafeMutablePointer<GtkWidget>) -> WatchStyleRows {
        let group = SettingsRows.group(
            Localized.text("Watch"), on: page,
            description: Localized.text(
                "How the agents wall looks and moves. Changes reach an open wall at once and stay on this machine."))
        let rows = WatchStyleRows(style: Preferences.agentsWatchStyle)
        rows.build(into: group)
        SettingsRows.keep(rows, alive: page)
        if let preset = rows.presetRow { anchor = Gtk.WeakWidget(preset) }
        heading = Gtk.WeakWidget(group)
        return rows
    }

    /// Brings the group to the top of the page once Settings is up, and gives its first row the focus.
    static func reveal() {
        Gtk.after(250) {
            Gtk.onMain {
                if let group = heading?.widget { scroll(to: group) }
                guard let widget = anchor?.widget else { return }
                gtk_widget_grab_focus(widget)
            }
        }
    }

    /// Moves the page's scrolled window so the group's title is at its top edge.
    static func scroll(to group: UnsafeMutablePointer<GtkWidget>) {
        guard let window = gtk_widget_get_ancestor(group, gtk_scrolled_window_get_type()),
            let viewport = gtk_scrolled_window_get_child(op(window)),
            let content = gtk_viewport_get_child(op(viewport)),
            let adjustment = gtk_scrolled_window_get_vadjustment(op(window))
        else { return }
        var x = 0.0
        var y = 0.0
        guard gtk_widget_translate_coordinates(group, content, 0, 0, &x, &y) != 0 else { return }
        gtk_adjustment_set_value(adjustment, max(0, y - 12))
    }
}
