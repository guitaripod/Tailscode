import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

/// The chat list: every conversation on every configured server, grouped LIVE NOW / SAVED /
/// RECENT, filterable, archivable — the Linux sidebar's semantics spoken through an NSTableView
/// kept transparent over the system sidebar glass.
///
/// The table is a pure function of `rows`, and every store is consulted exactly once per
/// `render()` pass, so a row can never disagree with the stores it summarises. Data arrives three
/// ways, fastest first: the disk cache paints before the first byte crosses the tailnet, the
/// 10-second poll keeps reachability honest, and a proto-2 bridge pushes changes the moment they
/// happen.
@MainActor
final class SidebarViewController: NSViewController {
    var onOpen: ((SessionEntry, any CodingAgentBackend) -> Void)?
    var onNotice: ((String) -> Void)?
    var onToast: ((String) -> Void)?

    private(set) var showingArchive = false

    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let rowMenu = NSMenu()
    private let usageFooter = UsageFooterView()

    private var entries: [SessionEntry] = []
    private var unreachable: [String] = []
    private var visible: [SessionRowModel] = []
    private var rows: [SidebarRow] = []
    /// Sessions whose delete is confirmed but not yet acknowledged by the server. Every listing —
    /// the 10-second refresh, the session-list stream, a stale request already in flight — keeps
    /// reporting the session until the delete lands, and each report would resurrect the row; the
    /// tombstone outlives them all and is lifted only once the post-delete refresh has
    /// reconciled, or the delete failed and the row should genuinely return.
    private var pendingDeletes: Set<String> = []
    /// A chat created a heartbeat ago is kept in the list by hand until the server's own listing
    /// carries it — a bridge that answers from a sweep a second old would otherwise blink the
    /// row away.
    private var freshlyCreated: SessionEntry?
    private var sidebarLimit = 60
    private var filter = ""
    private var cursor = 0
    private var selectedID: String?
    private var lastSidebar: ([SessionRowModel], [String], String, String)?
    private var refreshTask: Task<Void, Never>?
    private var listStreamTasks: [Task<Void, Never>] = []
    private var suppressSelectionSync = false
    private var menuModel: SessionRowModel?
    private var menuBackend: (any CodingAgentBackend)?

