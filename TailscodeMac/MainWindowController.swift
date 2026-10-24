import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

/// The hub — the Mac's `MainWindow`: it owns the window, the toolbar, the split layout, the
/// shortcut engine and the current-chat state. Child controllers talk to it through closures
/// wired at construction, and every later phase reaches the app through the handles this class
/// exposes rather than through globals.
@MainActor
final class MainWindowController: NSWindowController {
    let sidebar = SidebarViewController()
    /// The panes: the frame-placed canvas, or for one release the nested split controllers it
    /// replaced when `tailscode.legacyTiling` is set.
    let splitPanes: any PaneTiling = MainWindowController.makeTiling()
    /// The toolbar's `Live 2 of 5`.
    let liveChip = LiveChip()
    var liveChipItem: NSToolbarItem?
    #if !TAILSCODE_MAS
        let terminalPane = TerminalPane()
    #endif

    /// The focused pane's conversation — every single-chat verb in the app lands here, so the
    /// tiling tree changes what "the transcript" means without changing who asks for it.
    var transcript: TranscriptViewController { splitPanes.active }
    var currentEntry: SessionEntry? { transcript.currentEntry }
    var currentBackend: (any CodingAgentBackend)? { transcript.currentBackend }

    let split = NSSplitViewController()
    let contentSplit = NSSplitViewController()
    var sidebarItem: NSSplitViewItem?
    var terminalItem: NSSplitViewItem?
    var dividerSavingEnabled = false
    /// Posted once the live shortcut set has been re-read, for what is drawn with a key's name on it.
    static let shortcutsDidReload = Notification.Name("tailscode.mac.shortcutsDidReload")

    var shortcuts = ShortcutSet.load()
    var onShortcutsReloaded: (() -> Void)?
    var typeScaleWork: DispatchWorkItem?
    var pendingChords: [KeyChord] = []
    var focused: Pane = .chats
    /// What each restored pane was showing, until the cached listing carries the session and the
    /// pane can open it for real.
    var pendingBindings: [PaneID: SplitPaneSession] = [:]
    /// Restored chats a safe restore left paused after a launch that did not close normally; each
    /// wakes when its pane is gone to, or all at once from the banner.
    var parkedBindings: [PaneID: SplitPaneSession] = [:]
    /// Chats resolved and waiting their turn in a staggered wake, 300 ms apart.
    var wakingBindings: [PaneID: SplitPaneSession] = [:]
    var restoreBanner: RestoreBannerView?
    var cheatsheet: NSPanel?
    var keyMonitor: Any?
    var mouseMonitor: Any?
    var usageTask: Task<Void, Never>?
    var usageWindow: UsageWindowController?
    var spendPopover: NSPopover?
    var contextPopover: NSPopover?
    weak var rangePanel: RangePanelViewController?
    weak var rangePane: TranscriptViewController?
    var gitPopover: NSPopover?
    /// Diff windows outlive the popover that opened them, so the controller holds them: a window
    /// controller nobody retains closes itself the moment the stack unwinds.
    var gitDiffWindows: [GitDiffWindowController] = []
    var lastQuotas: [(String, UsageQuota)] = []
    /// The last good reading each machine gave for each account, served as cached while a poll
    /// fails and for no longer than ``QuotaFreshness/keptFor``.
    var heldQuotas: [HeldReading] = []
    /// When the last poll actually answered — nil while the first one is still out, which is a
    /// state the strip says out loud rather than an empty footer.
    var quotasAnsweredAt: Date?
    var usageTick: Timer?
    var serversWindow: ServersWindow?
    var welcomeTailscale: TailscaleReading?
    var welcomeFixture: FirstRunState?
    var readingTailscaleForWelcome = false
    var preferencesWindow: PreferencesWindow?
    var analyticsWindow: AnalyticsWindowController?
    var agentsWindow: AgentsWindowController?
    var updateWindow: UpdateWindowController?
    var proWindow: ProWindowController?
    var delegateWindow: DelegateWindowController?
    /// The settings toolbar item's button, which carries the standing mark. Weak because the
    /// toolbar owns its item's view, and this is only the handle that repaints the dot.
    weak var updateMark: UpdateMarkButton?
    /// The toolbar's video control, kept so the mark it wears can follow a render this window is not
    /// showing — the sheet closes, the other machine keeps working, and the control is where that is
    /// still legible.
    weak var videoMark: ForgeMarkButton?
    var watchFeed: MediaFeed?
    var watchCheckedAt: Date?
    var watchLoad: Task<Void, Never>?
    lazy var toasts = ToastPresenter { [weak self] in self?.transcript.toastAnchor }

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Tailscode"
        window.isReleasedWhenClosed = false
        window.contentMinSize = Self.smallestUsable
        window.collectionBehavior.insert(.fullScreenPrimary)
        MacTheme.Chrome.adopt(window)
        super.init(window: window)
        wireChildren()
        splitPanes.bootstrap()
        restoreSplitLayout()
        configureSplit()
        configureToolbar()
        wireLiveRuntime(window)
        window.center()
        window.setFrameAutosaveName("TailscodeMain")
        installKeyMonitor()
        installMouseMonitor()
        observeDividers()
        DispatchQueue.main.async { [weak self] in
            self?.applyStoredDividers()
            self?.dividerSavingEnabled = true
            self?.resolvePendingBindings()
        }
        startUsagePolling()
        MacUpdateWatch.shared.start()
        NotificationCenter.default.addObserver(
            forName: MacTheme.Chrome.didRepaint, object: nil, queue: .main
        ) { [weak self] _ in
            MainThread.call { self?.applyTheme() }
        }
        NotificationCenter.default.addObserver(
            forName: MacUpdateWatch.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainThread.call { self?.updateMark?.render() }
        }
        NotificationCenter.default.addObserver(
            forName: TypeScaleStore.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainThread.call { self?.typeScaleChanged() }
        }
        if !shortcuts.issues.isEmpty {
            setNotice(
                Localized.text("Keybindings: %@", shortcuts.issues.joined(separator: " · ")))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// The process's live conversations meet this window here: the drain's display link follows
    /// the window's screen, a watched chat's reading reaches the chat list, a window nobody can
    /// see parks every pane, and the governor's parked panes are parked.
    private func wireLiveRuntime(_ window: NSWindow) {
        let runtime = TileRuntime.shared
        runtime.clock.host = window.contentView
        runtime.onPresenceChanged = { [weak self] in
            self?.sidebar.notePresenceChanged()
            (self?.splitPanes as? TileHost)?.refreshStrip()
        }
        splitPanes.onRefused = { [weak self] text in self?.toast(text) }
        Seatbelts.shared.onDecision = { [weak self] decision in
            self?.splitPanes.applyGovernor(decision)
            self?.refreshLiveChip(decision)
        }
        liveChip.keepAllLive = { Seatbelts.shared.liveBudget == .all }
        liveChip.setKeepAllLive = { [weak self] keep in
            Seatbelts.shared.liveBudget = keep ? .all : .auto
            Seatbelts.shared.sample()
            self?.refreshLiveChip(Seatbelts.shared.decision)
        }
        splitPanes.onResume = { [weak self] paneID in self?.wakeParked(paneID) }
        if let tiles = splitPanes as? TileHost {
            tiles.listFace = { [weak self] session in self?.listFace(session) }
        }
        NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainThread.call {
                guard let self, let window = self.window else { return }
                self.splitPanes.setOccluded(!window.occlusionState.contains(.visible))
            }
        }
    }

