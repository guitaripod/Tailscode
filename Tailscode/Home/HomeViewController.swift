import TailscodeCore
import CodingAgentKit
import CodingAgentKitApple
import UIKit

/// The app's front door, organized around three jobs: triage (what needs you
/// right now — blocked or live agents, unreachable servers), continue (recent
/// conversations, badged when they changed since you last looked), and start
/// (the docked composer, the quick-ask sheet, and project cards that open
/// each project's own board).
@MainActor
final class HomeViewController: UIViewController {
    var onOpenSettings: (() -> Void)?

    private let viewModel: SessionListViewModel
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<HomeSection, HomeItem>!
    private let refreshControl = UIRefreshControl()
    private let composerBar = HomeComposerBar()
    private let settingsButton = UpdateMarkButton()
    private lazy var settingsItem = UIBarButtonItem(customView: settingsButton)
    private let orbView = PresenceOrbView()
    private var orbTarget: SessionEntry?
    private var quotas: [UsageQuota] = []
    private var savedChats: [SavedChat] = SavedChatStore.all()
    private var opencodeQuota: UsageQuota?
    private var hasAppeared = false
    private var hasLoadedOnce = false
    private var wantsComposerFocus = false
    private var pendingDeepLink: (sessionID: String, parkedAt: Date)?
    private var modelChoices: [String: ModelChoice] = [:]
    private var resolvingModels: Set<String> = []
    private var appliedComposerState: String?
    private var appliedComposeButtonState: String?
    private var composerDraftScope: DraftScope?
    private var resolvedComposeTarget: (profileID: String, directory: String?)?
    private var scheduledSnapshot = false
    private var deferredSnapshot = false
    /// What each card was last drawn from. A diffable identity says which card a row *is*, never
    /// whether anything on it moved, so reconfiguring everything that survived a diff redrew the
    /// whole board on a tick that changed one word.
    private var appliedContent: [HomeItem: Int] = [:]

