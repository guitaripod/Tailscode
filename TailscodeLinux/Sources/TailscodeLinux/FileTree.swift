import CAdw
import CodingAgentKit
import Foundation
import TailscodeCore

/// The project the conversation is working in, browsable.
///
/// The files come from the server, not from this machine — the agent's working directory is on
/// whichever box runs the bridge, and a desktop client that browsed its own disk would be showing
/// the wrong tree. Selecting a file drops its path into the composer, which is how a prompt names
/// something without anyone typing it out.
final class FileTree: @unchecked Sendable {
    let widget = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    var onOpen: ((String) -> Void)?

    private let pathLabel = Gtk.label("", css: "tree-path", selectable: false)
    private let list = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    private var backend: (any FileBrowsingBackend)?
    private var root: String?
    private var current: String?
    private var loadTask: Task<Void, Never>?

    init() {
        Gtk.addClass(widget, "canvas")
        Gtk.margins(pathLabel, top: 6, bottom: 4, leading: 10, trailing: 10)
        gtk_box_append(ptr(widget), pathLabel)

        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(op(scroller), GTK_POLICY_AUTOMATIC, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_child(op(scroller), list)
        gtk_widget_set_vexpand(scroller, 1)
        gtk_box_append(ptr(widget), scroller)
    }

    func show(directory: String?, on backend: any CodingAgentBackend) {
        guard let browsing = backend as? any FileBrowsingBackend else {
            render(entries: [], message: Localized.text("This server has no file browser."))
            return
        }
        self.backend = browsing
        root = directory
        load(directory)
    }

    private func load(_ path: String?) {
        current = path
        gtk_label_set_text(op(pathLabel), path ?? "~")
        loadTask?.cancel()
        guard let backend else { return }
        loadTask = Task { [weak self] in
            let listing = (try? await backend.listFiles(path: path)) ?? []
            guard !Task.isCancelled else { return }
            Gtk.onMain { [weak self] in
                self?.render(
                    entries: listing,
                    message: listing.isEmpty ? Localized.text("Empty folder.") : nil)
            }
        }
    }

    private func render(entries: [FileNode], message: String?) {
        Gtk.removeChildren(of: list)
        if let message {
            let label = Gtk.label(message, css: "dim", selectable: false)
            Gtk.margins(label, top: 8, bottom: 8, leading: 12, trailing: 12)
            gtk_box_append(ptr(list), label)
            return
        }
        if current != root, current != nil {
            gtk_box_append(ptr(list), makeRow(name: "..", isDirectory: true, path: parentOfCurrent()))
        }
        for entry in entries.sorted(by: Self.folderFirst) {
            gtk_box_append(
                ptr(list),
                makeRow(name: entry.name, isDirectory: entry.isDirectory, path: entry.path))
        }
    }

    private static func folderFirst(_ a: FileNode, _ b: FileNode) -> Bool {
        if a.isDirectory != b.isDirectory { return a.isDirectory }
        return a.name.lowercased() < b.name.lowercased()
    }

    private func parentOfCurrent() -> String {
        guard let current else { return root ?? "" }
        return URL(fileURLWithPath: current).deletingLastPathComponent().path
    }

    private func makeRow(name: String, isDirectory: Bool, path: String)
        -> UnsafeMutablePointer<GtkWidget>
    {
        let button = gtk_button_new()!
        Gtk.addClass(button, "flat")
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        Gtk.margins(row, top: 1, bottom: 1, leading: 4, trailing: 4)
        let glyph = Gtk.label(isDirectory ? "▸" : " ", css: "tree-dir", selectable: false)
        let label = Gtk.label(name, css: isDirectory ? "tree-dir" : "tree-row", selectable: false)
        gtk_widget_set_hexpand(label, 1)
        gtk_box_append(ptr(row), glyph)
        gtk_box_append(ptr(row), label)
        gtk_button_set_child(ptr(button), row)
        Gtk.connect(UnsafeMutableRawPointer(button), "clicked") { [weak self] in
            if isDirectory {
                self?.load(path)
            } else {
                self?.onOpen?(path)
            }
        }
        return button
    }
}
