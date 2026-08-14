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
    let splitPanes = SplitPaneHost()
    let filesPane = FileTreePane()
    let terminalPane = TerminalPane()

    /// The focused pane's conversation — every single-chat verb in the app lands here, so the
    /// tiling tree changes what "the transcript" means without changing who asks for it.
    var transcript: TranscriptViewController { splitPanes.active }
    var currentEntry: SessionEntry? { transcript.currentEntry }
    var currentBackend: (any CodingAgentBackend)? { transcript.currentBackend }

    private let split = NSSplitViewController()
    private let contentSplit = NSSplitViewController()
    private var sidebarItem: NSSplitViewItem?
    private var filesItem: NSSplitViewItem?
    private var terminalItem: NSSplitViewItem?
    private var dividerSavingEnabled = false
    private var shortcuts = ShortcutSet.load()
    private var pendingChords: [KeyChord] = []
    private var focused: Pane = .chats
    /// What each restored pane was showing, until the cached listing carries the session and the
    /// pane can open it for real.
    private var pendingBindings: [PaneID: SplitPaneSession] = [:]
    private var cheatsheet: NSPanel?
    private var keyMonitor: Any?
    private var mouseMonitor: Any?
    private var usageTask: Task<Void, Never>?
    private var usagePopover: NSPopover?
    private var spendPopover: NSPopover?
    private var gitPopover: NSPopover?
    /// Diff windows outlive the popover that opened them, so the controller holds them: a window
    /// controller nobody retains closes itself the moment the stack unwinds.
    private var gitDiffWindows: [GitDiffWindowController] = []
    private var lastQuotas: [(String, UsageQuota)] = []
    /// When the last poll actually answered — nil while the first one is still out, which is a
    /// state the strip says out loud rather than an empty footer.
    private var quotasAnsweredAt: Date?
    private var usageTick: Timer?
    private var serversWindow: ServersWindow?
    private var preferencesWindow: PreferencesWindow?
    private var analyticsWindow: AnalyticsWindowController?
    private var updateWindow: UpdateWindowController?
    /// The settings toolbar item's button, which carries the standing mark. Weak because the
    /// toolbar owns its item's view, and this is only the handle that repaints the dot.
    private weak var updateMark: UpdateMarkButton?
    private var watchFeed: MediaFeed?
    private var watchCheckedAt: Date?
    private var watchLoad: Task<Void, Never>?
    private lazy var toasts = ToastPresenter { [weak self] in self?.transcript.toastAnchor }

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Tailscode"
        MacTheme.Chrome.adopt(window)
        super.init(window: window)
        wireChildren()
        splitPanes.bootstrap()
        restoreSplitLayout()
        configureSplit()
        configureToolbar()
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
            MainActor.assumeIsolated { self?.applyTheme() }
        }
        NotificationCenter.default.addObserver(
            forName: UpdateLedger.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateMark?.render() }
        }
        if !shortcuts.issues.isEmpty {
            setNotice(
                Localized.text("Keybindings: %@", shortcuts.issues.joined(separator: " · ")))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

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

    /// A restored pane opens its session the moment the cached listing carries it; a session no
    /// listing carries leaves an explanation, and the binding is kept for the next refresh.
    private func resolvePendingBindings() {
        guard !pendingBindings.isEmpty else { return }
        let listed = SessionListCache.load()
        for (paneID, binding) in pendingBindings {
            guard let pane = splitPanes.panes[paneID] else {
                pendingBindings[paneID] = nil
                continue
            }
            guard
                let entry = listed.first(where: {
                    $0.profileID == binding.profileID && $0.session.id == binding.sessionID
                }),
                let profile = ServerDirectory.shared.profiles.first(where: {
                    $0.id == binding.profileID
                }),
                let backend = ServerDirectory.shared.backend(for: profile)
            else { continue }
            pendingBindings[paneID] = nil
            pane.open(entry, backend: backend)
        }
    }

    private func restoreSplitLayout() {
        guard let raw = UserDefaults.standard.string(forKey: SplitSnapshot.defaultsKey),
            let snapshot = SplitSnapshot.decode(raw)
        else { return }
        pendingBindings = splitPanes.restore(snapshot)
    }

    /// The focused pane changed — by keyboard, click, band, or a structural verb. The window
    /// title, the file tree, the terminal and the remembered last-session all follow the eye.
    private func focusedPaneChanged() {
        let pane = transcript
        guard let entry = pane.currentEntry else {
            window?.title = "Tailscode"
            window?.subtitle = ""
            return
        }
        UserDefaults.standard.set(entry.session.id, forKey: "tailscode.lastSession")
        window?.title =
            entry.session.hasPlaceholderTitle
            ? Localized.text("New conversation") : entry.session.title
        window?.subtitle = ServerLabel.display(name: entry.profileName, backend: entry.backendType)
        terminalPane.setDirectory(entry.session.directory)
        if let backend = pane.currentBackend {
            filesPane.show(directory: entry.session.directory, on: backend)
        }
    }

    /// The marked chats opened all at once as one even tiling: the tree replaces what the window
    /// held — the gesture asked for these conversations — and the panes bind through the same
    /// machinery a launch restore uses, so a server that cannot answer right now resolves on the
    /// next refresh instead of failing the whole gesture.
    private func openMarkedSplit(_ chosen: [SessionEntry], as arrangement: SplitArrangement) {
        guard let layout = SplitEven.layout(count: chosen.count, as: arrangement) else { return }
        var sessions: [String: SplitPaneSession] = [:]
        for (pane, entry) in zip(layout.paneIDs, chosen) {
            SessionSeenStore.markSeen(entry.session.id)
            sessions[pane.raw] = SplitPaneSession(
                profileID: entry.profileID, sessionID: entry.session.id)
        }
        pendingBindings = splitPanes.restore(SplitSnapshot(layout: layout, sessions: sessions))
        resolvePendingBindings()
        splitPanes.persist()
        focusedPaneChanged()
    }

    /// Opening a row into a fresh pane beside the ones already on screen: split, then run the
    /// same open path a sidebar click takes.
    private func openInNewSplit(_ entry: SessionEntry) {
        guard
            let profile = ServerDirectory.shared.profiles.first(where: {
                $0.id == entry.profileID
            }), let backend = ServerDirectory.shared.backend(for: profile)
        else {
            setNotice(Localized.text("That server is not configured."))
            return
        }
        splitPanes.splitActive(axis: .horizontal)
        SessionSeenStore.markSeen(entry.session.id)
        handleOpen(entry, backend: backend)
    }

    /// A two-second floating confirmation — the answer to "did my click do anything". Presented
    /// by the hub so every child's toast lands in the same queue.
    func toast(_ text: String) {
        toasts.show(text)
    }

    func setNotice(_ text: String) {
        transcript.setNotice(text)
    }

    /// Re-reads the rebinding file and rebuilds everything derived from it, live: the resolver,
    /// the cheatsheet if it is open, and the notice line if the file has something wrong in it.
    func reloadShortcuts() {
        shortcuts = ShortcutSet.load()
        pendingChords = []
        if let cheatsheet, cheatsheet.isVisible {
            cheatsheet.close()
            presentCheatsheet()
        }
        if shortcuts.issues.isEmpty {
            toast(Localized.text("Shortcuts reloaded"))
        } else {
            setNotice(
                Localized.text("Keybindings: %@", shortcuts.issues.joined(separator: " · ")))
        }
    }

    /// Everything the keyboard can mean, one switch. A verb aimed at a hidden pane declines,
    /// returning false so the keystroke falls through instead of being swallowed by a promise.
    @discardableResult
    func perform(_ action: KeyAction) -> Bool {
        switch action {
        case .focus(let pane):
            return focus(pane)
        case .cycleForward:
            cycle(1)
        case .cycleBackward:
            cycle(-1)
        case .selectNext:
            sidebar.move(by: 1)
        case .selectPrevious:
            sidebar.move(by: -1)
        case .selectFirst:
            sidebar.selectFirst()
        case .selectLast:
            sidebar.selectLast()
        case .openSelected:
            sidebar.openCursor()
        case .search:
            sidebar.focusFilter()
        case .insert:
            focused = .transcript
            transcript.focusComposer()
        case .leaveInsert:
            if sidebar.clearMarks() { return true }
            transcript.setFindShown(false)
            transcript.composer.dismissCompletion()
            window?.makeFirstResponder(nil)
            closeCheatsheet()
        case .toggleSaved:
            guard let currentEntry else { return true }
            sidebar.toggleSaved(currentEntry)
        case .archiveSelected:
            guard let currentEntry else { return true }
            sidebar.toggleArchived(currentEntry)
        case .toggleArchiveView:
            sidebar.setArchiveShown(!sidebar.showingArchive)
        case .toggleUnreadSelected:
            guard let currentEntry else { return true }
            sidebar.toggleUnread(currentEntry)
        case .renameSelected:
            guard let currentEntry, let currentBackend,
                currentBackend.capabilities.supportsRenaming
            else { return true }
            sidebar.presentRename(entry: currentEntry, backend: currentBackend)
        case .forkSelected:
            guard let currentEntry, let currentBackend,
                currentBackend.capabilities.supportsForking
            else { return true }
            sidebar.fork(entry: currentEntry, backend: currentBackend)
        case .toggleMarked:
            sidebar.toggleMarkUnderCursor()
        case .toggleMarkAll:
            sidebar.toggleMarkAllShown()
        case .deleteSelected:
            sidebar.presentDeleteFromKeyboard()
        case .copySessionID:
            guard let currentEntry else { return true }
            copyToPasteboard(currentEntry.session.id)
        case .copyProjectPath:
            guard let directory = currentEntry?.session.directory else { return true }
            copyToPasteboard(directory)
        case .toggleSidebar:
            togglePane(.sidebar)
        case .toggleFiles:
            togglePane(.files)
        case .toggleTerminal:
            togglePane(.terminal)
        case .toggleHelp:
            toggleCheatsheet()
        case .newChat:
            presentNewChat()
        case .reload:
            Task { [weak self] in await self?.sidebar.refresh() }
        case .scrollDown:
            transcript.scrollBy(60)
        case .scrollUp:
            transcript.scrollBy(-60)
        case .halfPageDown:
            transcript.scrollByPages(0.5)
        case .halfPageUp:
            transcript.scrollByPages(-0.5)
        case .scrollTop:
            transcript.scrollToTop()
        case .scrollBottom:
            transcript.scrollToBottom()
        case .findInConversation:
            transcript.setFindShown(true)
        case .allowOnce:
            transcript.respondToFirstPermission(.once)
        case .allowAlways:
            transcript.respondToFirstPermission(.always)
        case .deny:
            transcript.respondToFirstPermission(.reject)
        case .stop:
            if let text = window?.firstResponder as? NSText, text.selectedRange.length > 0 {
                text.copy(nil)
                toast(Localized.text("Copied"))
            } else {
                transcript.stopTurn()
            }
        case .send:
            transcript.composer.sendNow()
        case .commandPalette:
            transcript.composer.openCommandPalette()
        case .zoomIn:
            MacTheme.UIScale.step(0.1)
            applyUIScale()
        case .zoomOut:
            MacTheme.UIScale.step(-0.1)
            applyUIScale()
        case .zoomReset:
            MacTheme.UIScale.reset()
            applyUIScale()
        case .splitPane(let axis):
            focused = .transcript
            splitPanes.splitActive(axis: axis)
        case .closeSplit:
            splitPanes.closeActive()
        case .focusSplit(let direction):
            focused = .transcript
            splitPanes.focusNeighbor(direction)
        case .zoomSplit:
            splitPanes.zoomActive()
        case .equalizeSplits:
            splitPanes.equalize()
        case .exchangeSplit:
            splitPanes.exchangeActive()
        case .toggleProjectScope:
            sidebar.toggleProjectScope(fallback: currentEntry)
        case .quickAsk:
            presentQuickAsk()
        }
        return true
    }

    /// Every fact on the band answers to the same verbs a person would reach for — on the pane
    /// whose band was clicked, which the click also focuses.
    func perform(bandAction action: StatusFacts.Action, on pane: TranscriptViewController) {
        splitPanes.focus(pane, grabKeyboard: false)
        switch action {
        case .stop:
            pane.stopTurn()
        case .compact:
            pane.presentCompactPreflight()
        case .goal:
            pane.presentGoalSheet()
        case .scrollToPending:
            pane.scrollToBottom()
        case .scrollToAgents:
            pane.scrollToNewestAgent()
        case .agent(let id):
            pane.scrollToAgent(id)
        case .spend:
            presentSpend(for: pane)
        case .git:
            presentGit(for: pane)
        case .reconnect:
            pane.reconnect()
        }
    }

    /// The account behind the price, in a popover off the band itself — the number is where the
    /// question was asked, so the answer belongs there rather than in a window of its own.
    private func presentSpend(for pane: TranscriptViewController) {
        guard let spend = pane.spend else { return }
        spendPopover?.close()
        let panel = SpendPanelViewController(
            spend: spend, title: pane.currentEntry?.session.title ?? Localized.text("This conversation"))
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = panel
        let anchor = pane.bandAnchor
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        spendPopover = popover
    }

    /// The repository behind the branch on the band, in a popover off the band itself. A path or a
    /// commit inside it opens in a window, because a diff outlives the popover that offered it.
    private func presentGit(for pane: TranscriptViewController) {
        guard let git = pane.git, let backend = pane.gitBackend, let entry = pane.currentEntry
        else { return }
        gitPopover?.close()
        let directory = entry.session.directory
        let sessionID = entry.session.id
        let panel = GitPanelViewController(
            state: git, title: entry.session.title,
            patch: { row in
                try? await backend.gitPatch(
                    directory: directory, sessionID: sessionID, path: row.path, staged: row.staged)?
                    .patch
            },
            commit: { commit in
                try? await backend.gitCommit(
                    directory: directory, sessionID: sessionID, hash: commit.hash)?.patch
            },
            openDiff: { [weak self] title, subtitle, load in
                self?.gitPopover?.close()
                let window = GitDiffWindowController(title: title, subtitle: subtitle, load: load)
                self?.gitDiffWindows.append(window)
                window.present()
            })
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = panel
        let anchor = pane.bandAnchor
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        gitPopover = popover
    }

    private func applyUIScale() {
        splitPanes.eachPane { $0.applyUIScale() }
        sidebar.applyUIScale()
    }

    /// A theme change is a restyle of everything, and AppKit has no trait to invalidate for it: a
    /// `CGColor` in a layer and a rendering in a memo both keep the colour they were born with. So
    /// the window takes the same road it takes for a change of type scale — drop what was baked,
    /// rebuild what was drawn — and the two paths stay one path on purpose.
    private func applyTheme() {
        MacMarkdown.invalidate()
        window?.appearance = MacTheme.Chrome.appearance
        applyUIScale()
        transcript.applyPaneColours()
        splitPanes.eachPane { $0.applyPaneColours() }
        updateMark?.render()
    }

    /// The servers window, one per app: add, probe, update, sign in or remove a server, with the
    /// sidebar refreshed behind every change.
    func presentServers() {
        if serversWindow == nil {
            serversWindow = ServersWindow { [weak self] in
                MacUpdateWatch.shared.noteProfilesChanged()
                Task { [weak self] in await self?.sidebar.refresh() }
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
        }
        updateWindow?.present()
    }

    func presentPreferences() {
        if preferencesWindow == nil {
            preferencesWindow = PreferencesWindow(
                onComposerChanged: { [weak self] in
                    self?.transcript.composer.applyPreferences()
                },
                onTranscriptChanged: { [weak self] in
                    self?.transcript.applyUIScale()
                    Task { await self?.sidebar.refresh() }
                },
                onReloadShortcuts: { [weak self] in
                    self?.reloadShortcuts()
                })
        }
        preferencesWindow?.present()
    }

    /// A pane with nothing in it asks which server, then what on it — the question the chat list
    /// cannot ask, at the moment a split makes it worth asking.
    func presentChooser(in pane: TranscriptViewController, preferring serverID: String? = nil) {
        var chooser = PaneChooser(
            servers: chooserServers, entries: sidebar.allEntries, preferredServer: serverID)
        chooser.watchSummary = watchSummary
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

    private func restateChoosers() {
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
    private func pane(_ pane: TranscriptViewController, chose action: PaneChooserAction) {
        switch action {
        case .openChat(_, let sessionID):
            guard let entry = sidebar.allEntries.first(where: { $0.session.id == sessionID })
            else { return }
            splitPanes.focus(pane, grabKeyboard: false)
            sidebar.open(entry)
        case .newChat(let profileID):
            guard let profile = ServerDirectory.shared.profiles.first(where: { $0.id == profileID })
            else { return }
            splitPanes.focus(pane, grabKeyboard: false)
            presentNewChat(on: profile)
        case .addServer:
            presentServers()
        case .watch:
            splitPanes.focus(pane, grabKeyboard: false)
            pane.showVideo(nil)
            splitPanes.persist()
        case .browse:
            splitPanes.focus(pane, grabKeyboard: false)
            pane.showWeb(nil)
            splitPanes.persist()
        case .chooseServer, .allChats, .back:
            break
        }
    }

    /// ⌘N: a server and a directory, then Enter. No configured server means the servers window —
    /// the form that fixes the actual problem — rather than an empty picker.
    /// - Parameter profile: the server the sheet opens on, when the question has already been
    ///   answered somewhere else — a pane's chooser — so it is never asked twice.
    func presentNewChat(on profile: ConnectionProfile? = nil) {
        let profiles = ServerDirectory.shared.profiles
        guard !profiles.isEmpty else {
            presentServers()
            return
        }
        let entries = sidebar.allEntries
        let down = sidebar.unreachableServers
        Task { [weak self] in
            let locals = await Task.detached { NewChatSheet.localAddresses }.value
            guard let self, let window = self.window else { return }
            NewChatSheet.present(
                on: window, profiles: profiles, entries: entries, unreachable: down,
                localAddresses: locals, preferredServer: profile?.id,
                onFix: { [weak self] fix, done in self?.applyNewChatFix(fix, done: done) }
            ) { [weak self] profile, directory, done in
                self?.createChat(on: profile, directory: directory, done: done)
            }
        }
    }

    /// The one round trip that mints the session id is all the new chat waits for. The sidebar
    /// row is seeded from the answer and the conversation opens on the spot with the composer
    /// focused; the full list refresh reconciles behind it, because a person who just started a
    /// chat is looking at the prompt box, not at the list.
    private func createChat(
        on profile: ConnectionProfile, directory: String?,
        done: @escaping @MainActor (NewChatFailure?) -> Void = { _ in }
    ) {
        guard let backend = ServerDirectory.shared.backend(for: profile) else {
            done(NewChatDiagnosis.noCredentials(server: Self.newChatServer(profile)))
            return
        }
        let server = Self.newChatServer(profile)
        let password = ServerDirectory.shared.password(for: profile)
        Task { [weak self] in
            let minted = await NewChatAttempt.mint(
                using: backend, server: server, baseURL: profile.baseURL, password: password,
                directory: directory)
            guard case .success(let session) = minted else {
                done(minted.failureValue)
                return
            }
            done(nil)
            guard let self else { return }
            let entry = SessionEntry(
                profileID: profile.id, profileName: profile.name,
                host: profile.baseURL.host ?? profile.name,
                backendType: profile.backend, session: session)
            self.sidebar.noteCreated(entry)
            self.transcript.focusComposer()
            await self.sidebar.refresh()
        }
    }

    private static func newChatServer(_ profile: ConnectionProfile) -> NewChatServer {
        NewChatServer(
            profileID: profile.id, name: profile.name, backend: profile.backend,
            address: ServerLabel.address(profile))
    }

    /// The failure card's own remedy, carried out: a repoint rewrites the server's address so the
    /// chat can be tried again on the spot; anything else opens the screen it is fixed on.
    private func applyNewChatFix(
        _ fix: NewChatFailure.Fix, done: @escaping @MainActor (NewChatFailure?) -> Void
    ) {
        switch fix {
        case .repoint(let profileID, let url, _):
            guard var profile = ServerDirectory.shared.profiles.first(where: { $0.id == profileID })
            else {
                done(NewChatDiagnosis.noSuchServer())
                return
            }
            let password = ServerDirectory.shared.password(for: profile)
            profile.baseURL = url
            do {
                try ServerDirectory.shared.save(profile, password: password)
                done(nil)
                Task { [weak self] in await self?.sidebar.refresh() }
            } catch {
                done(
                    NewChatDiagnosis.failure(
                        server: Self.newChatServer(profile), directory: nil,
                        error: AgentErrorText.readable(error), witness: .unknown))
            }
        case .editServer, .none, .retry:
            presentServers()
            done(nil)
        }
    }

    /// A notification tap: raise the window, then bring the session it names to the eye — the
    /// pane already showing it if one is, else through the ordinary open into the focused pane.
    func openSession(withID id: String) {
        window?.makeKeyAndOrderFront(nil)
        if let pane = splitPanes.pane(showing: id) {
            splitPanes.focus(pane, grabKeyboard: false)
            return
        }
        sidebar.open(withID: id)
    }

    private func wireChildren() {
        sidebar.onOpen = { [weak self] entry, backend in
            self?.handleOpen(entry, backend: backend)
        }
        sidebar.onOpenSplit = { [weak self] entries, arrangement in
            self?.openMarkedSplit(entries, as: arrangement)
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
        sidebar.ultracodeSource = { [weak self] in
            var active = false
            self?.splitPanes.eachPane { active = active || $0.composer.auraActive }
            return active
        }
        sidebar.presenceSource = { [weak self] in self?.observedPresence() ?? [:] }
        splitPanes.makePane = { [weak self] in
            self?.makePane() ?? TranscriptViewController()
        }
        splitPanes.onPaneOpened = { [weak self] pane, source in
            self?.presentChooser(in: pane, preferring: source)
        }
        splitPanes.onFocusChanged = { [weak self] in self?.focusedPaneChanged() }
        splitPanes.chatTitleForDrop = { [weak self] payload in
            self?.chatTitle(for: payload)
        }
        splitPanes.onChatDropped = { [weak self] pane, payload, zone in
            self?.pane(pane, received: payload, zone: zone) ?? false
        }
        sidebar.onEntriesChanged = { [weak self] in
            self?.restateChoosers()
            self?.resolvePendingBindings()
        }
        filesPane.onOpen = { [weak self] path in
            self?.transcript.composer.insertText("@\(path) ")
        }
    }

    /// Every pane is wired at birth: its state feeds the notifier with its own session, its
    /// toasts land in the shared queue, and its band steers the pane it belongs to.
    private func makePane() -> TranscriptViewController {
        let pane = TranscriptViewController()
        pane.composer.onAuraChanged = { [weak self] in self?.sidebar.refreshOrb() }
        pane.onBackgroundWatch = { [weak self] conversation, entry in
            self?.keepWatching(conversation, entry: entry)
        }
        pane.onStopWatch = { [weak self] key in self?.stopWatching(key) }
        pane.onState = { [weak self, weak pane] state in
            guard let pane, let entry = pane.currentEntry else { return }
            MacNotifier.shared.observeConversation(
                profileID: entry.profileID, sessionID: entry.session.id,
                title: MissedActivity.name(
                    title: entry.session.title,
                    latestPrompt: state.messages.last { $0.role == .user }?
                        .parts.compactMap(\.text).joined(separator: "\n")),
                state: state)
            self?.sidebar.notePresenceChanged()
        }
        pane.onToast = { [weak self] text in self?.toast(text) }
        pane.onVideoChanged = { [weak self] in self?.splitPanes.persist() }
        pane.onBandAction = { [weak self, weak pane] action in
            guard let pane else { return }
            self?.perform(bandAction: action, on: pane)
        }
        pane.onChooserAction = { [weak self, weak pane] action in
            guard let pane else { return }
            self?.pane(pane, chose: action)
        }
        pane.quotasForStatus = { [weak self] in self?.lastQuotas.map(\.1) ?? [] }
        return pane
    }

    /// What every pane on screen knows first-hand about the conversation it is streaming, keyed
    /// the way the stores are keyed. This is what makes LIVE NOW honest: the server's listing
    /// reports `active` only for the seconds a turn is literally open on it and never reports a
    /// turn that stopped to ask for an approval, so a chat being talked in right now would
    /// otherwise be findable only by recency.
    private func observedPresence() -> [String: SessionPresence] {
        var observed = backgroundPresence
        splitPanes.eachPane { pane in
            guard let entry = pane.currentEntry else { return }
            let presence = pane.presence
            guard presence != .unobserved else { return }
            observed[SessionPinStore.key(entry.profileID, entry.session.id)] = presence
        }
        return observed
    }

    /// Watches a conversation whose pane moved on, so a turn still in flight keeps its LIVE NOW
    /// seat until it settles — the same retention the phone gives an in-flight chat.
    private var backgroundWatch: [String: (id: UUID, task: Task<Void, Never>)] = [:]
    private var backgroundPresence: [String: SessionPresence] = [:]

    func keepWatching(_ conversation: AgentConversation, entry: SessionEntry) {
        let key = SessionPinStore.key(entry.profileID, entry.session.id)
        stopWatching(key)
        let id = UUID()
        let task = Task { [weak self] in
            var lastReading: SessionPresence = .running(nil)
            while !Task.isCancelled {
                let stream = await conversation.states()
                for await state in stream {
                    guard let self else { return }
                    let reading = SessionPresence.reading(state, step: nil)
                    let changed = reading != lastReading
                    lastReading = reading
                    let settled = reading == .unobserved
                    DispatchQueue.main.async { [weak self] in
                        guard let self, self.backgroundWatch[key]?.id == id else { return }
                        self.backgroundPresence[key] = reading
                        if changed { self.sidebar.notePresenceChanged() }
                        if settled { self.stopWatching(key) }
                    }
                    if settled { return }
                }
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.backgroundWatch[key]?.id == id else { return }
                self.backgroundWatch[key] = nil
                self.backgroundPresence[key] = nil
                self.sidebar.notePresenceChanged()
            }
        }
        backgroundWatch[key] = (id, task)
    }

    func stopWatching(_ key: String) {
        backgroundWatch[key]?.task.cancel()
        backgroundWatch[key] = nil
        backgroundPresence[key] = nil
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

    /// Quota is account state, not session state: polled on its own slow cadence — quickly only
    /// while the profile list has not been seeded yet — and rendered in the sidebar footer, the
    /// way the phone keeps it on the Home board.
    private func startUsagePolling() {
        usageTask = Task { [weak self] in
            while !Task.isCancelled {
                let settled = await self?.refreshUsage() ?? true
                try? await Task.sleep(for: .seconds(settled ? 120 : 15))
            }
        }
        startUsageTick()
    }

    private func refreshUsage() async -> Bool {
        let profiles = ServerDirectory.shared.profiles
        guard !profiles.isEmpty else { return false }
        let snapshot = await Self.collectQuotas(profiles: profiles)
        if snapshot.isEmpty {
            if lastQuotas.isEmpty { quotasAnsweredAt = Date() }
        } else {
            lastQuotas = snapshot
            quotasAnsweredAt = Date()
        }
        sidebar.renderUsage(lastQuotas, answeredAt: quotasAnsweredAt)
        return true
    }

    /// The numbers move on the poll's cadence; the words about them move on their own, so a reset
    /// counted down two minutes at a time does not read as a clock that has stopped and an age
    /// only grows when there is something to grow from.
    private func startUsageTick() {
        usageTick?.invalidate()
        usageTick = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.sidebar.renderUsage(self.lastQuotas, answeredAt: self.quotasAnsweredAt)
            }
        }
    }

    /// Every quota every server can speak for: the agent's own, plus whatever other providers
    /// the machine holds accounts for (a bridge also reports Grok). Nothing is dropped here —
    /// ``QuotaRollup`` folds the reports into one holding per provider, so a second machine
    /// refines the account's numbers instead of being thrown away for arriving late.
    private static func collectQuotas(profiles: [ConnectionProfile]) async
        -> [(String, UsageQuota)]
    {
        var quotas: [(String, UsageQuota)] = []
        for profile in profiles {
            guard let backend = ServerDirectory.shared.backend(for: profile) else { continue }
            var collected: [UsageQuota] = []
            if let quota = (try? await backend.usageQuota()) ?? nil { collected.append(quota) }
            collected += (try? await backend.additionalUsageQuotas()) ?? []
            for quota in collected {
                quotas.append((profile.name, quota))
            }
        }
        return quotas
    }

    private func presentUsagePopover(from anchor: NSView) {
        if let usagePopover, usagePopover.isShown {
            usagePopover.close()
            self.usagePopover = nil
            return
        }
        let panel = UsagePanelViewController(
            initial: lastQuotas,
            refresh: { await Self.collectQuotas(profiles: ServerDirectory.shared.profiles) },
            onAnalytics: { [weak self] in
                self?.usagePopover?.close()
                self?.usagePopover = nil
                self?.presentAnalytics()
            })
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = panel
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        usagePopover = popover
    }

    /// The month in numbers, one window per app, held in a property because a window presented
    /// from a local is dead on arrival — released while shown, its buttons do nothing.
    func presentAnalytics() {
        if analyticsWindow == nil {
            analyticsWindow = AnalyticsWindowController {
                await Self.collectAnalytics()
            }
        }
        analyticsWindow?.present()
    }

    /// The whole account: every Claude server's ledger over the default window, merged by Core.
    /// One machine answering once is enough — a second profile on the same host must not double
    /// the money — and a server that cannot answer is named so its absence is a stated fact.
    private static func collectAnalytics() async -> UsageAnalytics? {
        var reports: [(name: String, report: UsageAnalyticsReport)] = []
        var missing: [String] = []
        var seenHosts = Set<String>()
        for profile in ServerDirectory.shared.profiles where profile.backend == .claudeCode {
            let host = "\(profile.baseURL.host ?? profile.id):\(profile.baseURL.port ?? 0)"
            guard seenHosts.insert(host).inserted else { continue }
            guard let backend = ServerDirectory.shared.backend(for: profile) else {
                missing.append(profile.name)
                continue
            }
            do {
                if let report = try await backend.usageAnalytics(
                    days: UsageAnalytics.defaultWindowDays)
                {
                    reports.append((profile.name, report))
                } else {
                    missing.append(profile.name)
                }
            } catch {
                continue
            }
        }
        return UsageAnalytics(servers: reports, missingServers: missing)
    }

    private func handleOpen(_ entry: SessionEntry, backend: any CodingAgentBackend) {
        UserDefaults.standard.set(entry.session.id, forKey: "tailscode.lastSession")
        transcript.open(entry, backend: backend)
        filesPane.show(directory: entry.session.directory, on: backend)
        terminalPane.setDirectory(entry.session.directory)
        window?.title =
            entry.session.hasPlaceholderTitle
            ? Localized.text("New conversation") : entry.session.title
        window?.subtitle = ServerLabel.display(name: entry.profileName, backend: entry.backendType)
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

    /// Sidebar, content column, files inspector — and inside the content column its own vertical
    /// split, the transcript over the terminal, so the terminal pane belongs to the conversation
    /// the way it does on Linux rather than running under the whole window.
    private func configureSplit() {
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 240
        sidebarItem.maximumThickness = 400
        sidebarItem.canCollapse = true
        sidebarItem.isCollapsed = !paneShown(.sidebar)
        split.addSplitViewItem(sidebarItem)
        self.sidebarItem = sidebarItem

        contentSplit.splitView.isVertical = false
        contentSplit.splitView.dividerStyle = .thin
        let transcriptItem = NSSplitViewItem(viewController: splitPanes)
        transcriptItem.minimumThickness = 240
        contentSplit.addSplitViewItem(transcriptItem)
        let terminal = NSSplitViewItem(viewController: terminalPane)
        terminal.minimumThickness = 120
        terminal.canCollapse = true
        terminal.holdingPriority = NSLayoutConstraint.Priority(261)
        terminal.isCollapsed = !paneShown(.terminal)
        contentSplit.addSplitViewItem(terminal)
        terminalItem = terminal
        split.addSplitViewItem(NSSplitViewItem(viewController: contentSplit))

        let files = NSSplitViewItem(inspectorWithViewController: filesPane)
        files.minimumThickness = 220
        files.maximumThickness = 400
        files.canCollapse = true
        files.isCollapsed = !paneShown(.files)
        split.addSplitViewItem(files)
        filesItem = files

        window?.contentViewController = split
    }

    private func configureToolbar() {
        guard let window else { return }
        let toolbar = NSToolbar(identifier: "TailscodeToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.titleVisibility = .visible
    }

    /// One local monitor is the whole engine: ⌘ chords fall through to the menu bar (the adapter
    /// returns nil for them on purpose), text fields keep their letters, and everything else goes
    /// through the shared registry exactly like Linux `installKeymap`.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            return self.handle(event)
        }
    }

    /// The pointer's own claim on the keyboard: a local monitor sees every button going down
    /// before AppKit dispatches it, so whatever was pressed becomes the focused pane and the
    /// keyboard's region *first* — a band chip, a permission card or a pill in a background pane
    /// then acts on its own conversation instead of on whichever pane the eye had left behind.
    /// The event is returned untouched: the click keeps its ordinary meaning and first responder
    /// lands exactly where the press put it.
    private func installMouseMonitor() {
        mouseMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] event in
            self?.pressLanded(event)
            return event
        }
    }

    private func pressLanded(_ event: NSEvent) {
        guard event.window === window else { return }
        let point = event.locationInWindow
        if let pane = splitPanes.pane(atWindowPoint: point) {
            regionPressed(.transcript)
            splitPanes.focus(pane, grabKeyboard: false)
            return
        }
        if contains(sidebar, point) {
            regionPressed(.chats)
        } else if filesItem?.isCollapsed == false, contains(filesPane, point) {
            regionPressed(.files)
        } else if terminalItem?.isCollapsed == false, contains(terminalPane, point) {
            regionPressed(.terminal)
        }
    }

    /// Pressing in a region is what makes it the keyboard's region, so Tab cycles from where the
    /// hand actually is. Only the region moves — the press keeps whatever it was going to do, and
    /// nothing is made first responder that the click did not already choose.
    private func regionPressed(_ pane: Pane) {
        guard focused != pane else { return }
        focused = pane
        if pane != .transcript { transcript.composer.dismissCompletion() }
    }

    private func contains(_ controller: NSViewController, _ windowPoint: NSPoint) -> Bool {
        guard controller.isViewLoaded, controller.view.window != nil,
            !controller.view.isHiddenOrHasHiddenAncestor
        else { return false }
        let local = controller.view.convert(windowPoint, from: nil)
        return NSMouseInRect(local, controller.view.bounds, controller.view.isFlipped)
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        if let verdict = composerKey(event) { return verdict ? nil : event }
        guard let chord = MacKeys.chord(for: event) else { return event }
        let context = keyContext()
        if context == .normal, focused == .transcript, pendingChords.isEmpty,
            transcript.handleChooserChord(chord)
        {
            return nil
        }
        if focused == .transcript, pendingChords.isEmpty,
            context == .normal || transcript.isChoosingStream,
            transcript.handleVideoChord(chord)
        {
            return nil
        }
        if focused == .transcript, pendingChords.isEmpty, transcript.handleWebChord(chord) {
            return nil
        }
        let awaiting =
            context == .normal
            && !(transcript.currentState?.pendingPermissions.isEmpty ?? true)
        switch shortcuts.resolve(
            chord, context: context, pending: pendingChords, awaitingApproval: awaiting)
        {
        case .run(let action):
            pendingChords = []
            return perform(action) ? nil : event
        case .pending(let chords):
            pendingChords = chords
            return nil
        case .unbound:
            pendingChords = []
            return event
        }
    }

    /// The prompt box's own key handling, decided here rather than in the text view so the same
    /// keystroke means the same thing whether a person typed it or a binding sent it — exactly
    /// Linux `handleComposerKey`: completion keys first while the popover shows, then vim, then
    /// Return-to-send. `nil` means "not the composer's business" and the keystroke falls through
    /// to the shared registry; `false` hands it to the text view for ordinary typing.
    private func composerKey(_ event: NSEvent) -> Bool? {
        guard let pane = splitPanes.orderedPanes.first(where: { $0.composer.editorHasFocus })
        else { return nil }
        splitPanes.focus(pane, grabKeyboard: false)
        focused = .transcript
        let composer = pane.composer
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if event.modifierFlags.contains(.command) {
            if isReturn {
                composer.sendNow()
                return true
            }
            return nil
        }
        let control = event.modifierFlags.contains(.control)
        let shift = event.modifierFlags.contains(.shift)
        let letter = event.charactersIgnoringModifiers

        if composer.completionVisible {
            switch event.keyCode {
            case 48:
                if shift { composer.moveCompletion(by: -1) } else { composer.acceptCompletion() }
                return true
            case 125:
                composer.moveCompletion(by: 1)
                return true
            case 126:
                composer.moveCompletion(by: -1)
                return true
            case 53:
                composer.dismissCompletion()
                return true
            default:
                if control, letter == "n" {
                    composer.moveCompletion(by: 1)
                    return true
                }
                if control, letter == "p" {
                    composer.moveCompletion(by: -1)
                    return true
                }
            }
        }

        if composer.vimEnabled {
            let key = vimKey(for: event)
            if composer.vimMode == .insert, key.isEscape || (control && letter == "[") {
                composer.applyVim(VimKey(isEscape: true))
                return true
            }
            if composer.vimMode != .insert {
                return composerNormalKey(key, event: event, pane: pane)
            }
        }

        if isReturn, !shift, ComposerView.sendOnReturn || control {
            composer.sendNow()
            return true
        }
        if isReturn, shift || !ComposerView.sendOnReturn { return false }
        return nil
    }

    /// The composer's normal mode is the app's normal mode: every key answers to the shortcut
    /// table first — j scrolls, J switches chats, ? opens the cheatsheet — while vim keeps what
    /// makes it vim: the visual modes, insert and visual entries, Enter to send, and every key of
    /// a command already in flight, so `3x`, `diw` and `ct)` still land. A chord sequence in
    /// flight outranks both, so `ctrl+w v` splits rather than entering visual mode. A key neither
    /// side binds goes back to vim rather than to the text view, so no stray letter types itself
    /// into the draft.
    private func composerNormalKey(
        _ key: VimKey, event: NSEvent, pane: TranscriptViewController
    ) -> Bool? {
        let composer = pane.composer
        if key.control, event.charactersIgnoringModifiers == "c",
            composer.copySelectionToPasteboard()
        {
            toast(Localized.text("Copied"))
            return true
        }
        guard let chord = MacKeys.chord(for: event) else { return nil }
        let awaiting = !(pane.currentState?.pendingPermissions.isEmpty ?? true)
        if awaiting, !chord.control, !chord.alt, pendingChords.isEmpty,
            let action = shortcuts.approval[chord.token]
        {
            pendingChords = []
            return perform(action)
        }
        if key.isEnter, chord.control {
            pendingChords = []
            composer.sendNow()
            return true
        }
        let plain = !chord.control && !chord.alt
        if composer.vimClaims(key, plain: plain, chordPending: !pendingChords.isEmpty) {
            pendingChords = []
            composer.applyVim(key)
            return true
        }
        switch shortcuts.resolve(
            chord, context: .normal, pending: pendingChords, awaitingApproval: false)
        {
        case .run(let action):
            pendingChords = []
            _ = perform(action)
            return true
        case .pending(let chords):
            pendingChords = chords
            return true
        case .unbound:
            pendingChords = []
            composer.applyVim(key)
            return true
        }
    }

    private func vimKey(for event: NSEvent) -> VimKey {
        var character: Character?
        if let raw = event.charactersIgnoringModifiers?.first,
            let scalar = raw.unicodeScalars.first?.value, scalar >= 0x20,
            !(0xF700...0xF8FF).contains(scalar)
        {
            character = raw
        }
        return VimKey(
            character: character,
            isEscape: event.keyCode == 53,
            isEnter: event.keyCode == 36 || event.keyCode == 76,
            isBackspace: event.keyCode == 51,
            control: event.modifierFlags.contains(.control))
    }

    /// Anything that takes text — the composer, the filter field's editor, a rename sheet — is
    /// insert; the rest of the window is normal. The terminal is stricter than both: a shell's
    /// own Ctrl+B or Ctrl+E is not the app's to take, so while its field or output holds focus
    /// only Ctrl+Shift moves and zoom resolve, exactly like Linux.
    private func keyContext() -> KeyContext {
        if terminalPane.ownsFocus(in: window) { return .terminal }
        guard let responder = window?.firstResponder else { return .normal }
        return responder is NSText ? .insert : .normal
    }

    @discardableResult
    private func focus(_ pane: Pane) -> Bool {
        if pane != .transcript { transcript.composer.dismissCompletion() }
        switch pane {
        case .chats:
            focused = .chats
            sidebar.takeFocus()
        case .transcript:
            focused = .transcript
            window?.makeFirstResponder(nil)
        case .files:
            guard filesItem?.isCollapsed == false else { return false }
            focused = .files
            filesPane.takeFocus()
        case .terminal:
            guard terminalItem?.isCollapsed == false else { return false }
            focused = .terminal
            terminalPane.takeFocus()
        }
        return true
    }

    /// Where the keyboard actually is, first responder as ground truth: the composer counts as
    /// its own stop so Tab from the transcript lands in the prompt box before moving on.
    private enum CycleStop {
        case chats
        case transcript
        case composer
        case files
        case terminal
    }

    private func currentStop() -> CycleStop {
        if terminalPane.ownsFocus(in: window) { return .terminal }
        if filesPane.ownsFocus(in: window) { return .files }
        if transcript.composer.editorHasFocus { return .composer }
        return focused == .chats ? .chats : .transcript
    }

    /// Linux `nextPane`, with the Mac's extra stop: chats → transcript → composer → files →
    /// terminal, wrapping, and a hidden pane is simply not on the route.
    private func cycle(_ delta: Int) {
        var stops: [CycleStop] = []
        if sidebarItem?.isCollapsed == false { stops.append(.chats) }
        stops.append(.transcript)
        stops.append(.composer)
        if filesItem?.isCollapsed == false { stops.append(.files) }
        if terminalItem?.isCollapsed == false { stops.append(.terminal) }
        let index = (stops.firstIndex(of: currentStop()) ?? 0) + delta
        let count = stops.count
        switch stops[((index % count) + count) % count] {
        case .chats:
            focus(.chats)
        case .transcript:
            focus(.transcript)
        case .composer:
            focused = .transcript
            transcript.focusComposer()
        case .files:
            focus(.files)
        case .terminal:
            focus(.terminal)
        }
    }

    /// Every pane closes, and the choice survives relaunch under the same `tailscode.pane.*`
    /// keys the other desktops use — a window someone shaped once should open shaped that way.
    private enum ClosablePane: String {
        case sidebar
        case files
        case terminal

        var key: String { "tailscode.pane.\(rawValue)" }
        var defaultShown: Bool { self == .sidebar }
    }

    private func paneShown(_ pane: ClosablePane) -> Bool {
        UserDefaults.standard.object(forKey: pane.key) as? Bool ?? pane.defaultShown
    }

    private func togglePane(_ pane: ClosablePane) {
        let shown = !paneShown(pane)
        UserDefaults.standard.set(shown, forKey: pane.key)
        let item: NSSplitViewItem?
        switch pane {
        case .sidebar: item = sidebarItem
        case .files: item = filesItem
        case .terminal: item = terminalItem
        }
        guard let item else { return }
        NSAnimationContext.runAnimationGroup(
            { _ in item.animator().isCollapsed = !shown },
            completionHandler: { [weak self] in
                guard let self, shown else { return }
                self.applyStoredDividers()
                if pane == .terminal { self.focus(.terminal) }
            })
    }

    /// The dividers survive relaunch under the same `tailscode.divider.*` keys the Linux desktop
    /// uses — sidebar and project on the outer split, terminal on the content column's own — and
    /// a pane toggled back open is re-asserted to the position it was shaped to, because
    /// NSSplitView's own resizing would otherwise re-deal the space.
    private enum DividerKey: String {
        case sidebar
        case project
        case terminal

        var key: String { "tailscode.divider.\(rawValue)" }
    }

    private func storedDivider(_ divider: DividerKey) -> CGFloat? {
        let value = UserDefaults.standard.double(forKey: divider.key)
        return value > 0 ? CGFloat(value) : nil
    }

    private func applyStoredDividers() {
        if paneShown(.sidebar), let position = storedDivider(.sidebar) {
            split.splitView.setPosition(position, ofDividerAt: 0)
        }
        if paneShown(.files), let position = storedDivider(.project) {
            split.splitView.setPosition(position, ofDividerAt: 1)
        }
        if paneShown(.terminal), let position = storedDivider(.terminal) {
            contentSplit.splitView.setPosition(position, ofDividerAt: 0)
        }
    }

    private func observeDividers() {
        NotificationCenter.default.addObserver(
            self, selector: #selector(dividersMoved),
            name: NSSplitView.didResizeSubviewsNotification, object: split.splitView)
        NotificationCenter.default.addObserver(
            self, selector: #selector(dividersMoved),
            name: NSSplitView.didResizeSubviewsNotification, object: contentSplit.splitView)
    }

    /// Positions are read back whenever the split settles rather than watched per-drag, and only
    /// sane ones are kept: a pane mid-collapse or mid-reveal passes through widths that are
    /// nobody's intent, so anything under the pane's own minimum is ignored.
    @objc private func dividersMoved() {
        guard dividerSavingEnabled else { return }
        let defaults = UserDefaults.standard
        if let sidebarItem, !sidebarItem.isCollapsed {
            let width = sidebarItem.viewController.view.frame.width
            if width >= sidebarItem.minimumThickness {
                defaults.set(Double(width), forKey: DividerKey.sidebar.key)
            }
        }
        if let filesItem, !filesItem.isCollapsed {
            let width = filesItem.viewController.view.frame.width
            if width >= filesItem.minimumThickness {
                let position = split.splitView.bounds.width - width
                    - split.splitView.dividerThickness
                defaults.set(Double(position), forKey: DividerKey.project.key)
            }
        }
        if let terminalItem, !terminalItem.isCollapsed {
            let height = terminalItem.viewController.view.frame.height
            if height >= terminalItem.minimumThickness {
                let position = contentSplit.splitView.bounds.height - height
                    - contentSplit.splitView.dividerThickness
                defaults.set(Double(position), forKey: DividerKey.terminal.key)
            }
        }
    }

    private func toggleCheatsheet() {
        if let cheatsheet, cheatsheet.isVisible {
            cheatsheet.close()
            return
        }
        presentCheatsheet()
    }

    private func closeCheatsheet() {
        guard let cheatsheet, cheatsheet.isVisible else { return }
        cheatsheet.close()
    }

    /// The cheatsheet is generated from the registry, so it always tells the truth — overrides
    /// included. Two columns, because forty rows in one column is a scroll, not a glance.
    /// The chord summons one field and nothing else; the words land in the focused pane as a new
    /// conversation with no project directory. With no servers the chord goes to setup instead
    /// of presenting a dead field.
    /// A question that arrived from another app. The window comes forward first because the field
    /// is inside it: a panel that opened behind whatever was frontmost would take the keystrokes
    /// meant for the question with it.
    func summonQuickAsk() {
        window?.makeKeyAndOrderFront(nil)
        presentQuickAsk()
    }

    private func presentQuickAsk() {
        let profiles = ServerDirectory.shared.profiles
        guard !profiles.isEmpty else {
            presentServers()
            return
        }
        QuickAskPanel.present(
            over: window, servers: profiles, preferredServer: currentEntry?.profileID,
            recents: sidebar.entries,
            onAsk: { [weak self] profileID, text, attachments, done in
                guard let self,
                    let profile = ServerDirectory.shared.profiles.first(where: {
                        $0.id == profileID
                    })
                else {
                    done(NewChatDiagnosis.noSuchServer())
                    return
                }
                self.mintQuickAsk(
                    on: profile, text: text, attachments: attachments, done: done)
            },
            onResume: { [weak self] entry in self?.sidebar.open(entry) })
    }

    /// The quick-ask mint queues the words — keyed to the minted session — and opens the chat in
    /// one main-actor turn, so nothing a hand does mid-flight can slip between the queue and the
    /// open, and no other conversation can ever inherit the question. A failed mint queues
    /// nothing and answers the panel with its reason.
    private func mintQuickAsk(
        on profile: ConnectionProfile, text: String, attachments: [PendingAttachment],
        done: @escaping @MainActor (NewChatFailure?) -> Void
    ) {
        guard let backend = ServerDirectory.shared.backend(for: profile) else {
            done(NewChatDiagnosis.noCredentials(server: Self.newChatServer(profile)))
            return
        }
        let server = Self.newChatServer(profile)
        let password = ServerDirectory.shared.password(for: profile)
        Task { [weak self] in
            let minted = await NewChatAttempt.mint(
                using: backend, server: server, baseURL: profile.baseURL, password: password,
                directory: nil)
            guard case .success(let session) = minted else {
                done(minted.failureValue)
                return
            }
            guard let self else {
                done(nil)
                return
            }
            QuickAskDefaults.stamp(profileID: profile.id, sessionID: session.id)
            let entry = SessionEntry(
                profileID: profile.id, profileName: profile.name,
                host: profile.baseURL.host ?? profile.name,
                backendType: profile.backend, session: session)
            self.transcript.queueFirstMessage(
                text, attachments: attachments, forSession: entry.session.id)
            self.sidebar.noteCreated(entry)
            /// The panel is answered — which is what closes it — only once the conversation is
            /// on screen behind it, and the keyboard is moved after the close rather than
            /// before: a field focused under a panel that is still key loses the focus again
            /// the moment that panel goes.
            done(nil)
            self.transcript.focusComposer()
            await self.sidebar.refresh()
        }
    }

    private func presentCheatsheet() {
        let panel = CheatsheetPanel(
            contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = Localized.text("Keyboard shortcuts")
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.contentView = makeCheatsheetContent()
        panel.setContentSize(panel.contentView?.fittingSize ?? NSSize(width: 640, height: 480))
        if let frame = window?.frame {
            let size = panel.frame.size
            panel.setFrameOrigin(
                NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2))
        }
        panel.makeKeyAndOrderFront(nil)
        cheatsheet = panel
    }

    private func makeCheatsheetContent() -> NSView {
        let sections = shortcuts.helpSections()
        let left = cheatsheetColumn()
        let right = cheatsheetColumn()
        let total = sections.reduce(0) { $0 + $1.rows.count + 2 }
        var used = 0
        for section in sections {
            let target = used < (total + 1) / 2 ? left : right
            used += section.rows.count + 2
            let header = NSTextField(labelWithString: section.title)
            header.font = MacTheme.Ramp.font(.sectionLabel)
            header.textColor = MacTheme.Color.secondaryLabel
            target.addArrangedSubview(header)
            target.setCustomSpacing(6, after: header)
            for row in section.rows {
                let keys = NSTextField(labelWithString: row.keys)
                keys.font = MacTheme.Ramp.font(.toolOutput)
                keys.lineBreakMode = .byTruncatingTail
                keys.widthAnchor.constraint(equalToConstant: 160).isActive = true
                let what = NSTextField(labelWithString: row.what)
                what.font = MacTheme.Ramp.font(.panelFootnote)
                what.textColor = MacTheme.Color.secondaryLabel
                let line = NSStackView(views: [keys, what])
                line.orientation = .horizontal
                line.spacing = 12
                line.alignment = .firstBaseline
                target.addArrangedSubview(line)
            }
            if let last = target.arrangedSubviews.last {
                target.setCustomSpacing(14, after: last)
            }
        }
        let columns = NSStackView(views: [left, right])
        columns.orientation = .horizontal
        columns.alignment = .top
        columns.spacing = 44
        let footer = NSTextField(
            labelWithString: Localized.text(
                "Rebind any of these: %@", ShortcutSet.configURL.path))
        footer.font = MacTheme.Ramp.font(.panelFootnote)
        footer.textColor = MacTheme.Color.tertiaryLabel
        let content = NSStackView(views: [columns, footer])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        content.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        return content
    }

    private func cheatsheetColumn() -> NSStackView {
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 3
        return column
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        toast(Localized.text("Copied"))
    }
}

extension MainWindowController: NSToolbarDelegate {
    private enum ToolbarID {
        static let sidebar = NSToolbarItem.Identifier("tailscode.toolbar.sidebar")
        static let newChat = NSToolbarItem.Identifier("tailscode.toolbar.newchat")
        static let actions = NSToolbarItem.Identifier("tailscode.toolbar.actions")
        static let files = NSToolbarItem.Identifier("tailscode.toolbar.files")
        static let terminal = NSToolbarItem.Identifier("tailscode.toolbar.terminal")
        static let usage = NSToolbarItem.Identifier("tailscode.toolbar.usage")
        static let servers = NSToolbarItem.Identifier("tailscode.toolbar.servers")
        static let settings = NSToolbarItem.Identifier("tailscode.toolbar.settings")
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            ToolbarID.sidebar, ToolbarID.newChat, .sidebarTrackingSeparator, .flexibleSpace,
            ToolbarID.actions, ToolbarID.files, ToolbarID.terminal, ToolbarID.usage,
            ToolbarID.servers, ToolbarID.settings,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space]
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case ToolbarID.sidebar:
            return makeToolbarItem(
                itemIdentifier, symbol: "sidebar.leading", label: Localized.text("Chats"),
                tip: Localized.text("Show or hide the chat list"),
                action: #selector(toolbarToggleSidebar))
        case ToolbarID.actions:
            let item = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
            item.image = NSImage(
                systemSymbolName: "ellipsis.circle",
                accessibilityDescription: Localized.text("Conversation actions"))
            item.label = Localized.text("Actions")
            item.paletteLabel = Localized.text("Actions")
            item.toolTip = Localized.text("Everything this conversation can do")
            item.isBordered = true
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            return item
        case ToolbarID.files:
            return makeToolbarItem(
                itemIdentifier, symbol: "sidebar.trailing", label: Localized.text("Files"),
                tip: Localized.text("Show or hide the files pane"),
                action: #selector(toolbarToggleFiles))
        case ToolbarID.terminal:
            return makeToolbarItem(
                itemIdentifier, symbol: "terminal", label: Localized.text("Terminal"),
                tip: Localized.text("Show or hide the terminal pane"),
                action: #selector(toolbarToggleTerminal))
        case ToolbarID.usage:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = Localized.text("Usage")
            item.paletteLabel = Localized.text("Usage")
            item.toolTip = Localized.text("Every provider's quota picture")
            let button = NSButton(
                image: NSImage(
                    systemSymbolName: "gauge",
                    accessibilityDescription: Localized.text("Usage"))!,
                target: self, action: #selector(toolbarUsage(_:)))
            button.bezelStyle = .toolbar
            item.view = button
            return item
        case ToolbarID.newChat:
            return makeToolbarItem(
                itemIdentifier, symbol: "square.and.pencil", label: Localized.text("New Chat"),
                tip: Localized.text("Start a conversation on one of your servers"),
                action: #selector(toolbarNewChat))
        case ToolbarID.servers:
            return makeToolbarItem(
                itemIdentifier, symbol: "server.rack", label: Localized.text("Servers"),
                tip: Localized.text("Add, probe, update or remove a server"),
                action: #selector(toolbarServers))
        case ToolbarID.settings:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = Localized.text("Settings")
            item.paletteLabel = Localized.text("Settings")
            let button = UpdateMarkButton(
                symbol: "gearshape", label: Localized.text("Settings"),
                tip: Localized.text("The prompt box, the transcript and the keyboard"),
                target: self, action: #selector(toolbarSettings))
            button.render()
            item.view = button
            updateMark = button
            return item
        default:
            return nil
        }
    }

    private func makeToolbarItem(
        _ identifier: NSToolbarItem.Identifier, symbol: String, label: String, tip: String,
        action: Selector
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.label = label
        item.paletteLabel = label
        item.toolTip = tip
        item.isBordered = true
        item.target = self
        item.action = action
        return item
    }

    @objc private func toolbarToggleSidebar() {
        perform(.toggleSidebar)
    }

    @objc private func toolbarToggleFiles() {
        perform(.toggleFiles)
    }

    @objc private func toolbarToggleTerminal() {
        perform(.toggleTerminal)
    }

    @objc private func toolbarUsage(_ sender: NSButton) {
        presentUsagePopover(from: sender)
    }

    @objc private func toolbarNewChat() {
        presentNewChat()
    }

    @objc private func toolbarServers() {
        presentServers()
    }

    @objc private func toolbarSettings() {
        presentPreferences()
    }
}

extension MainWindowController: NSToolbarItemValidation {
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool { true }
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

/// Esc dismisses, matching the key that opened it: the cheatsheet is a glance, not a window to
/// manage.
private final class CheatsheetPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { close() } else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) {
        close()
    }
}
