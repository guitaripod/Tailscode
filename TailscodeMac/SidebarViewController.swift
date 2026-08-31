import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

/// One chat and the machine that can remove it, paired before the fan-out so the concurrent half
/// never has to reach back into the directory from off the main actor.
private struct DeleteTarget: Sendable {
    let entry: SessionEntry
    let backend: any CodingAgentBackend
}

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
    var onOpenInSplit: ((SessionEntry) -> Void)?
    var onNewChatInScope: ((ProjectScope) -> Void)?
    var onDeleted: ((SessionEntry) -> Void)?
    var onNotice: ((String) -> Void)?
    var onOpenSplit: (([SessionEntry], SplitArrangement) -> Void)?
    /// The split's own row pressed: the arrangement is already on screen, so the window goes to
    /// it rather than rebuilding it.
    var onOpenSplitTab: ((SplitTab) -> Void)?
    /// A member of the split pressed: jump to the pane that is showing it.
    var onGoToMember: ((SessionEntry) -> Void)?
    /// The unsplit gesture: back to one pane, keeping the given chat when one is named.
    var onUnsplit: ((SessionEntry?) -> Void)?
    /// The window's current arrangement, read live at every render — the merged row exists
    /// exactly as long as the split does.
    var splitTabSource: (() -> SplitTab?)?
    var onToast: ((String) -> Void)?
    /// The standing mark was touched: the Update Center is the whole of what it leads to.
    var onOpenUpdates: (() -> Void)?
    /// The supporter card's one button: the Pro window is the whole of what it leads to.
    var onOpenPro: (() -> Void)?
    /// Which session the focused pane is actually showing. With a tiling tree, "already open"
    /// is a fact about the focused pane, not about this list's last click — an empty pane must
    /// be able to receive the row the previous pane still shows.
    var focusedSessionID: (() -> String?)?
    /// What the open panes know first-hand about the conversations they are streaming, keyed on
    /// `(profileID, sessionID)`. A listing reports `active` for the seconds a turn is literally
    /// open on the server and never reports a turn that stopped to ask something, so the chat a
    /// person is talking in right now leads LIVE NOW from here rather than from the next sweep.
    var presenceSource: (() -> [String: SessionPresence])?

    private(set) var showingArchive = false

    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let rowMenu = NSMenu()
    private let usageFooter = UsageFooterView()
    /// The standing mark: what every machine's software adds up to, rendered from the ledger and
    /// therefore on screen before this launch has asked anybody anything. It watches the ledger
    /// itself, so nothing above it has to remember to tell it.
    private let updateFooter = UpdateFooterView()
    private let supporterCard = SupporterCardView()
    private let bulkBar = SidebarBulkBar()
    private let orb = PresenceOrbView()
    /// Whether any open pane's composer is burning the ultracode aura, answered by the hub — the
    /// orb wears the same rainbow the moment the word is typed anywhere.
    var ultracodeSource: (() -> Bool)?

    private(set) var entries: [SessionEntry] = []
    private var unreachable: [String] = []
    /// Whether any listing on screen has come from a server rather than from the disk cache. The
    /// cache is what was last seen, which is no evidence that a chat missing from it was deleted.
    private var listedFromNetwork = false
    /// The rows the keyboard cursor acts on, which is exactly the conversations on screen. While
    /// search results have replaced the list it holds nothing: j/k opening a chat that is nowhere
    /// in the window, and Space marking one, are worse than a cursor that does nothing at all.
    private var visible: [ChatListItem] = []
    /// Every row the list knows about, before the filter and the archive view narrow it — what a
    /// bulk verb acts on, so a mark survives a keystroke in the filter field.
    private var known: [SessionRowModel] = []
    private var rows: [SidebarRow] = []
    /// The chats a verb is about to act on. Ephemeral by design: a gesture in progress, cleared
    /// by escape, by the verb that consumed it, and by any row that leaves the listing.
    private var selection = ChatSelection()
    private var lastPresence: [String: SessionPresence] = [:]
    /// Sessions whose delete is confirmed but not yet acknowledged by the server. Every listing —
    /// the 10-second refresh, the session-list stream, a stale request already in flight — keeps
    /// reporting the session until the delete lands, and each report would resurrect the row; the
    /// tombstone outlives them all and is lifted only once the post-delete refresh has
    /// reconciled, or the delete failed and the row should genuinely return. Keyed on
    /// `(profileID, sessionID)` like every other store here, because a selection spanning two
    /// servers can hold the same session id twice and a tombstone on the bare id would take the
    /// other machine's row out of the list with it.
    private var pendingDeletes: Set<String> = []
    /// A chat created a heartbeat ago is kept in the list by hand until the server's own listing
    /// carries it — a bridge that answers from a sweep a second old would otherwise blink the
    /// row away.
    private var freshlyCreated: SessionEntry?
    private var sidebarLimit = 60
    private var filter = ""
    private var projectScope: ProjectScope?
    /// The results of the last submitted search, and whether one is in flight. A list that is
    /// looking must say so: silence while a fleet answers is indistinguishable from nothing found.
    private var searchBoard: TranscriptSearch.Board?
    private var searchRunning = false
    private var searchTask: Task<Void, Never>?
    private var cursor = 0
    private var selectedID: String?
    private var lastSidebar: ([String], [String], String, String)?
    /// A click is a press and a release, and a row reloaded between the two never becomes one:
    /// the action reads `clickedRow` on the release, and a table rebuilt under the press re-sorts
    /// what that index means. The list is held for the length of the press and redrawn on the
    /// release, the way the transcript already is. The ceiling covers a press this window never
    /// sees the end of.
    private var renderHeld = false
    private var holdMonitor: Any?
    private var holdGeneration = 0
    private static let pointerHoldCeiling: TimeInterval = 1.2
    private var refreshTask: Task<Void, Never>?
    private var listStreamTasks: [Task<Void, Never>] = []
    private var suppressSelectionSync = false
    private var menuModel: SessionRowModel?
    /// The remembered split a context menu was opened on, held for the same reason `menuModel` is.
    private var menuTab: SplitTabRow?
    private var menuBackend: (any CodingAgentBackend)?

    override func loadView() {
        let container = NSView()

        searchField.placeholderString = Localized.text("Filter chats  ⏎ to search inside")
        searchField.sendsWholeSearchString = false
        searchField.sendsSearchStringImmediately = true
        searchField.target = self
        searchField.action = #selector(filterChanged)
        searchField.delegate = self
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

        bulkBar.isHidden = true
        bulkBar.onAction = { [weak self] action in self?.applyBulk(action) }
        bulkBar.onClear = { [weak self] in self?.clearMarks() }
        bulkBar.onSplit = { [weak self] arrangement in self?.applyMarkedSplit(arrangement) }

        orb.setEnabled(PresenceOrbSetting.isEnabled)
        orb.heightAnchor.constraint(equalToConstant: 76).isActive = true
        orb.onOpen = { [weak self] in self?.openOrbTarget() }
        NotificationCenter.default.addObserver(
            self, selector: #selector(orbSettingChanged), name: PresenceOrbSetting.didChange,
            object: nil)

        updateFooter.onOpen = { [weak self] in self?.onOpenUpdates?() }
        supporterCard.onUnlock = { [weak self] in self?.onOpenPro?() }

        let footer = FillingStack(views: [bulkBar, supporterCard, updateFooter, usageFooter, orb])
        footer.spacing = MacTheme.Spacing.xs
        footer.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(searchField)
        container.addSubview(scrollView)
        container.addSubview(footer)
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
                equalTo: footer.topAnchor, constant: -MacTheme.Spacing.xs),
            footer.leadingAnchor.constraint(
                equalTo: container.leadingAnchor, constant: MacTheme.Spacing.m),
            footer.trailingAnchor.constraint(
                equalTo: container.trailingAnchor, constant: -MacTheme.Spacing.m),
            footer.bottomAnchor.constraint(
                equalTo: container.bottomAnchor, constant: -MacTheme.Spacing.s),
        ])
        view = container
    }

    /// The quota picture at a glance, fed by the hub's slow poll — account state under the chat
    /// list, the way the phone keeps it on the Home board. `answeredAt` is when the numbers last
    /// arrived: a reading nobody could refresh has to say so before it says anything else.
    func renderUsage(_ quotas: [(String, UsageQuota)], answeredAt: Date?) {
        usageFooter.render(quotas, answeredAt: answeredAt)
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
        if !cached.isEmpty { applyEntries(cached, unreachable: [], fromNetwork: false) }
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
        let (fresh, down) = await ServerDirectory.shared.entries(knownDirectories: recentDirectories)
        if !fresh.isEmpty { SessionListCache.save(fresh) }
        SavedChatStore.reconcile(with: fresh)
        applyEntries(fresh, unreachable: down)
    }

    /// Every chat the list knows about, and the servers that stopped answering — read by the
    /// hub so an empty pane's chooser offers the same truth the list is showing.
    var allEntries: [SessionEntry] { entries }
    var unreachableServers: [String] { unreachable }

    /// A fresh listing landed: the hub restates any chooser standing on the old one.
    var onEntriesChanged: (() -> Void)?

    /// The directories chats already work in, newest first — the seed for the per-project walk a
    /// listing needs, and the same places the new-chat chooser ranks.
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

    /// A row clicked while its chat is already on screen is still somebody saying they have seen
    /// it, so what this list holds about the conversation is written whether or not a pane has to
    /// change — an unread mark that clears only by opening something else and coming back reads
    /// as broken. `alreadyShowing` spares the pane's half of the work, and nothing else.
    func open(_ entry: SessionEntry, freshlyCreated: Bool = false) {
        let alreadyShowing =
            focusedSessionID.map { $0() == entry.session.id } ?? (selectedID == entry.session.id)
        selectedID = entry.session.id
        SessionSeenStore.markSeen(entry.session.id)
        render()
        scrollSelectionIntoView()
        guard !alreadyShowing else { return }
        self.freshlyCreated = freshlyCreated ? entry : nil
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
        openItem(visible[cursor])
    }

    /// Opening what a row stands for: a conversation is opened, a remembered split is put back in
    /// the window whole.
    func openItem(_ item: ChatListItem) {
        switch item {
        case .chat(let row): open(row.entry)
        case .tab(let row): onOpenSplitTab?(row.tab)
        }
    }

    /// Every conversation the list is drawing, whatever it is grouped into — what a mark and a
    /// bulk verb are spent on.
    private var visibleEntries: [SessionEntry] {
        visible.flatMap(\.entries)
    }

    /// Marking a remembered split holds every chat in it: the row is one row, so the mark it wears
    /// has to mean the same thing the row does. Core's item toggle owns the rule — and the anchor,
    /// so the next shift-click measures from whichever row this press landed on.
    private func toggleMark(_ item: ChatListItem) {
        selection.toggle(item)
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

    func togglePinned(_ entry: SessionEntry) {
        SessionPinStore.toggle(profileID: entry.profileID, sessionID: entry.session.id)
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

    /// How many chats a verb would act on right now — read by the menu bar so Delete says what it
    /// would delete before it is opened.
    var markedCount: Int { selection.count }

    /// Space: the row under the keyboard cursor joins the set, or leaves it.
    func toggleMarkUnderCursor() {
        guard cursor < visible.count else { return }
        toggleMark(visible[cursor])
        lastSidebar = nil
        render()
    }

    /// ⌃a: everything the list is showing, or — pressed again with all of it already held —
    /// nothing. The archive view and the filter decide what "shown" means, so select-all never
    /// reaches a row the eye cannot see.
    func toggleMarkAllShown() {
        selection.toggleAll(in: visibleEntries)
        lastSidebar = nil
        render()
    }

    /// Escape clears the marks before it means anything else, so the way out of a gesture is the
    /// same key everywhere in the app. Answers whether there was anything to clear.
    @discardableResult
    func clearMarks() -> Bool {
        guard !selection.isEmpty else { return false }
        selection.clear()
        lastSidebar = nil
        render()
        return true
    }

    /// `x`, and the menu bar's Delete: every marked chat, or the one under the cursor when
    /// nothing is marked — the single-row delete is the same gesture with a set of one.
    func presentDeleteFromKeyboard() {
        let marked = markedModels
        if !marked.isEmpty {
            presentBulkDelete(marked)
            return
        }
        guard cursor < visible.count, let entry = visible[cursor].lead?.entry else { return }
        guard let backend = backend(for: entry) else {
            onNotice?(Localized.text("That server is not configured."))
            return
        }
        presentDelete(entry: entry, backend: backend)
    }

    /// A pane's stream said something new. The list only rebuilds when what it would say about a
    /// conversation actually changed, because a running turn reports on every chunk and rebuilding
    /// the whole table per chunk is the one thing this list must never do.
    /// The window's arrangement changed — a split, an unsplit, a pane rebound. The merged row is
    /// a function of it, so the list re-reads; the render diff keeps a no-op cheap.
    func noteLayoutChanged() {
        render()
    }

    func notePresenceChanged() {
        let presence = presenceSource?() ?? [:]
        guard presence != lastPresence else { return }
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

    /// One key walks in and out of a project: scoped, `p` restores the whole list; unscoped, it
    /// reads the project off the row under the cursor — or the conversation on screen when the
    /// cursor has nothing — and the sidebar becomes that project's own board.
    func toggleProjectScope(fallback: SessionEntry?) {
        guard projectScope == nil else { return setProjectScope(nil) }
        let row = tableView.selectedRow
        var cursorEntry: SessionEntry?
        if row >= 0, row < rows.count, case .session(let model, _, _) = rows[row] {
            cursorEntry = model.entry
        }
        guard let entry = cursorEntry ?? fallback else { return }
        setProjectScope(ProjectScope(of: entry))
    }

    func setProjectScope(_ scope: ProjectScope?) {
        projectScope = scope
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
    private func applyEntries(
        _ entries: [SessionEntry], unreachable: [String], fromNetwork: Bool = true
    ) {
        self.entries = entries
        self.unreachable = unreachable
        listedFromNetwork = listedFromNetwork || fromNetwork
        if let fresh = freshlyCreated {
            if entries.contains(where: { $0.session.id == fresh.session.id }) {
                freshlyCreated = nil
            } else {
                self.entries.insert(fresh, at: 0)
            }
        }
        render()
        onEntriesChanged?()
        guard selectedID == nil, !entries.isEmpty else { return }
        let remembered = UserDefaults.standard.string(forKey: "tailscode.lastSession")
            .flatMap { id in entries.first { $0.session.id == id } }
        open(remembered ?? entries[0])
    }

    /// Rebuilding the whole table is what the 10-second refresh would do whether or not anything
    /// changed — so nothing is touched unless what the list would say actually differs from what
    /// it says now.
    private func render() {
        if NSEvent.pressedMouseButtons != 0, view.window?.isKeyWindow == true {
            holdRender()
            return
        }
        let savedChats = SavedChatStore.all()
        let saved = Set(savedChats.map(\.sessionID))
        let unread = SessionSeenStore.unreadEvaluator()
        let needle = filter.lowercased()
        let presence = presenceSource?() ?? [:]
        lastPresence = presence
        var models = entries.filter { !pendingDeletes.contains(ChatSelection.key($0)) }.map {
            SessionRowModel(
                entry: $0,
                unreachable: unreachable.contains(
                    ServerLabel.display(name: $0.profileName, backend: $0.backendType)),
                unread: unread($0.session.id, $0.session.updatedAt),
                saved: saved.contains($0.session.id),
                pinned: SessionPinStore.contains(
                    profileID: $0.profileID, sessionID: $0.session.id),
                presence: presence[ChatSelection.key($0)] ?? .unobserved,
                observedAt: ServerDirectory.shared.lastHeard[
                    ServerLabel.display(name: $0.profileName, backend: $0.backendType)])
        }
        models += Self.orphanedSavedRows(savedChats, listed: entries)
        known = models
        refreshOrb()
        selection.prune(to: models.map(\.entry))
        let observations = models.map {
            ActivityObservation(
                profileID: $0.entry.profileID, sessionID: $0.entry.session.id,
                title: $0.title, isActive: $0.entry.session.isActive == true)
        }
        MacNotifier.shared.observeListing(observations, openSessionID: selectedID)
        ActivityInbox.reconcile(
            observations,
            authoritativeProfileIDs: listedFromNetwork
                ? Set(observations.map(\.profileID)) : [])
        let archivedKeys = ArchivedChatStore.all()
        let isArchived: (SessionRowModel) -> Bool = {
            archivedKeys.contains(ArchivedChatStore.key($0.entry.profileID, $0.entry.session.id))
        }
        let scoped =
            projectScope.map { scope in models.filter { scope.matches($0.entry) } } ?? models
        let archivedTotal = scoped.filter(isArchived).count
        let matching = scoped.filter {
            needle.isEmpty || $0.title.lowercased().contains(needle)
                || $0.detail.lowercased().contains(needle)
                || ($0.snippet?.lowercased().contains(needle) ?? false)
        }
        let active = matching.filter {
            !isArchived($0) || $0.state == .live || $0.state == .awaitingApproval
        }
        let grouped: [(String, [SessionRowModel])] =
            showingArchive
            ? [(Localized.text("ARCHIVED"), matching.filter(isArchived))].filter { !$0.1.isEmpty }
            : groupIntoSections(active).map { ($0.0.title, $0.1) }
        let sections = SplitTabGrouping.apply(
            to: grouped, tab: showingArchive ? nil : splitTabSource?())
        visible = (searchRunning || searchBoard != nil) ? [] : sections.flatMap(\.1)
        syncCursorToSelection()

        let missed = ActivityInbox.ordered(limit: 5)
        let vocabulary = ChatListVocabulary(rows: models)
        let snapshot = (
            visible.map(\.key), unreachable, filter,
            "\(sidebarLimit)|\(showingArchive)|\(archivedTotal)"
                + "|\(selection.keys.sorted().joined(separator: ","))"
                + "|\(missed.total)|\(missed.shown.map(\.identifier).joined(separator: ","))"
                + "|\(projectScope.map { "\($0.profileID):\($0.directory ?? "")" } ?? "")"
                + "|\(sections.map { "\($0.0):\($0.1.count)" }.joined(separator: ","))"
                + "|\(vocabulary.namesServer)\(vocabulary.namesBackend)|\(searchRunning)\(searchBoard != nil)"
        )
        let sameShape = lastSidebar.map { $0 == snapshot } ?? false
        lastSidebar = snapshot
        renderBulkBar()

        var next: [SidebarRow] = []
        if searchRunning || searchBoard != nil {
            rows = searchRows()
            tableView.reloadData()
            tableView.deselectAll(nil)
            return
        }
        if let scope = projectScope {
            let serverName =
                entries.first { $0.profileID == scope.profileID }?.profileName ?? scope.profileID
            next.append(.scopeLink(scope.banner(serverName: serverName)))
            next.append(.scopeNew(scope.name))
        }
        if !showingArchive, !missed.shown.isEmpty {
            next.append(.missedHeader(missed.total))
            next.append(contentsOf: missed.shown.map(SidebarRow.missed))
            if missed.total > missed.shown.count {
                next.append(
                    .empty(Localized.text("… %@ more", "\(missed.total - missed.shown.count)")))
            }
        }
        if !unreachable.isEmpty {
            next.append(
                .banner(
                    Localized.text(
                        "%@ unreachable — showing what was last seen",
                        unreachable.joined(separator: ", "))))
        }
        if showingArchive { next.append(.backLink) }
        if visible.isEmpty {
            next.append(.empty(emptyReading()))
        } else {
            var built = 0
            for (title, members) in sections {
                guard built < sidebarLimit else { break }
                next.append(.header(title, members.count))
                for item in members {
                    guard built < sidebarLimit else { break }
                    switch item {
                    case .chat(let model):
                        next.append(
                            .session(
                                model, marked: selection.contains(model.entry),
                                vocabulary: vocabulary))
                    case .tab(let model):
                        next.append(
                            .tab(
                                model,
                                marked: model.members.allSatisfy {
                                    selection.contains($0.entry)
                                }))
                    }
                    built += 1
                }
            }
            let remaining = visible.count - built
            if remaining > 0 { next.append(.more(remaining)) }
        }
        if !showingArchive, archivedTotal > 0 { next.append(.archived(archivedTotal)) }
        if sameShape, next.count == rows.count {
            reloadChangedRows(next)
        } else {
            rows = next
            tableView.reloadData()
        }
        reselect()
    }

    /// The same rows in the same places, some of them saying something new: an age that crossed a
    /// minute, a tool step that changed, the row just opened losing its unread mark. Only those
    /// rows are reloaded, so the rest of the list — and whatever the reader is about to click —
    /// stays exactly where it is.
    private func reloadChangedRows(_ next: [SidebarRow]) {
        let changed = IndexSet(rows.indices.filter { rows[$0] != next[$0] })
        rows = next
        guard !changed.isEmpty else { return }
        tableView.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integer: 0))
        tableView.noteHeightOfRows(withIndexesChanged: changed)
    }

    private func holdRender() {
        renderHeld = true
        guard holdMonitor == nil else { return }
        holdMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseUp, .rightMouseUp, .otherMouseUp]
        ) { [weak self] event in
            DispatchQueue.main.async { [weak self] in self?.releaseRender() }
            return event
        }
        holdGeneration += 1
        let generation = holdGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pointerHoldCeiling) { [weak self] in
            guard let self, self.holdGeneration == generation else { return }
            self.releaseRender()
        }
    }

    /// One runloop hop after the mouse-up, so the row's own action has read `clickedRow` against
    /// the table it was pressed on before anything about that table changes.
    private func releaseRender() {
        if let holdMonitor { NSEvent.removeMonitor(holdMonitor) }
        holdMonitor = nil
        holdGeneration += 1
        guard renderHeld else { return }
        renderHeld = false
        render()
    }

    /// Which absence the list is actually looking at. A machine with no servers configured has no
    /// chats *because* it has no servers, and "No conversations yet" blames the wrong thing on the
    /// one morning the sentence is the only thing in the window.
    private func emptyReading() -> String {
        if ServerDirectory.shared.profiles.isEmpty {
            return Localized.text("No servers yet — add the machine your agent runs on")
        }
        if showingArchive { return Localized.text("Nothing archived") }
        if !filter.isEmpty { return Localized.text("Nothing matches “%@”", filter) }
        if let scope = projectScope { return Localized.text("Nothing in %@ yet", scope.name) }
        return Localized.text("No conversations yet")
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
            let index = visible.firstIndex(where: { item in
                item.entries.contains { $0.session.id == selectedID }
            })
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
            switch $0 {
            case .session(let model, _, _): return model.entry.session.id == sessionID
            case .tab(let model, _):
                return model.members.contains { $0.entry.session.id == sessionID }
            default: return false
            }
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

    /// One chat's delete is the bulk delete with a set of one, so the tombstone, the optimistic
    /// removal and the way a refusal is reported have exactly one implementation.
    private func deleteOptimistically(_ entry: SessionEntry, backend: any CodingAgentBackend) {
        delete([DeleteTarget(entry: entry, backend: backend)])
    }

    /// Optimistic on confirm, concurrent behind it: the rows leave before the round trip, every
    /// server is asked at once rather than in turn, and what came back is reported in one sentence
    /// from `BulkChatCopy` — a partial failure that said nothing would read as a delete that
    /// silently skipped. Tombstones are keyed on the `(profile, session)` pair and lifted only
    /// once the refresh behind the request has reconciled.
    private func delete(_ targets: [DeleteTarget]) {
        guard !targets.isEmpty else { return }
        let keys = Set(targets.map { ChatSelection.key($0.entry) })
        pendingDeletes.formUnion(keys)
        entries.removeAll { keys.contains(ChatSelection.key($0)) }
        if let fresh = freshlyCreated, keys.contains(ChatSelection.key(fresh)) {
            freshlyCreated = nil
        }
        for target in targets { onDeleted?(target.entry) }
        if let openID = selectedID, targets.contains(where: { $0.entry.session.id == openID }) {
            selectedID = nil
            if let next = entries.first { open(next) }
        }
        lastSidebar = nil
        render()
        Task { [weak self] in
            let outcome = await Self.fanOutDelete(targets)
            guard let self else { return }
            if outcome.deleted > 0 { await self.refresh() }
            self.pendingDeletes.subtract(keys)
            guard !outcome.isClean else { return }
            if let sentence = BulkChatCopy.outcome(outcome) { self.onNotice?(sentence) }
            self.lastSidebar = nil
            self.render()
            await self.refresh()
        }
    }

    private nonisolated static func fanOutDelete(_ targets: [DeleteTarget]) async
        -> BulkChatOutcome
    {
        await withTaskGroup(of: String?.self) { group in
            for target in targets {
                group.addTask {
                    do {
                        try await target.backend.deleteSession(target.entry.session.id)
                        return nil
                    } catch {
                        return "\(error)"
                    }
                }
            }
            var deleted = 0
            var reasons: [String] = []
            for await failure in group {
                if let failure { reasons.append(failure) } else { deleted += 1 }
            }
            return BulkChatOutcome(
                deleted: deleted, failed: reasons.count, reason: reasons.first)
        }
    }

    /// The marked chats in the order the list is drawing them, so a confirm dialog names them the
    /// way the eye just read them — taken from everything the list knows rather than from what the
    /// filter is showing, because a mark made before a keystroke in the filter field is still a
    /// mark the person made.
    private var markedModels: [SessionRowModel] {
        known.filter { selection.contains($0.entry) }
    }

    private func renderBulkBar() {
        let marked = markedModels
        bulkBar.isHidden = marked.isEmpty
        guard !marked.isEmpty else { return }
        bulkBar.render(count: marked.count, actions: Self.bulkActions(for: marked))
    }

    /// What the verbs mean for what is held. A set that is entirely archived offers to unarchive,
    /// an entirely saved set offers to unsave, and a set holding anything unread offers to mark it
    /// read — a button must never do the opposite of the word on it.
    private static func bulkActions(for models: [SessionRowModel]) -> [BulkChatAction] {
        let archived = models.allSatisfy {
            ArchivedChatStore.contains(
                profileID: $0.entry.profileID, sessionID: $0.entry.session.id)
        }
        let saved = models.allSatisfy(\.saved)
        let unread = models.contains { $0.unread }
        return [
            .delete, archived ? .unarchive : .archive, saved ? .unsave : .save,
            unread ? .markRead : .markUnread,
        ]
    }

    private func applyBulk(_ action: BulkChatAction) {
        let marked = markedModels
        guard !marked.isEmpty else { return }
        switch action {
        case .delete:
            presentBulkDelete(marked)
        case .archive, .unarchive:
            let wanted = action == .archive
            for model in marked {
                let archived = ArchivedChatStore.contains(
                    profileID: model.entry.profileID, sessionID: model.entry.session.id)
                guard archived != wanted else { continue }
                ArchivedChatStore.toggle(
                    profileID: model.entry.profileID, sessionID: model.entry.session.id)
            }
            finishBulk()
        case .save:
            for model in marked where !model.saved { SavedChatStore.save(model.entry) }
            finishBulk()
        case .unsave:
            for model in marked {
                SavedChatStore.remove(
                    profileID: model.entry.profileID, sessionID: model.entry.session.id)
            }
            finishBulk()
        case .markRead:
            for model in marked { SessionSeenStore.markSeen(model.entry.session.id) }
            finishBulk()
        case .markUnread:
            for model in marked {
                SessionSeenStore.markUnread(
                    model.entry.session.id, updatedAt: model.entry.session.updatedAt)
            }
            finishBulk()
        }
    }

    /// A verb that acted on the whole set ends the set: the marks are a gesture in progress, and
    /// leaving them held invites the next verb to act on rows that already changed.
    private func finishBulk() {
        selection.clear()
        lastSidebar = nil
        render()
    }

    /// The selection spent on the window itself: the hub opens every marked chat at once as one
    /// even tiling, in the order the list was drawing the rows, and the gesture spends the marks
    /// like every other bulk verb.
    private func applyMarkedSplit(_ arrangement: SplitArrangement) {
        let entries = markedModels.map(\.entry)
        guard !SplitEven.offers(count: entries.count).isEmpty else { return }
        finishBulk()
        onOpenSplit?(entries, arrangement)
    }

    private func presentBulkDelete(_ models: [SessionRowModel]) {
        guard !models.isEmpty else { return }
        let count = models.count
        MacDialogs.confirm(
            on: view.window,
            title: BulkChatCopy.title(.delete, count: count),
            body: BulkChatCopy.message(count: count, titles: models.map(\.title)),
            confirmLabel: BulkChatCopy.confirm(.delete, count: count)
        ) { [weak self] in
            guard let self else { return }
            let targets = models.compactMap { model in
                self.backend(for: model.entry).map {
                    DeleteTarget(entry: model.entry, backend: $0)
                }
            }
            self.selection.clear()
            guard !targets.isEmpty else {
                self.onNotice?(Localized.text("That server is not configured."))
                self.lastSidebar = nil
                self.render()
                return
            }
            self.delete(targets)
        }
    }

    private func backend(for entry: SessionEntry) -> (any CodingAgentBackend)? {
        guard
            let profile = ServerDirectory.shared.profiles.first(where: {
                $0.id == entry.profileID
            })
        else { return nil }
        return ServerDirectory.shared.backend(for: profile)
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        onToast?(Localized.text("Copied"))
    }

    @objc private func filterChanged() {
        // Typing again is the way back to the list: results are about words that were submitted,
        // and leaving them up while the box says something else would be a lie about both.
        if searchBoard != nil || searchRunning { leaveTranscriptSearch(render: false) }
        filter = searchField.stringValue
        cursor = 0
        render()
    }

    /// Enter searches what was actually said, everywhere. The filter above it is titles-only and
    /// instant; this asks every machine at once and takes as long as the slowest one, so the list
    /// says it is looking rather than appearing to have found nothing.
    private func runTranscriptSearch() {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard TranscriptSearch.isSearchable(query) else { return }
        searchTask?.cancel()
        searchRunning = true
        searchBoard = nil
        lastSidebar = nil
        render()
        let listed = entries
        searchTask = Task { [weak self] in
            let sources = ServerDirectory.shared.profiles.compactMap { profile in
                ServerDirectory.shared.backend(for: profile).map {
                    TranscriptSearch.Source(
                        profileID: profile.id,
                        name: ServerLabel.display(name: profile.name, backend: profile.backend),
                        backend: $0,
                        entries: listed.filter { $0.profileID == profile.id })
                }
            }
            let board = await TranscriptSearch.run(query: query, sources: sources)
            guard !Task.isCancelled else { return }
            self?.searchRunning = false
            self?.searchBoard = board
            self?.lastSidebar = nil
            self?.render()
        }
    }

    /// The list, replaced by what was found.
    private func searchRows() -> [SidebarRow] {
        let query = searchBoard?.query ?? filter
        var next: [SidebarRow] = [.searchHeader(query, searchBoard?.rows.count ?? 0, searchRunning)]
        if searchRunning {
            next.append(.empty(Localized.text("Asking every server…")))
            return next
        }
        if let caveat = searchBoard.flatMap(TranscriptSearch.caveat) { next.append(.banner(caveat)) }
        guard let found = searchBoard?.rows, !found.isEmpty else {
            next.append(.empty(Localized.text("Nothing said “%@”", query)))
            return next
        }
        next.append(contentsOf: found.prefix(sidebarLimit).map(SidebarRow.searchResult))
        return next
    }

    private func leaveTranscriptSearch(render shouldRender: Bool = true) {
        searchTask?.cancel()
        searchTask = nil
        searchRunning = false
        searchBoard = nil
        lastSidebar = nil
        if shouldRender { render() }
    }

    /// A result opens the conversation it names. The listing may not carry it — a chat on a server
    /// this device has not listed lately — so one the list cannot resolve says so instead of
    /// doing nothing.
    private func openSearchResult(profileID: String, sessionID: String) {
        guard let entry = entries.first(where: {
            $0.profileID == profileID && $0.session.id == sessionID
        }) else {
            onToast?(Localized.text("That chat is not in this server's listing right now."))
            return
        }
        leaveTranscriptSearch(render: false)
        searchField.stringValue = ""
        filter = ""
        open(entry)
        render()
    }

    @objc private func orbSettingChanged() {
        orb.setEnabled(PresenceOrbSetting.isEnabled)
        refreshOrb()
    }

    /// One cheap re-read of the last aggregate, for the fact that changes without a listing —
    /// the ultracode aura lighting or dying under a draft. The full render feeds `known`; this
    /// keeps the rainbow honest between renders.
    func refreshOrb() {
        orb.update(
            signal: PresenceSignal.aggregate(
                known.map { $0.state.activity }, ultracode: ultracodeSource?() ?? false))
    }

    /// A touch on the orb goes to the conversation that most needs the person: a turn stopped to
    /// ask first, then whatever is running.
    private func openOrbTarget() {
        guard
            let target = known.first(where: { $0.state == .awaitingApproval })
                ?? known.first(where: { $0.state == .live })
        else { return }
        open(target.entry)
    }

    @objc private func rowClicked() {
        let index = tableView.clickedRow >= 0 ? tableView.clickedRow : tableView.selectedRow
        guard index >= 0, index < rows.count else { return }
        if index < visible.count,
            NSApp.currentEvent?.modifierFlags.contains(.shift) == true,
            rows[index].isChat
        {
            selection.rangeSelect(visible[index], in: visible)
            lastSidebar = nil
            render()
            return
        }
        switch rows[index] {
        case .session(let model, _, _):
            open(model.entry)
        case .tab(let model, _):
            onOpenSplitTab?(model.tab)
        case .more:
            sidebarLimit += 200
            lastSidebar = nil
            render()
        case .archived:
            setArchiveShown(true)
        case .backLink:
            setArchiveShown(false)
        case .scopeLink:
            setProjectScope(nil)
        case .scopeNew:
            guard let scope = projectScope else { break }
            onNewChatInScope?(scope)
        case .missed(let item):
            openMissed(sessionID: item.sessionID)
        case .searchResult(let result):
            openSearchResult(profileID: result.profileID, sessionID: result.sessionID)
        case .searchHeader:
            leaveTranscriptSearch()
        case .banner, .header, .empty, .missedHeader:
            break
        }
    }

    /// A missed notice is a place to go back to. The chat may have been deleted or its server
    /// removed since, in which case the notice is stale and goes rather than sitting there
    /// failing to open.
    private func openMissed(sessionID: String) {
        guard let entry = entries.first(where: { $0.session.id == sessionID }) else {
            ActivityInbox.clear(sessionID: sessionID)
            lastSidebar = nil
            render()
            return
        }
        open(entry)
        lastSidebar = nil
        render()
    }

    private func clearMissed() {
        ActivityInbox.clearAll()
        lastSidebar = nil
        render()
    }
}

