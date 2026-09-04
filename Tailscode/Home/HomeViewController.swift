import TailscodeCore
import CodingAgentKit
import CodingAgentKitApple
import PhotosUI
import UIKit
import UniformTypeIdentifiers

/// The app's front door, organized around three jobs: triage (what needs you
/// right now — blocked or live agents, unreachable servers), continue (recent
/// conversations, badged when they changed since you last looked), and start
/// (the docked composer in either of its two lanes, and project cards that open
/// each project's own board).
@MainActor
final class HomeViewController: UIViewController {
    var onOpenSettings: (() -> Void)?

    private let viewModel: SessionListViewModel
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<HomeSection, HomeItem>!
    private let refreshControl = UIRefreshControl()
    private let composerBar = HomeComposerBar()
    private let commandPalette = SlashCommandPalette()
    private let suggestions = HomeAskSuggestions()
    private let videoChips = HomeVideoChips()
    private let attachmentStrip = HomeAttachmentStrip()
    private let failureCard = HomeComposerFailureCard()
    /// Everything that floats between the board and the box, in the order a hand reaches for it:
    /// what went wrong furthest away, then what is being offered, then what is already in hand.
    private let accessories = UIStackView()
    /// Which lane the box is in. The chat lane starts a conversation in a project; the ask lane
    /// starts one on a machine and carries the ask's own memory of what should answer it.
    private var askLane: QuickAskLane = .chat
    private var attachments: [PendingAttachment] = []
    private var abilities = ModelAbilities.words
    private var pastedImageCount = 0
    private let enhancement = PromptEnhancementController()
    private weak var enhanceOverlay: PromptEnhanceOverlay?
    /// The mint that failed, kept whole so its remedy can be applied and the same words retried
    /// without asking anybody to type them again.
    private var lastAttempt: (aim: ComposerAim, send: QuickAskSend)?
    private var lastFailure: NewChatFailure?
    /// What the aimed machine can be told to do. Home's composer mints the conversation a command
    /// would run in, so it owes the same grammar the chat's own composer answers: a slash typed
    /// here is a command, not the first four letters of a question.
    private var commands: [AgentCommand] = []
    private var catalogProfileID: String?
    private var composerFloor: NSLayoutConstraint!
    private var composerRidesKeyboard: NSLayoutConstraint!
    private let settingsButton = UpdateMarkButton()
    private lazy var settingsItem = UIBarButtonItem(customView: settingsButton)
    private let videoButton = VideoMarkButton()
    private lazy var videoItem = UIBarButtonItem(customView: videoButton)
    private let orbView = PresenceOrbView()
    private var orbTarget: SessionEntry?
    private var quotas: [UsageQuota] = []
    private var savedChats: [SavedChat] = SavedChatStore.all()
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

