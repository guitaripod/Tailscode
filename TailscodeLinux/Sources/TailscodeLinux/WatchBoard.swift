import CAdw
import Foundation
import TailscodeCore

/// What is on, drawn. The board is the empty video slot's body: the sections `WatchChooser`
/// decided, each with its own heading, its rows carrying a picture, a live badge and the facts
/// under them, and the row that stands for the rest of a section it is holding back.
///
/// Rebuilt whole on every render, like the pane chooser beside it — a board is a few dozen widgets
/// and the alternative is diffing a tree that changes shape every time an answer lands. What does
/// not get rebuilt is the picture: textures live in `MediaImageCache`, so a re-render costs a
/// widget rather than a fetch.
enum WatchBoard {
    static let thumbWidth: Int32 = 104
    static let thumbHeight: Int32 = 58

    /// The board, and where in it the cursor sits — reported as the child's position rather than as
    /// its pointer, because the board is rebuilt whenever an answer lands and a pointer handed
    /// across a frame is a pointer to a widget that may already be gone.
    static func make(
        _ model: WatchChooser, onActivate: @escaping @Sendable (String, Int) -> Void
    ) -> (root: UnsafeMutablePointer<GtkWidget>, focused: Int?) {
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        gtk_widget_set_hexpand(column, 1)
        var cursorAt: Int?
        var position = 0

        for section in model.sections {
            gtk_box_append(ptr(column), header(section))
            position += 1
            for (offset, row) in section.rows.enumerated() {
                let isFocused = row.id == model.focused?.id
                let widget = make(row, focused: isFocused) { onActivate(section.id, offset) }
                if isFocused { cursorAt = position }
                gtk_box_append(ptr(column), widget)
                position += 1
            }
        }
        return (column, cursorAt)
    }

    private static func header(_ section: WatchSection) -> UnsafeMutablePointer<GtkWidget> {
        let line = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        let title = Gtk.label(section.title, css: "section-header", selectable: false)
        gtk_widget_set_hexpand(title, 1)
        gtk_box_append(ptr(line), title)
        if !section.detail.isEmpty {
            let detail = Gtk.label(section.detail, css: "watch-section-detail", selectable: false)
            gtk_widget_set_valign(detail, GTK_ALIGN_CENTER)
            gtk_box_append(ptr(line), detail)
        }
        Gtk.margins(line, trailing: 8)
        return line
    }

    private static func make(
        _ row: WatchRow, focused: Bool, onActivate: @escaping @Sendable () -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        guard row.isActivatable else { return note(row) }
        let button = gtk_button_new()!
        Gtk.addClass(button, "flat")
        Gtk.addClass(button, "session-row")
        if focused { Gtk.addClass(button, "row-focused") }

        let content = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        Gtk.margins(content, top: 4, bottom: 4, leading: 4, trailing: 6)

        if case .expander = row.kind {
            gtk_box_append(ptr(content), spacer())
        } else {
            gtk_box_append(ptr(content), thumbnail(row))
        }
        gtk_box_append(ptr(content), lines(row))
        gtk_button_set_child(ptr(button), content)
        Gtk.connect(UnsafeMutableRawPointer(button), "clicked", onActivate)
        return button
    }

    /// A line the board owed the reader — that a source is being asked, that one did not answer, or
    /// that nothing matched. It is a label, never a button: nothing here does anything, and drawing
    /// it as a row that hovers would promise otherwise.
    private static func note(_ row: WatchRow) -> UnsafeMutablePointer<GtkWidget> {
        let label = Gtk.label(row.title, css: "watch-note", wrap: true, selectable: false)
        gtk_label_set_max_width_chars(op(label), 40)
        Gtk.margins(label, top: 2, bottom: 4, leading: 8, trailing: 8)
        return label
    }

    /// The picture's box, always the same size whether or not a picture ever arrives. A row that
    /// grows when its thumbnail lands moves every row under it, which is the one thing a list
    /// being read must not do.
    private static func thumbnail(_ row: WatchRow) -> UnsafeMutablePointer<GtkWidget> {
        let frame = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        Gtk.addClass(frame, "watch-thumb")
        gtk_widget_set_size_request(frame, thumbWidth, thumbHeight)
        gtk_widget_set_valign(frame, GTK_ALIGN_START)
        guard let address = row.thumbnail else { return frame }
        let bits = MediaImageCache.shared.texture(for: address)
        guard bits != 0 else {
            MediaImageCache.shared.fetch(address)
            return frame
        }
        if let picture = MediaImageCache.shared.picture(
            bits, width: thumbWidth, height: thumbHeight)
        {
            gtk_box_append(ptr(frame), picture)
        }
        return frame
    }

    private static func spacer() -> UnsafeMutablePointer<GtkWidget> {
        let box = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_size_request(box, thumbWidth, 1)
        return box
    }

    private static func lines(_ row: WatchRow) -> UnsafeMutablePointer<GtkWidget> {
        let titleRow = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        let title = Gtk.label(
            row.title, css: row.isPrimary ? "row-title-unread" : "row-title", selectable: false)
        gtk_widget_set_hexpand(title, 1)
        gtk_box_append(ptr(titleRow), title)
        if row.isFollowed {
            let mark = Gtk.label("★", css: "watch-followed", selectable: false)
            gtk_widget_set_valign(mark, GTK_ALIGN_CENTER)
            gtk_box_append(ptr(titleRow), mark)
        }
        if let badge = row.badge {
            let pill = Gtk.label(badge.text, css: "pill", selectable: false)
            switch badge {
            case .live: Gtk.addClass(pill, "pill-live")
            case .offline: Gtk.addClass(pill, "pill-offline")
            case .plain: Gtk.addClass(pill, "pill-source")
            }
            gtk_widget_set_valign(pill, GTK_ALIGN_CENTER)
            gtk_box_append(ptr(titleRow), pill)
        }

        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 1)
        gtk_box_append(ptr(column), titleRow)
        if !row.detail.isEmpty {
            gtk_box_append(
                ptr(column), Gtk.label(row.detail, css: "row-detail", selectable: false))
        }
        if let note = row.note, !note.isEmpty {
            gtk_box_append(ptr(column), Gtk.label(note, css: "watch-meta", selectable: false))
        }
        gtk_widget_set_hexpand(column, 1)
        gtk_widget_set_valign(column, GTK_ALIGN_CENTER)
        return column
    }
}
