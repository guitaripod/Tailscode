import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

extension MainWindowController {
    /// One named surface, opened from the command line, so a window nobody is sitting in front of
    /// can be drawn and measured the way the main one already can. Every name here is a surface a
    /// person reaches with a menu item or a keystroke; nothing is reachable this way that is not
    /// reachable that way.
    func openSurface(named name: String) {
        if name.hasPrefix("preview=") {
            let rest = String(name.dropFirst("preview=".count))
            let splits = rest.hasSuffix("+split")
            openPreview(address: splits ? String(rest.dropLast("+split".count)) : rest, fixture: nil, split: splits)
            return
        }
        let parts = name.split(separator: ":", maxSplits: 1).map(String.init)
        switch parts.first ?? name {
        case "servers":
            presentServers()
            if parts.count > 1 { stageServersFailure(parts[1]) }
        case "first-run": presentFirstRunFixture(parts.count > 1 ? parts[1] : "machine-asking")
        case "welcome": presentWelcomeFixture(parts.count > 1 ? parts[1] : "machine-asking")
        case "updates": presentUpdates()
        case "preferences", "prefs":
            presentPreferences(page: parts.count > 1 ? PreferencesWindow.page(named: parts[1]) : nil)
        case "typesize", "type": presentPreferences(typeSize: true)
        case "analytics": presentAnalytics()
        case "agents", "agents-hour", "agent-peek", "agents-long", "agents-away": openAgentsFixture(parts.first ?? name)
        case "usage", "quotas": presentUsageWindow()
        case "newchat": presentNewChat(browsing: parts.count > 1 && parts[1] == "browse")
        case "quickask":
            let detail = parts.count > 1 ? parts[1] : ""
            presentQuickAsk(demoServer: detail == "long")
            #if DEBUG
                if detail == "party" || detail == "take" {
                    QuickAskPanel.frontmost?.stageParty(takes: detail == "take")
                }
            #endif
        case "cheatsheet", "shortcuts": presentCheatsheet()
        case "commands": transcript.presentCommandCatalog()
        case "chooser": presentChooser(in: transcript)
        case "models":
            transcript.composer.openDemoModelChooser(script: parts.count > 1 ? parts[1] : "")
        case "dial":
            let detail = parts.count > 1 ? parts[1] : ""
            if detail.hasPrefix("pill=") {
                transcript.composer.openDemoModelDial(
                    popover: false, face: String(detail.dropFirst("pill=".count)))
            } else if detail.hasPrefix("search:") {
                transcript.composer.openDemoModelDial(
                    popover: true, query: String(detail.dropFirst("search:".count)))
            } else if detail.hasPrefix("row:"), let row = Int(detail.dropFirst("row:".count)) {
                transcript.composer.openDemoModelDial(popover: true, cursor: row)
            } else {
                transcript.composer.openDemoModelDial(popover: detail != "pill")
            }
        case "spend": presentSpend(for: transcript)
        case "git":
            #if DEBUG
                if parts.count > 1, parts[1] == "diff" {
                    presentDemoDiff(for: transcript)
                } else {
                    presentGit(for: transcript)
                }
            #else
                presentGit(for: transcript)
            #endif
        case "forge", "video":
            if parts.count > 1 { StudioVideoDemo.apply(parts[1]) }
            presentStudio(lane: .video)
            #if DEBUG
                driveForge()
            #endif
        case "forgering":
            ForgeRunner.shared.stage(ForgeDemo.board(parts.count > 1 ? parts[1] : "running"), arriving: true)
        case "draw":
            transcript.showDraw(nil)
            splitPanes.persist()
        case "preview":
            let stages = parts.count > 1 ? parts[1].split(separator: "+").map(String.init) : []
            openPreview(
                address: nil, fixture: stages.first(where: { $0 != "split" }),
                split: stages.contains("split"))
        case "studio", "image":
            let stages = parts.count > 1 ? parts[1].split(separator: "+").map(String.init) : []
            if let state = stages.first { StudioDemo.apply(state, to: StudioWindowController.shared.image.studio) }
            presentStudio()
            #if DEBUG
                driveStudio()
                if stages.dropFirst().contains("viewer") {
                    DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(900)) {
                        StudioWindowController.shared.image.perform(.open)
                    }
                }
            #endif
        case "viewer":
            MediaViewerDemo.open(parts.count > 1 ? parts[1] : "", in: window)
        case "renderer", "forgesetup":
            presentStudio(lane: .video)
            StudioWindowController.shared.video.openSetup()
        #if DEBUG
            case "party":
                DialTour.fillFleetParty()
                transcript.composer.openDemoParty()
            case "split":
                let spec = parts.count > 1 ? parts[1].split(separator: ",").map(String.init) : []
                let named = spec.filter { $0 != "zoom" && Int($0) == nil }
                let count = Int(spec.first ?? "") ?? named.count + 1
                let chats = named.isEmpty ? ["demo-c1", "demo-c2", "demo-c4", "demo-c5"] : named
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    for index in 1..<max(count, 2) {
                        guard let self else { return }
                        let id = chats[(index - 1) % chats.count]
                        if let entry = self.sidebar.entries.first(where: { $0.session.id == id }) {
                            self.openInNewSplit(entry)
                        }
                        try? await Task.sleep(for: .milliseconds(900))
                    }
                    if spec.contains("zoom") { self?.splitPanes.zoomActive() }
                }
            case "stage":
                let spec = parts.count > 1 ? parts[1].split(separator: ",").map(String.init) : []
                guard let path = spec.first else { break }
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    self?.transcript.stage(messagesAt: path, directives: Array(spec.dropFirst()))
                }
        #endif
        case "clock-glance":
            if window?.isVisible != true { showWindow(nil) }
            sidebar.clockChip.reveal()
        case "clock-sheet":
            if window?.isVisible != true { showWindow(nil) }
            if let window {
                MeridianSheetController.shared.present(in: window)
                let content = MeridianSheetController.shared.content
                for item in parts.count > 1 ? parts[1].split(separator: "+") : [] {
                    if let minute = Int(item) {
                        content.scrub(to: minute, animated: false)
                    } else if item == "add" {
                        content.addPlace.open(focusing: false)
                    } else if item.hasPrefix("q=") {
                        content.addPlace.setQuery(String(item.dropFirst(2)))
                    }
                }
            }
        case "share":
            if window?.isVisible != true { showWindow(nil) }
            let staged = (parts.count > 1 ? parts[1] : "").split(separator: "+").map(String.init)
            if let window,
                let analytics = ShareFixtures.analytics(named: staged.first ?? "rich")
            {
                let format = staged.dropFirst().first.flatMap(ShareFormat.init(rawValue:))
                ShareCardPanel.present(
                    analytics, on: window, selection: format.map { ShareSelection(format: $0) })
            }
        case "delegate": presentDelegate()
        case "delegate-beta":
            presentDelegate()
            delegateWindow?.revealBeta()
        case "delegate-compose":
            presentDelegate()
            delegateWindow?.composeWhenReady()
        case "delegate-run":
            presentDelegate()
            delegateWindow?.selectFirstRun()
        default:
            FileHandle.standardError.write(
                Data(
                    ("unknown surface \(name) — servers, updates, preferences, typesize, analytics, newchat[:browse], "
                        + "quickask[:long|party|take], cheatsheet, commands, chooser, models, dial[:pill], spend, git, "
                        + "forge[:state], forgering[:state], studio[:state[+viewer]], viewer[:state], agents, agents-hour, agent-peek, party, clock-glance, clock-sheet[:minute+add+q=text], share[:fixture[+format]], draw, preview[:state[+split]], preview=HOST:PORT:/folder[+split], renderer, delegate\n").utf8))
        }
    }

    /// A preview pane for the headless driver. A fixture name draws that face from hand-built state
    /// with no host and no Keychain; an address (`HOST:PORT:/folder`) points a pane at a real host.
    /// `split` puts it beside the pane that was there, which is how its strip is looked at.
    private func openPreview(address: String?, fixture: String?, split: Bool) {
        if window?.isVisible != true { showWindow(nil) }
        if split { splitPanes.splitActive(axis: .horizontal) }
        let pane = splitPanes.active
        if let address {
            pane.showPreview(PreviewDemo.target(address))
        } else if let fixture, fixture != "asking", let state = PreviewDemo.state(fixture) {
            let memory = PreviewMemorySecrets()
            let target = PreviewTarget(host: PreviewDemo.host, project: PreviewDemo.project)
            pane.showPreview(target, runs: false, secrets: memory)
            let wantsPicture = ["live", "reconnecting", "broken"].contains(fixture)
            pane.previewView?.applyForTest(state, jpeg: wantsPicture ? PreviewDemo.picture : nil)
        } else {
            pane.showPreview(nil, secrets: PreviewMemorySecrets())
        }
        splitPanes.persist()
    }

    /// The Studio, raised: one sheet for the whole app, rising inside this window over the
    /// conversation rather than opening beside it. `brief` is words to start from — the composer's
    /// lanes send what was typed there — and nothing is rendered until a hand says Generate or Render.
    func presentStudio(lane: StudioLaneID = .image, brief: String? = nil) {
        if window?.isVisible != true { showWindow(nil) }
        StudioWindowController.shared.show(lane: lane, brief: brief, in: window)
    }

    #if DEBUG
        /// What a headless run asks of the Video lane once it is up — `TAILSCODE_VIDEO_PROMPT` to
        /// put words in the box, `TAILSCODE_VIDEO_FRAME` to start from a picture on disk — so a state
        /// can be photographed without a hand on the keyboard.
        private func driveForge() {
            let environment = ProcessInfo.processInfo.environment
            let lane = StudioWindowController.shared.video
            if let path = environment["TAILSCODE_VIDEO_FRAME"], !path.isEmpty {
                ForgeRunner.shared.start(from: .file(path))
            }
            if let words = environment["TAILSCODE_VIDEO_PROMPT"], !words.isEmpty {
                lane.dock.take(brief: words)
                lane.brief.rememberDraft(words)
            }
        }

        /// What a headless run asks of the Studio once it is up — `TAILSCODE_IMAGE_PROMPT` to paint,
        /// `TAILSCODE_IMAGE_REFERENCE` to start from a picture on disk — so a render against a stand-in
        /// ComfyUI can be watched and photographed without a hand on the keyboard.
        private func driveStudio() {
            let environment = ProcessInfo.processInfo.environment
            let studio = StudioWindowController.shared.image.studio
            if let path = environment["TAILSCODE_IMAGE_REFERENCE"], !path.isEmpty {
                studio.hold(ImageGenReference(path: path))
            }
            if let words = environment["TAILSCODE_IMAGE_PROMPT"], !words.isEmpty {
                StudioWindowController.shared.image.dock.take(brief: words)
                if environment["TAILSCODE_IMAGE_SUBMIT"] != "0" { studio.submit(prompt: words) }
            }
        }
    #endif

    /// Video, which is the Studio's second lane: the same sheet the pictures are made in, switched to
    /// the clip. A render lives in `ForgeRunner`, so closing the sheet never touches one, and opening
    /// it again finds the render exactly where it was.
    func presentForge() {
        presentStudio(lane: .video)
    }

    /// The servers window, one per app: add, probe, update, sign in or remove a server, with the
    /// sidebar refreshed behind every change.
    func presentServers() {
        if serversWindow == nil {
            serversWindow = ServersWindow { [weak self] in
                MacUpdateWatch.shared.noteProfilesChanged()
                Task { [weak self] in await self?.sidebar.refresh() }
            }
            serversWindow?.onNeedsPro = { [weak self] in self?.presentPro() }
            serversWindow?.onOpenUpdateCenter = { [weak self] in self?.presentUpdates() }
            serversWindow?.workingTurns = { [weak self] profileID in
                self?.sidebar.allEntries.filter {
                    $0.profileID == profileID && $0.session.isWorking
                }.count ?? 0
            }
        }
        serversWindow?.present()
    }

    /// The Update Center, one window per app, held in a property for the same reason the analytics
    /// window is: a window presented from a local is dead on arrival — released while shown, its
    /// buttons do nothing.
    func presentUpdates() {
        if updateWindow == nil {
            updateWindow = UpdateWindowController()
            updateWindow?.workingTurns = { [weak self] profileID in
                self?.sidebar.allEntries.filter {
                    $0.profileID == profileID && $0.session.isWorking
                }.count ?? 0
            }
        }
        updateWindow?.present()
    }

    /// The dispatcher's window, one per app. A store copy without Pro meets the unlock instead,
    /// because delegation is the door the purchase is sold through.
    func presentDelegate(handoff: DelegateHandoff? = nil) {
        guard MacDelegateGate.isOpen else {
            presentPro()
            return
        }
        MacDelegateGate.watchNotices()
        if delegateWindow == nil { delegateWindow = DelegateWindowController() }
        delegateWindow?.chatSource = { [weak self] in self?.sidebar.allEntries ?? [] }
        delegateWindow?.present()
        if let handoff { delegateWindow?.compose(handoff: handoff) }
    }

    /// The unlock, opened by hand — from the menu, or from the one gate that asks for it.
    func presentPro() {
        if proWindow == nil { proWindow = ProWindowController() }
        proWindow?.present()
    }

    func selectSettingsPage(named name: String) {
        preferencesWindow?.select(pageNamed: name)
    }

    func presentPreferences(typeSize: Bool = false, page: Int? = nil) {
        if preferencesWindow == nil {
            preferencesWindow = PreferencesWindow(
                onComposerChanged: { [weak self] in
                    self?.composerPreferencesChanged()
                },
                onTranscriptChanged: { [weak self] in
                    self?.transcriptPreferencesChanged()
                },
                onReloadShortcuts: { [weak self] in
                    self?.reloadShortcuts()
                })
            preferencesWindow?.actions = PreferencesWindow.Actions(
                manageServers: { [weak self] in self?.presentServers() },
                openUpdates: { [weak self] in self?.presentUpdates() },
                openPro: { [weak self] in self?.presentPro() },
                showCheatsheet: { [weak self] in self?.presentCheatsheet() },
                isSidebarShown: { [weak self] in self?.sidebarShown ?? true },
                setSidebarShown: { [weak self] shown in self?.setPane(.sidebar, shown: shown) },
                isTerminalShown: { [weak self] in self?.terminalShown ?? false },
                setTerminalShown: { [weak self] shown in self?.setPane(.terminal, shown: shown) })
        }
        if typeSize {
            preferencesWindow?.presentTypeSize()
        } else {
            preferencesWindow?.present(selecting: page)
        }
    }
}
