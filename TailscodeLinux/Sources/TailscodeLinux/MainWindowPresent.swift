import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension MainWindow {
    /// The selftest's way of giving a window that was never presented the tiling it would have
    /// built, so a verb that tells the window the focus moved has a window to tell.
    func installTiling(_ tiling: PaneTiling) {
        splitHost = tiling
    }

    /// The canvas follows the desktop, and the chats you had are on screen before the first byte
    /// crosses the tailnet — with liveness stripped from the cache, so nothing shown from it can
    /// claim to be running. The tiling tree is restored before the first paint for the same
    /// reason: the window's shape is local state and must never wait on a server.
    func present(in app: UnsafeMutablePointer<AdwApplication>) {
        Preferences.applyAppearance()
        MatrixTheme.install()
        terminal.applyPalette(MatrixTheme.palette)
        UIScale.apply()
        if let manager = adw_style_manager_get_default() {
            Gtk.onNotify(UnsafeMutableRawPointer(manager), property: "dark") { [weak self] in
                Gtk.onMain { [weak self] in self?.retheme() }
            }
        }
        Task.detached {
            DesktopIntegration.ensureInstalled()
            KWinPlacement.ensure()
        }
        observeMissedActivity()

        Trace.stamp("present begin")
        Seatbelts.shared.restoreLiveBudget()
        splitHost = TilingChoice.isLegacy ? SplitHost(host: self) : TileHost(host: self)
        if let tile = splitHost as? TileHost {
            tile.listFace = { [weak self] session in self?.listFace(for: session) }
            tile.onDensityChanged = { [weak self] in self?.updateLiveChip() }
        }
        if let raw = UserDefaults.standard.string(forKey: SplitSnapshot.defaultsKey),
            let snapshot = SplitSnapshot.decode(raw)
        {
            pendingBindings = splitHost.restore(snapshot)
        }
        let plan = Seatbelts.shared.beginLaunch(chatPanes: pendingBindings.count)
        restoreWake = RestoreWake(layout: splitHost.layout)
        if let bannerText = plan.bannerText {
            parkRestoredChats(bannerText: bannerText)
        }

        let window = adw_application_window_new(ptr(app))!
        gtk_window_set_title(ptr(window), "Tailscode")
        let size = Preferences.windowSize
        gtk_window_set_default_size(ptr(window), size.width, size.height)
        if Preferences.windowMaximized { gtk_window_maximize(ptr(window)) }
        gtk_window_set_icon_name(ptr(window), DesktopIntegration.appID)
        self.window = window

        let split = gtk_paned_new(GTK_ORIENTATION_HORIZONTAL)!
        gtk_paned_set_start_child(op(split), makeSidebarPane())
        gtk_paned_set_end_child(op(split), makeContentPane())
        gtk_paned_set_position(op(split), Preferences.divider(.sidebar) ?? 300)
        gtk_paned_set_resize_start_child(op(split), 0)
        gtk_paned_set_shrink_start_child(op(split), 1)
        gtk_paned_set_resize_end_child(op(split), 1)
        Gtk.onNotify(UnsafeMutableRawPointer(split), property: "position") { [weak self] in
            self?.holdSidebarFloor()
        }
        splitWidget = split

        let stack = gtk_paned_new(GTK_ORIENTATION_VERTICAL)!
        gtk_paned_set_start_child(op(stack), split)
        gtk_paned_set_end_child(op(stack), terminal.widget)
        gtk_paned_set_position(op(stack), Preferences.divider(.terminal) ?? 600)
        gtk_paned_set_resize_start_child(op(stack), 1)
        gtk_paned_set_shrink_start_child(op(stack), 0)
        gtk_paned_set_shrink_end_child(op(stack), 0)
        terminalPaned = stack

        let overlay = adw_toast_overlay_new()!
        adw_toast_overlay_set_child(op(overlay), stack)
        toastOverlay = overlay
        let root = gtk_overlay_new()!
        gtk_overlay_set_child(op(root), overlay)
        let headerHold = contentHeader.map { Gtk.WeakWidget($0) }
        let rootWindow = window
        studioSheet = StudioSheet(
            overlay: root, content: overlay, window: rootWindow,
            titlebar: {
                guard let header = headerHold?.widget else { return 0 }
                return Double(gtk_widget_get_height(header))
            })
        studioSheet?.onRise = { [weak self] in self?.pendingChords = [] }
        adw_application_window_set_content(ptr(window), root)
        gtk_window_present(ptr(window))
        Trace.stamp("window presented")
        Seatbelts.shared.start(window: window) { [weak self] in
            self?.seatbeltPanes() ?? .empty
        }

        splitHost.eachPane { $0.rebuildHelpOverlay() }
        installKeymap(on: window)
        installPressRouting(on: window)
        installSidebarLifecycle(on: window)
        Gtk.observe(UnsafeMutableRawPointer(window), "close-request") { [weak self] in
            VoiceCallRunner.shared.hangUp()
            self?.stashDrafts()
        }
        Gtk.connect(UnsafeMutableRawPointer(window), "destroy") { [weak self] in
            self?.windowDestroyed()
        }
        Notifier.shared.attach(
            app: app,
            onOpen: { [weak self] sessionID in
                self?.openSession(withID: sessionID)
            },
            onDecision: { [weak self] profileID, permission, approve, identifier in
                self?.decideFromNotification(
                    profileID: profileID, permission: permission, approve: approve,
                    identifier: identifier)
            },
            onReply: { [weak self] profileID, sessionID, words, identifier in
                self?.sendFromNotification(
                    profileID: profileID, sessionID: sessionID, words: words,
                    identifier: identifier)
            },
            onAnswer: { [weak self] profileID, question, answers, identifier in
                self?.answerFromNotification(
                    profileID: profileID, question: question, answers: answers,
                    identifier: identifier)
            })
        applyPanePreferences()
        Trace.stampFirstFrame(of: ptr(overlay), "input box")
        let cachedEntries = SessionListCache.load()
        if !cachedEntries.isEmpty { applyEntries(cachedEntries, unreachable: [], fromNetwork: false) }
        startRefreshing()
        startUsagePolling()
        observeUpdates()
        renderUpdates()
        UpdateWatch.start { [weak self] in self?.quitForUpdate() }
        FirstRunDialog.onLanded = { [weak self] landing in
            Gtk.onMain { [weak self] in self?.land(on: landing) }
        }
        presentFirstRun()
        if let seed = ProcessInfo.processInfo.environment["TAILSCODE_COMPOSER"] {
            activePane.insertIntoComposer(seed.replacingOccurrences(of: "\\n", with: "\n"))
        }
        installDriver()
        Soak.watchFrames(of: window)
    }

    /// Setup, from launch or from the road back the empty sidebar offers. It presents itself only
    /// when there is still no server, so pressing the row twice cannot stack two of them.
    func presentFirstRun() {
        FirstRunDialog.presentIfNeeded(parent: window) { [weak self] in
            Task { [weak self] in await self?.refresh() }
        }
    }

    /// The checklist for whoever asks for a machine to be added, from the empty pane or the
    /// Servers window: first run when no server exists, its addition mode when one does.
    func presentAddMachine(way: FirstRunPlan.Way.Kind? = nil) {
        FirstRunDialog.present(way: way, parent: window) { [weak self] in
            Task { [weak self] in await self?.refresh() }
        }
    }

    /// A machine just connected, from first run or from adding another: the toast says which, and
    /// a pane that holds no conversation opens the chooser already on that machine so the next
    /// press is a chat. The list was read when the server was saved, so the machine is known.
    func land(on landing: FirstRunLanding) {
        raise()
        toast(landing.toast)
        Task { [weak self] in
            await self?.refresh()
            Gtk.onMain { [weak self] in self?.openLandingChooser(landing) }
        }
    }

    func openLandingChooser(_ landing: FirstRunLanding) {
        let pane = activePane
        guard pane.sessionID == nil, !pane.chooserShown else { return }
        pane.showChooser(chooserModel(preferredServer: nil, landing: landing))
        splitHost.focus(pane, grabKeyboard: true)
        focused = .transcript
    }

    /// The welcome an empty pane draws while the app holds no real server, and its removal the
    /// moment one is saved. Tailscale is read once off the main thread and the welcome redrawn only
    /// if the answer changed what it says.
    func refreshWelcome() {
        let pane = activePane
        guard EmptyWelcome.holdsNoRealServer(knownProfiles), pane.sessionID == nil,
            !pane.chooserShown
        else {
            pane.clearWelcome()
            return
        }
        drawWelcome(in: pane)
        if welcomeFixture == nil { readTailscaleForWelcome() }
    }

    func drawWelcome(in pane: ChatPane) {
        var state = FirstRunState(platform: .linux)
        state.tailscale = welcomeTailscale
        if let welcomeFixture { state = welcomeFixture }
        let demoActive = !knownProfiles.isEmpty
        pane.showWelcome(EmptyWelcome.make(state, demoActive: demoActive)) { [weak self] intent in
            self?.answerWelcome(intent)
        }
    }

    func readTailscaleForWelcome() {
        guard !readingTailscaleForWelcome else { return }
        readingTailscaleForWelcome = true
        Task.detached { [weak self] in
            let reading = TailnetStatusLinux.read().reading
            Gtk.onMain { [weak self] in
                guard let self else { return }
                self.readingTailscaleForWelcome = false
                guard self.welcomeTailscale != reading else { return }
                self.welcomeTailscale = reading
                let pane = self.activePane
                if pane.welcomeShown { self.drawWelcome(in: pane) }
            }
        }
    }

    func answerWelcome(_ intent: EmptyWelcome.Intent) {
        switch intent {
        case .setUpMachine, .openTailscale: presentAddMachine()
        case .pasteLink: presentAddMachine(way: .link)
        case .tryDemo:
            Task { [weak self] in
                await ServerDirectory.shared.enterDemoMode()
                await self?.refresh()
            }
        case .signIn: presentServers()
        }
    }

    /// `frwelcome=<state>`: the welcome in one of the checklist's states, from `FirstRunFixtures`,
    /// so what it says while Tailscale is down or Claude is signed out can be looked at without either.
    func stageWelcome(_ name: String) {
        guard let state = FirstRunFixtures.state(named: name, platform: .linux) else {
            FileHandle.standardError.write(Data("welcome: no state \(name)\n".utf8))
            return
        }
        welcomeFixture = state
        drawWelcome(in: activePane)
    }
}
