import TailscodeCore
import UIKit

extension SessionListViewController {
    func bind() {
        viewModel.onChange = { [weak self] in
            self?.updateComposeButton()
            self?.rebuildChips()
            self?.updateUnreachableNotice()
            self?.applySnapshot()
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
            MainActor.assumeIsolated { self?.activityDidChange() }
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(activityDidChange),
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
        applySnapshot()
    }

    @objc private func archiveDidChange() {
        updateComposeButton()
        applySnapshot()
    }

    @objc private func activityDidChange() {
        reconfigureActivity()
        rebuildChips()
    }

    /// A turn starting or stopping moves the row between sections, not just its pill, so the whole
    /// snapshot is rebuilt rather than the visible cells reloaded — a chat that just went live must
    /// arrive in WORKING, never wear a spinner down in RECENT.
    func reconfigureActivity() {
        guard dataSource != nil else { return }
        applySnapshot()
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
        var list = viewModel.entries.filter {
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

    /// The listing as the shared `groupIntoSections` groups it — NEEDS YOU, WORKING, PINNED, SAVED, RECENT,
    /// with empty sections dropped so no heading ever sits over nothing. Every row carries the
    /// presence this device knows first-hand, which is what puts the conversation being streamed
    /// right now in WORKING instead of waiting for the server's next sweep to agree.
    private func sectionedRows(for entries: [SessionEntry]) -> [(SessionSection, [SessionRowModel])]
    {
        let saved = Set(SavedChatStore.all().map { SessionPinStore.key($0.profileID, $0.sessionID) })
        let context = RowContext.read(saved: saved, unreachable: Set(viewModel.unreachable))
        return groupIntoSections(entries.map { rowModel(for: $0, in: context) })
    }

    /// The flattened order the sections draw becomes `visibleEntries` — the one list the keyboard
    /// cursor, select-all and the held selection all address, because an `IndexPath` into a
    /// sectioned snapshot is not a position a person has.
    func applySnapshot() {
        guard mayRender() else { return }
        let entries = filteredEntries()
        let sections = sectionedRows(for: entries)
        let rows = sections.flatMap(\.1)

        rowModels = Dictionary(
            rows.map { (SessionPinStore.key($0.entry.profileID, $0.entry.session.id), $0) },
            uniquingKeysWith: { first, _ in first })
        vocabulary = ChatListVocabulary(rows: rows)
        visibleEntries = rows.map(\.entry)
        selection.prune(to: visibleEntries)

        var snapshot = NSDiffableDataSourceSnapshot<SessionSection, SessionEntry>()
        for (section, members) in sections {
            snapshot.appendSections([section])
            snapshot.appendItems(members.map(\.entry), toSection: section)
        }
        let existing = Set(dataSource.snapshot().itemIdentifiers)
        let retained = visibleEntries.filter { existing.contains($0) }
        if !retained.isEmpty { snapshot.reconfigureItems(retained) }
        dataSource.apply(snapshot, animatingDifferences: hasAppeared)
        refreshControl.endRefreshing()
        clampKeyCursor()
        updateSelectionBar()
        updateEmptyState(itemCount: snapshot.numberOfItems)
        syncOpenMark()
        onListingChange?()
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
