import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The machine pill: where the work happens and whether that machine can do it, in one control
/// that replaces a grey note about what a render costs the grid. A dot says how the machine is —
/// breathing only while a job runs, perfectly still the moment it settles, the failure tone when
/// it cannot paint — beside its name and the one fact worth knowing, and pressing it opens the
/// machine's own account.
///
/// Every word is Core's (`StudioMachinePill`, `ImageGenMachineWords`); this draws them. The dot
/// breathes through `ActivityPulse`, the swell every other working mark in the window shares, so
/// it is in time with them and asks nothing of the frame clock when it is still.
final class StudioMachineButton: @unchecked Sendable {
    let widget = gtk_menu_button_new()!
    private let dot = Gtk.label("●", css: "studio-dot", selectable: false)
    private let line = Gtk.label("", css: "studio-pill-line", selectable: false)
    private let popover = gtk_popover_new()!
    private var tone: StudioMachinePill.Tone = .unknown
    private var breathes = false
    private var shown = ""

    /// Builds the machine's account each time the popover opens, so it is read from the last
    /// look at the machine rather than from the moment the window was made.
    var details: (@Sendable () -> UnsafeMutablePointer<GtkWidget>)?

    init() {
        Gtk.addClass(widget, "studio-pill")
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_label_set_ellipsize(op(line), PANGO_ELLIPSIZE_END)
        gtk_label_set_max_width_chars(op(line), 64)
        gtk_box_append(ptr(row), dot)
        gtk_box_append(ptr(row), line)
        let chevron = Gtk.label(ImageGenField.engine.affordanceGlyph, css: "draw-chip-mark", selectable: false)
        gtk_box_append(ptr(row), chevron)
        gtk_menu_button_set_child(op(widget), row)
        gtk_menu_button_set_can_shrink(op(widget), 1)
        gtk_menu_button_set_always_show_arrow(op(widget), 0)
        gtk_menu_button_set_popover(op(widget), popover)
        gtk_widget_set_halign(widget, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(widget, GTK_ALIGN_CENTER)
        Gtk.setHidden(dot, true)
        Gtk.connect(UnsafeMutableRawPointer(popover), "map") { [weak self] in
            Gtk.onMain { [weak self] in self?.openDetails() }
        }
        apply(StudioMachinePill(machine: "", state: nil, version: nil, tone: .unknown))
    }

    /// Opens the machine's account, as pressing the pill does.
    func open() {
        gtk_menu_button_popup(op(widget))
    }

    private func openDetails() {
        guard let details else { return }
        gtk_popover_set_child(ptr(popover), details())
    }

    func apply(_ pill: StudioMachinePill) {
        let text = pill.line
        if text != shown {
            shown = text
            gtk_label_set_text(op(line), text)
            gtk_widget_set_tooltip_text(widget, text)
            tailscode_set_accessible_label(
                widget, "\(Localized.text("Machine")): \(text)")
        }
        guard pill.tone != tone || pill.breathes != breathes else { return }
        tone = pill.tone
        breathes = pill.breathes
        let tones = ActivityTone.allCases.map(\.glyphCSS)
        let mapped: ActivityTone
        switch pill.tone {
        case .ready, .working: mapped = .live
        case .danger: mapped = .danger
        case .quiet, .unknown: mapped = .quiet
        }
        Gtk.setTone(dot, mapped.glyphCSS, from: tones)
        ActivityPulse.apply(pill.breathes ? ActivityKind.working.icon : nil, to: dot)
    }

    /// For the headless driver: what the pill says and whether its dot is moving.
    var summary: String {
        let moving = ActivityPulse.reading(of: dot).contains("moving=1")
        return "\(shown.isEmpty ? "-" : shown) dot=\(tone) breathing=\(moving)"
    }
}

/// The machine's own account, drawn as the popover under the pill: where it is, what it runs,
/// when it was last looked at, whether each model file is there, and the two things a person does
/// about it — look again, and point somewhere else.
enum StudioMachineDetails {
    static func image(
        studio: ImageStudio, sighting: ImageGenSighting?, onCheck: @escaping @Sendable () -> Void,
        onChange: @escaping @Sendable () -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
        Gtk.margins(column, 14)
        gtk_widget_set_size_request(column, 360, -1)
        Gtk.addClass(column, "studio-machine")
        let title = Gtk.label(studio.endpoint.shortName, css: "draw-toggle-title", selectable: false)
        gtk_box_append(ptr(column), title)
        gtk_box_append(
            ptr(column),
            Gtk.label(ImageGenMachineWords.summary(sighting), css: "draw-toggle-detail", wrap: true, selectable: false))
        if ImageStudio.pinnedEndpoint == nil, ImageGenDoor.current().inherited {
            gtk_box_append(
                ptr(column),
                Gtk.label(ImageGenMachineWords.inherited, css: "draw-toggle-detail", wrap: true, selectable: false))
        }
        gtk_box_append(ptr(column), Gtk.hairline())
        gtk_box_append(ptr(column), fact(ImageGenMachineWords.addressLabel, studio.endpoint.address))
        gtk_box_append(
            ptr(column),
            fact(ImageGenMachineWords.versionLabel, sighting?.version ?? ImageGenMachineWords.unknown))
        gtk_box_append(
            ptr(column),
            fact(
                ImageGenMachineWords.checkedLabel,
                sighting.map { ImageGenLibraryWords.ago($0.at) } ?? ImageGenMachineWords.neverChecked))
        if let running = sighting?.running {
            gtk_box_append(
                ptr(column), fact(ImageGenMachineWords.queueLabel, ImageGenMachineWords.queue(running: running)))
        }
        gtk_box_append(
            ptr(column), Gtk.label(ImageGenMachineWords.modelsTitle, css: "draw-lbl", selectable: false))
        for file in ImageGenModelFile.all {
            let state: String
            switch sighting?.holds(file) {
            case .some(true): state = ImageGenMachineWords.present
            case .some(false): state = ImageGenMachineWords.missing
            case .none: state = ImageGenMachineWords.unknown
            }
            let row = fact(file.name, state)
            if sighting?.holds(file) == false { Gtk.addClass(row, "studio-machine-missing") }
            gtk_box_append(ptr(column), row)
        }
        let verbs = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        gtk_widget_set_margin_top(verbs, 6)
        gtk_box_append(
            ptr(verbs),
            Gtk.button(ImageGenMachineWords.checkAgain, css: ["draw-action"], onClick: { onCheck() }))
        gtk_box_append(
            ptr(verbs),
            Gtk.button(ImageGenMachineWords.change, css: ["draw-action"], onClick: { onChange() }))
        gtk_box_append(ptr(column), verbs)
        return column
    }

