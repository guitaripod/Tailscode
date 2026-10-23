import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

extension MainWindowController {
    /// A machine just connected, from first run or from adding another: the chat list is read so the
    /// machine's own chats are there, the toast says which machine it was, and a pane that holds no
    /// conversation opens the chooser already on that machine, so the next press is a chat. A pane
    /// that holds a conversation keeps it; the person is in one.
    func land(on landing: FirstRunLanding?) async {
        await sidebar.refresh()
        refreshWelcome()
        guard let landing else { return }
        showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        toast(landing.toast)
        let pane = transcript
        guard pane.currentEntry == nil, !pane.chooserShown else { return }
        presentChooser(in: pane, landing: landing)
    }

    /// The welcome an empty window draws while the app holds no real server, and its removal the
    /// moment one is saved. Tailscale is read once off the main actor and the welcome redrawn only
    /// if the answer changed what it says.
    func refreshWelcome() {
        let pane = transcript
        guard EmptyWelcome.holdsNoRealServer(ServerDirectory.shared.profiles),
            pane.currentEntry == nil, !pane.chooserShown
        else {
            pane.clearWelcome()
            return
        }
        drawWelcome(in: pane)
        if welcomeFixture == nil { readTailscaleForWelcome() }
    }

    /// `--open servers:failed:<cause>`: the servers window the moment a probe has failed, with the
    /// card and the one tap Core's diagnosis offers, so it is looked at without a machine to fail.
    func stageServersFailure(_ name: String) {
        guard let state = FirstRunFixtures.state(named: name, platform: .mac),
            case .failed(let diagnosis) = state.machine
        else {
            FileHandle.standardError.write(Data("servers: no failure \(name)\n".utf8))
            return
        }
        serversWindow?.stage(diagnosis)
    }

    /// `--open first-run[:state]`: one state of the checklist, drawn from `FirstRunFixtures`.
    func presentFirstRunFixture(_ name: String) {
        if FirstRunWindow.presentFixture(named: name) == nil {
            FileHandle.standardError.write(
                Data("first-run: no state \(name); try \(FirstRunFixtures.names.joined(separator: ", "))\n".utf8))
        }
    }

    /// `--open welcome[:state]`: the main pane's welcome in one of the checklist's states, so what
    /// it says while Tailscale is down or Claude is signed out can be looked at without either.
    func presentWelcomeFixture(_ name: String) {
        guard let state = FirstRunFixtures.state(named: name, platform: .mac) else {
            FileHandle.standardError.write(Data("welcome: no state \(name)\n".utf8))
            return
        }
        welcomeFixture = state
        drawWelcome(in: transcript)
    }

    private func drawWelcome(in pane: TranscriptViewController) {
        var state = FirstRunState(platform: .mac)
        state.tailscale = welcomeTailscale
        if let welcomeFixture { state = welcomeFixture }
        let demoActive = !ServerDirectory.shared.profiles.isEmpty
        pane.showWelcome(EmptyWelcome.make(state, demoActive: demoActive)) { [weak self] in
            self?.answerWelcome($0)
        }
    }

    private func readTailscaleForWelcome() {
        guard !readingTailscaleForWelcome else { return }
        readingTailscaleForWelcome = true
        Task { [weak self] in
            let status = await Task.detached(priority: .utility) { TailnetStatusMac.read() }.value
            guard let self else { return }
            self.readingTailscaleForWelcome = false
            guard self.welcomeTailscale != status.reading else { return }
            self.welcomeTailscale = status.reading
            let pane = self.transcript
            if pane.shownWelcome != nil { self.drawWelcome(in: pane) }
        }
    }

    private func answerWelcome(_ intent: EmptyWelcome.Intent) {
        switch intent {
        case .setUpMachine: FirstRunWindow.present(way: nil)
        case .pasteLink: FirstRunWindow.present(way: .link)
        case .tryDemo: FirstRunWindow.enterDemoMode()
        case .openTailscale: openTailscaleFromWelcome()
        case .signIn: presentServers()
        }
    }

    /// A page or the app opens straight away; a command has to run where its output can be read,
    /// which is the checklist's Tailscale row, so that is where it goes.
    private func openTailscaleFromWelcome() {
        guard let reading = welcomeTailscale, let door = TailnetStatusMac.door(for: reading) else {
            FirstRunWindow.present(way: nil)
            return
        }
        if case .page(let address) = door, let url = URL(string: address) {
            NSWorkspace.shared.open(url)
        } else if case .app(let url) = door {
            NSWorkspace.shared.open(url)
        } else {
            FirstRunWindow.present(way: nil)
        }
    }