    override func loadView() {
        let container = NSView()

        searchField.placeholderString = Localized.text("Filter chats")
        searchField.sendsWholeSearchString = false
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(filterChanged)
        searchField.translatesAutoresizingMaskIntoConstraints = false

        tableView.headerView = nil
        tableView.style = .sourceList
        tableView.backgroundColor = .clear
        tableView.usesAutomaticRowHeights = true
        tableView.allowsMultipleSelection = false
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.action = #selector(rowClicked)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("main"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        rowMenu.delegate = self
        tableView.menu = rowMenu

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(searchField)
        container.addSubview(scrollView)
        container.addSubview(usageFooter)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(
                equalTo: container.safeAreaLayoutGuide.topAnchor, constant: MacTheme.Spacing.s),
            searchField.leadingAnchor.constraint(
                equalTo: container.leadingAnchor, constant: MacTheme.Spacing.s),
            searchField.trailingAnchor.constraint(
                equalTo: container.trailingAnchor, constant: -MacTheme.Spacing.s),
            scrollView.topAnchor.constraint(
                equalTo: searchField.bottomAnchor, constant: MacTheme.Spacing.xs),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(
                equalTo: usageFooter.topAnchor, constant: -MacTheme.Spacing.xs),
            usageFooter.leadingAnchor.constraint(
                equalTo: container.leadingAnchor, constant: MacTheme.Spacing.m),
            usageFooter.trailingAnchor.constraint(
                equalTo: container.trailingAnchor, constant: -MacTheme.Spacing.m),
            usageFooter.bottomAnchor.constraint(
                equalTo: container.bottomAnchor, constant: -MacTheme.Spacing.s),
        ])
        view = container
    }

    /// The quota picture at a glance, fed by the hub's slow poll — account state under the chat
    /// list, the way the phone keeps it on the Home board.
    func renderUsage(_ quotas: [(String, UsageQuota)]) {
        usageFooter.render(quotas)
    }

    /// Rows pick their fonts up at configure time, so a reload is the whole zoom.
    func applyUIScale() {
        lastSidebar = nil
        render()
    }

    /// The chats you had are on screen before the first byte crosses the tailnet — a server that
    /// takes fifteen seconds to list its sessions must not mean fifteen seconds of empty window.
    /// Liveness is stripped from the cache, so nothing here can claim to be running.
    override func viewDidLoad() {
        super.viewDidLoad()
        let cached = SessionListCache.load()
        if !cached.isEmpty { applyEntries(cached, unreachable: []) }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        startRefreshing()
        startListStreamsIfNeeded()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        refreshTask?.cancel()
        refreshTask = nil
    }

    func refresh() async {
        ServerDirectory.shared.reload()
        let (fresh, down) = await ServerDirectory.shared.entries()
        if !fresh.isEmpty { SessionListCache.save(fresh) }
        SavedChatStore.reconcile(with: fresh)
        applyEntries(fresh, unreachable: down)
    }

    /// The directories chats already work in, newest first — what the new-chat sheet offers, so
    /// + then Enter starts a conversation where the last one worked.
    var recentDirectories: [String] {
        var seen = Set<String>()
        return entries.compactMap(\.session.directory).filter { seen.insert($0).inserted }
    }

    /// A chat created a heartbeat ago: seeded into the list by hand and opened on the spot,
    /// because a bridge that answers `GET /sessions` from a sweep a second old would otherwise
    /// blink the row away while the person is already typing into it.
    func noteCreated(_ entry: SessionEntry) {
        if !entries.contains(where: {
            $0.profileID == entry.profileID && $0.session.id == entry.session.id
        }) {
            entries.insert(entry, at: 0)
        }
        lastSidebar = nil
        render()
        open(entry, freshlyCreated: true)
    }

    /// A notification tap arrives here with only an id — refreshing first when the listing does
    /// not carry it yet.
    func open(withID id: String) {
        if let entry = entries.first(where: { $0.session.id == id }) {
            open(entry)
            return
        }
        Task { [weak self] in
            await self?.refresh()
            guard let self, let entry = self.entries.first(where: { $0.session.id == id })
            else { return }
            self.open(entry)
        }
    }

    func open(_ entry: SessionEntry, freshlyCreated: Bool = false) {
        guard selectedID != entry.session.id else { return }
        self.freshlyCreated = freshlyCreated ? entry : nil
        selectedID = entry.session.id
        SessionSeenStore.markSeen(entry.session.id)
        render()
        scrollSelectionIntoView()
        guard
            let profile = ServerDirectory.shared.profiles.first(where: {
                $0.id == entry.profileID
            }), let backend = ServerDirectory.shared.backend(for: profile)
        else {
            onNotice?(Localized.text("That server is not configured."))
            return
        }
        onOpen?(entry, backend)
    }

    func move(by delta: Int) {
        guard !visible.isEmpty else { return }
        cursor = max(0, min(visible.count - 1, cursor + delta))
        if cursor >= sidebarLimit {
            sidebarLimit = cursor + 60
            lastSidebar = nil
        }
        openCursor()
    }

    func selectFirst() {
        cursor = 0
        openCursor()
    }

    func selectLast() {
        cursor = max(0, visible.count - 1)
        openCursor()
    }

    func openCursor() {
        guard cursor < visible.count else { return }
        open(visible[cursor].entry)
    }

    func focusFilter() {
        view.window?.makeFirstResponder(searchField)
    }

    func takeFocus() {
        view.window?.makeFirstResponder(tableView)
    }

    func toggleSaved(_ entry: SessionEntry) {
        SavedChatStore.toggle(entry)
        render()
    }

    func toggleArchived(_ entry: SessionEntry) {
        ArchivedChatStore.toggle(profileID: entry.profileID, sessionID: entry.session.id)
        render()
    }

    func toggleUnread(_ entry: SessionEntry) {
        let unread = SessionSeenStore.unreadEvaluator()(entry.session.id, entry.session.updatedAt)
        if unread {
            SessionSeenStore.markSeen(entry.session.id)
        } else {
            SessionSeenStore.markUnread(entry.session.id, updatedAt: entry.session.updatedAt)
        }
        render()
    }

    func setArchiveShown(_ shown: Bool) {
        guard showingArchive != shown else { return }
        showingArchive = shown
        cursor = 0
        lastSidebar = nil
        render()
        if tableView.numberOfRows > 0 { tableView.scrollRowToVisible(0) }
    }

    func presentRename(entry: SessionEntry, backend: any CodingAgentBackend) {
        let sessionID = entry.session.id
        MacDialogs.prompt(
            on: view.window,
            title: Localized.text("Rename this conversation"),
            placeholder: Localized.text("Title"),
            initial: entry.session.hasPlaceholderTitle ? "" : entry.session.title,
            confirmLabel: Localized.text("Rename")
        ) { [weak self] title in
            guard !title.isEmpty else { return }
            Task { [weak self] in
                try? await backend.renameSession(sessionID, title: title)
                await self?.refresh()
            }
        }
    }

    /// Optimistic on confirm: the row disappears and the next chat opens before the server has
    /// answered — the person already decided, and the round trip is not theirs to wait for. The
    /// refresh behind the request reconciles either way, so a delete the server refused simply
    /// puts the row back, with a notice saying why.
    func presentDelete(entry: SessionEntry, backend: any CodingAgentBackend) {
        MacDialogs.confirm(
            on: view.window,
            title: Localized.text("Delete this conversation?"),
            body: Localized.text(
                "It is removed from %@ for every device. A saved copy on this machine survives.",
                entry.profileName),
            confirmLabel: Localized.text("Delete")
        ) { [weak self] in
            self?.deleteOptimistically(entry, backend: backend)
        }
    }

    func fork(entry: SessionEntry, backend: any CodingAgentBackend) {
        Task { [weak self] in
            guard let session = try? await backend.forkSession(entry.session.id) else { return }
            let forked = SessionEntry(
                profileID: entry.profileID, profileName: entry.profileName, host: entry.host,
                backendType: entry.backendType, session: session)
            await self?.refresh()
            self?.open(forked)
        }
    }

    private func startRefreshing() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    /// A proto-2 bridge pushes list changes the moment they happen; the 10-second poll survives
    /// only as reachability detection and as the whole story for older servers.
    private func startListStreamsIfNeeded() {
        guard listStreamTasks.isEmpty else { return }
        for profile in ServerDirectory.shared.profiles {
            guard let backend = ServerDirectory.shared.backend(for: profile),
                let streaming = backend as? SessionListStreaming
            else { continue }
            listStreamTasks.append(
                Task { [weak self] in
                    guard let changes = await streaming.sessionListChanges() else { return }
                    for await change in changes {
                        guard let self, !Task.isCancelled else { return }
                        self.applyListChange(change, profile: profile)
                    }
                })
        }
    }

    private func applyListChange(_ change: SessionListChange, profile: ConnectionProfile) {
        switch change {
        case .upsert(let session):
            let entry = SessionEntry(
                profileID: profile.id, profileName: profile.name,
                host: profile.baseURL.host ?? profile.name,
                backendType: profile.backend, session: session)
            var next = entries.filter {
                !($0.profileID == profile.id && $0.session.id == session.id)
            }
            next.append(entry)
            next.sort { $0.session.updatedAt > $1.session.updatedAt }
            entries = next
            if !next.isEmpty { SessionListCache.save(next) }
            render()
        case .remove(let id):
            entries.removeAll { $0.profileID == profile.id && $0.session.id == id }
            render()
        case .invalidated:
            Task { [weak self] in await self?.refresh() }
        }
    }

    /// Opens the conversation that was open last, not merely the newest one: reopening where you
    /// were is the difference between a window that restores and a window that resets.
    private func applyEntries(_ entries: [SessionEntry], unreachable: [String]) {
        self.entries = entries
        self.unreachable = unreachable
        if let fresh = freshlyCreated {
            if entries.contains(where: { $0.session.id == fresh.session.id }) {
                freshlyCreated = nil
            } else {
                self.entries.insert(fresh, at: 0)
            }
        }
        render()
        guard selectedID == nil, !entries.isEmpty else { return }
        let remembered = UserDefaults.standard.string(forKey: "tailscode.lastSession")
            .flatMap { id in entries.first { $0.session.id == id } }
        open(remembered ?? entries[0])
    }

    /// Rebuilding the whole table is what the 10-second refresh would do whether or not anything
    /// changed — so nothing is touched unless what the list would say actually differs from what
    /// it says now.
    private func render() {
        let savedChats = SavedChatStore.all()
        let saved = Set(savedChats.map(\.sessionID))
        let unread = SessionSeenStore.unreadEvaluator()
        let needle = filter.lowercased()
        var models = entries.filter { !pendingDeletes.contains($0.session.id) }.map {
            SessionRowModel(
                entry: $0,
                unreachable: unreachable.contains(
                    ServerLabel.display(name: $0.profileName, backend: $0.backendType)),
                unread: unread($0.session.id, $0.session.updatedAt),
                saved: saved.contains($0.session.id))
        }
        models += Self.orphanedSavedRows(savedChats, listed: entries)
        MacNotifier.shared.observeListing(
            models.map {
                ActivityObservation(
                    profileID: $0.entry.profileID, sessionID: $0.entry.session.id,
                    title: $0.title, isActive: $0.entry.session.isActive == true)
            },
            openSessionID: selectedID)
        let archivedKeys = ArchivedChatStore.all()
        let isArchived: (SessionRowModel) -> Bool = {
            archivedKeys.contains(ArchivedChatStore.key($0.entry.profileID, $0.entry.session.id))
        }
        let archivedTotal = models.filter(isArchived).count
        let matching = models.filter {
            needle.isEmpty || $0.title.lowercased().contains(needle)
                || $0.detail.lowercased().contains(needle)
        }
        let active = matching.filter {
            !isArchived($0) || $0.state == .live || $0.state == .awaitingApproval
        }
        let sections: [(String, [SessionRowModel])] =
            showingArchive
            ? [(Localized.text("ARCHIVED"), matching.filter(isArchived))].filter { !$0.1.isEmpty }
            : groupIntoSections(active).map { ($0.0.title, $0.1) }
        visible = sections.flatMap(\.1)
        syncCursorToSelection()

        let snapshot = (
            visible, unreachable, filter,
            "\(selectedID ?? "")|\(sidebarLimit)|\(showingArchive)|\(archivedTotal)"
        )
        if let last = lastSidebar, last == snapshot { return }
        lastSidebar = snapshot

        var next: [SidebarRow] = []
        if !unreachable.isEmpty {
            next.append(
                .banner(
                    Localized.text(
                        "%@ unreachable — showing what was last seen",
                        unreachable.joined(separator: ", "))))
        }
        if showingArchive { next.append(.backLink) }
        if visible.isEmpty {
            next.append(
                .empty(
                    showingArchive
                        ? Localized.text("Nothing archived")
                        : filter.isEmpty
                            ? Localized.text("No conversations yet")
                            : Localized.text("Nothing matches “%@”", filter)))
        } else {
            var built = 0
            for (title, members) in sections {
                guard built < sidebarLimit else { break }
                next.append(.header(title, members.count))
                for model in members {
                    guard built < sidebarLimit else { break }
                    next.append(.session(model))
                    built += 1
                }
            }
            let remaining = visible.count - built
            if remaining > 0 { next.append(.more(remaining)) }
        }
        if !showingArchive, archivedTotal > 0 { next.append(.archived(archivedTotal)) }
        rows = next
        tableView.reloadData()
        reselect()
    }

    /// The highlight follows the conversation that is open, never a position: the list re-sorts
    /// on every refresh — a chat going live jumps to the top — so a row index means something
    /// different a second later. The keyboard cursor is re-derived from the open chat here so J/K
    /// continues from where the eye is, in the order the list is actually drawn.
    private func syncCursorToSelection() {
        guard !visible.isEmpty else {
            cursor = 0
            return
        }
        if let selectedID,
            let index = visible.firstIndex(where: { $0.entry.session.id == selectedID })
        {
            cursor = index
        } else {
            cursor = min(cursor, visible.count - 1)
        }
    }

    private func reselect() {
        suppressSelectionSync = true
        defer { suppressSelectionSync = false }
        guard let selectedID, let row = rowIndex(of: selectedID) else {
            tableView.deselectAll(nil)
            return
        }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }

    private func scrollSelectionIntoView() {
        guard let selectedID, let row = rowIndex(of: selectedID) else { return }
        tableView.scrollRowToVisible(row)
    }

    private func rowIndex(of sessionID: String) -> Int? {
        rows.firstIndex {
            if case .session(let model) = $0 { return model.entry.session.id == sessionID }
            return false
        }
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

    private func deleteOptimistically(_ entry: SessionEntry, backend: any CodingAgentBackend) {
        let sessionID = entry.session.id
        pendingDeletes.insert(sessionID)
        entries.removeAll { $0.profileID == entry.profileID && $0.session.id == sessionID }
        if freshlyCreated?.session.id == sessionID { freshlyCreated = nil }
        if selectedID == sessionID {
            selectedID = nil
            if let next = entries.first { open(next) }
        }
        render()
        Task { [weak self] in
            let failure: String?
            do {
                try await backend.deleteSession(sessionID)
                failure = nil
            } catch {
                failure = "\(error)"
            }
            guard let self else { return }
            if failure == nil { await self.refresh() }
            self.pendingDeletes.remove(sessionID)
            if let failure {
                self.onNotice?(Localized.text("Could not delete: %@", failure))
                self.render()
                await self.refresh()
            }
        }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        onToast?(Localized.text("Copied"))
    }

    @objc private func filterChanged() {
        filter = searchField.stringValue
        cursor = 0
        render()
    }

    @objc private func rowClicked() {
        let index = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard index >= 0, index < rows.count else { return }
        switch rows[index] {
        case .session(let model):
            open(model.entry)
        case .more:
            sidebarLimit += 200
            lastSidebar = nil
            render()
        case .archived:
            setArchiveShown(true)
        case .backLink:
            setArchiveShown(false)
        case .banner, .header, .empty:
            break
        }
    }
}

