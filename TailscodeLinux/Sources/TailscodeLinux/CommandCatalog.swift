import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// Every command this server offers, on one browsable surface. The completion popover is for
/// speed; this is for discovery — grouped by source, searchable through the shared ranking.
enum CommandCatalog {
    static func present(
        parent: UnsafeMutablePointer<GtkWidget>?,
        commands: [AgentCommand],
        onPick: @escaping @Sendable (AgentCommand) -> Void
    ) {
        let (window, content) = Dialogs.window(
            title: Localized.text("Commands"), parent: parent, width: 520)
        gtk_window_set_default_size(ptr(window), 520, 600)

        let search = gtk_entry_new()!
        gtk_entry_set_placeholder_text(
            ptr(search),
            Localized.text("Search %@ commands", "\(commands.count)"))
        gtk_box_append(ptr(content), search)

        let list = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 4)
        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(op(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_max_content_height(op(scroller), 480)
        gtk_scrolled_window_set_propagate_natural_height(op(scroller), 1)
        gtk_scrolled_window_set_child(op(scroller), list)
        gtk_widget_set_vexpand(scroller, 1)
        gtk_box_append(ptr(content), scroller)

        let listBits = UInt(bitPattern: list)
        let searchBits = UInt(bitPattern: search)
        let windowBits = UInt(bitPattern: window)
        let commandsCopy = commands

        let rebuild: @Sendable () -> Void = {
            guard let listRaw = UnsafeMutableRawPointer(bitPattern: listBits),
                let searchRaw = UnsafeMutableRawPointer(bitPattern: searchBits)
            else { return }
            let listWidget: UnsafeMutablePointer<GtkWidget> = ptr(listRaw)
            let searchWidget: UnsafeMutablePointer<GtkWidget> = ptr(searchRaw)
            Gtk.removeChildren(of: listWidget)
            let query = Dialogs.entryText(searchWidget)
            let sections = CommandCatalogGrouping.sections(commands: commandsCopy, query: query)
            if sections.isEmpty {
                gtk_box_append(
                    ptr(listWidget),
                    Gtk.label(
                        query.isEmpty
                            ? Localized.text("No commands")
                            : Localized.text("No matches"),
                        css: "dim", selectable: false))
                return
            }
            for section in sections {
                gtk_box_append(
                    ptr(listWidget),
                    Gtk.label(
                        "\(section.title.uppercased())  ·  \(section.commands.count)",
                        css: "section-header", selectable: false))
                for command in section.commands {
                    let button = gtk_button_new()!
                    Gtk.addClass(button, "flat")
                    let lines = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
                    let title =
                        command.argumentHint.map { "/\(command.name) \($0)" }
                        ?? "/\(command.name)"
                    gtk_box_append(
                        ptr(lines), Gtk.label(title, css: "row-title", selectable: false))
                    let detailParts = [command.details, command.scope]
                        .compactMap { $0?.isEmpty == false ? $0 : nil }
                    if !detailParts.isEmpty {
                        let detail = Gtk.label(
                            detailParts.joined(separator: " · "), css: "row-detail",
                            selectable: false)
                        gtk_label_set_max_width_chars(op(detail), 72)
                        gtk_box_append(ptr(lines), detail)
                    }
                    gtk_button_set_child(ptr(button), lines)
                    let picked = command
                    Gtk.connect(UnsafeMutableRawPointer(button), "clicked") {
                        onPick(picked)
                        Gtk.onMain {
                            if let raw = UnsafeMutableRawPointer(bitPattern: windowBits) {
                                Dialogs.close(ptr(raw))
                            }
                        }
                    }
                    gtk_box_append(ptr(listWidget), button)
                }
            }
        }

        Gtk.connect(UnsafeMutableRawPointer(search), "changed") {
            Gtk.onMain { rebuild() }
        }
        rebuild()
        gtk_window_present(ptr(window))
        gtk_widget_grab_focus(search)
    }
}
