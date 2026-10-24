import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The six cards, three across and two down, held in one grid whose cells are the same size
/// however long a name is, so the shape never moves under the pointer.
final class PartyGridView: @unchecked Sendable {
    static let columns: Int32 = 3
    let widget: UnsafeMutablePointer<GtkWidget>
    let views: [PartyCardView]

    init(actions: PartyActions) {
        widget = gtk_grid_new()!
        Gtk.addClass(widget, "party-grid")
        gtk_grid_set_row_homogeneous(ptr(widget), 1)
        gtk_grid_set_column_homogeneous(ptr(widget), 1)
        views = (0..<ModelParty.size).map { PartyCardView(slot: $0, actions: actions) }
        for view in views {
            gtk_grid_attach(
                ptr(widget), view.cell, Int32(view.slot) % Self.columns,
                Int32(view.slot) / Self.columns, 1, 1)
        }
    }

    func apply(_ cards: [PartyCard], editing: Bool) {
        for (view, card) in zip(views, cards) { view.apply(card, editing: editing) }
    }

    func commitAll() {
        for view in views { view.commit(settling: false) }
    }

    /// The card that holds the keyboard focus, if one does.
    var focused: PartyCardView? {
        guard let widget = tailscode_focused_widget(widget) else { return nil }
        return views.first { gtk_widget_is_ancestor(widget, $0.cell) != 0 }
    }

    /// The card whose entry has the focus: the one the Delete key must leave alone.
    var focusIsInName: Bool {
        guard let focus = tailscode_focused_widget(widget) else { return false }
        return views.contains { view in
            view.entry.map { gtk_widget_is_ancestor(focus, $0) != 0 || focus == $0 } ?? false
        }
    }
}
