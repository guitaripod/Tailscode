import TailscodeCore
import UIKit

extension SessionListViewController {
    func bind() {
        viewModel.onChange = { [weak self] in
            self?.updateComposeButton()
            self?.rebuildChips()
            self?.updateUnreachableNotice()
            self?.requestRender()
        }
        viewModel.onError = { [weak self] message in self?.present(error: message) }
        NotificationCenter.default.addObserver(
            self, selector: #selector(activityDidChange),
            name: SessionActivity.didChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(archiveDidChange),
            name: ArchivedChatStore.didChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(pinDidChange),
            name: SessionPinStore.didChange, object: nil)
        NotificationCenter.default.addObserver(
            forName: ModelCatalogStore.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.readingsDidChange() }
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(readingsDidChange),
            name: SessionSeenStore.didSync, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(connectionsDidChange),
            name: ConnectionController.didChange, object: nil)
    }

    /// Settings added, removed or renamed a server. A list that lives as long as its window —
    /// the iPad's column — has to follow that the way Home does, rebuilding its backends in
    /// place rather than showing the servers it was made with.
    @objc private func connectionsDidChange() {
        viewModel.refreshSources()
        if case .profile(let id) = filter, !viewModel.servers.contains(where: { $0.id == id }) {
            filter = .all
        }
        updateTitle()
        rebuildChips()
        updateComposeButton()
        applySnapshot()
        Task { await viewModel.load() }
    }

    @objc private func pinDidChange() {
        requestRender()
    }

    @objc private func archiveDidChange() {
        updateComposeButton()
        requestRender()
    }

    @objc private func readingsDidChange() {
        reconfigureActivity()
        rebuildChips()
    }

    /// What this device is watching first-hand, as far as a row can show it: each conversation's
    /// status, the step a running turn is on and the call a waiting one is asking about.
    struct ActivityReading: Equatable {
        var statuses: [String: SessionActivity.Status]
        var steps: [String: String]
        var asks: [String: ApprovalAsk]

        @MainActor static func now() -> ActivityReading {
            let activity = SessionActivity.shared
            var steps: [String: String] = [:]
            var asks: [String: ApprovalAsk] = [:]
            for (id, status) in activity.statuses {
                switch status {
                case .running: steps[id] = activity.liveDetail(for: id)
                case .awaitingApproval: asks[id] = activity.approvalAsk(for: id)
                case .idle, .background, .stalled: break
                }
            }
            return ActivityReading(statuses: activity.statuses, steps: steps, asks: asks)
        }

        /// The conversations whose step or question differs between two readings.
        func moved(since other: ActivityReading) -> Set<String> {
            var ids: Set<String> = []
            for id in Set(steps.keys).union(other.steps.keys) where steps[id] != other.steps[id] {
                ids.insert(id)
            }
            for id in Set(asks.keys).union(other.asks.keys) where asks[id] != other.asks[id] {
                ids.insert(id)
            }
            return ids
        }
    }

    /// Activity is posted every time a turn starts or stops, and every two seconds while one
    /// runs, so that Home's cards look alive. Most of those ticks change nothing this list shows,
    /// and drawing the whole list for each one, beside the conversation that was running, was the
    /// stutter of a phone held sideways. A tick that changed nothing is dropped; one that only moved
    /// a running turn's step or a waiting turn's question redraws those rows; a turn starting or
    /// stopping moves rows between sections and draws the list.
    @objc private func activityDidChange() {
        guard dataSource != nil else { return }
        let reading = ActivityReading.now()
        guard let rendered = renderedActivity, !renderPacing.isWaiting, mayRender() else {
            reconfigureActivity()
            rebuildChips()
            return
        }
        guard reading != rendered else { return }
        guard reading.statuses == rendered.statuses else {
            reconfigureActivity()
            rebuildChips()
            return
        }
        refreshRows(of: reading.moved(since: rendered))
        renderedActivity = reading
    }

    /// Redraws the rows of these conversations from their models, leaving every other row and
    /// the order of the list alone.
    private func refreshRows(of sessionIDs: Set<String>) {
        guard !sessionIDs.isEmpty else { return }
        let entries = visibleEntries.filter { sessionIDs.contains($0.session.id) }
        guard !entries.isEmpty else { return }
        let saved = Set(SavedChatStore.all().map { SessionPinStore.key($0.profileID, $0.sessionID) })
        let context = RowContext.read(saved: saved, unreachable: Set(viewModel.unreachable))
        let now = Date()
        var keys: [String] = []
        for entry in entries {
            let key = ChatSelection.key(entry)
            rowModels[key] = cachedRowModel(for: entry, in: context, now: now)
            drawnAsks[entry.session.id] = SessionActivity.shared.approvalAsk(for: entry.session.id)
            keys.append(key)
        }
        _ = rowCache.takeRebuilt()
        var snapshot = dataSource.snapshot()
        let present = keys.filter { snapshot.indexOfItem($0) != nil }
        guard !present.isEmpty else { return }
        snapshot.reconfigureItems(present)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// A turn starting or stopping moves the row between sections, not just its pill, so the whole
    /// snapshot is rebuilt rather than the visible cells reloaded — a chat that just went live must
    /// arrive in WORKING, never wear a spinner down in RECENT.
    func reconfigureActivity() {
        guard dataSource != nil else { return }
        requestRender()
    }

    /// Draws the list now if it has not drawn lately, and otherwise once when the interval is up.
    /// A turn starting is a status change, a listing push and a read mark arriving within a few
    /// frames of each other, and the column beside a conversation drew the whole list for each;
    /// paced, they cost one draw at the start of the burst and one at its end, and the last state
    /// asked for is always the one drawn.
    func requestRender() {
        guard mayRender() else { return }
        let interval = SidebarCadence.interval(at: .calm, visible: true)
        switch renderPacing.request(at: CACurrentMediaTime(), interval: interval) {
        case .runNow:
            applySnapshot()
        case .covered:
            break
        case .wait(let delay, let token):
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.renderPacing.fire(token: token, at: CACurrentMediaTime()) else {
                    return
                }
                self.applySnapshot()
            }
        }
    }

    private func updateUnreachableNotice() {
        let names = viewModel.unreachable.compactMap { id in
            viewModel.servers.first(where: { $0.id == id })?.name
        }
        if names.isEmpty {
            unreachableLabel.isHidden = true
            unreachableLabel.text = nil
        } else {
            unreachableLabel.text = String(
                localized: "\(names.joined(separator: ", ")) unreachable — pull to retry")
            unreachableLabel.isHidden = false
        }
    }

    /// Whether the row would land in WORKING, asked the same way `groupIntoSections` asks it, so
    /// the Live chip's count and the section's contents can never disagree. Never re-reads
    /// liveness off the listing alone once this device is watching the turn itself. It is the
    /// same reading the archive is held to (`ChatArchiveRule`), because a conversation that is
    /// still going may not be hidden by either one.
    func isLive(_ entry: SessionEntry) -> Bool {
        ChatArchiveRule.isUnfinished(presence: presence(for: entry), session: entry.session)
    }

    /// What the chips choose among: the listing with the board's scope already applied, so a
    /// scoped Live count never advertises a turn the board is not showing.
    func filterableEntries() -> [SessionEntry] {
        guard let scope else { return viewModel.entries }
        return viewModel.entries.filter(scope.matches)
    }

    private func filteredEntries() -> [SessionEntry] {
        let archived = ArchivedChatStore.all()
        var list =
            archived.isEmpty
            ? viewModel.entries
            : viewModel.entries.filter {
                !archived.contains(ArchivedChatStore.key($0.profileID, $0.session.id)) || isLive($0)
            }
        if let scope { list = list.filter(scope.matches) }
        switch filter {
        case .all:
            break
        case .live:
            list = list.filter(isLive)
        case .profile(let id):
            list = list.filter { $0.profileID == id }
        }
        guard !searchQuery.isEmpty else { return list }
        return list.filter {
            $0.session.title.localizedCaseInsensitiveContains(searchQuery)
                || ($0.session.agentTask?.localizedCaseInsensitiveContains(searchQuery) ?? false)
                || ($0.session.directory?.localizedCaseInsensitiveContains(searchQuery) ?? false)
                || $0.profileName.localizedCaseInsensitiveContains(searchQuery)
        }
    }

    /// What this device is watching first-hand, so a row is live the moment a turn starts here
    /// rather than when the server's next sweep agrees, and a turn stopped for an approval says so.
    func presence(for entry: SessionEntry) -> SessionPresence {
        SessionActivity.shared.presence(for: entry.session.id)
    }

    /// What every row of one render is judged against, read from the stores once. The evaluator and
    /// the pin list each copy their whole backing store out of `UserDefaults`, so asking per row
    /// made one render cost the length of the list times the length of the store.
    private struct RowContext {
        let saved: Set<String>
        let unreachable: Set<String>
        let pins: Set<String>
        let isUnread: (String, Date) -> Bool

        static func read(saved: Set<String>, unreachable: Set<String>) -> RowContext {
            RowContext(
                saved: saved, unreachable: unreachable, pins: Set(SessionPinStore.all()),
                isUnread: SessionSeenStore.unreadEvaluator())
        }
    }

    private func rowModel(for entry: SessionEntry, in context: RowContext) -> SessionRowModel {
        let key = SessionPinStore.key(entry.profileID, entry.session.id)
        return SessionRowModel(
            entry: entry,
            unreachable: context.unreachable.contains(entry.profileID),
            unread: context.isUnread(entry.session.id, entry.session.updatedAt),
            saved: context.saved.contains(key),
            pinned: context.pins.contains(key),
            presence: presence(for: entry),
            observedAt: viewModel.observedAt[entry.profileID])
    }

    /// The same model, kept from the last render when nothing it is made from has moved.
    private func cachedRowModel(for entry: SessionEntry, in context: RowContext, now: Date)
        -> SessionRowModel
    {
        let key = SessionPinStore.key(entry.profileID, entry.session.id)
        return rowCache.model(
            for: entry, key: key,
            unreachable: context.unreachable.contains(entry.profileID),
            unread: context.isUnread(entry.session.id, entry.session.updatedAt),
            saved: context.saved.contains(key), pinned: context.pins.contains(key),
            presence: presence(for: entry), observedAt: viewModel.observedAt[entry.profileID],
            now: now)
    }

    /// The listing as the shared `groupIntoListSections` groups it — NEEDS YOU, WORKING, PINNED,
    /// SAVED, then the rest by when: Today, Yesterday, the last week, the last month, months and
    /// years — with empty sections dropped so no heading ever sits over nothing. Every row carries the
    /// presence this device knows first-hand, which is what puts the conversation being streamed
    /// right now in WORKING instead of waiting for the server's next sweep to agree.
    private func sectionedRows(for entries: [SessionEntry]) -> [(ChatListSection, [SessionRowModel])]
    {
        let saved = Set(SavedChatStore.all().map { SessionPinStore.key($0.profileID, $0.sessionID) })
        let context = RowContext.read(saved: saved, unreachable: Set(viewModel.unreachable))
        let now = Date()
        rowCache.beginPass()
        let rows = entries.map { cachedRowModel(for: $0, in: context, now: now) }
        rowCache.sweep()
        return groupIntoListSections(rows, now: now)
    }

    /// The flattened order the sections draw becomes `visibleEntries` — the one list the keyboard
    /// cursor, select-all and the held selection all address, because an `IndexPath` into a
    /// sectioned snapshot is not a position a person has.
    ///
    /// Only what moved is drawn. A row is reconfigured when its model was rebuilt or something
    /// else its cell reads changed (the listing's vocabulary, why it was missed, the heading it sits
    /// under, the call a waiting turn is asking about), and a render that moved nothing applies no
    /// snapshot at all. Every activity tick used to reconfigure every row and animate the lot, which
    /// beside a running conversation was most of what the main thread did.
    func applySnapshot() {
        guard mayRender() else { return }
        renderPacing.flush(at: CACurrentMediaTime())
        renderedActivity = ActivityReading.now()
        let entries = filteredEntries()
        let fixture = fixtureSections()
        let sections = fixture ?? sectionedRows(for: entries)
        let rebuilt = fixture == nil ? rowCache.takeRebuilt() : nil
        let rows = sections.flatMap(\.1)

        rowModels = Dictionary(
            rows.map { (SessionPinStore.key($0.entry.profileID, $0.entry.session.id), $0) },
            uniquingKeysWith: { first, _ in first })
        let vocabulary = ChatListVocabulary(rows: rows)
        let vocabularyMoved = vocabulary != self.vocabulary
        self.vocabulary = vocabulary
        visibleEntries = rows.map(\.entry)
        selection.prune(to: visibleEntries)

        var snapshot = NSDiffableDataSourceSnapshot<ChatListSection, String>()
        var headings: [ChatListSection: SectionHeading] = [:]
        var boards: [String: SessionSection] = [:]
        for (section, members) in sections {
            let keys = members.map { ChatSelection.key($0.entry) }
            snapshot.appendSections([section])
            snapshot.appendItems(keys, toSection: section)
            headings[section] = SectionHeading(
                section: section, rows: members.count, fresh: members.count { $0.unread })
            guard let board = section.board else { continue }
            for key in keys { boards[key] = board }
        }
        let headingsMoved = headings != self.headings
        self.headings = headings
        var missed = Dictionary(
            ActivityInbox.all().map { ($0.sessionID, $0.reason) },
            uniquingKeysWith: { first, _ in first })
        if showsFixture { missed = ChatListFixture.missed }

        var asks: [String: ApprovalAsk] = [:]
        for row in sections.first(where: { $0.0 == .needsYou })?.1 ?? [] {
            let id = row.entry.session.id
            asks[id] = SessionActivity.shared.approvalAsk(for: id)
        }

        let previous = dataSource.snapshot()
        let existing = Set(previous.itemIdentifiers)
        let retained = snapshot.itemIdentifiers.filter { existing.contains($0) }
        let stale = vocabularyMoved || rebuilt == nil
            ? retained
            : retained.filter { key in
                guard let id = rowModels[key]?.entry.session.id else { return true }
                return rebuilt?.contains(key) == true || boards[key] != rowBoards[key]
                    || missed[id] != missedReasons[id] || asks[id] != drawnAsks[id]
            }
        rowBoards = boards
        missedReasons = missed
        drawnAsks = asks

        let moved = previous.sectionIdentifiers != snapshot.sectionIdentifiers
            || previous.itemIdentifiers != snapshot.itemIdentifiers
        if moved || !stale.isEmpty {
            if !stale.isEmpty { snapshot.reconfigureItems(stale) }
            let animated = shouldAnimate(from: previous, to: snapshot, retained: retained.count)
            dataSource.apply(snapshot, animatingDifferences: animated)
        }
        if headingsMoved { refreshVisibleHeaders() }
        refreshControl.endRefreshing()
        clampKeyCursor()
        if isSelecting || !selectionBar.isHidden { updateSelectionBar() }
        updateEmptyState(itemCount: snapshot.numberOfItems)
        syncOpenMark()
        onListingChange?()
    }

    /// Only a list that gained or lost rows or headings animates, and only once it is on screen
    /// and not under a finger. A chat changing places — the newest moving up, a turn starting and
    /// taking its row into WORKING — is the same rows, and is drawn where it now belongs; a batch
    /// update landing mid-scroll fights the scroll it lands on.
    ///
    /// - Parameter retained: how many of the new rows the list already held; the rows are the
    ///   same set exactly when that is all of them on both sides.
    private func shouldAnimate(
        from previous: NSDiffableDataSourceSnapshot<ChatListSection, String>,
        to next: NSDiffableDataSourceSnapshot<ChatListSection, String>, retained: Int
    ) -> Bool {
        guard hasAppeared, view.window != nil, previous.numberOfItems > 0,
            !collectionView.isTracking, !collectionView.isDragging, !collectionView.isDecelerating
        else { return false }
        return previous.sectionIdentifiers != next.sectionIdentifiers
            || retained != previous.numberOfItems || retained != next.numberOfItems
    }

    #if DEBUG
        /// Read once: every cell asks, and the environment is copied out whole on each read.
        private static let fixtureMode = ProcessInfo.processInfo.environment["TAILSCODE_CHATLIST_FIXTURE"]
    #endif

    /// The conversation a row stands for. A row's identity in the snapshot is its key, the
    /// lightest thing a diffable list can copy, hash and bridge for every row of a long listing; a
    /// whole entry carried every field of its session through each diff. The entry is this
    /// render's, which is never older than the snapshot the row was drawn from.
    func entry(at indexPath: IndexPath) -> SessionEntry? {
        dataSource.itemIdentifier(for: indexPath).flatMap { rowModels[$0]?.entry }
    }

    /// Whether the list draws one of every row instead of the listing (`TAILSCODE_CHATLIST_FIXTURE`),
    /// for a picture of the grammar no real listing holds all at once.
    var showsFixture: Bool {
        #if DEBUG
            Self.fixtureMode != nil
        #else
            false
        #endif
    }

    private func fixtureSections() -> [(ChatListSection, [SessionRowModel])]? {
        guard showsFixture else { return nil }
        let all = groupIntoListSections(ChatListFixture.models())
        #if DEBUG
            if Self.fixtureMode == "tail" {
                return all.filter { $0.0 != .needsYou && $0.0 != .working && $0.0 != .pinned }
            }
        #endif
        return all
    }

    /// A cursor that outlived the row it pointed at must land somewhere real, not address a row a
    /// re-sort put somewhere else.
    private func clampKeyCursor() {
        guard let keyCursor else { return }
        guard !visibleEntries.isEmpty else {
            self.keyCursor = nil
            return
        }
        self.keyCursor = min(keyCursor, visibleEntries.count - 1)
    }

    private func updateEmptyState(itemCount: Int) {
        let working = itemCount == 0 && !hasLoadedOnce && searchQuery.isEmpty
        collectionView.showsWork(working)
        if itemCount > 0 {
            contentUnavailableConfiguration = nil
        } else if working {
            contentUnavailableConfiguration = nil
        } else if !searchQuery.isEmpty {
            contentUnavailableConfiguration = UIContentUnavailableConfiguration.search()
        } else if case .live = filter {
            var config = UIContentUnavailableConfiguration.empty()
            config.image = UIImage(systemName: "moon.zzz")
            config.text = String(localized: "Nothing running")
            config.secondaryText = String(
                localized: "Live sessions show up here the moment an agent starts working.")
            contentUnavailableConfiguration = config
        } else if viewModel.isEmptyOfServers {
            var config = UIContentUnavailableConfiguration.empty()
            config.image = UIImage(systemName: "server.rack")
            config.text = String(localized: "No servers connected")
            config.secondaryText = String(
                localized: "Add a connection in Settings to start chatting with your agents.")
            contentUnavailableConfiguration = config
        } else if viewModel.entries.isEmpty, !viewModel.unreachable.isEmpty {
            var config = UIContentUnavailableConfiguration.empty()
            config.image = UIImage(systemName: "wifi.exclamationmark")
            config.text = String(localized: "Server unreachable")
            config.secondaryText = String(localized: "Pull down to retry the connection.")
            contentUnavailableConfiguration = config
        } else {
            var config = UIContentUnavailableConfiguration.empty()
            config.image = UIImage(systemName: "bubble.left.and.bubble.right")
            config.text = String(localized: "No conversations here yet")
            config.secondaryText = String(localized: "Start one with the compose button.")
            contentUnavailableConfiguration = config
        }
    }
}

