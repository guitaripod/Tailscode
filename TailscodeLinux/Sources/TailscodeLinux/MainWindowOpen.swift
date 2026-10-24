import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension MainWindow {
    /// Enter searches what was actually said, everywhere. The filter above it is titles-only and
    /// instant; this asks every machine at once and takes as long as the slowest one, so the list
    /// says it is looking rather than appearing to have found nothing.
    func runTranscriptSearch() {
        let query = filter.trimmingCharacters(in: .whitespacesAndNewlines)
        guard TranscriptSearch.isSearchable(query) else { return }
        searchTask?.cancel()
        searchRunning = true
        searchBoard = nil
        lastSidebar = nil
        renderSidebar()
        // The listing is read here, on the GLib main loop, and carried into the task. Nothing on
        // this client may hop to the Swift main actor: GTK runs its own loop and the main-actor
        // executor is never drained, so an `await MainActor.run` here simply never returns.
        let listed = entries
        searchTask = Task {
            let sources = await Self.searchSources(entries: listed)
            guard !Task.isCancelled else { return }
            let board = await TranscriptSearch.run(query: query, sources: sources)
            guard !Task.isCancelled else { return }
            Gtk.onMain { [weak self] in
                guard let self, self.searchRunning else { return }
                self.searchRunning = false
                self.searchBoard = board
                self.lastSidebar = nil
                self.renderSidebar()
            }
        }
    }

    /// One source per configured server, carrying the sessions this device has already listed so a
    /// backend that cannot search inside its own conversations still contributes their titles.
    static func searchSources(entries: [SessionEntry]) async -> [TranscriptSearch.Source] {
        var sources: [TranscriptSearch.Source] = []
        for profile in await ServerDirectory.shared.profiles() {
            guard let backend = await ServerDirectory.shared.backend(for: profile) else { continue }
            sources.append(
                TranscriptSearch.Source(
                    profileID: profile.id,
                    name: ServerLabel.display(name: profile.name, backend: profile.backend),
                    backend: backend,
                    entries: entries.filter { $0.profileID == profile.id }))
        }
        return sources
    }

    /// The list, replaced by what was found. A result is a place to go back to on the machine it
    /// happened on, so opening one aims the active pane at that server's own session.
    func renderSearchResults() {
        let query = searchBoard?.query ?? filter
        let rows = searchBoard?.rows ?? []
        gtk_box_append(
            ptr(sidebarList),
            SidebarRow.searchHeader(
                query: query, count: rows.count, running: searchRunning
            ) { [weak self] in
                Gtk.onMain { [weak self] in self?.leaveTranscriptSearch() }
            })
        if searchRunning {
            gtk_box_append(ptr(sidebarList), SidebarRow.empty(Localized.text("Asking every server…")))
            return
        }
        if let caveat = searchBoard.flatMap(TranscriptSearch.caveat) {
            gtk_box_append(ptr(sidebarList), SidebarRow.banner(caveat))
        }
        guard !rows.isEmpty else {
            gtk_box_append(
                ptr(sidebarList),
                SidebarRow.empty(Localized.text("Nothing said “%@”", query)))
            return
        }
        for result in rows.prefix(sidebarLimit) {
            let profileID = result.profileID
            let sessionID = result.sessionID
            gtk_box_append(
                ptr(sidebarList),
                SidebarRow.searchResult(result) { [weak self] in
                    Gtk.onMain { [weak self] in
                        self?.openSearchResult(profileID: profileID, sessionID: sessionID)
                    }
                })
        }
    }

    /// A result opens the conversation it names. The listing may not carry it — a chat on a server
    /// this device has not listed lately, or one the filter had already excluded — so a session the
    /// list cannot resolve says so instead of doing nothing.
    func openSearchResult(profileID: String, sessionID: String) {
        guard let entry = entries.first(where: {
            $0.profileID == profileID && $0.session.id == sessionID
        }) else {
            toast(Localized.text("That chat is not in this server's listing right now."))
            return
        }
        leaveTranscriptSearch(render: false)
        gtk_editable_set_text(op(searchEntry), "")
        filter = ""
        open(entry)
        renderSidebar()
    }

    func leaveTranscriptSearch(render: Bool = true) {
        searchTask?.cancel()
        searchTask = nil
        searchRunning = false
        searchBoard = nil
        lastSidebar = nil
        if render { renderSidebar() }
    }

    /// A bookmark must still list and explain itself when its server is unreachable, its session
    /// deleted, or its profile removed. Rows for chats the listing no longer covers are rebuilt
    /// from the bookmark's own snapshot.
    static func orphanedSavedRows(
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

    /// The window closing is the last moment every open composer still exists to be read. A pane
    /// that is merely closed stashes itself, but the last one never closes and the window taking
    /// the whole app down would take what is typed in all of them with it.
    func stashDrafts() {
        splitHost.eachPane { $0.stashDraft() }
        DraftStore.flush()
    }

    /// A `tailscode://connect` link from outside the window — the desktop opening it, a second
    /// launch handing it over, a paste into the setup — brought to the checklist, which asks before
    /// it saves anything.
    func openConnectLink(_ text: String) {
        raise()
        FirstRunDialog.open(link: text, parent: window) { [weak self] in
            Task { [weak self] in await self?.refresh() }
        }
    }

    /// What a second launch gets: the window that exists, brought forward. Never a second one —
    /// the first is still holding every session's stream.
    func raise() {
        guard let window else { return }
        gtk_window_present(ptr(window))
    }

    /// The notification's own answer, without presenting the window. It goes through the
    /// conversation the hub already holds for the chat, so answering there settles the card in
    /// the chat in the same breath as the server hears it; the backend alone only told the
    /// server, leaving the card waiting until something else happened to refresh the transcript.
    /// A chat nobody holds is opened just long enough to answer it. A request the chat has
    /// already settled is not asked again, and its notice goes. Failure leaves the request
    /// standing — the inbox entry still knows about it and the chat can resolve it.
    func decideFromNotification(
        profileID: String, permission: PermissionRequest, approve: Bool, identifier: String
    ) {
        let key = LiveKey(profileID: profileID, sessionID: permission.sessionID)
        let decision: PermissionDecision = approve ? .once : .reject
        Task {
            do {
                let held = await live.hub.conversation(for: key)
                let opened = held == nil ? await LiveRuntime.open(key) : nil
                _ = try await PermissionAnswer.answer(
                    permission, decision: decision, through: held ?? opened, backend: nil)
                Gtk.onMain { Notifier.shared.withdraw([identifier]) }
            } catch {
                Trace.mark("notification decision failed: \(error)")
            }
        }
    }

    /// A notification tap arrives here: raise the window, then bring the session it names to the
    /// eye — the pane already showing it if one is, else the focused pane.
    func openSession(withID id: String) {
        if let window { gtk_window_present(ptr(window)) }
        if let pane = splitHost.pane(showing: id) {
            splitHost.focus(pane, grabKeyboard: false)
            return
        }
        if let entry = entries.first(where: { $0.session.id == id }) {
            open(entry)
            return
        }
        Task { [weak self] in
            await self?.refresh()
            Gtk.onMain { [weak self] in
                guard let self, let entry = self.entries.first(where: { $0.session.id == id })
                else { return }
                self.open(entry)
            }
        }
    }

    /// Opening from the list always lands in the focused pane; a background pane keeps what it
    /// has, which is the point of having panes.
    /// Opening a chat from the list answers for the whole window, not one pane of it. A chat
    /// already on screen is gone to — its pane takes the focus. A chat that is not collapses the
    /// window to one pane first: a plain row was clicked, so a plain window is what was asked
    /// for, and replacing one member of a split would shrink the merged row by a chat nobody
    /// closed.
    func open(_ entry: SessionEntry) {
        freshlyCreated = nil
        if splitHost.paneCount > 1 {
            if let pane = splitHost.pane(showing: entry.session.id) {
                focused = .transcript
                splitHost.focus(pane, grabKeyboard: true)
                return
            }
            splitHost.collapse(to: splitHost.activePane)
        }
        activePane.open(entry)
    }

    /// The missed list is about a machine you walked away from, so it is worth nothing unless it
    /// survives the app being closed — and `UserDefaults` on Linux is keyed to the running
    /// executable, which makes it a cache rather than storage. `SettingsFile` is the durable copy,
    /// so every change to the list is written through to it.
    func observeMissedActivity() {
        NotificationCenter.default.addObserver(
            forName: ActivityInbox.didChange, object: nil, queue: nil
        ) { _ in
            SettingsFile.capture()
        }
    }

    /// A missed notice is a place to go back to. The chat may have been deleted or its server
    /// removed since, in which case the notice is stale and goes rather than sitting there
    /// failing to open.
    func openMissed(sessionID: String) {
        guard let entry = entries.first(where: { $0.session.id == sessionID }) else {
            ActivityInbox.clear(sessionID: sessionID)
            renderSidebar()
            return
        }
        open(entry)
        renderSidebar()
    }

    /// A pane with nothing in it asks which server, then what on it — the question the chat list
    /// cannot ask, at the moment a split makes it worth asking. The servers may not be loaded yet
    /// on the very first frame, so the chooser goes up with what is known and restates itself the
    /// moment the directory answers.
    func presentChooser(in pane: ChatPane, preferring serverID: String? = nil) {
        pane.showChooser(chooserModel(preferredServer: serverID))
        guard knownProfiles.isEmpty else { return }
        Task { [weak self] in
            if await ServerDirectory.shared.profiles().isEmpty {
                await ServerDirectory.shared.reload()
            }
            let profiles = await ServerDirectory.shared.profiles()
            _ = Self.localAddresses
            Gtk.onMain { [weak self] in
                guard let self else { return }
                self.knownProfiles = profiles
                self.restateChoosers()
            }
        }
    }

    /// The servers a pane may offer beyond its own — the model chooser spans the fleet, and a pane
    /// does not keep the directory itself.
    func fleetProfiles() -> [ConnectionProfile] { knownProfiles }

    /// Asks servers what they run so the chooser can name a machine before anyone opens a chat on
    /// it. A cold machine is asked immediately; a catalog already remembered is re-asked on a slow
    /// cadence rather than every ten-second listing — open chats keep their own watch.
    static let catalogWarmInterval: TimeInterval = 15 * 60

    func warmCatalogs(_ profiles: [ConnectionProfile]) {
        let now = Date()
        for profile in profiles {
            let remembered = ModelCatalogStore.cached(profile.id)
            if !remembered.isEmpty,
                let last = lastCatalogWarm[profile.id],
                now.timeIntervalSince(last) < Self.catalogWarmInterval
            {
                continue
            }
            lastCatalogWarm[profile.id] = now
            Task { [weak self] in
                guard let backend = await ServerDirectory.shared.backend(for: profile) else {
                    return
                }
                let known = remembered.map(\.id)
                let fresh = await ModelCatalogStore.refresh(profileID: profile.id, backend: backend)
                guard fresh.map(\.id) != known else { return }
                Gtk.onMain { [weak self] in self?.restateChoosers() }
            }
        }
    }

    /// A split whose chat starts in the folder the terminal is standing in. The new half exists
    /// before the chat does and is filled while it is made — on the pane that was split, never on
    /// whichever pane the focus has wandered to — so a server slow to answer leaves the usual
    /// chooser in the split rather than nothing.
    func splitAtTerminal(axis: SplitAxis) {
        guard TerminalPane.keepsAShell else {
            toast(TerminalSplit.Refusal.oneCommandAtATime.words)
            return
        }
        let directory = terminal.standingDirectory()
        let source = activePane
        let preferred = source.entry?.profileID
        let unreachable = Set(self.unreachable)
        Task { [weak self] in
            let profiles = await ServerDirectory.shared.profiles()
            let localAddresses = Self.localAddresses
            let servers = profiles.map {
                TerminalSplit.Server(
                    profileID: $0.id, isLocal: Dialogs.isLocal($0, localAddresses: localAddresses),
                    reachable: !unreachable.contains($0.id))
            }
            Gtk.onMain { [weak self] in
                guard let self else { return }
                switch TerminalSplit.plan(
                    directory: directory, servers: servers, preferred: preferred)
                {
                case .refused(let refusal):
                    self.toast(refusal.words)
                case .open(let profileID, let folder):
                    self.openSplit(
                        source, axis: axis, onProfileID: profileID, directory: folder)
                }
            }
        }
    }

    func openSplit(
        _ source: ChatPane, axis: SplitAxis, onProfileID profileID: String, directory: String
    ) {
        let edge: PaneDropEdge = axis == .horizontal ? .right : .bottom
        guard splitHost.layout.contains(source.id),
            let fresh = splitHost.split(source, edge: edge)
        else { return }
        presentChooser(in: fresh, preferring: profileID)
        splitHost.focus(fresh, grabKeyboard: false)
        focused = .transcript
        startChat(onProfileID: profileID, in: directory, into: fresh)
    }

    /// A chat minted in a folder the person already chose, into the pane that asked. Pressing again
    /// while the server is still answering mints nothing more, and a failure is said where the
    /// press was made, the chooser still standing so the other answers remain.
    func startChat(onProfileID profileID: String, in directory: String, into pane: ChatPane) {
        guard mintingPanes.insert(pane.id).inserted else { return }
        let paneID = pane.id
        createChat(onProfileID: profileID, directory: directory, into: pane) {
            [weak self] failure in
            Gtk.onMain { [weak self] in
                self?.mintingPanes.remove(paneID)
                if let failure { self?.toast(failure.title) }
            }
        }
    }

    /// A pane asking for a chat on another machine, which is what picking that machine's model
    /// means.
    func startChat(on profileID: String, into pane: ChatPane, carrying carry: CarryPlan? = nil) {
        guard let profile = knownProfiles.first(where: { $0.id == profileID }) else { return }
        presentNewChat(on: profile, into: pane, carrying: carry)
    }

    /// Where the terminal is standing, for the rows that offer it. Only a shell that stays alive
    /// between commands has a folder to offer.
    var terminalFolder: String? {
        TerminalPane.keepsAShell ? terminal.standingDirectory() : nil
    }

    /// Every open chooser says where the terminal is now, because the person walks there with the
    /// shell while the question is still open.
    func followTerminal() {
        let folder = terminalFolder
        splitHost.eachPane { $0.followTerminal(folder) }
    }

    func chooserModel(
        preferredServer: String?, landing: FirstRunLanding? = nil
    ) -> PaneChooser {
        var model =
            landing?.chooser(servers: chooserServers, entries: entries)
            ?? PaneChooser(
                servers: chooserServers, entries: entries, preferredServer: preferredServer)
        model.watchSummary = watchSummary
        model.offersPreview = true
        model.previewHosts = PreviewAccessStore.all()
        model.setTerminalFolder(terminalFolder)
        checkWhatIsOn()
        return model
    }

    /// What is live among the channels this device follows, so the chooser's watch row can name
    /// them rather than name the two sites. Checked at most once a minute and never on the way to
    /// drawing: the row starts as it always read and improves when the answer lands.
    func checkWhatIsOn() {
        let channels = WatchStore.watchlist(limit: 12)
        let signedIn = MediaSource.allCases.contains(where: MediaAccounts.isSignedIn)
        guard !channels.isEmpty || signedIn else { return }
        if let checked = watchCheckedAt, Date().timeIntervalSince(checked) < 60 { return }
        guard watchCheck == nil else { return }
        watchCheckedAt = Date()
        watchCheck = Task { [weak self] in
            let feed = await MediaFollowing().live(local: channels)
            Gtk.onMain { [weak self] in
                guard let self else { return }
                self.watchCheck = nil
                self.watchSummary = WatchSummary(
                    feed: feed, followed: WatchStore.channels().count)
                self.restateChoosers()
            }
        }
    }

    var chooserServers: [PaneChooserServer] {
        let localAddresses = Self.localAddresses
        return knownProfiles.map { profile in
            PaneChooserServer(
                profileID: profile.id, name: profile.name, backend: profile.backend,
                address: ServerLabel.address(profile),
                reachable: !unreachable.contains(ServerLabel.display(profile)),
                isLocal: Dialogs.isLocal(profile, localAddresses: localAddresses))
        }
    }

    func restateChoosers() {
        let servers = chooserServers
        let summary = watchSummary
        splitHost.eachPane { pane in
            guard pane.chooserShown else { return }
            pane.restateChooser(servers: servers, entries: entries, watching: summary)
        }
    }

    /// What a chooser row means once it is chosen. The pane that asked is the pane that fills —
    /// including the new chat, which lands where the question was asked rather than in whichever
    /// pane the focus later wandered to.
    func pane(_ pane: ChatPane, chose action: PaneChooserAction) {
        switch action {
        case .openChat(let profileID, let sessionID):
            guard
                let entry = entries.first(where: {
                    $0.profileID == profileID && $0.session.id == sessionID
                })
            else { return }
            pane.open(entry)
        case .newChat(let profileID):
            guard let profile = knownProfiles.first(where: { $0.id == profileID }) else { return }
            presentNewChat(on: profile, into: pane)
        case .newChatInFolder(let profileID, let directory):
            startChat(onProfileID: profileID, in: directory, into: pane)
        case .addServer:
            presentAddMachine()
        case .browse:
            pane.showWeb(nil)
            splitHost.focus(pane, grabKeyboard: false)
            splitHost.persist()
        case .watch:
            pane.showVideo(nil)
            splitHost.focus(pane, grabKeyboard: false)
            splitHost.persist()
        case .draw:
            pane.showDraw(nil)
            splitHost.focus(pane, grabKeyboard: false)
            splitHost.persist()
        case .preview(.app(let host)):
            pane.showPreview(nil, fixedHost: host)
            splitHost.focus(pane, grabKeyboard: false)
            splitHost.persist()
        case .preview(.addMac):
            pane.showPreview(nil)
            splitHost.focus(pane, grabKeyboard: false)
            splitHost.persist()
        case .chooseServer, .allChats, .back:
            break
        }
    }
}
