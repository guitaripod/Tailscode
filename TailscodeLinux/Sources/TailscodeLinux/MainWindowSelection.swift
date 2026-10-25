import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension MainWindow {
    func makeSelectionBar() -> UnsafeMutablePointer<GtkWidget> {
        SidebarSelectionBar.make(
            count: marks.count,
            onClear: { [weak self] in
                Gtk.onMain { [weak self] in _ = self?.clearMarks() }
            },
            onAction: { [weak self] action in
                Gtk.onMain { [weak self] in self?.perform(bulk: action) }
            },
            onSplit: { [weak self] arrangement in
                Gtk.onMain { [weak self] in self?.openMarkedSplit(arrangement) }
            })
    }

    /// The selection spent on the window itself: every marked chat opens at once, tiled evenly in
    /// the chosen arrangement, in the order the list was drawing the rows. The tree replaces what
    /// the window held — the gesture asked for these conversations, and it persists like any
    /// hand-built layout.
    func openMarkedSplit(_ arrangement: SplitArrangement) {
        openSplit(marks.resolve(in: visibleEntries), as: arrangement)
    }

    func openSplit(_ chosen: [SessionEntry], as arrangement: SplitArrangement) {
        guard let layout = SplitEven.layout(count: chosen.count, as: arrangement) else { return }
        var sessions: [String: SplitPaneSession] = [:]
        for (pane, entry) in zip(layout.paneIDs, chosen) {
            sessions[pane.raw] = SplitPaneSession(
                profileID: entry.profileID, sessionID: entry.session.id)
        }
        _ = splitHost.restore(SplitSnapshot(layout: layout, sessions: sessions))
        openInTurns(Array(zip(layout.paneIDs, chosen)))
        splitHost.persist()
        marks.clear()
        lastSidebar = nil
        renderSidebar()
        focusedPaneChanged()
        splitHost.activePane.focusTranscript()
    }

    /// Every conversation the list is drawing, whatever it is grouped into — what a mark, a bulk
    /// verb and the driver's own index are spent on. A remembered split hands over all of its
    /// chats, because the row stands for all of them.
    var visibleEntries: [SessionEntry] {
        visible.flatMap(\.entries)
    }

    func makeSidebarItem(_ item: ChatListItem, vocabulary: ChatListVocabulary)
        -> UnsafeMutablePointer<GtkWidget>
    {
        switch item {
        case .chat(let row):
            return SidebarRow.make(
                row, focused: row.entry.session.id == activePane.sessionID,
                marked: marks.contains(row.entry), vocabulary: vocabulary,
                onOpen: { [weak self] in
                    self?.open(row.entry)
                },
                onMark: { [weak self] shifted in
                    Gtk.onMain { [weak self] in self?.mark(item: item, shifted: shifted) }
                },
                onAgents: { [weak self] in
                    Gtk.onMain { [weak self] in self?.presentAgentPeek(of: row.entry) }
                },
                onMenu: { [weak self] bits, x, y in
                    self?.presentRowMenu(row, rowBits: bits, x: x, y: y)
                })
        case .tab(let row):
            let open = activePane.sessionID
            return SidebarRow.tab(
                row, focused: open.map { id in row.members.contains { $0.entry.session.id == id } }
                    ?? false,
                marked: row.members.allSatisfy { marks.contains($0.entry) },
                onOpen: { [weak self] in
                    Gtk.onMain { [weak self] in self?.restoreSplit(row.tab) }
                },
                onOpenMember: { [weak self] index in
                    Gtk.onMain { [weak self] in
                        guard let self, index < row.members.count else { return }
                        self.goToMember(row.members[index].entry)
                    }
                },
                onMark: { [weak self] shifted in
                    Gtk.onMain { [weak self] in self?.mark(item: item, shifted: shifted) }
                },
                onMenu: { [weak self] bits, x, y in
                    self?.presentTabMenu(row, rowBits: bits, x: x, y: y)
                })
        }
    }

    /// Opening what a row stands for: a conversation is opened, a remembered split is put back in
    /// the window whole.
    func openItem(_ item: ChatListItem) {
        switch item {
        case .chat(let row): open(row.entry)
        case .tab(let row): restoreSplit(row.tab)
        }
    }

    /// The split collapsed onto one of its chats: that pane inherits the window, everything else
    /// closes, and the list separates. A member no pane is showing — the tree changed under the
    /// menu — is opened plainly instead of doing nothing.
    func unsplit(keeping entry: SessionEntry) {
        if let pane = splitHost.pane(showing: entry.session.id) {
            splitHost.collapse(to: pane)
        } else {
            splitHost.collapse(to: splitHost.activePane)
            open(entry)
        }
        lastSidebar = nil
        renderSidebar()
    }

    /// A member pressed on the split's row: its pane is already on screen, so the press goes to
    /// it — focused, keyboard and all — rather than opening the same chat a second time in
    /// whichever pane happened to hold the accent.
    func goToMember(_ entry: SessionEntry) {
        if let pane = splitHost.pane(showing: entry.session.id) {
            focused = .transcript
            splitHost.focus(pane, grabKeyboard: true)
            SessionSeenStore.markSeen(entry.session.id)
            renderSidebar()
            return
        }
        open(entry)
    }

    /// The row is the window's own arrangement, so pressing it goes to it rather than rebuilding
    /// it: the split is already on screen, and tearing down live streams to reopen the same chats
    /// would cost the reader exactly the panes they asked for.
    func restoreSplit(_ tab: SplitTab) {
        focused = .transcript
        splitHost.activePane.focusTranscript()
        focusedPaneChanged()
    }

    /// The split taken apart in one gesture: every pane but the focused one closes, and the
    /// merged row separates back into the plain rows it stood for — the chats themselves are
    /// exactly where they always were.
    func unsplitAll() {
        splitHost.collapse(to: splitHost.activePane)
        lastSidebar = nil
        renderSidebar()
    }

    /// The menu on the split's row: what it can be spent on as a selection, each chat inside it
    /// on its own, and the one gesture that takes the arrangement apart.
    func presentTabMenu(_ row: SplitTabRow, rowBits: UInt, x: Double, y: Double) {
        guard let raw = UnsafeMutableRawPointer(bitPattern: rowBits) else { return }
        let offsetY = tailscode_widget_offset_y(ptr(raw), sidebarList)
        guard offsetY >= 0 else { return }
        var rows: [(title: String, detail: String?, action: @Sendable () -> Void)] = bulkMenuRows()
        for member in row.members {
            let entry = member.entry
            rows.append(
                (Localized.text("Open just %@", member.title),
                 Localized.text("Unsplit down to this one chat"),
                 { [weak self] in
                     Gtk.onMain { [weak self] in self?.unsplit(keeping: entry) }
                 }))
        }
        rows.append(
            (Localized.text("Unsplit"),
             Localized.text("Back to one pane; the chats keep their own rows"),
             { [weak self] in
                 Gtk.onMain { [weak self] in self?.unsplitAll() }
             }))
        Gtk.contextMenu(on: sidebarList, x: x + 4, y: offsetY + y, rows: rows)
    }

    /// One press, two gestures: a plain press marks the row and anchors the next range; a
    /// shift-press rewrites the selection as the span the list is drawing between the anchored
    /// row and this one — the range re-measures from the same anchor on every shift-press.
    func mark(item: ChatListItem, shifted: Bool) {
        if shifted {
            marks.rangeSelect(item, in: visible)
        } else {
            marks.toggle(item)
        }
        lastSidebar = nil
        renderSidebar()
    }

    /// `space` marks the row the keyboard is on, which is the row the eye is on — the cursor, not
    /// whichever chat a background pane happens to be holding.
    func toggleMarkAtCursor() {
        guard cursor < visible.count else { return }
        mark(item: visible[cursor], shifted: false)
    }

    func toggleMarkAll() {
        marks.toggleAll(in: visibleEntries)
        lastSidebar = nil
        renderSidebar()
    }

    /// Answers whether there were marks to drop, so escape can spend itself on the selection and
    /// leave the rest of what it means — leaving insert, closing the finder — for the next press.
    @discardableResult
    func clearMarks() -> Bool {
        guard !marks.isEmpty else { return false }
        marks.clear()
        lastSidebar = nil
        renderSidebar()
        return true
    }

    func perform(bulk action: BulkChatAction) {
        let chosen = marks.resolve(in: visibleEntries)
        guard !chosen.isEmpty else { return }
        switch action {
        case .delete: confirmBulkDelete(chosen)
        case .archive, .unarchive, .save, .unsave, .markRead, .markUnread:
            applyLocalBulk(action, to: chosen)
        }
    }

    /// The verbs that only change what this device remembers land at once and without a dialog:
    /// nothing leaves the server, and every one of them is undone by the same row action that set
    /// it. The set is spent by the verb, because a selection that outlived its gesture would make
    /// the next `x` mean something nobody chose.
    func applyLocalBulk(_ action: BulkChatAction, to chosen: [SessionEntry]) {
        for entry in chosen {
            switch action {
            case .archive: setArchived(true, entry)
            case .unarchive: setArchived(false, entry)
            case .save: setSaved(true, entry)
            case .unsave: setSaved(false, entry)
            case .markRead: SessionSeenStore.markSeen(entry.session.id)
            case .markUnread:
                SessionSeenStore.markUnread(
                    entry.session.id, updatedAt: entry.session.updatedAt)
            case .delete: continue
            }
        }
        marks.clear()
        SettingsFile.capture()
        lastSidebar = nil
        renderSidebar()
        toast(BulkChatCopy.confirm(action, count: chosen.count))
    }

    func setArchived(_ archived: Bool, _ entry: SessionEntry) {
        guard
            ArchivedChatStore.contains(profileID: entry.profileID, sessionID: entry.session.id)
                != archived
        else { return }
        _ = ArchivedChatStore.toggle(profileID: entry.profileID, sessionID: entry.session.id)
    }

    func setSaved(_ saved: Bool, _ entry: SessionEntry) {
        guard SavedChatStore.contains(entry) != saved else { return }
        _ = SavedChatStore.toggle(entry)
    }

    /// A bulk delete states what it is about to remove before it removes anything — three chats by
    /// name, thirty as a number — because it reaches the servers and nothing here can undo it.
    func confirmBulkDelete(_ chosen: [SessionEntry]) {
        let titles = chosen.map {
            SessionRowModel(entry: $0, unreachable: false, unread: false, saved: false).title
        }
        Dialogs.confirm(
            title: BulkChatCopy.title(.delete, count: chosen.count),
            body: BulkChatCopy.message(count: chosen.count, titles: titles),
            confirmLabel: BulkChatCopy.confirm(.delete, count: chosen.count), parent: window
        ) { [weak self] in
            Gtk.onMain { [weak self] in self?.startBulkDelete(chosen) }
        }
    }

    /// Optimistic on confirm, like the single-row delete: the rows leave the list at once, every
    /// pane holding one of them is emptied or moved on, and the deletes go out together rather
    /// than in series — seven sessions across two servers is seven round trips nobody should
    /// watch queue up. The tombstones lift only after the refresh, so a delete the server has not
    /// acknowledged cannot be re-listed back into the list.
    func startBulkDelete(_ chosen: [SessionEntry]) {
        let doomed = Set(chosen.map { SessionPinStore.key($0.profileID, $0.session.id) })
        pendingDeletes.formUnion(doomed)
        entries.removeAll { doomed.contains(SessionPinStore.key($0.profileID, $0.session.id)) }
        if let fresh = freshlyCreated,
            doomed.contains(SessionPinStore.key(fresh.profileID, fresh.session.id))
        {
            freshlyCreated = nil
        }
        marks.clear()
        let sessionIDs = Set(chosen.map(\.session.id))
        let active = activePane
        splitHost.eachPane { pane in
            guard let id = pane.sessionID, sessionIDs.contains(id) else { return }
            if pane === active, let next = self.entries.first {
                pane.open(next)
            } else {
                pane.reset(placeholder: Localized.text("That conversation was deleted."))
            }
        }
        lastSidebar = nil
        renderSidebar()

        Task { [weak self] in
            let outcome = await Self.deleteConcurrently(chosen)
            await self?.refresh()
            Gtk.onMain { [weak self] in
                guard let self else { return }
                self.pendingDeletes.subtract(doomed)
                if let report = BulkChatCopy.outcome(outcome) {
                    self.activePane.setNotice(report)
                    Trace.mark("bulk delete: \(report)")
                }
                self.lastSidebar = nil
                self.renderSidebar()
            }
        }
    }

    /// Every delete at once, counted rather than thrown: three of seven failing has no precedent
    /// as a single error, so the first failure's reason speaks for the rest — a fan-out that fails
    /// almost always fails the same way for every row.
    static func deleteConcurrently(_ chosen: [SessionEntry]) async -> BulkChatOutcome {
        let profiles = await ServerDirectory.shared.profiles()
        var backends: [String: any CodingAgentBackend] = [:]
        for profile in profiles where chosen.contains(where: { $0.profileID == profile.id }) {
            backends[profile.id] = await ServerDirectory.shared.backend(for: profile)
        }
        return await withTaskGroup(of: String?.self) { group in
            for entry in chosen {
                guard let backend = backends[entry.profileID] else {
                    group.addTask { Localized.text("that server is not configured any more") }
                    continue
                }
                let sessionID = entry.session.id
                group.addTask {
                    do {
                        try await backend.deleteSession(sessionID)
                        return nil
                    } catch {
                        return "\(error)"
                    }
                }
            }
            var deleted = 0
            var failed = 0
            var reason: String?
            for await failure in group {
                guard let failure else {
                    deleted += 1
                    continue
                }
                failed += 1
                if reason == nil { reason = failure }
            }
            return BulkChatOutcome(deleted: deleted, failed: failed, reason: reason)
        }
    }

    /// Filing a chat away, and saying so: this is one keystroke, and a row that leaves the list
    /// without a word reads as a conversation the app lost rather than one it put away.
    @discardableResult
    /// Ends the work the chat's process is carrying between turns. The server says why when it
    /// cannot, and that sentence is the toast — and what the driver prints, so the whole path is
    /// provable headlessly.
    func stopBackgroundWork(
        _ entry: SessionEntry, on backend: any CodingAgentBackend,
        report: (@Sendable (String) -> Void)? = nil
    ) {
        Task { [weak self] in
            let word: String
            do {
                try await backend.stopBackgroundWork(sessionID: entry.session.id)
                word = Localized.text("Stopped the background work.")
            } catch {
                word = error.localizedDescription
            }
            Gtk.onMain { [weak self] in self?.toast(word) }
            report?(word)
        }
    }

    func toggleArchived(_ entry: SessionEntry) -> String {
        let filed = ArchivedChatStore.toggle(
            profileID: entry.profileID, sessionID: entry.session.id)
        SettingsFile.capture()
        renderSidebar()
        let row = SessionRowModel(
            entry: entry, unreachable: false, unread: false, saved: false,
            presence: observedPresence()[SessionPinStore.key(entry.profileID, entry.session.id)]
                ?? .unobserved)
        let word = ChatArchiveRule.word(
            filed: filed, title: row.title, unfinished: row.isUnfinished)
        toast(word)
        return word
    }

    func setArchiveShown(_ shown: Bool) {
        guard showingArchive != shown else { return }
        showingArchive = shown
        cursor = 0
        lastSidebar = nil
        sidebarScrollTarget = 0
        renderSidebar()
    }
}