    static let legacyTilingKey = "tailscode.legacyTiling"

    private static func makeTiling() -> any PaneTiling {
        UserDefaults.standard.bool(forKey: legacyTilingKey) ? SplitPaneHost() : TileHost()
    }

    /// The smallest window a chat still reads in: the chat list at its own minimum beside a
    /// conversation wide enough for the composer's row of pills, and tall enough for the composer
    /// with a few lines of transcript above it. The window had no floor at all, so it could be
    /// dragged down until nothing in it fit.
    private static let smallestUsable = NSSize(width: 640, height: 420)

    func open(_ entry: SessionEntry) {
        sidebar.open(entry)
    }

    /// What every pane is half-way through writing, put down on disk. The app delegate asks for
    /// this where the process is about to stop being asked — resigning active, quitting — because
    /// a draft is only ever lost in the moment nobody thought to save it.
    func stashComposerDrafts() {
        splitPanes.eachPane { $0.composer.stashDraft() }
    }

    func handleDidBecomeActive() {
        splitPanes.eachPane { $0.reconnect() }
        Task { [weak self] in
            await self?.sidebar.refresh()
            self?.resolvePendingBindings()
        }
    }

    /// When the last wake already scheduled falls due, so a second resolve queues behind it rather
    /// than starting its own streams in the same frames.
    var wakingQueueEnd: CFTimeInterval = 0

    var sidebarShown: Bool { sidebarItem?.isCollapsed == false }

    var terminalShown: Bool { terminalItem?.isCollapsed == false }

    /// What each conversation's last settled witness said, carried across the moment one watcher
    /// hands a chat to another. Without it, opening a live chat on a server whose listing cannot
    /// report a turn dropped the row to RECENT for one round trip and then took it back.
    var presenceLedger = PresenceLedger()
}

