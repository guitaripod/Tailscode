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
    /// A dialog is as tall as it needs to be, and never taller than the screen it opens on.
    ///
    /// `-1` asks GTK for the natural height, which is the right answer until the content grows past
    /// the display — and then it is the worst one: the window is laid out at its full natural size,
    /// the bottom of it falls off the monitor, and because a plain box does not scroll there is
    /// nothing to reach it with. That is how a 780px form becomes unusable on an 800px laptop and
    /// how first run lost its Connect button the day a radar was added above it. So the content
    /// lives in a scroller that reports its natural height — the window still sizes itself to fit
    /// small content exactly — bounded by what the monitor actually has.
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

        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(op(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_scrolled_window_set_propagate_natural_height(op(scroller), 1)
        gtk_scrolled_window_set_propagate_natural_width(op(scroller), 1)
        gtk_scrolled_window_set_max_content_height(op(scroller), Self.tallestDialog(near: parent))
        gtk_scrolled_window_set_child(op(scroller), content)
        gtk_window_set_child(ptr(window), scroller)
        return (window, content)
    }

    /// The same window with its buttons pinned below the scroller rather than at the end of it.
    ///
    /// A dialog that can scroll can scroll its own primary action off the screen, which is worse
    /// than being too tall: the window looks complete and the way forward is somewhere below the
    /// fold. Anything a person must be able to press — Connect, Later, the demo — goes in the
    /// returned footer, which never moves.
    static func windowWithActions(
        title: String, parent: UnsafeMutablePointer<GtkWidget>?, width: Int32 = 460
    ) -> (
        window: UnsafeMutablePointer<GtkWidget>, content: UnsafeMutablePointer<GtkWidget>,
        actions: UnsafeMutablePointer<GtkWidget>
    ) {
        let (window, content) = Self.window(title: title, parent: parent, width: width)
        guard let scroller = gtk_window_get_child(ptr(window)) else {
            return (window, content, content)
        }
        let stack = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        let actions = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_widget_set_halign(actions, GTK_ALIGN_END)
        Gtk.margins(actions, top: 6, bottom: 14, leading: 18, trailing: 18)
        gtk_widget_set_vexpand(scroller, 1)
        g_object_ref(scroller)
        gtk_window_set_child(ptr(window), nil)
        gtk_box_append(ptr(stack), scroller)
        g_object_unref(scroller)
        gtk_box_append(ptr(stack), actions)
        gtk_window_set_child(ptr(window), stack)
        return (window, content, actions)
    }

    /// How tall a dialog may get on the display it is opening on, with room left for the shell's own
    /// furniture. Falls back to a laptop-sized guess where the monitor cannot be read, which is
    /// smaller than every desktop and larger than nothing.
    private static func tallestDialog(near widget: UnsafeMutablePointer<GtkWidget>?) -> Int32 {
        let height = Int32(tailscode_monitor_workarea_height(widget))
        guard height > 0 else { return 620 }
        return max(360, Int32(Double(height) * 0.82))
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
    /// for what the summary must keep where the server takes one — so it opens a decision screen
    /// whose every word is the shared ``CompactPreflight``'s: what compacting does, what stays,
    /// what the previous one traded, and a place for the instruction.
    static func compactPreflight(
        parent: UnsafeMutablePointer<GtkWidget>?, facts: CompactPreflight,
        initialInstruction: String = "",
        draft: DraftScope?, onCompact: @escaping @Sendable (String?) -> Void
    ) {
        let (window, content) = Self.window(
            title: Localized.text("Compact this conversation?"), parent: parent, width: 520)

        let headline = Gtk.label(facts.headline, css: "preflight-headline", selectable: false)
        gtk_widget_set_halign(headline, GTK_ALIGN_START)
        gtk_box_append(ptr(content), headline)
        let subtitle = Gtk.label(facts.subtitle, css: "sidebar-detail", selectable: false)
        gtk_widget_set_halign(subtitle, GTK_ALIGN_START)
        gtk_box_append(ptr(content), subtitle)

        for paragraph in facts.paragraphs {
            let body = Gtk.label(paragraph, css: "agent-text", wrap: true, selectable: false)
            gtk_widget_set_halign(body, GTK_ALIGN_START)
            gtk_box_append(ptr(content), body)
        }

        let entry: UnsafeMutablePointer<GtkWidget>?
        if facts.showsInstruction {
            let caption = Gtk.label(
                facts.fieldCaption.uppercased(), css: "section-header", wrap: true,
                selectable: false)
            gtk_widget_set_halign(caption, GTK_ALIGN_START)
            gtk_widget_set_margin_top(caption, 4)
            gtk_box_append(ptr(content), caption)

            let field = gtk_entry_new()!
            gtk_entry_set_placeholder_text(ptr(field), facts.fieldPlaceholder)
            let seeded = initialInstruction.isEmpty
                ? draft.map { DraftStore.text(for: $0) } ?? "" : initialInstruction
            gtk_editable_set_text(op(field), seeded)
            gtk_box_append(ptr(content), field)
            entry = field
        } else {
            entry = nil
        }

        if let lastTime = facts.lastTime {
            let previously = Gtk.label(lastTime, css: "seam-footnote", wrap: true, selectable: false)
            gtk_widget_set_halign(previously, GTK_ALIGN_START)
            gtk_box_append(ptr(content), previously)
        }
        let wait = Gtk.label(facts.wait, css: "seam-footnote", wrap: true, selectable: false)
        gtk_widget_set_halign(wait, GTK_ALIGN_START)
        gtk_box_append(ptr(content), wait)

        let entryBits = entry.map { UInt(bitPattern: $0) }
        if let draft, let entry {
            Gtk.connect(UnsafeMutableRawPointer(entry), "changed") {
                guard let entryBits,
                    let raw = UnsafeMutableRawPointer(bitPattern: entryBits),
                    let text = gtk_editable_get_text(op(raw))
                else { return }
                DraftStore.record(String(cString: text), for: draft)
            }
        }
        /// The window is closed from its own handle rather than from the field's root: a server
        /// that takes no instruction (opencode decides what its summary keeps) draws no field, and
        /// closing through one that does not exist left the confirmation standing over a
        /// compaction that had already started.
        let windowBits = UInt(bitPattern: window)
        let compact: @Sendable () -> Void = {
            var instruction = ""
            if let entryBits, let raw = UnsafeMutableRawPointer(bitPattern: entryBits) {
                instruction = entryText(ptr(raw))
            }
            if let draft { DraftStore.clear(draft) }
            if let raw = UnsafeMutableRawPointer(bitPattern: windowBits) {
                gtk_window_destroy(ptr(raw))
            }
            onCompact(instruction.isEmpty ? nil : instruction)
        }
        if let entry {
            Gtk.connect(UnsafeMutableRawPointer(entry), "activate", compact)
        }
        gtk_box_append(
            ptr(content),
            buttonRow(
                window: window,
                confirm: Gtk.button(
                    facts.confirmTitle, css: ["destructive-action"], onClick: compact)))
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
    /// - Parameters:
    ///   - unreachable: the profiles that did not answer the last listing, so the modal can say a
    ///     machine is down before a folder is chosen on it rather than after.
    ///   - onCreate: mints the chat and answers with the reason when it does not — the modal holds
    ///     the question until then.
    ///   - onFix: applies a failure's remedy: repointing the profile at the port its agent is
    ///     really on, or opening its settings.
    static func newChat(
        parent: UnsafeMutablePointer<GtkWidget>?,
        profiles: [ConnectionProfile],
        entries: [SessionEntry],
        preferredServer: String?,
        localAddresses: Set<String>,
        unreachable: Set<String> = [],
        onFix: @escaping @Sendable (
            NewChatFailure.Fix, @escaping @Sendable (NewChatFailure?) -> Void
        ) -> Void = { _, done in done(nil) },
        onCreate: @escaping @Sendable (
            String, String?, @escaping @Sendable (NewChatFailure?) -> Void
        ) -> Void
    ) {
        guard !profiles.isEmpty else { return }
        let local = Set(
            profiles.filter { isLocal($0, localAddresses: localAddresses) }.map(\.id))
        let servers = profiles.map { profile in
            NewChatServer(
                profileID: profile.id, name: profile.name, backend: profile.backend,
                address: ServerLabel.address(profile),
                reachable: !unreachable.contains(profile.id),
                canBrowse: local.contains(profile.id),
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
            onFix: onFix,
            onStart: { profileID, directory, done in onCreate(profileID, directory, done) })
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
