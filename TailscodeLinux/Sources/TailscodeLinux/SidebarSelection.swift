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
    /// The verbs a whole selection is worth: the one that reaches the server, and the three that
    /// only change what this device remembers.
    static let offered: [BulkChatAction] = [.delete, .archive, .save, .markRead]

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
        gtk_widget_set_tooltip_text(clear, Localized.text("esc clears the marks"))
        gtk_box_append(ptr(headline), clear)
        gtk_box_append(ptr(column), headline)

        for action in offered where action.isDestructive {
            gtk_box_append(ptr(column), verb(action, count: count, onAction: onAction))
        }
        let rest = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
        gtk_box_set_homogeneous(ptr(rest), 1)
        for action in offered where !action.isDestructive {
            let button = verb(action, count: count, onAction: onAction)
            gtk_widget_set_hexpand(button, 1)
            gtk_box_append(ptr(rest), button)
        }
        gtk_box_append(ptr(column), rest)

        let arrangements = SplitEven.offers(count: count)
        if !arrangements.isEmpty {
            let header = Gtk.label(
                SplitEven.header(count: count), css: "selection-split-header", selectable: false)
            gtk_label_set_xalign(op(header), 0)
            Gtk.margins(header, top: 4)
            gtk_box_append(ptr(column), header)
            let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
            gtk_box_set_homogeneous(ptr(row), 1)
            for arrangement in arrangements {
                let button = Gtk.button(
                    "\(arrangement.glyph) \(arrangement.title)", css: ["flat", "selection-verb"]
                ) { onSplit(arrangement) }
                gtk_widget_set_tooltip_text(button, arrangement.caption(count: count))
                tailscode_set_accessible_label(button, arrangement.accessibleLabel(count: count))
                gtk_widget_set_hexpand(button, 1)
                gtk_box_append(ptr(row), button)
            }
            gtk_box_append(ptr(column), row)
        }
        return column
    }

    private static func verb(
        _ action: BulkChatAction, count: Int,
        onAction: @escaping @Sendable (BulkChatAction) -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let css = action.isDestructive ? ["destructive-action"] : ["flat", "selection-verb"]
        let button = Gtk.button(BulkChatCopy.button(action, count: count), css: css) {
            onAction(action)
        }
        gtk_widget_set_tooltip_text(button, BulkChatCopy.confirm(action, count: count))
        return button
    }
}
