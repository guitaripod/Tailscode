import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// The list a slash opens, drawn once for every composer the app has.
///
/// A chat's prompt box and the quick ask are the same box, so what pops up over them has to be the
/// same widget rather than two painters that drift apart the first time one of them learns
/// something. It paints and it walks; it decides nothing — what to show is `SlashPresentation`'s,
/// and a pick is handed back rather than acted on, because a chat can run a command on the spot and
/// a quick ask has no conversation to run it in yet.
final class SlashPopover: @unchecked Sendable {
    private let anchor: UnsafeMutablePointer<GtkWidget>
    private var popover: UnsafeMutablePointer<GtkWidget>?
    private var ranked: [SlashMatch] = []
    private(set) var cursor = 0

    /// Whether the composer this list belongs to is inside a project. A quick ask is not, and a
    /// word the catalog lacks for that reason is a different fact from a word nothing would resolve.
    var hasProject = true
    /// How many commands the surface could offer at all — what the no-match row invites somebody to
    /// go and read. Nothing to browse hides the invitation.
    var catalogSize = 0
    var onPick: ((AgentCommand) -> Void)?
    var onBrowse: (() -> Void)?

    init(anchor: UnsafeMutablePointer<GtkWidget>) {
        self.anchor = anchor
    }

    var isShown: Bool { popover.map { gtk_widget_get_visible($0) != 0 } ?? false }

    var matches: [AgentCommand] { ranked.map(\.command) }

    var selected: AgentCommand? {
        ranked.indices.contains(cursor) ? ranked[cursor].command : nil
    }

    func move(by delta: Int) {
        let count = ranked.count
        guard count > 0 else { return }
        cursor = ((cursor + delta) % count + count) % count
        paint(.naming(matches: ranked))
    }

    func dismiss() {
        guard let popover, gtk_widget_get_visible(popover) != 0 else { return }
        gtk_popover_popdown(ptr(popover))
    }

    /// The widget is parented on the anchor rather than owned by it, so a surface that is destroyed
    /// — the quick ask is, every time it closes — has to hand it back itself.
    func tearDown() {
        guard let popover else { return }
        gtk_popover_popdown(ptr(popover))
        gtk_widget_unparent(popover)
        self.popover = nil
        ranked = []
        cursor = 0
    }

    /// Argument stage, hints and no-match live here with the naming list — the greppable anchor for
    /// slashCompletion on Linux.
    ///
    /// - Parameter cursor: where the walk was, so a keystroke that shortens the list moves the
    ///   selection no further than it has to rather than throwing it back to the top.
    func renderCompletion(_ presentation: SlashPresentation, cursor: Int) {
        switch presentation {
        case .naming(let matches):
            ranked = matches
            self.cursor = max(0, min(cursor, matches.count - 1))
        case .hidden, .arguments, .noMatch:
            ranked = []
            self.cursor = 0
        }
        paint(presentation)
    }

    private func paint(_ presentation: SlashPresentation) {
        guard presentation.isVisible else {
            dismiss()
            return
        }
        let popover = self.popover ?? make()
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        switch presentation {
        case .hidden:
            break
        case .naming(let matches):
            let start = max(0, min(cursor - 3, matches.count - 8))
            let end = min(matches.count, start + 8)
            for index in start..<end {
                let command = matches[index].command
                gtk_box_append(
                    ptr(column),
                    button(
                        title: "/\(command.name)",
                        detail: [command.argumentHint, command.details, command.scope]
                            .compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · "),
                        selected: index == cursor
                    ) { [weak self] in
                        Gtk.onMain { [weak self] in self?.onPick?(command) }
                    })
            }
            if start > 0 || end < matches.count {
                let hidden = matches.count - (end - start)
                gtk_box_append(
                    ptr(column),
                    Gtk.label("… \(hidden) more", css: "row-detail", selectable: false))
            }
        case .arguments(let command, let typed):
            gtk_box_append(
                ptr(column), Gtk.label("/\(command.name)", css: "row-title", selectable: false))
            if let hint = command.argumentHint, !hint.isEmpty {
                gtk_box_append(ptr(column), Gtk.label(hint, css: "row-title", selectable: false))
            }
            if !command.details.isEmpty {
                gtk_box_append(
                    ptr(column), Gtk.label(command.details, css: "row-detail", selectable: false))
            }
            if !typed.isEmpty {
                gtk_box_append(
                    ptr(column),
                    Gtk.label(
                        Localized.text("Writing: %@", typed), css: "row-detail", selectable: false))
            }
        case .noMatch(let query):
            gtk_box_append(
                ptr(column),
                Gtk.label(
                    SlashPresentation.noMatchWording(query, hasProject: hasProject),
                    css: "row-detail", selectable: false))
            if catalogSize > 0, onBrowse != nil {
                gtk_box_append(
                    ptr(column),
                    button(
                        title: Localized.text("Browse every command"),
                        detail: Localized.text("%@ on this server", "\(catalogSize)"),
                        selected: false
                    ) { [weak self] in
                        Gtk.onMain { [weak self] in self?.onBrowse?() }
                    })
            }
        }
        gtk_popover_set_child(ptr(popover), column)
        gtk_popover_popup(ptr(popover))
    }

    /// It never takes focus and it never hides itself on a click elsewhere: it is a suggestion over
    /// a box somebody is still typing into, not a dialog.
    private func make() -> UnsafeMutablePointer<GtkWidget> {
        let popover = gtk_popover_new()!
        gtk_widget_set_parent(popover, anchor)
        gtk_popover_set_autohide(ptr(popover), 0)
        gtk_popover_set_has_arrow(ptr(popover), 0)
        gtk_popover_set_position(ptr(popover), GTK_POS_TOP)
        self.popover = popover
        return popover
    }

    private func button(
        title: String, detail: String, selected: Bool, action: @escaping @Sendable () -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let item = gtk_button_new()!
        Gtk.addClass(item, "flat")
        if selected { Gtk.addClass(item, "completion-selected") }
        let lines = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_box_append(ptr(lines), Gtk.label(title, css: "row-title", selectable: false))
        if !detail.isEmpty {
            let label = Gtk.label(detail, css: "row-detail", selectable: false)
            gtk_label_set_max_width_chars(op(label), 64)
            gtk_box_append(ptr(lines), label)
        }
        gtk_button_set_child(ptr(item), lines)
        Gtk.connect(UnsafeMutableRawPointer(item), "clicked", action)
        return item
    }
}
