import CAdw
import Foundation
import TailscodeCore

/// The empty pane's chooser, drawn. One heading, one hint, and the rows `PaneChooser` decided —
/// numbered, because 1–9 pick them outright, and shaped like the chat list's rows so a person
/// reading two panes is reading one vocabulary.
enum ChooserView {
    static func make(
        _ model: PaneChooser, onActivate: @escaping @Sendable (Int) -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 4)
        Gtk.margins(column, top: 18, bottom: 18, leading: 4, trailing: 4)

        let heading = Gtk.label(model.heading, css: "section-header", selectable: false)
        Gtk.margins(heading, leading: 6, trailing: 6)
        gtk_box_append(ptr(column), heading)

        let hint = Gtk.label(model.hint, css: "row-detail", selectable: false)
        Gtk.margins(hint, bottom: 8, leading: 6, trailing: 6)
        gtk_box_append(ptr(column), hint)

        for (index, row) in model.rows.enumerated() {
            gtk_box_append(
                ptr(column),
                make(row, number: index + 1, focused: index == model.cursor) {
                    onActivate(index)
                })
        }
        return column
    }

    private static func make(
        _ row: PaneChooserRow, number: Int, focused: Bool,
        onActivate: @escaping @Sendable () -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let button = gtk_button_new()!
        Gtk.addClass(button, "flat")
        Gtk.addClass(button, "session-row")
        if focused { Gtk.addClass(button, "row-focused") }

        let index = Gtk.label(number <= 9 ? "\(number)" : " ", css: "row-detail", selectable: false)
        gtk_label_set_ellipsize(op(index), PANGO_ELLIPSIZE_NONE)
        gtk_widget_set_size_request(index, 16, -1)
        gtk_widget_set_valign(index, GTK_ALIGN_START)
        Gtk.margins(index, top: 3)

        let titleRow = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        let title = Gtk.label(
            row.title, css: row.isPrimary ? "row-title-unread" : "row-title", selectable: false)
        gtk_widget_set_hexpand(title, 1)
        gtk_box_append(ptr(titleRow), title)
        if let badge = row.badge {
            let pill = Gtk.label(badge.text, css: "pill", selectable: false)
            switch badge {
            case .live: Gtk.addClass(pill, "pill-live")
            case .offline: Gtk.addClass(pill, "pill-offline")
            }
            gtk_widget_set_valign(pill, GTK_ALIGN_CENTER)
            gtk_box_append(ptr(titleRow), pill)
        }

        let lines = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        gtk_box_append(ptr(lines), titleRow)
        gtk_box_append(ptr(lines), Gtk.label(row.detail, css: "row-detail", selectable: false))
        if let note = row.note {
            let label = Gtk.label(note, css: "row-note", wrap: true, selectable: false)
            gtk_label_set_max_width_chars(op(label), 28)
            gtk_box_append(ptr(lines), label)
        }
        gtk_widget_set_hexpand(lines, 1)

        let content = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        Gtk.margins(content, top: 4, bottom: 4, leading: 4, trailing: 4)
        gtk_box_append(ptr(content), index)
        gtk_box_append(ptr(content), lines)
        gtk_button_set_child(ptr(button), content)
        Gtk.connect(UnsafeMutableRawPointer(button), "clicked", onActivate)
        return button
    }
}
