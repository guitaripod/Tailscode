import MidgarCore
import TailscodeCore
import CodingAgentKit
import UIKit

@MainActor
final class ChatViewController: UIViewController {
    enum Section { case main }

    let viewModel: ChatViewModel
    var collectionView: UICollectionView!
    var transcriptBottom: NSLayoutConstraint!
    var dataSource: UICollectionViewDiffableDataSource<Section, String>!
    let composer = ComposerView()
    lazy var callController = ChatCallController(
        chatID: viewModel.session.id, profileID: viewModel.contextID, host: callHost)
    let dialPill = ModelDialPill()
    let commandPalette = SlashCommandPalette()
    let banner = BannerView()
    let emptyState = ChatEmptyStateView()
    let loadingState = WorkingPlaceholderView()

    var rowsByID: [String: ChatRow] = [:]
    var orderedIDs: [String] = []
    /// How many compaction seams the transcript carries, counted when it was last built so a
    /// redraw of the docked rows does not walk it again.
    var seamCount = 0
    var renderedIDOrder: [String] = [] {
        didSet { renderedOrderIndex = nil }
    }
    var renderedOrderIndex: [String: Int]?
    /// The rows the data source holds right now, which are every row of the transcript except
    /// while a long one is still being opened from its end.
    var appliedIDs: [String] = []
    var opening: TranscriptOpening?
    var openingStage: TranscriptOpening.Stage?
    var openingStageStart: CFTimeInterval = 0
    var openingScheduled = false
    /// The air each row was last given above it, so a row whose neighbour changed — a rail
    /// arriving between it and the paragraph before it — is drawn again with its new gap even
    /// though nothing about the row itself moved.
    var appliedGaps: [String: CGFloat] = [:]
    var appliedGapMetrics: ChatMetrics?
    /// Which link rails the reader has opened, remembered by the rail's identity so a rebuild
    /// per streamed word does not fold one under their finger.
    var railExpansion = TranscriptExpansion()
    var pendingAttachments: [PromptAttachment] = []
    /// What each design board in this transcript turned out to be, so its card can say so. Kept
    /// per directory rather than per row: a board revised later in the conversation writes its
    /// manifest again and both cards are pictures of the same board.
    var designManifests: [String: DesignManifest] = [:]
    var designReads: Set<String> = []
    /// Names pasted pictures apart, so two screenshots in one prompt are two files rather than one
    /// overwriting the other on the machine that reads them.
    var pastedImageCount = 0
    var pendingPermission: PermissionRequest?
    var pendingQuestion: QuestionRequest?
    /// A turn this session's server was stopped in the middle of, waiting to be picked back up or
    /// let go. It survives a reconnect and a relaunch because the server holds it, not this device.
    var interrupted: InterruptedTurn?
    /// The card as it was last drawn, so a card that changed without the transcript moving — a
    /// press taken, a refusal that corrected it — is repainted rather than recognised by row id
    /// and left exactly as it was.
    var lastInterrupted: InterruptedTurn?
    static let interruptedRowID = "interrupted"
    /// The turn waiting on its provider right now, read fresh from `state.retry` on every render:
    /// the card recomputes its own countdown on a clock of its own, so nothing here needs to track
    /// more than whether the wait itself is still standing.
    var retryStanding: TurnRetry?
    var lastRetryStanding: TurnRetry?
    static let retryRowID = "retry"
    /// The conversation wound back to one of your messages, or nil when nothing is set aside.
    var revertBanner: RevertBanner?
    var lastRevertBanner: RevertBanner?
    /// Whether this device's own press on Restore is still out, baked into the banner's redraw the
    /// same way an interrupted-turn press is: the banner has no identity of its own to carry it.
    var lastRestoringRevert = false
    static let revertRowID = "revert"
    static let queuePausedRowID = "queue-paused"
    /// The standing revert's own boundary message, so the composer is refilled exactly once per
    /// revert rather than on every unrelated render while one stands.
    var lastRevertMessageID: String?
    /// The exact words a revert put in the composer, so a Restore that follows clears them again
    /// only if the reader left them untouched.
    var revertComposerFill: String?
    /// The message this device asked to wind back to. Only the device that pressed Undo gets the
    /// words back in its composer; a revert made on another machine leaves this one's draft alone.
    var requestedRevertID: String?
    /// The compaction happening right now, or the one that was just refused. Finished ones are
    /// rows in the transcript and need no state here.
    var liveCompaction: CompactionRow?
    /// How many seams the transcript must be holding before the live card may go, and how long the
    /// card may wait for one. A compaction that finishes clears itself and grows its `Compaction`
    /// part on two separate events, and a card dropped on the first of them leaves an applied
    /// snapshot with neither row in it: the divider blinks out and a different-looking one takes
    /// its place. A promise nothing ever keeps — a compaction abandoned by a server, a reconnect —
    /// expires instead of leaving "Compacting…" on screen for the rest of the session.
    var promisedSeamCount: Int?
    var promisedSeamDeadline: Date = .distantPast
    /// The clock the deadline is read by. `updateLiveCompaction` runs only from a render and a
    /// render only from a state arriving, so a compaction that is abandoned rather than finished
    /// clears inside its own burst of events — every one of them inside the patience — and nothing
    /// ever looks again. A deadline nobody is watching is not a deadline.
    var seamWatch: Task<Void, Never>?
    var questionSelection = QuestionCell.Selection()
    weak var transcriptDismissTap: UITapGestureRecognizer?
    var answeredQuestionIDs: Set<String> = []
    var lastNotifiedQuestionID: String?
    var lastBannerQuestionID: String?
    var availableModels: [ModelInfo] = []
    var modelsReachable: Bool?
    var modelPicker: ModelPickerViewController?
    var pickerWatch: Task<Void, Never>?
    var expandedReasoning: Set<String> = []
    var seenReasoning: Set<String> = []
    var wasRunning = false
    /// A chat opened on a device that never held it asks the server for its account before the
    /// history has arrived, and a request that raced the transcript answers nothing. The moment
    /// the transcript lands is the one edge that says the conversation is really here, so it is
    /// worth one more ask.
    var hadLoadedTranscript = false
    var lastStreamingID: String?
    var hasRevealed = false
    var revealFallback: Task<Void, Never>?
    var animateNextRender = false
    var isHandingOffEmptyState = false
    var deferEmptyStateHide = false
    var lastHapticPermissionID: String?
    var lastHapticFailure: String?
    let navStatusLabel = UILabel()
    let navTitleLabel = UILabel()
    let navStatusRow = UIStackView()
    var lastNotifiedPermissionID: String?
    let fab = UIButton(type: .system)
    var rowsAtDeparture: Int?
    let agentsChip = ChatChip(kind: .live)
    let backgroundChip = ChatChip(kind: .live)
    let goalChip = ChatChip(kind: .live)
    let contextChip = ChatChip(kind: .fact)
    let wallChip = ChatChip(kind: .fact)
    let cacheChip = ChatChip(kind: .fact)
    var rangeQuotas: [UsageQuota] = []
    var rangeClock: Task<Void, Never>?
    weak var rangeSheet: RangeViewController?
    /// What the whole conversation has cost, beside its size — the two facts a long chat is
    /// judged by. Tapping opens the account behind the number.
    let spendChip = ChatChip(kind: .fact)
    /// The server's own account when it keeps one, else what the transcript says — kept apart so a
    /// poll that came back with nothing cannot erase a good reading, which is what left the chart
    /// on the one device the session was started from.
    var spendReading = SpendReading()
    /// The branch the work is landing on, and how far the tree has drifted from it. Tapping opens
    /// the repository — read-only, because this app never commits on anyone's behalf.
    let gitChip = ChatChip(kind: .fact)
    var git: GitState?
    /// The way into the running app, offered only where this conversation's machine runs a preview
    /// host and the folder is known. It is a control, so it is outlined, and it leads the one
    /// chip row the chat has, so a row that scrolls sideways never hides it.
    let previewChip = ChatChip(kind: .control)
    lazy var factsRow = ChatFactsRow(chips: [
        previewChip, agentsChip, backgroundChip, goalChip, contextChip, wallChip, cacheChip,
        spendChip, gitChip,
    ])
    let factsScrim = FadeScrimView(fade: CGFloat(ChatChrome.transcriptToChrome))
    let findBar = UIView()
    let findField = UISearchTextField()
    let findCountLabel = UILabel()
    var findMatches: [String] = []
    var findCursor = 0
    var findHighlightedID: String?
    var findVisible = false
    var lastFindRowCount = 0
    var lastRenderedGoal: SessionGoal?
    let composerAccessories = AccessoryStack()
    var streamingActivityID: String?
    var expandedAgentGroups: Set<String> = []
    let navTitleStack = UIStackView()
    /// What the turn is doing, in the same symbol and the same motion the desks use — a terminal
    /// while a shell runs, a raised hand while it waits on you. A bare spinner said only that
    /// something was happening, which is the one thing the reader could already see.
    let navBadge = ActivityBadgeView(pointSize: 12)
    let attachmentStrip = UIStackView()
    var suppressBannerUntil: Date = .distantPast
    var userScrolledUp = false
    /// Rows measure themselves after the transcript was last laid out — a tool row opening its
    /// detail, an image decoding, a running row growing a line — and the room above a short
    /// transcript and the end of a long one are both worked out from its height, so a height that
    /// moves has to say so or the last rows end up behind whatever floats over the composer.
    var contentSizeWatch: NSKeyValueObservation?
    #if DEBUG
        lazy var heightProbe = ChatHeightProbe(sessionID: viewModel.session.id)
    #endif
    /// A finger resting on the transcript, which is not the same gesture as a drag and stops the
    /// stream following the bottom all the same.
    var isFingerDown = false
    var lastRenderedIDs: Set<String> = []
    let enhancement = PromptEnhancementController()
    var enhanceOverlay: PromptEnhanceOverlay?
    var isApplyingEnhancedPrompt = false
    let cascade = CascadeDriver()
    /// Rows the wave has just let go of. A turn that simply ends leaves the row's value identical,
    /// so the diff has nothing to do and the last glyphs would keep the heat of a stream that
    /// stopped — they are reconfigured by name instead.
    var settledCascadeRows: Set<String> = []
    /// A row the wave gave up on. It is not taken back: restarting a reveal that already snapped to
    /// whole would rewind the answer under the reader.
    var abandonedCascadeRow: String?
    /// The live row as it arrived, before the gate cut it back to what is safe to render. Giving up
    /// on a row means showing the reader everything the agent wrote, which is this and never the
    /// paced copy the data source is holding.
    var wholeCascadeRow: ChatRow?
    /// The clock that keeps trying a hand-back nothing else would ever try again — the wave lets go
    /// of its display link and its watchdog in the same breath, and a turn that ended sends no more
    /// states.
    var cascadeRepair: Task<Void, Never>?