    /// Everything the lane decides, resolved once. The two lanes differ by exactly this much —
    /// where the conversation lands, which memory names the model, and which draft is in the box —
    /// so every path that used to read the compose target reads this instead and stops caring
    /// which lane it is in.
    struct ComposerAim {
        let lane: QuickAskLane
        let profile: ConnectionProfile
        let directory: String?
        /// Where this device files the model and effort for this lane on this server. The ask
        /// lane's is a context beside the server's own, never inside it, so pointing lookups at
        /// something cheap never re-aims the project chats.
        let memoryKey: String
        /// The context a resolve reads from, which is the ask's own only once one is claimed —
        /// until then a question runs on what a new chat there would have used.
        let resolutionContext: String?
        let draftScope: DraftScope
    }

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
        videoButton.addTarget(self, action: #selector(openVideo), for: .touchUpInside)
        updateVideoMark()
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
                    self?.seedAskForVerification()
                }
            }
            if ProcessInfo.processInfo.environment["TAILSCODE_OPEN_VIDEOLANE"] != nil {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    guard let self else { return }
                    self.setLane(.video, animated: false)
                    ForgeRunner.shared.describe("a cat asleep on a warm tiled roof")
                    self.composerBar.setText(ForgeRunner.shared.board.recipe.prompt)
                }
            }
            if ProcessInfo.processInfo.environment["TAILSCODE_OPEN_STREAM"] != nil {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    self?.navigationController?.pushViewController(
                        StreamRendererViewController(), animated: false)
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
            if let text = ProcessInfo.processInfo.environment["TAILSCODE_COMPOSE_TYPE"] {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(4))
                    self?.focusComposer()
                    self?.composerBar.tourSetText(text)
                }
            }
        #endif
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        composerFollowsKeyboard(composerBar.isEditing)
        if deferredSnapshot { renderSnapshot() }
        if hasAppeared { Task { await load() } }
        hasAppeared = true
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        startLiveRefresh()
        #if DEBUG
            DelegateGate.debugOpenIfAsked(from: self)
        #endif
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
        let insert = KeyBridge.shared.insertKeyCommands(action: #selector(handleInsertKeyCommand(_:)))
        return commandPalette.isHidden ? insert : paletteKeyCommands() + insert
    }

    /// Only while the list is up, and only then claiming priority over the system: the arrows have
    /// to keep moving the caret through an ordinary question, Return has to keep sending it, and
    /// escape has to close the list before it gives up the keyboard.
    private func paletteKeyCommands() -> [UIKeyCommand] {
        let bindings: [(String, Selector)] = [
            (UIKeyCommand.inputUpArrow, #selector(paletteSelectPrevious)),
            (UIKeyCommand.inputDownArrow, #selector(paletteSelectNext)),
            ("\t", #selector(paletteSelectNext)),
            ("\r", #selector(paletteAccept)),
            (UIKeyCommand.inputEscape, #selector(paletteDismiss)),
        ]
        var commands = bindings.map { input, action -> UIKeyCommand in
            let command = UIKeyCommand(input: input, modifierFlags: [], action: action)
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
        let back = UIKeyCommand(
            input: "\t", modifierFlags: .shift, action: #selector(paletteSelectPrevious))
        back.wantsPriorityOverSystemBehavior = true
        commands.append(back)
        return commands
    }

    @objc private func paletteSelectNext() { commandPalette.moveSelection(by: 1) }

    @objc private func paletteSelectPrevious() { commandPalette.moveSelection(by: -1) }

    @objc private func paletteAccept() {
        guard commandPalette.activateSelection() else {
            let text = composerBar.currentText
            guard !text.isEmpty else { return }
            Theme.Haptics.send()
            composerSend(text)
            return
        }
    }

    @objc private func paletteDismiss() { hideCommandPalette() }

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
        composerFollowsKeyboard(false)
        hideCommandPalette()
        stopLiveRefresh()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let top = min(composerBar.frame.minY, accessories.frame.minY)
        let overlap = max(0, view.bounds.height - top - view.safeAreaInsets.bottom)
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

        /// Puts the ask lane into a named state so each one can be reviewed without a hand:
        /// `attach` hangs a picture and a file in the strip, `failed` shows a diagnosis with its
        /// remedy above the box.
        private func seedAskForVerification() {
            guard let mode = ProcessInfo.processInfo.environment["TAILSCODE_ASK_STATE"]
            else { return }
            switch mode {
            case "attach":
                let renderer = UIGraphicsImageRenderer(size: CGSize(width: 64, height: 64))
                let png = renderer.image { context in
                    Theme.Color.accent.setFill()
                    context.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
                }.pngData() ?? Data()
                attachments = [
                    PendingAttachment(name: "shelf.png", mime: "image/png", data: png),
                    PendingAttachment(
                        name: "notes.txt", mime: "text/plain",
                        data: Data(repeating: 0x20, count: 2048)),
                ]
                composerBar.setDraft("What is on this shelf?", focus: false)
                refreshAttachments()
            case "failed":
                composerBar.setDraft("What is on this shelf?", focus: false)
                showFailure(
                    NewChatDiagnosis.failure(
                        server: NewChatServer(
                            profileID: "demo", name: composerAim?.profile.name ?? "studio",
                            backend: .claudeCode, address: "100.64.0.1:4098"),
                        directory: nil, error: "Connection refused", witness: .unknown))
            default: break
            }
        }
    #endif

    private func bind() {
        viewModel.onChange = { [weak self] in
            guard let self else { return }
            self.updateComposeButton()
            self.updateComposer()
            self.applySnapshot()
            SessionActivity.shared.wakeHeldQueues(entries: self.viewModel.entries) {
                self.viewModel.backend(forProfileID: $0)
            }
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
            self, selector: #selector(boardDidChange),
            name: QuotaBoardStore.didChange, object: nil)
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
        NotificationCenter.default.addObserver(
            self, selector: #selector(supporterDidChange),
            name: SupporterInvitation.didChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(supporterDidChange),
            name: ProStore.didChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(updateVideoMark),
            name: ForgeRunner.didChange, object: nil)
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

    @objc private func boardDidChange() { applySnapshot() }

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
        if ConnectionController.shared.isDemoMode, !Self.demoBadgeHidden {
            items.append(demoBadge())
        }
        navigationItem.leftBarButtonItems = items
    }

    /// The marketing set is shot in the demo world, and a badge that honestly brands every
    /// screenshot as fake would defeat the set's whole purpose — so the screenshot pipeline may
    /// hide it, and only in DEBUG builds.
    private static let demoBadgeHidden: Bool = {
        #if DEBUG
            return ProcessInfo.processInfo.environment["TAILSCODE_HIDE_DEMO_BADGE"] != nil
        #else
            return false
        #endif
    }()

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
        navigationItem.rightBarButtonItems = [composeItem, videoItem, delegateItem(for: servers)]
    }

    /// The dispatcher's door on Home: one server opens its board outright, more than one asks which
    /// machine first. A free copy meets the Pro sheet with the delegate pitch either way.
    private func delegateItem(for servers: [ConnectionProfile]) -> UIBarButtonItem {
        let image = UIImage(systemName: DelegateEntryPoint.symbol)
        let item: UIBarButtonItem
        if servers.count > 1 {
            let actions = servers.map { profile in
                UIAction(
                    title: profile.name, subtitle: ServerLabel.address(profile),
                    image: UIImage(systemName: profile.backend.symbolName)?
                        .withTintColor(profile.backend.brandColor, renderingMode: .alwaysOriginal)
                ) { [weak self] _ in
                    guard let self else { return }
                    DelegateGate.open(from: self, profile: profile)
                }
            }
            item = UIBarButtonItem(image: image, menu: UIMenu(title: DelegateEntryPoint.menuTitle, children: actions))
        } else {
            item = UIBarButtonItem(
                image: image,
                primaryAction: UIAction { [weak self] _ in
                    guard let self, let profile = servers.first else { return }
                    DelegateGate.open(from: self, profile: profile)
                })
        }
        item.accessibilityLabel = DelegateEntryPoint.title
        return item
    }

    private var lastEnrichment: Date?
    private var isEnriching = false
    private var loadTask: Task<Void, Never>?
    private var liveRefreshTask: Task<Void, Never>?
    private var clockTickTask: Task<Void, Never>?

    /// The last numbers the app landed anywhere — background refresh, silent
    /// push, widget — shared on disk. Painting them first means the usage
    /// section carries real figures from the first frame instead of waiting on a
    /// live fetch and a multi-server scan that between them can take a minute.
    private func seedCachedQuotas() {
        let cached = UsageWidgetStore.cachedQuotas()
        guard !cached.isEmpty else { return }
        quotas = cached
    }

    /// Home is a status board, so it keeps itself current while it is on screen:
    /// a chat started from a terminal, a turn that finishes, an agent that stops
    /// to ask something — all of it lands without a pull. Quick cadence while
    /// anything is live, slow when the board is quiet, and stopped outright when
    /// the screen is off or the app is inactive so nothing polls in the
    /// background.
    /// The board's durations move on their own clock, not on the data poll.
    ///
    /// A card's age is baked into its diffable content, so without something driving a redraw a
    /// running turn's elapsed sat frozen for the ten seconds between listings and then jumped. This
    /// ticks once a second, costs no network, and — because `contentSignature` gates the
    /// reconfigure — repaints only the cards whose text actually changed. It runs only while a card
    /// is genuinely counting: an unreachable host's frozen age has nothing to say every second, and
    /// a board of idle chats has no reason to wake the CPU at all.
    private func startClockTick() {
        guard clockTickTask == nil, viewIfLoaded?.window != nil,
            UIApplication.shared.applicationState == .active
        else { return }
        clockTickTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self, self.viewIfLoaded?.window != nil else { return }
                guard self.hasTickingCard else { continue }
                self.applySnapshot()
            }
        }
    }

    private func stopClockTick() {
        clockTickTask?.cancel()
        clockTickTask = nil
    }

    /// Whether any card on the board is measuring against `now` rather than against a host that
    /// stopped answering. Only these move, so only these are worth a repaint.
    private var hasTickingCard: Bool {
        viewModel.entries.contains {
            isLive($0) && !viewModel.unreachable.contains($0.profileID)
        }
    }

    /// The clock a card drawn from `entry` must measure against: this device's `now` while that
    /// entry's server is answering, and the moment it was last heard from once it is not.
    private func hostClock(for entry: SessionEntry) -> HostClock {
        HostClock(
            isLive: !viewModel.unreachable.contains(entry.profileID),
            observedAt: viewModel.observedAt[entry.profileID])
    }

    private func startLiveRefresh() {
        startClockTick()
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
        stopClockTick()
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
        let live = Set(
            viewModel.entries.filter { $0.session.isWorking }.map(\.session.id)
        ).union(
            SessionActivity.shared.statuses.filter { $0.value != .idle }.map(\.key))
        await NotificationManager.adoptDelivered(
            profileForSession: { owners[$0] }, liveSessionIDs: live)
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
    /// Never restarts work that is already running: launch starts the fetch and `didBecomeActive`
    /// lands a moment later, and cancelling a half-second-old fetch to start the same one again
    /// only makes the board wait longer for the numbers it is already getting.
    private func startEnrichment(force: Bool) {
        guard !isEnriching else { return }
        if !force, let last = lastEnrichment, Date().timeIntervalSince(last) < 90 { return }
        lastEnrichment = Date()
        isEnriching = true
        isFetchingLiveQuotas = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.loadEnrichment()
            self.isEnriching = false
        }
    }

    private func loadEnrichment() async {
        await loadQuotas()
        isFetchingLiveQuotas = false
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
        quotas = fetched
        if let deepseek = UsageWidgetStore.cachedQuotas()
            .first(where: { $0.providerName == DeepSeekBalance.providerName })
        {
            quotas = quotas.filter { $0.providerName != DeepSeekBalance.providerName } + [deepseek]
        }
        if let ollama = UsageWidgetStore.cachedQuotas()
            .first(where: { $0.providerName == OllamaCloud.providerName })
        {
            quotas = quotas.filter { $0.providerName != OllamaCloud.providerName } + [ollama]
        }
        guard !quotas.isEmpty else { return }
        UsageWidgetStore.writeLive(fetched)
        UsageWarnings.evaluate(quotas: fetched)
        if let deepseek = UsageWidgetStore.read()?.providers
            .first(where: { $0.providerName == DeepSeekBalance.providerName })
        {
            UsageWarnings.evaluate(providers: [deepseek])
        }
        if let ollama = UsageWidgetStore.read()?.providers
            .first(where: { $0.providerName == OllamaCloud.providerName })
        {
            UsageWarnings.evaluate(providers: [ollama])
        }
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
        if collectionView.isTracking || collectionView.isDragging || collectionView.isDecelerating
        {
            deferredWhileTouching = true
            return
        }
        scheduledSnapshot = true
        DispatchQueue.main.async { [weak self] in
            guard let self, self.scheduledSnapshot else { return }
            self.scheduledSnapshot = false
            self.renderSnapshot()
        }
    }

    /// The list may reorder itself, but never while a finger is on it: the row pressed must be the
    /// row opened. Everything that arrived during the touch applies the moment it ends.
    private var deferredWhileTouching = false

    private func releaseDeferredSnapshotIfNeeded() {
        guard deferredWhileTouching else { return }
        deferredWhileTouching = false
        applySnapshot()
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { releaseDeferredSnapshotIfNeeded() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        releaseDeferredSnapshotIfNeeded()
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
                    uniqued(
                        down.map { .alert(ServerAlertCard(profileID: $0.id, name: $0.name)) },
                        in: .alerts),
                    toSection: .alerts)
            }
        }
        if SupporterInvitation.isDue(isPro: ProStore.shared.isPro) {
            snapshot.appendSections([.supporter])
            snapshot.appendItems([.supporter(SupporterCard(price: proPrice))], toSection: .supporter)
        }
        let missed = ActivityInbox.ordered(limit: 4).shown
        if !missed.isEmpty {
            snapshot.appendSections([.missed])
            snapshot.appendItems(
                uniqued(missed.map(HomeItem.missed), in: .missed), toSection: .missed)
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
                uniqued(
                    live.map {
                        .live(
                            LiveCard(
                                entry: $0, presence: presence(for: $0),
                                activity: SessionActivity.shared.liveDetail(for: $0.session.id),
                                clock: self.hostClock(for: $0)))
                    }, in: .live),
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
            snapshot.appendItems(
                uniqued(savedCards.map(HomeItem.saved), in: .saved), toSection: .saved)
        }
        let projects = projectCards()
        if !projects.isEmpty {
            snapshot.appendSections([.projects])
            snapshot.appendItems(
                uniqued(projects.map(HomeItem.project), in: .projects), toSection: .projects)
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
                uniqued(
                    recent.map {
                        .recent(
                            RecentCard(
                                entry: $0, unread: isUnread($0.session.id, $0.session.updatedAt)))
                    }, in: .recent),
                toSection: .recent)
        } else if !hasLoadedOnce, !viewModel.servers.isEmpty {
            snapshot.appendSections([.recent])
            snapshot.appendItems((0..<3).map(HomeItem.placeholder), toSection: .recent)
        }
        let board = QuotaBoardStore.current
        let usageCards = quotas
            .filter { !board.isHidden(QuotaBoard.key(providerName: $0.providerName)) }
            .map { QuotaCard(quota: $0) }
        let reserved = reservedUsageCards
        if !usageCards.isEmpty || reserved > 0 {
            snapshot.appendSections([.usage])
            snapshot.appendItems(
                uniqued(usageCards.map(HomeItem.usage), in: .usage), toSection: .usage)
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
        return live ? 1 : 0
    }

    /// What a section may be handed. A diffable snapshot given the same identifier twice does not
    /// draw the row twice — it raises, and the app is gone before the row it was drawing appears.
    /// Every list on this screen is derived from something a server said, so a duplicate is a
    /// server's account of itself changing under a poll rather than a mistake anybody can see
    /// coming; the row is dropped, and the drop is written down with the section that produced it
    /// so the next one names its own cause instead of arriving as a stack trace.
    private func uniqued(_ items: [HomeItem], in section: HomeSection) -> [HomeItem] {
        var seen = Set<HomeItem>()
        var kept: [HomeItem] = []
        for item in items where seen.insert(item).inserted { kept.append(item) }
        if kept.count != items.count {
            AppLogger.ui.error(
                "home: \(items.count - kept.count) duplicate row(s) dropped from \(String(describing: section))"
            )
        }
        return kept
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
        let working = itemCount == 0 && !viewModel.isEmptyOfServers && !hasLoadedOnce
        if !working { collectionView.backgroundView = nil }
        collectionView.showsWork(working)
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
            contentUnavailableConfiguration = nil
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
    ///
    /// The question travels as a decision rather than as words (`QuickAskSend`), because a slash
    /// typed into a surface that has no conversation yet still has to run as a command in the one
    /// it mints. Both roads out of here hand it to the same `deliver`: the chat already on screen
    /// used to be the road that quietly bypassed the grammar.
    @discardableResult
    private func openChat(
        for entry: SessionEntry, seeding choice: ModelChoice? = nil,
        sending question: (send: QuickAskSend, attachments: [PromptAttachment])? = nil
    ) -> ChatViewModel? {
        guard let nav = navigationController else { return nil }
        if let top = nav.topViewController as? ChatViewController, top.sessionID == entry.session.id
        {
            AppLogger.session.info(
                "openChat dedupe session=\(entry.session.id) title=\(entry.session.title)")
            if let question {
                top.deliver(question.send, attachments: question.attachments)
            } else {
                Theme.Haptics.tap()
                top.announceIdentity()
            }
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
        let reused =
            SessionActivity.shared.retainedViewModel(
                for: entry.session.id, contextID: entry.profileID)
        let chatViewModel =
            reused
            ?? ChatViewModel(
                backend: backend, session: entry.session, contextID: entry.profileID,
                serverName: entry.profileName)
        if let choice { chatViewModel.seed(choice) }
        /// A sheet still over the stack is the one animation this movement gets: the chat is
        /// pushed behind it and revealed as it slides away, rather than the two of them taking
        /// turns for the better part of a second.
        let previousTop = (nav.topViewController as? ChatViewController)?.sessionID ?? "-"
        let chat = ChatViewController(viewModel: chatViewModel)
        nav.pushViewController(chat, animated: presentedViewController == nil)
        AppLogger.session.info(
            "openChat push session=\(entry.session.id) title=\(entry.session.title) top=\(previousTop) reused=\(reused != nil)")
        if let question { chat.deliver(question.send, attachments: question.attachments) }
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

    /// One gesture puts the box in the ask lane — the icon's jump list, the Control Center tile,
    /// the keyboard's own verb — and it lands on the box that is already there rather than on a
    /// sheet over it. Anything covering Home is dismissed first, because a question summoned from
    /// outside the app is a question aimed at the field, not at whatever was left open. With no
    /// servers the gesture goes to setup instead of focusing a dead text box.
    func presentQuickAsk() {
        if presentedViewController != nil {
            dismiss(animated: true) { [weak self] in self?.presentQuickAsk() }
            return
        }
        navigationController?.popToViewController(self, animated: true)
        Theme.Haptics.tap()
        guard !viewModel.servers.isEmpty else {
            presentServerSetup()
            return
        }
        setLane(.ask, animated: composerBar.lane != .ask)
        composerBar.focus()
    }

    /// Throwing the switch is a change of destination, so it moves the draft the way re-aiming the
    /// chip does: what is written belongs to the lane it was written in, and each lane hands back
    /// whatever it was left holding.
    private func setLane(_ lane: QuickAskLane, animated: Bool) {
        guard askLane != lane else { return }
        let previous = askLane
        askLane = lane
        composerBar.setLane(lane, animated: animated)
        if previous == .video { composerBar.clearText() }
        if lane == .video {
            if let scope = composerDraftScope {
                DraftStore.record(composerBar.rawText, for: scope)
            }
            composerDraftScope = nil
            composerBar.setText(ForgeRunner.shared.board.recipe.prompt)
        }
        dismissFailure()
        appliedComposerState = nil
        updateComposer()
        updateSuggestions()
        updateCommandPalette(for: lane == .video ? "" : composerBar.currentText)
    }

    /// A render is minutes long and happens on another machine, so the mark on the way in says
    /// one thing only: that something is being made right now. It clears itself when the render
    /// stops, which is why it needs no acknowledgement of its own. The video lane reads the same
    /// snapshots: its chips restate the recipe, and the box follows a draft another surface edited.
    @objc private func updateVideoMark() {
        videoButton.apply(
            rendering: ForgeRunner.shared.isRendering,
            configured: ForgeRunner.shared.endpoint != nil,
            spoken: ForgeRunner.shared.board.job.subtitle)
        guard askLane == .video else { return }
        appliedComposerState = nil
        updateComposer()
        let prompt = ForgeRunner.shared.board.recipe.prompt
        if !composerBar.isEditing, composerBar.rawText != prompt {
            composerBar.setText(prompt)
        }
    }

    @objc func openVideo() {
        Theme.Haptics.tap()
        presentVideo()
    }

    /// A render is a task you start, watch and collect — not a place you work — so the forge opens
    /// over whatever is on screen and closes back to it, with the conversation behind it untouched.
    /// Closing it never stops the render: the job lives in `ForgeRunner`, above every surface that
    /// draws it.
    func presentVideo() {
        let host: UIViewController = navigationController ?? self
        guard host.presentedViewController == nil else {
            host.dismiss(animated: true) { [weak self] in self?.presentVideo() }
            return
        }
        let forge = UINavigationController(rootViewController: VideoForgeViewController())
        forge.navigationBar.prefersLargeTitles = true
        host.present(forge, animated: true)
    }

    func pushUsage() {
        navigationController?.pushViewController(UsageViewController(), animated: true)
    }

    private func configureCollectionView() {
        let layout = UICollectionViewCompositionalLayout { [weak self] index, environment in
            let section: NSCollectionLayoutSection
            if let self, let id = self.dataSource?.sectionIdentifier(for: index) {
                switch id {
                case .live: section = Self.liveSection()
                case .projects: section = Self.projectsSection()
                case .alerts, .supporter: section = Self.listSection(withHeader: false)
                case .missed: section = Self.listSection()
                case .saved, .recent, .usage: section = Self.listSection()
                }
            } else {
                section = Self.listSection()
            }
            if environment.traitCollection.horizontalSizeClass == .regular {
                section.contentInsetsReference = .readableContent
            }
            return section
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

    private var rails: [ReadableRail] = []

    private func configureComposer() {
        composerBar.delegate = self
        composerBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(composerBar)
        composerFloor = composerBar.bottomAnchor.constraint(
            equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        composerRidesKeyboard = composerBar.bottomAnchor.constraint(
            equalTo: view.keyboardLayoutGuide.topAnchor)
        NSLayoutConstraint.activate([composerFloor])
        rails.append(ReadableRail(composerBar, in: view))

        configureAccessories()

        commandPalette.isHidden = true
        commandPalette.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(commandPalette)
        NSLayoutConstraint.activate([
            commandPalette.bottomAnchor.constraint(
                equalTo: accessories.topAnchor, constant: -Theme.Spacing.xs),
            commandPalette.topAnchor.constraint(
                greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor,
                constant: Theme.Spacing.s),
        ])
        rails.append(
            ReadableRail(
                host: view,
                compact: [
                    commandPalette.leadingAnchor.constraint(
                        equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: Theme.Spacing.l),
                    commandPalette.trailingAnchor.constraint(
                        equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -Theme.Spacing.l),
                ],
                regular: [
                    commandPalette.leadingAnchor.constraint(
                        equalTo: view.readableContentGuide.leadingAnchor, constant: Theme.Spacing.l),
                    commandPalette.trailingAnchor.constraint(
                        equalTo: view.readableContentGuide.trailingAnchor, constant: -Theme.Spacing.l),
                ]))
        configureOrb()
    }

    /// The three things that float in the gap between the board and the box, in one stack so they
    /// can never land on top of each other: what failed, what is offered, what is in hand. Each
    /// hides itself, and a stack with nothing in it takes no room at all — the bar's own floor
    /// never moves.
    private func configureAccessories() {
        accessories.axis = .vertical
        accessories.spacing = Theme.Spacing.xs
        accessories.translatesAutoresizingMaskIntoConstraints = false
        failureCard.isHidden = true
        suggestions.isHidden = true
        attachmentStrip.isHidden = true
        videoChips.isHidden = true
        [failureCard, suggestions, videoChips, attachmentStrip].forEach(
            accessories.addArrangedSubview)
        videoChips.onPick = { [weak self] field, id in
            ForgeRunner.shared.pick(field, id: id)
            Theme.Haptics.selection()
        }
        videoChips.onOpen = { [weak self] in
            Theme.Haptics.tap()
            self?.presentVideo()
        }
        view.addSubview(accessories)
        NSLayoutConstraint.activate([
            accessories.bottomAnchor.constraint(
                equalTo: composerBar.topAnchor, constant: -Theme.Spacing.xs),
        ])
        rails.append(ReadableRail(accessories, in: view))
        suggestions.onStarter = { [weak self] starter in self?.pickStarter(starter) }
        suggestions.onRecent = { [weak self] entry in
            Theme.Haptics.tap()
            self?.openChat(for: entry)
        }
        attachmentStrip.onRemove = { [weak self] id in
            guard let self else { return }
            self.attachments.removeAll { $0.id == id }
            Theme.Haptics.tap()
            self.refreshAttachments()
        }
        failureCard.onFix = { [weak self] in self?.applyFix() }
        failureCard.onDismiss = { [weak self] in
            Theme.Haptics.tap()
            self?.dismissFailure()
        }
        enhancement.onStatusChange = { [weak self] status in
            self?.handleEnhancementStatus(status)
        }
        view.addInteraction(UIDropInteraction(delegate: self))
    }

    /// The composer follows the keyboard only while this screen is the one being typed into.
    ///
    /// `keyboardLayoutGuide` tracks the keyboard whether or not its own view controller is on
    /// screen, so a chat popped with its keyboard still up handed Home a guide sitting halfway up
    /// the display — and the docked bar was drawn there, floating in the middle of the screen, for
    /// as long as the dismissal took. Home has exactly one text field, so the rule is simple: the
    /// bar rests at the bottom edge, and takes the keyboard's word for where it goes only from the
    /// moment its own composer starts being typed into until this screen goes away.
    ///
    /// The floor is the safe area's bottom, which is exactly where the keyboard guide rests with
    /// no keyboard up — `usesBottomSafeArea` is on by default, so the guide is not the view's own
    /// bottom edge. Adopting it is therefore a change of authority rather than a change of
    /// position, and the bar neither hops nor spends the first tap climbing out from under the
    /// home indicator.
    private func composerFollowsKeyboard(_ follows: Bool) {
        guard composerRidesKeyboard.isActive != follows else { return }
        if follows {
            composerFloor.isActive = false
            composerRidesKeyboard.isActive = true
        } else {
            composerRidesKeyboard.isActive = false
            composerFloor.isActive = true
        }
    }

    private func configureOrb() {
        orbView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(orbView)
        NSLayoutConstraint.activate([
            orbView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            orbView.bottomAnchor.constraint(equalTo: accessories.topAnchor, constant: -10),
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
        let supporterCell = UICollectionView.CellRegistration<SupporterCell, SupporterCard> {
            [weak self] cell, _, card in
            cell.configure(card)
            cell.onUnlock = { [weak self] in self?.openSupporterOffer() }
            cell.onNotNow = { [weak self] in self?.declineSupporterOffer() }
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
            case .supporter(let card):
                return collectionView.dequeueConfiguredReusableCell(
                    using: supporterCell, for: indexPath, item: card)
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
            case .alerts, .supporter:
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

    func homeComposerDidBeginEditing(_ bar: HomeComposerBar) {
        composerFollowsKeyboard(true)
        updateCommandPalette(for: bar.currentText)
        updateSuggestions()
        enhancement.prewarm()
    }

    func homeComposerTextDidChange(_ text: String) {
        if askLane == .video {
            ForgeRunner.shared.describe(text)
            updateSuggestions()
            return
        }
        updateCommandPalette(for: composerBar.currentText)
        updateSuggestions()
        enhancement.updateInput(composerBar.currentText)
        enhanceOverlay?.requestDismiss()
        guard let scope = composerDraftScope else { return }
        DraftStore.record(text, for: scope)
    }

    /// The bar has already thrown itself; what the lane means is decided here.
    func homeComposerDidToggleLane(_ bar: HomeComposerBar) {
        setLane(bar.lane, animated: false)
    }

    /// Photos and files are different errands, and only the ones this aim can carry out are
    /// offered: a model that cannot see is never handed a photo picker.
    func homeComposerAttachOptions() -> [UIMenuElement] {
        var actions: [UIMenuElement] = []
        if abilities.vision {
            actions.append(
                UIAction(
                    title: String(localized: "Photo Library"),
                    image: UIImage(systemName: "photo.on.rectangle")
                ) { [weak self] _ in self?.presentPhotoPicker() })
        }
        if abilities.camera {
            actions.append(
                UIAction(title: String(localized: "Take Photo"), image: UIImage(systemName: "camera")
                ) { [weak self] _ in self?.presentCamera() })
        }
        if abilities.attachments {
            actions.append(
                UIAction(title: String(localized: "Files"), image: UIImage(systemName: "folder")
                ) { [weak self] _ in self?.presentDocumentPicker() })
        }
        if UIPasteboard.general.hasImages || UIPasteboard.general.hasStrings {
            actions.append(
                UIAction(
                    title: String(localized: "Paste"),
                    image: UIImage(systemName: "doc.on.clipboard")
                ) { [weak self] _ in self?.pasteFromClipboard() })
        }
        return actions
    }

    /// A screenshot in hand is the commonest thing a phone has to show an agent, so pasting one
    /// attaches it rather than doing nothing at all.
    func homeComposerDidPasteImage(_ data: Data, mime: String) {
        guard abilities.vision else {
            toast(String(localized: "This model can't read pictures."))
            return
        }
        pastedImageCount += 1
        attach(data: data, name: "pasted-\(pastedImageCount).png", mime: mime)
    }

    /// A paste too large to read as a sentence becomes the file it already is, so the question
    /// stays a question and the wall of text rides beside it.
    func homeComposerDidPasteLargeText(_ text: String) {
        guard abilities.attachments, let data = text.data(using: .utf8) else {
            composerBar.insertText(text)
            return
        }
        composerBar.deleteSelection()
        attach(data: data, name: "pasted-\(UUID().uuidString.prefix(8)).txt", mime: "text/plain")
        toast(
            String(
                localized: "Attached \(text.count.formatted()) characters — sent with the message."))
    }

    /// Holding Send raises the on-device enhancement deck for words worth sharpening — the same
    /// gesture the chat's composer answers, because the front door is exactly where a vague
    /// sentence costs a whole round trip.
    func homeComposerDidLongPressSend(from view: UIView) {
        let text = composerBar.currentText
        guard !text.isEmpty else { return }
        enhancement.requestNow(for: text)
        presentEnhanceOverlay(original: text)
    }

    /// What the aimed machine can be told to do, read from memory first and corrected by the
    /// machine afterwards. Fetched with no directory even when the composer is aimed at a project:
    /// the catalog answers what this server knows, and the words that read a transcript are dropped
    /// because the conversation this send mints has none.
    private func loadCommandsIfNeeded(for profile: ConnectionProfile) {
        guard catalogProfileID != profile.id else { return }
        catalogProfileID = profile.id
        commands = CommandCatalogStore.forQuickAsk(CommandCatalogStore.cached(profile.id))
        updateCommandPalette(for: composerBar.currentText)
        guard let backend = viewModel.backend(forProfileID: profile.id),
            backend.capabilities.supportsCommands
        else {
            commands = []
            hideCommandPalette()
            return
        }
        Task { [weak self] in
            let fetched = await CommandCatalogStore.refresh(
                profileID: profile.id, backend: backend)
            guard let self, self.catalogProfileID == profile.id else { return }
            self.commands = CommandCatalogStore.forQuickAsk(fetched)
            self.updateCommandPalette(for: self.composerBar.currentText)
        }
    }

    /// The same reading the chat composer answers, drawn in the same list: candidates while the
    /// command is being named, that one command's signature once it is settled, and a word the
    /// catalog lacks said out loud rather than left to vanish under the caret.
    private func updateCommandPalette(for text: String) {
        guard composerBar.isEditing, !composerBar.isHidden else { return hideCommandPalette() }
        switch SlashPresentation.of(
            text: text, commands: commands, recents: SlashRecents.surviving(in: commands))
        {
        case .hidden:
            hideCommandPalette()
        case .naming(let matches):
            commandPalette.update(
                with: .commands([
                    SlashCommandSection(
                        title: "",
                        commands: matches.map { paletteRow(for: $0.command, highlight: $0.highlight) })
                ]))
            showCommandPalette()
        case .arguments(let command, let typed):
            commandPalette.update(
                with: .arguments(command: paletteRow(for: command), typed: typed))
            showCommandPalette()
        case .noMatch(let query):
            commandPalette.update(
                with: .noMatch(
                    wording: SlashPresentation.noMatchWording("/\(query)", hasProject: false),
                    browse: nil))
            showCommandPalette()
        }
    }

    private func paletteRow(for command: AgentCommand, highlight: [Int] = []) -> SlashCommand {
        SlashCommand(
            id: "server:\(command.name)",
            keywords: [command.name.lowercased()],
            title: "/\(command.name)",
            subtitle: command.details,
            symbol: CommandSymbol.of(command),
            highlight: highlight.map { $0 + 1 },
            argumentHint: command.argumentHint,
            badge: command.scope,
            runsOnServer: true
        ) { [weak self] in self?.selectCommand(command) }
    }

    private func selectCommand(_ command: AgentCommand) {
        Theme.Haptics.selection()
        hideCommandPalette()
        composerBar.setText(command.takesArguments ? "/\(command.name) " : "/\(command.name)")
        composerBar.focus()
    }

    private func showCommandPalette() {
        guard commandPalette.isHidden else { return }
        commandPalette.alpha = 0
        commandPalette.isHidden = false
        UIView.animate(withDuration: 0.18) { self.commandPalette.alpha = 1 }
        updateSuggestions()
    }

    private func hideCommandPalette() {
        guard !commandPalette.isHidden else { return }
        UIView.animate(
            withDuration: 0.15, animations: { self.commandPalette.alpha = 0 },
            completion: { _ in
                self.commandPalette.isHidden = true
                self.updateSuggestions()
            })
    }

    /// Home's composer has no session to belong to, so what is written in it belongs to where it
    /// is aimed: re-aiming the chip — or throwing the lane switch — stashes the text under the
    /// destination it was written for and hands back whatever was left unsent for the new one, the
    /// way switching chats does in a pane.
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

    /// Everything the lane decides, resolved in one place. The chat lane goes to a project the
    /// person keeps aimed; the ask lane goes to the machine the last question went to, falling back
    /// to whatever the composer was already pointed at rather than to an arbitrary server.
    var composerAim: ComposerAim? {
        switch askLane {
        case .video:
            return nil
        case .chat:
            guard let target = composeTarget,
                let profile = viewModel.servers.first(where: { $0.id == target.profileID })
            else { return nil }
            return ComposerAim(
                lane: .chat, profile: profile, directory: target.directory,
                memoryKey: profile.id, resolutionContext: nil,
                draftScope: .home(profileID: profile.id, directory: target.directory))
        case .ask:
            guard
                let id = QuickAskDefaults.target(
                    among: viewModel.servers.map(\.id), fallback: composeTarget?.profileID),
                let profile = viewModel.servers.first(where: { $0.id == id })
            else { return nil }
            return ComposerAim(
                lane: .ask, profile: profile, directory: nil,
                memoryKey: QuickAskDefaults.contextID(forProfileID: profile.id),
                resolutionContext: QuickAskDefaults.aimContext(forProfileID: profile.id),
                draftScope: .quickAsk(profileID: profile.id))
        }
    }

    /// Reapplies only when something the user can see actually changed: the live
    /// refresh runs this every few seconds, and reassigning a button's menu
    /// underneath an open one is exactly the kind of churn that makes a picker
    /// flicker shut mid-choice. Both menus resolve their contents when opened,
    /// so skipping the rebuild can't serve a stale list.
    private func updateComposer() {
        composerBar.isHidden = viewModel.servers.isEmpty && askLane != .video
        if askLane == .video {
            updateVideoComposer()
            return
        }
        guard let aim = composerAim else {
            updateSuggestions()
            return
        }
        syncComposerDraft(to: aim.draftScope)
        loadCommandsIfNeeded(for: aim.profile)
        let title = composerChipTitle(for: aim)
        let modelLabel = modelChipLabel(for: aim)
        composerBar.ultracodeEffort =
            modelChoices[aim.memoryKey]?.effort
            ?? EffortPreferenceStore.globalEffort(
                forContextID: aim.resolutionContext ?? aim.profile.id)
        let state = [
            aim.lane.rawValue, aim.profile.id, aim.directory ?? "", title, modelLabel ?? "",
        ].joined(separator: "|")
        guard state != appliedComposerState else { return }
        appliedComposerState = state
        let icon = UIImage(
            systemName: aim.profile.backend.symbolName,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))?
            .withTintColor(aim.profile.backend.brandColor, renderingMode: .alwaysOriginal)
        composerBar.setContext(icon: icon, title: title, menu: composerTargetMenu(for: aim))
        updateModelChip(for: aim, label: modelLabel)
        refreshAbilities(for: aim)
        updateSuggestions()
        view.setNeedsLayout()
    }

    /// The video lane's chrome: the destination chip names the renderer the way the chat lane
    /// names its project — or says none is set up and opens the setup — the model chip has nothing
    /// to say, the paperclip is not offered, and the walkable settings ride as chips under the box.
    private func updateVideoComposer() {
        let board = ForgeRunner.shared.board
        let configured = ForgeRunner.shared.endpoint != nil
        composerBar.setModel(title: nil, menu: nil)
        composerBar.showsAttach = false
        composerBar.ultracodeEffort = nil
        let title = board.value(of: .endpoint)
        let state = ["video", title, "\(configured)"].joined(separator: "|")
        if state != appliedComposerState {
            appliedComposerState = state
            let icon = UIImage(
                systemName: configured ? "desktopcomputer" : "desktopcomputer.trianglebadge.exclamationmark",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))?
                .withTintColor(
                    configured ? Theme.Color.accent : Theme.Color.warning,
                    renderingMode: .alwaysOriginal)
            composerBar.setContext(icon: icon, title: title, menu: videoTargetMenu())
        }
        videoChips.update(board: board)
        updateSuggestions()
        view.setNeedsLayout()
    }

    private func videoTargetMenu() -> UIMenu {
        UIMenu(children: [
            UIAction(
                title: ForgeSurface.title, image: UIImage(systemName: ForgeEntryPoint.symbol)
            ) { [weak self] _ in self?.presentVideo() },
            UIAction(
                title: ForgeSetup.title, image: UIImage(systemName: "desktopcomputer")
            ) { [weak self] _ in self?.presentRendererSetup() },
        ])
    }

    private func presentRendererSetup() {
        Theme.Haptics.tap()
        let nav = UINavigationController(rootViewController: ForgeSetupViewController())
        nav.navigationBar.prefersLargeTitles = true
        present(nav, animated: true)
    }

    /// Sending from the video lane is the forge's own begin: a configured renderer starts the
    /// render and the surface opens over the work so the first seconds of waiting are watched; a
    /// missing one opens the same surface leading with its setup instead of failing the send. A
    /// render already out is never cancelled by a send — the surface simply opens on it.
    private func renderSend(_ text: String) {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        let runner = ForgeRunner.shared
        runner.describe(words)
        if let action = runner.begin(), case .render(let recipe) = action {
            Theme.Haptics.send()
            runner.render(recipe)
        }
        view.endEditing(true)
        presentVideo()
    }

    /// A chat names the project it will live in; a question has none to name, so the chip says
    /// only which machine is being asked rather than inventing a place for the answer to live.
    private func composerChipTitle(for aim: ComposerAim) -> String {
        guard aim.lane == .chat, let directory = aim.directory else { return aim.profile.name }
        return "\((directory as NSString).lastPathComponent) · \(aim.profile.name)"
    }

    /// The chip names the model the next message will actually run on — resolved
    /// exactly the way the chat screen resolves it — so starting a chat is never
    /// a blind commitment to whatever the server happens to default to. Nil for
    /// a backend that has neither model nor effort control, which then shows no
    /// chip at all.
    private func modelChipLabel(for aim: ComposerAim) -> String? {
        guard let backend = viewModel.backend(forProfileID: aim.profile.id),
            backend.capabilities.supportsModelSelection
                || backend.capabilities.supportsReasoningEffort
        else { return nil }
        let choice = modelChoices[aim.memoryKey] ?? ModelChoice()
        return ModelBadge.label(model: choice.model, effort: choice.effort)
    }

    private func updateModelChip(for aim: ComposerAim, label: String?) {
        guard let label, let backend = viewModel.backend(forProfileID: aim.profile.id) else {
            composerBar.setModel(title: nil, menu: nil)
            return
        }
        composerBar.setModel(title: label, menu: modelMenu(for: aim, backend: backend))
        resolveModelChoiceIfNeeded(for: aim, backend: backend)
    }

    private func resolveModelChoiceIfNeeded(for aim: ComposerAim, backend: any CodingAgentBackend) {
        guard modelChoices[aim.memoryKey] == nil,
            resolvingModels.insert(aim.memoryKey).inserted
        else { return }
        Task { @MainActor in
            let choice = await ChatModelResolver.choice(
                profileID: aim.profile.id, backend: backend, contextID: aim.resolutionContext)
            resolvingModels.remove(aim.memoryKey)
            modelChoices[aim.memoryKey] = choice
            updateComposer()
        }
    }

    /// Built lazily on every present: the catalog may still be in flight when
    /// the chip is first drawn, and a menu opened a second later must show the
    /// models rather than the placeholder it was built with.
    private func modelMenu(for aim: ComposerAim, backend: any CodingAgentBackend) -> UIMenu {
        UIMenu(
            title: String(localized: "Model"),
            children: [
                UIDeferredMenuElement.uncached { [weak self] completion in
                    Task { @MainActor in
                        guard let self else { return completion([]) }
                        let models =
                            backend.capabilities.supportsModelSelection
                            ? await ModelCatalog.models(for: aim.profile.id, backend: backend) : []
                        var elements = ModelMenu.elements(
                            sources: ModelFleet.sources(
                                profiles: ConnectionController.shared.profiles,
                                current: aim.profile.id, currentModels: models,
                                allowsServerDefault: ChatModelResolver.honoursServerDefault(backend)),
                            choice: self.modelChoices[aim.memoryKey] ?? ModelChoice(),
                            efforts: backend.reasoningEffortOptions,
                            allowsServerDefault: ChatModelResolver.honoursServerDefault(backend),
                            quotas: QuotaSurface.relevantQuotas(
                                for: backend.agentType, among: UsageWidgetStore.cachedQuotas()),
                            actions: ModelMenu.Actions(
                                selectModel: { [weak self] selection in
                                    self?.setComposeModel(selection, for: aim)
                                },
                                selectEffort: { [weak self] level in
                                    self?.setComposeEffort(level, for: aim)
                                },
                                browseAll: { [weak self] in
                                    self?.presentComposeModelPicker(
                                        aim: aim, backend: backend, models: models)
                                }))
                        if let follow = self.followServerElement(for: aim) {
                            elements.append(follow)
                        }
                        completion(elements)
                    }
                }
            ])
    }

    /// The ask lane's aim is its own once it has been set by hand, which is the whole point of it
    /// — and the way back is one row rather than a settings screen.
    private func followServerElement(for aim: ComposerAim) -> UIMenuElement? {
        guard aim.lane == .ask, QuickAskDefaults.hasOwnAim(forProfileID: aim.profile.id) else {
            return nil
        }
        return UIMenu(
            options: .displayInline,
            children: [
                UIAction(
                    title: String(localized: "Follow this server"),
                    subtitle: String(localized: "Use what a new chat here would"),
                    image: UIImage(systemName: "arrow.uturn.backward")
                ) { [weak self] _ in
                    guard let self else { return }
                    QuickAskDefaults.clearOwnAim(forProfileID: aim.profile.id)
                    self.modelChoices[aim.memoryKey] = nil
                    self.appliedComposerState = nil
                    self.updateComposer()
                }
            ])
    }

    /// A pick in the ask lane claims that lane's own memory and leaves the server's exactly as it
    /// was: pointing lookups at something cheap may never re-aim the project chats.
    private func setComposeModel(_ selection: ModelSelection?, for aim: ComposerAim) {
        let backend = viewModel.backend(forProfileID: aim.profile.id)
        let models = ModelCatalog.cached(for: aim.profile.id)
        let agentOptions = backend?.reasoningEffortOptions ?? []
        switch aim.lane {
        case .chat:
            ModelPreferenceStore.recordPick(selection, sessionKey: nil, contextID: aim.profile.id)
            if selection == nil {
                modelChoices[aim.memoryKey] = nil
            } else {
                var choice = modelChoices[aim.memoryKey] ?? ModelChoice()
                choice.model = selection
                let kept = ModelEffort.adopt(
                    choice.effort, for: selection, models: models, agentOptions: agentOptions)
                if kept != choice.effort {
                    choice.effort = kept
                    EffortPreferenceStore.recordPick(
                        kept, sessionKey: nil, contextID: aim.profile.id)
                }
                modelChoices[aim.memoryKey] = choice
            }
        case .video:
            assertionFailure("the video lane has no ComposerAim")
        case .ask:
            QuickAskDefaults.recordModel(selection, forProfileID: aim.profile.id)
            var choice = modelChoices[aim.memoryKey] ?? ModelChoice()
            choice.model = selection
            let kept = ModelEffort.adopt(
                choice.effort, for: selection, models: models, agentOptions: agentOptions)
            if kept != choice.effort {
                choice.effort = kept
                QuickAskDefaults.recordEffort(kept, forProfileID: aim.profile.id)
            }
            modelChoices[aim.memoryKey] = choice
        }
        Theme.Haptics.selection()
        appliedComposerState = nil
        updateComposer()
    }

    private func setComposeEffort(_ level: String?, for aim: ComposerAim) {
        switch aim.lane {
        case .chat:
            EffortPreferenceStore.recordPick(level, sessionKey: nil, contextID: aim.profile.id)
        case .ask:
            QuickAskDefaults.recordEffort(level, forProfileID: aim.profile.id)
        case .video:
            assertionFailure("the video lane has no ComposerAim")
        }
        var choice = modelChoices[aim.memoryKey] ?? ModelChoice()
        choice.effort = level
        modelChoices[aim.memoryKey] = choice
        Theme.Haptics.selection()
        appliedComposerState = nil
        updateComposer()
    }

    private func presentComposeModelPicker(
        aim: ComposerAim, backend: any CodingAgentBackend, models: [ModelInfo]
    ) {
        guard !models.isEmpty else { return }
        Theme.Haptics.tap()
        let profile = aim.profile
        let picker = ModelPickerViewController(
            sources: ModelFleet.sources(
                profiles: ConnectionController.shared.profiles, current: profile.id,
                currentModels: models, allowsServerDefault: profile.backend == .claudeCode),
            selected: modelChoices[aim.memoryKey]?.model,
            quotas: QuotaSurface.relevantQuotas(
                for: profile.backend, among: UsageWidgetStore.cachedQuotas())
        ) { [weak self] pick in
            guard let self else { return }
            guard pick.isElsewhere else {
                self.setComposeModel(pick.selection, for: aim)
                return
            }
            switch aim.lane {
            case .chat:
                ModelFleet.adopt(pick)
                self.aimCompose(at: pick.profileID)
            case .ask:
                QuickAskDefaults.adopt(pick)
                self.aimAsk(at: pick.profileID)
            case .video:
                assertionFailure("the video lane has no ComposerAim")
            }
        }
        let nav = UINavigationController(rootViewController: picker)
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(nav, animated: true)
        let contextID = profile.id
        let allowsServerDefault = profile.backend == .claudeCode
        let sources = { (models: [ModelInfo]) in
            ModelFleet.sources(
                profiles: ConnectionController.shared.profiles, current: contextID,
                currentModels: models, allowsServerDefault: allowsServerDefault)
        }
        let watch = PickerCatalogWatch.keep(
            picker: picker, profileID: contextID, backend: backend, sources: sources)
        picker.onClose = { watch.cancel() }
        Task { @MainActor in
            let fresh = await ModelCatalog.fresh(for: contextID, backend: backend)
            picker.update(sources: sources(fresh))
        }
    }

    private func composerTargetMenu(for aim: ComposerAim) -> UIMenu {
        switch aim.lane {
        case .chat:
            return UIMenu(
                title: String(localized: "Start the chat in…"),
                children: [
                    UIDeferredMenuElement.uncached { [weak self] completion in
                        completion(self?.composeTargets() ?? [])
                    }
                ])
        case .ask:
            return UIMenu(
                title: String(localized: "Ask on"),
                children: [
                    UIDeferredMenuElement.uncached { [weak self] completion in
                        completion(self?.askTargets() ?? [])
                    }
                ])
        case .video:
            return videoTargetMenu()
        }
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

    /// A question carries no project, so the ask lane's chip offers machines and nothing else.
    private func askTargets() -> [UIMenuElement] {
        let current = composerAim?.profile.id
        return viewModel.servers.map { profile in
            UIAction(
                title: profile.name, subtitle: profile.backend.displayName,
                image: UIImage(systemName: profile.backend.symbolName),
                state: profile.id == current ? .on : .off
            ) { [weak self] _ in self?.aimAsk(at: profile.id) }
        }
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
        setLane(.chat, animated: true)
        appliedComposerState = nil
        updateComposer()
    }

    /// Moving the question to another machine takes the draft with it: what is typed belongs to
    /// the question, not to the server it was pointed at a second ago, and the words already filed
    /// under the machine being left stay there for the next time it is aimed at.
    private func aimAsk(at profileID: String) {
        guard profileID != composerAim?.profile.id else { return }
        QuickAskDefaults.record(profileID: profileID)
        Theme.Haptics.selection()
        appliedComposerState = nil
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

    /// What the words turn out to be, asked of the shared grammar before anything is minted: a
    /// command the aimed machine knows runs as a command in the conversation this send creates, and
    /// everything else — including a word on a server that reads its own slashes out of the prompt
    /// — goes as the words that were written.
    private func composerDecision(_ text: String, on profile: ConnectionProfile) -> QuickAskSend {
        guard let backend = viewModel.backend(forProfileID: profile.id),
            backend.capabilities.supportsCommands
        else { return QuickAskSend(text: text, kind: .prompt) }
        return QuickAskSend.decide(
            text: text, commands: commands,
            resolvesFromPromptText: backend.resolvesCommandsFromPromptText)
    }

    /// The session is created only now, on commit; the box keeps the words and whatever is in its
    /// strip until the create succeeds, so a dead server loses nothing.
    private func composerSend(_ text: String) {
        if askLane == .video { return renderSend(text) }
        guard let aim = composerAim,
            QuickAskComposition.canSend(text: text, attachments: attachments.count)
        else { return }
        let send = composerDecision(text, on: aim.profile)
        if case .command(let command, _) = send.kind { SlashRecents.record(command.name) }
        hideCommandPalette()
        dismissFailure()
        mint(aim: aim, send: send)
    }

    private func mint(aim: ComposerAim, send: QuickAskSend) {
        lastAttempt = (aim, send)
        composerBar.setSending(true)
        Task { [weak self] in
            guard let self else { return }
            let result = await self.viewModel.createSession(
                on: aim.profile, directory: aim.directory)
            self.composerBar.setSending(false)
            switch result {
            case .success(let entry):
                self.landed(entry, aim: aim, send: send)
            case .failure(let failure):
                Theme.Haptics.error()
                self.composerBar.setText(send.text)
                DraftStore.record(send.text, for: aim.draftScope)
                self.showFailure(failure)
            }
        }
    }

    /// The handover is one movement: the conversation is opened with the words and whatever rode
    /// with them already on their way, and the box is emptied only once the machine has agreed to
    /// hold them.
    private func landed(_ entry: SessionEntry, aim: ComposerAim, send: QuickAskSend) {
        switch aim.lane {
        case .chat:
            if let directory = aim.directory {
                FileBrowserRecents.record(directory, for: aim.profile.id)
            }
            AppPreferences.lastComposeTarget = (aim.profile.id, aim.directory)
        case .ask:
            QuickAskDefaults.record(profileID: aim.profile.id)
            QuickAskDefaults.stamp(profileID: aim.profile.id, sessionID: entry.session.id)
        case .video:
            assertionFailure("the video lane has no ComposerAim")
        }
        let payload = attachments.map(\.prompt)
        attachments = []
        refreshAttachments()
        composerBar.clearText()
        DraftStore.clear(aim.draftScope)
        view.endEditing(true)
        Theme.Haptics.success()
        openChat(
            for: entry, seeding: modelChoices[aim.memoryKey],
            sending: (send: send, attachments: payload))
    }
}

/// The ask lane's own furniture: what it offers while it is empty, what it can be handed, and what
/// it says when the machine on the other end refuses to mint a conversation.
extension HomeViewController {
    /// The strip is the lane's empty state and nothing more: the moment there is a question — or
    /// something in hand, or a command being named — it gets out of the way, and it comes back if
    /// the box is emptied again.
    private var wantsSuggestions: Bool {
        askLane == .ask && !composerBar.isHidden && composerBar.currentText.isEmpty
            && attachments.isEmpty && commandPalette.isHidden
    }

    func updateSuggestions() {
        setAccessory(videoChips, visible: askLane == .video && !composerBar.isHidden)
        guard wantsSuggestions else { return setAccessory(suggestions, visible: false) }
        if let aim = composerAim {
            suggestions.update(
                starters: QuickAskStarters.offered(for: abilities),
                recents: QuickAskRecents.asks(among: viewModel.entries, profileID: aim.profile.id),
                note: nil)
        } else {
            suggestions.update(starters: [], recents: [], note: QuickAskWords.noServers)
        }
        setAccessory(suggestions, visible: true)
    }

    /// A starter is the first half of a sentence, never a question the app asked on somebody's
    /// behalf: the words land in the box with the caret at their end, and a row that needs a
    /// picture or a file opens the picker for it in the same touch.
    func pickStarter(_ starter: QuickAskStarter) {
        Theme.Haptics.tap()
        QuickAskStarterRecents.record(starter.id)
        if composerBar.currentText.isEmpty {
            composerBar.setDraft(starter.prompt, focus: true)
        } else {
            composerBar.focus()
        }
        switch starter.opens {
        case .none: break
        case .photos: presentPhotoPicker()
        case .camera: presentCamera()
        case .files: presentDocumentPicker()
        }
    }

    private func setAccessory(_ view: UIView, visible: Bool) {
        guard view.isHidden == visible else { return }
        UIView.animate(withDuration: 0.2) {
            view.isHidden = !visible
            view.alpha = visible ? 1 : 0
            self.accessories.layoutIfNeeded()
        }
    }

    /// What the aim can be handed, re-read whenever either half of it moves. A picture already in
    /// the strip that the new model cannot read is dropped out loud rather than carried to a send
    /// the other machine would refuse.
    func refreshAbilities(for aim: ComposerAim) {
        let backend = viewModel.backend(forProfileID: aim.profile.id)
        abilities = ModelAbilities.resolve(
            supportsAttachments: backend?.capabilities.supportsAttachments ?? false,
            model: modelCapabilities(for: aim),
            camera: UIImagePickerController.isSourceTypeAvailable(.camera))
        composerBar.showsAttach = abilities.attachments
        let kept = attachments.filter { abilities.accepts(mime: $0.mime) }
        let dropped = attachments.count - kept.count
        if dropped > 0 {
            attachments = kept
            toast(QuickAskComposition.droppedNotice(count: dropped))
        }
        refreshAttachments()
    }

    private func modelCapabilities(for aim: ComposerAim) -> ModelCapabilities? {
        guard let selection = modelChoices[aim.memoryKey]?.model else { return nil }
        return ModelCatalog.cached(for: aim.profile.id).first {
            $0.providerID == selection.providerID && $0.id == selection.modelID
        }?.capabilities
    }

    func refreshAttachments() {
        attachmentStrip.update(attachments)
        composerBar.carriesAttachments = !attachments.isEmpty
        setAccessory(attachmentStrip, visible: !attachments.isEmpty)
        updateSuggestions()
    }

    func attach(_ attachment: PendingAttachment) {
        guard abilities.accepts(mime: attachment.mime) else {
            toast(String(localized: "This model can't read \(attachment.name)."))
            return
        }
        attachments.append(attachment)
        Theme.Haptics.success()
        refreshAttachments()
    }

    func attach(data: Data, name: String, mime: String) {
        guard data.count <= AttachmentIntake.byteCap else {
            toast(
                String(
                    localized:
                        "\(name) is \(AttachmentIntake.sizeText(data.count)) — the cap is 8 MB."))
            return
        }
        attach(PendingAttachment(name: name, mime: mime, data: data))
    }

    func presentPhotoPicker() {
        Theme.Haptics.tap()
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 5
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    func presentCamera() {
        guard UIImagePickerController.isSourceTypeAvailable(.camera) else { return }
        Theme.Haptics.tap()
        let picker = UIImagePickerController()
        picker.sourceType = .camera
        picker.delegate = self
        present(picker, animated: true)
    }

    func presentDocumentPicker() {
        Theme.Haptics.tap()
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = true
        present(picker, animated: true)
    }

    /// The pasteboard, taken for what it is holding: a picture becomes an attachment, words go
    /// into the box where the caret is.
    func pasteFromClipboard() {
        let pasteboard = UIPasteboard.general
        if pasteboard.hasImages, abilities.vision {
            guard let image = pasteboard.image, let data = image.pngData() else {
                toast(String(localized: "The clipboard holds no picture."))
                return
            }
            pastedImageCount += 1
            attach(data: data, name: "pasted-\(pastedImageCount).png", mime: "image/png")
            return
        }
        guard let text = pasteboard.string, !text.isEmpty else {
            toast(String(localized: "The clipboard holds nothing to send."))
            return
        }
        composerBar.insertText(text)
    }

    func toast(_ message: String) {
        ToastView(message: message).flash(in: view, above: composerBar.topAnchor)
    }

    func showFailure(_ failure: NewChatFailure) {
        lastFailure = failure
        failureCard.show(failure)
        setAccessory(failureCard, visible: true)
        UIAccessibility.post(notification: .announcement, argument: failure.spoken)
    }

    func dismissFailure() {
        guard lastFailure != nil else { return }
        lastFailure = nil
        setAccessory(failureCard, visible: false)
    }

    /// The remedy, applied and the send retried on the spot — somebody who tapped "Use :4098"
    /// asked for an answer, not for a settings screen.
    func applyFix() {
        guard let failure = lastFailure else { return }
        Theme.Haptics.tap()
        dismissFailure()
        switch failure.fix {
        case .none:
            break
        case .retry:
            guard let attempt = lastAttempt else { return }
            mint(aim: attempt.aim, send: attempt.send)
        case .editServer(let profileID):
            guard let profile = viewModel.servers.first(where: { $0.id == profileID }) else {
                return
            }
            let editor = ServerEditViewController(profile: profile)
            editor.onSaved = { [weak self] _ in
                guard let self else { return }
                self.viewModel.refreshSources()
                self.dismiss(animated: true) { self.retryLastAttempt() }
            }
            present(UINavigationController(rootViewController: editor), animated: true)
        case .repoint(let profileID, let url, _):
            guard var profile = viewModel.servers.first(where: { $0.id == profileID }) else {
                return
            }
            let password = ConnectionController.shared.password(for: profile.id)
            profile.baseURL = url
            do {
                try ConnectionController.shared.save(profile, password: password)
                viewModel.refreshSources()
                retryLastAttempt()
            } catch {
                showFailure(
                    NewChatDiagnosis.failure(
                        server: NewChatServer(
                            profileID: profile.id, name: profile.name, backend: profile.backend,
                            address: ServerLabel.address(profile)),
                        directory: nil, error: AgentErrorText.readable(error), witness: .unknown))
            }
        }
    }

    /// The aim is re-read rather than replayed: a fix that changed the server changed the profile
    /// the attempt was holding, and minting against the stale one would fail the same way twice.
    private func retryLastAttempt() {
        guard let attempt = lastAttempt, let aim = composerAim else { return }
        mint(aim: aim, send: attempt.send)
    }

    private func presentEnhanceOverlay(original: String) {
        enhanceOverlay?.removeFromSuperview()
        let overlay = PromptEnhanceOverlay()
        overlay.delegate = self
        overlay.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: view.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: composerBar.topAnchor),
        ])
        enhanceOverlay = overlay
        overlay.render(enhancement.status, original: original)
        view.layoutIfNeeded()
        let anchor = composerBar.sendControlAnchor
        let origin = anchor.convert(
            CGPoint(x: anchor.bounds.midX, y: anchor.bounds.midY), to: overlay)
        overlay.animateIn(fromButtonCenter: origin)
    }

    func handleEnhancementStatus(_ status: PromptEnhancementController.Status) {
        composerBar.setEnhanceHint(enhancement.hasFreshSuggestions)
        enhanceOverlay?.render(status, original: enhancement.latestInput)
    }
}

extension HomeViewController: PromptEnhanceOverlayDelegate {
    func enhanceOverlay(_ overlay: PromptEnhanceOverlay, didChoose prompt: EnhancedPrompt) {
        Theme.Haptics.success()
        composerBar.setDraft(prompt.text, focus: true)
        overlay.requestDismiss()
    }

    func enhanceOverlay(_ overlay: PromptEnhanceOverlay, didCopy prompt: EnhancedPrompt) {
        UIPasteboard.general.string = prompt.text
        Theme.Haptics.success()
        toast(String(localized: "Enhanced prompt copied."))
    }

    func enhanceOverlayDidRequestRetry(_ overlay: PromptEnhanceOverlay) {
        Theme.Haptics.tap()
        enhancement.retry()
    }

    func enhanceOverlayDidDismiss(_ overlay: PromptEnhanceOverlay) {
        if enhanceOverlay === overlay { enhanceOverlay = nil }
        composerBar.setEnhanceHint(enhancement.hasFreshSuggestions)
    }
}

extension HomeViewController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        for result in results {
            let provider = result.itemProvider
            let name = provider.suggestedName
            provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) {
                [weak self] data, _ in
                guard let data else { return }
                let kind = ImageBytes.kind(of: data)
                Task { @MainActor in
                    self?.attach(
                        data: data,
                        name: "\(name ?? "image-\(UUID().uuidString.prefix(8))").\(kind.ext)",
                        mime: kind.mime)
                }
            }
        }
    }
}

extension HomeViewController: UIImagePickerControllerDelegate, UINavigationControllerDelegate {
    func imagePickerController(
        _ picker: UIImagePickerController,
        didFinishPickingMediaWithInfo info: [UIImagePickerController.InfoKey: Any]
    ) {
        picker.dismiss(animated: true)
        guard let image = info[.originalImage] as? UIImage,
            let data = image.jpegData(compressionQuality: 0.9)
        else { return }
        pastedImageCount += 1
        attach(data: data, name: "photo-\(pastedImageCount).jpg", mime: "image/jpeg")
    }

    func imagePickerControllerDidCancel(_ picker: UIImagePickerController) {
        picker.dismiss(animated: true)
    }
}

extension HomeViewController: UIDocumentPickerDelegate {
    func documentPicker(
        _ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]
    ) {
        for url in urls {
            switch AttachmentIntake.read(path: url.path) {
            case .success(let attachment): attach(attachment)
            case .failure(let refusal): toast(refusal.message)
            }
        }
    }
}

/// A picture dragged onto the front door is a question about that picture: the drop is taken where
/// it lands, on any part of the screen, because aiming at a 32-point paperclip with something held
/// in the other hand is not a gesture anybody should have to make.
extension HomeViewController: UIDropInteractionDelegate {
    func dropInteraction(_ interaction: UIDropInteraction, canHandle session: UIDropSession) -> Bool
    {
        abilities.attachments && !composerBar.isHidden
    }

    func dropInteraction(
        _ interaction: UIDropInteraction, sessionDidUpdate session: UIDropSession
    ) -> UIDropProposal {
        UIDropProposal(operation: .copy)
    }

    func dropInteraction(_ interaction: UIDropInteraction, performDrop session: UIDropSession) {
        for item in session.items {
            let provider = item.itemProvider
            let name = provider.suggestedName ?? String(localized: "attachment")
            if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) {
                    [weak self] data, _ in
                    guard let data else { return }
                    let kind = ImageBytes.kind(of: data)
                    Task { @MainActor in
                        self?.attach(data: data, name: "\(name).\(kind.ext)", mime: kind.mime)
                    }
                }
                continue
            }
            provider.loadFileRepresentation(forTypeIdentifier: UTType.item.identifier) {
                [weak self] url, _ in
                guard let url, let data = try? Data(contentsOf: url) else { return }
                let filename = url.lastPathComponent
                let mime = AttachmentIntake.mime(forExtension: url.pathExtension)
                Task { @MainActor in
                    self?.attach(data: data, name: filename, mime: mime)
                }
            }
        }
    }
}

extension HomeViewController {
    /// The store's price for the unlock, fetched once the card is due so the button can name it.
    private static var fetchedProPrice: String?

    private var proPrice: String? {
        if let price = Self.fetchedProPrice { return price }
        Task { @MainActor [weak self] in
            guard let product = await ProStore.shared.products().pro else { return }
            Self.fetchedProPrice = product.displayPrice
            self?.applySnapshot()
        }
        return nil
    }

    @objc private func supporterDidChange() {
        if ProStore.shared.isPro { SupporterInvitation.settle() }
        applySnapshot()
    }

    private func openSupporterOffer() {
        Theme.Haptics.tap()
        ProUpgradeViewController.present(from: self)
    }

    private func declineSupporterOffer() {
        Theme.Haptics.selection()
        SupporterInvitation.dismiss()
    }
}

extension HomeViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        releaseDeferredSnapshotIfNeeded()
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        switch item {
        case .alert:
            onOpenSettings?()
        case .supporter:
            break
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
        case .alert, .supporter, .missed, .usage, .placeholder, .usagePlaceholder:
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