    static func forge(
        board: ForgeBoard, onCheck: @escaping @Sendable () -> Void,
        onChange: @escaping @Sendable () -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
        Gtk.margins(column, 14)
        gtk_widget_set_size_request(column, 340, -1)
        Gtk.addClass(column, "studio-machine")
        let name = board.endpoint.map { $0.host.split(separator: ".").first.map(String.init) ?? $0.host }
            ?? board.rows.first(where: { $0.kind == .field(.endpoint) })?.title ?? ""
        gtk_box_append(ptr(column), Gtk.label(name, css: "draw-toggle-title", selectable: false))
        if let endpoint = board.endpoint {
            gtk_box_append(
                ptr(column), fact(ImageGenMachineWords.addressLabel, "\(endpoint.host):\(endpoint.port)"))
        }
        if let row = board.rows.first(where: { $0.kind == .field(.endpoint) }), let badge = row.badge {
            gtk_box_append(ptr(column), fact(ForgeField.endpoint.label, badge))
        }
        let verbs = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        gtk_widget_set_margin_top(verbs, 6)
        gtk_box_append(
            ptr(verbs),
            Gtk.button(ImageGenMachineWords.checkAgain, css: ["draw-action"], onClick: { onCheck() }))
        gtk_box_append(
            ptr(verbs),
            Gtk.button(ImageGenMachineWords.change, css: ["draw-action"], onClick: { onChange() }))
        gtk_box_append(ptr(column), verbs)
        return column
    }

    private static func fact(_ name: String, _ value: String) -> UnsafeMutablePointer<GtkWidget> {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        let label = Gtk.label(name, css: "draw-toggle-detail", selectable: false)
        gtk_widget_set_hexpand(label, 1)
        let text = Gtk.label(value, css: "draw-facts", selectable: true)
        gtk_label_set_xalign(op(text), 1)
        gtk_box_append(ptr(row), label)
        gtk_box_append(ptr(row), text)
        return row
    }
}
