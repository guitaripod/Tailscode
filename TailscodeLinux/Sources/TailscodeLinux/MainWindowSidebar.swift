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
        SidebarCadence.interval(at: CascadeBudget.level, visible: sidebarWindowVisible)
    }

    /// Asks for the list to be drawn. The first request after a quiet spell is drawn at once; the
    /// rest of a burst is one more draw at the end of the interval, which reads whatever is true
    /// by then, so the last state is always the one drawn.
    func scheduleSidebarRender() {
        guard !sidebarTornDown, !Gtk.isQuitting else { return }
        switch sidebarCoalescer.request(at: Self.sidebarClock, interval: sidebarInterval) {
        case .runNow:
            drawSidebar()
        case .covered:
            break
        case .wait(let delay, let token):
            Gtk.after(UInt32(max(1, (delay * 1000).rounded(.up)))) { [weak self] in
                guard let self, !self.sidebarTornDown,
                    self.sidebarCoalescer.fire(token: token, at: Self.sidebarClock)
                else { return }
                self.drawSidebar()
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
    }

    /// Rebuilding two hundred rows of widgets is a visible stutter — nothing is touched unless
    /// what the list would say actually differs from what it says now, and only the first
    /// screenful or two are built. A list nobody can see keeps its models and its side effects (the
    /// notices and the orb read them) and leaves its widgets alone until it can be seen.
    func drawSidebar() {
        guard !sidebarTornDown, !Gtk.isQuitting else { return }
        if sidebarPointerHeld {
            sidebarRenderHeld = true
            return
        }
        let canDraw = sidebarWindowVisible
        defer { if canDraw { scheduleRowVerbsRefresh() } }
        Trace.mark("renderSidebar begin \(entries.count) entries")
        defer { Trace.mark("renderSidebar end") }
        let selectedID = activePane.sessionID
        let savedChats = SavedChatStore.all()
        let saved = Set(savedChats.map(\.sessionID))
        let unread = SessionSeenStore.unreadEvaluator()
        let pinned = SessionPinStore.snapshot()
        let archivedKeys = ArchivedChatStore.all()
        let needle = filter.lowercased()
        let presence = observedPresence()
        let now = Date()
        sidebarRowCache.beginPass()
        var servers: [String: (unreachable: Bool, observedAt: Date?)] = [:]
        var rows: [SessionRowModel] = []
        rows.reserveCapacity(entries.count)
        for entry in entries {
            let key = SessionPinStore.key(entry.profileID, entry.session.id)
            if !pendingDeletes.isEmpty, pendingDeletes.contains(key) { continue }
            let serverKey = "\(entry.profileID)|\(entry.profileName)"
            let server: (unreachable: Bool, observedAt: Date?)
            if let known = servers[serverKey] {
                server = known
            } else {
                let label = ServerLabel.display(name: entry.profileName, backend: entry.backendType)
                server = (unreachable.contains(label), lastHeard[label])
                servers[serverKey] = server
                Notifier.shared.noteServer(profileID: entry.profileID, name: entry.profileName)
            }
            rows.append(
                sidebarRowCache.model(
                    for: entry, key: key, unreachable: server.unreachable,
                    unread: unread(entry.session.id, entry.session.updatedAt),
                    saved: saved.contains(entry.session.id), pinned: pinned.contains(key),
                    presence: presence[key] ?? .unobserved, observedAt: server.observedAt,
                    now: now))
        }
        sidebarRowCache.sweep()
        sidebarDirtyKeys.formUnion(sidebarRowCache.takeRebuilt())
        let listedCount = rows.count
        rows += Self.orphanedSavedRows(savedChats, listed: entries)
        for orphan in rows[listedCount...] {
            Notifier.shared.noteServer(
                profileID: orphan.entry.profileID, name: orphan.entry.profileName)
            sidebarDirtyKeys.insert(
                SessionPinStore.key(orphan.entry.profileID, orphan.entry.session.id))
        }
        orbTarget =
            rows.first { $0.state == .awaitingApproval }?.entry
            ?? rows.first { $0.state == .live }?.entry
        orbKinds = rows.map { $0.state.activity }
        refreshOrb()
        refreshAgentsEntry(rows: rows.map(\.state))
        let observations = rows.map {
            ActivityObservation(
                profileID: $0.entry.profileID, sessionID: $0.entry.session.id,
                title: $0.title, isActive: $0.entry.session.isActive == true,
                updatedAt: $0.entry.session.updatedAt)
        }
        Notifier.shared.observeListing(
            observations, openSessionID: selectedID, windowActive: windowIsActive)
        ActivityInbox.reconcile(
            observations,
            authoritativeProfileIDs: listedFromNetwork
                ? Set(observations.map(\.profileID)) : [])
        let candidates: [(row: SessionRowModel, archived: Bool)] = rows.map {
            (
                $0,
                archivedKeys.contains(
                    ArchivedChatStore.key($0.entry.profileID, $0.entry.session.id))
            )
        }
        let scoped =
            projectScope.map { scope in candidates.filter { scope.matches($0.row.entry) } }
            ?? candidates
        let archivedTotal = scoped.count { $0.archived }
        let matching =
            needle.isEmpty
            ? scoped
            : scoped.filter {
                $0.row.title.lowercased().contains(needle)
                    || $0.row.detail.lowercased().contains(needle)
                    || ($0.row.snippet?.lowercased().contains(needle) ?? false)
            }
        let grouped: [(String, [SessionRowModel])] =
            showingArchive
            ? [(Localized.text("ARCHIVED"), matching.filter { $0.archived }.map { $0.row })]
                .filter { !$0.1.isEmpty }
            : groupIntoSections(
                matching.filter { !$0.archived || $0.row.isUnfinished }.map { $0.row }
            ).map { ($0.0.title, $0.1) }
        let sections = SplitTabGrouping.apply(
            to: grouped, tab: showingArchive ? nil : SplitTab(snapshot: splitHost.snapshot()))
        visible = sections.flatMap(\.1)
        if !marks.isEmpty { marks.prune(to: visibleEntries) }
        syncCursorToSelection()
        guard canDraw else { return }

        let missed = ActivityInbox.ordered(limit: 5)
        let vocabulary = ChatListVocabulary(rows: rows)
        let snapshot = (
            visible.map(\.key), unreachable, filter,
            "\(sidebarLimit)|\(showingArchive)|\(archivedTotal)|\(splitHost.paneCount)|\(marks.keys.sorted().joined(separator: ","))|\(missed.total)|\(missed.shown.map(\.identifier).joined(separator: ","))|\(projectScope.map { "\($0.profileID):\($0.directory ?? "")" } ?? "")|\(sections.map { "\($0.0):\($0.1.count)" }.joined(separator: ","))|\(vocabulary.namesServer)\(vocabulary.namesBackend)|\(knownProfiles.isEmpty)"
        )
        let previous = lastVisible
        lastVisible = visible
        let changed = sidebarDirtyKeys
        sidebarDirtyKeys = []
        if let last = lastSidebar, last == snapshot {
            refreshChangedSidebarRows(from: previous, vocabulary: vocabulary, changed: changed)
            markFocusedRow(selectedID)
            return
        }
        lastSidebar = snapshot

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
            gtk_box_append(
                ptr(sidebarBanner),
                SidebarRow.banner(
                    Localized.text("%@ unreachable — showing what was last seen",
                        unreachable.joined(separator: ", "))))
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
                        ActivityInbox.clearAll()
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
        for (title, members) in sections {
            guard built < sidebarLimit else { break }
            gtk_box_append(
                ptr(sidebarList), SidebarRow.header(title, count: members.count))
            for item in members {
                guard built < sidebarLimit else { break }
                let widget = makeSidebarItem(item, vocabulary: vocabulary)
                gtk_box_append(ptr(sidebarList), widget)
                sidebarRows.append(
                    SidebarRowWidget(
                        key: item.key, sessionIDs: item.entries.map(\.session.id),
                        widget: widget))
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
        let filed = ArchivedChatStore.all()
        return entries.count { filed.contains(ArchivedChatStore.key($0.profileID, $0.session.id)) }
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
    func refreshChangedSidebarRows(
        from previous: [ChatListItem], vocabulary: ChatListVocabulary, changed: Set<String>
    ) {
        guard previous.count == visible.count else { return }
        for (index, item) in visible.enumerated() {
            guard index < sidebarRows.count else { break }
            if changed.isEmpty, !item.isTab { continue }
            guard sidebarRows[index].key == item.key, changed.contains(item.key) || item.isTab,
                previous[index] != item, let old = sidebarRows[index].widget
            else { continue }
            let fresh = makeSidebarItem(item, vocabulary: vocabulary)
            gtk_box_insert_child_after(ptr(sidebarList), fresh, old)
            gtk_box_remove(ptr(sidebarList), old)
            sidebarRows[index] = SidebarRowWidget(
                key: item.key, sessionIDs: item.entries.map(\.session.id), widget: fresh)
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