    init() {
        let sources = ConnectionController.shared.allBackends().map {
            SessionListViewModel.Source(profile: $0.profile, backend: $0.backend)
        }
        self.viewModel = SessionListViewModel(sources: sources)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Tailscode"
        navigationItem.largeTitleDisplayMode = .always
        view.backgroundColor = Theme.Color.groupedBackground
        settingsButton.addTarget(self, action: #selector(openSettings), for: .touchUpInside)
        updateLeftBarItems()
        updateComposeButton()
        configureCollectionView()
        configureDataSource()
        configureComposer()
        bind()
        seedCachedQuotas()
        applySnapshot()
        updateComposer()
        Task { await load() }
        #if DEBUG
            if ProcessInfo.processInfo.environment["TAILSCODE_OPEN_CHATS"] != nil {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    self?.pushChats()
                }
            }
            if let session = ProcessInfo.processInfo.environment["TAILSCODE_OPEN_SESSION"] {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    guard let self else { return }
                    let id =
                        session == "first"
                        ? self.viewModel.entries.first?.session.id : session
                    if let id { self.openSession(withID: id) }
                }
            }
            if let mode = ProcessInfo.processInfo.environment["TAILSCODE_OPEN_SAVED"] {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(4))
                    self?.seedSavedForVerification(mode)
                    self?.pushSaved()
                }
            }
            if ProcessInfo.processInfo.environment["TAILSCODE_OPEN_ASK"] != nil {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    self?.presentQuickAsk()
                }
            }
            if ProcessInfo.processInfo.environment["TAILSCODE_OPEN_SETTINGS"] != nil {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    self?.onOpenSettings?()
                }
            }
            if let text = ProcessInfo.processInfo.environment["TAILSCODE_COMPOSE_SEND"] {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    self?.composerSend(text)
                }
            }
            if let directory = ProcessInfo.processInfo.environment["TAILSCODE_NEW_CHAT"] {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(4))
                    self?.startChatForVerification(in: directory)
                }
            }
            if ProcessInfo.processInfo.environment["TAILSCODE_FOCUS_COMPOSER"] != nil {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    self?.focusComposer()
                }
            }
        #endif
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if deferredSnapshot { renderSnapshot() }
        if hasAppeared { Task { await load() } }
        hasAppeared = true
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startLiveRefresh()
        if wantsComposerFocus {
            wantsComposerFocus = false
            composerBar.focus()
        } else {
            becomeFirstResponder()
        }
    }

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        guard keyContext == .insert else { return nil }
        return KeyBridge.shared.insertKeyCommands(action: #selector(handleInsertKeyCommand(_:)))
    }

    @objc private func handleInsertKeyCommand(_ command: UIKeyCommand) {
        guard let token = command.propertyList as? String,
            let chord = KeyBridge.chord(forToken: token)
        else { return }
        _ = KeyBridge.shared.handle(chord, context: .insert, awaitingApproval: false) {
            [weak self] action in
            self?.performKeyAction(action) ?? false
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if keyContext == .normal, handleKeyPresses(presses) { return }
        super.pressesBegan(presses, with: event)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        stopLiveRefresh()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let overlap = max(
            0, view.bounds.height - composerBar.frame.minY - view.safeAreaInsets.bottom)
        let inset = composerBar.isHidden ? 0 : overlap + Theme.Spacing.s
        if collectionView.contentInset.bottom != inset {
            collectionView.contentInset.bottom = inset
            collectionView.verticalScrollIndicatorInsets.bottom = inset
        }
    }

    func focusComposer() {
        guard viewIfLoaded?.window != nil else {
            wantsComposerFocus = true
            return
        }
        composerBar.focus()
    }

    #if DEBUG
        var tourScrollView: UIScrollView { collectionView }

        func tourFocusComposer() { composerBar.focus() }

        func tourType(_ text: String, perCharacter: Double) async {
            for index in text.indices {
                composerBar.tourSetText(String(text[text.startIndex...index]))
                try? await Task.sleep(for: .seconds(perCharacter))
            }
        }

        func tourSendComposer() { composerSend(composerBar.tourText) }

        func tourPushChats() { pushChats() }

        func tourPushSaved(seeding mode: String? = nil) {
            if let mode { seedSavedForVerification(mode) }
            pushSaved()
        }

        func tourOpenSettings() { onOpenSettings?() }

        func tourPop() { navigationController?.popViewController(animated: true) }

        /// Puts the board into its first-frame state for a take: no bookmarks carried
        /// over from an earlier run, and recent work that moved while you were away.
        func tourResetBoard(seenAge: TimeInterval) {
            for chat in SavedChatStore.all() {
                SavedChatStore.remove(profileID: chat.profileID, sessionID: chat.sessionID)
            }
            SessionSeenStore.tourRewindBaseline(seenAge)
            savedChats = SavedChatStore.all()
            applySnapshot()
        }

        var tourProjectsRail: UIScrollView? {
            collectionView.visibleCells.first { $0 is ProjectCell }?.superview as? UIScrollView
        }

        func tourAim(serverIndex: Int, directory: String?) {
            guard viewModel.servers.indices.contains(serverIndex) else { return }
            setComposeTarget(profile: viewModel.servers[serverIndex], directory: directory)
        }
    #endif

    private func bind() {
        viewModel.onChange = { [weak self] in
            self?.updateComposeButton()
            self?.updateComposer()
            self?.applySnapshot()
        }
        viewModel.onError = { [weak self] message in
            self?.refreshControl.endRefreshing()
            AppLogger.session.error("home load: \(message)")
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(activityDidChange),
            name: SessionActivity.didChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(savedDidChange),
            name: SavedChatStore.didChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(activityDidChange),
            name: ActivityInbox.didChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(archiveDidChange),
            name: ArchivedChatStore.didChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(sceneDidActivate),
            name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(sceneWillResign),
            name: UIApplication.willResignActiveNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(connectionsDidChange),
            name: ConnectionController.didChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(updatesDidChange),
            name: UpdateLedger.didChange, object: nil)
        for name: Notification.Name in [
            UIApplication.didEnterBackgroundNotification,
            UIApplication.willTerminateNotification,
        ] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(flushState), name: name, object: nil)
        }
    }

    @objc private func activityDidChange() { applySnapshot() }

    @objc private func archiveDidChange() { applySnapshot() }

    /// Settings edited the servers. Rebuilding the backends here — rather than
    /// recreating the whole screen — keeps scroll position, the composer draft,
    /// and any in-flight chat intact through something as small as a rename.
    @objc private func connectionsDidChange() {
        viewModel.refreshSources()
        resolvedComposeTarget = nil
        updateLeftBarItems()
        updateComposeButton()
        updateComposer()
        applySnapshot()
        Task { await load(.user) }
    }

    @objc private func sceneDidActivate() {
        Task { await load(.user) }
        startLiveRefresh()
    }

    @objc private func sceneWillResign() {
        stopLiveRefresh()
        flushState()
    }

    /// Everything this screen writes on a trailing edge, taken now — the debounce window is not
    /// something a process about to be suspended can wait out.
    @objc private func flushState() {
        DraftStore.flush()
        SessionListCache.flushPendingSave()
    }

    @objc private func openSettings() {
        view.endEditing(true)
        onOpenSettings?()
    }
    @objc private func refresh() { Task { await load(.user) } }

    @objc private func savedDidChange() {
        savedChats = SavedChatStore.all()
        applySnapshot()
    }

    /// Everything the left of the bar says about what this app is doing, decided in one place.
    ///
    /// The demo is a full, believable two-server world, which is exactly why it needs to say so on
    /// every screen — and why the way out of it belongs here rather than three taps deep in
    /// Settings. The standing update mark rides the same slot, on the gear itself. Two methods
    /// each rebuilding `leftBarButtonItems` from what they found there fought: whichever ran last
    /// won, and the other's item vanished.
    private func updateLeftBarItems() {
        settingsButton.apply(UpdateLedger.rollup())
        var items = [settingsItem]
        if ConnectionController.shared.isDemoMode { items.append(demoBadge()) }
        navigationItem.leftBarButtonItems = items
    }

    @objc private func updatesDidChange() {
        settingsButton.apply(UpdateLedger.rollup())
    }

    private func demoBadge() -> UIBarButtonItem {
        var config = UIButton.Configuration.tinted()
        config.title = String(localized: "DEMO")
        config.baseForegroundColor = Theme.Color.warning
        config.baseBackgroundColor = Theme.Color.warning
        config.cornerStyle = .capsule
        config.buttonSize = .mini
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            var out = $0
            out.font = Theme.Ramp.font(.metricLabel)
            return out
        }
        let button = UIButton(configuration: config)
        button.accessibilityLabel = String(localized: "Demo mode. Sample data, no real servers.")
        button.showsMenuAsPrimaryAction = true
        button.menu = UIMenu(children: [
            UIAction(
                title: String(localized: "Set up my machine"), image: UIImage(systemName: "server.rack")
            ) { [weak self] _ in self?.presentSetup() },
            UIAction(
                title: String(localized: "Leave the demo"), image: UIImage(systemName: "xmark"),
                attributes: .destructive
            ) { _ in
                Theme.Haptics.warning()
                ConnectionController.shared.leaveDemoMode()
            },
        ])
        return UIBarButtonItem(customView: button)
    }

    /// Opens the add-server flow from wherever the app is, so the Home screen
    /// quick action reaches the same screen as the demo-mode menu's own entry.
    func presentServerSetup() {
        presentSetup()
    }

    private func presentSetup() {
        Theme.Haptics.tap()
        let setup = ServerSetupViewController(mode: .addServer)
        let nav = UINavigationController(rootViewController: setup)
        nav.navigationBar.prefersLargeTitles = true
        setup.navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .close,
            primaryAction: UIAction { [weak nav] _ in nav?.dismiss(animated: true) })
        setup.onConnected = { [weak nav] in nav?.dismiss(animated: true) }
        present(nav, animated: true)
    }

    /// Compose aims the docked composer instead of creating a session: server,
    /// project, and model are all chosen there, and nothing exists on the server
    /// until a message is actually sent. One server aims straight at it; several
    /// offer the pick first.
    private func updateComposeButton() {
        let servers = viewModel.servers
        let state = servers.map { "\($0.id)|\($0.name)|\($0.backend.rawValue)" }
            .joined(separator: "\u{1}")
        guard state != appliedComposeButtonState else { return }
        appliedComposeButtonState = state
        let compose = UIImage(systemName: "square.and.pencil")
        let composeItem: UIBarButtonItem
        if servers.count > 1 {
            let actions = servers.map { profile in
                UIAction(
                    title: profile.name,
                    subtitle: profile.backend.displayName,
                    image: UIImage(systemName: profile.backend.symbolName)?
                        .withTintColor(profile.backend.brandColor, renderingMode: .alwaysOriginal)
                ) { [weak self] _ in self?.startChat(on: profile) }
            }
            composeItem = UIBarButtonItem(
                image: compose, menu: UIMenu(title: String(localized: "New chat on…"), children: actions))
        } else {
            composeItem = UIBarButtonItem(
                image: compose, primaryAction: UIAction { [weak self] _ in
                    guard let self, let profile = self.viewModel.servers.first else { return }
                    self.startChat(on: profile)
                })
        }
        composeItem.accessibilityLabel = String(localized: "New chat")
        let ask = UIBarButtonItem(
            image: UIImage(systemName: "sparkle"),
            primaryAction: UIAction { [weak self] _ in self?.presentQuickAsk() })
        ask.accessibilityLabel = String(localized: "Quick ask")
        navigationItem.rightBarButtonItems = [composeItem, ask]
    }

    private var lastOpencodeScan: Date?
    /// The caps the last scan was priced against; changing them in Settings
    /// invalidates the cooldown, or the card would keep the old percentages for
    /// up to five minutes.
    private var scannedCaps = GoCaps.signature
    private var lastEnrichment: Date?
    private var isEnriching = false
    private var loadTask: Task<Void, Never>?
    private var liveRefreshTask: Task<Void, Never>?

    /// The last numbers the app landed anywhere — background refresh, silent
    /// push, widget — shared on disk. Painting them first means the usage
    /// section carries real figures from the first frame instead of waiting on a
    /// live fetch and a multi-server scan that between them can take a minute.
    private func seedCachedQuotas() {
        let cached = UsageWidgetStore.cachedQuotas()
        guard !cached.isEmpty else { return }
        quotas = cached.filter { $0.providerName != UsageWidgetStore.opencodeProviderName }
        opencodeQuota = cached.first { $0.providerName == UsageWidgetStore.opencodeProviderName }
    }

    /// Home is a status board, so it keeps itself current while it is on screen:
    /// a chat started from a terminal, a turn that finishes, an agent that stops
    /// to ask something — all of it lands without a pull. Quick cadence while
    /// anything is live, slow when the board is quiet, and stopped outright when
    /// the screen is off or the app is inactive so nothing polls in the
    /// background.
    private func startLiveRefresh() {
        guard liveRefreshTask == nil, viewIfLoaded?.window != nil,
            UIApplication.shared.applicationState == .active
        else { return }
        liveRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let interval = self?.liveRefreshInterval else { return }
                try? await Task.sleep(for: .seconds(interval))
                guard !Task.isCancelled, let self, self.viewIfLoaded?.window != nil else { return }
                await self.load(.poll)
            }
        }
    }

    private func stopLiveRefresh() {
        liveRefreshTask?.cancel()
        liveRefreshTask = nil
    }

    /// Paced against what a listing actually costs: a bridge with hundreds of
    /// sessions spends seconds folding transcripts for one, so a tighter loop
    /// would keep every server permanently busy for a board the user only
    /// glances at. Turns this device drives repaint from their own stream in
    /// between, not from this.
    private var liveRefreshInterval: Double {
        viewModel.entries.contains(where: isLive) ? 10 : 30
    }
    /// True from launch so the usage section reserves its height on the first
    /// frame instead of shoving the list when the quotas land. Tracked per source
    /// because the opencode scan finishes long after the live fetch, and a card
    /// with no seat reserved is exactly the shove this avoids.
    private var isFetchingLiveQuotas = true
    private var isScanningOpencode = true

    /// Why the list is being refreshed, which decides how eagerly the expensive
    /// parts run: a load the user asked for re-runs the quota and scan work,
    /// while the background cadence rides on throttled enrichment. Reachability
    /// is not on this dial — a server is judged the same way whoever asked.
    private enum LoadReason {
        case user, appear, poll
    }

    /// The session fan-out alone decides when the pull-to-refresh spinner stops:
    /// quota and scan work is best-effort enrichment, and an unreachable server
    /// makes each of those calls sit on the 30s request timeout. Blocking the
    /// spinner behind them made a single dead tailnet peer look like a broken
    /// refresh for two minutes.
    /// `viewWillAppear`, scene activation, pull-to-refresh and post-action
    /// reloads can all fire within the same second; against an unreachable
    /// server every one of them parks on the request timeout, so they share a
    /// single in-flight load rather than queueing up behind each other.
    private func load(_ reason: LoadReason = .appear) async {
        if let inFlight = loadTask {
            await inFlight.value
            if reason == .user { startEnrichment(force: true) }
            refreshControl.endRefreshing()
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performLoad(reason)
        }
        loadTask = task
        await task.value
        if loadTask == task { loadTask = nil }
    }

    private func performLoad(_ reason: LoadReason) async {
        await viewModel.load()
        refreshControl.endRefreshing()
        hasLoadedOnce = true
        HomeQuickActions.refresh(entries: viewModel.entries)
        updateComposer()
        applySnapshot()
        await adoptDeliveredNotices()
        startEnrichment(force: reason == .user)
    }

    /// A notice the bridge pushed while the app was not running was never written down here, so
    /// the listing that just landed is the first moment its session can be placed on a server.
    private func adoptDeliveredNotices() async {
        let owners = Dictionary(
            viewModel.entries.map { ($0.session.id, $0.profileID) }, uniquingKeysWith: { first, _ in
                first
            })
        await NotificationManager.adoptDelivered { owners[$0] }
    }

    /// Deliberately not awaited by `performLoad`: quota and scan work is
    /// enrichment layered onto an already-painted list, so it must never hold
    /// the refresh spinner — nor a caller that coalesced onto this load, which
    /// is how pull-to-refresh ended up waiting on an unreachable server twice
    /// over.
    /// Unforced callers (returning to Home, the live-refresh cadence) are rate
    /// limited: quotas move on the scale of minutes, and re-running the whole
    /// fan-out every few seconds would burn a request per server per tick for
    /// numbers that cannot have changed.
    /// Never restarts work that is already running. Cancelling and relaunching
    /// looked harmless until launch itself did it — the initial load starts the
    /// scan, `didBecomeActive` lands a moment later and forced a restart, and the
    /// half-second-old opencode scan died with "failed on every host". It then
    /// stayed dead, because the scan had already stamped its 5-minute cooldown.
    private func startEnrichment(force: Bool) {
        guard !isEnriching else { return }
        if !force, let last = lastEnrichment, Date().timeIntervalSince(last) < 90 { return }
        lastEnrichment = Date()
        isEnriching = true
        isFetchingLiveQuotas = true
        isScanningOpencode = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.loadEnrichment()
            self.isEnriching = false
        }
    }

    private func loadEnrichment() async {
        async let quotas: Void = loadQuotas()
        async let scan: Void = scanOpencodeIfNeeded()
        _ = await (quotas, scan)
        isFetchingLiveQuotas = false
        isScanningOpencode = false
        applySnapshot()
    }

    /// The cooldown is stamped on success only: a scan that failed has told us
    /// nothing, so blocking the retry for five minutes just leaves the card
    /// missing for five minutes.
    private func scanOpencodeIfNeeded() async {
        defer { isScanningOpencode = false }
        if scannedCaps != GoCaps.signature { lastOpencodeScan = nil }
        if let last = lastOpencodeScan, Date().timeIntervalSince(last) < 300 { return }
        scannedCaps = GoCaps.signature
        let entries = ConnectionController.shared.opencodeBackends()
        guard !entries.isEmpty else { return }
        guard
            let result = await UsageScanner.scanOpencode(
                backends: entries.map { ($0.profile.name, $0.backend) })
        else { return }
        lastOpencodeScan = Date()
        opencodeQuota = UsageScanner.quota(from: result)
        applySnapshot()
    }

    /// A bridge answers for every provider its host machine is signed into,
    /// but not every bridge host has live quota data — take the first Claude
    /// profile whose bridge does.
    /// Delegates to the same deadline-bounded fetcher the widget and the
    /// background refresh use — it already queries every bridge concurrently,
    /// keeps the partial haul when the deadline fires, and resolves the
    /// first-bridge-wins-per-provider ordering. Home previously carried a
    /// third, unbounded copy of that logic. An empty result means nothing
    /// answered in time, which must not blank a good card.
    private func loadQuotas() async {
        let fetched = await LiveQuotaFetcher.fetch(deadline: 10)
        isFetchingLiveQuotas = false
        guard !fetched.isEmpty else { return }
        quotas = fetched
        UsageWidgetStore.writeLive(fetched)
        UsageWarnings.evaluate(quotas: fetched)
        applySnapshot()
    }

    private func isLive(_ entry: SessionEntry) -> Bool {
        entry.session.isWorking
            || SessionActivity.shared.status(for: entry.session.id) != .idle
    }

    /// A cached `isActive` from the cold-launch snapshot can describe an agent
    /// that died while the app was closed, so unconfirmed liveness renders as
    /// syncing rather than a confident LIVE.
    private func presence(for entry: SessionEntry) -> LiveCard.Presence {
        switch SessionActivity.shared.status(for: entry.session.id) {
        case .awaitingApproval: return .needsInput
        case .running: return .working
        case .idle: return hasLoadedOnce ? .working : .syncing
        }
    }

    /// Rebuilding the board is what everything that moves asks for, and almost none of them are
    /// asking for it now.
    ///
    /// A finished turn alone runs this three or four times in a row — the listing upsert, the
    /// activity change, the load's own pass — and the live cadence asks again every couple of
    /// seconds, from a screen that is very often behind a chat nobody would see it redraw. So a
    /// request is a request: it is dropped entirely while Home is off screen (`viewWillAppear`
    /// takes the deferred one), and otherwise coalesced to one pass per runloop turn, so a burst
    /// costs what one change costs. The deep link is the exception on the off-screen path — it is
    /// parked with a deadline and a notification tap must not wait behind a screen coming back.
    private func applySnapshot() {
        guard viewIfLoaded?.window != nil else {
            deferredSnapshot = true
            consumePendingDeepLink()
            return
        }
        guard !scheduledSnapshot else { return }
        scheduledSnapshot = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.scheduledSnapshot else { return }
            self.scheduledSnapshot = false
            self.renderSnapshot()
        }
    }

    private func renderSnapshot() {
        deferredSnapshot = false
        savedChats = SavedChatStore.all()
        var snapshot = NSDiffableDataSourceSnapshot<HomeSection, HomeItem>()
        if hasLoadedOnce {
            let down = viewModel.servers.filter { viewModel.unreachable.contains($0.id) }
            if !down.isEmpty {
                snapshot.appendSections([.alerts])
                snapshot.appendItems(
                    down.map { .alert(ServerAlertCard(profileID: $0.id, name: $0.name)) },
                    toSection: .alerts)
            }
        }
        let missed = ActivityInbox.ordered(limit: 4).shown
        if !missed.isEmpty {
            snapshot.appendSections([.missed])
            snapshot.appendItems(missed.map(HomeItem.missed), toSection: .missed)
        }
        let live = viewModel.entries.filter(isLive)
            .sorted { lhs, rhs in
                let lhsBlocked = presence(for: lhs) == .needsInput
                let rhsBlocked = presence(for: rhs) == .needsInput
                if lhsBlocked != rhsBlocked { return lhsBlocked }
                return lhs.session.updatedAt > rhs.session.updatedAt
            }
            .prefix(10)
        if !live.isEmpty {
            snapshot.appendSections([.live])
            snapshot.appendItems(
                live.map {
                    .live(
                        LiveCard(
                            entry: $0, presence: presence(for: $0),
                            activity: SessionActivity.shared.liveDetail(for: $0.session.id)))
                },
                toSection: .live)
        }
        let isUnread = SessionSeenStore.unreadEvaluator()
        let liveIDs = Set(live.map(\.session.id))
        let serverIDs = Set(viewModel.servers.map(\.id))
        let listed = Set(viewModel.entries.map { "\($0.profileID)\u{1}\($0.session.id)" })
        let savedCards = Array(
            savedChats.lazy
                .filter { self.isOpenable($0, servers: serverIDs, listed: listed) }
                .filter { !liveIDs.contains($0.sessionID) }
                .prefix(3)
                .map { SavedCard(chat: $0, unread: isUnread($0.sessionID, $0.updatedAt)) })
        if !savedCards.isEmpty {
            snapshot.appendSections([.saved])
            snapshot.appendItems(savedCards.map(HomeItem.saved), toSection: .saved)
        }
        let projects = projectCards()
        if !projects.isEmpty {
            snapshot.appendSections([.projects])
            snapshot.appendItems(projects.map(HomeItem.project), toSection: .projects)
        }
        let shown = liveIDs.union(savedCards.map(\.chat.sessionID))
        let archived = ArchivedChatStore.all()
        let recent = viewModel.entries.filter {
            !shown.contains($0.session.id)
                && !archived.contains(ArchivedChatStore.key($0.profileID, $0.session.id))
        }.prefix(6)
        if !recent.isEmpty {
            snapshot.appendSections([.recent])
            snapshot.appendItems(
                recent.map {
                    .recent(RecentCard(entry: $0, unread: isUnread($0.session.id, $0.session.updatedAt)))
                }, toSection: .recent)
        } else if !hasLoadedOnce, !viewModel.servers.isEmpty {
            snapshot.appendSections([.recent])
            snapshot.appendItems((0..<3).map(HomeItem.placeholder), toSection: .recent)
        }
        let usageCards = quotas.map { QuotaCard(quota: $0) }
            + (opencodeQuota.map { [QuotaCard(quota: $0)] } ?? [])
        let reserved = reservedUsageCards
        if !usageCards.isEmpty || reserved > 0 {
            snapshot.appendSections([.usage])
            snapshot.appendItems(usageCards.map(HomeItem.usage), toSection: .usage)
            snapshot.appendItems((0..<reserved).map(HomeItem.usagePlaceholder), toSection: .usage)
        }
        let previous = dataSource.snapshot()
        let existing = Set(previous.itemIdentifiers)
        var content: [HomeItem: Int] = [:]
        var stale: [HomeItem] = []
        for item in snapshot.itemIdentifiers {
            let signature = item.contentSignature
            content[item] = signature
            if existing.contains(item), appliedContent[item] != signature { stale.append(item) }
        }
        appliedContent = content
        if !stale.isEmpty { snapshot.reconfigureItems(stale) }
        dataSource.apply(snapshot, animatingDifferences: shouldAnimate(from: previous, to: snapshot))
        updateEmptyState(itemCount: snapshot.numberOfItems)
        applyOrbState()
        consumePendingDeepLink()
    }

    /// A missed notice is a place to go back to. The chat may have been deleted or its server
    /// removed since, in which case the notice is stale and goes rather than sitting there
    /// failing to open.
    private func openMissed(_ item: MissedActivity) {
        guard let entry = viewModel.entries.first(where: { $0.session.id == item.sessionID })
        else {
            NotificationManager.clearNotices(sessionID: item.sessionID)
            applySnapshot()
            return
        }
        openChat(for: entry)
    }

    /// Home lists a saved chat only while it is something you can actually open.
    /// A bookmark whose conversation was deleted, or whose server was
    /// disconnected, is a tidying-up job for the Saved screen, not a launch pad.
    private func isOpenable(_ chat: SavedChat, servers: Set<String>, listed: Set<String>) -> Bool {
        guard servers.contains(chat.profileID) else { return false }
        if listed.contains("\(chat.profileID)\u{1}\(chat.sessionID)") { return true }
        return !hasLoadedOnce || viewModel.unreachable.contains(chat.profileID)
    }

    /// Only structural changes animate, and only once something is on screen to
    /// animate from: a card arriving should slide the list open rather than snap
    /// it, but the per-second content churn of a running agent must not.
    ///
    /// A reorder is not a structural change to a reader — the same cards are there — so a poll that
    /// moves the most recent chat up settles rather than animating, and nothing animates at all
    /// under a finger: a batch update landing mid-scroll fights the scroll it lands on.
    private func shouldAnimate(
        from previous: NSDiffableDataSourceSnapshot<HomeSection, HomeItem>,
        to next: NSDiffableDataSourceSnapshot<HomeSection, HomeItem>
    ) -> Bool {
        guard view.window != nil, !previous.itemIdentifiers.isEmpty,
            !collectionView.isDragging, !collectionView.isDecelerating
        else { return false }
        return previous.sectionIdentifiers != next.sectionIdentifiers
            || Set(previous.itemIdentifiers) != Set(next.itemIdentifiers)
    }

    /// Skeletons to hold open for cards that are still out. One per source that
    /// can still answer, and only for sources this user actually has: someone
    /// without an opencode server must never see a slot for one. A bridge can
    /// answer for several providers at once (Claude and Grok), so the live fetch
    /// reserves a single seat and any extra card animates in beside it.
    private var reservedUsageCards: Int {
        let backends = Set(viewModel.servers.map(\.backend))
        let live = isFetchingLiveQuotas && quotas.isEmpty && backends.contains(.claudeCode)
        let scan = isScanningOpencode && opencodeQuota == nil && backends.contains(.openCode)
        return (live ? 1 : 0) + (scan ? 1 : 0)
    }

    private func projectCards() -> [ProjectCard] {
        struct Key: Hashable {
            let profileID: String
            let directory: String
        }
        var counts: [Key: Int] = [:]
        var latest: [Key: Date] = [:]
        var meta: [Key: (name: String, backend: AgentType)] = [:]
        for entry in viewModel.entries {
            guard let directory = entry.session.directory else { continue }
            let key = Key(profileID: entry.profileID, directory: directory)
            counts[key, default: 0] += 1
            if entry.session.updatedAt > (latest[key] ?? .distantPast) {
                latest[key] = entry.session.updatedAt
            }
            meta[key] = (entry.profileName, entry.backendType)
        }
        return latest.sorted { $0.value > $1.value }.prefix(6).compactMap { key, _ in
            guard let info = meta[key], let count = counts[key] else { return nil }
            return ProjectCard(
                profileID: key.profileID, profileName: info.name, backend: info.backend,
                directory: key.directory, chatCount: count)
        }
    }

    private func updateEmptyState(itemCount: Int) {
        collectionView.backgroundView = nil
        if itemCount > 0 {
            contentUnavailableConfiguration = nil
        } else if viewModel.isEmptyOfServers {
            var config = UIContentUnavailableConfiguration.empty()
            config.image = UIImage(systemName: "server.rack")
            config.text = String(localized: "No servers connected")
            config.secondaryText = String(
                localized: "Add a connection in Settings to start chatting with your agents.")
            contentUnavailableConfiguration = config
        } else if !hasLoadedOnce {
            contentUnavailableConfiguration = UIContentUnavailableConfiguration.loading()
        } else {
            contentUnavailableConfiguration = nil
            collectionView.backgroundView = Self.emptyHintView()
        }
    }

    /// A plain background hint rather than `contentUnavailableConfiguration`,
    /// which would overlay (and block) the docked composer it points at.
    private static func emptyHintView() -> UIView {
        let icon = UIImageView(
            image: UIImage(
                systemName: "bubble.left.and.bubble.right",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 34, weight: .regular)))
        icon.tintColor = Theme.Color.tertiaryLabel
        icon.contentMode = .scaleAspectFit

        let title = UILabel()
        title.text = String(localized: "No conversations yet")
        title.font = Theme.Ramp.font(.cardTitle)
        title.textColor = Theme.Color.secondaryLabel
        title.textAlignment = .center

        let subtitle = UILabel()
        subtitle.text = String(localized: "Start one below.")
        subtitle.font = Theme.Ramp.font(.panelLabel)
        subtitle.textColor = Theme.Color.tertiaryLabel
        subtitle.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [icon, title, subtitle])
        stack.axis = .vertical
        stack.spacing = Theme.Spacing.s
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = UIView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: -40),
        ])
        return container
    }

    func openSession(withID id: String) {
        if let top = navigationController?.topViewController as? ChatViewController,
            top.sessionID == id
        {
            return
        }
        guard let entry = viewModel.entries.first(where: { $0.session.id == id }) else {
            pendingDeepLink = (id, Date())
            Task { await load() }
            return
        }
        pendingDeepLink = nil
        land(on: entry)
    }

    /// Clearing the way to a chat and pushing it are two navigation transitions, and starting the
    /// second before the first has finished is how a deep link corrupts the stack: the push waits
    /// for the dismissal it depends on. A notification tap can also arrive mid-transition or before
    /// Home has a window, so the push itself is deferred until the stack is quiet.
    private func land(on entry: SessionEntry) {
        loadViewIfNeeded()
        view.endEditing(true)
        let open = { [weak self] in
            guard let self else { return }
            if let nav = self.navigationController, nav.topViewController !== self {
                nav.popToRootViewController(animated: false)
            }
            DispatchQueue.main.async { [weak self] in
                self?.openChat(for: entry)
            }
        }
        if let presented = presentedViewController {
            presented.dismiss(animated: false, completion: open)
            return
        }
        open()
    }

    /// Stays parked until the session actually appears: the cold-launch
    /// snapshot applies before the list loads, and consuming (and dropping)
    /// the link on that early pass loses notification taps.
    private func consumePendingDeepLink() {
        guard let pending = pendingDeepLink else { return }
        guard Date().timeIntervalSince(pending.parkedAt) < 30 else {
            pendingDeepLink = nil
            return
        }
        guard let entry = viewModel.entries.first(where: { $0.session.id == pending.sessionID })
        else { return }
        pendingDeepLink = nil
        land(on: entry)
    }

    /// Opens a conversation, and — when the caller has one — puts a question into it.
    ///
    /// The question travels *with* the open rather than being chained onto what this returns.
    /// Every early exit here returns nil (the chat is already on screen, a push is mid-flight,
    /// the server is gone), and a caller that wrote `openChat(…)?.send(text)` therefore dropped
    /// the words silently on each of them: the chat opened, the question did not. A quick ask's
    /// dismissal is exactly when a transition is most likely to be running, which is what made it
    /// a coin toss. So `sending` is carried through the retry, delivered to a chat already open,
    /// and sent by the one path that has the view model.
    @discardableResult
    private func openChat(
        for entry: SessionEntry, seeding choice: ModelChoice? = nil,
        sending question: (text: String, attachments: [PromptAttachment])? = nil
    ) -> ChatViewModel? {
        guard let nav = navigationController else { return nil }
        if let top = nav.topViewController as? ChatViewController, top.sessionID == entry.session.id
        {
            if let question { top.deliver(question.text, attachments: question.attachments) }
            return nil
        }
        if nav.transitionCoordinator != nil {
            DispatchQueue.main.async { [weak self] in
                self?.openChat(for: entry, seeding: choice, sending: question)
            }
            return nil
        }
        guard let backend = viewModel.backend(for: entry) else { return nil }
        SessionSeenStore.markSeen(entry.session.id)
        let chatViewModel =
            SessionActivity.shared.retainedViewModel(
                for: entry.session.id, contextID: entry.profileID)
            ?? ChatViewModel(
                backend: backend, session: entry.session, contextID: entry.profileID,
                serverName: entry.profileName)
        if let choice { chatViewModel.seed(choice) }
        /// A sheet still over the stack is the one animation this movement gets: the chat is
        /// pushed behind it and revealed as it slides away, rather than the two of them taking
        /// turns for the better part of a second.
        nav.pushViewController(
            ChatViewController(viewModel: chatViewModel), animated: presentedViewController == nil)
        if let question {
            chatViewModel.send(question.text, attachments: question.attachments)
        }
        return chatViewModel
    }

    private func startChat(on profile: ConnectionProfile) {
        Theme.Haptics.tap()
        let stored = AppPreferences.lastComposeTarget
        let directory =
            (stored?.profileID == profile.id ? stored?.directory : nil)
            ?? recentDirectories(for: profile).first
        setComposeTarget(profile: profile, directory: directory)
        composerBar.focus()
    }

    func pushSaved() {
        Theme.Haptics.tap()
        navigationController?.pushViewController(SavedChatsViewController(), animated: true)
    }

    #if DEBUG
        /// Puts the Saved list into a named state so each one can be reviewed
        /// without tapping: `empty` clears it, `seed` bookmarks real chats, and
        /// `states` adds a chat its server no longer has plus one whose server
        /// is gone entirely.
        private func seedSavedForVerification(_ mode: String) {
            for chat in SavedChatStore.all() {
                SavedChatStore.remove(profileID: chat.profileID, sessionID: chat.sessionID)
            }
            guard mode != "empty" else { return }
            for entry in viewModel.entries.prefix(3) { SavedChatStore.save(entry) }
            guard mode == "states", let sample = viewModel.entries.first else { return }
            var ghost = sample.session
            ghost.title = "Deleted on the server"
            SavedChatStore.save(
                SessionEntry(
                    profileID: sample.profileID, profileName: sample.profileName,
                    host: sample.host, backendType: sample.backendType,
                    session: AgentSession(
                        id: "ghost-session", agentType: sample.backendType, title: ghost.title,
                        createdAt: ghost.createdAt, updatedAt: ghost.updatedAt)))
            SavedChatStore.save(
                SessionEntry(
                    profileID: "removed-server", profileName: "old-laptop",
                    host: "old-laptop", backendType: sample.backendType,
                    session: AgentSession(
                        id: "orphan-session", agentType: sample.backendType,
                        title: "Chat on a server I disconnected",
                        createdAt: ghost.createdAt, updatedAt: ghost.updatedAt)))
        }
    #endif

    /// Opening from Home prefers the live session so the chat starts with the
    /// server's own view of it, and falls back to the saved snapshot when the
    /// listing hasn't landed — the bookmark is meant to work while offline.
    private func openSaved(_ chat: SavedChat) {
        if let entry = viewModel.entries.first(where: {
            $0.profileID == chat.profileID && $0.session.id == chat.sessionID
        }) {
            openChat(for: entry)
            return
        }
        guard let profile = viewModel.servers.first(where: { $0.id == chat.profileID }) else {
            pushSaved()
            return
        }
        let entry = SessionEntry(
            profileID: chat.profileID, profileName: chat.profileName,
            host: profile.baseURL.host ?? chat.profileName, backendType: chat.backend,
            session: AgentSession(
                id: chat.sessionID, agentType: chat.backend, title: chat.title,
                directory: chat.directory, createdAt: chat.updatedAt, updatedAt: chat.updatedAt))
        openChat(for: entry)
    }

    #if DEBUG
        /// Opens the new-chat sheet on the first server and starts in a folder, so the states a
        /// mint can end in — waiting, and each failure with its own remedy — can be seen on a
        /// simulator without a hand on the screen.
        private func startChatForVerification(in directory: String) {
            guard let profile = viewModel.servers.first else { return }
            NewChatFlow.begin(
                from: self, profile: profile, viewModel: viewModel, directory: directory
            ) { [weak self] entry in
                self?.openSession(withID: entry.session.id)
            }
        }
    #endif

    private func pushChats(filterProfileID: String? = nil) {
        navigationController?.pushViewController(
            SessionListViewController(filterProfileID: filterProfileID), animated: true)
    }

    /// A folder opens a container, never a composer: the card's tap lands on the project's own
    /// board — its chats and nothing else — with the launch pad's mint waiting in the board's
    /// chrome and in the card's long-press.
    private func openProjectBoard(for card: ProjectCard) {
        Theme.Haptics.tap()
        navigationController?.pushViewController(
            SessionListViewController(
                scope: ProjectScope(profileID: card.profileID, directory: card.directory)),
            animated: true)
    }

    /// One gesture summons the surface — the chrome's sparkle, the icon's jump list, the
    /// Control Center tile — and where the conversation opens afterwards is the same road every
    /// conversation takes, with the words sent the moment the chat is up. With no servers the
    /// gesture goes to setup instead of presenting a dead text box, and a surface already up is
    /// left alone rather than stacked on.
    func presentQuickAsk() {
        if let presented = presentedViewController {
            guard !(presented is QuickAskViewController) else { return }
            dismiss(animated: true) { [weak self] in self?.presentQuickAsk() }
            return
        }
        Theme.Haptics.tap()
        guard !viewModel.servers.isEmpty else {
            presentServerSetup()
            return
        }
        let ask = QuickAskViewController.present(from: self, viewModel: viewModel)
        ask.onOpen = { [weak self] entry, text, aim, attachments in
            self?.openChat(
                for: entry, seeding: aim, sending: (text: text, attachments: attachments))
        }
        ask.onResume = { [weak self] entry in
            self?.openChat(for: entry)
        }
    }

    func pushUsage() {
        navigationController?.pushViewController(UsageViewController(), animated: true)
    }

    private func configureCollectionView() {
        let layout = UICollectionViewCompositionalLayout { [weak self] index, environment in
            guard let self, let section = self.dataSource?.sectionIdentifier(for: index)
            else { return Self.listSection() }
            switch section {
            case .live: return Self.liveSection()
            case .projects: return Self.projectsSection()
            case .alerts: return Self.listSection(withHeader: false)
            case .missed: return Self.listSection()
            case .saved, .recent, .usage: return Self.listSection()
            }
        }
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.refreshControl = refreshControl
        collectionView.keyboardDismissMode = .interactive
        let dismissTap = UITapGestureRecognizer(target: self, action: #selector(backgroundTapped))
        dismissTap.cancelsTouchesInView = false
        collectionView.addGestureRecognizer(dismissTap)
        refreshControl.addTarget(self, action: #selector(refresh), for: .valueChanged)
        view.addSubview(collectionView)
    }

    /// Tapping anywhere outside the composer puts the keyboard away; the tap
    /// still reaches whatever it landed on. Project cards are exempt — their
    /// whole point is to re-aim the composer, so the keyboard stays up.
    @objc private func backgroundTapped(_ gesture: UITapGestureRecognizer) {
        guard composerBar.isEditingText else { return }
        if let indexPath = collectionView.indexPathForItem(at: gesture.location(in: collectionView)),
            case .project = dataSource.itemIdentifier(for: indexPath)
        {
            return
        }
        view.endEditing(true)
    }

    private func configureComposer() {
        composerBar.delegate = self
        composerBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(composerBar)
        NSLayoutConstraint.activate([
            composerBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composerBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            composerBar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
        configureOrb()
    }

    private func configureOrb() {
        orbView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(orbView)
        NSLayoutConstraint.activate([
            orbView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            orbView.bottomAnchor.constraint(equalTo: composerBar.topAnchor, constant: -10),
            orbView.widthAnchor.constraint(equalToConstant: 76),
            orbView.heightAnchor.constraint(equalToConstant: 76),
        ])
        orbView.setEnabled(PresenceOrbSetting.isEnabled)
        orbView.onTap = { [weak self] in
            guard let self, let entry = self.orbTarget else { return }
            self.openChat(for: entry)
        }
        composerBar.onAuraChanged = { [weak self] in self?.applyOrbState() }
        NotificationCenter.default.addObserver(
            self, selector: #selector(orbSettingChanged),
            name: PresenceOrbSetting.didChange, object: nil)
    }

    @objc private func orbSettingChanged() {
        orbView.setEnabled(PresenceOrbSetting.isEnabled)
        applyOrbState()
    }

    /// The orb reads the same board the list draws: what this device is streaming first-hand
    /// wins, the listing's own working flag counts, and every unreachable server rests one quiet
    /// weight on the body. The conversation a tap opens is the one that most needs the person.
    private func applyOrbState() {
        guard PresenceOrbSetting.isEnabled else { return }
        var kinds: [ActivityKind?] = viewModel.entries.map { entry in
            switch SessionActivity.shared.status(for: entry.session.id) {
            case .awaitingApproval: return .needsApproval
            case .running: return .working
            case .idle: return isLive(entry) ? .working : nil
            }
        }
        kinds += viewModel.unreachable.map { _ in ActivityKind.offline }
        orbTarget =
            viewModel.entries.first {
                SessionActivity.shared.status(for: $0.session.id) == .awaitingApproval
            } ?? viewModel.entries.first { isLive($0) }
        orbView.update(
            signal: PresenceSignal.aggregate(kinds, ultracode: composerBar.auraIsActive))
    }

    private static func liveSection() -> NSCollectionLayoutSection {
        let item = NSCollectionLayoutItem(
            layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .fractionalHeight(1)))
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: .init(widthDimension: .absolute(248), heightDimension: .absolute(104)),
            subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.orthogonalScrollingBehavior = .continuous
        section.interGroupSpacing = Theme.Spacing.m
        section.contentInsets = .init(
            top: Theme.Spacing.s, leading: Theme.Spacing.l,
            bottom: Theme.Spacing.l, trailing: Theme.Spacing.l)
        section.boundarySupplementaryItems = [header()]
        return section
    }

    private static func projectsSection() -> NSCollectionLayoutSection {
        let item = NSCollectionLayoutItem(
            layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .fractionalHeight(1)))
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: .init(widthDimension: .absolute(150), heightDimension: .absolute(88)),
            subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.orthogonalScrollingBehavior = .continuous
        section.interGroupSpacing = Theme.Spacing.m
        section.contentInsets = .init(
            top: Theme.Spacing.s, leading: Theme.Spacing.l,
            bottom: Theme.Spacing.l, trailing: Theme.Spacing.l)
        section.boundarySupplementaryItems = [header()]
        return section
    }

    private static func listSection(withHeader: Bool = true) -> NSCollectionLayoutSection {
        let item = NSCollectionLayoutItem(
            layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(72)))
        let group = NSCollectionLayoutGroup.vertical(
            layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(72)),
            subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = Theme.Spacing.s
        section.contentInsets = .init(
            top: Theme.Spacing.s, leading: Theme.Spacing.l,
            bottom: Theme.Spacing.l, trailing: Theme.Spacing.l)
        if withHeader { section.boundarySupplementaryItems = [header()] }
        return section
    }

    private static func header() -> NSCollectionLayoutBoundarySupplementaryItem {
        NSCollectionLayoutBoundarySupplementaryItem(
            layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(30)),
            elementKind: UICollectionView.elementKindSectionHeader, alignment: .top)
    }

    private func configureDataSource() {
        let alertCell = UICollectionView.CellRegistration<ServerAlertCell, ServerAlertCard> {
            cell, _, card in cell.configure(card)
        }
        let missedCell = UICollectionView.CellRegistration<MissedActivityCell, MissedActivity> {
            cell, _, item in cell.configure(item)
        }
        let liveCell = UICollectionView.CellRegistration<LiveSessionCell, LiveCard> {
            cell, _, card in cell.configure(card)
        }
        let projectCell = UICollectionView.CellRegistration<ProjectCell, ProjectCard> {
            cell, _, card in cell.configure(card)
        }
        let recentCell = UICollectionView.CellRegistration<RecentSessionCell, RecentCard> {
            cell, _, card in cell.configure(card)
        }
        let savedCell = UICollectionView.CellRegistration<RecentSessionCell, SavedCard> {
            cell, _, card in cell.configure(card)
        }
        let quotaCell = UICollectionView.CellRegistration<QuotaCardCell, QuotaCard> {
            cell, _, card in cell.configure(card)
        }
        let placeholderCell = UICollectionView.CellRegistration<RecentPlaceholderCell, Int> {
            _, _, _ in
        }
        let usagePlaceholderCell = UICollectionView.CellRegistration<QuotaPlaceholderCell, Int> {
            _, _, _ in
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
            collectionView, indexPath, item in
            switch item {
            case .alert(let card):
                return collectionView.dequeueConfiguredReusableCell(
                    using: alertCell, for: indexPath, item: card)
            case .missed(let item):
                return collectionView.dequeueConfiguredReusableCell(
                    using: missedCell, for: indexPath, item: item)
            case .live(let card):
                return collectionView.dequeueConfiguredReusableCell(
                    using: liveCell, for: indexPath, item: card)
            case .project(let card):
                return collectionView.dequeueConfiguredReusableCell(
                    using: projectCell, for: indexPath, item: card)
            case .saved(let card):
                return collectionView.dequeueConfiguredReusableCell(
                    using: savedCell, for: indexPath, item: card)
            case .recent(let card):
                return collectionView.dequeueConfiguredReusableCell(
                    using: recentCell, for: indexPath, item: card)
            case .usage(let card):
                return collectionView.dequeueConfiguredReusableCell(
                    using: quotaCell, for: indexPath, item: card)
            case .placeholder(let index):
                return collectionView.dequeueConfiguredReusableCell(
                    using: placeholderCell, for: indexPath, item: index)
            case .usagePlaceholder(let index):
                return collectionView.dequeueConfiguredReusableCell(
                    using: usagePlaceholderCell, for: indexPath, item: index)
            }
        }

        let header = UICollectionView.SupplementaryRegistration<HomeHeaderView>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            guard let self,
                let section = self.dataSource.sectionIdentifier(for: indexPath.section)
            else { return }
            switch section {
            case .alerts:
                break
            case .missed:
                view.configure(
                    title: String(localized: "Missed"),
                    actionTitle: String(localized: "Clear")
                ) {
                    Theme.Haptics.tap()
                    NotificationManager.clearAllNotices()
                    self.applySnapshot()
                }
            case .live:
                view.configure(title: String(localized: "Live now"))
            case .projects:
                view.configure(title: String(localized: "Projects"))
            case .saved:
                view.configure(
                    title: String(localized: "Saved"), actionTitle: String(localized: "See all")
                ) { [weak self] in
                    self?.pushSaved()
                }
            case .recent:
                view.configure(
                    title: String(localized: "Recent"), actionTitle: String(localized: "See all")
                ) { [weak self] in
                    self?.pushChats()
                }
            case .usage:
                view.configure(
                    title: String(localized: "Usage"), actionTitle: String(localized: "Details")
                ) { [weak self] in
                    self?.pushUsage()
                }
            }
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
    }
}

