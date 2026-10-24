import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension MainWindow {
    func startRefreshing() {
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await BackgroundGate.shared.untilVisible()
                await self?.refresh()
                await BackgroundGate.shared.sleep(10)
            }
        }
    }

    /// A proto-2 bridge pushes list changes the moment they happen; the 10-second poll survives
    /// only as reachability detection and as the whole story for older servers. Streams are keyed
    /// by profile and opened once the directory actually has machines — a cold start with an empty
    /// list used to start nothing and never try again.
    func ensureListStreams(_ profiles: [ConnectionProfile]) {
        guard !tornDown else { return }
        let wanted = Set(profiles.map(\.id))
        for (id, task) in listStreamTasks where !wanted.contains(id) {
            task.cancel()
            listStreamTasks[id] = nil
        }
        for profile in profiles {
            guard listStreamTasks[profile.id] == nil else { continue }
            let profileID = profile.id
            listStreamTasks[profileID] = Task { [weak self] in
                guard let backend = await ServerDirectory.shared.backend(for: profile),
                    let streaming = backend as? SessionListStreaming,
                    let changes = await streaming.sessionListChanges()
                else {
                    Gtk.onMain { [weak self] in
                        guard let self, self.listStreamTasks[profileID] != nil else { return }
                        self.listStreamTasks[profileID] = nil
                    }
                    return
                }
                for await change in changes {
                    guard !Task.isCancelled else { return }
                    Gtk.onMain { [weak self] in self?.applyListChange(change, profile: profile) }
                }
                Gtk.onMain { [weak self] in self?.listStreamTasks[profileID] = nil }
            }
        }
    }

    /// List pushes are gathered for a moment and folded into one merge and one draw, the way the
    /// phone folds them: a server that moves forty chats at once is one pass over the list.
    func applyListChange(_ change: SessionListChange, profile: ConnectionProfile) {
        guard !sidebarTornDown else { return }
        if case .invalidated = change {
            Task { [weak self] in await self?.refresh() }
            return
        }
        pendingListChanges.append((change, profile))
        guard !listGatherQueued else { return }
        listGatherQueued = true
        Gtk.after(UInt32(SidebarCadence.listGather * 1000)) { [weak self] in
            guard let self else { return }
            self.listGatherQueued = false
            self.flushListChanges()
        }
    }

    func flushListChanges() {
        guard !sidebarTornDown, !pendingListChanges.isEmpty else { return }
        let batch = pendingListChanges
        pendingListChanges = []
        if !SessionListOrder.isNewestFirst(entries) {
            entries.sort { $0.session.updatedAt > $1.session.updatedAt }
        }
        var touched: [SessionEntry] = []
        for (change, profile) in batch {
            switch change {
            case .upsert(let session):
                let entry = SessionEntry(
                    profileID: profile.id, profileName: profile.name,
                    host: profile.baseURL.host ?? profile.name,
                    backendType: profile.backend, session: session)
                SessionListOrder.upsert(entry, into: &entries)
                touched.append(entry)
            case .remove(let id):
                SessionListOrder.remove(profileID: profile.id, sessionID: id, from: &entries)
            case .invalidated:
                break
            }
        }
        if !touched.isEmpty {
            let saved = entries
            Soak.timeListSave { SessionListCache.enqueueSave(saved) }
            SessionMarks.reconcile(with: touched)
        }
        feedAgents()
        scheduleSidebarRender()
        guard !touched.isEmpty else { return }
        let touchedIDs = Set(touched.map(\.session.id))
        splitHost.eachPane { pane in
            if let id = pane.sessionID, touchedIDs.contains(id) { pane.refreshPills() }
        }
        refreshTitleFromListing(touched)
    }

    /// A pane keeps the entry it was opened with, so a chat the server named after it opened, or
    /// one renamed since, would wear its first title until it was opened again. Every pane is
    /// handed the listing's current entry for its chat, and what else reads the title (the
    /// header, the overflow strip) follows the panes that took it.
    func refreshTitleFromListing(_ listed: [SessionEntry]) {
        var renamed = false
        splitHost.eachPane { pane in
            guard let current = pane.entry,
                let fresh = listed.first(where: {
                    $0.profileID == current.profileID && $0.session.id == current.session.id
                }),
                pane.adoptTitle(from: fresh)
            else { return }
            renamed = true
        }
        guard renamed else { return }
        refreshChromeForActivePane()
        (splitHost as? TileHost)?.refreshStrip()
    }

    func refresh() async {
        await ServerDirectory.shared.reload()
        let profiles = await ServerDirectory.shared.profiles()
        var known = Set(self.entries.compactMap(\.session.directory))
        known.formUnion(SessionListCache.load().compactMap(\.session.directory))
        let (entries, unreachable) = await ServerDirectory.shared.entries(
            knownDirectories: Array(known), previous: self.entries)
        let heard = await ServerDirectory.shared.lastHeard
        if !entries.isEmpty { SessionListCache.enqueueSave(entries) }
        await SessionMarkSync.drain { await ServerDirectory.shared.backend(forProfileID: $0) }
        Gtk.onMain { SessionMarks.reconcile(with: entries) }
        UpdateWatch.keep(profiles)
        _ = Self.localAddresses
        Gtk.onMain { [weak self] in
            self?.knownProfiles = profiles
            self?.refreshWelcome()
            self?.ensureListStreams(profiles)
            self?.warmCatalogs(profiles)
            self?.rememberDividers()
            self?.applyEntries(entries, unreachable: unreachable, lastHeard: heard)
            SettingsFile.capture()
        }
    }

    /// Opens the conversation that was open last, not merely the newest one — and resolves every
    /// restored pane's remembered session as soon as the listing carries it.
    func applyEntries(
        _ entries: [SessionEntry], unreachable: [String], lastHeard: [String: Date] = [:],
        fromNetwork: Bool = true
    ) {
        self.entries = entries
        self.unreachable = unreachable
        if !lastHeard.isEmpty { self.lastHeard = lastHeard }
        if fromNetwork { listedFromNetwork = true }
        feedAgents()
        wakeHeldQueues()
        if let fresh = freshlyCreated {
            if entries.contains(where: { $0.session.id == fresh.session.id }) {
                freshlyCreated = nil
            } else {
                self.entries.insert(fresh, at: 0)
            }
        }
        resolvePendingBindings()
        refreshTitleFromListing(self.entries)
        scheduleSidebarRender()
        restateChoosers()
        let active = activePane
        guard active.sessionID == nil, pendingBindings[active.id] == nil,
            parkedBindings[active.id] == nil, readyToWake[active.id] == nil, !entries.isEmpty,
            !active.isAnswering
        else { return }
        let remembered = Preferences.lastSession.flatMap { id in
            entries.first { $0.session.id == id }
        }
        active.open(remembered ?? entries[0])
    }

    /// A restored pane opens its session the moment the listing carries it. A session the
    /// network-backed listing does not carry gets an explanation, not a collapse — and the
    /// binding is kept, because a server that was unreachable this minute may list it the next.
    func resolvePendingBindings() {
        guard !pendingBindings.isEmpty else { return }
        for (paneID, binding) in pendingBindings {
            guard let pane = splitHost.panes[paneID] else {
                pendingBindings[paneID] = nil
                continue
            }
            if let entry = entries.first(where: {
                $0.profileID == binding.profileID && $0.session.id == binding.sessionID
            }) {
                pendingBindings[paneID] = nil
                readyToWake[paneID] = entry
                restoreWake.markReady(paneID)
            } else if listedFromNetwork {
                pane.showPlaceholder(
                    Localized.text(
                        "The chat this pane was showing is not in any listing right now."))
            }
        }
        pumpRestoreWake()
    }

    /// Opens the next restored chat whose turn has come, and arms one timer for the one after: a
    /// restore never opens every stream in one frame. A pane the person has since filled with
    /// something else, or closed, is skipped rather than overwritten.
    func pumpRestoreWake() {
        while true {
            switch restoreWake.take(now: Watchdog.now) {
            case .idle:
                return
            case .wait(let delay):
                guard !wakeScheduled else { return }
                wakeScheduled = true
                Gtk.after(UInt32((delay * 1000).rounded(.up))) { [weak self] in
                    self?.wakeScheduled = false
                    self?.pumpRestoreWake()
                }
                return
            case .wake(let paneID):
                guard let entry = readyToWake.removeValue(forKey: paneID),
                    let pane = splitHost.panes[paneID], pane.sessionID == nil, !pane.isAnswering
                else { continue }
                Trace.mark("restore wake \(splitHost.layout.paneIDs.firstIndex(of: paneID) ?? -1)")
                pane.open(entry)
                return pumpRestoreWake()
            }
        }
    }

    /// The unclean-exit restore: every restored chat keeps its place and its name and opens no
    /// stream, and the banner waits for the person to say how they come back.
    func parkRestoredChats(bannerText: String) {
        parkedBindings = pendingBindings
        pendingBindings = [:]
        for paneID in parkedBindings.keys {
            splitHost.panes[paneID]?.showPlaceholder(Self.parkedPlaceholder)
        }
        let banner = RestoreBanner(
            text: bannerText,
            resumeAll: { [weak self] in
                Gtk.onMain { [weak self] in self?.resumeParked(all: true) }
            },
            resumeOneByOne: { [weak self] in
                Gtk.onMain { [weak self] in self?.resumeParked(all: false) }
            },
            dismiss: { [weak self] in
                Gtk.onMain { [weak self] in self?.dismissRestoreBanner() }
            })
        banner.attach(to: splitHost.container)
        restoreBanner = banner
        splitHost.setHeld(parkedBindings)
    }

    static var parkedPlaceholder: String {
        Localized.text("This chat is paused. Click it to resume.")
    }

    /// `Resume all` wakes every paused chat through the staggered wake; `Resume one by one` wakes
    /// the focused pane and leaves the rest paused until each is pressed.
    func resumeParked(all: Bool) {
        dismissRestoreBanner()
        let chosen = all ? Array(parkedBindings.keys) : [activePane.id]
        for paneID in chosen { resume(paneID) }
    }

    func dismissRestoreBanner() {
        restoreBanner?.remove()
        restoreBanner = nil
    }

    /// One paused chat back into the wake.
    func resumeRestored(_ paneID: PaneID) {
        resume(paneID)
    }

    func resume(_ paneID: PaneID) {
        guard let binding = parkedBindings.removeValue(forKey: paneID) else { return }
        defer { splitHost.setHeld(parkedBindings) }
        splitHost.panes[paneID]?.showPlaceholder(Localized.text("Connecting…"))
        pendingBindings[paneID] = binding
        if parkedBindings.isEmpty { dismissRestoreBanner() }
        resolvePendingBindings()
    }

    /// The chat a pane is holding for but not yet showing — waiting for the listing, its turn in
    /// the wake, or a paused restore — so a layout written meanwhile keeps it instead of forgetting
    /// every chat a restore has not opened yet.
    func heldSession(for paneID: PaneID) -> SplitPaneSession? {
        if let binding = pendingBindings[paneID] ?? parkedBindings[paneID] { return binding }
        return readyToWake[paneID].map {
            SplitPaneSession(profileID: $0.profileID, sessionID: $0.session.id)
        }
    }

    /// The panes as the governor reads them: what each holds, whether the zoom left it on screen,
    /// its size, and what it is asking of the person.
    func seatbeltPanes() -> SeatbeltPanes {
        if let tile = splitHost as? TileHost {
            var waiting = pendingBindings
            for (id, entry) in readyToWake {
                waiting[id] = SplitPaneSession(profileID: entry.profileID, sessionID: entry.session.id)
            }
            for (id, binding) in parkedBindings { waiting[id] = binding }
            return tile.seatbeltPanes(waiting: waiting)
        }
        let layout = splitHost.layout
        var facts: [PaneFacts] = []
        var placed = 0
        var hidden = 0
        for pane in splitHost.orderedPanes {
            let onScreen = layout.zoomedPane == nil || layout.zoomedPane == pane.id
            let kind: PaneKind
            if pane.previewTarget != nil {
                kind = .preview
            } else if pane.drawEndpoint != nil {
                kind = .draw
            } else if pane.webTarget != nil {
                kind = .web
            } else if pane.videoTarget != nil {
                kind = .video
            } else if pane.entry != nil || parkedBindings[pane.id] != nil {
                kind = .chat
            } else {
                kind = .empty
            }
            let parked = parkedBindings[pane.id] != nil
            if onScreen, !parked { placed += 1 } else { hidden += 1 }
            facts.append(
                PaneFacts(
                    id: pane.id, kind: kind, focused: pane.id == layout.focusedPane,
                    placed: onScreen && !parked, width: Double(gtk_widget_get_width(pane.root)),
                    height: Double(gtk_widget_get_height(pane.root)),
                    attention: Self.attention(of: pane.lastState)))
        }
        return SeatbeltPanes(facts: facts, placed: placed, hidden: hidden)
    }

    static func attention(of state: ConversationState?) -> PaneAttention {
        guard let state else { return .quiet }
        if !state.pendingPermissions.isEmpty || !state.pendingQuestions.isEmpty { return .needsYou }
        if state.lastFailure != nil { return .failed }
        return state.status == .running ? .running : .quiet
    }

    /// One cheap re-read of the last aggregate, for the fact that changes without a listing —
    /// the ultracode aura lighting or dying under a draft. The full render feeds `orbKinds`;
    /// this keeps the rainbow honest between renders.
    func refreshOrb() {
        orb.update(
            signal: PresenceSignal.aggregate(
                orbKinds, ultracode: splitHost.panes.values.contains { $0.auraActive }))
    }
}