/// Enter in the filter field is the search. `NSSearchField`'s own action fires on every keystroke
/// when the string is sent immediately, so the submit has to be taken from the text view's
/// insert-newline command rather than from the action.
extension SidebarViewController: NSSearchFieldDelegate {
    func control(
        _ control: NSControl, textView: NSTextView, doCommandBy selector: Selector
    ) -> Bool {
        guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
        filter = searchField.stringValue
        runTranscriptSearch()
        return true
    }
}

extension SidebarViewController: NSTableViewDataSource {
    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int)
        -> (any NSPasteboardWriting)?
    {
        guard case .session(let model, _, _) = rows[row] else { return nil }
        let payload = PaneDragPayload(
            profileID: model.entry.profileID, sessionID: model.entry.session.id)
        let item = NSPasteboardItem()
        item.setString(payload.encoded, forType: .tailscodeChat)
        return item
    }
}

extension SidebarViewController: NSTableViewDelegate {
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int)
        -> NSView?
    {
        SidebarCellFactory.view(
            for: rows[row], in: tableView,
            onClearMissed: { [weak self] in self?.clearMissed() },
            onOpenMember: { [weak self] tab, index in
                guard let self,
                    let binding = tab.members.indices.contains(index) ? tab.members[index] : nil,
                    let entry = self.known.first(where: {
                        $0.entry.profileID == binding.profileID
                            && $0.entry.session.id == binding.sessionID
                    })
                else { return }
                SessionSeenStore.markSeen(entry.entry.session.id)
                self.onGoToMember?(entry.entry)
            })
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        switch rows[row] {
        case .session, .tab: return true
        default: return false
        }
    }

    /// Native arrow keys move the highlight without opening; the cursor follows so Enter opens
    /// what the highlight is actually on.
    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !suppressSelectionSync else { return }
        let row = tableView.selectedRow
        guard row >= 0, row < rows.count else { return }
        let key: String
        switch rows[row] {
        case .session(let model, _, _):
            key = ChatSelection.key(model.entry)
        case .tab(let model, _):
            key = "split:\(model.tab.identity)"
        default: return
        }
        guard let index = visible.firstIndex(where: { $0.key == key }) else { return }
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
        guard row >= 0, row < rows.count else { return }
        if case .tab(let model, _) = rows[row] {
            buildTabMenu(menu, for: model)
            return
        }
        guard case .session(let model, _, _) = rows[row] else { return }
        menuModel = model
        let entry = model.entry
        if let profile = ServerDirectory.shared.profiles.first(where: { $0.id == entry.profileID }) {
            menuBackend = ServerDirectory.shared.backend(for: profile)
        }
        if entry.session.id != selectedID {
            menu.addItem(menuItem(Localized.text("Open"), action: #selector(menuOpen)))
        }
        menu.addItem(
            menuItem(
                selection.contains(entry)
                    ? Localized.text("Unmark") : Localized.text("Mark"),
                subtitle: Localized.text("Act on several chats at once"),
                action: #selector(menuToggleMarked)))
        menu.addItem(
            menuItem(
                Localized.text("Open in a new split"),
                subtitle: Localized.text("Beside the conversations already on screen"),
                action: #selector(menuOpenInSplit)))
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
        let pinned = SessionPinStore.contains(
            profileID: entry.profileID, sessionID: entry.session.id)
        menu.addItem(
            menuItem(
                pinned ? Localized.text("Unpin") : Localized.text("Pin"),
                subtitle: pinned
                    ? Localized.text("Back into the recency order")
                    : Localized.text("Always at the top of the chat list"),
                action: #selector(menuTogglePinned)))
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
        if projectScope == nil {
            menu.addItem(
                menuItem(
                    Localized.text("Only this project"),
                    subtitle: ProjectScope(of: entry).banner(serverName: entry.profileName),
                    action: #selector(menuScopeProject)))
        } else {
            menu.addItem(
                menuItem(
                    Localized.text("Every chat"),
                    subtitle: Localized.text("Leave the project board"),
                    action: #selector(menuScopeClear)))
        }
        if menuBackend != nil {
            menu.addItem(.separator())
            menu.addItem(
                menuItem(
                    Localized.text("Delete…"),
                    subtitle: Localized.text("Remove the session from its server"),
                    destructive: true, action: #selector(menuDelete)))
        }
        guard selection.count > 1 else { return }
        menu.addItem(
            menuItem(
                BulkChatCopy.button(.delete, count: selection.count) + "…",
                subtitle: Localized.text("Every marked chat, on every server they are on"),
                destructive: true, action: #selector(menuDeleteMarked)))
    }

    /// The menu on the split's row: each chat inside it on its own, and the one gesture that
    /// takes the arrangement apart. The members are held on the controller so the items can act
    /// without a target per row.
    private func buildTabMenu(_ menu: NSMenu, for model: SplitTabRow) {
        menuTab = model
        for (index, member) in model.members.enumerated() {
            let item = menuItem(
                Localized.text("Open just %@", member.title),
                subtitle: Localized.text("Unsplit down to this one chat"),
                action: #selector(menuOpenTabMember(_:)))
            item.tag = index
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(
            menuItem(
                Localized.text("Unsplit"),
                subtitle: Localized.text("Back to one pane; the chats keep their own rows"),
                action: #selector(menuUnsplit)))
    }

    @objc private func menuOpenTabMember(_ sender: NSMenuItem) {
        guard let members = menuTab?.members, members.indices.contains(sender.tag) else { return }
        onUnsplit?(members[sender.tag].entry)
    }

    @objc private func menuUnsplit() {
        onUnsplit?(nil)
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

    @objc private func menuOpenInSplit() {
        guard let model = menuModel else { return }
        onOpenInSplit?(model.entry)
    }

    @objc private func menuToggleMarked() {
        guard let model = menuModel else { return }
        selection.toggle(model.entry)
        lastSidebar = nil
        render()
    }

    @objc private func menuDeleteMarked() {
        presentBulkDelete(markedModels)
    }

    @objc private func menuToggleSaved() {
        guard let model = menuModel else { return }
        toggleSaved(model.entry)
    }

    @objc private func menuToggleArchived() {
        guard let model = menuModel else { return }
        toggleArchived(model.entry)
    }

    @objc private func menuTogglePinned() {
        guard let model = menuModel else { return }
        togglePinned(model.entry)
    }

    @objc private func menuScopeProject() {
        guard let model = menuModel else { return }
        setProjectScope(ProjectScope(of: model.entry))
    }

    @objc private func menuScopeClear() {
        setProjectScope(nil)
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
