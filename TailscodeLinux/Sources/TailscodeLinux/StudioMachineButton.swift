import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The machine pill: where the work happens and whether that machine can do it, in one control
/// that replaces a grey note about what a render costs the grid. A dot says how the machine is —
/// breathing only while a job runs, perfectly still the moment it settles, the failure tone when
/// it cannot paint — beside its name and the one fact worth knowing, and pressing it opens the
/// checklist for what that machine can make, the same one every other road in leads to.
///
/// Every word is Core's (`StudioMachinePill`); this draws them. The dot
/// breathes through `ActivityPulse`, the swell every other working mark in the window shares, so
/// it is in time with them and asks nothing of the frame clock when it is still.
final class StudioMachineButton: @unchecked Sendable {
    let widget = gtk_button_new()!
    private let dot = Gtk.label("●", css: "studio-dot", selectable: false)
    private let line = Gtk.label("", css: "studio-pill-line", selectable: false)
    private var tone: StudioMachinePill.Tone = .unknown
    private var breathes = false
    private var shown = ""

    /// What pressing the pill does: open the checklist for this machine and this lane.
    var onPress: (() -> Void)?

    init() {
        Gtk.addClass(widget, "studio-pill")
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_label_set_ellipsize(op(line), PANGO_ELLIPSIZE_END)
        gtk_label_set_max_width_chars(op(line), 64)
        gtk_box_append(ptr(row), dot)
        gtk_box_append(ptr(row), line)
        let chevron = Gtk.label(ImageGenField.engine.affordanceGlyph, css: "draw-chip-mark", selectable: false)
        gtk_box_append(ptr(row), chevron)
        gtk_button_set_child(ptr(widget), row)
        gtk_button_set_can_shrink(ptr(widget), 1)
        gtk_widget_set_halign(widget, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(widget, GTK_ALIGN_CENTER)
        Gtk.setHidden(dot, true)
        Gtk.connect(UnsafeMutableRawPointer(widget), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in self?.open() }
        }
        apply(StudioMachinePill(machine: "", state: nil, version: nil, tone: .unknown))
    }

    /// Opens the machine's checklist, as pressing the pill does.
    func open() {
        onPress?()
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