extension MainWindowController: PaneHost {
    func paneToast(_ text: String) { toast(text) }
    func paneDialToast(_ text: String) { dialToast(text) }
    func paneAuraChanged() { sidebar.refreshOrb() }
    func paneStateChanged(_ pane: TranscriptViewController) {
        sidebar.notePresenceChanged()
        if rangePane === pane { rangePanel?.stateChanged() }
    }
    func paneSlotChanged(_ pane: TranscriptViewController) { splitPanes.persist() }

    func pane(_ pane: TranscriptViewController, pressedBand action: StatusFacts.Action) {
        perform(bandAction: action, on: pane)
    }

    func pane(_ pane: TranscriptViewController, answeredChooser action: PaneChooserAction) {
        self.pane(pane, chose: action)
    }

    func pane(_ pane: TranscriptViewController, askedAgent words: String) {
        let chats = splitPanes.orderedPanes.filter { $0 !== pane && $0.currentEntry != nil }
        let target = chats.first { $0 === splitPanes.active } ?? chats.first
        guard let target else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(words, forType: .string)
            toast(Localized.text("Copied"))
            return
        }
        guard target.composer.sendAgain(words) else {
            toast(Localized.text("Send or clear what is in the composer first."))
            return
        }
    }

    func paneQuotas() -> [UsageQuota] { lastQuotas.map(\.1) }

    func paneWatchInBackground(_ entry: SessionEntry, backend: any CodingAgentBackend) {
        TileRuntime.shared.watch(entry, backend: backend)
    }

    func paneStopWatching(_ key: LiveKey) {
        TileRuntime.shared.stopWatching(key)
    }
}

extension MainWindowController: NSMenuDelegate {
    /// The ⋯ menu: everything the open conversation can do, rebuilt on every click so the verbs
    /// and the Save/Unsave title always describe the chat as it is now — capability-gated, and
    /// reusing the sidebar's own flows so a rename here and a rename there are the same rename.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let entry = currentEntry, let backend = currentBackend else {
            let empty = NSMenuItem(
                title: Localized.text("No conversation open"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        let capabilities = backend.capabilities
        let saved = SavedChatStore.contains(entry)
        menu.addItem(
            actionsItem(
                saved ? Localized.text("Unsave") : Localized.text("Save"),
                subtitle: Localized.text(
                    "A saved chat lists itself even when its server is unreachable")
            ) { [weak self] in
                self?.sidebar.toggleSaved(entry)
            })
        if capabilities.supportsRenaming {
            menu.addItem(
                actionsItem(Localized.text("Rename…")) { [weak self] in
                    self?.sidebar.presentRename(entry: entry, backend: backend)
                })
        }
        if capabilities.supportsForking {
            menu.addItem(
                actionsItem(
                    Localized.text("Fork"),
                    subtitle: Localized.text(
                        "A new session with this history, for a different direction")
                ) { [weak self] in
                    self?.sidebar.fork(entry: entry, backend: backend)
                })
        }
        if capabilities.supportsCompaction {
            menu.addItem(
                actionsItem(
                    Localized.text("Compact…"),
                    subtitle: Localized.text("Irreversible, takes minutes")
                ) { [weak self] in
                    self?.transcript.presentCompactPreflight()
                })
        }
        if !entry.host.isEmpty {
            menu.addItem(
                actionsItem(DelegateHandoff.menuTitle, subtitle: DelegateHandoff.details) { [weak self] in
                    self?.transcript.handOff(goal: "")
                })
        }
        if capabilities.supportsClearing {
            menu.addItem(
                actionsItem(
                    Localized.text("Clear…"),
                    subtitle: Localized.text("Empty the conversation in place")
                ) { [weak self] in
                    self?.presentClear(entry: entry, backend: backend)
                })
        }
        menu.addItem(.separator())
        menu.addItem(
            actionsItem(
                Localized.text("Delete…"),
                subtitle: Localized.text("Remove the session from its server"), destructive: true
            ) { [weak self] in
                self?.sidebar.presentDelete(entry: entry, backend: backend)
            })
    }

    private func actionsItem(
        _ title: String, subtitle: String? = nil, destructive: Bool = false,
        handler: @escaping @MainActor () -> Void
    ) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, handler: handler)
        if let subtitle { item.subtitle = subtitle }
        if destructive {
            item.attributedTitle = NSAttributedString(
                string: title, attributes: [.foregroundColor: MacTheme.Color.danger])
        }
        return item
    }

    private func presentClear(entry: SessionEntry, backend: any CodingAgentBackend) {
        let sessionID = entry.session.id
        MacDialogs.confirm(
            on: window,
            title: Localized.text("Clear this conversation?"),
            body: Localized.text("Everything in it goes away, on the server, for every device."),
            confirmLabel: Localized.text("Clear")
        ) { [weak self] in
            Task { [weak self] in
                try? await backend.clearConversation(sessionID)
                await self?.sidebar.refresh()
            }
        }
    }
}