extension HomeViewController: HomeComposerBarDelegate {
    func homeComposer(_ bar: HomeComposerBar, didSend text: String) {
        composerSend(text)
    }

    func homeComposerDidBeginEditing(_ bar: HomeComposerBar) {}

    func homeComposerTextDidChange(_ text: String) {
        guard let scope = composerDraftScope else { return }
        DraftStore.record(text, for: scope)
    }

    /// Home's composer has no session to belong to, so what is written in it belongs to where it
    /// is aimed: re-aiming the chip stashes the text under the destination it was written for and
    /// hands back whatever was left unsent for the new one, the way switching chats does in a pane.
    private func syncComposerDraft(to scope: DraftScope) {
        guard composerDraftScope != scope else { return }
        let carried = composerBar.rawText
        guard let previous = composerDraftScope else {
            composerDraftScope = scope
            if composerBar.currentText.isEmpty {
                composerBar.setText(DraftStore.text(for: scope))
            } else {
                DraftStore.record(carried, for: scope)
            }
            return
        }
        DraftStore.record(carried, for: previous)
        composerDraftScope = scope
        composerBar.setText(DraftStore.text(for: scope))
    }

    /// Where the next message goes. A target the user chose is stored and authoritative; everything
    /// else is a guess drawn from the chat list, which re-sorts by itself every time another device
    /// finishes a turn or a poll lands. Re-deriving the guess on each of those would move the
    /// destination — and with it the scope the composer's draft is filed under — with nobody
    /// touching the phone, so the guess is made once and kept until a real retarget or a change to
    /// the servers themselves.
    private var composeTarget: (profileID: String, directory: String?)? {
        if let stored = AppPreferences.lastComposeTarget,
            viewModel.servers.contains(where: { $0.id == stored.profileID })
        {
            return stored
        }
        if let memo = resolvedComposeTarget,
            viewModel.servers.contains(where: { $0.id == memo.profileID })
        {
            return memo
        }
        let resolved = resolveComposeTarget()
        resolvedComposeTarget = resolved
        return resolved
    }

