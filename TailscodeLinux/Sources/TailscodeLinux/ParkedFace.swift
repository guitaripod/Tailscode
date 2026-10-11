import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// A pane that holds a conversation and spends nothing on it: no stream, no clock. It says whose
/// conversation it is, what the chat list last heard about it, and the last words a glance read
/// from it, dimmed and dated so they are never mistaken for live ones — and offers to resume.
///
/// Everything on it comes from what the window already has: the face from the listing the chat
/// list polls, the words from a glance kept in memory for ten minutes. A needs-you or a finish
/// reaches it through the listing and the turn-wait machinery, never through a stream of its own.
final class ParkedFace: @unchecked Sendable {
    let widget = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 8)
    private let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
    private let glyph = Gtk.label("", css: "glance-glyph", selectable: false)
    private let titleLabel = Gtk.label("", css: "glance-title", selectable: false)
    private let badge = Gtk.label(Localized.text("Paused"), css: "glance-badge", selectable: false)
    private let detail = Gtk.label("", css: "parked-detail", wrap: true, selectable: false)
    private let tail = Gtk.label("", css: "parked-tail", wrap: true, selectable: false)
    private let age = Gtk.label("", css: "parked-age", selectable: false)
    private var resume: UnsafeMutablePointer<GtkWidget>?
    private var position = (index: 1, count: 1)
    private var title = ""
    private(set) var renders = 0

    init(paneID: PaneID, onResume: @escaping @Sendable () -> Void) {
        Gtk.addClass(widget, "parked-face")
        Gtk.addClass(widget, "tile-face")
        gtk_widget_set_hexpand(widget, 1)
        gtk_widget_set_vexpand(widget, 1)
        gtk_widget_set_overflow(widget, GTK_OVERFLOW_HIDDEN)
        gtk_widget_set_valign(column, GTK_ALIGN_CENTER)
        gtk_widget_set_halign(column, GTK_ALIGN_CENTER)
        gtk_widget_set_vexpand(column, 1)
        gtk_widget_set_hexpand(column, 1)

        let heading = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        gtk_widget_set_halign(heading, GTK_ALIGN_CENTER)
        gtk_widget_set_visible(glyph, 0)
        gtk_label_set_ellipsize(op(titleLabel), PANGO_ELLIPSIZE_END)
        gtk_label_set_max_width_chars(op(titleLabel), 40)
        Gtk.makePaneDragSource(titleLabel, payload: PaneMovePayload(pane: paneID).encoded)
        gtk_box_append(ptr(heading), glyph)
        gtk_box_append(ptr(heading), titleLabel)
        gtk_box_append(ptr(column), heading)

        gtk_widget_set_halign(badge, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(column), badge)
        for label in [detail, tail] {
            gtk_label_set_xalign(op(label), 0.5)
            gtk_label_set_justify(op(label), GTK_JUSTIFY_CENTER)
            gtk_label_set_max_width_chars(op(label), 56)
            gtk_widget_set_halign(label, GTK_ALIGN_CENTER)
        }
        gtk_label_set_lines(op(tail), 3)
        gtk_label_set_ellipsize(op(tail), PANGO_ELLIPSIZE_END)
        gtk_box_append(ptr(column), detail)
        gtk_box_append(ptr(column), tail)
        gtk_widget_set_halign(age, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(column), age)

        let button = Gtk.button(Localized.text("Resume"), css: ["parked-resume"]) {
            Gtk.onMain { onResume() }
        }
        gtk_widget_set_halign(button, GTK_ALIGN_CENTER)
        Gtk.margins(button, top: 6)
        gtk_box_append(ptr(column), button)
        resume = button
        gtk_box_append(ptr(widget), column)
    }

    /// Draws the paused face. `detail` is why it is paused when that is not the person's own
    /// choice — a safe restore after a launch that did not close normally.
    func render(
        title: String, activity: ActivityKind?, lastWords: String?, readAt: Date?,
        detail text: String?, index: Int, of count: Int
    ) {
        renders += 1
        self.title = title
        position = (index, count)
        gtk_label_set_text(op(titleLabel), title)
        if let activity {
            let icon = activity.icon
            gtk_widget_set_visible(glyph, 1)
            gtk_label_set_text(op(glyph), icon.glyph)
            Gtk.setTone(glyph, icon.tone.glyphCSS, from: GlanceTile.tones)
        } else {
            gtk_widget_set_visible(glyph, 0)
        }
        gtk_label_set_text(op(detail), text ?? "")
        gtk_widget_set_visible(detail, text == nil ? 0 : 1)
        let words = lastWords?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        gtk_label_set_text(op(tail), words)
        gtk_widget_set_visible(tail, words.isEmpty ? 0 : 1)
        if let readAt, !words.isEmpty {
            gtk_label_set_text(op(age), SessionRowModel.age(of: readAt))
            gtk_widget_set_visible(age, 1)
        } else {
            gtk_widget_set_visible(age, 0)
        }
        var spoken = [
            Localized.text("Pane %@ of %@", "\(index)", "\(count)"), title, Localized.text("Paused"),
        ]
        if let activity { spoken.append(activity.spoken) }
        tailscode_set_accessible_label(widget, spoken.joined(separator: ", "))
    }

    func setFocusRing(_ on: Bool) {
        if on { gtk_widget_add_css_class(widget, "pane-focused") } else {
            gtk_widget_remove_css_class(widget, "pane-focused")
        }
    }

    var titleText: String { title }
    var hasWords: Bool { gtk_widget_get_visible(tail) != 0 }
    var hasResume: Bool { resume != nil }

    func pressResume() {
        guard let resume else { return }
        gtk_widget_activate(resume)
    }
}
