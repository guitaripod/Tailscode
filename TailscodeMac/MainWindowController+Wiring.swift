import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

extension MainWindowController {
    func wireChildren() {
        sidebar.onOpen = { [weak self] entry, backend in
            guard let self else { return }
            if self.splitPanes.paneCount > 1 {
                if let pane = self.splitPanes.pane(showing: entry.session.id) {
                    self.splitPanes.focus(pane, grabKeyboard: true)
                    self.focusedPaneChanged()
                    return
                }
                if self.pendingBindings.values.contains(where: { $0.sessionID == entry.session.id }
                ) {
                    self.resolvePendingBindings()
                    return
                }
                if let paneID = self.heldPane(showing: entry.session.id),
                    let pane = self.splitPanes.panes[paneID]
                {
                    self.splitPanes.focus(pane, grabKeyboard: true)
                    self.focusedPaneChanged()
                    return
                }
                self.splitPanes.collapse(to: self.splitPanes.active)
            }
            self.handleOpen(entry, backend: backend)
        }
        sidebar.onOpenSplit = { [weak self] entries, arrangement in
            self?.openMarkedSplit(entries, as: arrangement)
        }
        sidebar.onOpenSplitTab = { [weak self] tab in
            self?.restoreSplitTab(tab)
        }
        sidebar.onGoToMember = { [weak self] entry in
            self?.goToSplitMember(entry)
        }
        sidebar.onUnsplit = { [weak self] keeping in
            self?.unsplit(keeping: keeping)
        }
        sidebar.splitTabSource = { [weak self] in
            guard let self, self.splitPanes.paneCount > 1 else { return nil }
            return SplitTab(snapshot: self.splitPanes.snapshot())
        }
        splitPanes.onLayoutChanged = { [weak self] in
            self?.sidebar.noteLayoutChanged()
            self?.forgetHeldPanesGone()
        }
        sidebar.onOpenInSplit = { [weak self] entry in
            self?.openInNewSplit(entry)
        }
        sidebar.onNewChatInScope = { [weak self] scope in
            guard let self,
                let profile = ServerDirectory.shared.profiles.first(where: {
                    $0.id == scope.profileID
                })
            else { return }
            self.createChat(on: profile, directory: scope.directory)
        }
        sidebar.focusedSessionID = { [weak self] in
            self?.transcript.currentEntry?.session.id
        }
        sidebar.onDeleted = { [weak self] entry in
            self?.paneCleanupAfterDelete(entry)
        }
        sidebar.onNotice = { [weak self] text in self?.setNotice(text) }
        sidebar.onToast = { [weak self] text in self?.toast(text) }
        sidebar.onOpenUpdates = { [weak self] in self?.presentUpdates() }
        sidebar.onOpenPro = { [weak self] in self?.presentPro() }
        sidebar.ultracodeSource = { [weak self] in
            var active = false
            self?.splitPanes.eachPane { active = active || $0.composer.auraActive }
            return active
        }
        sidebar.presenceSource = { [weak self] in self?.observedPresence() ?? [:] }
        sidebar.announce = { [weak self] line in self?.toast(line) }
        splitPanes.makePane = { [weak self] in
            self?.makePane() ?? TranscriptViewController()
        }
        (splitPanes as? TileHost)?.paneHost = self
        splitPanes.onPaneOpened = { [weak self] pane, source in
            self?.presentChooser(in: pane, preferring: source)
        }
        splitPanes.onFocusChanged = { [weak self] in
            guard let self else { return }
            self.focusedPaneChanged()
            self.wakeParked(self.splitPanes.layout.focusedPane)
        }
        splitPanes.heldSessions = { [weak self] in self?.heldSessions ?? [:] }
        Seatbelts.shared.panes = { [weak self] in self?.seatbeltPanes() ?? SeatbeltPanes() }
        splitPanes.chatTitleForDrop = { [weak self] payload in
            self?.chatTitle(for: payload)
        }
        splitPanes.onChatDropped = { [weak self] pane, payload, zone in
            self?.pane(pane, received: payload, zone: zone) ?? false
        }
        sidebar.onTitleChanged = { [weak self] in
            self?.refreshTitleFromListing()
        }
        sidebar.onAddMachine = { FirstRunWindow.present(way: nil) }
        sidebar.onEntriesChanged = { [weak self] in
            guard let self else { return }
            self.refreshWelcome()
            self.restateChoosers()
            self.refreshTitleFromListing()
            self.resolvePendingBindings()
            self.wakeHeldQueues(entries: self.sidebar.entries)
        }
    }

