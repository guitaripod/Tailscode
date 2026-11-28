import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The band the chat list wears while chats are marked: what the gesture is holding, and the verbs
/// it can be spent on.
///
/// Every sentence comes from `BulkChatCopy`, so the number in "Delete 4" is phrased the same way
/// here as it is in the confirm dialog and on the other two clients. The destructive verb stands
/// alone on its own line and is the only thing on the band wearing a colour — an archive sitting
/// shoulder to shoulder with a delete is how the wrong one gets clicked.
enum SidebarSelectionBar {
    /// The verbs a whole selection is worth: the two that ask each chat's agent something, the one
    /// that removes from the server, and the three that only change what this device remembers.
    static let offered: [BulkChatAction] = [.resume, .status, .delete, .archive, .save, .markRead]

    static func make(
        count: Int,
        onClear: @escaping @Sendable () -> Void,
        onAction: @escaping @Sendable (BulkChatAction) -> Void,
        onSplit: @escaping @Sendable (SplitArrangement) -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
        Gtk.addClass(column, "selection-bar")
        Gtk.margins(column, top: 8, bottom: 8, leading: 8, trailing: 8)

        let headline = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        let title = Gtk.label(
            Localized.text("%@ marked", "\(count)"), css: "selection-count", selectable: false)
        gtk_widget_set_hexpand(title, 1)
        gtk_box_append(ptr(headline), title)
        let clear = Gtk.button(Localized.text("Clear"), css: ["flat", "dim"], onClick: onClear)
        Tip.set(clear, Localized.text("esc clears the marks"))
        gtk_box_append(ptr(headline), clear)
        gtk_box_append(ptr(column), headline)

        let nudges = offered.filter { $0.nudge != nil }
        let asks = reflowing(columns: nudges.count)
        for action in nudges {
            gtk_flow_box_append(op(asks), verb(action, count: count, onAction: onAction))
        }
        gtk_box_append(ptr(column), asks)

        for action in offered where action.isDestructive {
            gtk_box_append(ptr(column), verb(action, count: count, onAction: onAction))
        }
        let verbs = offered.filter { !$0.isDestructive && $0.nudge == nil }
        let rest = reflowing(columns: verbs.count)
        for action in verbs {
            gtk_flow_box_append(op(rest), verb(action, count: count, onAction: onAction))
        }
        gtk_box_append(ptr(column), rest)

        let arrangements = SplitEven.offers(count: count)
        if !arrangements.isEmpty {
            let header = Gtk.label(
                SplitEven.header(count: count), css: "selection-split-header", selectable: false)
            gtk_label_set_xalign(op(header), 0)
            Gtk.margins(header, top: 4)
            gtk_box_append(ptr(column), header)
            let row = reflowing(columns: arrangements.count)
            for arrangement in arrangements {
                let button = Gtk.button(
                    "\(arrangement.glyph) \(arrangement.title)", css: ["flat", "selection-verb"]
                ) { onSplit(arrangement) }
                Tip.set(button, arrangement.caption(count: count))
                tailscode_set_accessible_label(button, arrangement.accessibleLabel(count: count))
                gtk_flow_box_append(op(row), button)
            }
            gtk_box_append(ptr(column), row)
        }
        return column
    }

    /// A row of equal buttons that folds onto further lines when the list is narrower than the
    /// row, rather than holding the list open at the width of every button laid side by side.
    private static func reflowing(columns: Int) -> UnsafeMutablePointer<GtkWidget> {
        let flow = gtk_flow_box_new()!
        gtk_flow_box_set_selection_mode(op(flow), GTK_SELECTION_NONE)
        gtk_flow_box_set_homogeneous(op(flow), 1)
        gtk_flow_box_set_min_children_per_line(op(flow), 1)
        gtk_flow_box_set_max_children_per_line(op(flow), UInt32(max(columns, 1)))
        gtk_flow_box_set_column_spacing(op(flow), 6)
        gtk_flow_box_set_row_spacing(op(flow), 6)
        Gtk.addClass(flow, "selection-flow")
        return flow
    }

    private static func verb(
        _ action: BulkChatAction, count: Int,
        onAction: @escaping @Sendable (BulkChatAction) -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let css = action.isDestructive ? ["destructive-action"] : ["flat", "selection-verb"]
        let button = Gtk.button(BulkChatCopy.button(action, count: count), css: css) {
            onAction(action)
        }
        Tip.set(
            button, action.nudge?.hint ?? BulkChatCopy.confirm(action, count: count))
        tailscode_set_accessible_label(button, BulkChatCopy.button(action, count: count))
        return button
    }
}
