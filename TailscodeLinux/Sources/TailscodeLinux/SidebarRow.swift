import CAdw
import Foundation
import TailscodeCore

/// Every kind of row the chat list can draw, in one place: a section heading, a conversation, the
/// banner that says a server stopped answering, and the line that admits there is nothing here.
enum SidebarRow {
    static func header(_ title: String, count: Int) -> UnsafeMutablePointer<GtkWidget> {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        let label = Gtk.label(title, css: "section-header", selectable: false)
        gtk_widget_set_hexpand(label, 1)
        let tally = Gtk.label("\(count)", css: "section-header", selectable: false)
        gtk_label_set_ellipsize(op(tally), PANGO_ELLIPSIZE_NONE)
        gtk_widget_set_size_request(tally, 34, -1)
        gtk_box_append(ptr(row), label)
        gtk_box_append(ptr(row), tally)
        return row
    }

    static func banner(_ text: String) -> UnsafeMutablePointer<GtkWidget> {
        let label = Gtk.label(text, css: "row-detail", wrap: true, selectable: false)
        Gtk.addClass(label, "glyph-error")
        Gtk.margins(label, top: 8, bottom: 8, leading: 12, trailing: 12)
        return label
    }

    static func empty(_ text: String) -> UnsafeMutablePointer<GtkWidget> {
        let label = Gtk.label(text, css: "dim", selectable: false)
        Gtk.margins(label, top: 20, bottom: 20, leading: 12, trailing: 12)
        return label
    }

    /// One conversation. Three registers on two lines — what it is, where it lives, and what it is
    /// doing — with the state carried by a pill rather than by a colour a reader has to decode.
    /// A right click hands back the row widget (as bits, for the sendable hop) and where inside it
    /// the click landed, so the caller can open a menu under the pointer.
    static func make(
        _ model: SessionRowModel, focused: Bool,
        onOpen: @escaping @Sendable () -> Void,
        onMenu: @escaping @Sendable (UInt, Double, Double) -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let button = gtk_button_new()!
        Gtk.addClass(button, "flat")
        Gtk.addClass(button, "session-row")
        if focused { Gtk.addClass(button, "row-focused") }

        let glyph = Gtk.label(model.state.glyph.text, css: model.state.glyph.css, selectable: false)
        gtk_widget_set_valign(glyph, GTK_ALIGN_START)
        Gtk.margins(glyph, top: 3)

        let titleRow = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        let title = Gtk.label(
            model.title, css: model.unread ? "row-title-unread" : "row-title", selectable: false)
        gtk_widget_set_hexpand(title, 1)
        gtk_box_append(ptr(titleRow), title)
        if let pill = model.state.pill {
            gtk_box_append(ptr(titleRow), makePill(pill.text, css: pill.css))
        }
        if model.saved {
            gtk_box_append(ptr(titleRow), makePill(Localized.text("SAVED"), css: "pill-saved"))
        }
        if model.unread {
            gtk_box_append(ptr(titleRow), Gtk.label("●", css: "unread-dot", selectable: false))
        }

        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        gtk_box_append(ptr(column), titleRow)
        gtk_box_append(
            ptr(column), Gtk.label(model.detail, css: "row-detail", selectable: false))
        gtk_widget_set_hexpand(column, 1)

        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        Gtk.margins(row, top: 4, bottom: 4, leading: 4, trailing: 4)
        gtk_box_append(ptr(row), glyph)
        gtk_box_append(ptr(row), column)
        gtk_button_set_child(ptr(button), row)

        Gtk.connect(UnsafeMutableRawPointer(button), "clicked", onOpen)
        let buttonBits = UInt(bitPattern: button)
        Gtk.onRightClick(button) { x, y in onMenu(buttonBits, x, y) }
        return button
    }

    private static func makePill(_ text: String, css: String) -> UnsafeMutablePointer<GtkWidget> {
        let label = Gtk.label(text, css: "pill", selectable: false)
        Gtk.addClass(label, css)
        gtk_widget_set_valign(label, GTK_ALIGN_CENTER)
        return label
    }
}