    var sessionID: String { viewModel.session.id }
    var contextID: String { viewModel.contextID }

    /// Set by the iPad's workspace while it carries this chat from its column to the one-stack
    /// arrangement or back. Leaving one navigation stack for another is not the reader leaving the
    /// conversation, so the stream, the enhancement in flight and the binding all stay; the chat
    /// clears the mark itself when it is on screen again.
    var isChangingColumns = false {
        didSet {
            if isChangingColumns, !oldValue { carriesEndThroughMove = isParkedOnEnd() }
        }
    }
    /// Whether the reader was on the end of the page when the window moved this conversation
    /// between a column and a stack — folding a phone shut does exactly that — so the end is put
    /// back under the composer once the transcript has been measured at its new width.
    private var carriesEndThroughMove = false

    init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    deinit {
        elapsedTicker?.cancel()
        revealFallback?.cancel()
        workflowTicker?.cancel()
        cascadeRepair?.cancel()
        seamWatch?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationManager.clearNotices(sessionID: viewModel.session.id)
        title = navDisplayTitle
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.backButtonDisplayMode = .minimal
        view.backgroundColor = Theme.Color.background
        configureLayout()
        configureFAB()
        configureAgentsChip()
        configureGoalChip()
        configureContextChip()
        configureRangeChips()
        configureSpendChip()
        configureGitChip()
        configurePreviewChip()
        configureBackgroundChip()
        configureFindBar()
        configureNavTitleView()
        configureDataSource()
        callController.attach()
        composer.delegate = self
        composer.showsAttach = canAttachAnything
        enhancement.onStatusChange = { [weak self] status in
            self?.handleEnhancementStatus(status)
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(sceneDidActivate),
            name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(catalogDidChange), name: ModelCatalog.didChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(responseStatsDidChange),
            name: ResponseStatsSetting.didChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(linkEmbedsDidChange),
            name: LinkEmbedsSetting.didChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(chatDensityDidChange),
            name: ChatDensitySetting.didChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(activityStyleDidChange),
            name: ActivityStyleSetting.didChange, object: nil)
        for name: Notification.Name in [
            UIApplication.willResignActiveNotification,
            UIApplication.didEnterBackgroundNotification,
            UIApplication.willTerminateNotification,
        ] {
            NotificationCenter.default.addObserver(
                self, selector: #selector(flushDraft), name: name, object: nil)
        }
        collectionView.alpha = 0
        revealFallback = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            self?.revealTranscript()
        }
        bind()
        viewModel.start()
        viewModel.restoreHeldMessages()
        #if DEBUG
            if let auto = ProcessInfo.processInfo.environment["TAILSCODE_AUTOSEND"] {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    self?.composerDidSend(auto)
                }
            }
            if let option = ProcessInfo.processInfo.environment["TAILSCODE_ANSWER_QUESTION"]
                .flatMap(Int.init)
            {
                Task { [weak self] in await self?.answerPendingQuestion(option: option) }
            }
            if ProcessInfo.processInfo.environment["TAILSCODE_OPEN_ATTACHMENT"] != nil {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    self?.openFirstAttachment()
                }
            }
            if ProcessInfo.processInfo.environment["TAILSCODE_SAVE_ATTACHMENT"] != nil {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    self?.saveFirstAttachment()
                }
            }
            if let which = ProcessInfo.processInfo.environment["TAILSCODE_OPEN_RAIL"] {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(Double(which) ?? 4))
                    guard let self,
                        let id = self.orderedIDs.first(where: {
                            if case .linkRail(let run)? = self.rowsByID[$0]?.content {
                                return run.addresses.count > 1
                            }
                            return false
                        })
                    else { return }
                    self.toggleRail(id)
                }
            }
            if ProcessInfo.processInfo.environment["TAILSCODE_OPEN_RANGE"] != nil {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    self?.presentRange()
                }
            }
            if let which = ProcessInfo.processInfo.environment["TAILSCODE_OPEN_COMPACT"] {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    guard let self else { return }
                    which == "summary"
                        ? self.openFirstCompactionSummary() : self.presentCompactPreflight()
                }
            }
            if let hook = ProcessInfo.processInfo.environment["TAILSCODE_OPEN_AGENTS"] {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    guard let self else { return }
                    let agents = self.viewModel.trackedSubagents
                    guard !agents.isEmpty else { return }
                    switch hook {
                    case "first": self.revealSubagent(id: agents[0].id)
                    case "group": self.scrollToFirstAgentGroup()
                    default: self.presentSubagents(agents)
                    }
                }
            }
            if let draft = ProcessInfo.processInfo.environment["TAILSCODE_DRAFT"] {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    self?.composer.setDraft(draft)
                }
            }
            if let dial = ProcessInfo.processInfo.environment["TAILSCODE_DIAL"] {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(7))
                    for verb in dial.split(separator: "+") {
                        guard let self else { return }
                        await self.tourDial(String(verb))
                        try? await Task.sleep(for: .seconds(0.6))
                    }
                }
            }
            if ProcessInfo.processInfo.environment["TAILSCODE_OPEN_MODELS"] != nil {
                Task { [weak self] in
                    let delay = ProcessInfo.processInfo.environment["TAILSCODE_MODELS_DELAY"]
                        .flatMap(Double.init) ?? 2
                    try? await Task.sleep(for: .seconds(delay))
                    self?.presentModelPicker()
                    if let model = ProcessInfo.processInfo.environment["TAILSCODE_MODELS_PEEK"] {
                        try? await Task.sleep(for: .seconds(1.5))
                        self?.modelPicker?.tourPeek(matching: model)
                    }
                    if let machine = ProcessInfo.processInfo.environment[
                        "TAILSCODE_MODELS_MACHINE"
                    ].flatMap(Int.init) {
                        try? await Task.sleep(for: .seconds(1))
                        self?.modelPicker?.tourMachine(machine)
                    }
                    if let door = ProcessInfo.processInfo.environment["TAILSCODE_MODELS_DOOR"]
                        .flatMap(Int.init)
                    {
                        try? await Task.sleep(for: .seconds(1))
                        self?.modelPicker?.tourDoor(door)
                    }
                    if ProcessInfo.processInfo.environment["TAILSCODE_MODELS_EXPAND"] != nil {
                        try? await Task.sleep(for: .seconds(1))
                        self?.modelPicker?.tourExpand()
                    }
                    if let query = ProcessInfo.processInfo.environment["TAILSCODE_MODELS_SEARCH"] {
                        try? await Task.sleep(for: .seconds(1))
                        self?.modelPicker?.tourSearch(query)
                    }
                }
            }
            if let hook = ProcessInfo.processInfo.environment["TAILSCODE_OPEN_GIT"] {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    guard let self else { return }
                    self.presentGit()
                    if ProcessInfo.processInfo.environment["TAILSCODE_GIT_LARGE"] != nil {
                        let sheet = (self.presentedViewController as? UINavigationController)?
                            .sheetPresentationController
                        sheet?.animateChanges { sheet?.selectedDetentIdentifier = .large }
                    }
                    guard hook == "diff" || hook == "commit" else { return }
                    try? await Task.sleep(for: .seconds(2))
                    let beside = self.workspace?.inspector.navigation.viewControllers.first
                    let status =
                        (beside as? GitStatusViewController)
                        ?? (self.presentedViewController as? UINavigationController)?
                        .topViewController as? GitStatusViewController
                    status?.openFirst(hook == "commit" ? .commit : .change)
                }
            }
            if let what = ProcessInfo.processInfo.environment["TAILSCODE_INSPECT"] {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(5))
                    self?.inspectForVerification(what)
                }
            }
        #endif
        let draft = DraftStore.text(for: draftScope)
        if !draft.isEmpty { composer.setDraft(draft, focus: false) }
        if viewModel.supportsModelSelection || viewModel.supportsReasoningEffort {
            Task { await loadModels() }
        }
        viewModel.loadServerCommands()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        viewModel.isBound = true
        viewModel.startSubagentTracking()
        callController.screenAppeared()
        updatePreviewChip()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        MidgarLog.info(
            "chat appeared session=\(viewModel.session.id) title=\(viewModel.displayTitle)", category: .chat)
        AppActivityController.shared.shown(viewModel.session.id, in: self)
        isChangingColumns = false
        if findVisible, !brainSearch.isWarm { brainSearch.start() }
        if carriesEndThroughMove {
            carriesEndThroughMove = false
            settleUntil = CACurrentMediaTime() + 4
            collectionView.layoutIfNeeded()
            carryEnd()
        }
        if UIApplication.shared.applicationState == .active {
            AppActivityController.shared.seen(viewModel.session.id)
            if !setAsideUnread { SessionSeenStore.markSeen(viewModel.session.id) }
        }
        if !announcedIdentity {
            announcedIdentity = true
            announceIdentity()
        }
        if !composer.isEditing { becomeFirstResponder() }
        refreshSpend()
        refreshGit()
        startRangeClock()
    }

    private var announcedIdentity = false

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        let palette = commandPalette.isHidden ? [] : paletteKeyCommands()
        var takeBack: [UIKeyCommand] = []
        if commandPalette.isHidden,
            QueueReading.upArrowOpensLast(
                composerText: composer.currentText, display: viewModel.queueDisplay)
        {
            let command = UIKeyCommand(
                input: UIKeyCommand.inputUpArrow, modifierFlags: [],
                action: #selector(takeBackLastQueued))
            command.wantsPriorityOverSystemBehavior = true
            takeBack.append(command)
        }
        guard keyContext == .insert else { return (palette + takeBack).isEmpty ? nil : palette + takeBack }
        return palette + takeBack
            + KeyBridge.shared.insertKeyCommands(action: #selector(handleInsertKeyCommand(_:)))
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if keyContext == .normal, enterBrainWithTab(presses) { return }
        if keyContext == .normal, handleKeyPresses(presses) { return }
        super.pressesBegan(presses, with: event)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        AppActivityController.shared.hidden(self)
        brainSearch.cancel()
        rangeClock?.cancel()
        rangeClock = nil
        cascade.release()
        flushDraft()
        if !setAsideUnread { SessionSeenStore.markSeen(viewModel.session.id) }
        viewModel.stopSubagentTracking()
        callController.screenGone()
        if !isChangingColumns, isCoveredByAnotherChat { callController.chatLeft() }
        if !isChangingColumns,
            isMovingFromParent || isBeingDismissed || navigationController?.isBeingDismissed == true
        {
            releaseConversation()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        adaptToFold()
        updateTranscriptInsets()
    }

    /// When the page was opened onto the end, so that the rows settling in behind it — a cached
    /// transcript giving way to the server's, cells being measured after the scroll — keep the end
    /// in view for a few seconds instead of leaving the page stranded wherever the estimate put it.
    var settleUntil: CFTimeInterval = 0

    /// The room held under the transcript so the prompt just sent can rest at the top of the
    /// window, and the row it is held for. Read on every relayout so the composer moving, the
    /// keyboard going or the answer growing all shrink it by the same arithmetic.
    var canvasPadding: CGFloat = 0
    /// The rows of the send the canvas holds room for, by identity rather than by index. A prompt
    /// with pictures is several rows — each picture above the words — and the block that rises is
    /// all of them. The rows are this device's pending ones until the server's account catches
    /// up, and then the server's own rows for that message: which row is at which index is the
    /// one thing a swap between the two is allowed to change.
    var canvasPromptIDs: [String] = []
    /// A send that has gone and has not yet been given its canvas. It outlives any single apply,
    /// because the server's echo can land between one apply and its completion: the pending rows
    /// this device drew are gone by the time the completion looks for them, and a canvas that only
    /// knew those rows opened on nothing.
    var canvasIntent: [String] = []
    /// The rise is being set up: the rows are in the list but the room and the motion are not
    /// finished. Nothing may let the canvas go while this is true — a room measured against a row
    /// the list has not yet laid out is no room at all, and a canvas released on that reading took
    /// the whole rise with it and left the prompt where it was sent.
    var canvasRising = false
    /// Whether the prompt is still being kept at the headroom. It is put there and *held* there:
    /// every reason the one motion misses — a row measured after it is drawn, the room allocated a
    /// frame late, the server's own rows replacing the ones this device drew — happens after the
    /// motion is over, and a rise that was only ever aimed once has no way to notice. A hand on the
    /// transcript ends the pin and leaves the room alone.
    var canvasPinned = false
    /// Guards the pin against the layout pass its own scroll provokes.
    var isPinningCanvas = false
    /// How long a rise keeps asking for geometry that is not there yet.
    var canvasRiseDeadline: CFTimeInterval?
    /// A send that is going again in the row it already has. Its rows are not new to the list, so
    /// nothing about the transcript can tell that anything was sent; this is the send saying so.
    var canvasForcedSend: UUID?

    /// Where in the transcript the send the canvas is about was drawn: the pending rows go after
    /// every server row, so the server's own rows for that message can only land there or later.
    /// A user message from further up is an older prompt — a pending row that was discarded
    /// rather than reconciled leaves one as the last user message — and a canvas that rose to it
    /// would be the wrong page.
    var canvasFloor = 0

    var rails: [ReadableRail] = []

    var shownJump: JumpReading?

    override var title: String? {
        didSet {
            navTitleLabel.text = title
            refreshNavAccessibility()
        }
    }

    #if DEBUG
        var providedItems: [Int] = []

        var isOpenedForBench: Bool { hasRevealed && opening == nil }

        func renderRefetchedCopyForBench(_ messages: [ChatMessage]) -> Double {
            var state = lastRenderedState ?? viewModel.state
            state.messages = messages
            let started = CACurrentMediaTime()
            render(state)
            return (CACurrentMediaTime() - started) * 1000
        }

        var lastTextLengthForBench: Int {
            for id in orderedIDs.reversed() {
                if case .text(let words)? = rowsByID[id]?.content { return words.count }
            }
            return -1
        }

        func openLatestBrainForBench() {
            guard let turnID = viewModel.state.messages.last(where: { $0.role == .assistant })?.id,
                !brain.store.isOpen(turnID)
            else { return }
            brain.store.toggle(turnID)
            render(lastRenderedState ?? viewModel.state)
        }
    #endif

    /// Which failed rows have already been felt. A failure is worth one knock, and the row is
    /// redrawn on every clock tick that ages its caption.
    var announcedFailedSends: Set<UUID> = []

    var brainEffort: BrainEffortReading?

    var pacer = RenderPacer()
    var heldRender: DispatchWorkItem?

    var hasPainted = false

    var firstPaint: FirstPaint?

    var lastReadMarkAt: CFTimeInterval = 0
    var wasRunningWhenMarked = false

    var lastReadStamp = 0

    let openedAt = ContinuousClock.now
    var openTimed = false

    let segmentMemo = SegmentRowMemo()
    let brain = ChatBrainController()
    lazy var brainSearch = BrainSearchWarmer(
        store: brain.store, isVisible: { [weak self] in self?.view.window != nil },
        finished: { [weak self] in self?.runFind(retarget: false) })

    /// Where every tool call stood when the transcript was last built, so a call that has just
    /// completed is told from one that was already done without keeping a second copy of every row.
    var lastToolStatuses: [String: ToolStatus] = [:]

    var turnStartedAt: Date?
    var elapsedTicker: Task<Void, Never>?
    var lastStatusPhaseText = ""
    var transcriptFill: ContextFill?
    /// The transcript's fill read against the model the next send will run on, so a model switch
    /// re-sizes the ring at once.
    var contextFill: ContextFill? {
        transcriptFill?.rewindowed(
            model: viewModel.selectedModel?.modelID,
            providerID: viewModel.selectedModel?.providerID, catalog: availableModels)
    }
    var countedMessages = -1

    var shownSpendBadge: String?

    var shownContext: (fill: ContextFill, words: String?, tone: ContextFill.Tone)?
    /// The ring the context chip wears, by the whole percent it shows: the fill moves with every
    /// token, and a ring drawn again for a change a twelve-point circle cannot show was most of
    /// what updating the chip cost.
    var shownRing: (percent: Int, ink: UIColor)?

    /// Which waiting message the composer is currently rewriting, if any.
    ///
    /// Taking a queued message back into the composer and sending it again would put it at the end
    /// of the queue, which is not editing — it is deleting and re-adding, and it silently reorders
    /// what somebody wrote. So the composer remembers which entry it holds and the send puts it
    /// back where it was.
    var editingQueued: String?

    /// Marks the overflow button while a permission waits, by tint rather than by
    /// a badged symbol: `ellipsis.circle.badge.exclamationmark` does not exist, so
    /// asking for it returned nil and blanked the button in the one state where
    /// the menu behind it matters most.
    var shownOverflowBadge: (item: ObjectIdentifier, hasPermission: Bool)?

    var setAsideUnread = false

    /// Backends that never name the spawning call — opencode's child sessions, or a bridge that
    /// hasn't resolved the id yet — get their cards seated in order against the spawn calls
    /// still free, so a card still lands where its work began.
    var workflowRuns: [WorkflowRun] = []
    var workflowNow: Date = Date()
    var workflowTicker: Task<Void, Never>?
    var lastRenderedState: ConversationState?
    /// The order this conversation first saw each agent in, which is the only order a seat may be
    /// handed out by.
    var agentArrivals: [String: Int] = [:]
    var agentArrivalCount = 0
    /// The spawn call each unattached card was seated against, kept for the life of the view. A seat
    /// is remembered rather than worked out again, because working it out again is what let two
    /// cards swap chairs.
    var spawnSeats: [String: String] = [:]
    /// The moment this draw reads its agent rows at, and how the call that spawned each one holds
    /// it. Both belong to the pass rather than to the card: a snapshot whose clocks keep running
    /// is not a snapshot, and two cards in one transcript may not disagree about what time it is.
    var agentReadAt = Date()
    var holds: [String: AgentHold] = [:]

    /// When the follow last moved, so a glide knows how much time one frame was.
    var followClock: CFTimeInterval?

    /// Whether the last frame's glide was still on its way to where the writing ends. A frame that
    /// moved only the band, with the glide settled, has nowhere to follow to and measures nothing.
    var followGliding = false
}

extension ChatViewController {
    /// What the call needs of this screen and nothing else: the conversation as it stands, the same
    /// send path a typed message takes, the ordinary stop, and somewhere to present and to say
    /// things.
    fileprivate var callHost: ChatCallController.Host {
        ChatCallController.Host(
            presenter: { [weak self] in self },
            state: { [weak self] in self?.viewModel.state ?? ConversationState() },
            sending: { [weak self] in self?.viewModel.optimisticThinking ?? false },
            title: { [weak self] in self?.navDisplayTitle ?? "" },
            deliver: { [weak self] text in self?.sendSpoken(text) ?? false },
            stopTurn: { [weak self] in self?.viewModel.abort() },
            toast: { [weak self] message in self?.presentToast(message, duration: 5) },
            dismissKeyboard: { [weak self] in self?.view.endEditing(true) },
            barItemsChanged: { [weak self] in self?.refreshCallBarItem() })
    }

    /// What the voice heard goes out exactly as typed words do — pending ink, queue, marks — with
    /// the chat's current model and effort, and leaves the draft in the composer alone.
    fileprivate func sendSpoken(_ text: String) -> Bool {
        userScrolledUp = false
        animateNextRender = true
        viewModel.send(text)
        return true
    }

    fileprivate func refreshCallBarItem() {
        guard let overflow = navigationItem.rightBarButtonItems?.first else { return }
        navigationItem.rightBarButtonItems = [overflow] + callController.barItems
    }
}
