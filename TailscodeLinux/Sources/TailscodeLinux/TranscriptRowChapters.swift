import CAdw
import CGtkShim
import Foundation
import TailscodeCore

extension TranscriptRow {
    /// Where a chapter began: its number and the time in the small label, its title under it in
    /// the strong voice, wrapping rather than cut. The whole heading is one flat button that opens
    /// the chapters panel on this chapter, so a reader can see where it sits in the conversation.
    static func chapterHeading(
        _ heading: ChapterHeading, key: String, context: TranscriptContext
    ) -> UnsafeMutablePointer<GtkWidget> {
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        let kicker = Gtk.label(
            StatusMark.chapters + " " + heading.label.uppercased() + "  ·  " + heading.time,
            css: "chapter-kicker", selectable: false)
        gtk_widget_set_halign(kicker, GTK_ALIGN_START)
        let title = Gtk.label(heading.title, css: "chapter-title", wrap: true, selectable: false)
        gtk_widget_set_halign(title, GTK_ALIGN_START)
        gtk_label_set_xalign(op(title), 0)
        gtk_box_append(ptr(column), kicker)
        gtk_box_append(ptr(column), title)
        let press = gtk_button_new()!
        Gtk.addClass(press, "flat")
        Gtk.addClass(press, "chapter-heading")
        gtk_button_set_child(ptr(press), column)
        gtk_widget_set_halign(press, GTK_ALIGN_FILL)
        gtk_widget_set_hexpand(press, 1)
        gtk_widget_set_cursor_from_name(press, "pointer")
        tailscode_set_accessible_label(press, heading.spoken)
        let anchor = key.hasPrefix("chapter:") ? String(key.dropFirst("chapter:".count)) : nil
        let open = context.openChapters
        Gtk.connect(UnsafeMutableRawPointer(press), "clicked") { open?(anchor) }
        return press
    }
}
