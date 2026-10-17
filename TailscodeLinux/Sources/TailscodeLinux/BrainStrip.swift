import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The readout of a stacked row, before anything is pinned: two lines directly under the head that
/// wear the step's zone on a 3 point left edge. Pinning grows it into the whole readout.
final class BrainStrip: @unchecked Sendable {
    unowned let owner: BrainView
    let widget: UnsafeMutablePointer<GtkWidget>
    private let first: UnsafeMutablePointer<GtkWidget>
    private let second: UnsafeMutablePointer<GtkWidget>
    private var shown: NeuralReadout?
    private var zoneClass: String?

    init(owner: BrainView) {
        self.owner = owner
        widget = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        first = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        second = BrainUI.label("", "bn-strip-line")
        Gtk.addClass(widget, "bn-strip")
        Gtk.addClass(first, "bn-strip-head")
        gtk_label_set_ellipsize(op(second), PANGO_ELLIPSIZE_END)
        gtk_box_append(ptr(widget), first)
        gtk_box_append(ptr(widget), second)
        gtk_widget_set_overflow(widget, GTK_OVERFLOW_HIDDEN)
        tailscode_set_accessible_label(widget, BrainWords.readoutLabel)
    }

    func show(_ readout: NeuralReadout, inks: BrainInks) {
        if shown == readout { return }
        shown = readout
        Gtk.removeChildren(of: first)
        if let zoneClass { gtk_widget_remove_css_class(widget, zoneClass) }
        zoneClass = nil
        if let step = readout.step {
            let zone = step.header.zone
            let name = "bn-z-\(BrainUI.zoneName(zone))"
            zoneClass = name
            Gtk.addClass(widget, name)
            gtk_box_append(ptr(first), BrainUI.shapeGlyph(zone, size: 16) { inks.corrected(zone) })
            gtk_box_append(ptr(first), BrainUI.label(step.header.label, "bn-zone", "bn-tone-text"))
            gtk_box_append(ptr(first), BrainUI.label(step.subject.title, "bn-strip-title"))
            gtk_box_append(
                ptr(first),
                BrainUI.label(step.header.chip.word, "bn-chip", BrainReadout.toneClass(step.header.chip.tone)))
            let counter = BrainUI.label(step.header.counter, "bn-counter", ellipsize: true)
            gtk_widget_set_hexpand(counter, 1)
            gtk_label_set_xalign(op(counter), 1)
            gtk_box_append(ptr(first), counter)
            let prompt = step.subject.kind == .command ? "$ " : ""
            gtk_label_set_text(op(second), prompt + (step.subject.primary.components(separatedBy: "\n").first ?? ""))
        } else if let digest = readout.digest {
            gtk_box_append(ptr(first), BrainUI.label(BrainWords.turn, "bn-zone", "bn-dim"))
            gtk_box_append(ptr(first), BrainUI.label(BrainWords.settled.uppercased(), "bn-chip", "bn-chip-live"))
            let counter = BrainUI.label(BrainWords.steps(digest.ticks.count), "bn-counter", ellipsize: true)
            gtk_widget_set_hexpand(counter, 1)
            gtk_label_set_xalign(op(counter), 1)
            gtk_box_append(ptr(first), counter)
            gtk_label_set_text(op(second), digest.headline)
        } else {
            gtk_box_append(ptr(first), BrainUI.label(readout.announcement, "bn-strip-title"))
            gtk_label_set_text(op(second), "")
        }
    }

    var text: String {
        gtk_label_get_text(op(second)).map { String(cString: $0) } ?? ""
    }
}