extension SidebarViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }
}

extension SidebarViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        SidebarCellFactory.view(for: rows[row], in: tableView)
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        if case .session = rows[row] { return true }
        return false
    }

    /// Native arrow keys move the highlight without opening; the cursor follows so Enter opens
    /// what the highlight is actually on.
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelectionSync else { return }
        let row = tableView.selectedRow
        guard row >= 0, row < rows.count, case .session(let model) = rows[row],
            let index = visible.firstIndex(where: {
                $0.entry.session.id == model.entry.session.id
            })
        else { return }
        cursor = index
    }
}

extension SidebarViewController: NSMenuDelegate {
    /// The right-click menu on a chat row, exactly the Linux set. The backend lookup that gates
    /// rename, fork and delete happens on the way, so an unreachable server's row still offers
    /// what works offline.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        menuModel = nil
        menuBackend = nil
        let row = tableView.clickedRow
        guard row >= 0, row < rows.count, case .session(let model) = rows[row] else { return }
        menuModel = model
        let entry = model.entry
        if let profile = ServerDirectory.shared.profiles.first(where: { $0.id == entry.profileID }) {
            menuBackend = ServerDirectory.shared.backend(for: profile)
        }
        if entry.session.id != selectedID {
            menu.addItem(menuItem(Localized.text("Open"), action: #selector(menuOpen)))
        }
        let saved = SavedChatStore.contains(entry)
        menu.addItem(
            menuItem(
                saved ? Localized.text("Unsave") : Localized.text("Save"),
                subtitle: Localized.text(
                    "A saved chat lists itself even when its server is unreachable"),
                action: #selector(menuToggleSaved)))
        let archived = ArchivedChatStore.contains(
            profileID: entry.profileID, sessionID: entry.session.id)
        menu.addItem(
            menuItem(
                archived ? Localized.text("Unarchive") : Localized.text("Archive"),
                subtitle: archived
                    ? Localized.text("Back into the chat list")
                    : Localized.text("Out of the list, kept on the server"),
                action: #selector(menuToggleArchived)))
        menu.addItem(
            menuItem(
                model.unread
                    ? Localized.text("Mark as read") : Localized.text("Mark as unread"),
                action: #selector(menuToggleUnread)))
        if let backend = menuBackend {
            if backend.capabilities.supportsRenaming {
                menu.addItem(menuItem(Localized.text("Rename…"), action: #selector(menuRename)))
            }
            if backend.capabilities.supportsForking {
                menu.addItem(
                    menuItem(
                        Localized.text("Fork"),
                        subtitle: Localized.text(
                            "A new session with this history, for a different direction"),
                        action: #selector(menuFork)))
            }
        }
        menu.addItem(
            menuItem(
                Localized.text("Copy session ID"), subtitle: entry.session.id,
                action: #selector(menuCopyID)))
        if let directory = entry.session.directory {
            menu.addItem(
                menuItem(
                    Localized.text("Copy project path"), subtitle: directory,
                    action: #selector(menuCopyPath)))
        }
        if menuBackend != nil {
            menu.addItem(.separator())
            menu.addItem(
                menuItem(
                    Localized.text("Delete…"),
                    subtitle: Localized.text("Remove the session from its server"),
                    destructive: true, action: #selector(menuDelete)))
        }
    }

    private func menuItem(
        _ title: String, subtitle: String? = nil, destructive: Bool = false, action: Selector
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if let subtitle { item.subtitle = subtitle }
        if destructive {
            item.attributedTitle = NSAttributedString(
                string: title, attributes: [.foregroundColor: MacTheme.Color.danger])
        }
        return item
    }

    @objc private func menuOpen() {
        guard let model = menuModel else { return }
        open(model.entry)
    }

    @objc private func menuToggleSaved() {
        guard let model = menuModel else { return }
        toggleSaved(model.entry)
    }

    @objc private func menuToggleArchived() {
        guard let model = menuModel else { return }
        toggleArchived(model.entry)
    }

    @objc private func menuToggleUnread() {
        guard let model = menuModel else { return }
        toggleUnread(model.entry)
    }

    @objc private func menuRename() {
        guard let model = menuModel, let backend = menuBackend else { return }
        presentRename(entry: model.entry, backend: backend)
    }

    @objc private func menuFork() {
        guard let model = menuModel, let backend = menuBackend else { return }
        fork(entry: model.entry, backend: backend)
    }

    @objc private func menuCopyID() {
        guard let model = menuModel else { return }
        copyToPasteboard(model.entry.session.id)
    }

    @objc private func menuCopyPath() {
        guard let directory = menuModel?.entry.session.directory else { return }
        copyToPasteboard(directory)
    }

    @objc private func menuDelete() {
        guard let model = menuModel, let backend = menuBackend else { return }
        presentDelete(entry: model.entry, backend: backend)
    }
}
