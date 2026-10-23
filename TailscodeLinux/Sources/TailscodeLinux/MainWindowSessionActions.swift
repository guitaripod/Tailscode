import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension MainWindow {
    /// The window is kept here as well as by the manager's own registry, so a second ask raises
    /// the one already open instead of stacking a second copy of a screen full of live probes.
    func presentServers(expandingEverything: Bool = false) {
        let manager = servers ?? ServerManager { [weak self] in
            Task { [weak self] in await self?.refresh() }
        }
        servers = manager
        manager.present(parent: window)
        if expandingEverything { manager.expandEverything() }
    }

    func presentRename(entry: SessionEntry, backend: any CodingAgentBackend) {
        let sessionID = entry.session.id
        Dialogs.prompt(
            title: Localized.text("Rename this conversation"), body: nil,
            placeholder: Localized.text("Title"),
            initial: entry.session.hasPlaceholderTitle ? "" : entry.session.title,
            confirmLabel: Localized.text("Rename"), parent: window
        ) { [weak self] title in
            guard !title.isEmpty else { return }
            Task { [weak self] in
                try? await backend.renameSession(sessionID, title: title)
                await self?.refresh()
                Gtk.onMain { [weak self] in
                    guard let self, self.activePane.sessionID == sessionID else { return }
                    gtk_label_set_text(op(self.titleLabel), title)
                }
            }
        }
    }

    func fork(entry: SessionEntry, backend: any CodingAgentBackend) {
        let sessionID = entry.session.id
        Task { [weak self] in
            guard let session = try? await backend.forkSession(sessionID) else { return }
            let forked = SessionEntry(
                profileID: entry.profileID, profileName: entry.profileName, host: entry.host,
                backendType: entry.backendType, session: session)
            await self?.refresh()
            Gtk.onMain { [weak self] in self?.open(forked) }
        }
    }

    func presentCompactPreflight(for pane: ChatPane, initialInstruction: String = "") {
        guard pane.conversation != nil else { return }
        Dialogs.compactPreflight(
            parent: window,
            facts: CompactPreflight.make(
                state: pane.lastState,
                showsInstruction: pane.backend?.capabilities.supportsCompactionInstructions ?? true),
            initialInstruction: initialInstruction,
            draft: pane.compactionScope
        ) { [weak pane] instruction in
            pane?.requestCompaction(instruction: instruction ?? "")
        }
    }

    /// The brief leaves as a prompt in the conversation it was asked from, so the board it produces
    /// lands in the transcript that will build it.
    func presentDesignPreflight(for pane: ChatPane, request: String = "") {
        presentDesignPreflight(for: pane, argument: request)
    }

    func presentDesignPreflight(for pane: ChatPane, argument request: String) {
        Dialogs.designPreflight(parent: window, request: request) { [weak pane] brief in
            Gtk.onMain { [weak pane] in pane?.sendComposed(brief.prompt) }
        }
    }

    func presentClear(entry: SessionEntry, backend: any CodingAgentBackend) {
        let sessionID = entry.session.id
        Dialogs.confirm(
            title: Localized.text("Clear this conversation?"),
            body: Localized.text("Everything in it goes away, on the server, for every device."),
            confirmLabel: Localized.text("Clear"), parent: window
        ) { [weak self] in
            Task { [weak self] in
                try? await backend.clearConversation(sessionID)
                await self?.refresh()
            }
        }
    }

    /// Optimistic on confirm: the row disappears and the next chat opens before the server has
    /// answered. Every pane showing the session empties with an explanation; the focused one
    /// moves on to the next chat.
    func presentDelete(entry: SessionEntry, backend: any CodingAgentBackend) {
        let sessionID = entry.session.id
        Dialogs.confirm(
            title: Localized.text("Delete this conversation?"),
            body: Localized.text(
                "It is removed from %@ for every device. A saved copy on this machine survives.",
                entry.profileName),
            confirmLabel: Localized.text("Delete"), parent: window
        ) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self else { return }
                self.pendingDeletes.insert(SessionPinStore.key(entry.profileID, sessionID))
                self.entries.removeAll {
                    $0.profileID == entry.profileID && $0.session.id == sessionID
                }
                if self.freshlyCreated?.session.id == sessionID { self.freshlyCreated = nil }
                let active = self.activePane
                self.splitHost.eachPane { pane in
                    guard pane.sessionID == sessionID else { return }
                    if pane === active, let next = self.entries.first {
                        pane.open(next)
                    } else {
                        pane.reset(placeholder: Localized.text("That conversation was deleted."))
                    }
                }
                self.renderSidebar()
            }
            Task { [weak self] in
                let failure: String?
                do {
                    try await backend.deleteSession(sessionID)
                    failure = nil
                } catch {
                    failure = "\(error)"
                }
                if failure == nil { await self?.refresh() }
                Gtk.onMain { [weak self] in
                    guard let self else { return }
                    self.pendingDeletes.remove(SessionPinStore.key(entry.profileID, sessionID))
                    if let failure {
                        self.activePane.setNotice(Localized.text("Could not delete: %@", failure))
                        self.renderSidebar()
                    }
                }
                if failure != nil { await self?.refresh() }
            }
        }
    }

    func toggleSaved(_ entry: SessionEntry) {
        _ = SavedChatStore.toggle(entry)
        SettingsFile.capture()
        renderSidebar()
    }

    func togglePinned(_ entry: SessionEntry) {
        SessionPinStore.toggle(profileID: entry.profileID, sessionID: entry.session.id)
        renderSidebar()
    }

    /// The right-click menu on a chat row, anchored to the sidebar's own box — a widget that
    /// outlives any re-render.
    func presentRowMenu(_ row: SessionRowModel, rowBits: UInt, x: Double, y: Double) {
        guard let raw = UnsafeMutableRawPointer(bitPattern: rowBits) else { return }
        let offsetY = tailscode_widget_offset_y(ptr(raw), sidebarList)
        guard offsetY >= 0 else { return }
        let anchorX = x + 4
        let anchorY = offsetY + y
        let entry = row.entry
        Task { [weak self] in
            let profiles = await ServerDirectory.shared.profiles()
            var backend: (any CodingAgentBackend)?
            if let profile = profiles.first(where: { $0.id == entry.profileID }) {
                backend = await ServerDirectory.shared.backend(for: profile)
            }
            let resolved = backend
            Gtk.onMain { [weak self] in
                guard let self else { return }
                Gtk.contextMenu(
                    on: self.sidebarList, x: anchorX, y: anchorY,
                    rows: self.rowMenuRows(row, backend: resolved))
            }
        }
    }

    /// While marks are held the menu leads with what they can be spent on, and each verb says so
    /// in its own detail line — a right click that landed on an unmarked row must never read as
    /// acting on that row when the selection is what it would take.
    func bulkMenuRows()
        -> [(title: String, detail: String?, action: @Sendable () -> Void)]
    {
        guard !marks.isEmpty else { return [] }
        let count = marks.count
        var rows: [(title: String, detail: String?, action: @Sendable () -> Void)] =
            SidebarSelectionBar.offered.map { action in
                (
                    BulkChatCopy.button(action, count: count),
                    Localized.text("%@ marked", "\(count)"),
                    { [weak self] in
                        Gtk.onMain { [weak self] in self?.perform(bulk: action) }
                    }
                )
            }
        rows += SplitEven.offers(count: count).map { arrangement in
            (
                "\(arrangement.glyph) \(SplitEven.header(count: count)) · \(arrangement.title)",
                arrangement.caption(count: count),
                { [weak self] in
                    Gtk.onMain { [weak self] in self?.openMarkedSplit(arrangement) }
                }
            )
        }
        return rows
    }

    func rowMenuRows(
        _ row: SessionRowModel, backend: (any CodingAgentBackend)?
    ) -> [(title: String, detail: String?, action: @Sendable () -> Void)] {
        let entry = row.entry
        var rows: [(title: String, detail: String?, action: @Sendable () -> Void)] = []
        rows += bulkMenuRows()
        if entry.session.id != activePane.sessionID {
            rows.append(
                (Localized.text("Open"), nil,
                 { [weak self] in Gtk.onMain { [weak self] in self?.open(entry) } }))
        }
        rows.append(
            (Localized.text("Open in a new split"),
             Localized.text("Beside the conversations already on screen"),
             { [weak self] in
                 Gtk.onMain { [weak self] in
                     guard let self else { return }
                     self.splitHost.splitActive(axis: .horizontal)
                     self.activePane.open(entry)
                 }
             }))
        let saved = SavedChatStore.contains(entry)
        rows.append(
            (saved ? Localized.text("Unsave") : Localized.text("Save"),
             Localized.text("A saved chat lists itself even when its server is unreachable"),
             { [weak self] in Gtk.onMain { [weak self] in self?.toggleSaved(entry) } }))
        let archived = ArchivedChatStore.contains(
            profileID: entry.profileID, sessionID: entry.session.id)
        rows.append(
            (archived ? Localized.text("Unarchive") : Localized.text("Archive"),
             archived
                 ? Localized.text("Back into the chat list")
                 : Localized.text("Out of the list, kept on the server"),
             { [weak self] in Gtk.onMain { [weak self] in self?.toggleArchived(entry) } }))
        if row.state.carriesBackgroundWork, let backend, backend.capabilities.supportsBackgroundStop {
            rows.append(
                (Localized.text("Stop background work"),
                 Localized.text("End the command the agent left running on the machine"),
                 { [weak self] in
                     Gtk.onMain { [weak self] in self?.stopBackgroundWork(entry, on: backend) }
                 }))
        }
        let pinned = SessionPinStore.contains(
            profileID: entry.profileID, sessionID: entry.session.id)
        rows.append(
            (pinned ? Localized.text("Unpin") : Localized.text("Pin"),
             pinned
                 ? Localized.text("Back into the recency order")
                 : Localized.text("Always at the top of the chat list"),
             { [weak self] in Gtk.onMain { [weak self] in self?.togglePinned(entry) } }))
        rows.append(
            (row.unread ? Localized.text("Mark as read") : Localized.text("Mark as unread"), nil,
             { [weak self] in
                 Gtk.onMain { [weak self] in
                     if row.unread {
                         SessionSeenStore.markSeen(entry.session.id)
                     } else {
                         SessionSeenStore.markUnread(
                             entry.session.id, updatedAt: entry.session.updatedAt)
                     }
                     self?.renderSidebar()
                 }
             }))
        if let backend {
            if backend.capabilities.supportsRenaming {
                rows.append(
                    (Localized.text("Rename…"), nil,
                     { [weak self] in
                         Gtk.onMain { [weak self] in
                             self?.presentRename(entry: entry, backend: backend)
                         }
                     }))
            }
            if backend.capabilities.supportsForking {
                rows.append(
                    (Localized.text("Fork"),
                     Localized.text("A new session with this history, for a different direction"),
                     { [weak self] in
                         Gtk.onMain { [weak self] in self?.fork(entry: entry, backend: backend) }
                     }))
            }
        }
        if projectScope == nil {
            let scope = ProjectScope(of: entry)
            rows.append(
                (Localized.text("Only this project"), scope.banner(serverName: entry.profileName),
                 { [weak self] in
                     Gtk.onMain { [weak self] in self?.setProjectScope(scope) }
                 }))
        } else {
            rows.append(
                (Localized.text("Every chat"), Localized.text("Leave the project board"),
                 { [weak self] in
                     Gtk.onMain { [weak self] in self?.setProjectScope(nil) }
                 }))
        }
        rows.append(
            (Localized.text("Copy session ID"), entry.session.id,
             { Gtk.onMain { Gtk.copyToClipboard(entry.session.id) } }))
        if let directory = entry.session.directory {
            rows.append(
                (Localized.text("Copy project path"), directory,
                 { Gtk.onMain { Gtk.copyToClipboard(directory) } }))
        }
        if let backend {
            rows.append(
                (Localized.text("Delete…"), Localized.text("Remove the session from its server"),
                 { [weak self] in
                     Gtk.onMain { [weak self] in
                         self?.presentDelete(entry: entry, backend: backend)
                     }
                 }))
        }
        return rows
    }
}
