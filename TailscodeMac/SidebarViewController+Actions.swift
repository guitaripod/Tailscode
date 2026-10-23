import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

extension SidebarViewController {
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
    /// `reveal` scrolls the list to the row. A person who asked for a chat — a click, a key, a
    /// notification — wants to see where it is; a window that is merely coming back to the chat it
    /// had is not asking, and a list that opens already scrolled past its pins, its missed news
    /// and its live chats reads as broken before anything has been touched.
    func open(_ entry: SessionEntry, freshlyCreated: Bool = false, reveal: Bool = true) {
        let alreadyShowing =
            focusedSessionID.map { $0() == entry.session.id } ?? (selectedID == entry.session.id)
        selectedID = entry.session.id
        SessionSeenStore.markSeen(entry.session.id)
        MacNotifier.clearNotices(sessionID: entry.session.id)
        render()
        if reveal { scrollSelectionIntoView() }
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
    func toggleMark(_ item: ChatListItem) {
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
        let filed = ArchivedChatStore.toggle(
            profileID: entry.profileID, sessionID: entry.session.id)
        render()
        let row = SessionRowModel(
            entry: entry, unreachable: false, unread: false, saved: false,
            presence: (presenceSource?() ?? lastPresence)[ChatSelection.key(entry)] ?? .unobserved)
        let word = ChatArchiveRule.word(
            filed: filed, title: row.title, unfinished: row.isUnfinished)
        announce?([word, deviceOnlyNotice(for: entry)].compactMap { $0 }.joined(separator: "\n"))
    }

    func togglePinned(_ entry: SessionEntry) {
        SessionPinStore.toggle(profileID: entry.profileID, sessionID: entry.session.id)
        render()
        if let notice = deviceOnlyNotice(for: entry) { announce?(notice) }
    }

    /// Said once per server per launch: a person pinning a dozen chats on a machine that keeps no
    /// marks needs to hear it the first time, not at every press.
    private func deviceOnlyNotice(for entry: SessionEntry) -> String? {
        guard let notice = SessionMarks.deviceOnlyNotice(for: entry),
            toldDeviceOnly.insert(entry.profileID).inserted
        else { return nil }
        return notice
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
        guard !presenceRenderPending else { return }
        presenceRenderPending = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.presenceSettle) { [weak self] in
            guard let self else { return }
            self.presenceRenderPending = false
            let presence = self.presenceSource?() ?? [:]
            guard presence != self.lastPresence else { return }
            self.render()
        }
    }

    private static let presenceSettle: TimeInterval = 0.25

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
                do {
                    try await backend.renameSession(sessionID, title: title)
                } catch {
                    self?.onNotice?(Localized.text("Couldn't rename this conversation."))
                }
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
            guard let session = try? await backend.forkSession(entry.session.id) else {
                self?.onNotice?(Localized.text("Couldn't fork this conversation."))
                return
            }
            let forked = SessionEntry(
                profileID: entry.profileID, profileName: entry.profileName, host: entry.host,
                backendType: entry.backendType, session: session)
            await self?.refresh()
            self?.open(forked)
        }
    }
}
