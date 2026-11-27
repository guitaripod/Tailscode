import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension MainWindow {
    /// The monotonic clock the draw spacing is measured on.
    static var sidebarClock: TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// Whether anybody could see the list: the window exists and the compositor has not said it is
    /// minimised, on another workspace or covered whole.
    var sidebarWindowVisible: Bool {
        guard !sidebarTornDown, let window else { return false }
        return gtk_window_is_suspended(ptr(window)) == 0
    }

    var sidebarInterval: TimeInterval {
        max(
            SidebarCadence.interval(at: CascadeBudget.level, visible: sidebarWindowVisible),
            sidebarHoldUntil - Self.sidebarClock)
    }

    /// Asks for the list to be drawn. The first request after a quiet spell is drawn at once; the
    /// rest of a burst is one more draw at the end of the interval, which reads whatever is true
    /// by then, so the last state is always the one drawn.
    func scheduleSidebarRender() {
        guard !sidebarTornDown, !Gtk.isQuitting else { return }
        switch sidebarCoalescer.request(at: Self.sidebarClock, interval: sidebarInterval) {
        case .runNow:
            drawSidebarAway()
        case .covered:
            break
        case .wait(let delay, let token):
            Gtk.after(UInt32(max(1, (delay * 1000).rounded(.up)))) { [weak self] in
                guard let self, !self.sidebarTornDown,
                    self.sidebarCoalescer.fire(token: token, at: Self.sidebarClock)
                else { return }
                self.drawSidebarAway()
            }
        }
    }

    /// Draws the list now, whatever is waiting: what a press on a row asked for must show under the
    /// pointer, not a tenth of a second after.
    func renderSidebar() {
        guard !sidebarTornDown else { return }
        sidebarCoalescer.flush(at: Self.sidebarClock)
        drawSidebar()
    }

    /// The window can be seen again, or has been mapped for the first time: whatever the list
    /// owed while nobody was looking is drawn now.
    func sidebarVisibilityChanged() {
        guard sidebarWindowVisible else { return }
        renderSidebar()
    }

    /// The window is going: nothing in the list may be touched again, and the row widgets this
    /// window was holding are no longer anybody's to name.
    func sidebarTeardown() {
        sidebarTornDown = true
        sidebarRows = []
        sidebarHeadings = [:]
        sidebarCoalescer.reset()
        pendingListChanges = []
    }

    func installSidebarLifecycle(on window: UnsafeMutablePointer<GtkWidget>) {
        let root = UnsafeMutableRawPointer(window)
        Gtk.onNotify(root, property: "suspended") { [weak self] in
            self?.sidebarVisibilityChanged()
        }
        Gtk.observe(root, "destroy") { [weak self] in
            self?.sidebarTeardown()
        }
        watchSidebarStores()
    }

    /// The four stores a row is decided from, kept between draws and dropped by their own
    /// notifications. Reading them per draw was copying the seen map, the pin list, the saved set
    /// and the archive out of the defaults several times a second.
    func sidebarStoreReadings() -> SidebarReadings {
        if let sidebarReadings { return sidebarReadings }
        let savedChats = SavedChatStore.all()
        let readings = SidebarReadings(
            savedChats: savedChats,
            saved: Set(savedChats.map(\.sessionID)),
            pins: SessionPinStore.snapshot(),
            archived: ArchivedChatStore.keys(),
            unread: SessionSeenStore.unreadEvaluator())
        sidebarReadings = readings
        return readings
    }

    /// Each store's notice drops the readings and books a draw. A notice posted on the GTK thread,
    /// which is where every press writes, drops them before the post returns: the press redraws the
    /// list straight after its write, and a drop that waited for the idle hop left that draw
    /// reading the marks from before the click.
    private func watchSidebarStores() {
        guard sidebarStoreWatches.isEmpty else { return }
        let names = [
            SessionPinStore.didChange, SessionSeenStore.didSync, SessionSeenStore.didMark,
            SavedChatStore.didChange, ArchivedChatStore.didChange,
        ]
        for name in names {
            sidebarStoreWatches.append(
                NotificationCenter.default.addObserver(
                    forName: name, object: nil, queue: nil
                ) { [weak self] _ in
                    if Thread.isMainThread { self?.sidebarReadings = nil }
                    Gtk.onMain { [weak self] in
                        guard let self else { return }
                        self.sidebarReadings = nil
                        if name == SessionSeenStore.didSync {
                            self.sidebarReadMarksMoved = true
                            self.sidebarObservationDirty = true
                        }
                        if name == SavedChatStore.didChange { self.sidebarObservationDirty = true }
                        self.scheduleSidebarRender()
                    }
                })
        }
    }

    /// A change landed in `entries` rather than in a store: the fleet-wide work the list speaks
    /// for is due, and the draw that follows is coalesced with every other request.
    func noteListingMoved() {
        sidebarListingVersion += 1
        sidebarObservationDirty = true
        scheduleSidebarRender()
    }

    /// Draws the list now, the fleet walked on the GTK thread: what a press, a keystroke in the
    /// filter or a bench needs, because the person is looking at the row that moves.
    func drawSidebar() {
        guard !sidebarTornDown, !Gtk.isQuitting else { return }
        if let sidebarFixture {
            drawSidebarFixture(sidebarFixture)
            return
        }
        if sidebarPointerHeld {
            sidebarRenderHeld = true
            return
        }
        sidebarGeneration += 1
        Trace.mark("renderSidebar begin \(entries.count) entries")
        defer { Trace.mark("renderSidebar end") }
        let began = SidebarWalk.threadTime()
        let plan = sidebarPlan()
        var cache = sidebarRowCache
        let walked = SidebarWalk.threadTime()
        let walk = SidebarWalk.make(plan.input, cache: &cache)
        sidebarRowCache = cache
        let presented = SidebarWalk.threadTime()
        presentSidebar(walk, plan: plan)
        sidebarCost = (presented - walked, SidebarWalk.threadTime() - presented + walked - began)
    }

    /// Draws the list for something the listing, a presence or a store said, which nobody pressed:
    /// the fleet is walked on a dispatch worker (``SidebarWalk``) and only the patching comes back
    /// to the GTK thread. One walk is out at a time and owns the row cache while it is; a request
    /// that arrives meanwhile is drawn once after it lands, and a draw made in between — a press,
    /// a keystroke in the filter — makes the walk stale, so it is dropped with its cache.
    func drawSidebarAway() {
        guard !sidebarTornDown, !Gtk.isQuitting else { return }
        guard sidebarFixture == nil else { return drawSidebar() }
        if sidebarPointerHeld {
            sidebarRenderHeld = true
            return
        }
        guard !sidebarWalking else {
            sidebarWalkAgain = true
            return
        }
        sidebarGeneration += 1
        let generation = sidebarGeneration
        let began = SidebarWalk.threadTime()
        let plan = sidebarPlan()
        let planned = SidebarWalk.threadTime() - began
        let cache = sidebarRowCache
        sidebarWalking = true
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var cache = cache
            let walkBegan = SidebarWalk.threadTime()
            let walk = SidebarWalk.make(plan.input, cache: &cache)
            let walked = SidebarWalk.threadTime() - walkBegan
            Gtk.onMain { [weak self, cache] in
                guard let self else { return }
                self.sidebarWalking = false
                defer {
                    if self.sidebarWalkAgain {
                        self.sidebarWalkAgain = false
                        self.scheduleSidebarRender()
                    }
                }
                guard !self.sidebarTornDown, !Gtk.isQuitting, self.sidebarGeneration == generation
                else { return }
                if self.sidebarPointerHeld {
                    self.sidebarRenderHeld = true
                    return
                }
                self.sidebarRowCache = cache
                Trace.mark(
                    "renderSidebar begin \(plan.input.entries.count) entries, walked away in \(Int(walked.rounded())) ms, planned in \(Int(planned.rounded())) ms")
                defer { Trace.mark("renderSidebar end") }
                let presented = SidebarWalk.threadTime()
                self.presentSidebar(walk, plan: plan)
                self.sidebarCost = (walked, SidebarWalk.threadTime() - presented + planned)
            }
        }
    }

    /// What a draw reads on the GTK thread before the fleet is walked.
    struct SidebarPlan: Sendable {
        let input: SidebarWalk.Input
        let selectedID: String?
        let canDraw: Bool
    }

    private func sidebarPlan() -> SidebarPlan {
        let readings = sidebarStoreReadings()
        let observe = sidebarListingVersion != sidebarObservedListing || sidebarObservationDirty
        if observe {
            sidebarObservedListing = sidebarListingVersion
            sidebarObservationDirty = false
        }
        let input = SidebarWalk.Input(
            entries: entries, pendingDeletes: pendingDeletes, unreachable: unreachable,
            lastHeard: lastHeard, savedChats: readings.savedChats, saved: readings.saved,
            pins: readings.pins, archived: readings.archived, unread: readings.unread,
            presence: observedPresence(), needle: filter.lowercased(), projectScope: projectScope,
            showingArchive: showingArchive,
            splitTab: showingArchive ? nil : SplitTab(snapshot: splitHost.snapshot()),
            observe: observe, now: Date())
        return SidebarPlan(input: input, selectedID: activePane.sessionID, canDraw: sidebarWindowVisible)
    }

    /// Rebuilding two hundred rows of widgets is a visible stutter — nothing is touched unless
    /// what the list would say actually differs from what it says now, and only the first
    /// screenful or two are built. A list nobody can see keeps its models and its side effects (the
    /// notices and the orb read them) and leaves its widgets alone until it can be seen.
    private func presentSidebar(_ walk: SidebarWalk, plan: SidebarPlan) {
        let canDraw = plan.canDraw
        defer { if canDraw { scheduleRowVerbsRefresh() } }
        let selectedID = plan.selectedID
        let rows = walk.rows
        let sections = walk.sections
        let archivedTotal = walk.archivedTotal
        for server in walk.servers {
            Notifier.shared.noteServer(profileID: server.profileID, name: server.name)
        }
        sidebarDirtyKeys.formUnion(walk.rebuilt)
        sidebarDirtyKeys.formUnion(walk.orphanKeys)
        orbTarget = walk.orbTarget
        orbKinds = walk.orbKinds
        refreshOrb()
        refreshAgentsEntry(rows: rows)
        if let observations = walk.observations {
            Notifier.shared.observeListing(observations, windowActive: windowIsActive)
            ActivityInbox.reconcile(
                observations,
                authoritativeProfileIDs: listedFromNetwork
                    ? Set(observations.map(\.profileID)) : [],
                isUnread: plan.input.unread)
        }
        if sidebarReadMarksMoved {
            sidebarReadMarksMoved = false
            Notifier.shared.withdrawRead()
        }
        visible = walk.visible
        sidebarBoardOfKey = walk.boardOfKey
        sidebarMissedReasons = Dictionary(
            ActivityInbox.all().map { ($0.sessionID, $0.reason) },
            uniquingKeysWith: { first, _ in first })
        let asks = observedAsks()
        let asksMoved = Set(asks.keys).union(sidebarAsks.keys).filter { asks[$0] != sidebarAsks[$0] }
        sidebarAsks = asks
        if !marks.isEmpty { marks.prune(to: visibleEntries) }
        syncCursorToSelection()
        guard canDraw else { return }


        let drawn = visible.prefix(sidebarLimit).flatMap { item -> [SessionRowModel] in
            switch item {
            case .chat(let row): return [row]
            case .tab(let tab): return tab.members
            }
        }
        let missed = ActivityInbox.unsaid(by: drawn, limit: 5)
        let listed = missed.all
        let vocabulary = walk.vocabulary
        let snapshot = (
            walk.order, unreachable, filter,
            "\(sidebarLimit)|\(showingArchive)|\(archivedTotal)|\(splitHost.paneCount)|\(marks.keys.sorted().joined(separator: ","))|\(missed.total)|\(missed.shown.map(\.identifier).joined(separator: ","))|\(projectScope.map { "\($0.profileID):\($0.directory ?? "")" } ?? "")|\(sections.map { "\($0.0.key):\($0.1.count)" }.joined(separator: ","))|\(vocabulary.namesServer)\(vocabulary.namesBackend)|\(knownProfiles.isEmpty)"
        )
        let previous = lastVisible
        lastVisible = visible
        let changed = sidebarDirtyKeys
        sidebarDirtyKeys = []
        if let last = lastSidebar, last == snapshot {
            refreshChangedSidebarRows(
                from: previous, vocabulary: vocabulary, changed: changed, asked: Set(asksMoved))
            refreshSidebarHeadings(sections)
            markFocusedRow(selectedID)
            return
        }
        lastSidebar = snapshot
        sidebarHeadings = [:]

        let scrollTarget = sidebarScrollTarget ?? sidebarScrollValue()
        sidebarScrollTarget = nil
        defer { restoreSidebarScroll(scrollTarget) }
        sidebarRows = []

        Gtk.removeChildren(of: sidebarBanner)
        if let scope = projectScope {
            let serverName =
                entries.first { $0.profileID == scope.profileID }?.profileName ?? scope.profileID
            let clear = Gtk.button(
                Localized.text("%@ ✕", scope.banner(serverName: serverName)), css: ["flat", "dim"]
            ) { [weak self] in
                Gtk.onMain { [weak self] in self?.setProjectScope(nil) }
            }
            Gtk.margins(clear, top: 4, bottom: 0)
            gtk_box_append(ptr(sidebarBanner), clear)
            let mint = Gtk.button(
                Localized.text("＋ New chat in %@", scope.name), css: ["flat", "dim"]
            ) { [weak self] in
                Gtk.onMain { [weak self] in
                    self?.createChat(
                        onProfileID: scope.profileID, directory: scope.directory)
                }
            }
            Gtk.margins(mint, top: 0, bottom: 2)
            gtk_box_append(ptr(sidebarBanner), mint)
        }
        if !unreachable.isEmpty {
            let line = Localized.text(
                "%@ unreachable — showing what was last seen", unreachable.joined(separator: ", "))
            gtk_box_append(
                ptr(sidebarBanner),
                SidebarRow.banner(reach.map { "\(line)\n\($0.deskHint)" } ?? line))
        }
        if !marks.isEmpty { gtk_box_append(ptr(sidebarBanner), makeSelectionBar()) }

        Gtk.removeChildren(of: sidebarList)
        if searchRunning || searchBoard != nil {
            renderSearchResults()
            return
        }
        if !showingArchive, !missed.shown.isEmpty {
            gtk_box_append(
                ptr(sidebarList),
                SidebarRow.missedHeader(count: missed.total) {
                    Gtk.onMain { [weak self] in
                        ActivityInbox.clear(listed)
                        self?.renderSidebar()
                    }
                })
            for item in missed.shown {
                let sessionID = item.sessionID
                gtk_box_append(
                    ptr(sidebarList),
                    SidebarRow.missed(item) { [weak self] in
                        Gtk.onMain { [weak self] in self?.openMissed(sessionID: sessionID) }
                    })
            }
            if missed.total > missed.shown.count {
                gtk_box_append(
                    ptr(sidebarList),
                    SidebarRow.empty(
                        Localized.text("… %@ more", "\(missed.total - missed.shown.count)")))
            }
        }
        if showingArchive {
            gtk_box_append(
                ptr(sidebarList),
                Gtk.button(Localized.text("← All chats"), css: ["flat", "dim"]) { [weak self] in
                    Gtk.onMain { [weak self] in self?.setArchiveShown(false) }
                })
        }
        guard !visible.isEmpty else {
            // An empty list with no server behind it is not "no conversations yet" — it is a setup
            // that never finished, and the only screen that could finish it has been dismissed.
            // Pressing Later used to leave a window with no visible road anywhere.
            if !showingArchive, filter.isEmpty, projectScope == nil, knownProfiles.isEmpty {
                gtk_box_append(ptr(sidebarList), SidebarRow.empty(EmptyWelcome.sidebarLine))
                gtk_box_append(
                    ptr(sidebarList),
                    Gtk.button(EmptyWelcome.setUpTitle, css: ["flat"]) { [weak self] in
                        Gtk.onMain { [weak self] in self?.presentAddMachine() }
                    })
                return
            }
            gtk_box_append(
                ptr(sidebarList),
                SidebarRow.empty(
                    showingArchive
                        ? Localized.text("Nothing archived")
                        : !filter.isEmpty
                            ? Localized.text("Nothing matches “%@”", filter)
                            : projectScope.map { Localized.text("Nothing in %@ yet", $0.name) }
                                ?? Localized.text("No conversations yet")))
            appendArchiveFooter(archivedTotal)
            return
        }

        var built = 0
        for (section, members) in sections {
            guard built < sidebarLimit else { break }
            let heading = SidebarRow.header(SectionHeading(section: section, items: members))
            sidebarHeadings[section.key] = Gtk.WeakWidget(heading.fresh)
            gtk_box_append(ptr(sidebarList), heading.row)
            for item in members {
                guard built < sidebarLimit else { break }
                let widget = makeSidebarItem(item, vocabulary: vocabulary)
                gtk_box_append(ptr(sidebarList), widget)
                sidebarRows.append(
                    SidebarRowWidget(
                        key: item.key, sessionIDs: item.entries.map(\.session.id),
                        widget: widget, face: sidebarFace(of: item, vocabulary: vocabulary)))
                built += 1
            }
        }
        let remaining = visible.count - built
        if remaining > 0 {
            let more = Gtk.button(
                Localized.text("%@ more chats", "\(remaining)"), css: ["flat", "dim"]
            ) { [weak self] in
                Gtk.onMain { [weak self] in
                    guard let self else { return }
                    self.sidebarLimit += 200
                    self.lastSidebar = nil
                    self.renderSidebar()
                }
            }
            Gtk.margins(more, top: 6, bottom: 10)
            gtk_box_append(ptr(sidebarList), more)
        }
        appendArchiveFooter(archivedTotal)
    }

    /// How many of the chats this window is listing are filed away, which is what the door is
    /// allowed to claim: the store outlives the sessions in it, so a key left behind by a chat no
    /// server has any more must not be counted as something there is to go and look at.
    func archivedCount() -> Int {
        let filed = ArchivedChatStore.keys()
        return entries.count {
            filed.contains(
                ArchivedChatStore.ChatKey(profileID: $0.profileID, sessionID: $0.session.id))
        }
    }

    /// A door at the foot of the list, and another in the menu, because the foot of a list three
    /// hundred chats long is not a place anybody arrives at.
    func appendArchiveFooter(_ archivedTotal: Int) {
        guard !showingArchive, archivedTotal > 0 else { return }
        let button = Gtk.button(
            Localized.text("%@ archived", "\(archivedTotal)"), css: ["flat", "dim"]
        ) { [weak self] in
            Gtk.onMain { [weak self] in self?.setArchiveShown(true) }
        }
        Gtk.margins(button, top: 6, bottom: 10)
        gtk_box_append(ptr(sidebarList), button)
    }

    /// What the panes on screen are watching, keyed on `(profileID, sessionID)` like every store
    /// here, so a conversation this window is streaming reaches LIVE NOW without waiting for the
    /// server's next sweep. Two panes on one chat resolve to the louder answer: a pane that knows
    /// nothing must never overwrite the one that knows a turn is running. Conversations a pane
    /// moved on from are still watched in the background, and their reading counts the same way.
    /// One of every row the list can draw, in place of the listing: a picture of the grammar that
    /// no real listing ever holds all at once. The rows open nothing.
    private func drawSidebarFixture(_ sections: [ChatListFixture.Section]) {
        sidebarRows = []
        sidebarHeadings = [:]
        lastSidebar = nil
        Gtk.removeChildren(of: sidebarBanner)
        Gtk.removeChildren(of: sidebarList)
        let vocabulary = ChatListFixture.vocabulary()
        for section in sections {
            gtk_box_append(ptr(sidebarList), SidebarRow.header(section.heading).row)
            for row in section.rows {
                gtk_box_append(
                    ptr(sidebarList),
                    SidebarRow.make(
                        row.model,
                        focused: row.model.entry.session.id == ChatListFixture.openSessionID,
                        vocabulary: vocabulary, section: row.section, news: row.news,
                        onOpen: {}, onMenu: { _, _, _ in }))
            }
        }
    }

    /// The count of new rows beside each standing heading, written in place: a chat that was just
    /// read changes a figure, and a figure is not worth rebuilding the list under it.
    func refreshSidebarHeadings(_ sections: [(ChatListSection, [ChatListItem])]) {
        for (section, members) in sections {
            guard let label = sidebarHeadings[section.key]?.widget else { continue }
            SidebarRow.setFresh(label, SectionHeading(section: section, items: members).freshLabel)
        }
    }

    /// What the panes that are waiting on the person are waiting for, in a row's own words. Read
    /// only for a pane that is actually waiting, which is rare and is the one time the question is
    /// worth the walk through its turn.
    func observedAsks() -> [String: ApprovalAsk] {
        var asks: [String: ApprovalAsk] = [:]
        splitHost.eachPane { pane in
            guard pane.presence == .awaitingApproval, let entry = pane.entry,
                let state = pane.lastState, let ask = ApprovalAsk.reading(in: state)
            else { return }
            asks[SessionPinStore.key(entry.profileID, entry.session.id)] = ask
        }
        return asks
    }

    func observedPresence() -> [String: SessionPresence] {
        var observed = backgroundPresence
        splitHost.eachPane { pane in
            guard let entry = pane.entry else { return }
            let key = SessionPinStore.key(entry.profileID, entry.session.id)
            let presence = pane.presence
            guard presence.rank > (observed[key] ?? .unsettled).rank else { return }
            observed[key] = presence
        }
        presenceLedger.absorb(observed)
        return presenceLedger.readings()
    }

    /// One line describing the selection, for the headless driver: how many are held, and which
    /// rows they are in the order the list is drawing them.
    var marksSummary: String {
        let titles = marks.resolve(in: visibleEntries).map { entry in
            SessionRowModel(entry: entry, unreachable: false, unread: false, saved: false).title
        }
        return "\(marks.count) [\(titles.joined(separator: " | "))]"
    }

    func sidebarScrollValue() -> Double {
        guard let sidebarScroller else { return 0 }
        return gtk_adjustment_get_value(gtk_scrolled_window_get_vadjustment(op(sidebarScroller)))
    }

    /// The reader's place survives the rebuild, not just the frame after it. An idle callback at
    /// default priority runs *before* GTK's layout pass, so the fresh rows have no height yet and
    /// the pass that follows clamps the adjustment back toward the top — which is the list
    /// yanking itself up under a reader mid-scroll every time a working session changes state.
    /// So the offset is set at once for the common case where the range survives, and then held
    /// as a standing target that `notify::upper` re-applies for as long as the rebuild is still
    /// settling; the target is dropped after a beat so a later window resize cannot replay a
    /// stale position.
    func restoreSidebarScroll(_ value: Double) {
        sidebarScrollRestore = value
        reapplySidebarScroll()
        Gtk.after(400) { [weak self] in
            guard let self, self.sidebarScrollRestore == value else { return }
            self.sidebarScrollRestore = nil
        }
    }

    func reapplySidebarScroll() {
        guard let target = sidebarScrollRestore, let sidebarScroller,
            let adjustment = gtk_scrolled_window_get_vadjustment(op(sidebarScroller))
        else { return }
        let ceiling = max(
            0, gtk_adjustment_get_upper(adjustment) - gtk_adjustment_get_page_size(adjustment))
        gtk_adjustment_set_value(adjustment, min(target, ceiling))
    }

    /// Which chat is open changes far more often than which chats there are — every press in
    /// another pane is one — and rebuilding a list of six hundred rows to move an accent is both
    /// the cost of that press and the only chance the list ever gets to move under the reader. So
    /// the accent is taken off the rows that are on screen and put on the one that is open.
    /// Redraws only the rows whose model changed since the last draw, each in its own place. The
    /// keys and the sections matched, so every row already has a widget in the right slot; a row
    /// whose words moved gets a fresh widget in that slot and every other row keeps the one the
    /// reader may be pressing on.
    ///
    /// - Parameter asked: the rows whose question moved while nothing else about them did. What a
    ///   waiting turn wants is not in its row model, so a second permission behind the first would
    ///   otherwise leave the row asking for the one already answered.
    func refreshChangedSidebarRows(
        from previous: [ChatListItem], vocabulary: ChatListVocabulary, changed: Set<String>,
        asked: Set<String> = []
    ) {
        guard previous.count == visible.count else { return }
        for (index, item) in visible.enumerated() {
            guard index < sidebarRows.count else { break }
            if changed.isEmpty, asked.isEmpty, !item.isTab { continue }
            let moved = asked.contains(item.key)
            guard sidebarRows[index].key == item.key,
                changed.contains(item.key) || item.isTab || moved,
                previous[index] != item || moved, let old = sidebarRows[index].widget
            else { continue }
            let face = sidebarFace(of: item, vocabulary: vocabulary)
            if let face, face == sidebarRows[index].face, case .chat(let row) = item,
                SidebarRow.patchWords(
                    old, model: row, vocabulary: vocabulary, section: sidebarBoardOfKey[item.key],
                    news: sidebarNews(for: row, key: item.key))
            {
                continue
            }
            let fresh = makeSidebarItem(item, vocabulary: vocabulary)
            gtk_box_insert_child_after(ptr(sidebarList), fresh, old)
            gtk_box_remove(ptr(sidebarList), old)
            sidebarRows[index] = SidebarRowWidget(
                key: item.key, sessionIDs: item.entries.map(\.session.id), widget: fresh, face: face)
        }
    }

    func holdSidebar() {
        warmChatPressed()
        sidebarPointerHeld = true
        Gtk.after(Self.sidebarHoldCeiling) { [weak self] in
            Gtk.onMain { [weak self] in self?.releaseSidebar() }
        }
    }

    /// A press the toolkit never finishes must not freeze the list, so the ceiling releases too.
    func releaseSidebar() {
        guard sidebarPointerHeld else { return }
        sidebarPointerHeld = false
        guard sidebarRenderHeld else { return }
        sidebarRenderHeld = false
        renderSidebar()
    }

    func markFocusedRow(_ selectedID: String?) {
        guard !sidebarTornDown else { return }
        for row in sidebarRows {
            guard let widget = row.widget else { continue }
            SidebarRow.setFocused(widget, selectedID.map(row.sessionIDs.contains) ?? false)
        }
    }

    /// The list follows the keyboard cursor, and that is the only reason it moves on its own: a
    /// row already in view is left exactly where it is, and one past either edge is brought just
    /// inside it rather than centred, so J down a long list reads as the list following a hand.
    /// A rebuild has no allocations to measure yet, so the row is named as a standing target that
    /// the layout pass re-tries — and a reveal outranks the position the rebuild was holding,
    /// which is the one case where the two disagree.
    func revealCursorRow() {
        guard cursor < visible.count else { return }
        let target = visible[cursor].key
        sidebarReveal = target
        applySidebarReveal()
        Gtk.after(120) { [weak self] in
            guard let self, self.sidebarReveal == target else { return }
            self.sidebarReveal = nil
        }
    }

    func applySidebarReveal() {
        guard let target = sidebarReveal,
            let widget = sidebarRows.first(where: { $0.key == target })?.widget,
            let sidebarScroller,
            let adjustment = gtk_scrolled_window_get_vadjustment(op(sidebarScroller))
        else { return }
        let height = Double(gtk_widget_get_height(widget))
        let top = tailscode_widget_offset_y(widget, sidebarList)
        guard height > 0, top >= 0 else { return }
        let page = gtk_adjustment_get_page_size(adjustment)
        let value = gtk_adjustment_get_value(adjustment)
        let landing =
            top < value
            ? top
            : top + height > value + page ? min(top + height - page, gtk_adjustment_get_upper(adjustment) - page) : value
        sidebarReveal = nil
        guard landing != value else { return }
        sidebarScrollRestore = nil
        gtk_adjustment_set_value(adjustment, max(0, landing))
    }

    /// The highlight follows the conversation that is open, never a position. The keyboard cursor
    /// is re-derived from the open chat so J/K continues from where the eye is.
    func syncCursorToSelection() {
        guard !visible.isEmpty else {
            cursor = 0
            return
        }
        if let selectedID = activePane.sessionID,
            let index = visible.firstIndex(where: { item in
                item.entries.contains { $0.session.id == selectedID }
            })
        {
            cursor = index
        } else {
            cursor = min(cursor, visible.count - 1)
        }
    }

    func applyFilterFromEntry() {
        guard let raw = gtk_editable_get_text(op(searchEntry)) else { return }
        let text = String(cString: raw)
        // Typing again is the way back to the list: results are about words that were submitted,
        // and leaving them up while the box says something else would be a lie about both.
        if searchBoard != nil || searchRunning { leaveTranscriptSearch(render: false) }
        filter = text
        cursor = 0
        renderSidebar()
    }
}
