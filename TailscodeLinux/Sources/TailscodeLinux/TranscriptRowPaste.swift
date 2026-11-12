import CAdw
import CGtkShim
import Foundation
import TailscodeCore

extension TranscriptRow {
    /// A person's message as rows: their words behind the accent rule, and each long paste folded
    /// to one line under them. The first row keeps the message's own key, so a message that never
    /// held a paste keeps the identity it always had.
    static func promptRows(_ text: String, key: String, messageID: String) -> [TranscriptRow] {
        guard PasteFold.mayHold(text) else {
            return [TranscriptRow(key: key, kind: .userText(text, messageID: messageID))]
        }
        let reading = PasteFold.split(text, id: key)
        guard reading.isFolded else {
            return [TranscriptRow(key: key, kind: .userText(text, messageID: messageID))]
        }
        return reading.pieces.enumerated().map { index, piece in
            let pieceKey = index == 0 ? key : "\(key):f\(index)"
            switch piece {
            case .words(let words):
                return TranscriptRow(key: pieceKey, kind: .userText(words, messageID: messageID))
            case .paste(let paste):
                return TranscriptRow(key: pieceKey, kind: .pastedText(paste, messageID: messageID))
            }
        }
    }

    /// A folded paste in a sent message: behind the prompt's own rule, what it is and how long,
    /// the first line that says anything, and the chevron that says the line opens the whole of it.
    static func pastedLine(
        _ paste: FoldedPaste, messageID: String, context: TranscriptContext
    ) -> UnsafeMutablePointer<GtkWidget> {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        let rule = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        Gtk.addClass(rule, "prompt-rule")
        gtk_widget_set_size_request(rule, 2, -1)

        let content = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        let glyph = Gtk.label("▤", css: "paste-line-glyph", selectable: false)
        gtk_widget_set_valign(glyph, GTK_ALIGN_CENTER)
        let label = Gtk.label(paste.label, css: "paste-line-label", selectable: false)
        gtk_widget_set_valign(label, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(content), glyph)
        gtk_box_append(ptr(content), label)
        if !paste.glimpse.isEmpty {
            let glimpse = Gtk.label(paste.glimpse, css: "paste-glimpse", selectable: false)
            gtk_label_set_ellipsize(op(glimpse), PANGO_ELLIPSIZE_END)
            gtk_label_set_single_line_mode(op(glimpse), 1)
            gtk_label_set_max_width_chars(op(glimpse), 64)
            gtk_widget_set_valign(glimpse, GTK_ALIGN_CENTER)
            gtk_box_append(ptr(content), glimpse)
        }
        let chevron = Gtk.label("›", css: "paste-line-glyph", selectable: false)
        gtk_widget_set_valign(chevron, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(content), chevron)

        let press = gtk_button_new()!
        Gtk.addClass(press, "flat")
        Gtk.addClass(press, "paste-line")
        gtk_button_set_child(ptr(press), content)
        gtk_widget_set_halign(press, GTK_ALIGN_START)
        gtk_widget_set_cursor_from_name(press, "pointer")
        gtk_widget_set_tooltip_text(press, Localized.text("Opens the pasted text"))
        tailscode_set_accessible_label(press, paste.spoken)
        let present = context.presentText
        let title = FoldedPaste.title
        let summary = paste.summary
        let body = paste.text
        Gtk.connect(UnsafeMutableRawPointer(press), "clicked") {
            present?(title, summary, body, true)
        }

        gtk_box_append(ptr(row), rule)
        gtk_box_append(ptr(row), press)
        let bits = UInt(bitPattern: row)
        Gtk.onRightClickCapture(row) { x, y in context.presentMessageMenu?(messageID, bits, x, y) }
        return row
    }
}
