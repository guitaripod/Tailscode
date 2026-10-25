import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// A label on the wall: set in an absolute pixel size, a weight and a colour of its own through
/// Pango attributes, so it wears the wall's dark palette whatever the desk's appearance is and a
/// resize restyles it without parsing any CSS. It takes no pointer, so a press on the words
/// reaches the tile beneath.
final class WatchLabel: @unchecked Sendable {
    struct Style: Equatable {
        var size: Double
        var bold = false
        var mono = false
        var ink: PartyInk
        var alpha = 1.0
    }

    let widget: UnsafeMutablePointer<GtkWidget>
    private(set) var style: Style?
    private(set) var text = ""
    private(set) var lines = 0
    private(set) var wraps = true

    init(wrap: Bool = true) {
        widget = gtk_label_new("")!
        wraps = wrap
        let label: OpaquePointer = op(widget)
        gtk_label_set_xalign(label, 0)
        gtk_label_set_yalign(label, 0)
        gtk_label_set_wrap(label, wrap ? 1 : 0)
        gtk_label_set_wrap_mode(label, PANGO_WRAP_WORD_CHAR)
        gtk_label_set_selectable(label, 0)
        gtk_label_set_ellipsize(label, wrap ? PANGO_ELLIPSIZE_NONE : PANGO_ELLIPSIZE_END)
        gtk_widget_set_can_target(widget, 0)
        gtk_widget_set_can_focus(widget, 0)
        gtk_widget_set_overflow(widget, GTK_OVERFLOW_HIDDEN)
        tailscode_set_accessible_hidden(widget, 1)
    }

    func set(text next: String) {
        guard next != text else { return }
        text = next
        gtk_label_set_text(op(widget), next)
    }

    func set(lines next: Int) {
        guard next != lines else { return }
        lines = next
        gtk_label_set_lines(op(widget), next > 0 ? Int32(next) : -1)
        if wraps { gtk_label_set_ellipsize(op(widget), next > 0 ? PANGO_ELLIPSIZE_END : PANGO_ELLIPSIZE_NONE) }
    }

    func set(align: Float) {
        gtk_label_set_xalign(op(widget), align)
    }

    func set(style next: Style) {
        guard next != style else { return }
        style = next
        guard let list = pango_attr_list_new() else { return }
        pango_attr_list_insert(list, pango_attr_size_new_absolute(Int32(next.size * Double(PANGO_SCALE))))
        pango_attr_list_insert(list, pango_attr_weight_new(next.bold ? PANGO_WEIGHT_BOLD : PANGO_WEIGHT_NORMAL))
        if next.mono { pango_attr_list_insert(list, pango_attr_family_new("monospace")) }
        pango_attr_list_insert(
            list,
            pango_attr_foreground_new(
                UInt16(next.ink.red * 65535), UInt16(next.ink.green * 65535), UInt16(next.ink.blue * 65535)))
        if next.alpha < 1 {
            pango_attr_list_insert(list, pango_attr_foreground_alpha_new(UInt16(next.alpha * 65535)))
        }
        gtk_label_set_attributes(op(widget), list)
        pango_attr_list_unref(list)
    }

    func height(forWidth width: Double) -> Double {
        var minimum: Int32 = 0
        var natural: Int32 = 0
        var ignoredA: Int32 = 0
        var ignoredB: Int32 = 0
        gtk_widget_measure(
            widget, GTK_ORIENTATION_VERTICAL, Int32(max(1, width.rounded(.down))), &minimum, &natural,
            &ignoredA, &ignoredB)
        return Double(natural)
    }

    var naturalWidth: Double {
        var minimum: Int32 = 0
        var natural: Int32 = 0
        var ignoredA: Int32 = 0
        var ignoredB: Int32 = 0
        gtk_widget_measure(widget, GTK_ORIENTATION_HORIZONTAL, -1, &minimum, &natural, &ignoredA, &ignoredB)
        return Double(natural)
    }

    var isEllipsized: Bool {
        guard let layout = gtk_label_get_layout(op(widget)) else { return false }
        return pango_layout_is_ellipsized(layout) != 0
    }

    func lineHeight(size: Double) -> Double { size * 1.28 }
}