#if DEBUG
    extension MainWindowController {
        /// `split=<n>`: the first chats of the list opened as one tiling, the way marking them does.
        func driveSplit(_ count: Int, as arrangement: SplitArrangement? = nil) {
            let chosen = arrangement ?? (count >= 3 ? .grid : .sideBySide)
            openMarkedSplit(Array(sidebar.entries.prefix(count)), as: chosen)
        }

        /// `tile=<verb>`: the canvas's own verbs, by name, for a run nobody is sitting at.
        func driveTile(_ verb: String) {
            let parts = verb.split(separator: ",").map(String.init)
            switch parts.first ?? "" {
            case "zoom": perform(.zoomSplit)
            case "next": perform(.cycleSplit(true))
            case "promote": perform(.promoteSplit)
            case "rotate": perform(.rotateSplits(true))
            case "arrange": perform(.arrangeSplits)
            case "pin": perform(.pinSplit)
            case "park": perform(.parkSplit)
            case "equal": perform(.equalizeSplits)
            case "wider": perform(.resizeSplit(.right))
            case "focus":
                let index = Int(parts.dropFirst().first ?? "") ?? 1
                let panes = splitPanes.orderedPanes
                if panes.indices.contains(index - 1) {
                    splitPanes.focus(panes[index - 1], grabKeyboard: false)
                }
            case "size":
                let width = Double(parts.dropFirst().first ?? "") ?? 1400
                let height = Double(parts.dropFirst(2).first ?? "") ?? 900
                window?.setContentSize(NSSize(width: width, height: height))
            case "sidebar": togglePane(.sidebar)
            default: break
            }
        }

        /// `tiles`: what the canvas holds, in counts and faces.
        func driveTilesReport() -> String {
            guard let tiles = splitPanes as? TileHost else { return "TILES legacy host" }
            let faces = tiles.layout.paneIDs.map { id -> String in
                switch tiles.face(of: id) {
                case .full?: return "F"
                case .glance?: return "G"
                case .paused?: return "P"
                case nil: return "?"
                }
            }
            let hidden = tiles.placement?.hidden.count ?? 0
            return
                "TILES panes=\(tiles.paneCount) faces=\(faces.joined()) hidden=\(hidden) "
                + "feeds=\(tiles.feedCount()) reparents=\(tiles.canvas.reparents) "
                + "chip=\"\(liveChip.button.title)\" level=\(Seatbelts.shared.level.code) "
                + "budget=\(Seatbelts.shared.decision?.fullBudget ?? -1) governed="
                + tiles.layout.paneIDs.map { id in
                    switch Seatbelts.shared.decision?.densities[id] {
                    case .full?: return "F"
                    case .glance?: return "G"
                    case .parked?: return "P"
                    case nil: return "-"
                    }
                }.joined()
        }

        /// `restore`: what the safe restore is holding, in counts.
        func driveRestoreReport() -> String {
            var open = 0
            splitPanes.eachPane { if $0.currentEntry != nil { open += 1 } }
            return
                "RESTORE panes=\(splitPanes.paneCount) open=\(open) parked=\(parkedBindings.count) "
                + "pending=\(pendingBindings.count) waking=\(wakingBindings.count) "
                + "banner=\(restoreBanner?.text ?? "none")"
        }

        /// `resume=all` or `resume=one`: the banner's two buttons.
        func driveResume(_ how: String) {
            if how == "all" { resumeAllParked() } else { resumeParkedOneByOne() }
        }

        /// `chord=ctrl+w a`: a registered sequence resolved through the same shortcut set a key
        /// press goes through, so a scripted chord and a typed one are the same code path.
        func driveChord(_ spec: String) -> String {
            guard let (_, chords) = KeySpec.parse(spec) else { return "CHORD unreadable \(spec)" }
            for chord in chords {
                switch shortcuts.resolve(
                    chord, context: .normal, pending: pendingChords, awaitingApproval: false)
                {
                case .run(let action):
                    pendingChords = []
                    _ = perform(action)
                case .pending(let held):
                    pendingChords = held
                case .unbound:
                    pendingChords = []
                }
            }
            return splitPanes.driveOrder("CHORD \(spec)")
        }
    }
#endif
