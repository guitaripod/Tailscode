import CAdw
import CGtkShim
import Foundation
import TailscodeCore

extension ChatPane {
    /// A long paste beside the box: what it is and how long, the first line that says anything,
    /// and the control that takes it away. Pressing the chip opens the whole paste, where it can be
    /// copied or put back in the box as words to edit.
    func pasteChip(_ paste: FoldedPaste) -> UnsafeMutablePointer<GtkWidget> {
        let chip = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 2)
        Gtk.addClass(chip, "carry-chip")
        Gtk.addClass(chip, "paste-chip")
        gtk_widget_set_valign(chip, GTK_ALIGN_CENTER)

        let content = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        let glyph = Gtk.label("▤", css: "chip-glyph", selectable: false)
        gtk_widget_set_valign(glyph, GTK_ALIGN_CENTER)
        let label = Gtk.label(paste.label, css: "carry-chip-text", selectable: false)
        gtk_widget_set_valign(label, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(content), glyph)
        gtk_box_append(ptr(content), label)
        if !paste.glimpse.isEmpty {
            let glimpse = Gtk.label(paste.glimpse, css: "paste-glimpse", selectable: false)
            gtk_label_set_ellipsize(op(glimpse), PANGO_ELLIPSIZE_END)
            gtk_label_set_max_width_chars(op(glimpse), 28)
            gtk_label_set_single_line_mode(op(glimpse), 1)
            gtk_widget_set_valign(glimpse, GTK_ALIGN_CENTER)
            gtk_box_append(ptr(content), glimpse)
        }

        let id = paste.id
        let open = gtk_button_new()!
        Gtk.addClass(open, "flat")
        Gtk.addClass(open, "paste-chip-open")
        gtk_button_set_child(ptr(open), content)
        gtk_widget_set_cursor_from_name(open, "pointer")
        gtk_widget_set_tooltip_text(open, Localized.text("Opens the pasted text"))
        tailscode_set_accessible_label(open, paste.spoken)
        Gtk.connect(UnsafeMutableRawPointer(open), "clicked") { [weak self] in
            Gtk.onMain { [weak self] in self?.readPaste(id) }
        }

        let remove = Localized.text("Remove %@", FoldedPaste.title)
        let clear = Gtk.button("✕", css: ["flat", "carry-chip-clear"]) { [weak self] in
            Gtk.onMain { [weak self] in self?.removePaste(id) }
        }
        gtk_widget_set_valign(clear, GTK_ALIGN_CENTER)
        gtk_widget_set_tooltip_text(clear, remove)
        tailscode_set_accessible_label(clear, remove)

        gtk_box_append(ptr(chip), open)
        gtk_box_append(ptr(chip), clear)
        gtk_widget_set_margin_end(chip, 6)
        return chip
    }

    /// The whole paste in the reader, with the one thing only the composer can offer: putting it
    /// back in the box as words.
    func readPaste(_ id: String) {
        guard let paste = pastes.first(where: { $0.id == id }) else { return }
        Dialogs.reader(
            title: FoldedPaste.title, subtitle: paste.summary, body: paste.text, mono: true,
            parent: host?.windowWidget,
            action: (
                Localized.text("Edit as text"),
                { [weak self] in Gtk.onMain { [weak self] in self?.unfoldPaste(id) } }
            ))
    }
}