    /// Every pane is wired at birth to this window as its `PaneHost`: its state feeds the chat
    /// list, its toasts land in the shared queue, and its band steers the pane it belongs to.
    private func makePane() -> TranscriptViewController {
        let pane = TranscriptViewController()
        pane.connect(to: self)
        return pane
    }

    /// What every pane on screen knows first-hand about the conversation it is streaming, keyed
    /// the way the stores are keyed. This is what makes WORKING honest: the server's listing
    /// reports `active` only for the seconds a turn is literally open on it and never reports a
    /// turn that stopped to ask for an approval, so a chat being talked in right now would
    /// otherwise be findable only by recency.
    private func observedPresence() -> [String: SessionPresence] {
        var observed = TileRuntime.shared.backgroundPresence
        splitPanes.eachPane { pane in
            guard let entry = pane.currentEntry else { return }
            let presence = pane.presence
            let key = SessionPinStore.key(entry.profileID, entry.session.id)
            guard presence.rank > (observed[key] ?? .unsettled).rank else { return }
            observed[key] = presence
        }
        presenceLedger.absorb(observed)
        return presenceLedger.readings()
    }

    /// Every conversation the store is holding a message for gets a watch, so a queue written
    /// before the app quit goes when its turn yields rather than when somebody opens the chat.
    /// A chat a pane is showing drains from the pane; a held chat the listing no longer has waits
    /// for a listing that does.
    func wakeHeldQueues(entries: [SessionEntry]) {
        for record in SendQueueStore.all() {
            let key = LiveKey(profileID: record.profileID, sessionID: record.sessionID)
            guard !TileRuntime.shared.isWatching(key),
                !splitPanes.panes.values.contains(where: {
                    $0.currentEntry?.session.id == record.sessionID
                        && $0.currentEntry?.profileID == record.profileID
                }),
                let entry = entries.first(where: {
                    $0.session.id == record.sessionID && $0.profileID == record.profileID
                }),
                let profile = ServerDirectory.shared.profiles.first(where: { $0.id == record.profileID }),
                let backend = ServerDirectory.shared.backend(for: profile)
            else { continue }
            TileRuntime.shared.watch(entry, backend: backend)
        }
    }

    /// Every pane showing a deleted session empties with an explanation; the sidebar's own flow
    /// already repopulates the focused one.
    private func paneCleanupAfterDelete(_ entry: SessionEntry) {
        splitPanes.eachPane { pane in
            guard pane.currentEntry?.session.id == entry.session.id,
                pane.currentEntry?.profileID == entry.profileID
            else { return }
            pane.resetPane(placeholder: Localized.text("That conversation was deleted."))
        }
        splitPanes.persist()
    }

    func handleOpen(_ entry: SessionEntry, backend: any CodingAgentBackend) {
        UserDefaults.standard.set(entry.session.id, forKey: "tailscode.lastSession")
        transcript.open(entry, backend: backend)
        retargetTerminal(to: entry.session.directory)
        showTitle(of: entry)
        splitPanes.persist()
    }

    /// What a chat dragged from the list is called, for the caption inside the drop highlight.
    private func chatTitle(for payload: PaneDragPayload) -> String? {
        if let entry = sidebar.entries.first(where: {
            $0.profileID == payload.profileID && $0.session.id == payload.sessionID
        }) {
            return SessionRowModel(entry: entry, unreachable: false, unread: false, saved: false)
                .title
        }
        return SavedChatStore.all().first { $0.sessionID == payload.sessionID }?.title
    }

    /// A chat let go over a pane. The middle of a pane means open it there; an edge means the
    /// arrangement the highlight drew.
    @discardableResult
    private func pane(
        _ pane: TranscriptViewController, received payload: PaneDragPayload, zone: PaneDropZone
    ) -> Bool {
        guard
            let entry = sidebar.entries.first(where: {
                $0.profileID == payload.profileID && $0.session.id == payload.sessionID
            }),
            let profile = ServerDirectory.shared.profiles.first(where: { $0.id == entry.profileID }),
            let backend = ServerDirectory.shared.backend(for: profile)
        else { return false }
        SessionSeenStore.markSeen(entry.session.id)
        switch zone {
        case .fill:
            splitPanes.focus(pane, grabKeyboard: false)
            handleOpen(entry, backend: backend)
        case .split(let edge):
            guard let fresh = splitPanes.split(pane, edge: edge) else { return false }
            splitPanes.focus(fresh, grabKeyboard: false)
            handleOpen(entry, backend: backend)
        }
        return true
    }
}
