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
    /// the conversation's flow. Focus opens on the Close button, not the first selectable label —
    /// a focused GtkLabel opens with its whole paragraph highlighted, which reads as a stuck
    /// selection.
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

        let view: UnsafeMutablePointer<GtkWidget>
        if mono {
            let text = gtk_text_view_new()!
            gtk_text_view_set_editable(ptr(UnsafeMutableRawPointer(text)), 0)
            gtk_text_view_set_cursor_visible(ptr(UnsafeMutableRawPointer(text)), 0)
            gtk_text_view_set_wrap_mode(ptr(UnsafeMutableRawPointer(text)), GTK_WRAP_WORD_CHAR)
            gtk_text_view_set_left_margin(ptr(UnsafeMutableRawPointer(text)), 18)
            gtk_text_view_set_right_margin(ptr(UnsafeMutableRawPointer(text)), 18)
            gtk_text_view_set_top_margin(ptr(UnsafeMutableRawPointer(text)), 14)
            gtk_text_view_set_bottom_margin(ptr(UnsafeMutableRawPointer(text)), 14)
            Gtk.addClass(text, "reader-mono")
            if let buffer = gtk_text_view_get_buffer(ptr(UnsafeMutableRawPointer(text))) {
                gtk_text_buffer_set_text(buffer, body, -1)
            }
            view = text
        } else {
            let rich = TranscriptRow.richBody(body)
            Gtk.addClass(rich, "reader-prose")
            Gtk.margins(rich, top: 14, bottom: 18, leading: 18, trailing: 18)
            view = rich
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
        let dismiss = Gtk.button(Localized.text("Close"), css: ["suggested-action"]) {
            guard let raw = UnsafeMutableRawPointer(bitPattern: windowBits) else { return }
            gtk_window_destroy(ptr(raw))
        }
        gtk_box_append(ptr(actions), dismiss)
        gtk_box_append(ptr(column), actions)

        gtk_window_set_child(ptr(window), column)
        gtk_window_present(ptr(window))
        gtk_widget_grab_focus(dismiss)
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
    /// The question is asked by ``NewChatWindow`` over the shared `NewChatChooser`; what this
    /// function owns is the translation from this desktop's own facts into it — which profiles
    /// exist, which of them is this same machine, and what "Browse…" can mean.
    ///
    /// Only a local server offers to browse: the desktop's own folder chooser is the one place a
    /// native picker tells the truth, and pointing it at this disk on behalf of a machine across
    /// the tailnet would offer folders that are not there.
    static func newChat(
        parent: UnsafeMutablePointer<GtkWidget>?,
        profiles: [ConnectionProfile],
        entries: [SessionEntry],
        preferredServer: String?,
        localAddresses: Set<String>,
        onCreate: @escaping @Sendable (ConnectionProfile, String?) -> Void
    ) {
        guard !profiles.isEmpty else { return }
        let byID = Dictionary(uniqueKeysWithValues: profiles.map { ($0.id, $0) })
        let local = Set(
            profiles.filter { isLocal($0, localAddresses: localAddresses) }.map(\.id))
        let servers = profiles.map { profile in
            NewChatServer(
                profileID: profile.id, name: profile.name, backend: profile.backend,
                address: ServerLabel.address(profile), canBrowse: local.contains(profile.id),
                isLocal: local.contains(profile.id))
        }
        let parentBits = parent.map { UInt(bitPattern: $0) } ?? 0
        NewChatWindow.present(
            servers: servers, entries: entries, preferredServer: preferredServer, parent: parent,
            onBrowse: { _, typed, deliver in
                let host = UnsafeMutableRawPointer(bitPattern: parentBits).map {
                    raw -> UnsafeMutablePointer<GtkWidget> in ptr(raw)
                }
                Gtk.selectFolder(parent: host, initial: browseSeed(typed)) { picked in
                    guard let picked else { return }
                    deliver(picked)
                }
            },
            onStart: { profileID, directory in
                guard let profile = byID[profileID] else { return }
                onCreate(profile, directory)
            })
    }

    /// This machine answering its own tailnet address is still this machine: a profile is local
    /// when its host is a loopback, the hostname, or the address Tailscale gives this box.
    private static func isLocal(
        _ profile: ConnectionProfile, localAddresses: Set<String>
    ) -> Bool {
        guard let host = profile.baseURL.host?.lowercased() else { return false }
        if localAddresses.contains(host) { return true }
        return localAddresses.contains(String(host.split(separator: ".").first ?? ""))
    }

    /// The picker opens where the entry points when that is a real folder here, expanding a
    /// leading `~`; anywhere else it falls back to the chooser's own default.
    private static func browseSeed(_ text: String) -> String? {
        guard !text.isEmpty else { return nil }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let expanded =
            text == "~"
            ? home
            : text.hasPrefix("~/") ? home + text.dropFirst() : text
        var isDirectory: ObjCBool = false
        guard expanded.hasPrefix("/"),
            FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory),
            isDirectory.boolValue
        else { return nil }
        return expanded
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
}
