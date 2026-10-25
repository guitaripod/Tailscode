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
        floor: Double = 0, told: @escaping @Sendable (String) -> Void
    ) {
        switch PartyEdits.place(preset) {
        case .placed(let slot):
            told(Localized.text("Added to slot %d", slot + 1))
        case .full:
            ask(on: anchor, inputs: inputs, floor: floor) { slot in
                PartyEdits.replace(slot, with: preset)
                told(Localized.text("Added to slot %d", slot + 1))
            }
        }
    }

    /// The six cards under the question, one press answering it.
    static func ask(
        on anchor: UnsafeMutablePointer<GtkWidget>, inputs: PartyInputs, floor: Double = 0,
        answered: @escaping @Sendable (Int) -> Void
    ) {
        let popover = gtk_popover_new()!
        Gtk.addClass(popover, "party-pop")
        gtk_widget_set_parent(popover, anchor)
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
        let scroll = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(op(scroll), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_propagate_natural_height(op(scroll), 1)
        gtk_scrolled_window_set_child(op(scroll), column)
        gtk_popover_set_child(ptr(popover), scroll)
        grid.apply(inputs.cards, editing: false)
        place(popover, scroll: scroll, column: column, on: anchor, floor: floor)
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

    /// How much of the window the question may take, so it is never cut by an edge: below the
    /// anchor when the six cards fit there, above it when they fit there, and otherwise over the
    /// anchor's own top, which is what a chooser as tall as its window leaves. What still does
    /// not fit scrolls rather than runs off the window. `floor` is the least height it may be given
    /// by a window too small to hold it, whose popover then hangs past the window's edge.
    private static func place(
        _ popover: UnsafeMutablePointer<GtkWidget>, scroll: UnsafeMutablePointer<GtkWidget>,
        column: UnsafeMutablePointer<GtkWidget>, on anchor: UnsafeMutablePointer<GtkWidget>,
        floor: Double
    ) {
        gtk_popover_set_position(ptr(popover), GTK_POS_BOTTOM)
        guard let root = gtk_widget_get_root(anchor) else { return }
        let window = UnsafeMutableRawPointer(root).assumingMemoryBound(to: GtkWidget.self)
        let height = Double(gtk_widget_get_height(window))
        var least: Int32 = 0
        var natural: Int32 = 0
        var ignoredA: Int32 = 0
        var ignoredB: Int32 = 0
        gtk_widget_measure(
            column, GTK_ORIENTATION_VERTICAL, PartyPopover.width, &least, &natural, &ignoredA,
            &ignoredB)
        let needed = Double(natural) + edgeMargin
        guard let box = Gtk.bounds(of: anchor, in: window) else {
            limit(scroll, to: max(height - edgeMargin, floor))
            return
        }
        let below = height - (box.y + box.height)
        let above = box.y
        if below >= needed {
            limit(scroll, to: max(below - edgeMargin, floor))
        } else if above >= needed {
            gtk_popover_set_position(ptr(popover), GTK_POS_TOP)
            limit(scroll, to: max(above - edgeMargin, floor))
        } else {
            var point = GdkRectangle(x: gint(box.width / 2), y: 6, width: 1, height: 1)
            gtk_popover_set_pointing_to(ptr(popover), &point)
            limit(scroll, to: max(height - (box.y + 6) - edgeMargin, floor))
        }
    }

    private static func limit(_ scroll: UnsafeMutablePointer<GtkWidget>, to room: Double) {
        gtk_scrolled_window_set_max_content_height(op(scroll), gint(max(160, room)))
    }

    /// The arrow, the shadow and a breath between the question and the window's edge.
    private static let edgeMargin = 24.0
}
