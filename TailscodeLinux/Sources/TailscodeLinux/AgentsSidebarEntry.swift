import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The Agents row at the head of the sidebar: one press to the board, with a chip that is amber
/// when something waits on the person and the count of what is working when nothing does. It is a
/// fixture of the sidebar, not a row of its list, so a redraw of the list never takes it away.
final class AgentsSidebarEntry: @unchecked Sendable {
    let widget = gtk_button_new()!
    private let mark = Gtk.label("◉", css: "agents-glyph", selectable: false)
    private let title = Gtk.label(Localized.text("Agents"), css: "agents-entry-title", selectable: false)
    private let chip = Gtk.label("", css: "agents-chip-live", selectable: false)
    private(set) var reading = AgentsChip(needsYou: 0, working: 0)

    var chipLabel: UnsafeMutablePointer<GtkWidget> { chip }
    var isChipShown: Bool { gtk_widget_get_visible(chip) != 0 }

    init(open: @escaping @Sendable () -> Void) {
        Gtk.addClass(widget, "flat")
        Gtk.addClass(widget, "agents-entry")
        gtk_widget_set_hexpand(title, 1)
        gtk_widget_set_valign(chip, GTK_ALIGN_CENTER)
        tailscode_set_accessible_hidden(mark, 1)
        let line = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_box_append(ptr(line), mark)
        gtk_box_append(ptr(line), title)
        gtk_box_append(ptr(line), chip)
        gtk_button_set_child(ptr(widget), line)
        Gtk.margins(widget, top: 4, bottom: 0, leading: 6, trailing: 6)
        gtk_widget_set_tooltip_text(widget, Localized.text("What every agent is doing · Ctrl+Shift+A"))
        Gtk.connect(UnsafeMutableRawPointer(widget), "clicked") { Gtk.onMain { open() } }
        apply(AgentsChip(needsYou: 0, working: 0))
    }

    func apply(_ next: AgentsChip) {
        reading = next
        AgentsParts.setVisible(chip, !next.isEmpty)
        AgentsParts.setText(chip, next.text)
        Gtk.setTone(
            chip, next.isUrgent ? "agents-chip-needs" : "agents-chip-live",
            from: ["agents-chip-live", "agents-chip-needs"])
        Gtk.setTone(
            mark, next.isUrgent ? "glyph-needs" : next.working > 0 ? "glyph-running" : "glyph-pending",
            from: ["glyph-running", "glyph-needs", "glyph-pending"])
        tailscode_set_accessible_label(widget, next.spoken)
    }
}
