import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The start-from slot: 56 points at the dock's leading edge, the same square in the image studio
/// and the forge. A dashed target when nothing is held, the picture itself when one is — or a
/// glyph for a start that has no picture of its own, such as the end of a clip — and a press opens
/// where else a start can come from. A small cross lets go of what is held, and a count says when
/// it is more than one.
final class StudioSlotView: @unchecked Sendable {
    /// What the dock places: the slot with its cross.
    let widget = gtk_overlay_new()!
    private let button: UnsafeMutablePointer<GtkWidget>
    private let art = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    private let caption = Gtk.label("", css: "studio-slot-caption", selectable: false)
    private let count = Gtk.label("", css: "studio-slot-count", selectable: false)
    private let remove: UnsafeMutablePointer<GtkWidget>
    private var shown: [String]?

    /// - Parameters:
    ///   - rows: where a start can come from, built each time the slot is pressed.
    ///   - onRemove: the cross was pressed.
    init(
        rows: @escaping @Sendable () -> [(title: String, detail: String?, action: @Sendable () -> Void)],
        onRemove: @escaping @Sendable () -> Void
    ) {
        button = Gtk.menuButton("", css: [], rows: rows)
        remove = Gtk.button("×", css: ["studio-slot-remove"], onClick: { Gtk.onMain { onRemove() } })
        Gtk.addClass(button, "studio-slot")
        gtk_menu_button_set_always_show_arrow(op(button), 0)
        gtk_menu_button_set_can_shrink(op(button), 1)
        let inner = gtk_overlay_new()!
        Gtk.addClass(art, "studio-slot-art")
        gtk_widget_set_size_request(art, 56, 56)
        gtk_overlay_set_child(op(inner), art)
        gtk_widget_set_halign(caption, GTK_ALIGN_FILL)
        gtk_widget_set_valign(caption, GTK_ALIGN_END)
        gtk_label_set_xalign(op(caption), 0.5)
        gtk_label_set_ellipsize(op(caption), PANGO_ELLIPSIZE_NONE)
        gtk_label_set_text(op(caption), StudioWords.startFromTitle)
        gtk_widget_set_can_target(caption, 0)
        gtk_overlay_add_overlay(op(inner), caption)
        gtk_widget_set_halign(count, GTK_ALIGN_END)
        gtk_widget_set_valign(count, GTK_ALIGN_START)
        gtk_widget_set_can_target(count, 0)
        gtk_widget_set_visible(count, 0)
        gtk_overlay_add_overlay(op(inner), count)
        gtk_menu_button_set_child(op(button), inner)
        tailscode_set_accessible_label(button, StudioWords.startFromTitle)

        gtk_widget_set_size_request(widget, 56, 56)
        gtk_widget_set_valign(widget, GTK_ALIGN_START)
        gtk_overlay_set_child(op(widget), button)
        gtk_widget_set_halign(remove, GTK_ALIGN_END)
        gtk_widget_set_valign(remove, GTK_ALIGN_START)
        gtk_widget_set_visible(remove, 0)
        gtk_widget_set_tooltip_text(remove, ImageGenWords.detachHint)
        tailscode_set_accessible_label(remove, ImageGenWords.detachHint)
        gtk_overlay_add_overlay(op(widget), remove)
    }

    /// Says what the slot holds: how many starts, the decoded picture of the first when it has
    /// one, or a glyph when it does not. Nothing is redrawn when nothing changed.
    func apply(count held: Int, bits: UInt, glyph: String? = nil, tooltip: String) {
        gtk_widget_set_visible(remove, held == 0 ? 0 : 1)
        gtk_widget_set_visible(count, held > 1 ? 1 : 0)
        gtk_label_set_text(op(count), "\(held)")
        gtk_widget_set_tooltip_text(button, tooltip)
        let signature = ["\(held)", "\(bits)", glyph ?? ""]
        guard shown == nil || shown! != signature else { return }
        shown = signature
        Gtk.removeChildren(of: art)
        if held == 0 {
            Gtk.addClass(art, "studio-slot-empty")
            let plus = Gtk.label("+", css: "studio-slot-plus", selectable: false)
            gtk_widget_set_halign(plus, GTK_ALIGN_CENTER)
            gtk_widget_set_valign(plus, GTK_ALIGN_START)
            gtk_box_append(ptr(art), plus)
            gtk_widget_remove_css_class(caption, "studio-slot-caption-held")
            return
        }
        gtk_widget_remove_css_class(art, "studio-slot-empty")
        Gtk.addClass(caption, "studio-slot-caption-held")
        if bits != 0, let picture = Gtk.studioPicture(bits: bits, fit: GTK_CONTENT_FIT_COVER) {
            gtk_widget_set_size_request(picture, 56, 56)
            Gtk.setHidden(picture, true)
            gtk_box_append(ptr(art), Gtk.squareFrame(holding: picture, side: 56))
        } else if let glyph {
            let mark = Gtk.label(glyph, css: "studio-slot-plus", selectable: false)
            gtk_widget_set_halign(mark, GTK_ALIGN_CENTER)
            gtk_widget_set_valign(mark, GTK_ALIGN_START)
            gtk_box_append(ptr(art), mark)
        }
    }

    /// Opens where else a start can come from, as pressing the slot does.
    func open() {
        gtk_menu_button_popup(op(button))
    }

    /// Files dropped on the slot are starts.
    func acceptDrops(_ handler: @escaping ([String]) -> Void) {
        Gtk.acceptFileDrops(on: widget, handler)
    }
}
