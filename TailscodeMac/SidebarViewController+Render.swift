import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

extension SidebarViewController {
    /// What the stores decide a row from, read once and dropped when their own notification says
    /// they moved. The archive is held as identities because building a "profile/session" line per
    /// row to ask a set whether it holds it was most of a refresh's CPU.
    struct StoreReadings {
        let savedChats: [SavedChat]
        let saved: Set<String>
        let pins: Set<String>
        let archived: Set<ArchivedChatStore.ChatKey>
        let unread: @Sendable (String, Date) -> Bool
    }

    /// A conversation as it was last worded, and the facts that wording was made from.
    struct RowMemo {
        let session: AgentSession
        let unreachable: Bool
        let unread: Bool
        let saved: Bool
        let pinned: Bool
        let presence: SessionPresence
        let observedAt: Date?
        let bucket: Int
        let model: SessionRowModel

        func matches(
            session: AgentSession, unreachable: Bool, unread: Bool, saved: Bool, pinned: Bool,
            presence: SessionPresence, observedAt: Date?, bucket: Int
        ) -> Bool {
            self.session == session && self.unreachable == unreachable && self.unread == unread
                && self.saved == saved && self.pinned == pinned && self.presence == presence
                && self.observedAt == observedAt && self.bucket == bucket
        }
    }


    func readings() -> StoreReadings {
        if let storeReadings { return storeReadings }
        let savedChats = SavedChatStore.all()
        let readings = StoreReadings(
            savedChats: savedChats,
            saved: Set(savedChats.map(\.sessionID)),
            pins: Set(SessionPinStore.all()),
            archived: ArchivedChatStore.keys(),
            unread: SessionSeenStore.unreadEvaluator())
        storeReadings = readings
        return readings
    }

    /// A listing assigned its chats: what the whole fleet says can have moved, so the work that
    /// speaks for it is due, and one draw is booked rather than one per pushed change.
    func noteListingMoved(renderNow: Bool = false) {
        listingVersion += 1
        observationDirty = true
        if renderNow {
            render()
        } else {
            scheduleListingRender()
        }
    }

