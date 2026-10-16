import CAdw
import CGtkShim
import Foundation

/// A walk over every label a window shows, counting the ones that are cut short: ellipsized, given
/// less width than their own words need, or wrapped into less height than their lines take. It is
/// how "no label is ever cut off at any type size" is a number rather than a look.
enum ClockAudit {
    struct Result {
        var audited = 0
        var cut = 0
        var notes: [String] = []

        var line: String { "labels=\(audited) cut=\(cut)" + (notes.isEmpty ? "" : " " + notes.prefix(8).joined(separator: " | ")) }
    }

    static func run(on widget: UnsafeMutablePointer<GtkWidget>) -> Result {
        var result = Result()
        visit(widget, &result)
        return result
    }

    private static func visit(_ widget: UnsafeMutablePointer<GtkWidget>, _ result: inout Result) {
        if String(cString: gtk_widget_get_css_name(widget)) == "label", gtk_widget_get_mapped(widget) != 0 {
            check(widget, &result)
        }
        var child = gtk_widget_get_first_child(widget)
        while let current = child {
            visit(current, &result)
            child = gtk_widget_get_next_sibling(current)
        }
    }

    private static func check(_ widget: UnsafeMutablePointer<GtkWidget>, _ result: inout Result) {
        let label: OpaquePointer = op(widget)
        let text = gtk_label_get_text(label).map { String(cString: $0) } ?? ""
        guard !text.isEmpty else { return }
        result.audited += 1
        func fail(_ why: String) {
            result.cut += 1
            result.notes.append("\(why):\(text.prefix(24))")
        }
        if gtk_label_get_ellipsize(label) != PANGO_ELLIPSIZE_NONE {
            fail("ellipsize")
            return
        }
        guard let layout = gtk_label_get_layout(label) else { return }
        if pango_layout_is_ellipsized(layout) != 0 {
            fail("ellipsized")
            return
        }
        var drawnWidth: Int32 = 0
        var drawnHeight: Int32 = 0
        pango_layout_get_pixel_size(layout, &drawnWidth, &drawnHeight)
        let width = gtk_widget_get_width(widget)
        let height = gtk_widget_get_height(widget)
        if width < drawnWidth { fail("narrow \(width)<\(drawnWidth)") }
        if height < drawnHeight { fail("short \(height)<\(drawnHeight)") }
    }
}
