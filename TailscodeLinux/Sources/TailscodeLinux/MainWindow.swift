import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// The window: the chat list, the conversation, and the project it is working in.
///
/// State lives here on the GLib main context; everything that talks to a server happens in a
/// detached `Task` and comes back through ``Gtk/onMain(_:)``. There is no `@MainActor` anywhere in
/// this app — `g_application_run` never drains libdispatch's main queue, so awaiting into a
/// main-actor type from a signal handler would suspend forever with no crash and no log line.
final class MainWindow: @unchecked Sendable {
    private var window: UnsafeMutablePointer<GtkWidget>?
    private let sidebarList = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    private let sidebarBanner = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    private let transcriptBox = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 10)
    private let statusLabel = Gtk.label("", css: "status-line")
    private let entryView = gtk_text_view_new()!
    private let sendButton = gtk_button_new_with_label("Send")!
    private let titleLabel = Gtk.label("", css: "mono", selectable: false)
    private var transcriptScroller: UnsafeMutablePointer<GtkWidget>?
    private let fileTree = FileTree()
    private let terminal = TerminalPane()

    private var entries: [SessionEntry] = []
    private var unreachable: [String] = []
    private var selectedID: String?
    private var conversation: AgentConversation?
    private var streamTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

    func present(in app: UnsafeMutablePointer<AdwApplication>) {
        MatrixTheme.install()

        let window = adw_application_window_new(ptr(app))!
        gtk_window_set_title(ptr(window), "Tailscode")
        gtk_window_set_default_size(ptr(window), 1400, 880)
        self.window = window

        let split = adw_navigation_split_view_new()!
        adw_navigation_split_view_set_sidebar(op(split), makeSidebarPage())
        adw_navigation_split_view_set_content(op(split), makeContentPage())
        adw_navigation_split_view_set_min_sidebar_width(op(split), 260)
        adw_navigation_split_view_set_max_sidebar_width(op(split), 400)

        adw_application_window_set_content(ptr(window), split)
        gtk_window_present(ptr(window))

        fileTree.onOpen = { [weak self] path in self?.insertIntoComposer("@\(path) ") }
        startRefreshing()
    }

    private func makeSidebarPage() -> UnsafeMutablePointer<AdwNavigationPage> {
        let toolbar = adw_toolbar_view_new()!
        let header = adw_header_bar_new()!
        adw_header_bar_set_title_widget(
            op(header), Gtk.label("TAILSCODE", css: "section-header", selectable: false))
        adw_toolbar_view_add_top_bar(op(toolbar), header)

        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_box_append(ptr(column), sidebarBanner)

        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(op(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        Gtk.margins(sidebarList, top: 2, bottom: 8, leading: 6, trailing: 6)
        gtk_scrolled_window_set_child(op(scroller), sidebarList)
        gtk_widget_set_vexpand(scroller, 1)
        gtk_box_append(ptr(column), scroller)

        adw_toolbar_view_set_content(op(toolbar), column)
        return adw_navigation_page_new(toolbar, "Chats")!
    }

    /// Conversation on the left of the content area, the project it works in on the right: the
    /// files the agent is editing and a shell in the same directory, because reading what it just
    /// changed and running the thing it just built are the two moves that otherwise send you back
    /// to a terminal.
    private func makeContentPage() -> UnsafeMutablePointer<AdwNavigationPage> {
        let toolbar = adw_toolbar_view_new()!
        let header = adw_header_bar_new()!
        adw_header_bar_set_title_widget(op(header), titleLabel)
        adw_toolbar_view_add_top_bar(op(toolbar), header)

        let panes = gtk_paned_new(GTK_ORIENTATION_HORIZONTAL)!
        gtk_paned_set_start_child(op(panes), makeConversationColumn())
        gtk_paned_set_end_child(op(panes), makeProjectColumn())
        gtk_paned_set_position(op(panes), 800)
        gtk_paned_set_resize_start_child(op(panes), 1)
        gtk_paned_set_shrink_end_child(op(panes), 0)

        adw_toolbar_view_set_content(op(toolbar), panes)
        return adw_navigation_page_new(toolbar, "Conversation")!
    }

    private func makeConversationColumn() -> UnsafeMutablePointer<GtkWidget> {
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        Gtk.addClass(column, "canvas")

        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(op(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        Gtk.addClass(transcriptBox, "transcript")
        gtk_scrolled_window_set_child(op(scroller), transcriptBox)
        gtk_widget_set_vexpand(scroller, 1)
        transcriptScroller = scroller
        gtk_box_append(ptr(column), scroller)
        gtk_box_append(ptr(column), statusLabel)
        gtk_box_append(ptr(column), makeComposer())
        return column
    }

    private func makeProjectColumn() -> UnsafeMutablePointer<GtkWidget> {
        let panes = gtk_paned_new(GTK_ORIENTATION_VERTICAL)!
        gtk_widget_set_size_request(panes, 380, -1)
        gtk_paned_set_start_child(op(panes), fileTree.widget)
        gtk_paned_set_end_child(op(panes), terminal.widget)
        gtk_paned_set_position(op(panes), 380)
        return panes
    }

    private func makeComposer() -> UnsafeMutablePointer<GtkWidget> {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        Gtk.margins(row, top: 10, bottom: 12, leading: 26, trailing: 26)

        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(op(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_widget_set_size_request(scroller, -1, 64)
        gtk_widget_set_hexpand(scroller, 1)
        gtk_text_view_set_wrap_mode(ptr(entryView), GTK_WRAP_WORD_CHAR)
        gtk_text_view_set_monospace(ptr(entryView), 1)
        gtk_text_view_set_top_margin(ptr(entryView), 8)
        gtk_text_view_set_left_margin(ptr(entryView), 10)
        gtk_text_view_set_right_margin(ptr(entryView), 10)
        gtk_scrolled_window_set_child(op(scroller), entryView)
        Gtk.addClass(scroller, "composer")

        Gtk.addClass(sendButton, "suggested-action")
        gtk_widget_set_valign(sendButton, GTK_ALIGN_END)
        Gtk.connect(UnsafeMutableRawPointer(sendButton), "clicked") { [weak self] in
            self?.sendFromComposer()
        }

        gtk_box_append(ptr(row), scroller)
        gtk_box_append(ptr(row), sendButton)
        return row
    }

    private func startRefreshing() {
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    func refresh() async {
        await ServerDirectory.shared.reload()
        let (entries, unreachable) = await ServerDirectory.shared.entries()
        Gtk.onMain { [weak self] in
            self?.applyEntries(entries, unreachable: unreachable)
        }
    }

    private func applyEntries(_ entries: [SessionEntry], unreachable: [String]) {
        self.entries = entries
        self.unreachable = unreachable
        renderSidebar()
        if selectedID == nil, !entries.isEmpty { open(entries[0]) }
    }

    private func renderSidebar() {
        Gtk.removeChildren(of: sidebarBanner)
        if !unreachable.isEmpty {
            gtk_box_append(
                ptr(sidebarBanner),
                SidebarRow.banner(
                    Localized.text("%@ unreachable — showing what was last seen",
                        unreachable.joined(separator: ", "))))
        }

        Gtk.removeChildren(of: sidebarList)
        guard !entries.isEmpty else {
            gtk_box_append(ptr(sidebarList), SidebarRow.empty(Localized.text("No conversations yet")))
            return
        }
        let saved = Set(SavedChatStore.all().map(\.sessionID))
        let rows = entries.map {
            SessionRowModel(
                entry: $0, unreachable: unreachable.contains($0.profileName),
                unread: SessionSeenStore.unreadEvaluator()($0.session.id, $0.session.updatedAt),
                saved: saved.contains($0.session.id))
        }
        for (section, members) in groupIntoSections(rows) {
            gtk_box_append(
                ptr(sidebarList), SidebarRow.header(section.title, count: members.count))
            for row in members.prefix(section == .recent ? 120 : 20) {
                gtk_box_append(
                    ptr(sidebarList),
                    SidebarRow.make(row) { [weak self] in self?.open(row.entry) })
            }
        }
    }

    private func open(_ entry: SessionEntry) {
        guard selectedID != entry.session.id else { return }
        selectedID = entry.session.id
        conversation = nil
        streamTask?.cancel()
        renderRows([], placeholder: Localized.text("Connecting…"))
        gtk_label_set_text(
            op(titleLabel),
            entry.session.hasPlaceholderTitle
                ? Localized.text("New conversation") : entry.session.title)
        SessionSeenStore.markSeen(entry.session.id)
        terminal.setDirectory(entry.session.directory)

        streamTask = Task { [weak self] in
            guard let self else { return }
            guard
                let profile = await ServerDirectory.shared.profiles().first(where: {
                    $0.id == entry.profileID
                }), let backend = await ServerDirectory.shared.backend(for: profile)
            else {
                Gtk.onMain { [weak self] in
                    self?.renderRows([], placeholder: Localized.text("That server is not configured."))
                }
                return
            }
            Gtk.onMain { [weak self] in
                self?.fileTree.show(directory: entry.session.directory, on: backend)
            }
            let conversation = AgentConversation(
                backend: backend, sessionID: entry.session.id, cache: AppCache.sessionCache)
            self.conversation = conversation
            for await state in await conversation.states() {
                if Task.isCancelled { return }
                let rows = state.messages.flatMap(TranscriptRow.rows(for:))
                let status = Self.statusText(for: state)
                let running = state.status == .running
                let placeholder =
                    rows.isEmpty
                    ? (state.hasLoadedTranscript
                        ? Localized.text("Nothing here yet. Say something.")
                        : Localized.text("Loading…"))
                    : nil
                Gtk.onMain { [weak self] in
                    self?.renderRows(rows, placeholder: placeholder)
                    self?.setStatus(status, running: running)
                }
            }
        }
    }

    /// What the line under the transcript says. Every distinguishable condition gets its own
    /// sentence — a failure, a reconnect and a running turn must not all read as silence.
    private static func statusText(for state: ConversationState) -> String {
        if let failure = state.lastFailure { return "! \(failure.message)" }
        switch state.connection {
        case .offline: return Localized.text("Offline — the server stopped answering")
        case .reconnecting: return Localized.text("Reconnecting…")
        case .connecting: return Localized.text("Connecting…")
        case .live: break
        }
        if !state.pendingPermissions.isEmpty { return Localized.text("Waiting for your approval") }
        if !state.pendingQuestions.isEmpty { return Localized.text("Waiting for your answer") }
        if state.status == .running { return Localized.text("Working…") }
        return Localized.text("Idle")
    }

    private func setStatus(_ text: String, running: Bool) {
        gtk_label_set_text(op(statusLabel), text)
        gtk_button_set_label(
            ptr(sendButton), running ? Localized.text("Queue") : Localized.text("Send"))
    }

    private func renderRows(_ rows: [TranscriptRow], placeholder: String?) {
        Gtk.removeChildren(of: transcriptBox)
        if let placeholder {
            let label = Gtk.label(placeholder, css: "dim", selectable: false)
            Gtk.margins(label, top: 24, bottom: 24, leading: 4, trailing: 4)
            gtk_box_append(ptr(transcriptBox), label)
            return
        }
        for row in rows {
            gtk_box_append(ptr(transcriptBox), row.makeWidget())
        }
        scrollToBottom()
    }

    private func scrollToBottom() {
        guard let scroller = transcriptScroller,
            let adjustment = gtk_scrolled_window_get_vadjustment(op(scroller))
        else { return }
        let raw = UInt(bitPattern: adjustment)
        Gtk.onMain {
            guard let base = UnsafeMutableRawPointer(bitPattern: raw) else { return }
            let adjustment: UnsafeMutablePointer<GtkAdjustment> = ptr(base)
            gtk_adjustment_set_value(
                adjustment,
                gtk_adjustment_get_upper(adjustment) - gtk_adjustment_get_page_size(adjustment))
        }
    }

    private func insertIntoComposer(_ text: String) {
        let buffer = gtk_text_view_get_buffer(ptr(entryView))
        var end = GtkTextIter()
        gtk_text_buffer_get_end_iter(buffer, &end)
        gtk_text_buffer_insert(buffer, &end, text, -1)
    }

    private func sendFromComposer() {
        let buffer = gtk_text_view_get_buffer(ptr(entryView))
        var start = GtkTextIter()
        var end = GtkTextIter()
        gtk_text_buffer_get_bounds(buffer, &start, &end)
        guard let raw = gtk_text_buffer_get_text(buffer, &start, &end, 0) else { return }
        let text = String(cString: raw).trimmingCharacters(in: .whitespacesAndNewlines)
        g_free(raw)
        guard !text.isEmpty, let conversation else { return }
        gtk_text_buffer_set_text(buffer, "", 0)
        Task { try? await conversation.send(text) }
    }
}