    private func resolveComposeTarget() -> (profileID: String, directory: String?)? {
        if let recent = viewModel.entries.first(where: { $0.session.directory != nil }) {
            return (recent.profileID, recent.session.directory)
        }
        guard let first = viewModel.servers.first else { return nil }
        return (first.id, FileBrowserRecents.all(for: first.id).first)
    }

    /// Reapplies only when something the user can see actually changed: the live
    /// refresh runs this every few seconds, and reassigning a button's menu
    /// underneath an open one is exactly the kind of churn that makes a picker
    /// flicker shut mid-choice. Both menus resolve their contents when opened,
    /// so skipping the rebuild can't serve a stale list.
    private func updateComposer() {
        composerBar.isHidden = viewModel.servers.isEmpty
        guard let target = composeTarget,
            let profile = viewModel.servers.first(where: { $0.id == target.profileID })
        else { return }
        syncComposerDraft(
            to: .home(profileID: target.profileID, directory: target.directory))
        let project = target.directory.map { ($0 as NSString).lastPathComponent }
        let title = project.map { "\($0) · \(profile.name)" } ?? profile.name
        let modelLabel = modelChipLabel(for: profile)
        composerBar.ultracodeEffort =
            modelChoices[profile.id]?.effort
            ?? EffortPreferenceStore.globalEffort(forContextID: profile.id)
        let state = "\(profile.id)|\(target.directory ?? "")|\(title)|\(modelLabel ?? "")"
        guard state != appliedComposerState else { return }
        appliedComposerState = state
        let icon = UIImage(
            systemName: profile.backend.symbolName,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))?
            .withTintColor(profile.backend.brandColor, renderingMode: .alwaysOriginal)
        composerBar.setContext(icon: icon, title: title, menu: composeTargetMenu())
        updateModelChip(for: profile, label: modelLabel)
        view.setNeedsLayout()
    }

    /// The chip names the model the next message will actually run on — resolved
    /// exactly the way the chat screen resolves it — so starting a chat is never
    /// a blind commitment to whatever the server happens to default to. Nil for
    /// a backend that has neither model nor effort control, which then shows no
    /// chip at all.
    private func modelChipLabel(for profile: ConnectionProfile) -> String? {
        guard let backend = viewModel.backend(forProfileID: profile.id),
            backend.capabilities.supportsModelSelection
                || backend.capabilities.supportsReasoningEffort
        else { return nil }
        let choice = modelChoices[profile.id] ?? ModelChoice()
        return ModelBadge.label(model: choice.model, effort: choice.effort)
    }

    private func updateModelChip(for profile: ConnectionProfile, label: String?) {
        guard let label, let backend = viewModel.backend(forProfileID: profile.id) else {
            composerBar.setModel(title: nil, menu: nil)
            return
        }
        composerBar.setModel(title: label, menu: modelMenu(for: profile, backend: backend))
        resolveModelChoiceIfNeeded(for: profile, backend: backend)
    }

    private func resolveModelChoiceIfNeeded(
        for profile: ConnectionProfile, backend: any CodingAgentBackend
    ) {
        guard modelChoices[profile.id] == nil, resolvingModels.insert(profile.id).inserted else {
            return
        }
        Task { @MainActor in
            let choice = await ChatModelResolver.choice(profileID: profile.id, backend: backend)
            resolvingModels.remove(profile.id)
            modelChoices[profile.id] = choice
            updateComposer()
        }
    }

    /// Built lazily on every present: the catalog may still be in flight when
    /// the chip is first drawn, and a menu opened a second later must show the
    /// models rather than the placeholder it was built with.
    private func modelMenu(for profile: ConnectionProfile, backend: any CodingAgentBackend)
        -> UIMenu
    {
        UIMenu(
            title: String(localized: "Model"),
            children: [
                UIDeferredMenuElement.uncached { [weak self] completion in
                    Task { @MainActor in
                        guard let self else { return completion([]) }
                        let models =
                            backend.capabilities.supportsModelSelection
                            ? await ModelCatalog.models(for: profile.id, backend: backend) : []
                        completion(
                            ModelMenu.elements(
                                models: models,
                                choice: self.modelChoices[profile.id] ?? ModelChoice(),
                                efforts: backend.reasoningEffortOptions,
                                allowsServerDefault: ChatModelResolver.honoursServerDefault(backend),
                                quotas: QuotaSurface.relevantQuotas(
                                    for: backend.agentType, among: UsageWidgetStore.cachedQuotas()),
                                actions: ModelMenu.Actions(
                                    selectModel: { [weak self] selection in
                                        self?.setComposeModel(selection, for: profile)
                                    },
                                    selectEffort: { [weak self] level in
                                        self?.setComposeEffort(level, for: profile)
                                    },
                                    browseAll: { [weak self] in
                                        self?.presentComposeModelPicker(
                                            profile: profile, models: models)
                                    })))
                    }
                }
            ])
    }

    private func setComposeModel(_ selection: ModelSelection?, for profile: ConnectionProfile) {
        ModelPreferenceStore.recordPick(selection, sessionKey: nil, contextID: profile.id)
        if selection == nil {
            modelChoices[profile.id] = nil
        } else {
            var choice = modelChoices[profile.id] ?? ModelChoice()
            choice.model = selection
            modelChoices[profile.id] = choice
        }
        Theme.Haptics.selection()
        updateComposer()
    }

    private func setComposeEffort(_ level: String?, for profile: ConnectionProfile) {
        EffortPreferenceStore.recordPick(level, sessionKey: nil, contextID: profile.id)
        var choice = modelChoices[profile.id] ?? ModelChoice()
        choice.effort = level
        modelChoices[profile.id] = choice
        Theme.Haptics.selection()
        updateComposer()
    }

    private func presentComposeModelPicker(profile: ConnectionProfile, models: [ModelInfo]) {
        guard !models.isEmpty else { return }
        Theme.Haptics.tap()
        let picker = ModelPickerViewController(
            sources: ModelFleet.sources(
                profiles: ConnectionController.shared.profiles, current: profile.id,
                currentModels: models, allowsServerDefault: profile.backend == .claudeCode),
            selected: modelChoices[profile.id]?.model,
            quotas: QuotaSurface.relevantQuotas(
                for: profile.backend, among: UsageWidgetStore.cachedQuotas())
        ) { [weak self] pick in
            guard let self else { return }
            if pick.isElsewhere {
                ModelFleet.adopt(pick)
                self.aimCompose(at: pick.profileID)
            } else {
                self.setComposeModel(pick.selection, for: profile)
            }
        }
        let nav = UINavigationController(rootViewController: picker)
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(nav, animated: true)
    }

    private func composeTargetMenu() -> UIMenu {
        UIMenu(
            title: String(localized: "Start the chat in…"),
            children: [
                UIDeferredMenuElement.uncached { [weak self] completion in
                    completion(self?.composeTargets() ?? [])
                }
            ])
    }

    private func composeTargets() -> [UIMenuElement] {
        let current = composeTarget
        let serverMenus: [UIMenuElement] = viewModel.servers.map { profile in
            var children: [UIMenuElement] = []
            children.append(contentsOf: recentDirectories(for: profile).map { directory in
                UIAction(
                    title: (directory as NSString).lastPathComponent,
                    subtitle: directory,
                    image: UIImage(systemName: "folder"),
                    state: current?.profileID == profile.id && current?.directory == directory
                        ? .on : .off
                ) { [weak self] _ in
                    self?.setComposeTarget(profile: profile, directory: directory)
                }
            })
            children.append(
                UIAction(
                    title: String(localized: "Somewhere else…"),
                    subtitle: String(localized: "Search folders, browse, or type a path"),
                    image: UIImage(systemName: "folder.badge.plus")
                ) {
                    [weak self] _ in self?.chooseComposeTarget(profile: profile)
                })
            if viewModel.servers.count == 1 {
                return UIMenu(options: .displayInline, children: children)
            }
            return UIMenu(
                title: profile.name,
                image: UIImage(systemName: profile.backend.symbolName),
                children: children)
        }
        return serverMenus
    }

    /// Explicitly chosen recents first, then directories of past sessions.
    private func recentDirectories(for profile: ConnectionProfile) -> [String] {
        let sessionDirs = viewModel.entries
            .filter { $0.profileID == profile.id }
            .compactMap(\.session.directory)
        var seen = Set<String>()
        var result: [String] = []
        for directory in FileBrowserRecents.all(for: profile.id) + sessionDirs
        where seen.insert(directory).inserted {
            result.append(directory)
            if result.count == 6 { break }
        }
        return result
    }

    private func setComposeTarget(profile: ConnectionProfile, directory: String?) {
        AppPreferences.lastComposeTarget = (profile.id, directory)
        resolvedComposeTarget = nil
        if let directory { FileBrowserRecents.record(directory, for: profile.id) }
        Theme.Haptics.selection()
        updateComposer()
    }

    /// Aims the docked composer at another machine, the Home half of the fleet's "start a chat
    /// there" move. The compose is a promise about where the next session will live, so it is the
    /// one thing on this screen that can point somewhere else.
    func aimCompose(at profileID: String) {
        guard let profile = ConnectionController.shared.profiles.first(where: { $0.id == profileID })
        else { return }
        setComposeTarget(profile: profile, directory: nil)
        focusComposer()
    }

    /// "Somewhere else" is one screen, not two: the same `NewChatViewController` the chat list
    /// opens, asked only for the answer. Browsing the server's tree is one of its rows, so a
    /// server that can list its files and one that cannot are the same gesture here. Never opens
    /// a bare path prompt as the fallback.
    private func chooseComposeTarget(profile: ConnectionProfile) {
        NewChatFlow.chooseDirectory(from: self, profile: profile, viewModel: viewModel) {
            [weak self] profileID, directory in
            guard let self,
                let picked = self.viewModel.servers.first(where: { $0.id == profileID })
            else { return }
            self.setComposeTarget(profile: picked, directory: directory)
            self.composerBar.focus()
        }
    }

    /// The session is created only now, on commit; the composer keeps the
    /// text until the create succeeds so a dead server loses nothing.
    private func composerSend(_ text: String) {
        guard let target = composeTarget,
            let profile = viewModel.servers.first(where: { $0.id == target.profileID })
        else { return }
        composerBar.setSending(true)
        Task {
            guard let entry = await viewModel.newSession(on: profile, directory: target.directory)
            else {
                composerBar.setSending(false)
                Theme.Haptics.error()
                let alert = UIAlertController(
                    title: String(localized: "Couldn't start the chat"),
                    message: String(
                        localized:
                            "\(profile.name) didn't respond. Check the connection and try again."),
                    preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
                present(alert, animated: true)
                return
            }
            if let directory = target.directory {
                FileBrowserRecents.record(directory, for: profile.id)
            }
            AppPreferences.lastComposeTarget = target
            composerBar.setSending(false)
            composerBar.clearText()
            DraftStore.clear(.home(profileID: target.profileID, directory: target.directory))
            view.endEditing(true)
            Theme.Haptics.success()
            openChat(
                for: entry, seeding: modelChoices[profile.id],
                sending: (text: text, attachments: []))
        }
    }
}

