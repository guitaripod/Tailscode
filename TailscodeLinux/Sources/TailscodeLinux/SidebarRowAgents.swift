import CAdw
import CGtkShim
import Foundation
import TailscodeCore

extension SidebarRow {
    /// The small "2 agents" chip of a working row with live sub-agents: a press on it opens that
    /// chat's peek in the Agents board, a press on the rest of the row still opens the chat. It
    /// leaves the keyboard to the Agents card, sits beside the model rather than at the trailing
    /// edge where the row's hover verbs float, and gives way to an ellipsis before it can widen a
    /// narrow sidebar.
    static func agentsChip(
        _ model: SessionRowModel, onOpen: @escaping @Sendable () -> Void
    ) -> UnsafeMutablePointer<GtkWidget>? {
        let count = model.entry.session.activeAgents ?? 0
        guard count > 0, model.state == .live || model.state == .awaitingApproval else { return nil }
        let words = AgentsReading.agentsWords(count)
        let button = gtk_button_new()!
        Gtk.addClass(button, "flat")
        Gtk.addClass(button, "row-agents")
        let label = Gtk.label(words, css: "row-agents-label", selectable: false)
        gtk_label_set_ellipsize(op(label), PANGO_ELLIPSIZE_END)
        gtk_label_set_width_chars(op(label), 5)
        gtk_button_set_child(ptr(button), label)
        gtk_widget_set_valign(button, GTK_ALIGN_CENTER)
        gtk_widget_set_tooltip_text(button, Localized.text("What this chat's agents are doing"))
        tailscode_set_accessible_label(
            button, words + ", " + Localized.text("What this chat's agents are doing"))
        Gtk.onClaimedClick(button, onOpen)
        Gtk.connect(UnsafeMutableRawPointer(button), "clicked", onOpen)
        return button
    }
}
