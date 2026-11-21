import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

extension ModelChooserWindow {
    /// The card behind a chip, as a popover off the strip it sits in: Core's headings, lines and
    /// footnotes in one column, the state line in the state's own tone.
    static func showBriefing(
        _ card: ChooserBriefing, on anchor: UnsafeMutablePointer<GtkWidget>, x: Double, y: Double
    ) {
        let popover = gtk_popover_new()!
        gtk_widget_set_parent(popover, anchor)
        var rect = GdkRectangle(x: gint(x), y: gint(y), width: 1, height: 1)
        gtk_popover_set_pointing_to(ptr(popover), &rect)
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 4)
        Gtk.margins(column, top: 10, bottom: 10, leading: 12, trailing: 12)
        gtk_widget_set_size_request(column, 380, -1)
        gtk_box_append(ptr(column), Gtk.label(card.title, css: "row-title", selectable: false))
        gtk_box_append(ptr(column), Gtk.label(card.subtitle, css: "row-detail", selectable: false))
        let lead = Gtk.label(card.lead, css: "row-detail", wrap: true, selectable: false)
        gtk_label_set_max_width_chars(op(lead), 60)
        gtk_box_append(ptr(column), lead)
        for (index, section) in card.sections.enumerated() {
            let heading = Gtk.label(section.heading.uppercased(), css: "section-title", selectable: false)
            Gtk.margins(heading, top: 10)
            gtk_box_append(ptr(column), heading)
            for (row, line) in section.lines.enumerated() {
                let item = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
                let glyph = Gtk.label(line.glyph ?? "·", css: "row-detail", selectable: false)
                gtk_widget_set_size_request(glyph, 16, -1)
                if index == 0, row == 0, let tone = card.tone {
                    Gtk.addClass(glyph, toneClass(tone))
                }
                gtk_box_append(ptr(item), glyph)
                let name = Gtk.label(line.label, css: "row-title", selectable: false)
                gtk_widget_set_hexpand(name, 1)
                gtk_label_set_xalign(op(name), 0)
                gtk_box_append(ptr(item), name)
                let value = Gtk.label(line.value, css: "row-detail", wrap: true, selectable: false)
                gtk_label_set_max_width_chars(op(value), 36)
                gtk_label_set_xalign(op(value), 1)
                gtk_box_append(ptr(item), value)
                gtk_box_append(ptr(column), item)
            }
            if let footnote = section.footnote {
                let note = Gtk.label(footnote, css: "row-detail", wrap: true, selectable: false)
                gtk_label_set_max_width_chars(op(note), 60)
                Gtk.margins(note, top: 4)
                gtk_box_append(ptr(column), note)
            }
        }
        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(op(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_max_content_height(op(scroller), 560)
        gtk_scrolled_window_set_propagate_natural_height(op(scroller), 1)
        gtk_scrolled_window_set_propagate_natural_width(op(scroller), 1)
        gtk_scrolled_window_set_child(op(scroller), column)
        gtk_popover_set_child(ptr(popover), scroller)
        let popoverHold = Gtk.WeakWidget(popover)
        Gtk.connect(UnsafeMutableRawPointer(popover), "closed") {
            Gtk.onMain {
                guard let held = popoverHold.widget, gtk_widget_get_parent(held) != nil
                else { return }
                gtk_widget_unparent(held)
            }
        }
        gtk_popover_popup(ptr(popover))
    }
}
