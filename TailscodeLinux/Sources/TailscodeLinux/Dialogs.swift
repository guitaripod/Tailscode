import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// Modal windows built from plain widgets rather than AdwAlertDialog: the alert API answers
/// through a GAsyncResult callback whose shape the shim would have to marshal, and a window the
/// app owns can hold live state — a probe in flight, a failure named in place — which is exactly
/// what the server form needs.
enum Dialogs {
    static func window(
        title: String, parent: UnsafeMutablePointer<GtkWidget>?, width: Int32 = 460
    ) -> (window: UnsafeMutablePointer<GtkWidget>, content: UnsafeMutablePointer<GtkWidget>) {
        let window = gtk_window_new()!
        gtk_window_set_title(ptr(window), title)
        gtk_window_set_modal(ptr(window), 1)
        gtk_window_set_default_size(ptr(window), width, -1)
        if let parent, let root = gtk_widget_get_root(parent) {
            gtk_window_set_transient_for(ptr(window), ptr(UnsafeMutableRawPointer(root)))
        }
        let content = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 12)
        Gtk.margins(content, 18)
        gtk_window_set_child(ptr(window), content)
        return (window, content)
    }

    static func close(_ widget: UnsafeMutablePointer<GtkWidget>) {
        if let root = gtk_widget_get_root(widget) {
            gtk_window_destroy(ptr(UnsafeMutableRawPointer(root)))
        }
    }

    static func entryText(_ entry: UnsafeMutablePointer<GtkWidget>) -> String {
        guard let raw = gtk_editable_get_text(op(entry)) else { return "" }
        return String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// One line of text in, two buttons out. Serves rename and every prompt like it.
    static func prompt(
        title: String, body: String?, placeholder: String, initial: String = "",
        confirmLabel: String, parent: UnsafeMutablePointer<GtkWidget>?,
        onConfirm: @escaping @Sendable (String) -> Void
    ) {
        let (window, content) = Self.window(title: title, parent: parent)
        if let body {
            gtk_box_append(ptr(content), Gtk.label(body, css: "row-detail", wrap: true))
        }
        let entry = gtk_entry_new()!
        gtk_entry_set_placeholder_text(ptr(entry), placeholder)
        gtk_editable_set_text(op(entry), initial)
        gtk_box_append(ptr(content), entry)

        let entryBits = UInt(bitPattern: entry)
        let confirm: @Sendable () -> Void = {
            guard let raw = UnsafeMutableRawPointer(bitPattern: entryBits) else { return }
            let entry: UnsafeMutablePointer<GtkWidget> = ptr(raw)
            let text = entryText(entry)
            close(entry)
            onConfirm(text)
        }
        Gtk.connect(UnsafeMutableRawPointer(entry), "activate", confirm)
        gtk_box_append(
            ptr(content),
            buttonRow(
                window: window,
                confirm: Gtk.button(confirmLabel, css: ["suggested-action"], onClick: confirm)))
        gtk_window_present(ptr(window))
    }

    /// A destructive action states what it destroys and waits for the second click.
    static func confirm(
        title: String, body: String, confirmLabel: String, destructive: Bool = true,
        parent: UnsafeMutablePointer<GtkWidget>?,
        onConfirm: @escaping @Sendable () -> Void
    ) {
        let (window, content) = Self.window(title: title, parent: parent)
        gtk_box_append(ptr(content), Gtk.label(body, css: "agent-text", wrap: true))
        let windowBits = UInt(bitPattern: window)
        gtk_box_append(
            ptr(content),
            buttonRow(
                window: window,
                confirm: Gtk.button(
                    confirmLabel, css: [destructive ? "destructive-action" : "suggested-action"]
                ) {
                    if let raw = UnsafeMutableRawPointer(bitPattern: windowBits) {
                        gtk_window_destroy(ptr(raw))
                    }
                    onConfirm()
                }))
        gtk_window_present(ptr(window))
    }

    /// Long machine-facing prose — a compaction summary, a tool's full output — reads in a window
    /// of its own: selectable, scrollable, copyable, never squeezed into a few hundred pixels of
    /// the conversation's flow.
    static func reader(
        title: String, subtitle: String? = nil, body: String, mono: Bool = false,
        parent: UnsafeMutablePointer<GtkWidget>?
    ) {
        let window = gtk_window_new()!
        gtk_window_set_title(ptr(window), title)
        gtk_window_set_modal(ptr(window), 1)
        gtk_window_set_default_size(ptr(window), 760, 600)
        if let parent, let root = gtk_widget_get_root(parent) {
            gtk_window_set_transient_for(ptr(window), ptr(UnsafeMutableRawPointer(root)))
        }

        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        Gtk.addClass(column, "canvas")
        if let subtitle {
            let header = Gtk.label(subtitle, css: "seam-text", selectable: false)
            gtk_widget_set_halign(header, GTK_ALIGN_START)
            Gtk.margins(header, top: 12, bottom: 10, leading: 18, trailing: 18)
            gtk_box_append(ptr(column), header)
            gtk_box_append(ptr(column), Gtk.hairline())
        }

        let view = gtk_text_view_new()!
        gtk_text_view_set_editable(ptr(UnsafeMutableRawPointer(view)), 0)
        gtk_text_view_set_cursor_visible(ptr(UnsafeMutableRawPointer(view)), 0)
        gtk_text_view_set_wrap_mode(ptr(UnsafeMutableRawPointer(view)), GTK_WRAP_WORD_CHAR)
        gtk_text_view_set_left_margin(ptr(UnsafeMutableRawPointer(view)), 18)
        gtk_text_view_set_right_margin(ptr(UnsafeMutableRawPointer(view)), 18)
        gtk_text_view_set_top_margin(ptr(UnsafeMutableRawPointer(view)), 14)
        gtk_text_view_set_bottom_margin(ptr(UnsafeMutableRawPointer(view)), 14)
        Gtk.addClass(view, mono ? "reader-mono" : "reader-body")
        if let buffer = gtk_text_view_get_buffer(ptr(UnsafeMutableRawPointer(view))) {
            gtk_text_buffer_set_text(buffer, body, -1)
        }
        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(op(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_widget_set_vexpand(scroller, 1)
        gtk_scrolled_window_set_child(op(scroller), view)
        gtk_box_append(ptr(column), scroller)

        gtk_box_append(ptr(column), Gtk.hairline())
        let actions = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_widget_set_halign(actions, GTK_ALIGN_END)
        Gtk.margins(actions, top: 10, bottom: 12, leading: 18, trailing: 18)
        gtk_box_append(
            ptr(actions),
            Gtk.button(Localized.text("Copy")) { Gtk.copyToClipboard(body) })
        let windowBits = UInt(bitPattern: window)
        gtk_box_append(
            ptr(actions),
            Gtk.button(Localized.text("Close"), css: ["suggested-action"]) {
                guard let raw = UnsafeMutableRawPointer(bitPattern: windowBits) else { return }
                gtk_window_destroy(ptr(raw))
            })
        gtk_box_append(ptr(column), actions)

        gtk_window_set_child(ptr(window), column)
        gtk_window_present(ptr(window))
    }

    /// `/compact` never fires bare: it is irreversible, takes minutes, and accepts an instruction
    /// for what the summary must keep — so the preflight says all three.
    static func compactPreflight(
        parent: UnsafeMutablePointer<GtkWidget>?, initialInstruction: String = "",
        onCompact: @escaping @Sendable (String?) -> Void
    ) {
        let (window, content) = Self.window(
            title: Localized.text("Compact this conversation?"), parent: parent, width: 520)
        gtk_box_append(
            ptr(content),
            Gtk.label(
                Localized.text(
                    "The transcript so far is replaced by a summary. This is irreversible, takes minutes, and the agent works from the summary afterwards."),
                css: "agent-text", wrap: true))
        let entry = gtk_entry_new()!
        gtk_entry_set_placeholder_text(
            ptr(entry), Localized.text("What must the summary keep? (optional)"))
        gtk_editable_set_text(op(entry), initialInstruction)
        gtk_box_append(ptr(content), entry)

        let entryBits = UInt(bitPattern: entry)
        gtk_box_append(
            ptr(content),
            buttonRow(
                window: window,
                confirm: Gtk.button(Localized.text("Compact"), css: ["destructive-action"]) {
                    guard let raw = UnsafeMutableRawPointer(bitPattern: entryBits) else { return }
                    let entry: UnsafeMutablePointer<GtkWidget> = ptr(raw)
                    let instruction = entryText(entry)
                    close(entry)
                    onCompact(instruction.isEmpty ? nil : instruction)
                }))
        gtk_window_present(ptr(window))
    }

    /// A new conversation needs a server and a directory; everything else the agent works out.
    static func newChat(
        parent: UnsafeMutablePointer<GtkWidget>?,
        profiles: [ConnectionProfile],
        recentDirectories: [String],
        onCreate: @escaping @Sendable (ConnectionProfile, String?) -> Void
    ) {
        guard !profiles.isEmpty else { return }
        let (window, content) = Self.window(
            title: Localized.text("New conversation"), parent: parent, width: 520)

        let chosen = Selection<ConnectionProfile>(profiles[0])
        if profiles.count > 1 {
            gtk_box_append(
                ptr(content), Gtk.label(Localized.text("SERVER"), css: "section-header", selectable: false))
            let serverButton = Gtk.menuButton(profiles[0].name) {
                profiles.map { profile in
                    (profile.name, profile.baseURL.absoluteString, { chosen.value = profile })
                }
            }
            gtk_box_append(ptr(content), serverButton)
        }

        gtk_box_append(
            ptr(content),
            Gtk.label(Localized.text("DIRECTORY"), css: "section-header", selectable: false))
        let entry = gtk_entry_new()!
        gtk_entry_set_placeholder_text(
            ptr(entry), Localized.text("Where the agent works, e.g. ~/Dev/thing"))
        if let first = recentDirectories.first { gtk_editable_set_text(op(entry), first) }
        gtk_box_append(ptr(content), entry)
        for directory in recentDirectories.prefix(6) {
            let entryBits = UInt(bitPattern: entry)
            let row = Gtk.button(directory, css: ["flat", "answer-option"]) {
                guard let raw = UnsafeMutableRawPointer(bitPattern: entryBits) else { return }
                gtk_editable_set_text(op(raw), directory)
            }
            gtk_widget_set_halign(row, GTK_ALIGN_START)
            gtk_box_append(ptr(content), row)
        }

        let entryBits = UInt(bitPattern: entry)
        gtk_box_append(
            ptr(content),
            buttonRow(
                window: window,
                confirm: Gtk.button(Localized.text("Start"), css: ["suggested-action"]) {
                    guard let raw = UnsafeMutableRawPointer(bitPattern: entryBits) else { return }
                    let entry: UnsafeMutablePointer<GtkWidget> = ptr(raw)
                    let directory = entryText(entry)
                    close(entry)
                    onCreate(chosen.value, directory.isEmpty ? nil : directory)
                }))
        gtk_window_present(ptr(window))
    }

    private static func buttonRow(
        window: UnsafeMutablePointer<GtkWidget>, confirm: UnsafeMutablePointer<GtkWidget>
    ) -> UnsafeMutablePointer<GtkWidget> {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_widget_set_halign(row, GTK_ALIGN_END)
        let windowBits = UInt(bitPattern: window)
        gtk_box_append(
            ptr(row),
            Gtk.button(Localized.text("Cancel")) {
                guard let raw = UnsafeMutableRawPointer(bitPattern: windowBits) else { return }
                gtk_window_destroy(ptr(raw))
            })
        gtk_box_append(ptr(row), confirm)
        return row
    }

    final class Selection<Value: Sendable>: @unchecked Sendable {
        var value: Value
        init(_ value: Value) { self.value = value }
    }
}
