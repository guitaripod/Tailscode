import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

/// One chat and the machine that can remove it, paired before the fan-out so the concurrent half
/// never has to reach back into the directory from off the main actor.
struct DeleteTarget: Sendable {
    let entry: SessionEntry
    let backend: any CodingAgentBackend
}

/// The chat list: every conversation on every configured server, grouped NEEDS YOU / WORKING / SAVED /
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
    var onAddMachine: (() -> Void)?
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
    /// person is talking in right now leads WORKING from here rather than from the next sweep.
    var presenceSource: (() -> [String: SessionPresence])?
    /// Says one line in the window's own toast. Filing a chat away is one keystroke, so the list
    /// tells the person what it just did rather than letting a row leave without a word.
    var announce: ((String) -> Void)?

    var showingArchive = false

    let searchField = NSSearchField()
    let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let rowMenu = NSMenu()
    private let usageFooter = UsageFooterView()
    /// The standing mark: what every machine's software adds up to, rendered from the ledger and
    /// therefore on screen before this launch has asked anybody anything. It watches the ledger
    /// itself, so nothing above it has to remember to tell it.
    private let updateFooter = UpdateFooterView()
    /// The world clock, leading the Update mark in the foot's one row: it is always there, and the
    /// Update mark beside it hides itself when there is nothing to say.
    let clockChip = ClockChipView()
    private let supporterCard = SupporterCardView()
    let bulkBar = SidebarBulkBar()
    let orb = PresenceOrbView()
    let agentsEntry = AgentsSidebarEntry()
    var onOpenAgents: (() -> Void)?
    /// Whether any open pane's composer is burning the ultracode aura, answered by the hub — the
    /// orb wears the same rainbow the moment the word is typed anywhere.
    var ultracodeSource: (() -> Bool)?

    var entries: [SessionEntry] = []
    var unreachable: [String] = []
    /// Whether any listing on screen has come from a server rather than from the disk cache. The
    /// cache is what was last seen, which is no evidence that a chat missing from it was deleted.
    var listedFromNetwork = false
    /// The rows the keyboard cursor acts on, which is exactly the conversations on screen. While
    /// search results have replaced the list it holds nothing: j/k opening a chat that is nowhere
    /// in the window, and Space marking one, are worse than a cursor that does nothing at all.
    var visible: [ChatListItem] = []
    /// Every row the list knows about, before the filter and the archive view narrow it — what a
    /// bulk verb acts on, so a mark survives a keystroke in the filter field.
    var known: [SessionRowModel] = []
    var rows: [SidebarRow] = []
    /// The chats a verb is about to act on. Ephemeral by design: a gesture in progress, cleared
    /// by escape, by the verb that consumed it, and by any row that leaves the listing.
    var selection = ChatSelection()
    var lastPresence: [String: SessionPresence] = [:]
    /// Sessions whose delete is confirmed but not yet acknowledged by the server. Every listing —
    /// the 10-second refresh, the session-list stream, a stale request already in flight — keeps
    /// reporting the session until the delete lands, and each report would resurrect the row; the
    /// tombstone outlives them all and is lifted only once the post-delete refresh has
    /// reconciled, or the delete failed and the row should genuinely return. Keyed on
    /// `(profileID, sessionID)` like every other store here, because a selection spanning two
    /// servers can hold the same session id twice and a tombstone on the bare id would take the
    /// other machine's row out of the list with it.
    var pendingDeletes: Set<String> = []
    /// A chat created a heartbeat ago is kept in the list by hand until the server's own listing
    /// carries it — a bridge that answers from a sweep a second old would otherwise blink the
    /// row away.
    var freshlyCreated: SessionEntry?
    var sidebarLimit = 60
    var filter = ""
    var projectScope: ProjectScope?
    /// The results of the last submitted search, and whether one is in flight. A list that is
    /// looking must say so: silence while a fleet answers is indistinguishable from nothing found.
    var searchBoard: TranscriptSearch.Board?
    var searchRunning = false
    var searchTask: Task<Void, Never>?
    var cursor = 0
    var selectedID: String?
    var lastSidebar: ([String], [String], String, String)?
    /// A click is a press and a release, and a row reloaded between the two never becomes one:
    /// the action reads `clickedRow` on the release, and a table rebuilt under the press re-sorts
    /// what that index means. The list is held for the length of the press and redrawn on the
    /// release, the way the transcript already is. The ceiling covers a press this window never
    /// sees the end of.
    var renderHeld = false
    var holdMonitor: Any?
    var holdGeneration = 0
    static let pointerHoldCeiling: TimeInterval = 1.2
    var refreshTask: Task<Void, Never>?
    var toldDeviceOnly: Set<String> = []
    /// One live listing per server, keyed by the profile it was opened for, so a server removed,
    /// re-added or re-addressed gets its stream replaced rather than kept.
    var listStreams: [String: (profile: ConnectionProfile, task: Task<Void, Never>)] = [:]
    var suppressSelectionSync = false
    /// The row the pointer is resting on, which wears a ground and — for a chat — its verbs. The
    /// list is watched through one tracking area for the whole table rather than one per row, and
    /// the row is read again whenever the list scrolls or redraws under a pointer standing still.
    var hoveredRow = -1
    lazy var hoverWatch = SidebarHoverWatch { [weak self] in self?.refreshHover() }
    /// A pointer that stops on a chat for this long is most of the way to a click, which is when
    /// its conversation is started, so the pane that opens it finds its words already there.
    static let hoverIntent: TimeInterval = 0.065
    var warmWork: DispatchWorkItem?
    var pressWatch: Any?
    var menuModel: SessionRowModel?
    /// The remembered split a context menu was opened on, held for the same reason `menuModel` is.
    var menuTab: SplitTabRow?
    var menuBackend: (any CodingAgentBackend)?

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
        hoverWatch.watch(tableView, scrolling: scrollView)
        watchPresses()
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
        observeDecisions()
        observeAgents()

        updateFooter.onOpen = { [weak self] in self?.onOpenUpdates?() }
        supporterCard.onUnlock = { [weak self] in self?.onOpenPro?() }

        MeridianFeed.shared.start()
        let clockRow = NSStackView(views: [clockChip, updateFooter])
        clockRow.orientation = .horizontal
        clockRow.alignment = .centerY
        clockRow.spacing = MacTheme.Spacing.s
        clockRow.translatesAutoresizingMaskIntoConstraints = false
        let footer = FillingStack(views: [bulkBar, supporterCard, clockRow, usageFooter, orb])
        footer.spacing = MacTheme.Spacing.xs
        footer.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(searchField)
        container.addSubview(agentsEntry)
        container.addSubview(scrollView)
        container.addSubview(footer)
        NSLayoutConstraint.activate([
            searchField.topAnchor.constraint(
                equalTo: container.safeAreaLayoutGuide.topAnchor, constant: MacTheme.Spacing.s),
            searchField.leadingAnchor.constraint(
                equalTo: container.leadingAnchor, constant: MacTheme.Spacing.s),
            searchField.trailingAnchor.constraint(
                equalTo: container.trailingAnchor, constant: -MacTheme.Spacing.s),
            agentsEntry.topAnchor.constraint(
                equalTo: searchField.bottomAnchor, constant: MacTheme.Spacing.xs),
            agentsEntry.leadingAnchor.constraint(
                equalTo: container.leadingAnchor, constant: MacTheme.Spacing.s),
            agentsEntry.trailingAnchor.constraint(
                equalTo: container.trailingAnchor, constant: -MacTheme.Spacing.s),
            scrollView.topAnchor.constraint(
                equalTo: agentsEntry.bottomAnchor, constant: MacTheme.Spacing.xs),
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
        MeridianFeed.shared.update(quotas: quotas)
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
        syncListStreams()
    }

    override func viewDidDisappear() {
        super.viewDidDisappear()
        refreshTask?.cancel()
        refreshTask = nil
    }

    func refresh() async {
        ServerDirectory.shared.reload()
        syncListStreams()
        let (fresh, down) = await ServerDirectory.shared.entries(knownDirectories: recentDirectories)
        if !fresh.isEmpty { SessionListCache.scheduleSave(fresh) }
        await SessionMarkSync.drain { await ServerDirectory.shared.backend(forProfileID: $0) }
        SessionMarks.reconcile(with: fresh)
        applyEntries(fresh, unreachable: down)
    }

    /// Every chat the list knows about, and the servers that stopped answering — read by the
    /// hub so an empty pane's chooser offers the same truth the list is showing.
    var allEntries: [SessionEntry] { entries }
    var unreachableServers: [String] { unreachable }

    /// A fresh listing landed: the hub restates any chooser standing on the old one.
    var onEntriesChanged: (() -> Void)?
    /// A streamed push changed a chat's title and nothing else the window must take in: the panes
    /// showing it, the window and the strip are redrawn without the full listing's work.
    var onTitleChanged: (() -> Void)?

    /// The directories chats already work in, newest first — the seed for the per-project walk a
    /// listing needs, and the same places the new-chat chooser ranks.
    var recentDirectories: [String] {
        var seen = Set<String>()
        return entries.compactMap(\.session.directory).filter { seen.insert($0).inserted }
    }

    /// How many chats a verb would act on right now — read by the menu bar so Delete says what it
    /// would delete before it is opened.
    var markedCount: Int { selection.count }

    /// A pane reports its state on every token it streams, and each report used to redraw every
    /// row in the list — a thousand of them across five machines — whenever the step it was on
    /// moved. The badge is read at a glance rather than watched, so reports landing close together
    /// are answered once.
    var presenceRenderPending = false
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
        let view = SidebarCellFactory.view(
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
        if let cell = view as? SidebarSessionCell, case .session(let model, _, _) = rows[row] {
            let entry = model.entry
            cell.onQuickAction = { [weak self] action, sender in
                self?.performQuickAction(action, on: entry, from: sender)
            }
            cell.setHovered(row == hoveredRow ? quickState(for: row) : nil)
        }
        return view
    }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let view = SidebarRowView()
        view.isHovered = row == hoveredRow
        return view
    }

    func tableView(_ tableView: NSTableView, shouldSelectRow row: Int) -> Bool {
        switch rows[row] {
        case .session, .tab: return true
        default: return false
        }
    }

    /// Typing a chat's first letters walks to it, the way every list on the Mac answers a name.
    /// The rows are drawn by hand rather than through a cell's text field, so the table is told
    /// which words each row stands for; the headings and links between them stand for nothing.
    func tableView(_ tableView: NSTableView, typeSelectStringFor tableColumn: NSTableColumn?, row: Int)
        -> String?
    {
        guard row >= 0, row < rows.count else { return nil }
        switch rows[row] {
        case .session(let model, _, _): return model.title
        case .tab(let model, _): return model.title
        default: return nil
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