    /// A pane with nothing in it asks which server, then what on it — the question the chat list
    /// cannot ask, at the moment a split makes it worth asking.
    func presentChooser(
        in pane: TranscriptViewController, preferring serverID: String? = nil,
        landing: FirstRunLanding? = nil
    ) {
        var chooser =
            landing?.chooser(servers: chooserServers, entries: sidebar.allEntries)
            ?? PaneChooser(
                servers: chooserServers, entries: sidebar.allEntries, preferredServer: serverID)
        chooser.watchSummary = watchSummary
        #if TAILSCODE_MAS
            chooser.offersWatching = false
            chooser.offersBrowsing = false
        #endif
        chooser.offersPreview = true
        chooser.previewHosts = PreviewAccessStore.all()
        pane.showChooser(chooser)
        refreshWatchFeed()
    }

    /// What is on among the channels this device follows and the ones a signed-in account does, so
    /// the pane's watch row reports rather than labels. The answer is round trips to somebody
    /// else's site, so it is cached and re-asked at most once a minute however many empty panes ask
    /// the question.
    private var watchSummary: WatchSummary? {
        guard let watchFeed else { return nil }
        return WatchSummary(feed: watchFeed, followed: WatchStore.channels().count)
    }

    private func refreshWatchFeed() {
        #if !TAILSCODE_MAS
            guard watchLoad == nil else { return }
            if let watchCheckedAt, Date().timeIntervalSince(watchCheckedAt) < 60 { return }
            let channels = WatchStore.watchlist()
            guard !channels.isEmpty || WatchAccounts.rows().contains(where: \.isSignedIn) else {
                return
            }
            watchCheckedAt = Date()
            watchLoad = Task { [weak self] in
                let feed = await Task.detached(priority: .utility) {
                    await MediaFollowing().live(local: channels)
                }.value
                guard let self else { return }
                self.watchLoad = nil
                self.watchFeed = feed
                self.restateChoosers()
            }
        #endif
    }

    private var chooserServers: [PaneChooserServer] {
        let down = sidebar.unreachableServers
        return ServerDirectory.shared.profiles.map { profile in
            PaneChooserServer(
                profileID: profile.id, name: profile.name, backend: profile.backend,
                address: ServerLabel.address(profile),
                reachable: !down.contains(ServerLabel.display(profile)))
        }
    }

    func restateChoosers() {
        let servers = chooserServers
        let entries = sidebar.allEntries
        let watch = watchSummary
        splitPanes.eachPane { pane in
            guard pane.chooserShown else { return }
            pane.restateChooser(servers: servers, entries: entries, watch: watch)
        }
    }

    /// What a chooser row means once it is chosen. The pane that asked is the pane that fills —
    /// including the new chat, which lands where the question was asked.
    func pane(_ pane: TranscriptViewController, chose action: PaneChooserAction) {
        switch action {
        case .openChat(_, let sessionID):
            guard let entry = sidebar.allEntries.first(where: { $0.session.id == sessionID }),
                let profile = ServerDirectory.shared.profiles.first(where: {
                    $0.id == entry.profileID
                }),
                let backend = ServerDirectory.shared.backend(for: profile)
            else { return }
            SessionSeenStore.markSeen(entry.session.id)
            splitPanes.focus(pane, grabKeyboard: false)
            handleOpen(entry, backend: backend)
        case .newChat(let profileID):
            guard let profile = ServerDirectory.shared.profiles.first(where: { $0.id == profileID })
            else { return }
            splitPanes.focus(pane, grabKeyboard: false)
            presentNewChat(on: profile)
        case .addServer:
            presentServers()
        case .watch:
            #if !TAILSCODE_MAS
                splitPanes.focus(pane, grabKeyboard: false)
                pane.showVideo(nil)
                splitPanes.persist()
            #endif
        case .browse:
            #if !TAILSCODE_MAS
                splitPanes.focus(pane, grabKeyboard: false)
                pane.showWeb(nil)
                splitPanes.persist()
            #endif
        case .draw:
            splitPanes.focus(pane, grabKeyboard: false)
            pane.showDraw(nil)
            splitPanes.persist()
        case .preview(let choice):
            splitPanes.focus(pane, grabKeyboard: false)
            switch choice {
            case .app(let host): pane.showPreview(nil, fixedHost: host)
            case .addMac: pane.showPreview(nil)
            }
            splitPanes.persist()
        case .chooseServer, .allChats, .back, .newChatInFolder:
            break
        }
    }
}
