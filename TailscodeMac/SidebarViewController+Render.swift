import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

extension SidebarViewController {
    func startRefreshing() {
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
            var next = entries.filter {
                !($0.profileID == profile.id && $0.session.id == session.id)
            }
            next.append(entry)
            next.sort { $0.session.updatedAt > $1.session.updatedAt }
            entries = next
            if !next.isEmpty { SessionListCache.scheduleSave(next) }
            SessionMarks.reconcile(with: [entry])
            render()
            if retitled { onTitleChanged?() }
        case .remove(let id):
            entries.removeAll { $0.profileID == profile.id && $0.session.id == id }
            render()
        case .invalidated:
            Task { [weak self] in await self?.refresh() }
        }
    }

    /// Opens the conversation that was open last, not merely the newest one: reopening where you
    /// were is the difference between a window that restores and a window that resets.
    func applyEntries(
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
        open(remembered ?? entries[0], reveal: false)
    }

    /// Rebuilding the whole table is what the 10-second refresh would do whether or not anything
    /// changed — so nothing is touched unless what the list would say actually differs from what
    /// it says now.
    func render() {
        if NSEvent.pressedMouseButtons != 0, view.window?.isKeyWindow == true {
            holdRender()
            return
        }
        let interval = Pace.signposter.beginInterval("list")
        defer { Pace.signposter.endInterval("list", interval) }
        let savedChats = SavedChatStore.all()
        let saved = Set(savedChats.map(\.sessionID))
        let unread = SessionSeenStore.unreadEvaluator()
        let needle = filter.lowercased()
        let presence = presenceSource?() ?? [:]
        lastPresence = presence
        let pins = Set(SessionPinStore.all())
        var models = entries.filter { !pendingDeletes.contains(ChatSelection.key($0)) }.map {
            SessionRowModel(
                entry: $0,
                unreachable: unreachable.contains(
                    ServerLabel.display(name: $0.profileName, backend: $0.backendType)),
                unread: unread($0.session.id, $0.session.updatedAt),
                saved: saved.contains($0.session.id),
                pinned: pins.contains(SessionPinStore.key($0.profileID, $0.session.id)),
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
                title: $0.title, isActive: $0.entry.session.isActive == true,
                updatedAt: $0.entry.session.updatedAt)
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
        let active = matching.filter { !isArchived($0) || $0.isUnfinished }
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
            if ServerDirectory.shared.profiles.isEmpty {
                next.append(.addMachine(EmptyWelcome.setUpTitle))
            }
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
        refreshHover()
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
}
