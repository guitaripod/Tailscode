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

    private let searchEntry = gtk_search_entry_new()!
    private let helpOverlay = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)

    private var entries: [SessionEntry] = []
    private var visible: [SessionRowModel] = []
    private var unreachable: [String] = []
    private var cursor = 0
    private var filter = ""
    private var pending = ""
    private var helpShown = false
    private var focused: Pane = .chats
    private var selectedID: String?
    private var conversation: AgentConversation?
    private var streamTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?

    func present(in app: UnsafeMutablePointer<AdwApplication>) {
        MatrixTheme.install()

        let window = adw_application_window_new(ptr(app))!
        gtk_window_set_title(ptr(window), "Tailscode")
        gtk_window_set_default_size(ptr(window), 1400, 900)
        gtk_window_set_icon_name(ptr(window), "tailscode")
        self.window = window

        let split = adw_navigation_split_view_new()!
        adw_navigation_split_view_set_sidebar(op(split), makeSidebarPage())
        adw_navigation_split_view_set_content(op(split), makeContentPage())
        adw_navigation_split_view_set_min_sidebar_width(op(split), 260)
        adw_navigation_split_view_set_max_sidebar_width(op(split), 400)

        // The shell runs the full width of the window under everything else, the way a terminal
        // pane sits under an editor: what you run there is about the whole project, not about the
        // one conversation that happens to be open.
        let stack = gtk_paned_new(GTK_ORIENTATION_VERTICAL)!
        gtk_paned_set_start_child(op(stack), split)
        gtk_paned_set_end_child(op(stack), terminal.widget)
        gtk_paned_set_position(op(stack), 600)
        gtk_paned_set_resize_start_child(op(stack), 1)
        gtk_paned_set_shrink_end_child(op(stack), 0)

        adw_application_window_set_content(ptr(window), stack)
        gtk_window_present(ptr(window))

        fileTree.onOpen = { [weak self] path in self?.insertIntoComposer("@\(path) ") }
        installKeymap(on: window)
        startRefreshing()
    }

    private func makeSidebarPage() -> UnsafeMutablePointer<AdwNavigationPage> {
        let toolbar = adw_toolbar_view_new()!
        let header = adw_header_bar_new()!
        adw_header_bar_set_title_widget(
            op(header), Gtk.label("TAILSCODE", css: "section-header", selectable: false))
        adw_toolbar_view_add_top_bar(op(toolbar), header)

        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_search_entry_set_placeholder_text(op(searchEntry), Localized.text("Filter chats  /"))
        Gtk.margins(searchEntry, top: 4, bottom: 4, leading: 6, trailing: 6)
        Gtk.connect(UnsafeMutableRawPointer(searchEntry), "search-changed") { [weak self] in
            self?.applyFilterFromEntry()
        }
        gtk_box_append(ptr(column), searchEntry)
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
        gtk_widget_set_visible(helpOverlay, 0)
        Gtk.addClass(helpOverlay, "canvas")
        Gtk.margins(helpOverlay, top: 8, bottom: 8, leading: 26, trailing: 26)
        for entry in Keymap.help {
            let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 12)
            let keys = Gtk.label(entry.keys, css: "tool-name", selectable: false)
            gtk_widget_set_size_request(keys, 130, -1)
            gtk_box_append(ptr(row), keys)
            gtk_box_append(ptr(row), Gtk.label(entry.what, css: "row-detail", selectable: false))
            gtk_box_append(ptr(helpOverlay), row)
        }
        gtk_box_append(ptr(column), helpOverlay)
        gtk_box_append(ptr(column), statusLabel)
        gtk_box_append(ptr(column), makeComposer())
        return column
    }

    private func makeProjectColumn() -> UnsafeMutablePointer<GtkWidget> {
        gtk_widget_set_size_request(fileTree.widget, 340, -1)
        return fileTree.widget
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
        let saved = Set(SavedChatStore.all().map(\.sessionID))
        let unread = SessionSeenStore.unreadEvaluator()
        let needle = filter.lowercased()
        visible = entries.map {
            SessionRowModel(
                entry: $0, unreachable: unreachable.contains($0.profileName),
                unread: unread($0.session.id, $0.session.updatedAt),
                saved: saved.contains($0.session.id))
        }.filter {
            needle.isEmpty || $0.title.lowercased().contains(needle)
                || $0.detail.lowercased().contains(needle)
        }

        guard !visible.isEmpty else {
            gtk_box_append(
                ptr(sidebarList),
                SidebarRow.empty(
                    filter.isEmpty
                        ? Localized.text("No conversations yet")
                        : Localized.text("Nothing matches “%@”", filter)))
            return
        }
        cursor = min(cursor, visible.count - 1)

        var index = 0
        for (section, members) in groupIntoSections(visible) {
            gtk_box_append(
                ptr(sidebarList), SidebarRow.header(section.title, count: members.count))
            for row in members {
                let position = index
                gtk_box_append(
                    ptr(sidebarList),
                    SidebarRow.make(row, focused: position == cursor) { [weak self] in
                        self?.cursor = position
                        self?.open(row.entry)
                    })
                index += 1
            }
        }
    }

    private func applyFilterFromEntry() {
        guard let raw = gtk_editable_get_text(op(searchEntry)) else { return }
        filter = String(cString: raw)
        cursor = 0
        renderSidebar()
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

    /// Normal mode owns the letters; focusing anything that takes text hands them back. Every
    /// binding has a thing you can also click, so the keyboard is a shortcut rather than the only
    /// way in.
    private func installKeymap(on window: UnsafeMutablePointer<GtkWidget>) {
        let root = UInt(bitPattern: window)
        Gtk.onKey(window) { [weak self] keyval, state in
            guard let self, let base = UnsafeMutableRawPointer(bitPattern: root) else {
                return false
            }
            let window: UnsafeMutablePointer<GtkWidget> = ptr(base)
            if Gtk.focusTakesText(window) {
                guard let action = Keymap.insert(keyval: keyval, state: state) else { return false }
                return self.perform(action)
            }
            let action = Keymap.normal(keyval: keyval, state: state, pending: self.pending)
            self.pending = Keymap.scalar(keyval) == "g" && action == nil ? "g" : ""
            guard let action else { return false }
            return self.perform(action)
        }
    }

    private func perform(_ action: KeyAction) -> Bool {
        switch action {
        case .focus(let pane): focus(pane)
        case .cycleForward: focus(nextPane(after: focused, by: 1))
        case .cycleBackward: focus(nextPane(after: focused, by: -1))
        case .selectNext: move(by: 1)
        case .selectPrevious: move(by: -1)
        case .selectFirst: cursor = 0; renderSidebar(); openCursor()
        case .selectLast: cursor = max(0, visible.count - 1); renderSidebar(); openCursor()
        case .openSelected: openCursor()
        case .scrollDown: scroll(by: 60)
        case .scrollUp: scroll(by: -60)
        case .halfPageDown: scroll(byPages: 0.5)
        case .halfPageUp: scroll(byPages: -0.5)
        case .scrollTop: scroll(toEnd: false)
        case .scrollBottom: scroll(toEnd: true)
        case .insert: focus(.transcript); gtk_widget_grab_focus(entryView)
        case .leaveInsert: gtk_widget_grab_focus(sidebarList); setHelp(false)
        case .search: gtk_widget_grab_focus(searchEntry)
        case .send: sendFromComposer()
        case .stop: stopTurn()
        case .toggleHelp: setHelp(!helpShown)
        case .reload: Task { [weak self] in await self?.refresh() }
        }
        return true
    }

    private func nextPane(after pane: Pane, by delta: Int) -> Pane {
        let all = Pane.allCases
        let index = (all.firstIndex(of: pane) ?? 0) + delta
        return all[(index % all.count + all.count) % all.count]
    }

    private func focus(_ pane: Pane) {
        focused = pane
        switch pane {
        case .chats: gtk_widget_grab_focus(sidebarList)
        case .transcript: gtk_widget_grab_focus(transcriptBox)
        case .files: gtk_widget_grab_focus(fileTree.widget)
        case .terminal: terminal.takeFocus()
        }
    }

    private func move(by delta: Int) {
        guard !visible.isEmpty else { return }
        cursor = max(0, min(visible.count - 1, cursor + delta))
        renderSidebar()
        openCursor()
    }

    private func openCursor() {
        guard cursor < visible.count else { return }
        open(visible[cursor].entry)
    }

    private func setHelp(_ shown: Bool) {
        helpShown = shown
        gtk_widget_set_visible(helpOverlay, shown ? 1 : 0)
    }

    private func stopTurn() {
        guard let conversation else { return }
        Task { try? await conversation.cancelCurrentTurn() }
    }

    private func scroll(by amount: Double) {
        adjust { $0 + amount }
    }

    private func scroll(byPages fraction: Double) {
        guard let scroller = transcriptScroller,
            let adjustment = gtk_scrolled_window_get_vadjustment(op(scroller))
        else { return }
        let page = gtk_adjustment_get_page_size(adjustment) * fraction
        adjust { $0 + page }
    }

    private func scroll(toEnd bottom: Bool) {
        guard let scroller = transcriptScroller,
            let adjustment = gtk_scrolled_window_get_vadjustment(op(scroller))
        else { return }
        let limit =
            bottom
            ? gtk_adjustment_get_upper(adjustment) - gtk_adjustment_get_page_size(adjustment)
            : gtk_adjustment_get_lower(adjustment)
        adjust { _ in limit }
    }

    private func adjust(_ transform: (Double) -> Double) {
        guard let scroller = transcriptScroller,
            let adjustment = gtk_scrolled_window_get_vadjustment(op(scroller))
        else { return }
        let ceiling = gtk_adjustment_get_upper(adjustment)
            - gtk_adjustment_get_page_size(adjustment)
        let next = min(max(gtk_adjustment_get_lower(adjustment),
            transform(gtk_adjustment_get_value(adjustment))), max(0, ceiling))
        gtk_adjustment_set_value(adjustment, next)
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
