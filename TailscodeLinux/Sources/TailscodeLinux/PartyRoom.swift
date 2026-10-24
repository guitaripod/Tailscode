import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// Putting a model in the party: the first hollow slot takes it, and with six held the six are
/// shown and the person says which one makes room.
enum PartyRoom {
    /// Offers `preset` to the party. `anchor` is a widget that outlives the question; `told` hears
    /// what happened, in words.
    static func offer(
        _ preset: ModelPreset, on anchor: UnsafeMutablePointer<GtkWidget>, inputs: PartyInputs,
        told: @escaping @Sendable (String) -> Void
    ) {
        switch PartyEdits.place(preset) {
        case .placed(let slot):
            told(Localized.text("Added to slot %d", slot + 1))
        case .full:
            ask(on: anchor, inputs: inputs) { slot in
                PartyEdits.replace(slot, with: preset)
                told(Localized.text("Added to slot %d", slot + 1))
            }
        }
    }

    /// The six cards under the question, one press answering it.
    static func ask(
        on anchor: UnsafeMutablePointer<GtkWidget>, inputs: PartyInputs,
        answered: @escaping @Sendable (Int) -> Void
    ) {
        let popover = gtk_popover_new()!
        Gtk.addClass(popover, "party-pop")
        gtk_widget_set_parent(popover, anchor)
        gtk_popover_set_position(ptr(popover), GTK_POS_BOTTOM)
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_widget_set_size_request(column, PartyPopover.width, -1)
        let question = Gtk.label(
            Localized.text("Which one makes room?"), css: "party-head", selectable: false)
        Gtk.margins(question, top: 14, bottom: 6, leading: 12, trailing: 14)
        gtk_box_append(ptr(column), question)
        let actions = PartyActions()
        let grid = PartyGridView(actions: actions)
        gtk_widget_set_margin_start(grid.widget, 4)
        gtk_widget_set_margin_end(grid.widget, 14)
        gtk_widget_set_margin_bottom(grid.widget, 10)
        gtk_box_append(ptr(column), grid.widget)
        gtk_popover_set_child(ptr(popover), column)
        grid.apply(inputs.cards, editing: false)
        let hold = Gtk.WeakWidget(popover)
        actions.activate = { slot in
            if let held = hold.widget { gtk_popover_popdown(ptr(held)) }
            answered(slot)
        }
        actions.replace = actions.activate
        Gtk.connect(UnsafeMutableRawPointer(popover), "closed") {
            Gtk.onMain {
                withExtendedLifetime(grid) {
                    guard let held = hold.widget, gtk_widget_get_parent(held) != nil else { return }
                    gtk_widget_unparent(held)
                }
            }
        }
        gtk_popover_popup(ptr(popover))
    }
}