extension HomeViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        switch item {
        case .alert:
            onOpenSettings?()
        case .missed(let item):
            openMissed(item)
        case .live(let card):
            openChat(for: card.entry)
        case .project(let card):
            openProjectBoard(for: card)
        case .saved(let card):
            openSaved(card.chat)
        case .recent(let card):
            openChat(for: card.entry)
        case .usage:
            pushUsage()
        case .placeholder, .usagePlaceholder:
            break
        }
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first,
            let item = dataSource.itemIdentifier(for: indexPath)
        else { return nil }
        switch item {
        case .project(let card):
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                UIMenu(children: [
                    UIAction(
                        title: String(localized: "New chat here"),
                        image: UIImage(systemName: "plus.bubble")
                    ) { _ in
                        guard let self,
                            let profile = self.viewModel.servers.first(where: { $0.id == card.profileID })
                        else { return }
                        Task {
                            guard let entry = await self.viewModel.newSession(
                                on: profile, directory: card.directory)
                            else { return }
                            Theme.Haptics.success()
                            self.openChat(for: entry)
                        }
                    },
                    UIAction(
                        title: String(localized: "Write here"),
                        subtitle: String(localized: "Aim the composer at this project"),
                        image: UIImage(systemName: "square.and.pencil")
                    ) { _ in
                        guard let self,
                            let profile = self.viewModel.servers.first(where: { $0.id == card.profileID })
                        else { return }
                        self.setComposeTarget(profile: profile, directory: card.directory)
                        self.composerBar.focus()
                    },
                    UIAction(
                        title: String(localized: "View chats on \(card.profileName)"),
                        image: UIImage(systemName: "bubble.left.and.bubble.right")
                    ) { _ in self?.pushChats(filterProfileID: card.profileID) },
                ])
            }
        case .saved(let card):
            return savedMenu(for: card.chat)
        case .recent(let card):
            return sessionMenu(for: card.entry, allowDelete: true)
        case .live(let card):
            return sessionMenu(for: card.entry, allowDelete: false)
        case .alert, .missed, .usage, .placeholder, .usagePlaceholder:
            return nil
        }
    }

    private func savedMenu(for chat: SavedChat) -> UIContextMenuConfiguration {
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [
                UIAction(
                    title: String(localized: "Open"), image: UIImage(systemName: "bubble.left")
                ) { _ in
                    self?.openSaved(chat)
                },
                UIAction(
                    title: String(localized: "Remove from Saved"),
                    image: UIImage(systemName: "bookmark.slash"),
                    attributes: .destructive
                ) { _ in
                    Theme.Haptics.tap()
                    SavedChatStore.remove(profileID: chat.profileID, sessionID: chat.sessionID)
                },
            ])
        }
    }

    /// Long-press on a session card mirrors the Chats screen's row menu, so
    /// managing a conversation never requires leaving Home.
    private func sessionMenu(
        for entry: SessionEntry, allowDelete: Bool
    ) -> UIContextMenuConfiguration {
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return UIMenu() }
            var actions: [UIMenuElement] = [
                UIAction(
                    title: String(localized: "Open"), image: UIImage(systemName: "bubble.left")
                ) {
                    [weak self] _ in self?.openChat(for: entry)
                }
            ]
            if let directory = entry.session.directory,
                let profile = self.viewModel.servers.first(where: { $0.id == entry.profileID })
            {
                actions.append(
                    UIAction(
                        title: String(localized: "New chat in same project"),
                        image: UIImage(systemName: "plus.bubble")
                    ) { [weak self] _ in
                        Task {
                            guard let self,
                                let new = await self.viewModel.newSession(
                                    on: profile, directory: directory)
                            else { return }
                            Theme.Haptics.success()
                            self.openChat(for: new)
                        }
                    })
            }
            let isSaved = SavedChatStore.contains(entry)
            actions.append(
                UIAction(
                    title: isSaved
                        ? String(localized: "Remove from Saved") : String(localized: "Save chat"),
                    image: UIImage(systemName: isSaved ? "bookmark.slash" : "bookmark")
                ) { [weak self] _ in
                    Theme.Haptics.tap()
                    SavedChatStore.toggle(entry)
                    self?.applySnapshot()
                })
            let isArchived = ArchivedChatStore.contains(
                profileID: entry.profileID, sessionID: entry.session.id)
            actions.append(
                UIAction(
                    title: isArchived
                        ? String(localized: "Unarchive") : String(localized: "Archive"),
                    subtitle: isArchived
                        ? String(localized: "Back into the chat list")
                        : String(localized: "Out of the list, kept on the server"),
                    image: UIImage(systemName: isArchived ? "tray.and.arrow.up" : "archivebox")
                ) { _ in
                    Theme.Haptics.tap()
                    ArchivedChatStore.toggle(
                        profileID: entry.profileID, sessionID: entry.session.id)
                })
            let isPinned = SessionPinStore.contains(
                profileID: entry.profileID, sessionID: entry.session.id)
            actions.append(
                UIAction(
                    title: isPinned ? String(localized: "Unpin") : String(localized: "Pin"),
                    subtitle: isPinned
                        ? String(localized: "Back into the recency order")
                        : String(localized: "Always at the top of the chat list"),
                    image: UIImage(systemName: isPinned ? "pin.slash" : "pin")
                ) { _ in
                    Theme.Haptics.tap()
                    SessionPinStore.toggle(
                        profileID: entry.profileID, sessionID: entry.session.id)
                })
            let isUnread = SessionSeenStore.unreadEvaluator()(
                entry.session.id, entry.session.updatedAt)
            actions.append(
                UIAction(
                    title: isUnread
                        ? String(localized: "Mark as read") : String(localized: "Mark as unread"),
                    image: UIImage(systemName: isUnread ? "envelope.open" : "envelope.badge")
                ) { [weak self] _ in
                    Theme.Haptics.tap()
                    if isUnread {
                        SessionSeenStore.markSeen(entry.session.id)
                    } else {
                        SessionSeenStore.markUnread(
                            entry.session.id, updatedAt: entry.session.updatedAt)
                    }
                    self?.applySnapshot()
                })
            if self.viewModel.supportsRenaming(entry) {
                actions.append(
                    UIAction(
                        title: String(localized: "Rename"), image: UIImage(systemName: "pencil")
                    ) {
                        [weak self] _ in self?.promptRename(entry)
                    })
            }
            if self.viewModel.supportsForking(entry) {
                actions.append(
                    UIAction(
                        title: String(localized: "Fork"),
                        subtitle: String(
                            localized: "A new session with this history, for a different direction"),
                        image: UIImage(systemName: "arrow.triangle.branch")
                    ) { [weak self] _ in
                        Task { [weak self] in
                            guard let self, let forked = await self.viewModel.fork(entry)
                            else { return }
                            Theme.Haptics.success()
                            self.openChat(for: forked)
                        }
                    })
            }
            if allowDelete, self.viewModel.supportsMultipleSessions(entry) {
                actions.append(
                    UIAction(
                        title: String(localized: "Delete"), image: UIImage(systemName: "trash"),
                        attributes: .destructive
                    ) { [weak self] _ in self?.confirmDelete(entry) })
            }
            return UIMenu(children: actions)
        }
    }

    private func promptRename(_ entry: SessionEntry) {
        let alert = UIAlertController(
            title: String(localized: "Rename conversation"), message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = entry.session.title
            field.clearButtonMode = .whileEditing
            field.autocapitalizationType = .sentences
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(
            UIAlertAction(title: String(localized: "Rename"), style: .default) {
                [weak self, weak alert] _ in
            let title = alert?.textFields?.first?.text?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty, title != entry.session.title else { return }
            Theme.Haptics.success()
            Task { await self?.viewModel.rename(entry, to: title) }
        })
        present(alert, animated: true)
    }

    private func confirmDelete(_ entry: SessionEntry) {
        let alert = UIAlertController(
            title: String(localized: "Delete conversation?"),
            message: String(
                localized:
                    "\"\(SessionListViewController.displayTitle(entry.session.title))\" will be removed from the server."
            ),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(
            UIAlertAction(title: String(localized: "Delete"), style: .destructive) { [weak self] _ in
            Theme.Haptics.warning()
            Task { await self?.viewModel.delete(entry) }
        })
        present(alert, animated: true)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

extension HomeViewController: KeyActionHost {
    var keyContext: KeyContext { composerBar.isEditing ? .insert : .normal }

    /// The board's answers to the shared registry: the app-level verbs live here — new chat,
    /// filter, archive view, help — and the list-cursor verbs live one push away on the Chats
    /// screen, which is where a hardware-keyboard user lands the moment they ask for them.
    func performKeyAction(_ action: KeyAction) -> Bool {
        switch action {
        case .newChat:
            guard let profile = viewModel.servers.first else { return false }
            if viewModel.servers.count == 1 {
                startChat(on: profile)
            } else {
                composerBar.focus()
            }
        case .search:
            pushChats()
        case .selectNext, .selectPrevious, .selectFirst, .selectLast, .openSelected:
            pushChats()
        case .toggleArchiveView:
            Theme.Haptics.tap()
            navigationController?.pushViewController(
                ArchivedChatsViewController(), animated: true)
        case .insert:
            composerBar.focus()
        case .quickAsk:
            presentQuickAsk()
        case .leaveInsert:
            guard composerBar.isEditing else { return false }
            composerBar.unfocus()
            becomeFirstResponder()
        case .scrollDown:
            nudgeBoard(by: 120)
        case .scrollUp:
            nudgeBoard(by: -120)
        case .halfPageDown:
            nudgeBoard(by: collectionView.bounds.height * 0.5)
        case .halfPageUp:
            nudgeBoard(by: -collectionView.bounds.height * 0.5)
        case .reload:
            Task { await load(.user) }
        case .toggleHelp:
            ShortcutCheatsheetViewController.present(from: self)
        default:
            return false
        }
        return true
    }

    private func nudgeBoard(by delta: CGFloat) {
        let inset = collectionView.adjustedContentInset
        let minY = -inset.top
        let maxY = max(
            minY, collectionView.contentSize.height - collectionView.bounds.height + inset.bottom)
        let target = min(maxY, max(minY, collectionView.contentOffset.y + delta))
        collectionView.setContentOffset(CGPoint(x: 0, y: target), animated: true)
    }
}