    func scheduleListingRender() {
        guard !listingRenderArmed else { return }
        listingRenderArmed = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            self.listingRenderArmed = false
            self.renderAway()
        }
    }

    /// A draw deferred because the window could not be seen, or because a pointer was holding a
    /// row under itself, is made the moment it can be.
    func flushPendingRender() {
        guard renderPending || renderHeld else { return }
        renderPending = false
        if !renderHeld { render() }
    }

    func startRefreshing() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                if self?.isOnScreen ?? false { await self?.refresh() }
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    /// Whether anybody can see the list. A window that is hidden, minimised or covered keeps its
    /// streams, which cost nothing while nothing changes, and skips the poll, which asks every
    /// server every ten seconds whether it is still there.
    private var isOnScreen: Bool {
        guard let window = view.window else { return false }
        return window.isVisible && window.occlusionState.contains(.visible)
    }

    /// A proto-2 bridge pushes list changes the moment they happen; the 10-second poll survives
    /// only as reachability detection and as the whole story for older servers.
    ///
    /// The streams follow the profiles rather than the launch. Opened once, a stream outlived its
    /// server's removal: a machine removed and added again kept speaking under the old profile's
    /// id, so every turn it ran upserted a second copy of the conversation into the list.
    func syncListStreams() {
        let profiles = ServerDirectory.shared.profiles
        for (id, stream) in listStreams where !profiles.contains(stream.profile) {
            stream.task.cancel()
            listStreams[id] = nil
        }
        for profile in profiles where listStreams[profile.id] == nil {
            guard let backend = ServerDirectory.shared.backend(for: profile),
                let streaming = backend as? SessionListStreaming
            else { continue }
            let task = Task { [weak self] in
                guard let changes = await streaming.sessionListChanges() else { return }
                for await change in changes {
                    guard let self, !Task.isCancelled else { return }
                    self.applyListChange(change, profile: profile)
                }
            }
            listStreams[profile.id] = (profile, task)
        }
    }

    private func applyListChange(_ change: SessionListChange, profile: ConnectionProfile) {
        guard listStreams[profile.id]?.profile == profile else { return }
        switch change {
        case .upsert(let session):
            let entry = SessionEntry(
                profileID: profile.id, profileName: profile.name,
                host: profile.baseURL.host ?? profile.name,
                backendType: profile.backend, session: session)
            let retitled = entries.contains {
                $0.profileID == profile.id && $0.session.id == session.id
                    && $0.session.title != session.title
            }
            if let index = entries.firstIndex(where: {
                $0.profileID == profile.id && $0.session.id == session.id
            }) {
                entries.remove(at: index)
            }
            let at =
                entries.firstIndex { $0.session.updatedAt < session.updatedAt } ?? entries.endIndex
            entries.insert(entry, at: at)
            if !entries.isEmpty { SessionListCache.scheduleSave(entries) }
            SessionMarks.reconcile(with: [entry])
            noteListingMoved()
            if retitled { onTitleChanged?() }
        case .remove(let id):
            entries.removeAll { $0.profileID == profile.id && $0.session.id == id }
            noteListingMoved(renderNow: true)
        case .invalidated:
            Task { [weak self] in await self?.refresh() }
        }
    }

    /// Opens the conversation that was open last, not merely the newest one: reopening where you
    /// were is the difference between a window that restores and a window that resets. The first
    /// listing draws in the same turn, because that open reads it; every one after walks away.
    func applyEntries(
        _ entries: [SessionEntry], unreachable: [String], fromNetwork: Bool = true
    ) {
        self.entries = SidebarBench.padded(entries)
        self.unreachable = unreachable
        listedFromNetwork = listedFromNetwork || fromNetwork
        if let fresh = freshlyCreated {
            if entries.contains(where: { $0.session.id == fresh.session.id }) {
                freshlyCreated = nil
            } else {
                self.entries.insert(fresh, at: 0)
            }
        }
        listingVersion += 1
        observationDirty = true
        if selectedID == nil { render() } else { renderAway() }
        onEntriesChanged?()
        guard selectedID == nil, !entries.isEmpty else { return }
        let remembered = UserDefaults.standard.string(forKey: "tailscode.lastSession")
            .flatMap { id in entries.first { $0.session.id == id } }
        open(remembered ?? entries[0], reveal: false)
    }

    /// Rebuilding the whole table is what the 10-second refresh would do whether or not anything
    /// changed — so nothing is touched unless what the list would say actually differs from what
    /// it says now. This draws in the same turn, which is what a press, a key, a filter typed or a
    /// fresh listing needs; a server's push draws through ``renderAway()``.
    func render() {
        if let fixture {
            renderFixture(fixture)
            return
        }
        let trace = Pace.traceStart()
        defer { Pace.traceEnd("sidebar.render", trace) }
        drawGeneration += 1
        guard let plan = beginDraw() else { return }
        let interval = Pace.signposter.beginInterval("list")
        defer { Pace.signposter.endInterval("list", interval) }
        let drawBegan = SidebarBench.isRunning ? SidebarBench.clock() : 0
        defer { if SidebarBench.isRunning { SidebarBench.note(draw: SidebarBench.clock() - drawBegan) } }
        SidebarBench.beginStages()
        let walk = SidebarWalk.make(plan.input)
        SidebarBench.stage("walk")
        finishDraw(walk, plan: plan)
    }

    /// A draw a server's push asked for: the fleet is walked off the main thread (``SidebarWalk``)
    /// and only the table comes back to it. A draw begun after this one, by a push or a press, makes
    /// it stale and it is dropped; one that lands under a held pointer or in a window nobody can see
    /// waits as a draw always has.
    func renderAway() {
        guard fixture == nil else { return render() }
        drawGeneration += 1
        let generation = drawGeneration
        guard let plan = beginDraw() else { return }
        Task { @MainActor [weak self] in
            let (walk, spent) = await SidebarWalk.away(plan.input)
            guard let self, self.drawGeneration == generation else { return }
            if NSEvent.pressedMouseButtons != 0, self.view.window?.isKeyWindow == true {
                self.holdRender()
                return
            }
            guard self.isOnScreen || DisplayGate.assumesVisible else {
                self.renderPending = true
                return
            }
            let trace = Pace.traceStart()
            defer { Pace.traceEnd("sidebar.render", trace) }
            let drawBegan = SidebarBench.isRunning ? SidebarBench.clock() : 0
            defer {
                if SidebarBench.isRunning {
                    SidebarBench.note(draw: SidebarBench.clock() - drawBegan + plan.cost, away: spent)
                }
            }
            SidebarBench.beginStages()
            self.finishDraw(walk, plan: plan)
        }
    }

    /// What a draw reads on the main thread before the fleet is walked, or nil when it cannot draw
    /// now: a pointer is holding a row, or nobody can see the list.
    struct DrawPlan {
        let input: SidebarWalk.Input
        let listingVersion: Int
        let observationStamp: Int
        /// What reading it cost the main thread, for the bench.
        let cost: Double
    }

    private func beginDraw() -> DrawPlan? {
        if NSEvent.pressedMouseButtons != 0, view.window?.isKeyWindow == true {
            holdRender()
            return nil
        }
        guard isOnScreen || DisplayGate.assumesVisible else {
            renderPending = true
            return nil
        }
        let began = SidebarBench.isRunning ? SidebarBench.clock() : 0
        lastRenderAt = CACurrentMediaTime()
        let readings = readings()
        let presence = presenceSource?() ?? [:]
        lastPresence = presence
        let input = SidebarWalk.Input(
            entries: entries, pendingDeletes: pendingDeletes, unreachable: unreachable,
            savedChats: readings.savedChats, saved: readings.saved, pins: readings.pins,
            archived: readings.archived, unread: readings.unread, presence: presence,
            lastHeard: ServerDirectory.shared.lastHeard, memo: rowMemo, needle: filter.lowercased(),
            scope: projectScope, showingArchive: showingArchive, splitTab: splitTabSource?(),
            observes: listingVersion != observedListingVersion || observationDirty, now: Date())
        return DrawPlan(
            input: input, listingVersion: listingVersion, observationStamp: observationStamp,
            cost: SidebarBench.isRunning ? SidebarBench.clock() - began : 0)
    }

    /// Lays out what a walk found: the orb, the notices the fleet owes, the rows that are drawn and
    /// only the rows whose words moved reloaded.
    private func finishDraw(_ walk: SidebarWalk, plan: DrawPlan) {
        rowMemo = walk.memo
        let models = walk.models
        known = models
        refreshOrb()
        refreshAgentsEntry()
        if !selection.isEmpty { selection.prune(to: models.map(\.entry)) }
        SidebarBench.stage("orb")
        if let observations = walk.observations {
            observedListingVersion = plan.listingVersion
            if observationStamp == plan.observationStamp { observationDirty = false }
            MacNotifier.shared.observeListing(observations)
            ActivityInbox.reconcile(
                observations,
                authoritativeProfileIDs: listedFromNetwork
                    ? Set(observations.map(\.profileID)) : [])
        }
        if readMarksMoved {
            readMarksMoved = false
            MacNotifier.withdrawRead()
        }
        SidebarBench.stage("observe")
        let sections = walk.sections
        let archivedTotal = walk.archivedTotal
        visible = (searchRunning || searchBoard != nil) ? [] : sections.flatMap(\.1)
        syncCursorToSelection()
        SidebarBench.stage("sections")
        let missed = ActivityInbox.unsaid(by: Self.drawnRows(sections, limit: sidebarLimit), limit: 5)
        listedMissed = missed.all
        let vocabulary = walk.vocabulary
        let snapshot = SidebarShape(
            visibleCount: visible.count, firstKey: visible.first?.key ?? "",
            lastKey: visible.last?.key ?? "", unreachable: unreachable, filter: filter,
            digest:
                "\(sidebarLimit)|\(showingArchive)|\(archivedTotal)"
                + "|\(selection.keys.sorted().joined(separator: ","))"
                + "|\(missed.total)|\(missed.shown.map(\.identifier).joined(separator: ","))"
                + "|\(projectScope.map { "\($0.profileID):\($0.directory ?? "")" } ?? "")"
                + "|\(sections.map { "\($0.0.key):\($0.1.count)" }.joined(separator: ","))"
                + "|\(vocabulary.namesServer)\(vocabulary.namesBackend)|\(searchRunning)\(searchBoard != nil)")
        SidebarBench.stage("vocab")
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
            let line = Localized.text(
                "%@ unreachable — showing what was last seen", unreachable.joined(separator: ", "))
            next.append(.banner(reach.map { "\(line)\n\($0.deskHint)" } ?? line))
        }
        if showingArchive { next.append(.backLink) }
        if visible.isEmpty {
            next.append(.empty(emptyReading()))
            if ServerDirectory.shared.profiles.isEmpty {
                next.append(.addMachine(EmptyWelcome.setUpTitle))
            }
        } else {
            var built = 0
            let reasons = Dictionary(
                ActivityInbox.all().map { ($0.sessionID, $0.reason) },
                uniquingKeysWith: { first, _ in first })
            let asks = askSource?() ?? [:]
            for (section, members) in sections {
                guard built < sidebarLimit else { break }
                next.append(.header(SectionHeading(section: section, items: members)))
                for item in members {
                    guard built < sidebarLimit else { break }
                    switch item {
                    case .chat(let model):
                        let news = ChatRowNews.reading(
                            for: model, ask: asks[ChatSelection.key(model.entry)],
                            missed: reasons[model.entry.session.id])
                        next.append(
                            .session(
                                model, marked: selection.contains(model.entry),
                                dress: SidebarRowDress(
                                    vocabulary: vocabulary, section: section.board, news: news)))
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
        SidebarBench.stage("rows")
        if sameShape, next.count == rows.count {
            reloadChangedRows(next)
        } else {
            rows = next
            tableView.reloadData()
        }
        SidebarBench.stage("reload")
        reselect()
        refreshHover()
        SidebarBench.stage("rest")
    }

    /// The chat rows the list is about to draw: the first `limit` items in the order the sections
    /// run, a split counted as the chats it stands for. What MISSED leaves out is judged against
    /// exactly these, because a row below the limit says nothing to anybody.
    static func drawnRows(_ sections: [(ChatListSection, [ChatListItem])], limit: Int)
        -> [SessionRowModel]
    {
        sections.flatMap(\.1).prefix(limit).flatMap { item -> [SessionRowModel] in
            switch item {
            case .chat(let row): return [row]
            case .tab(let tab): return tab.members
            }
        }
    }

    /// One of every row the list can draw, in place of the listing: a picture of the grammar that
    /// no real listing ever holds all at once.
    private func renderFixture(_ sections: [ChatListFixture.Section]) {
        var next: [SidebarRow] = []
        for section in sections {
            next.append(.header(section.heading))
            for row in section.rows {
                next.append(
                    .session(
                        row.model, marked: false,
                        dress: SidebarRowDress(
                            vocabulary: ChatListFixture.vocabulary(), section: row.section,
                            news: row.news)))
            }
        }
        rows = next
        tableView.reloadData()
        suppressSelectionSync = true
        defer { suppressSelectionSync = false }
        if let open = rowIndex(of: ChatListFixture.openSessionID) {
            tableView.selectRowIndexes(IndexSet(integer: open), byExtendingSelection: false)
        }
    }

    /// The same rows in the same places, some of them saying something new: an age that crossed a
    /// minute, a tool step that changed, the row just opened losing its unread mark. Only those
    /// rows are touched, so the rest of the list — and whatever the reader is about to click —
    /// stays exactly where it is. A chat row on screen whose height cannot have moved is dressed
    /// again where it stands (``redressInPlace(_:from:to:)``): asking the table to reload it made
    /// a new cell and measured it, three quarters of a millisecond a row, for the three to five
    /// rows every push from a working turn changes.
    private func reloadChangedRows(_ next: [SidebarRow]) {
        let before = rows
        let changed = IndexSet(rows.indices.filter { rows[$0] != next[$0] })
        rows = next
        guard !changed.isEmpty else { return }
        let reload = IndexSet(changed.filter { !redressInPlace($0, from: before[$0], to: next[$0]) })
        guard !reload.isEmpty else { return }
        tableView.reloadData(forRowIndexes: reload, columnIndexes: IndexSet(integer: 0))
        tableView.noteHeightOfRows(withIndexesChanged: reload)
    }

    /// Dresses a chat row's cell again in place, and says whether it could: the row was a chat and
    /// is one, its cell is made, and its news line keeps the one line it had or the none.
    private func redressInPlace(_ index: Int, from old: SidebarRow, to new: SidebarRow) -> Bool {
        guard case .session(_, _, let was) = old, case .session(let model, let marked, let dress) = new,
            Self.keepsHeight(was.news, dress.news),
            let cell = tableView.view(atColumn: 0, row: index, makeIfNecessary: false)
                as? SidebarSessionCell
        else { return false }
        cell.configure(with: model, marked: marked, dress: dress)
        let entry = model.entry
        cell.onQuickAction = { [weak self] action, sender in
            self?.performQuickAction(action, on: entry, from: sender)
        }
        return true
    }

    /// Whether a row's news can change without its height changing: none before and none after,
    /// or one line both times.
    private static func keepsHeight(_ was: ChatRowNews?, _ now: ChatRowNews?) -> Bool {
        switch (was, now) {
        case (nil, nil): return true
        case (let was?, let now?):
            return ChatRowInk.newsLines(was.voice, roomy: false) == 1
                && ChatRowInk.newsLines(now.voice, roomy: false) == 1
        default: return false
        }
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
            return EmptyWelcome.sidebarLine
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

    func scrollSelectionIntoView() {
        guard let selectedID, let row = rowIndex(of: selectedID) else { return }
        tableView.scrollRowToVisible(row)
    }

    func rowIndex(of sessionID: String) -> Int? {
        rows.firstIndex {
            switch $0 {
            case .session(let model, _, _): return model.entry.session.id == sessionID
            case .tab(let model, _):
                return model.members.contains { $0.entry.session.id == sessionID }
            default: return false
            }
        }
    }
}
