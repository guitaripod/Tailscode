import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
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
    private let pendingBox = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 8)
    private let authBanner = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
    private let goalLabel = Gtk.label("", css: "goal-line", selectable: false)
    private let statusLabel = Gtk.label("", css: "status-line")
    private let entryView = gtk_text_view_new()!
    private let sendButton = gtk_button_new_with_label("Send")!
    private let stopButton = gtk_button_new_with_label("⏹")!
    private let titleLabel = Gtk.label("", css: "mono", selectable: false)
    private var modelButton: UnsafeMutablePointer<GtkWidget>?
    private var effortButton: UnsafeMutablePointer<GtkWidget>?
    private var commandButton: UnsafeMutablePointer<GtkWidget>?
    private let destinationLabel = Gtk.label("", css: "row-detail", selectable: false)
    private var transcriptScroller: UnsafeMutablePointer<GtkWidget>?
    private let fileTree = FileTree()
    private let terminal = TerminalPane()

    private let searchEntry = gtk_search_entry_new()!
    private let helpOverlay = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)

    private let attachmentsBox = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
    private var attachments: [PendingAttachment] = []
    private var pastedImageCount = 0

    private let jumpButton = gtk_button_new()!
    private var unseenRows = 0

    private let findBar = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
    private let findEntry = gtk_search_entry_new()!
    private let findCountLabel = Gtk.label("", css: "row-detail", selectable: false)
    private var findMatches: [Int] = []
    private var findCursor = 0
    private var highlightedRow: UInt = 0
    private var canvasBox: UnsafeMutablePointer<GtkWidget>?
    private var rebuildingInPlace = false

    private let usageBox = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 4)
    private var usageTask: Task<Void, Never>?

    private let context = TranscriptContext()
    private var renderedRows: [TranscriptRow] = []
    private var rowWidgets: [UInt] = []
    private var placeholderShown = false
    private var inFlightImages: Set<String> = []
    private var inFlightSubagents: Set<String> = []

    private var entries: [SessionEntry] = []
    private var visible: [SessionRowModel] = []
    private var unreachable: [String] = []
    private var cursor = 0
    private var filter = ""
    private var pending = ""
    private var helpShown = false
    private var focused: Pane = .chats
    private var selectedID: String?
    private var currentEntry: SessionEntry?
    private var currentBackend: (any CodingAgentBackend)?
    private var conversation: AgentConversation?
    private var lastState: ConversationState?
    private var streamTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var tickerTask: Task<Void, Never>?
    private var turnStartedAt: Date?

    private var models: [ModelInfo] = []
    private var commands: [AgentCommand] = []
    private var chosenModel: ModelSelection?
    private var chosenEffort: String?

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

        let stack = gtk_paned_new(GTK_ORIENTATION_VERTICAL)!
        gtk_paned_set_start_child(op(stack), split)
        gtk_paned_set_end_child(op(stack), terminal.widget)
        gtk_paned_set_position(op(stack), 600)
        gtk_paned_set_resize_start_child(op(stack), 1)
        gtk_paned_set_shrink_end_child(op(stack), 0)

        adw_application_window_set_content(ptr(window), stack)
        gtk_window_present(ptr(window))

        fileTree.onOpen = { [weak self] path in self?.insertIntoComposer("@\(path) ") }
        wireContext()
        installKeymap(on: window)
        startRefreshing()
        startUsagePolling()
    }

    private func makeSidebarPage() -> UnsafeMutablePointer<AdwNavigationPage> {
        let toolbar = adw_toolbar_view_new()!
        let header = adw_header_bar_new()!
        adw_header_bar_set_title_widget(
            op(header), Gtk.label("TAILSCODE", css: "section-header", selectable: false))
        adw_header_bar_pack_start(
            op(header),
            Gtk.button("+", css: ["flat"]) { [weak self] in self?.presentNewChat() })
        adw_header_bar_pack_end(
            op(header),
            Gtk.button("⚙", css: ["flat"]) { [weak self] in self?.presentServers() })
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

        gtk_widget_set_visible(usageBox, 0)
        Gtk.addClass(usageBox, "usage-footer")
        Gtk.margins(usageBox, top: 6, bottom: 8, leading: 10, trailing: 10)
        gtk_box_append(ptr(column), usageBox)

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
        adw_header_bar_pack_end(op(header), makeActionsButton())
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

        Gtk.addClass(authBanner, "banner-auth")
        gtk_widget_set_visible(authBanner, 0)
        gtk_box_append(ptr(column), authBanner)

        gtk_box_append(ptr(column), makeFindBar())

        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(op(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        let canvas = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 10)
        Gtk.addClass(canvas, "transcript")
        canvasBox = canvas
        gtk_box_append(ptr(canvas), transcriptBox)
        Gtk.margins(pendingBox, top: 8)
        gtk_box_append(ptr(canvas), pendingBox)
        gtk_scrolled_window_set_child(op(scroller), canvas)
        gtk_widget_set_vexpand(scroller, 1)
        transcriptScroller = scroller

        let overlay = gtk_overlay_new()!
        gtk_overlay_set_child(op(overlay), scroller)
        gtk_widget_set_vexpand(overlay, 1)
        Gtk.addClass(jumpButton, "jump-pill")
        gtk_widget_set_halign(jumpButton, GTK_ALIGN_END)
        gtk_widget_set_valign(jumpButton, GTK_ALIGN_END)
        Gtk.margins(jumpButton, bottom: 14, trailing: 22)
        gtk_widget_set_visible(jumpButton, 0)
        Gtk.connect(UnsafeMutableRawPointer(jumpButton), "clicked") { [weak self] in
            self?.jumpToBottom()
        }
        gtk_overlay_add_overlay(op(overlay), jumpButton)
        gtk_box_append(ptr(column), overlay)

        if let adjustment = gtk_scrolled_window_get_vadjustment(op(scroller)) {
            Gtk.connect(UnsafeMutableRawPointer(adjustment), "value-changed") { [weak self] in
                guard let self, self.isNearBottom() else { return }
                self.clearUnseen()
            }
        }

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

        gtk_widget_set_visible(goalLabel, 0)
        gtk_box_append(ptr(column), goalLabel)
        gtk_box_append(ptr(column), statusLabel)
        gtk_widget_set_visible(attachmentsBox, 0)
        Gtk.margins(attachmentsBox, top: 4, leading: 26, trailing: 26)
        gtk_box_append(ptr(column), attachmentsBox)
        gtk_box_append(ptr(column), makeComposer())
        gtk_box_append(ptr(column), makePillRow())
        return column
    }

    private func makeProjectColumn() -> UnsafeMutablePointer<GtkWidget> {
        gtk_widget_set_size_request(fileTree.widget, 340, -1)
        return fileTree.widget
    }

    private func makeComposer() -> UnsafeMutablePointer<GtkWidget> {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        Gtk.margins(row, top: 10, bottom: 4, leading: 26, trailing: 26)

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

        let attach = Gtk.menuButton("📎", css: ["flat"]) { [weak self] in
            self?.attachRows() ?? []
        }
        gtk_widget_set_valign(attach, GTK_ALIGN_END)

        gtk_box_append(ptr(row), scroller)
        gtk_box_append(ptr(row), attach)
        gtk_box_append(ptr(row), sendButton)
        return row
    }

    /// The transcript's own search, over what the rows say rather than what the server indexes:
    /// it works offline, on a saved copy, and mid-turn.
    private func makeFindBar() -> UnsafeMutablePointer<GtkWidget> {
        Gtk.addClass(findBar, "find-bar")
        gtk_widget_set_visible(findBar, 0)
        Gtk.margins(findBar, top: 4, bottom: 4, leading: 26, trailing: 26)

        gtk_search_entry_set_placeholder_text(
            op(findEntry), Localized.text("Find in this conversation"))
        gtk_widget_set_hexpand(findEntry, 1)
        Gtk.connect(UnsafeMutableRawPointer(findEntry), "search-changed") { [weak self] in
            self?.runFind(retarget: true)
        }
        Gtk.connect(UnsafeMutableRawPointer(findEntry), "activate") { [weak self] in
            self?.stepFind(by: 1)
        }
        Gtk.connect(UnsafeMutableRawPointer(findEntry), "stop-search") { [weak self] in
            self?.setFindShown(false)
        }
        gtk_box_append(ptr(findBar), findEntry)
        gtk_box_append(ptr(findBar), findCountLabel)
        gtk_box_append(
            ptr(findBar), Gtk.button("↑", css: ["flat"]) { [weak self] in self?.stepFind(by: -1) })
        gtk_box_append(
            ptr(findBar), Gtk.button("↓", css: ["flat"]) { [weak self] in self?.stepFind(by: 1) })
        gtk_box_append(
            ptr(findBar),
            Gtk.button("✕", css: ["flat"]) { [weak self] in self?.setFindShown(false) })
        return findBar
    }

    /// The line under the composer that says where the next prompt goes and how: destination,
    /// model, effort, the command palette, and stop. The CLI's status line, made clickable.
    private func makePillRow() -> UnsafeMutablePointer<GtkWidget> {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        Gtk.addClass(row, "pill-row")

        gtk_box_append(ptr(row), destinationLabel)

        let model = Gtk.menuButton(Localized.text("model")) { [weak self] in
            self?.modelRows() ?? []
        }
        modelButton = model
        gtk_box_append(ptr(row), model)

        let effort = Gtk.menuButton(Localized.text("effort")) { [weak self] in
            self?.effortRows() ?? []
        }
        effortButton = effort
        gtk_box_append(ptr(row), effort)

        let palette = Gtk.menuButton("/") { [weak self] in
            self?.commandRows() ?? []
        }
        commandButton = palette
        gtk_box_append(ptr(row), palette)

        let spacer = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        gtk_widget_set_hexpand(spacer, 1)
        gtk_box_append(ptr(row), spacer)

        gtk_widget_set_visible(stopButton, 0)
        Gtk.addClass(stopButton, "destructive-action")
        Gtk.connect(UnsafeMutableRawPointer(stopButton), "clicked") { [weak self] in
            self?.stopTurn()
        }
        gtk_box_append(ptr(row), stopButton)
        return row
    }

    private func makeActionsButton() -> UnsafeMutablePointer<GtkWidget> {
        Gtk.menuButton("⋯", css: ["flat"]) { [weak self] in
            self?.actionRows() ?? []
        }
    }

    private func wireContext() {
        context.onToggle = { [weak self] key, open in
            Gtk.onMain { [weak self] in
                guard let self else { return }
                if open { self.context.expanded.insert(key) } else {
                    self.context.expanded.remove(key)
                }
            }
        }
        context.requestImage = { [weak self] reference, key in
            Gtk.onMain { [weak self] in self?.fetchImage(reference, key: key) }
        }
        context.requestSubagent = { [weak self] call in
            Gtk.onMain { [weak self] in self?.fetchSubagent(call) }
        }
        context.openImage = { [weak self] key, name in
            Gtk.onMain { [weak self] in self?.presentImage(key: key, name: name) }
        }
    }

    /// The picture at full size in its own window, and a save that hands over the bytes the
    /// server sent — never a re-encode of the bitmap a row downsampled to display.
    private func presentImage(key: String, name: String) {
        guard let bits = context.textures[key], bits != 0 else { return }
        let texture = OpaquePointer(bitPattern: Int(bitPattern: bits))
        let data = context.imageData[key]
        let (viewer, content) = Dialogs.window(title: name, parent: window, width: 960)
        gtk_window_set_default_size(ptr(viewer), 960, 720)

        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(op(scroller), GTK_POLICY_AUTOMATIC, GTK_POLICY_AUTOMATIC)
        let picture = tailscode_picture_for_texture(texture)!
        gtk_widget_set_size_request(
            picture, tailscode_texture_width(texture), tailscode_texture_height(texture))
        gtk_scrolled_window_set_child(op(scroller), picture)
        gtk_widget_set_vexpand(scroller, 1)
        gtk_box_append(ptr(content), scroller)

        let bar = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_box_append(
            ptr(bar),
            Gtk.label(
                "\(tailscode_texture_width(texture))×\(tailscode_texture_height(texture))",
                css: "row-detail", selectable: false))
        let spacer = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        gtk_widget_set_hexpand(spacer, 1)
        gtk_box_append(ptr(bar), spacer)
        if let data {
            let filename = name
            gtk_box_append(
                ptr(bar),
                Gtk.button(Localized.text("Save to Downloads"), css: ["suggested-action"]) {
                    [weak self] in
                    let target = FileManager.default.homeDirectoryForCurrentUser
                        .appendingPathComponent("Downloads", isDirectory: true)
                        .appendingPathComponent(filename)
                    try? FileManager.default.createDirectory(
                        at: target.deletingLastPathComponent(),
                        withIntermediateDirectories: true)
                    let wrote = (try? data.write(to: target)) != nil
                    Gtk.onMain { [weak self] in
                        guard let self else { return }
                        gtk_label_set_text(
                            op(self.statusLabel),
                            wrote
                                ? Localized.text("Saved %@", target.path)
                                : Localized.text("Could not write %@", target.path))
                    }
                })
        }
        gtk_box_append(ptr(content), bar)
        gtk_window_present(ptr(viewer))
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
        let savedChats = SavedChatStore.all()
        let saved = Set(savedChats.map(\.sessionID))
        let unread = SessionSeenStore.unreadEvaluator()
        let needle = filter.lowercased()
        var rows = entries.map {
            SessionRowModel(
                entry: $0, unreachable: unreachable.contains($0.profileName),
                unread: unread($0.session.id, $0.session.updatedAt),
                saved: saved.contains($0.session.id))
        }
        rows += Self.orphanedSavedRows(savedChats, listed: entries)
        visible = rows.filter {
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

    /// A bookmark must still list and explain itself when its server is unreachable, its session
    /// deleted, or its profile removed — the saved list never depends on a live listing. Rows for
    /// chats the listing no longer covers are rebuilt from the bookmark's own snapshot.
    private static func orphanedSavedRows(
        _ savedChats: [SavedChat], listed: [SessionEntry]
    ) -> [SessionRowModel] {
        let listedIDs = Set(listed.map(\.session.id))
        return savedChats.filter { !listedIDs.contains($0.sessionID) }.map { chat in
            let session = AgentSession(
                id: chat.sessionID, agentType: chat.backend, title: chat.displayTitle,
                directory: chat.directory, createdAt: chat.savedAt, updatedAt: chat.updatedAt)
            let entry = SessionEntry(
                profileID: chat.profileID, profileName: chat.profileName,
                host: chat.profileName, backendType: chat.backend, session: session)
            return SessionRowModel(entry: entry, unreachable: true, unread: false, saved: true)
        }
    }

    private func open(_ entry: SessionEntry) {
        guard selectedID != entry.session.id else { return }
        stashDraft()
        selectedID = entry.session.id
        currentEntry = entry
        conversation = nil
        currentBackend = nil
        lastState = nil
        models = []
        commands = []
        chosenModel = nil
        chosenEffort = nil
        turnStartedAt = nil
        context.expanded = []
        context.textures = [:]
        context.imageData = [:]
        context.subagentRows = [:]
        inFlightImages = []
        inFlightSubagents = []
        attachments = []
        pastedImageCount = 0
        renderAttachments()
        clearUnseen()
        if gtk_widget_get_visible(findBar) != 0 { setFindShown(false) }
        restoreDraft(for: entry.session.id)
        streamTask?.cancel()
        showPlaceholder(Localized.text("Connecting…"))
        Gtk.removeChildren(of: pendingBox)
        gtk_widget_set_visible(authBanner, 0)
        gtk_label_set_text(
            op(titleLabel),
            entry.session.hasPlaceholderTitle
                ? Localized.text("New conversation") : entry.session.title)
        refreshPills()
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
                    self?.showPlaceholder(Localized.text("That server is not configured."))
                }
                return
            }
            Gtk.onMain { [weak self] in
                self?.currentBackend = backend
                self?.fileTree.show(directory: entry.session.directory, on: backend)
            }
            self.loadSessionExtras(backend: backend, directory: entry.session.directory)
            let conversation = AgentConversation(
                backend: backend, sessionID: entry.session.id, cache: AppCache.sessionCache)
            self.conversation = conversation
            for await state in await conversation.states() {
                if Task.isCancelled { return }
                let rows = TranscriptRow.rows(for: state.messages)
                Gtk.onMain { [weak self] in
                    self?.apply(state: state, rows: rows)
                }
            }
        }
    }

    /// Everything worth knowing about the session besides its transcript, fetched once per open:
    /// the models the server offers, the commands it resolves, and whether its Claude is signed in.
    private func loadSessionExtras(backend: any CodingAgentBackend, directory: String?) {
        Task { [weak self] in
            let models = (try? await backend.availableModels()) ?? []
            let commands = (try? await backend.availableCommands(directory: directory)) ?? []
            Gtk.onMain { [weak self] in
                guard let self else { return }
                self.models = models
                self.commands = commands
                self.refreshPills()
            }
        }
        if let authenticating = backend as? any AuthenticatingBackend {
            Task { [weak self] in
                guard let auth = try? await authenticating.authStatus() else { return }
                Gtk.onMain { [weak self] in
                    self?.renderAuthBanner(auth, backend: authenticating)
                }
            }
        }
    }

    private func renderAuthBanner(_ auth: ServerAuth, backend: any AuthenticatingBackend) {
        Gtk.removeChildren(of: authBanner)
        guard !auth.loggedIn else {
            gtk_widget_set_visible(authBanner, 0)
            return
        }
        let name = currentEntry?.profileName ?? "server"
        let label = Gtk.label(
            Localized.text("⚠ Claude is signed out on %@ — every turn will refuse until it signs in.", name),
            css: "banner-auth", wrap: true, selectable: false)
        gtk_widget_set_hexpand(label, 1)
        gtk_box_append(ptr(authBanner), label)
        let rootBits = window.map { UInt(bitPattern: $0) } ?? 0
        gtk_box_append(
            ptr(authBanner),
            Gtk.button(Localized.text("Sign in")) { [weak self] in
                let parent = UnsafeMutableRawPointer(bitPattern: rootBits).map {
                    raw -> UnsafeMutablePointer<GtkWidget> in ptr(raw)
                }
                SignInDialog.present(
                    parent: parent, serverName: name, backend: backend
                ) { [weak self] in
                    Gtk.onMain { [weak self] in
                        guard let self else { return }
                        gtk_widget_set_visible(self.authBanner, 0)
                    }
                }
            })
        gtk_widget_set_visible(authBanner, 1)
    }

    private func apply(state: ConversationState, rows: [TranscriptRow]) {
        lastState = state
        let placeholder: String? =
            rows.isEmpty
            ? (state.hasLoadedTranscript
                ? Localized.text("Nothing here yet. Say something.") : Localized.text("Loading…"))
            : nil
        if let placeholder {
            showPlaceholder(placeholder)
        } else {
            applyRows(rows)
        }
        renderPendingCards(state)
        renderGoal(state.goal)
        updateStatus()
        updateTicker(running: state.status == .running || state.compaction?.isRunning == true)
    }

    private func showPlaceholder(_ text: String) {
        Gtk.removeChildren(of: transcriptBox)
        renderedRows = []
        rowWidgets = []
        highlightedRow = 0
        placeholderShown = true
        let label = Gtk.label(text, css: "dim", selectable: false)
        Gtk.margins(label, top: 24, bottom: 24, leading: 4, trailing: 4)
        gtk_box_append(ptr(transcriptBox), label)
    }

    /// The streaming path: everything before the first changed row keeps its widget — and its
    /// disclosure state, its selection, its scroll cost — and only the tail is rebuilt. A token
    /// appended to the last message rebuilds one row, not the conversation.
    private func applyRows(_ rows: [TranscriptRow]) {
        let initialFill = placeholderShown
        if placeholderShown {
            Gtk.removeChildren(of: transcriptBox)
            renderedRows = []
            rowWidgets = []
            placeholderShown = false
        }
        let stick = initialFill || isNearBottom()
        let growth = initialFill || rebuildingInPlace ? 0 : rows.count - renderedRows.count

        var prefix = 0
        while prefix < renderedRows.count, prefix < rows.count, renderedRows[prefix] == rows[prefix] {
            prefix += 1
        }
        for bits in rowWidgets[prefix...] {
            guard let raw = UnsafeMutableRawPointer(bitPattern: bits) else { continue }
            if bits == highlightedRow { highlightedRow = 0 }
            gtk_box_remove(ptr(transcriptBox), ptr(raw) as UnsafeMutablePointer<GtkWidget>)
        }
        rowWidgets.removeSubrange(prefix...)
        for row in rows[prefix...] {
            let widget = row.makeWidget(context: context)
            gtk_box_append(ptr(transcriptBox), widget)
            rowWidgets.append(UInt(bitPattern: widget))
        }
        renderedRows = rows

        if stick {
            scrollToBottom()
        } else {
            noteAppendedWhileScrolledUp(growth)
        }
        if gtk_widget_get_visible(findBar) != 0 { runFind(retarget: false) }
    }

    /// A cache arrival (a decoded picture, a fetched subagent transcript) replays the same rows
    /// through fresh widgets. It is not new content: the unseen counter and the find highlight
    /// must survive it untouched — the highlight as a cleared pointer, never a dangling one.
    private func forceRebuild() {
        guard !placeholderShown else { return }
        clearFindHighlight()
        rebuildingInPlace = true
        defer { rebuildingInPlace = false }
        Gtk.removeChildren(of: transcriptBox)
        let rows = renderedRows
        renderedRows = []
        rowWidgets = []
        applyRows(rows)
    }

    /// What the turn is waiting on, docked where the CLI's prompt would sit: approvals first,
    /// then questions. Cards are few; rebuilding them wholesale on every state is free.
    private func renderPendingCards(_ state: ConversationState) {
        Gtk.removeChildren(of: pendingBox)
        for permission in state.pendingPermissions {
            gtk_box_append(
                ptr(pendingBox),
                PendingCards.permission(permission) { [weak self] decision in
                    self?.respond(to: permission, decision: decision)
                })
        }
        for question in state.pendingQuestions {
            gtk_box_append(
                ptr(pendingBox),
                PendingCards.question(question) { [weak self] answers in
                    self?.answer(question, answers: answers)
                })
        }
        if let compaction = state.compaction, let failure = compaction.failure {
            let card = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 4)
            Gtk.addClass(card, "card")
            gtk_box_append(
                ptr(card),
                Gtk.label(
                    Localized.text("Compaction failed: %@", failure), css: "glyph-error",
                    wrap: true))
            gtk_box_append(ptr(pendingBox), card)
        }
    }

    private func renderGoal(_ goal: SessionGoal?) {
        guard let goal else {
            gtk_widget_set_visible(goalLabel, 0)
            return
        }
        let text: String
        if goal.isMet {
            text = Localized.text("goal met · %@", goal.condition)
        } else if goal.didFail {
            text = Localized.text("goal failed · %@", goal.condition)
        } else {
            text = Localized.text("goal · %@", goal.condition)
        }
        gtk_label_set_text(op(goalLabel), text)
        gtk_widget_set_visible(goalLabel, goal.isActive || goal.didFail ? 1 : 0)
    }

    private func respond(to permission: PermissionRequest, decision: PermissionDecision) {
        guard let conversation else { return }
        Task { try? await conversation.respond(to: permission, decision: decision) }
    }

    /// Claude answers by message, so the answer goes out through the ordinary send path — a
    /// bridge busy with a live turn refuses a side-channel call but queues a message. The card
    /// stops asking immediately either way.
    private func answer(_ question: QuestionRequest, answers: [[String]]) {
        guard let conversation else { return }
        let byMessage = currentBackend?.capabilities.answersQuestionsByMessage == true
        Task {
            if byMessage {
                await conversation.markAnswered(question)
                try? await conversation.send(question.answerMessage(answers))
            } else {
                try? await conversation.answer(question, answers: answers)
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
        if let compaction = state.compaction, compaction.isRunning {
            return Localized.text("Compacting — this takes minutes…")
        }
        if !state.pendingPermissions.isEmpty { return Localized.text("Waiting for your approval — y / a / n") }
        if !state.pendingQuestions.isEmpty { return Localized.text("Waiting for your answer") }
        if state.status == .running { return Localized.text("Working…") }
        return Localized.text("Idle")
    }

    private func updateStatus() {
        guard let state = lastState else { return }
        var text = Self.statusText(for: state)
        let running = state.status == .running || state.compaction?.isRunning == true
        if running {
            if turnStartedAt == nil { turnStartedAt = Date() }
            if let started = turnStartedAt {
                text += " · \(TranscriptRow.clock(Date().timeIntervalSince(started)))"
            }
        } else {
            turnStartedAt = nil
        }
        if running, let tool = runningTool(state) {
            text += " · \(tool)"
        }
        gtk_label_set_text(op(statusLabel), text)
        gtk_button_set_label(
            ptr(sendButton), running ? Localized.text("Queue") : Localized.text("Send"))
        gtk_widget_set_visible(stopButton, running ? 1 : 0)
    }

    private func runningTool(_ state: ConversationState) -> String? {
        for message in state.messages.reversed() {
            for part in message.parts.reversed() {
                if case .tool(let call) = part.kind, call.status == .running {
                    return call.name
                }
            }
            if message.role == .user { break }
        }
        return nil
    }

    /// A once-a-second nudge while a turn runs, so elapsed time moves without any state event.
    private func updateTicker(running: Bool) {
        if running, tickerTask == nil {
            tickerTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    Gtk.onMain { [weak self] in self?.updateStatus() }
                }
            }
        } else if !running {
            tickerTask?.cancel()
            tickerTask = nil
        }
    }

    private func refreshPills() {
        let entry = currentEntry
        let destination = [
            entry?.profileName,
            entry?.session.directory.map { URL(fileURLWithPath: $0).lastPathComponent },
        ].compactMap { $0 }.joined(separator: " · ")
        gtk_label_set_text(op(destinationLabel), destination)

        let modelText = chosenModel?.modelID ?? entry?.session.model ?? Localized.text("model")
        if let modelButton { gtk_menu_button_set_label(op(modelButton), modelText) }
        let effortText = chosenEffort ?? entry?.session.reasoningEffort ?? Localized.text("effort")
        if let effortButton { gtk_menu_button_set_label(op(effortButton), effortText) }
    }

    private func modelRows() -> [(String, String?, @Sendable () -> Void)] {
        guard !models.isEmpty else {
            return [(Localized.text("This server lists no models"), nil, {})]
        }
        var rows: [(String, String?, @Sendable () -> Void)] = [
            (Localized.text("Server default"), nil, { [weak self] in
                Gtk.onMain { [weak self] in
                    self?.chosenModel = nil
                    self?.refreshPills()
                }
            })
        ]
        for model in models {
            let selection = model.selection
            rows.append(
                (model.name, model.providerID, { [weak self] in
                    Gtk.onMain { [weak self] in
                        self?.chosenModel = selection
                        self?.refreshPills()
                    }
                }))
        }
        return rows
    }

    private func effortRows() -> [(String, String?, @Sendable () -> Void)] {
        let options = currentBackend?.reasoningEffortOptions ?? []
        guard !options.isEmpty else {
            return [(Localized.text("This agent has no effort control"), nil, {})]
        }
        var rows: [(String, String?, @Sendable () -> Void)] = [
            (Localized.text("Server default"), nil, { [weak self] in
                Gtk.onMain { [weak self] in
                    self?.chosenEffort = nil
                    self?.refreshPills()
                }
            })
        ]
        for option in options {
            rows.append(
                (option, nil, { [weak self] in
                    Gtk.onMain { [weak self] in
                        self?.chosenEffort = option
                        self?.refreshPills()
                    }
                }))
        }
        return rows
    }

    /// On the server first — what this machine will actually resolve — then what the app itself
    /// can do. Picking one drops it into the composer so arguments can follow; `/compact` keeps
    /// its preflight.
    private func commandRows() -> [(String, String?, @Sendable () -> Void)] {
        var rows: [(String, String?, @Sendable () -> Void)] = []
        rows.append(
            ("/compact", Localized.text("Trade the transcript for a summary — with a preflight"),
             { [weak self] in Gtk.onMain { [weak self] in self?.presentCompactPreflight() } }))
        rows.append(
            ("/goal", Localized.text("Set a standing goal the agent pursues"),
             { [weak self] in Gtk.onMain { [weak self] in self?.insertIntoComposer("/goal ") } }))
        for command in commands where command.name != "compact" && command.name != "goal" {
            let insertion = command.takesArguments ? "/\(command.name) " : "/\(command.name)"
            rows.append(
                ("/\(command.name)", command.details.isEmpty ? command.source.rawValue : command.details,
                 { [weak self] in Gtk.onMain { [weak self] in self?.insertIntoComposer(insertion) } }))
        }
        return rows
    }

    private func actionRows() -> [(String, String?, @Sendable () -> Void)] {
        guard let entry = currentEntry else { return [] }
        let capabilities = currentBackend?.capabilities
        var rows: [(String, String?, @Sendable () -> Void)] = []

        let saved = SavedChatStore.contains(entry)
        rows.append(
            (saved ? Localized.text("Unsave") : Localized.text("Save"),
             Localized.text("A saved chat lists itself even when its server is unreachable"),
             { [weak self] in Gtk.onMain { [weak self] in self?.toggleSaved() } }))

        if capabilities?.supportsRenaming == true {
            rows.append(
                (Localized.text("Rename…"), nil,
                 { [weak self] in Gtk.onMain { [weak self] in self?.presentRename() } }))
        }
        if capabilities?.supportsForking == true {
            rows.append(
                (Localized.text("Fork"),
                 Localized.text("A new session with this history, for a different direction"),
                 { [weak self] in Gtk.onMain { [weak self] in self?.forkCurrent() } }))
        }
        if capabilities?.supportsCompaction == true {
            rows.append(
                (Localized.text("Compact…"),
                 Localized.text("Irreversible, takes minutes"),
                 { [weak self] in Gtk.onMain { [weak self] in self?.presentCompactPreflight() } }))
        }
        if capabilities?.supportsClearing == true {
            rows.append(
                (Localized.text("Clear…"), Localized.text("Empty the conversation in place"),
                 { [weak self] in Gtk.onMain { [weak self] in self?.presentClear() } }))
        }
        rows.append(
            (Localized.text("Delete…"), Localized.text("Remove the session from its server"),
             { [weak self] in Gtk.onMain { [weak self] in self?.presentDelete() } }))
        return rows
    }

    private func presentNewChat() {
        Task { [weak self] in
            let profiles = await ServerDirectory.shared.profiles()
            Gtk.onMain { [weak self] in
                guard let self else { return }
                guard !profiles.isEmpty else {
                    self.presentServers()
                    return
                }
                var seen = Set<String>()
                let recents = self.entries.compactMap(\.session.directory).filter {
                    seen.insert($0).inserted
                }
                Dialogs.newChat(
                    parent: self.window, profiles: profiles, recentDirectories: recents
                ) { [weak self] profile, directory in
                    self?.createChat(on: profile, directory: directory)
                }
            }
        }
    }

    private func createChat(on profile: ConnectionProfile, directory: String?) {
        Task { [weak self] in
            guard let backend = await ServerDirectory.shared.backend(for: profile) else { return }
            do {
                let session = try await backend.createSession(title: nil, directory: directory)
                let entry = SessionEntry(
                    profileID: profile.id, profileName: profile.name,
                    host: profile.baseURL.host ?? profile.name,
                    backendType: profile.backend, session: session)
                await self?.refresh()
                Gtk.onMain { [weak self] in self?.open(entry) }
            } catch {
                Gtk.onMain { [weak self] in
                    guard let self else { return }
                    gtk_label_set_text(
                        op(self.statusLabel),
                        Localized.text("Could not start a session: %@", "\(error)"))
                }
            }
        }
    }

    private func presentServers() {
        let manager = ServerManager { [weak self] in
            Task { [weak self] in await self?.refresh() }
        }
        manager.present(parent: window)
    }

    private func presentRename() {
        guard let entry = currentEntry, let backend = currentBackend else { return }
        let sessionID = entry.session.id
        Dialogs.prompt(
            title: Localized.text("Rename this conversation"), body: nil,
            placeholder: Localized.text("Title"),
            initial: entry.session.hasPlaceholderTitle ? "" : entry.session.title,
            confirmLabel: Localized.text("Rename"), parent: window
        ) { [weak self] title in
            guard !title.isEmpty else { return }
            Task { [weak self] in
                try? await backend.renameSession(sessionID, title: title)
                await self?.refresh()
                Gtk.onMain { [weak self] in
                    guard let self else { return }
                    gtk_label_set_text(op(self.titleLabel), title)
                }
            }
        }
    }

    private func forkCurrent() {
        guard let entry = currentEntry, let backend = currentBackend else { return }
        let sessionID = entry.session.id
        Task { [weak self] in
            guard let session = try? await backend.forkSession(sessionID) else { return }
            let forked = SessionEntry(
                profileID: entry.profileID, profileName: entry.profileName, host: entry.host,
                backendType: entry.backendType, session: session)
            await self?.refresh()
            Gtk.onMain { [weak self] in self?.open(forked) }
        }
    }

    private func presentCompactPreflight(initialInstruction: String = "") {
        guard let conversation else { return }
        Dialogs.compactPreflight(
            parent: window, initialInstruction: initialInstruction
        ) { instruction in
            Task { try? await conversation.compact(instructions: instruction) }
        }
    }

    private func presentClear() {
        guard let entry = currentEntry, let backend = currentBackend else { return }
        let sessionID = entry.session.id
        Dialogs.confirm(
            title: Localized.text("Clear this conversation?"),
            body: Localized.text("Everything in it goes away, on the server, for every device."),
            confirmLabel: Localized.text("Clear"), parent: window
        ) { [weak self] in
            Task { [weak self] in
                try? await backend.clearConversation(sessionID)
                await self?.refresh()
            }
        }
    }

    private func presentDelete() {
        guard let entry = currentEntry, let backend = currentBackend else { return }
        let sessionID = entry.session.id
        Dialogs.confirm(
            title: Localized.text("Delete this conversation?"),
            body: Localized.text(
                "It is removed from %@ for every device. A saved copy on this machine survives.",
                entry.profileName),
            confirmLabel: Localized.text("Delete"), parent: window
        ) { [weak self] in
            Task { [weak self] in
                try? await backend.deleteSession(sessionID)
                Gtk.onMain { [weak self] in
                    guard let self else { return }
                    self.selectedID = nil
                    self.currentEntry = nil
                }
                await self?.refresh()
            }
        }
    }

    private func toggleSaved() {
        guard let entry = currentEntry else { return }
        _ = SavedChatStore.toggle(entry)
        renderSidebar()
    }

    private func fetchImage(_ reference: FileReference, key: String) {
        guard let backend = currentBackend, !inFlightImages.contains(key) else { return }
        inFlightImages.insert(key)
        Task { [weak self] in
            guard let data = try? await backend.attachmentData(reference) else { return }
            Gtk.onMain { [weak self] in
                guard let self else { return }
                let texture = data.withUnsafeBytes { buffer in
                    tailscode_texture_from_bytes(buffer.baseAddress, gsize(buffer.count))
                }
                guard let texture else { return }
                self.context.textures[key] = UInt(bitPattern: texture)
                self.context.imageData[key] = data
                self.forceRebuild()
            }
        }
    }

    private func fetchSubagent(_ call: ToolCall) {
        guard let backend = currentBackend, let entry = currentEntry,
            !inFlightSubagents.contains(call.id)
        else { return }
        inFlightSubagents.insert(call.id)
        let sessionID = entry.session.id
        Task { [weak self] in
            let agents = (try? await backend.subagents(for: sessionID)) ?? []
            let match = agents.first { $0.toolUseID == call.id }
            let messages: [ChatMessage]
            if let match {
                messages = (try? await backend.subagentMessages(
                    sessionID: sessionID, agentID: match.id)) ?? []
            } else {
                messages = []
            }
            let rows = TranscriptRow.rows(for: messages)
            Gtk.onMain { [weak self] in
                guard let self else { return }
                self.context.subagentRows[call.id] = rows
                self.forceRebuild()
            }
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
            let awaiting = !(self.lastState?.pendingPermissions.isEmpty ?? true)
            let action = Keymap.normal(
                keyval: keyval, state: state, pending: self.pending, awaitingApproval: awaiting)
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
        case .leaveInsert:
            if gtk_widget_get_visible(findBar) != 0 { setFindShown(false) }
            gtk_widget_grab_focus(sidebarList)
            setHelp(false)
        case .search: gtk_widget_grab_focus(searchEntry)
        case .send: sendFromComposer()
        case .stop: stopTurn()
        case .toggleHelp: setHelp(!helpShown)
        case .reload: Task { [weak self] in await self?.refresh() }
        case .allowOnce: respondToFirstPermission(.once)
        case .allowAlways: respondToFirstPermission(.always)
        case .deny: respondToFirstPermission(.reject)
        case .newChat: presentNewChat()
        case .toggleSaved: toggleSaved()
        case .findInConversation: setFindShown(true)
        case .commandPalette:
            if let commandButton { gtk_menu_button_popup(op(commandButton)) }
        }
        return true
    }

    private func respondToFirstPermission(_ decision: PermissionDecision) {
        guard let permission = lastState?.pendingPermissions.first else { return }
        respond(to: permission, decision: decision)
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

    private func isNearBottom() -> Bool {
        guard let scroller = transcriptScroller,
            let adjustment = gtk_scrolled_window_get_vadjustment(op(scroller))
        else { return true }
        let value = gtk_adjustment_get_value(adjustment)
        let ceiling = gtk_adjustment_get_upper(adjustment)
            - gtk_adjustment_get_page_size(adjustment)
        return value >= ceiling - 60
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
        gtk_widget_grab_focus(entryView)
    }

    private func composerText() -> String {
        let buffer = gtk_text_view_get_buffer(ptr(entryView))
        var start = GtkTextIter()
        var end = GtkTextIter()
        gtk_text_buffer_get_bounds(buffer, &start, &end)
        guard let raw = gtk_text_buffer_get_text(buffer, &start, &end, 0) else { return "" }
        defer { g_free(raw) }
        return String(cString: raw)
    }

    /// Half-typed prompts follow their conversation, not the window: switching chats stashes what
    /// was in the composer and restores whatever was stashed for the chat being opened.
    private func stashDraft() {
        guard let selectedID else { return }
        let text = composerText()
        let key = "tailscode.draft.\(selectedID)"
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(text, forKey: key)
        }
    }

    private func restoreDraft(for sessionID: String) {
        let draft = UserDefaults.standard.string(forKey: "tailscode.draft.\(sessionID)") ?? ""
        gtk_text_buffer_set_text(gtk_text_view_get_buffer(ptr(entryView)), draft, -1)
    }

    private func sendFromComposer() {
        let text = composerText().trimmingCharacters(in: .whitespacesAndNewlines)
        let outgoing = attachments
        guard !text.isEmpty || !outgoing.isEmpty, let conversation else { return }
        let buffer = gtk_text_view_get_buffer(ptr(entryView))
        gtk_text_buffer_set_text(buffer, "", 0)
        if let selectedID {
            UserDefaults.standard.removeObject(forKey: "tailscode.draft.\(selectedID)")
        }
        if handleSlashCommand(text) { return }
        attachments = []
        renderAttachments()
        let model = chosenModel
        let effort = chosenEffort
        Task {
            try? await conversation.send(
                text, model: model, reasoningEffort: effort,
                attachments: outgoing.map(\.prompt))
        }
    }

    private func attachRows() -> [(String, String?, @Sendable () -> Void)] {
        guard currentBackend?.capabilities.supportsAttachments != false else {
            return [(Localized.text("This server does not take attachments"), nil, {})]
        }
        return [
            (Localized.text("Attach files…"), Localized.text("Up to 8 MB each"),
             { [weak self] in Gtk.onMain { [weak self] in self?.pickAttachments() } }),
            (Localized.text("Paste image"), Localized.text("From the clipboard, as PNG"),
             { [weak self] in Gtk.onMain { [weak self] in self?.pasteImageAttachment() } }),
        ]
    }

    private func pickAttachments() {
        Gtk.openFiles(parent: window) { [weak self] paths in
            guard let self else { return }
            for path in paths {
                switch AttachmentIntake.read(path: path) {
                case .success(let attachment):
                    self.attachments.append(attachment)
                case .failure(let refusal):
                    gtk_label_set_text(op(self.statusLabel), refusal.message)
                }
            }
            self.renderAttachments()
        }
    }

    private func pasteImageAttachment() {
        Gtk.readClipboardImage { [weak self] data in
            guard let self else { return }
            guard let data else {
                gtk_label_set_text(
                    op(self.statusLabel), Localized.text("The clipboard holds no picture."))
                return
            }
            guard data.count <= AttachmentIntake.byteCap else {
                gtk_label_set_text(
                    op(self.statusLabel),
                    Localized.text(
                        "That picture is %@ — the cap is 8 MB",
                        AttachmentIntake.sizeText(data.count)))
                return
            }
            self.pastedImageCount += 1
            self.attachments.append(
                PendingAttachment(
                    name: "pasted-\(self.pastedImageCount).png", mime: "image/png", data: data))
            self.renderAttachments()
        }
    }

    private func renderAttachments() {
        Gtk.removeChildren(of: attachmentsBox)
        gtk_widget_set_visible(attachmentsBox, attachments.isEmpty ? 0 : 1)
        for attachment in attachments {
            let title = "\(attachment.name) · \(AttachmentIntake.sizeText(attachment.data.count))  ✕"
            let id = attachment.id
            gtk_box_append(
                ptr(attachmentsBox),
                Gtk.button(title, css: ["chip"]) { [weak self] in
                    guard let self else { return }
                    self.attachments.removeAll { $0.id == id }
                    self.renderAttachments()
                })
        }
    }

    private func jumpToBottom() {
        scrollToBottom()
        clearUnseen()
    }

    private func clearUnseen() {
        unseenRows = 0
        gtk_widget_set_visible(jumpButton, 0)
    }

    private func noteAppendedWhileScrolledUp(_ count: Int) {
        guard count > 0 else { return }
        unseenRows += count
        gtk_button_set_label(ptr(jumpButton), "↓ \(unseenRows)")
        gtk_widget_set_visible(jumpButton, 1)
    }

    private func setFindShown(_ shown: Bool) {
        gtk_widget_set_visible(findBar, shown ? 1 : 0)
        if shown {
            gtk_widget_grab_focus(findEntry)
            runFind(retarget: false)
        } else {
            gtk_editable_set_text(op(findEntry), "")
            clearFindHighlight()
            findMatches = []
            gtk_label_set_text(op(findCountLabel), "")
            gtk_widget_grab_focus(transcriptBox)
        }
    }

    private func findQuery() -> String {
        guard let raw = gtk_editable_get_text(op(findEntry)) else { return "" }
        return String(cString: raw)
    }

    private func runFind(retarget: Bool) {
        let needle = findQuery().lowercased()
        clearFindHighlight()
        guard !needle.isEmpty else {
            findMatches = []
            gtk_label_set_text(op(findCountLabel), "")
            return
        }
        findMatches = renderedRows.indices.filter {
            renderedRows[$0].searchText.lowercased().contains(needle)
        }
        if retarget { findCursor = 0 }
        if findCursor >= findMatches.count { findCursor = max(0, findMatches.count - 1) }
        updateFindCount()
        guard !findMatches.isEmpty else { return }
        applyFindHighlight(scroll: retarget)
    }

    private func stepFind(by delta: Int) {
        guard !findMatches.isEmpty else { return }
        let count = findMatches.count
        findCursor = ((findCursor + delta) % count + count) % count
        updateFindCount()
        applyFindHighlight(scroll: true)
    }

    private func updateFindCount() {
        gtk_label_set_text(
            op(findCountLabel),
            findMatches.isEmpty
                ? Localized.text("No matches") : "\(findCursor + 1)/\(findMatches.count)")
    }

    /// Marks the current match, and on an explicit jump scrolls it to the upper third so the eye
    /// lands on the hit rather than hunting for it. The offset is measured against the widget the
    /// adjustment actually scrolls — the padded canvas — not the transcript box inside it.
    private func applyFindHighlight(scroll: Bool) {
        guard findMatches.indices.contains(findCursor) else { return }
        let index = findMatches[findCursor]
        guard index < rowWidgets.count,
            let raw = UnsafeMutableRawPointer(bitPattern: rowWidgets[index])
        else { return }
        clearFindHighlight()
        let widget: UnsafeMutablePointer<GtkWidget> = ptr(raw)
        Gtk.addClass(widget, "find-hit")
        highlightedRow = rowWidgets[index]
        guard scroll else { return }
        let offset = tailscode_widget_offset_y(widget, canvasBox ?? transcriptBox)
        guard offset >= 0, let scroller = transcriptScroller,
            let adjustment = gtk_scrolled_window_get_vadjustment(op(scroller))
        else { return }
        let page = gtk_adjustment_get_page_size(adjustment)
        let ceiling = max(0, gtk_adjustment_get_upper(adjustment) - page)
        gtk_adjustment_set_value(adjustment, min(max(0, offset - page * 0.3), ceiling))
    }

    private func clearFindHighlight() {
        guard highlightedRow != 0,
            let raw = UnsafeMutableRawPointer(bitPattern: highlightedRow)
        else { return }
        gtk_widget_remove_css_class(ptr(raw) as UnsafeMutablePointer<GtkWidget>, "find-hit")
        highlightedRow = 0
    }

    /// Quota is account state, not session state: polled on its own slow cadence and rendered in
    /// the sidebar footer, the way the phone keeps it on the Home board.
    private func startUsagePolling() {
        usageTask = Task { [weak self] in
            while !Task.isCancelled {
                let settled = await self?.refreshUsage() ?? true
                try? await Task.sleep(for: .seconds(settled ? 120 : 15))
            }
        }
    }

    /// False while the profile list has not been seeded yet — the poll retries quickly then,
    /// rather than leaving the footer empty for its whole slow cadence after a cold start.
    private func refreshUsage() async -> Bool {
        let profiles = await ServerDirectory.shared.profiles()
        guard !profiles.isEmpty else { return false }
        var quotas: [(String, UsageQuota)] = []
        for profile in profiles {
            guard let backend = await ServerDirectory.shared.backend(for: profile),
                let quota = (try? await backend.usageQuota()) ?? nil
            else { continue }
            quotas.append((profile.name, quota))
        }
        let snapshot = quotas
        Gtk.onMain { [weak self] in self?.renderUsage(snapshot) }
        return true
    }

    private func renderUsage(_ quotas: [(String, UsageQuota)]) {
        Gtk.removeChildren(of: usageBox)
        gtk_widget_set_visible(usageBox, quotas.isEmpty ? 0 : 1)
        for (name, quota) in quotas {
            gtk_box_append(
                ptr(usageBox),
                Gtk.label(
                    "\(name) · \(quota.providerName)", css: "section-header", selectable: false))
            for gauge in quota.gauges {
                let fraction = min(max(gauge.fraction, 0), 1)
                let filled = Int((fraction * 10).rounded())
                let bar = String(repeating: "▰", count: filled)
                    + String(repeating: "▱", count: 10 - filled)
                var line = "\(gauge.label)  \(bar) \(Int((fraction * 100).rounded()))%"
                if let resets = gauge.resetsAt, gauge.trustedReset {
                    line += " · " + Localized.text("resets in %@", Self.countdown(to: resets))
                }
                let css = fraction > 0.85 ? "gauge-danger" : fraction >= 0.6 ? "gauge-warn" : "gauge-ok"
                gtk_box_append(ptr(usageBox), Gtk.label(line, css: css, selectable: false))
            }
        }
    }

    private static func countdown(to date: Date) -> String {
        let interval = date.timeIntervalSinceNow
        guard interval > 0 else { return Localized.text("moments") }
        let hours = Int(interval) / 3600
        let minutes = (Int(interval) % 3600) / 60
        return hours > 0 ? "\(hours)h \(minutes)m" : "\(minutes)m"
    }

    /// A typed slash command goes where the palette would send it: `/compact` to its preflight,
    /// a known server command to the command route when the server wants one, and anything
    /// unknown out as plain text — the server is the authority on its own grammar.
    private func handleSlashCommand(_ text: String) -> Bool {
        guard text.hasPrefix("/") else { return false }
        let name = String(text.dropFirst().prefix(while: { !$0.isWhitespace }))
        let arguments = String(text.dropFirst(1 + name.count)).trimmingCharacters(
            in: .whitespaces)
        if name == "compact" {
            presentCompactPreflight(initialInstruction: arguments)
            return true
        }
        guard let command = commands.first(where: { $0.name == name }),
            let conversation
        else { return false }
        if currentBackend?.resolvesCommandsFromPromptText == true { return false }
        Task {
            try? await conversation.run(command, arguments: arguments.isEmpty ? nil : arguments)
        }
        return true
    }
}