extension SessionListViewController {
    /// What the side of an iPad's window shows beside this list: each server with how many of its
    /// conversations are running and whether it answered, the pinned chats in pin order wearing
    /// their own faces, and how many chats are archived. Built from the listing already held and
    /// the same readings the rows use, so the sidebar and the list can never disagree.
    func digest() -> ChatListDigest {
        let archived = ArchivedChatStore.all()
        let unreachable = Set(viewModel.unreachable)
        let live = viewModel.entries.filter(isLive)
        let context = RowContext.read(saved: [], unreachable: unreachable)
        let pinRanks = Dictionary(
            SessionPinStore.all().enumerated().map { ($0.element, $0.offset) },
            uniquingKeysWith: { first, _ in first })
        let pinned = viewModel.entries
            .compactMap { entry in
                pinRanks[SessionPinStore.key(entry.profileID, entry.session.id)]
                    .map { (rank: $0, entry: entry) }
            }
            .sorted { $0.rank < $1.rank }
            .map { pin in
                let row = rowModel(for: pin.entry, in: context)
                return ChatListDigest.Pinned(
                    key: ChatSelection.key(pin.entry), title: pin.entry.session.title,
                    backend: pin.entry.backendType, activity: row.state.activity,
                    unread: context.isUnread(pin.entry.session.id, pin.entry.session.updatedAt))
            }
        return ChatListDigest(
            servers: viewModel.servers.map { profile in
                ChatListDigest.Server(
                    id: profile.id, name: profile.name, backend: profile.backend,
                    live: live.count { $0.profileID == profile.id },
                    unreachable: unreachable.contains(profile.id))
            },
            live: live.count,
            archived: viewModel.entries.count {
                archived.contains(ArchivedChatStore.key($0.profileID, $0.session.id))
            },
            pinned: pinned)
    }
}
