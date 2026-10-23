import TailscodeCore
import CodingAgentKit
import CodingAgentKitApple
import UIKit

/// The app's front door, organized around three jobs: triage (what needs you
/// right now — blocked or live agents, unreachable servers), continue (recent
/// conversations, badged when they changed since you last looked), and start
/// (the docked composer in either of its two lanes, and project cards that open
/// each project's own board).
@MainActor
final class HomeViewController: UIViewController {
    var onOpenSettings: (() -> Void)?

    let viewModel: SessionListViewModel
    var warmed: ChatViewModel?
    var collectionView: UICollectionView!
    var dataSource: UICollectionViewDiffableDataSource<HomeSection, HomeItem>!
    let refreshControl = UIRefreshControl()
    let composerBar = HomeComposerBar()
    let commandPalette = SlashCommandPalette()
    let suggestions = HomeAskSuggestions()
    let videoChips = HomeVideoChips()
    let imageChips = HomeImageChips()
    /// The composer's reference chip reaches the same five doors the studio's does, presented
    /// from this screen; "From the Library" opens the studio, where the whole shelf is.
    lazy var imageIntake = ImageReferenceIntake(presenter: self, studio: ImageStudio.shared) {
        [weak self] in self?.presentImage()
    }
    let attachmentStrip = HomeAttachmentStrip()
    let failureCard = HomeComposerFailureCard()
    /// Everything that floats between the board and the box, in the order a hand reaches for it:
    /// what went wrong furthest away, then what is being offered, then what is already in hand.
    let accessories = UIStackView()
    /// Which lane the box is in. The chat lane starts a conversation in a project; the ask lane
    /// starts one on a machine and carries the ask's own memory of what should answer it.
    var askLane: QuickAskLane = .chat
    var attachments: [PendingAttachment] = []
    var abilities = ModelAbilities.words
    var pastedImageCount = 0
    let enhancement = PromptEnhancementController()
    weak var enhanceOverlay: PromptEnhanceOverlay?
    /// The mint that failed, kept whole so its remedy can be applied and the same words retried
    /// without asking anybody to type them again.
    var lastAttempt: (aim: ComposerAim, send: QuickAskSend)?
    var lastFailure: NewChatFailure?
    /// What the aimed machine can be told to do. Home's composer mints the conversation a command
    /// would run in, so it owes the same grammar the chat's own composer answers: a slash typed
    /// here is a command, not the first four letters of a question.
    var commands: [AgentCommand] = []
    var catalogProfileID: String?
    var composerFloor: NSLayoutConstraint!
    var composerRidesKeyboard: NSLayoutConstraint!
    private let settingsButton = SettingsGearButton()
    lazy var settingsItem = UIBarButtonItem(customView: settingsButton)
    let updateChip = UpdateChipButton()
    lazy var updateChipItem = UIBarButtonItem(customView: updateChip)
    let videoButton = VideoMarkButton()
    lazy var videoItem = UIBarButtonItem(customView: videoButton)
    let imageButton = ImageMarkButton()
    lazy var imageItem = UIBarButtonItem(customView: imageButton)
    let orbView = PresenceOrbView()
    var orbTarget: SessionEntry?
    var quotas: [UsageQuota] = []
    var quotasAnsweredAt: Date?
    var savedChats: [SavedChat] = SavedChatStore.all()
    private var hasAppeared = false
    var hasLoadedOnce = false
    private var wantsComposerFocus = false
    var pendingDeepLink: (sessionID: String, parkedAt: Date)?
    var modelChoices: [String: ModelChoice] = [:]
    var resolvingModels: Set<String> = []
    var appliedComposerState: String?
    var appliedComposeButtonState: String?
    var composerDraftScope: DraftScope?
    var resolvedComposeTarget: (profileID: String, directory: String?)?
    private var appliedTodayState: String?
    var scheduledSnapshot = false
    var deferredSnapshot = false
    /// What each card was last drawn from. A diffable identity says which card a row *is*, never
    /// whether anything on it moved, so reconfiguring everything that survived a diff redrew the
    /// whole board on a tick that changed one word.
    var appliedContent: [HomeItem: Int] = [:]

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
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.backButtonTitle = String(localized: "Home")
        view.backgroundColor = Theme.Color.groupedBackground
        settingsButton.addTarget(self, action: #selector(openSettings), for: .touchUpInside)
        updateChip.addTarget(self, action: #selector(openUpdates), for: .touchUpInside)
        videoButton.addTarget(self, action: #selector(openVideo), for: .touchUpInside)
        imageButton.addTarget(self, action: #selector(openImage), for: .touchUpInside)
        updateVideoMark()
        updateImageMark()
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
            if let script = ProcessInfo.processInfo.environment["TAILSCODE_HOME_DIAL"] {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(4))
                    for verb in script.split(separator: "+") {
                        guard let self else { return }
                        let parts = verb.split(separator: ":", maxSplits: 1).map(String.init)
                        switch parts.first ?? "" {
                        case "pins": DialTour.pinPairs()
                        case "aim":
                            if parts.count > 1,
                                let profile = self.viewModel.servers.first(where: { $0.id == parts[1] })
                            {
                                self.setComposeTarget(profile: profile, directory: nil)
                            }
                        case "pick":
                            if parts.count > 1, let aim = self.composerAim {
                                self.setComposeModel(DialTour.selection(parts[1]), for: aim)
                            }
                        case "level":
                            if parts.count > 1, let aim = self.composerAim {
                                self.setComposeEffort(parts[1], for: aim)
                            }
                        case "rail": self.composerBar.dialPill.openRail()
                        case "menu": self.composerBar.dialPill.openMenu()
                        default: break
                        }
                        try? await Task.sleep(for: .seconds(0.6))
                    }
                }
            }
            if ProcessInfo.processInfo.environment["TAILSCODE_OPEN_ASK"] != nil {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    self?.presentQuickAsk()
                    self?.seedAskForVerification()
                }
            }
            if let host = ProcessInfo.processInfo.environment["TAILSCODE_OPEN_IMAGE"] {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    guard let self else { return }
                    if case .endpoint(let endpoint) = ImageGenEndpoint.read(host) {
                        ImageGenStore.remember(endpoint)
                    }
                    ImageStudio.shared.adoptDoor()
                    if let engine = ProcessInfo.processInfo.environment["TAILSCODE_IMAGE_ENGINE"]
                        .flatMap(ImageGenEngine.init(rawValue:))
                    {
                        ImageStudio.shared.choose(engine: engine)
                    }
                    if let aspect = ProcessInfo.processInfo.environment["TAILSCODE_IMAGE_ASPECT"]
                        .flatMap(ImageGenAspect.init(rawValue:))
                    {
                        ImageStudio.shared.choose(aspect: aspect)
                    }
                    self.updateImageMark()
                    let words = ProcessInfo.processInfo.environment["TAILSCODE_IMAGE_PROMPT"]
                    if ProcessInfo.processInfo.environment["TAILSCODE_IMAGE_LANE"] != nil {
                        self.setLane(.image, animated: false)
                        self.composerBar.setText(words ?? "")
                        return
                    }
                    if ProcessInfo.processInfo.environment["TAILSCODE_IMAGE_MISSING"] != nil {
                        try? await Task.sleep(for: .seconds(5))
                        ImageGenStore.record(
                            ImageGenSighting(
                                host: ImageStudio.shared.endpoint.displayHost, reachable: true,
                                missingModels: ImageGenEngine.fast.files.map(\.path)))
                    }
                    if let seed = ProcessInfo.processInfo.environment["TAILSCODE_IMAGE_SEED"]
                        .flatMap(UInt64.init)
                    {
                        ImageStudio.shared.stage(seed: seed)
                    }
                    self.presentImage()
                    guard let words else { return }
                    for line in words.split(separator: "|") {
                        if ProcessInfo.processInfo.environment["TAILSCODE_IMAGE_EDIT"] != nil {
                            try? await Task.sleep(for: .seconds(3))
                            switch ImageStudio.shared.exhibit {
                            case .made(let made):
                                ImageStudio.shared.hold(
                                    ImageGenReference(path: made.path, kept: made.kept))
                            case .kept(let kept):
                                ImageStudio.shared.hold(kept: kept)
                            case nil:
                                break
                            }
                        }
                        ImageStudio.shared.submit(prompt: String(line))
                        while ImageStudio.shared.isPainting {
                            try? await Task.sleep(for: .seconds(1))
                        }
                    }
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
            if let name = ProcessInfo.processInfo.environment["TAILSCODE_DUO_SCREEN"] {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    self?.presentDuoScreen(named: name)
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
            if ProcessInfo.processInfo.environment["TAILSCODE_HOME_QUOTAS"] != nil {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(6))
                    guard let self else { return }
                    var found: [UsageQuota] = []
                    for source in ConnectionController.shared.allBackends() {
                        if let quota = try? await source.backend.usageQuota() { found.append(quota) }
                    }
                    self.quotas = found
                    self.quotasAnsweredAt = Date()
                    self.applySnapshot()
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
        DelegateGate.watchNotices()
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

    /// Beside a chat list the pane that is left is Today: the list already holds every row, so
    /// Home is what a list cannot be — the whole question a waiting agent is asking, and the
    /// account's quota. With the list tucked away behind the conversation (the narrow band) Home
    /// is the phone's own board again, bands and all.
    var showsToday: Bool {
        guard let workspace else { return false }
        return workspace.displayMode != .secondaryOnly
    }

    /// Whole quota cards need a tall pane; a short one (the Duo's inner display flat, a page of
    /// the book) keeps the one-line glance, because the composer takes the room the cards would.
    var showsQuotaCards: Bool {
        showsToday && view.bounds.height >= 760 && view.bounds.width >= 460
    }

    private func refreshTodayLayout() {
        let state = "\(showsToday)|\(showsQuotaCards)"
        guard state != appliedTodayState else { return }
        appliedTodayState = state
        applySnapshot()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        refreshTodayLayout()
        keepBoardAboveFold()
        let top = min(composerBar.frame.minY, accessories.frame.minY)
        let overlap = max(0, collectionView.frame.maxY - top - collectionView.safeAreaInsets.bottom)
        let inset = composerBar.isHidden ? 0 : overlap + Theme.Spacing.s
        if collectionView.contentInset.bottom != inset {
            collectionView.contentInset.bottom = inset
            collectionView.verticalScrollIndicatorInsets.bottom = inset
        }
    }

    /// Held like a laptop the board fills the top region and stops at the fold, and the box to type
    /// in stays on the base below it, so nothing a person reads or taps sits on the crease.
    private func keepBoardAboveFold() {
        let fold = FoldReading.read(in: view)
        let wanted = fold.flatMap { $0.isLaptop ? -(view.bounds.height - $0.frame.minY) : nil } ?? 0
        if abs(collectionBottom.constant - wanted) > 0.5 { collectionBottom.constant = wanted }
    }

    func focusComposer() {
        guard viewIfLoaded?.window != nil else {
            wantsComposerFocus = true
            return
        }
        composerBar.focus()
    }

    var lastEnrichment: Date?
    var isEnriching = false
    var loadTask: Task<Void, Never>?
    var liveRefreshTask: Task<Void, Never>?
    var clockTickTask: Task<Void, Never>?

    /// The list may reorder itself, but never while a finger is on it: the row pressed must be the
    /// row opened. Everything that arrived during the touch applies the moment it ends.
    var deferredWhileTouching = false

    var rails: [ReadableRail] = []
    var collectionBottom: NSLayoutConstraint!
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
