import TailscodeCore
import CodingAgentKit
import PhotosUI
import SafariServices
import UIKit
import UniformTypeIdentifiers

@MainActor
final class ChatViewController: UIViewController {
    private enum Section { case main }

    private let viewModel: ChatViewModel
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, String>!
    private let composer = ComposerView()
    private let commandPalette = SlashCommandPalette()
    private let banner = BannerView()
    private let emptyState = ChatEmptyStateView()
    private let loadingState = UIContentUnavailableView(configuration: .loading())

    private var rowsByID: [String: ChatRow] = [:]
    private var orderedIDs: [String] = []
    private var renderedIDOrder: [String] = []
    private var pendingAttachments: [PromptAttachment] = []
    private var pendingPermission: PermissionRequest?
    private var pendingQuestion: QuestionRequest?
    /// The compaction happening right now, or the one that was just refused. Finished ones are
    /// rows in the transcript and need no state here.
    private var liveCompaction: CompactionRow?
    private var questionSelection = QuestionCell.Selection()
    private var answeredQuestionIDs: Set<String> = []
    private var lastNotifiedQuestionID: String?
    private var availableModels: [ModelInfo] = []
    private var expandedReasoning: Set<String> = []
    private var seenReasoning: Set<String> = []
    private var wasRunning = false
    private var lastStreamingID: String?
    private var hasRevealed = false
    private var revealFallback: Task<Void, Never>?
    private var animateNextRender = false
    private var isHandingOffEmptyState = false
    private var deferEmptyStateHide = false
    private var lastHapticPermissionID: String?
    private var lastHapticFailure: String?
    private var unreadCount = 0
    private let navStatusLabel = UILabel()
    private var lastNotifiedPermissionID: String?
    private let fab = UIButton(type: .system)
    private let agentsChip = UIButton(type: .system)
    private let goalChip = UIButton(type: .system)
    private let contextChip = UIButton(type: .system)
    /// What the whole conversation has cost, beside its size — the two facts a long chat is
    /// judged by. Tapping opens the account behind the number.
    private let spendChip = UIButton(type: .system)
    private var spend: SessionSpend?
    private let findBar = UIView()
    private let findField = UISearchTextField()
    private let findCountLabel = UILabel()
    private var findMatches: [String] = []
    private var findCursor = 0
    private var findHighlightedID: String?
    private var findVisible = false
    private var lastFindRowCount = 0
    private var lastRenderedGoal: SessionGoal?
    private let composerAccessories = UIStackView()
    private var streamingActivityID: String?
    private var expandedAgentGroups: Set<String> = []
    private let navTitleContainer = UIView()
    /// What the turn is doing, in the same symbol and the same motion the desks use — a terminal
    /// while a shell runs, a raised hand while it waits on you. A bare spinner said only that
    /// something was happening, which is the one thing the reader could already see.
    private let navBadge = ActivityBadgeView(pointSize: 12)
    private let attachmentStrip = UIStackView()
    private var suppressBannerUntil: Date = .distantPast
    private var userScrolledUp = false
    private var lastRenderedIDs: Set<String> = []
    private let enhancement = PromptEnhancementController()
    private var enhanceOverlay: PromptEnhanceOverlay?
    private var isApplyingEnhancedPrompt = false
    private let cascade = CascadeDriver()
    /// Rows the wave has just let go of. A turn that simply ends leaves the row's value identical,
    /// so the diff has nothing to do and the last glyphs would keep the heat of a stream that
    /// stopped — they are reconfigured by name instead.
    private var settledCascadeRows: Set<String> = []

    var sessionID: String { viewModel.session.id }
    init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    deinit {
        elapsedTicker?.cancel()
        revealFallback?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        ActivityInbox.clear(sessionID: viewModel.session.id)
        title = navDisplayTitle
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.backButtonDisplayMode = .minimal
        view.backgroundColor = Theme.Color.background
        configureLayout()
        configureFAB()
        configureAgentsChip()
        configureGoalChip()
        configureContextChip()
        configureSpendChip()
        configureFindBar()
        configureNavTitleView()
        configureDataSource()
        composer.delegate = self
        composer.showsAttach = canAttachAnything
        enhancement.onStatusChange = { [weak self] status in
            self?.handleEnhancementStatus(status)
        }
        NotificationManager.requestAuthorizationIfNeeded()
        NotificationCenter.default.addObserver(
            self, selector: #selector(sceneDidActivate),
            name: UIApplication.didBecomeActiveNotification, object: nil)
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
            if ProcessInfo.processInfo.environment["TAILSCODE_OPEN_MODELS"] != nil {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    self?.presentModelPicker()
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
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if !composer.isEditing { becomeFirstResponder() }
        refreshSpend()
    }

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        let palette = commandPalette.isHidden ? [] : paletteKeyCommands()
        guard keyContext == .insert else { return palette.isEmpty ? nil : palette }
        return palette + KeyBridge.shared.insertKeyCommands(action: #selector(handleInsertKeyCommand(_:)))
    }

    /// Only while the palette is up, and only then claiming priority over the system: the same
    /// arrows have to keep moving the caret through an ordinary draft, and Return has to keep
    /// sending one. A completion list that ate them permanently would be worse than none.
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
            composer.triggerSend()
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

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        cascade.release()
        flushDraft()
        SessionSeenStore.markSeen(viewModel.session.id)
        viewModel.stopSubagentTracking()
        if isMovingFromParent || isBeingDismissed || navigationController?.isBeingDismissed == true {
            viewModel.isBound = false
            if !viewModel.isBusy { viewModel.stop() }
            enhancement.cancel()
            enhanceOverlay?.removeFromSuperview()
            enhanceOverlay = nil
        }
    }

    /// The chat title is the conversation's own name; auto-generated
    /// placeholder titles fall back to the agent's name.
    private var navDisplayTitle: String {
        AgentSession.isPlaceholderTitle(viewModel.title)
            ? viewModel.backend.agentType.displayName
            : viewModel.title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The composer writes for this conversation, so what is in it belongs to the chat rather than
    /// to the screen showing it: the same pairing `SessionEntry` uses for identity.
    private var draftScope: DraftScope {
        .chat(profileID: viewModel.contextID, sessionID: viewModel.session.id)
    }

    private var compactionDraftScope: DraftScope {
        .compaction(profileID: viewModel.contextID, sessionID: viewModel.session.id)
    }

    private var goalDraftScope: DraftScope {
        .goal(profileID: viewModel.contextID, sessionID: viewModel.session.id)
    }

    /// A free-typed answer belongs to the one question it answers, and a request can carry several
    /// — so the row's own identity carries the question's place inside it. Both survive a relaunch
    /// because both are read back off the transcript rather than held in memory.
    private func answerDraftScope(for request: QuestionRequest, questionIndex: Int) -> DraftScope {
        .answer(
            profileID: viewModel.contextID, sessionID: viewModel.session.id,
            questionID: "\(request.id)#\(questionIndex)")
    }

    /// Every keystroke is already recorded, so this only closes the store's coalescing window by
    /// hand where the process is about to stop being asked.
    @objc private func flushDraft() { DraftStore.flush() }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateTranscriptInsets()
    }

    /// The transcript fills the screen behind the composer, so it reserves the
    /// composer's on-screen height at the bottom (the automatic inset adjustment
    /// already accounts for the home indicator) and — because a `.plain` list is
    /// top-aligned — pads the top so a short transcript rests just above the
    /// composer instead of stranding it under the navigation bar.
    private func updateTranscriptInsets() {
        let composerTop = composerAccessories.bounds.height > 0
            ? min(composer.frame.minY, composerAccessories.frame.minY)
            : composer.frame.minY
        let bottomInset = max(
            0, view.bounds.height - composerTop - collectionView.safeAreaInsets.bottom)
        if abs(collectionView.contentInset.bottom - bottomInset) > 0.5 {
            collectionView.contentInset.bottom = bottomInset
            collectionView.verticalScrollIndicatorInsets.bottom = bottomInset
        }

        let bannerInset: CGFloat = banner.isHidden ? 0 : banner.bounds.height
        let available = composerTop - collectionView.safeAreaInsets.top - bannerInset
        let contentHeight = collectionView.collectionViewLayout.collectionViewContentSize.height
        let topInset = bannerInset + max(0, available - contentHeight)
        if abs(collectionView.contentInset.top - topInset) > 0.5 {
            collectionView.contentInset.top = topInset
        }
    }

    private func configureLayout() {
        var config = UICollectionLayoutListConfiguration(appearance: .plain)
        config.showsSeparators = false
        config.backgroundColor = .clear
        let layout = UICollectionViewCompositionalLayout.list(using: config)
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = Theme.Color.background
        collectionView.keyboardDismissMode = .interactive
        collectionView.alwaysBounceVertical = true
        collectionView.allowsSelection = false
        collectionView.contentInsetAdjustmentBehavior = .automatic
        collectionView.delegate = self
        collectionView.scrollsToTop = true
        let dismissTap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        dismissTap.cancelsTouchesInView = false
        collectionView.addGestureRecognizer(dismissTap)
        collectionView.register(TextBubbleCell.self, forCellWithReuseIdentifier: TextBubbleCell.reuseID)
        collectionView.register(CodeBlockCell.self, forCellWithReuseIdentifier: CodeBlockCell.reuseID)
        collectionView.register(
            ImageBubbleCell.self, forCellWithReuseIdentifier: ImageBubbleCell.reuseID)
        collectionView.register(PermissionCell.self, forCellWithReuseIdentifier: PermissionCell.reuseID)
        collectionView.register(
            ActivityGroupCell.self, forCellWithReuseIdentifier: ActivityGroupCell.reuseID)
        collectionView.register(
            SubagentCardCell.self, forCellWithReuseIdentifier: SubagentCardCell.reuseID)
        collectionView.register(
            WorkflowCardCell.self, forCellWithReuseIdentifier: WorkflowCardCell.reuseID)
        collectionView.register(
            SubagentGroupCell.self, forCellWithReuseIdentifier: SubagentGroupCell.reuseID)
        collectionView.register(
            ThinkingCell.self, forCellWithReuseIdentifier: ThinkingCell.reuseID)
        collectionView.register(
            QuestionCell.self, forCellWithReuseIdentifier: QuestionCell.reuseID)
        collectionView.register(
            CompactionCell.self, forCellWithReuseIdentifier: CompactionCell.reuseID)

        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)

        [banner, composer].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview($0)
        }
        banner.isUserInteractionEnabled = true
        let bannerTap = UITapGestureRecognizer(target: self, action: #selector(bannerTapped))
        banner.addGestureRecognizer(bannerTap)

        attachmentStrip.axis = .horizontal
        attachmentStrip.spacing = Theme.Spacing.s
        attachmentStrip.isHidden = true
        agentsChip.isHidden = true
        agentsChip.translatesAutoresizingMaskIntoConstraints = false
        goalChip.isHidden = true
        goalChip.translatesAutoresizingMaskIntoConstraints = false
        composerAccessories.axis = .vertical
        composerAccessories.spacing = Theme.Spacing.xs
        composerAccessories.alignment = .leading
        composerAccessories.translatesAutoresizingMaskIntoConstraints = false
        composerAccessories.addArrangedSubview(attachmentStrip)
        composerAccessories.addArrangedSubview(goalChip)
        composerAccessories.addArrangedSubview(agentsChip)
        contextChip.isHidden = true
        contextChip.translatesAutoresizingMaskIntoConstraints = false
        spendChip.isHidden = true
        spendChip.translatesAutoresizingMaskIntoConstraints = false
        let chips = UIStackView(arrangedSubviews: [contextChip, spendChip])
        chips.axis = .horizontal
        chips.spacing = Theme.Spacing.xs
        composerAccessories.addArrangedSubview(chips)
        view.addSubview(composerAccessories)

        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            banner.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            banner.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            composer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            composer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])

        commandPalette.isHidden = true
        view.addSubview(commandPalette)
        NSLayoutConstraint.activate([
            commandPalette.leadingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: Theme.Spacing.l),
            commandPalette.trailingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -Theme.Spacing.l),
            commandPalette.bottomAnchor.constraint(
                equalTo: composerAccessories.topAnchor, constant: -Theme.Spacing.xs),
            commandPalette.topAnchor.constraint(
                greaterThanOrEqualTo: view.safeAreaLayoutGuide.topAnchor,
                constant: Theme.Spacing.s),
        ])

        NSLayoutConstraint.activate([
            composerAccessories.leadingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: Theme.Spacing.l),
            composerAccessories.trailingAnchor.constraint(
                lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -Theme.Spacing.l),
            composerAccessories.bottomAnchor.constraint(
                equalTo: composer.topAnchor, constant: -Theme.Spacing.xs),
        ])

        emptyState.translatesAutoresizingMaskIntoConstraints = false
        emptyState.isHidden = true
        emptyState.onSuggestion = { [weak self] prompt in self?.composer.setDraft(prompt) }
        view.insertSubview(emptyState, belowSubview: composer)
        NSLayoutConstraint.activate([
            emptyState.topAnchor.constraint(equalTo: collectionView.topAnchor),
            emptyState.leadingAnchor.constraint(equalTo: collectionView.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: collectionView.trailingAnchor),
            emptyState.bottomAnchor.constraint(equalTo: composer.topAnchor),
        ])

        loadingState.translatesAutoresizingMaskIntoConstraints = false
        loadingState.isHidden = true
        loadingState.isUserInteractionEnabled = false
        view.insertSubview(loadingState, belowSubview: composer)
        NSLayoutConstraint.activate([
            loadingState.topAnchor.constraint(equalTo: collectionView.topAnchor),
            loadingState.leadingAnchor.constraint(equalTo: collectionView.leadingAnchor),
            loadingState.trailingAnchor.constraint(equalTo: collectionView.trailingAnchor),
            loadingState.bottomAnchor.constraint(equalTo: composer.topAnchor),
        ])
    }

    /// A quiet chip above the composer while subagents are working — a session
    /// deep in fan-out work can leave the main transcript still for minutes,
    /// which otherwise reads as "nothing is happening".
    private func configureAgentsChip() {
        guard viewModel.supportsSubagents else { return }
        var config = UIButton.Configuration.gray()
        config.cornerStyle = .capsule
        config.buttonSize = .small
        config.image = UIImage(
            systemName: "circle.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 8))
        config.imagePadding = 6
        config.baseForegroundColor = Theme.Color.success
        agentsChip.configuration = config
        agentsChip.addAction(
            UIAction { [weak self] _ in
                guard let self else { return }
                let agents = self.viewModel.trackedSubagents
                guard !agents.isEmpty else { return }
                if agents.count == 1 {
                    self.revealSubagent(id: agents[0].id)
                } else {
                    self.presentSubagents(agents)
                }
            }, for: .touchUpInside)
        viewModel.startSubagentTracking()
    }

    private func refreshAgentsChip() {
        let live = viewModel.liveSubagentCount
        guard live > 0 else {
            agentsChip.isHidden = true
            return
        }
        agentsChip.configuration?.title = String(localized: "\(live) agents working")
        agentsChip.isHidden = false
    }

    private func configureGoalChip() {
        guard viewModel.supportsGoals else { return }
        var config = UIButton.Configuration.tinted()
        config.cornerStyle = .capsule
        config.buttonSize = .small
        config.image = UIImage(
            systemName: "target",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        config.imagePadding = 6
        config.baseForegroundColor = Theme.Color.warning
        config.baseBackgroundColor = Theme.Color.warning
        config.titleLineBreakMode = .byTruncatingTail
        goalChip.configuration = config
        goalChip.titleLabel?.lineBreakMode = .byTruncatingTail
        goalChip.accessibilityHint = String(localized: "Shows the goal the agent is working toward.")
        goalChip.addAction(
            UIAction { [weak self] _ in self?.presentGoalDetail() }, for: .touchUpInside)
    }

    /// The chip is the only place a pursued goal is visible, so it tracks the active goal exactly:
    /// a goal that has been met or cleared leaves nothing behind but the toast that announced it.
    private func updateGoalChip(for state: ConversationState) {
        guard viewModel.supportsGoals else { return }
        let previous = lastRenderedGoal
        lastRenderedGoal = state.goal
        if let active = state.activeGoal {
            goalChip.configuration?.title = active.condition
            goalChip.accessibilityLabel = String(localized: "Working toward: \(active.condition)")
            goalChip.isHidden = false
        } else {
            goalChip.isHidden = true
        }
        guard let settled = state.goal, settled.isMet, previous?.isActive == true,
            previous?.condition == settled.condition
        else { return }
        AppLogger.chat.info("goal reached: \(settled.condition)")
        Theme.Haptics.received()
        presentToast(String(localized: "Goal reached — \(settled.condition)"))
    }

    /// Asks for a stop condition rather than a message. A goal is a predicate the agent checks
    /// before it is allowed to finish, so it reads and writes differently from a prompt — worth its
    /// own field and its own words.
    private func presentGoalComposer() {
        let alert = UIAlertController(
            title: String(localized: "Set a goal"),
            message: String(
                localized:
                    "The agent keeps working until this is true, and won't stop early. You can close the app."
            ),
            preferredStyle: .alert)
        let scope = goalDraftScope
        alert.addTextField { field in
            field.placeholder = String(localized: "the test suite passes")
            field.autocapitalizationType = .none
            field.returnKeyType = .go
            field.text = DraftStore.text(for: scope)
            field.addAction(
                UIAction { [weak field] _ in DraftStore.record(field?.text ?? "", for: scope) },
                for: .editingChanged)
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(
            UIAlertAction(title: String(localized: "Start"), style: .default) {
                [weak self, weak alert] _ in
                guard let condition = alert?.textFields?.first?.text?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !condition.isEmpty
                else { return }
                DraftStore.clear(scope)
                self?.viewModel.setGoal(condition)
            })
        present(alert, animated: true)
    }

    /// Text search within the open conversation, with the desktop find bars' semantics: one
    /// match per row, case-insensitive, a live "n of m" count, next/previous that wrap, and the
    /// current hit ringed and scrolled into view.
    private func configureFindBar() {
        findBar.backgroundColor = Theme.Color.secondaryBackground
        findBar.layer.cornerRadius = 12
        findBar.layer.cornerCurve = .continuous
        findBar.layer.shadowColor = UIColor.black.cgColor
        findBar.layer.shadowOpacity = 0.15
        findBar.layer.shadowRadius = 8
        findBar.layer.shadowOffset = CGSize(width: 0, height: 2)
        findBar.isHidden = true
        findBar.translatesAutoresizingMaskIntoConstraints = false

        findField.placeholder = String(localized: "Find in conversation")
        findField.returnKeyType = .search
        findField.autocorrectionType = .no
        findField.autocapitalizationType = .none
        findField.addAction(
            UIAction { [weak self] _ in self?.runFind(retarget: true) }, for: .editingChanged)
        findField.addAction(
            UIAction { [weak self] _ in self?.stepFind(1) }, for: .primaryActionTriggered)

        findCountLabel.font = .preferredFont(forTextStyle: .caption1)
        findCountLabel.textColor = Theme.Color.secondaryLabel
        findCountLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let previous = UIButton(
            type: .system,
            primaryAction: UIAction(image: UIImage(systemName: "chevron.up")) { [weak self] _ in
                self?.stepFind(-1)
            })
        previous.accessibilityLabel = String(localized: "Previous match")
        let next = UIButton(
            type: .system,
            primaryAction: UIAction(image: UIImage(systemName: "chevron.down")) { [weak self] _ in
                self?.stepFind(1)
            })
        next.accessibilityLabel = String(localized: "Next match")
        let close = UIButton(
            type: .system,
            primaryAction: UIAction(image: UIImage(systemName: "xmark")) { [weak self] _ in
                self?.closeFind()
            })
        close.accessibilityLabel = String(localized: "Close find")

        let row = UIStackView(arrangedSubviews: [findField, findCountLabel, previous, next, close])
        row.axis = .horizontal
        row.spacing = Theme.Spacing.s
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        findBar.addSubview(row)
        view.addSubview(findBar)
        NSLayoutConstraint.activate([
            findBar.topAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.topAnchor, constant: Theme.Spacing.s),
            findBar.leadingAnchor.constraint(
                equalTo: view.leadingAnchor, constant: Theme.Spacing.l),
            findBar.trailingAnchor.constraint(
                equalTo: view.trailingAnchor, constant: -Theme.Spacing.l),
            row.topAnchor.constraint(equalTo: findBar.topAnchor, constant: Theme.Spacing.xs),
            row.bottomAnchor.constraint(equalTo: findBar.bottomAnchor, constant: -Theme.Spacing.xs),
            row.leadingAnchor.constraint(equalTo: findBar.leadingAnchor, constant: Theme.Spacing.m),
            row.trailingAnchor.constraint(
                equalTo: findBar.trailingAnchor, constant: -Theme.Spacing.m),
        ])
    }

    func openFind() {
        findVisible = true
        findBar.isHidden = false
        view.bringSubviewToFront(findBar)
        findField.becomeFirstResponder()
        runFind(retarget: true)
    }

    private func closeFind() {
        findVisible = false
        findBar.isHidden = true
        findField.resignFirstResponder()
        setFindHighlight(nil)
        findMatches = []
        findCountLabel.text = nil
    }

    private func runFind(retarget: Bool) {
        let previousID = findMatches.indices.contains(findCursor) ? findMatches[findCursor] : nil
        findMatches = ChatFind.matchingIDs(
            needle: findField.text ?? "", orderedIDs: orderedIDs, rowsByID: rowsByID)
        findCursor = ChatFind.cursor(
            matches: findMatches, previousID: previousID, previousCursor: findCursor,
            retarget: retarget)
        if findMatches.isEmpty {
            findCountLabel.text = (findField.text ?? "").trimmingCharacters(in: .whitespaces).isEmpty
                ? nil : String(localized: "No matches")
            setFindHighlight(nil)
            return
        }
        updateFindCount()
        applyFindHighlight(scroll: retarget)
    }

    private func stepFind(_ delta: Int) {
        guard !findMatches.isEmpty else { return }
        findCursor = (findCursor + delta + findMatches.count) % findMatches.count
        updateFindCount()
        applyFindHighlight(scroll: true)
    }

    private func updateFindCount() {
        findCountLabel.text = findMatches.isEmpty
            ? String(localized: "No matches")
            : "\(findCursor + 1)/\(findMatches.count)"
    }

    private func applyFindHighlight(scroll: Bool) {
        guard findMatches.indices.contains(findCursor) else {
            setFindHighlight(nil)
            return
        }
        let id = findMatches[findCursor]
        setFindHighlight(id)
        guard scroll else { return }
        userScrolledUp = true
        scrollTo(id: id)
    }

    /// The current hit carries an accent ring; rows scroll in and out of reuse, so the ring is
    /// re-applied in `willDisplay` and cleared here on whichever cell shows the old id.
    private func setFindHighlight(_ id: String?) {
        let previous = findHighlightedID
        findHighlightedID = id
        for indexPath in collectionView.indexPathsForVisibleItems {
            guard let cellID = dataSource.itemIdentifier(for: indexPath),
                cellID == previous || cellID == id,
                let cell = collectionView.cellForItem(at: indexPath)
            else { continue }
            decorateFindRing(cell, on: cellID == id)
        }
    }

    /// The match wears the palette's own search wash behind an accent edge — a ring alone is easy
    /// to lose in a long transcript, and the wash is the one slot authored for exactly this.
    private func decorateFindRing(_ cell: UICollectionViewCell, on: Bool) {
        cell.layer.cornerRadius = on ? 10 : 0
        cell.layer.cornerCurve = .continuous
        cell.layer.borderWidth = on ? 2 : 0
        cell.layer.borderColor =
            on
            ? Theme.Color.accent.withAlphaComponent(0.6).resolvedColor(with: traitCollection).cgColor
            : nil
        cell.backgroundColor = on ? Theme.Color.findHit : nil
    }

    /// `/compact` never fires bare: it costs minutes, cannot be undone, and takes an instruction
    /// most people don't know it accepts. The sheet is where that gets said.
    private func presentCompactPreflight(instruction: String = "") {
        let sheet = CompactPreflightViewController(
            messageCount: viewModel.state.messages.count(where: { $0.role != .system }),
            lastCompaction: viewModel.lastCompaction,
            initialInstruction: instruction,
            draftScope: compactionDraftScope
        ) { [weak self] instructions in
            self?.viewModel.compact(instructions: instructions)
        }
        let nav = UINavigationController(rootViewController: sheet)
        if let presentation = nav.sheetPresentationController {
            presentation.detents = [.large(), .medium()]
            presentation.selectedDetentIdentifier = .large
            presentation.prefersGrabberVisible = true
        }
        present(nav, animated: true)
    }

    private func presentCompactionSummary(_ row: CompactionRow) {
        guard let compaction = row.compaction, row.isReadable else { return }
        let nav = UINavigationController(
            rootViewController: CompactionSummaryViewController(compaction: compaction))
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        present(nav, animated: true)
    }

    private func presentGoalDetail() {
        guard let goal = viewModel.goal, goal.isActive else { return }
        let sheet = UIAlertController(
            title: String(localized: "Working toward"), message: goal.condition,
            preferredStyle: .actionSheet)
        sheet.addAction(
            UIAlertAction(title: String(localized: "Stop pursuing this"), style: .destructive) {
                [weak self] _ in
                self?.viewModel.clearGoal()
            })
        sheet.addAction(UIAlertAction(title: String(localized: "Keep going"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = goalChip
        sheet.popoverPresentationController?.sourceRect = goalChip.bounds
        present(sheet, animated: true)
    }

    private func configureFAB() {
        fab.configuration = fabConfiguration()
        fab.accessibilityLabel = String(localized: "Scroll to bottom")
        fab.translatesAutoresizingMaskIntoConstraints = false
        fab.isHidden = true
        fab.addTarget(self, action: #selector(fabTapped), for: .touchUpInside)
        view.addSubview(fab)
        NSLayoutConstraint.activate([
            fab.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -Theme.Spacing.l),
            fab.bottomAnchor.constraint(equalTo: composer.topAnchor, constant: -Theme.Spacing.m),
            fab.widthAnchor.constraint(greaterThanOrEqualToConstant: 44),
            fab.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    private func fabConfiguration() -> UIButton.Configuration {
        var config = Theme.Glass.buttonConfiguration()
        config.cornerStyle = .capsule
        config.image = UIImage(
            systemName: "chevron.down",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .bold))
        config.baseForegroundColor = Theme.Color.label
        if unreadCount > 0 {
            config.title = "\(unreadCount)"
            config.imagePadding = Theme.Spacing.xs
            config.baseForegroundColor = Theme.Color.accent
        }
        return config
    }

    private func configureNavTitleView() {
        navStatusLabel.font = .preferredFont(forTextStyle: .footnote)
        navStatusLabel.textColor = Theme.Color.secondaryLabel
        navStatusLabel.adjustsFontSizeToFitWidth = true
        navStatusLabel.minimumScaleFactor = 0.8
        let stack = UIStackView(arrangedSubviews: [navBadge, navStatusLabel])
        stack.axis = .horizontal
        stack.spacing = Theme.Spacing.s
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false
        navTitleContainer.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: navTitleContainer.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: navTitleContainer.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: navTitleContainer.leadingAnchor),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: navTitleContainer.trailingAnchor),
        ])
    }

    @objc private func sceneDidActivate() {
        suppressBannerUntil = Date().addingTimeInterval(3)
        viewModel.resync()
    }

    @objc private func bannerTapped() {
        Theme.Haptics.tap()
        if viewModel.isSignedOut {
            presentSignIn()
            return
        }
        viewModel.acknowledgeFailure()
        banner.hide()
        viewModel.refresh()
    }

    /// Signing the machine back in is the one repair a phone can make from here, so the banner
    /// leads straight to it rather than to a retry that will fail the same way.
    private func presentSignIn() {
        guard let authenticator = viewModel.authenticator else { return }
        let profile = ConnectionController.shared.profiles.first { $0.id == viewModel.contextID }
            ?? ConnectionController.shared.activeProfile
        guard let profile else { return }
        let signIn = ServerSignInViewController(profile: profile, backend: authenticator)
        signIn.onSignedIn = { [weak self] _ in
            guard let self else { return }
            self.viewModel.clearSignedOut()
            self.banner.hide()
            self.viewModel.refresh()
        }
        present(UINavigationController(rootViewController: signIn), animated: true)
    }

    private func configureDataSource() {
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
            [weak self] collectionView, indexPath, id in
            guard let self else { return Self.blankCell(collectionView, indexPath) }
            if id.hasPrefix("queued:"),
                let message = self.viewModel.queued.first(where: { "queued:\($0.id.uuidString)" == id })
            {
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: TextBubbleCell.reuseID, for: indexPath) as! TextBubbleCell
                cell.configure(
                    text: "⏳ \(message.text)", role: .user, reasoning: false)
                cell.contentView.alpha = 0.5
                return cell
            }
            if id == "thinking" {
                return collectionView.dequeueReusableCell(
                    withReuseIdentifier: ThinkingCell.reuseID, for: indexPath)
            }
            if let live = self.liveCompaction, live.id == id {
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: CompactionCell.reuseID, for: indexPath) as! CompactionCell
                cell.configure(live, onTap: nil)
                return cell
            }
            if id.hasPrefix("local:"), id.contains(":img"),
                let echo = self.viewModel.localEchoes.first(where: {
                    id.hasPrefix("local:\($0.id.uuidString):img")
                }),
                let index = Int(id.components(separatedBy: ":img").last ?? ""),
                echo.attachments.indices.contains(index)
            {
                let attachment = echo.attachments[index]
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: ImageBubbleCell.reuseID, for: indexPath) as! ImageBubbleCell
                cell.delegate = self
                cell.configure(
                    file: FileReference(
                        path: nil, mime: attachment.mime, url: "local:\(echo.id.uuidString):\(index)",
                        filename: attachment.filename),
                    role: .user, backend: self.viewModel.backend, localData: attachment.data)
                return cell
            }
            if id.hasPrefix("local:"),
                let echo = self.viewModel.localEchoes.first(where: { "local:\($0.id.uuidString)" == id })
            {
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: TextBubbleCell.reuseID, for: indexPath) as! TextBubbleCell
                cell.configure(text: echo.text, role: .user, reasoning: false)
                return cell
            }
            if id.hasPrefix("question:"), let request = self.pendingQuestion {
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: QuestionCell.reuseID, for: indexPath) as! QuestionCell
                cell.configure(
                    request: request,
                    selection: self.questionSelection,
                    submitted: self.answeredQuestionIDs.contains(request.id),
                    onSelectionChanged: { [weak self] selection in
                        self?.questionSelection = selection
                    },
                    onSubmit: { [weak self] answers in
                        guard let self, self.answeredQuestionIDs.insert(request.id).inserted
                        else { return }
                        self.viewModel.answerQuestion(request, answers: answers)
                    },
                    onCustom: { [weak self] questionIndex in
                        self?.promptCustomAnswer(for: request, questionIndex: questionIndex)
                    },
                    onSkip: { [weak self] in
                        guard let self, self.answeredQuestionIDs.insert(request.id).inserted
                        else { return }
                        self.viewModel.rejectQuestion(request)
                    })
                cell.turnInset = self.turnGap(at: indexPath)
                return cell
            }
            if id.hasPrefix("permission:"), let request = self.pendingPermission {
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: PermissionCell.reuseID, for: indexPath) as! PermissionCell
                cell.turnInset = self.turnGap(at: indexPath)
                cell.configure(
                    title: request.toolName.map { String(localized: "Allow \($0)?") }
                        ?? String(localized: "Permission requested"),
                    detail: request.title
                        ?? String(localized: "The agent needs your approval to continue.")
                ) { [weak self] decision in
                    self?.viewModel.respond(to: request, decision: decision)
                }
                return cell
            }
            guard let row = self.rowsByID[id] else { return Self.blankCell(collectionView, indexPath) }
            switch row.content {
            case .timestamp(let text):
                return self.bubble(collectionView, indexPath, text, .system, reasoning: false, timestamp: true)
            case .text(let text):
                return self.bubble(
                    collectionView, indexPath, text, row.role, reasoning: false,
                    cascade: self.cascade.tail(for: id))
            case .code(let block):
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: CodeBlockCell.reuseID, for: indexPath) as! CodeBlockCell
                cell.turnInset = self.turnGap(at: indexPath)
                cell.configure(
                    block, expanded: self.expandedReasoning.contains(id),
                    cascade: self.cascade.tail(for: id)
                ) {
                    [weak self] in self?.toggleReasoning(id)
                }
                return cell
            case .activity(let steps):
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: ActivityGroupCell.reuseID, for: indexPath)
                    as! ActivityGroupCell
                let streaming = self.viewModel.isBusy && id == self.streamingActivityID
                let toolTap: ((ToolCall) -> Void)? =
                    self.viewModel.supportsSubagents
                    ? { [weak self] call in self?.revealSubagent(spawnedBy: call) } : nil
                cell.turnInset = self.turnGap(at: indexPath)
                cell.configure(
                    steps: steps, expanded: self.expandedReasoning.contains(id),
                    streaming: streaming, compact: AppPreferences.compactActivity,
                    onToggle: { [weak self] in self?.toggleReasoning(id) },
                    onToolTap: toolTap,
                    onLinkTap: { [weak self] url in self?.openWebLink(url) })
                return cell
            case .workflow(let run):
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: WorkflowCardCell.reuseID, for: indexPath)
                    as! WorkflowCardCell
                cell.turnInset = self.turnGap(at: indexPath)
                cell.configure(
                    run, at: self.workflowNow,
                    onAgentTap: { [weak self] agentID in self?.openWorkflowAgent(agentID) })
                return cell
            case .subagent(let card):
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: SubagentCardCell.reuseID, for: indexPath)
                    as! SubagentCardCell
                cell.turnInset = self.turnGap(at: indexPath)
                cell.configure(
                    card,
                    onToggle: { [weak self] in self?.toggleSubagent(card.agentID) },
                    onLinkTap: { [weak self] url in self?.openWebLink(url) })
                return cell
            case .subagentGroup(let group):
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: SubagentGroupCell.reuseID, for: indexPath)
                    as! SubagentGroupCell
                cell.turnInset = self.turnGap(at: indexPath)
                cell.configure(group) { [weak self] in self?.toggleAgentGroup(group.id) }
                return cell
            case .compaction(let compaction):
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: CompactionCell.reuseID, for: indexPath) as! CompactionCell
                cell.configure(compaction) { [weak self] in
                    self?.presentCompactionSummary(compaction)
                }
                return cell
            case .file(let file):
                let label = "📎 \(file.filename ?? file.mime ?? String(localized: "attachment"))"
                return self.bubble(collectionView, indexPath, label, row.role, reasoning: false)
            case .image(let file):
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: ImageBubbleCell.reuseID, for: indexPath) as! ImageBubbleCell
                cell.delegate = self
                cell.onLoaded = { [weak self] in self?.remeasureRow(row.id) }
                cell.turnInset = self.turnGap(at: indexPath)
                cell.configure(file: file, role: row.role, backend: self.viewModel.backend)
                return cell
            case .error(let text):
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: TextBubbleCell.reuseID, for: indexPath) as! TextBubbleCell
                cell.configureError(text)
                return cell
            }
        }
    }

    /// Diffable providers must return dequeued cells; a raw
    /// `UICollectionViewCell()` throws NSInternalInconsistencyException when
    /// a row's backing state vanished between snapshot applies.
    private static func blankCell(
        _ collectionView: UICollectionView, _ indexPath: IndexPath
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: TextBubbleCell.reuseID, for: indexPath) as! TextBubbleCell
        cell.configure(text: "", role: .system, reasoning: false)
        return cell
    }

    private func bubble(
        _ collectionView: UICollectionView, _ indexPath: IndexPath, _ text: String,
        _ role: MessageRole, reasoning: Bool, timestamp: Bool = false,
        cascade: CascadeTail? = nil
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: TextBubbleCell.reuseID, for: indexPath) as! TextBubbleCell
        cell.turnInset = self.turnGap(at: indexPath)
        cell.configure(
            text: text, role: role, reasoning: reasoning, timestamp: timestamp, cascade: cascade)
        cell.linkDelegate = self
        return cell
    }

    /// One frame of the wave. The live row is repainted in place: the paragraph is measured once
    /// when its text arrives and never again, so a frame that only moves colours — the reveal and
    /// the band both — never touches the data source or the layout, and the transcript cannot
    /// jump under the reader. Only a row with no cell on screen falls back to a reconfigure.
    private func repaintCascade() {
        guard let id = cascade.key else { return }
        if repaintLiveCellInPlace(id) { return }
        var snapshot = dataSource.snapshot()
        guard snapshot.itemIdentifiers.contains(id) else { return }
        snapshot.reconfigureItems([id])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// The row the agent is writing into, revealed at reading speed rather than in whatever lumps
    /// the network delivered. Only the last row can be live — anything after it is proof the
    /// stream has moved on — and only prose and code grow a character at a time, so a tool call
    /// landing after a paragraph settles that paragraph rather than freezing it half-written.
    ///
    /// The row is held at its markdown-safe prefix so the renderer never sees `**bold` without its
    /// closer; how much of what it rendered is on screen is the cell's business, from the plan the
    /// driver hands it.
    private func paceCascade(_ rows: [ChatRow]) {
        let live = viewModel.isBusy
            ? rows.last.flatMap { $0.streamedText == nil ? nil : $0 } : nil
        let released = cascade.key
        guard let live, let source = live.streamedText else {
            cascade.release()
            if let released { settledCascadeRows.insert(released) }
            return
        }
        let safe = LiveCascade.renderable(source, sealed: !viewModel.isBusy)
        let row = safe == source ? live : live.held(to: safe)
        rowsByID[row.id] = row
        cascade.focus(
            row.id, rendered: Self.renderedText(of: row), sealed: !viewModel.isBusy,
            ultracode: viewModel.ultracodeInFlight
                || viewModel.currentEffort == Ultracode.effortLevel)
        if let released, released != cascade.key { settledCascadeRows.insert(released) }
    }

    /// One frame of the wave over the cell where it stands, so the data source never hears about
    /// a colour change. False when the row is off screen or has no cell to talk to, and the
    /// caller falls back to the data source.
    private func repaintLiveCellInPlace(_ id: String) -> Bool {
        guard let tail = cascade.tail(for: id), let row = rowsByID[id],
            let indexPath = dataSource.indexPath(for: id),
            let cell = collectionView.cellForItem(at: indexPath)
        else { return false }
        switch (row.content, cell) {
        case (.text(let text), let bubble as TextBubbleCell):
            bubble.applyCascade(tail, text: text, reasoning: false)
            return true
        case (.code(let block), let code as CodeBlockCell):
            code.applyCascade(tail, block: block)
            return true
        default:
            return false
        }
    }

    /// What the reveal counts: the characters a reader will actually see, markers already eaten by
    /// the renderer whose output the cell will show.
    private static func renderedText(of row: ChatRow) -> String {
        switch row.content {
        case .text(let text):
            return TextBubbleCell.rendered(text, color: Theme.Color.label).string
        case .code(let block):
            return block.source
        default:
            return ""
        }
    }

    private func bind() {
        cascade.onFrame = { [weak self] in self?.repaintCascade() }
        viewModel.onState = { [weak self] state in self?.render(state) }
        viewModel.onSignInStateChanged = { [weak self] in
            guard let self else { return }
            self.updateBanner(for: self.viewModel.state)
        }
        viewModel.onModelChange = { [weak self] in self?.updateNavControls() }
        viewModel.onCommandsChange = { [weak self] in
            guard let self, !self.commandPalette.isHidden else { return }
            self.updateCommandPalette(for: self.composer.currentText)
        }
        viewModel.onSubagentsChange = { [weak self] in
            guard let self else { return }
            self.refreshAgentsChip()
            self.render(self.viewModel.state)
        }
        viewModel.onError = { [weak self] message in self?.presentError(message) }
        viewModel.onTitleChange = { [weak self] in
            guard let self else { return }
            self.title = self.navDisplayTitle
        }
        viewModel.onQuestionFailed = { [weak self] questionID in
            guard let self else { return }
            self.answeredQuestionIDs.remove(questionID)
            var snapshot = self.dataSource.snapshot()
            let id = "question:\(questionID)"
            if snapshot.itemIdentifiers.contains(id) {
                snapshot.reconfigureItems([id])
                self.dataSource.apply(snapshot, animatingDifferences: false)
            }
        }
        viewModel.onSendFailed = { [weak self] text in
            guard let self else { return }
            Theme.Haptics.error()
            if self.composer.currentText.isEmpty {
                self.composer.setDraft(text, focus: false)
                DraftStore.record(text, for: self.draftScope)
                self.flushDraft()
                self.presentToast(
                    String(localized: "Not sent — your message is back in the composer."))
            } else {
                UIPasteboard.general.string = text
                self.presentToast(String(localized: "Not sent — message copied to clipboard."))
            }
        }
    }

    private func render(_ state: ConversationState) {
        let runs = WorkflowRunAssembly.runs(
            messages: state.messages, agents: viewModel.trackedSubagents, now: workflowNow)
        workflowRuns = runs
        lastRenderedState = state
        updateWorkflowTicker()
        let rows = ChatRowBuilder.makeRows(
            from: state.messages, agents: subagentPlacement(for: state.messages),
            runs: Dictionary(uniqueKeysWithValues: runs.map { ($0.id, $0) }))
        let previous = rowsByID
        rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        orderedIDs = rows.map(\.id)
        paceCascade(rows)
        streamingActivityID = orderedIDs.last(where: { id in
            guard let content = rowsByID[id]?.content else { return false }
            if case .activity = content { return true }
            return false
        })

        if AppPreferences.autoExpandThinking {
            for row in rows where isActivity(row) && !seenReasoning.contains(row.id) {
                seenReasoning.insert(row.id)
                expandedReasoning.insert(row.id)
            }
            if seenReasoning.count > 500 {
                let oldest = seenReasoning.sorted().prefix(seenReasoning.count - 300)
                seenReasoning.subtract(oldest)
                expandedReasoning.subtract(oldest)
            }
        }

        let previousPermissionID = pendingPermission?.id
        let previousQuestionID = pendingQuestion?.id
        pendingPermission = state.pendingPermissions.first
        if pendingQuestion?.id != state.pendingQuestions.first?.id {
            questionSelection = QuestionCell.Selection()
        }
        pendingQuestion = state.pendingQuestions.first
        withdrawResolvedRequests(
            previousPermission: previousPermissionID, previousQuestion: previousQuestionID)
        var ids = orderedIDs
        for echo in viewModel.localEchoes {
            for index in echo.attachments.indices {
                ids.append("local:\(echo.id.uuidString):img\(index)")
            }
            if !echo.text.isEmpty || echo.attachments.isEmpty {
                ids.append("local:\(echo.id.uuidString)")
            }
        }
        let lastContentRole: MessageRole? =
            viewModel.localEchoes.isEmpty
            ? orderedIDs.last.flatMap { rowsByID[$0]?.role } : .user
        liveCompaction = state.compaction.map {
            CompactionRow(
                id: $0.isRunning ? "compacting" : "compaction-failed",
                state: $0.failure.map { .failed($0) } ?? .running(startedAt: $0.startedAt))
        }
        if let liveCompaction {
            ids.append(liveCompaction.id)
        } else if viewModel.isBusy, pendingPermission == nil, pendingQuestion == nil,
            lastContentRole != .assistant
        {
            ids.append("thinking")
        }
        if let pendingQuestion { ids.append("question:\(pendingQuestion.id)") }
        if let pendingPermission { ids.append("permission:\(pendingPermission.id)") }
        for message in viewModel.queued { ids.append("queued:\(message.id.uuidString)") }
        Self.logPendingPhantom(state: state, viewModel: viewModel)
        renderedIDOrder = ids
        let idSet = Set(ids)
        let entranceEligible = hasRevealed && !userScrolledUp
        let entranceBubbles =
            entranceEligible
            ? ids.filter {
                !lastRenderedIDs.contains($0)
                    && ($0.hasPrefix("local:") || $0.hasPrefix("queued:"))
            } : []
        let entranceThinking =
            entranceEligible && ids.contains("thinking") && !lastRenderedIDs.contains("thinking")
        lastRenderedIDs = idSet

        let handOffEmptyState =
            isHandingOffEmptyState && !emptyState.isHidden && !entranceBubbles.isEmpty
        isHandingOffEmptyState = false
        deferEmptyStateHide = handOffEmptyState
        updatePlaceholders(hasRows: !ids.isEmpty, for: state)
        deferEmptyStateHide = false

        let nearBottom = isNearBottom()
        var snapshot = NSDiffableDataSourceSnapshot<Section, String>()
        snapshot.appendSections([.main])
        snapshot.appendItems(ids, toSection: .main)

        var changed = orderedIDs.filter { previous[$0] != nil && previous[$0] != rowsByID[$0] }
        for id in settledCascadeRows where rowsByID[id] != nil && !changed.contains(id) {
            changed.append(id)
        }
        settledCascadeRows.removeAll()
        let streamingID = viewModel.isBusy ? streamingActivityID : nil
        if streamingID != lastStreamingID {
            for id in [streamingID, lastStreamingID].compactMap({ $0 })
            where rowsByID[id] != nil && !changed.contains(id) {
                changed.append(id)
            }
            lastStreamingID = streamingID
        }
        let previousToolStatuses = Self.collectToolStatuses(from: previous.values.flatMap { row in
            if case .activity(let steps) = row.content { return steps }
            return []
        })
        let currentToolStatuses = Self.collectToolStatuses(from: rows.flatMap { row in
            if case .activity(let steps) = row.content { return steps }
            return []
        })
        for (id, previousStatus) in previousToolStatuses {
            if let currentStatus = currentToolStatuses[id],
                previousStatus != currentStatus, currentStatus == .completed
            {
                Theme.Haptics.step()
            }
        }
        let animated = animateNextRender && hasRevealed
        animateNextRender = false
        let reconfigurable = changed.filter { idSet.contains($0) }
        if !reconfigurable.isEmpty { snapshot.reconfigureItems(reconfigurable) }
        if !entranceBubbles.isEmpty || entranceThinking {
            dataSource.apply(snapshot, animatingDifferences: false) { [weak self] in
                guard let self else { return }
                self.updateTranscriptInsets()
                self.scrollToBottom(animated: false)
                self.collectionView.layoutIfNeeded()
                if handOffEmptyState { self.animateEmptyStateHandoff() }
                self.animateSendEntrance(
                    bubbleIDs: entranceBubbles, includeThinking: entranceThinking)
            }
        } else {
            dataSource.apply(snapshot, animatingDifferences: animated) { [weak self] in
                guard let self else { return }
                self.updateTranscriptInsets()
                if nearBottom && !self.userScrolledUp { self.scrollToBottom(animated: animated) }
                if !self.hasRevealed && !self.orderedIDs.isEmpty { self.revealTranscript() }
            }
        }

        composer.setBusy(viewModel.isBusy)
        syncFAB()
        noteUnread(orderedIDs.filter { previous[$0] == nil }.count)
        updateNavStatus(for: state)
        if wasRunning && state.status != .running {
            Theme.Haptics.received()
            refreshSpend()
        }
        wasRunning = state.status == .running
        if let permission = pendingPermission, permission.id != lastHapticPermissionID {
            lastHapticPermissionID = permission.id
            Theme.Haptics.needsYou()
        }
        if let permission = pendingPermission, permission.id != lastNotifiedPermissionID {
            lastNotifiedPermissionID = permission.id
            NotificationManager.notify(
                kind: .approval,
                title: viewModel.title,
                body: permission.toolName.map { String(localized: "Approval needed: \($0)") }
                    ?? String(localized: "Approval needed."),
                identifier: "perm:\(permission.id)", sessionID: viewModel.session.id,
                profileID: viewModel.contextID, activity: .needsApproval)
        }
        if let question = pendingQuestion, question.id != lastNotifiedQuestionID {
            lastNotifiedQuestionID = question.id
            Theme.Haptics.needsYou()
            NotificationManager.notify(
                kind: .approval,
                title: viewModel.title,
                body: question.questions.first?.question
                    ?? String(localized: "The agent has a question."),
                identifier: "question:\(question.id)", sessionID: viewModel.session.id,
                profileID: viewModel.contextID, activity: .needsAnswer)
        }
        updateBanner(for: state)
        updateGoalChip(for: state)
        updateOverflowBadge(hasPermission: pendingPermission != nil)
        if findVisible, !viewModel.isBusy || orderedIDs.count != lastFindRowCount {
            lastFindRowCount = orderedIDs.count
            runFind(retarget: false)
        }
    }

    /// Distinguishes "history is still on its way" from "genuinely empty":
    /// until the transcript has actually loaded (or failed to), an empty
    /// conversation shows a spinner, not the suggestion chips — a session
    /// started on another machine must never flash the empty state while its
    /// history is in flight.
    private func updatePlaceholders(hasRows: Bool, for state: ConversationState) {
        let settled =
            state.hasLoadedTranscript || state.lastFailure != nil
            || state.connection == .offline
        loadingState.isHidden = !(hasRevealed && !hasRows && !settled)
        setEmptyStateVisible(hasRevealed && !hasRows && settled)
    }

    /// The suggestion chips fade rather than hard-cut, so a first send reads
    /// as the empty state yielding to the conversation.
    private func setEmptyStateVisible(_ visible: Bool) {
        if visible {
            if emptyState.isHidden {
                emptyState.alpha = 0
                emptyState.isHidden = false
            }
            UIView.animate(withDuration: 0.2) { self.emptyState.alpha = 1 }
        } else {
            guard !emptyState.isHidden else { return }
            if deferEmptyStateHide { return }
            UIView.animate(
                withDuration: 0.18,
                animations: { self.emptyState.alpha = 0 },
                completion: { _ in self.emptyState.isHidden = true })
        }
    }

    /// Lifts the suggestion chips out in the same beat the first message springs
    /// up from the composer, so the empty state yielding to the conversation
    /// reads as one motion instead of a fade racing the entrance and a scroll snap.
    private func animateEmptyStateHandoff() {
        guard !emptyState.isHidden else { return }
        UIView.animate(
            withDuration: 0.45, delay: 0, usingSpringWithDamping: 0.85,
            initialSpringVelocity: 0.4, options: [.curveEaseIn, .allowUserInteraction]
        ) {
            self.emptyState.alpha = 0
            self.emptyState.transform =
                CGAffineTransform(translationX: 0, y: -16).scaledBy(x: 0.98, y: 0.98)
        } completion: { _ in
            self.emptyState.isHidden = true
            self.emptyState.alpha = 1
            self.emptyState.transform = .identity
        }
    }

    /// A sent message springs up from the composer into place, then the
    /// thinking indicator rises in just behind it — the bubble should feel
    /// like it physically leaves the input field.
    private func animateSendEntrance(bubbleIDs: [String], includeThinking: Bool) {
        let snapshot = dataSource.snapshot()
        var targets: [(cell: UICollectionViewCell, delay: TimeInterval, rise: CGFloat)] = []
        for id in bubbleIDs {
            guard let index = snapshot.indexOfItem(id),
                let cell = collectionView.cellForItem(at: IndexPath(item: index, section: 0))
            else { continue }
            targets.append((cell, 0, 44))
        }
        if includeThinking, let index = snapshot.indexOfItem("thinking"),
            let cell = collectionView.cellForItem(at: IndexPath(item: index, section: 0))
        {
            targets.append((cell, targets.isEmpty ? 0 : 0.12, 18))
        }
        for target in targets {
            let content = target.cell.contentView
            let finalAlpha = content.alpha
            let isBubble = target.rise > 20
            content.alpha = 0
            content.transform = isBubble
                ? CGAffineTransform(translationX: 0, y: target.rise).scaledBy(x: 0.96, y: 0.96)
                : CGAffineTransform(translationX: 0, y: target.rise)
            UIView.animate(
                withDuration: 0.55, delay: target.delay, usingSpringWithDamping: 0.8,
                initialSpringVelocity: 0.4, options: [.allowUserInteraction]
            ) {
                content.alpha = finalAlpha
                content.transform = .identity
            }
        }
    }

    private func updateBanner(for state: ConversationState) {
        guard UIApplication.shared.applicationState == .active else {
            banner.hide()
            return
        }
        viewModel.noteSignedOutIfHinted(state)
        if viewModel.isSignedOut {
            banner.show(
                String(localized: "Claude is signed out on this machine — tap to sign in"),
                color: Theme.Color.warning, symbol: "person.badge.key")
            return
        }
        switch state.connection {
        case .reconnecting:
            if Date() > suppressBannerUntil {
                banner.show(
                    String(localized: "Reconnecting…"), color: Theme.Color.warning,
                    symbol: "wifi.exclamationmark")
            }
        case .offline:
            if Date() > suppressBannerUntil {
                banner.show(
                    String(localized: "Offline — tap to retry"), color: Theme.Color.danger,
                    symbol: "wifi.slash")
            }
        case .connecting, .live:
            if applyQuotaExhaustion(for: state) { return }
            if let failure = state.lastFailure, failure != viewModel.dismissedFailure,
                state.status != .running, Date() > suppressBannerUntil
            {
                banner.show(
                    failure.message, color: Theme.Color.danger,
                    symbol: "exclamationmark.triangle.fill")
                if lastHapticFailure != failure.message {
                    lastHapticFailure = failure.message
                    Theme.Haptics.error()
                }
            } else {
                banner.hide()
            }
        }
    }

    /// A used-up quota is a state, not a generic failure: name the window, say when it resets,
    /// and leave the raw rate-limit string behind. Pre-emptive when gauges are already full, and
    /// after a turn dies of a rate limit.
    @discardableResult
    private func applyQuotaExhaustion(for state: ConversationState) -> Bool {
        guard Date() > suppressBannerUntil, state.status != .running else { return false }
        let quotas = UsageWidgetStore.cachedQuotas()
        let failure: String? = {
            guard let f = state.lastFailure, f != viewModel.dismissedFailure else { return nil }
            return f.message
        }()
        let exhaustion: QuotaExhaustion?
        if let failure {
            exhaustion = QuotaSurface.resolve(failureMessage: failure, quotas: quotas)
        } else {
            exhaustion = QuotaSurface.hottestExhausted(
                in: QuotaSurface.relevantQuotas(for: viewModel.backend.agentType, among: quotas))
        }
        guard let exhaustion else { return false }
        banner.show(
            QuotaSurface.bannerBody(exhaustion), color: Theme.Color.danger,
            symbol: "gauge.with.dots.needle.100percent")
        let key = "\(exhaustion.provider)|\(exhaustion.window)|\(exhaustion.source)"
        if lastHapticFailure != key {
            lastHapticFailure = key
            Theme.Haptics.warning()
        }
        return true
    }



    @objc private func fabTapped() {
        userScrolledUp = false
        clearUnread()
        scrollToBottom(animated: true)
        Theme.Haptics.tap()
    }

    private func syncFAB() {
        let show = !isNearBottom() && orderedIDs.count > 1
        if !show { clearUnread() }
        guard fab.isHidden == show else { return }
        if show {
            fab.isHidden = false
            fab.alpha = 0
            fab.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
            UIView.animate(
                withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.7, initialSpringVelocity: 0.5
            ) {
                self.fab.alpha = 1
                self.fab.transform = .identity
            }
        } else {
            UIView.animate(
                withDuration: 0.15,
                animations: {
                    self.fab.alpha = 0
                    self.fab.transform = CGAffineTransform(scaleX: 0.6, y: 0.6)
                },
                completion: { _ in
                    self.fab.isHidden = true
                    self.fab.transform = .identity
                    self.fab.alpha = 1
                })
        }
    }

    private func noteUnread(_ count: Int) {
        guard count > 0, userScrolledUp, !fab.isHidden else { return }
        unreadCount += count
        fab.configuration = fabConfiguration()
        fab.accessibilityLabel = String(localized: "Scroll to bottom, \(unreadCount) new")
    }

    private func clearUnread() {
        guard unreadCount != 0 else { return }
        unreadCount = 0
        fab.configuration = fabConfiguration()
        fab.accessibilityLabel = String(localized: "Scroll to bottom")
    }

    private var turnStartedAt: Date?
    private var elapsedTicker: Task<Void, Never>?
    private var lastStatusPhaseText = ""
    private var contextEstimate: Int?
    private var countedMessages = -1

    /// The nav status states the same facts as the desktop status bands — phase, running tool,
    /// clock — derived through the shared `StatusFacts` rather than a private phase guess. The
    /// richer iOS wording for the busy line still comes from `liveStatus`, but the phase and
    /// color are the facts'.
    private func updateNavStatus(for state: ConversationState) {
        if state.messages.count != countedMessages {
            countedMessages = state.messages.count
            contextEstimate = StatusFacts.estimateContextTokens(state.messages)
        }
        updateContextChip()
        updateSpendChip()
        let facts = StatusFacts.from(
            state: state, turnStartedAt: turnStartedAt, agents: viewModel.trackedSubagents,
            usage: nil, attachments: pendingAttachments.count, contextTokens: contextEstimate,
            queued: viewModel.queued.count)
        var text: String?
        var color = Theme.Color.secondaryLabel
        switch facts.phase {
        case .idle, .offline, .connecting:
            text = nil
        case .working:
            text = ChatViewModel.liveStatus(for: state).text
        case .compacting:
            text = String(localized: "Compacting…")
        case .awaitingApproval:
            text = ChatViewModel.liveStatus(for: state).text
            color = Theme.Color.warning
        case .awaitingAnswer:
            text = String(localized: "Waiting for your answer")
            color = Theme.Color.warning
        case .reconnecting:
            text = String(localized: "Reconnecting…")
            color = Theme.Color.warning
        case .failed:
            text = nil
        }
        if let phase = text, facts.queued > 0 {
            text = phase + " · " + ActivityKind.queued(facts.queued).bandWord
        }
        guard let text else {
            navBadge.activity = nil
            navigationItem.titleView = nil
            turnStartedAt = nil
            elapsedTicker?.cancel()
            elapsedTicker = nil
            lastStatusPhaseText = ""
            return
        }
        if viewModel.isBusy, turnStartedAt == nil {
            turnStartedAt = Date()
            elapsedTicker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    self?.renderNavStatus()
                }
            }
        }
        if navigationItem.titleView == nil {
            navTitleContainer.frame = CGRect(x: 0, y: 0, width: 190, height: 30)
            navigationItem.titleView = navTitleContainer
        }
        navBadge.activity = facts.activity
        if lastStatusPhaseText != text {
            lastStatusPhaseText = text
            UIView.transition(
                with: navStatusLabel, duration: 0.2, options: .transitionCrossDissolve
            ) {
                self.navStatusLabel.textColor = color
                self.renderNavStatus()
            }
        } else {
            navStatusLabel.textColor = color
            renderNavStatus()
        }
    }

    private func renderNavStatus() {
        guard !lastStatusPhaseText.isEmpty else { return }
        guard let started = turnStartedAt else {
            navStatusLabel.text = lastStatusPhaseText
            return
        }
        let seconds = Int(Date().timeIntervalSince(started))
        let elapsed = seconds >= 60
            ? String(format: "%d:%02d", seconds / 60, seconds % 60) : "\(seconds)s"
        navStatusLabel.text = seconds >= 3
            ? "\(lastStatusPhaseText) · \(elapsed)" : lastStatusPhaseText
    }

    /// The transcript's own size in tokens, always visible above the composer once it is worth
    /// knowing — the same `~` estimate the desktop bands show, one tap from Compact.
    private func configureContextChip() {
        var config = UIButton.Configuration.gray()
        config.cornerStyle = .capsule
        config.buttonSize = .small
        config.image = UIImage(
            systemName: "cylinder.split.1x2",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 9))
        config.imagePadding = 6
        config.baseForegroundColor = Theme.Color.secondaryLabel
        contextChip.configuration = config
        contextChip.accessibilityHint = String(
            localized: "Estimated conversation size. Opens compaction.")
        contextChip.addAction(
            UIAction { [weak self] _ in self?.presentCompactPreflight() }, for: .touchUpInside)
    }

    /// The conversation's price, once the server can account for it. It opens the whole account —
    /// what each turn cost, where the money went between fresh tokens and cache, which model spent
    /// it — because a number with no story behind it is a number nobody trusts.
    private func configureSpendChip() {
        var config = UIButton.Configuration.gray()
        config.cornerStyle = .capsule
        config.buttonSize = .small
        config.image = UIImage(
            systemName: "creditcard",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 9))
        config.imagePadding = 6
        config.baseForegroundColor = Theme.Color.secondaryLabel
        spendChip.configuration = config
        spendChip.accessibilityHint = String(
            localized: "What this conversation has cost. Opens the breakdown.")
        spendChip.addAction(
            UIAction { [weak self] _ in self?.presentSpend() }, for: .touchUpInside)
    }

    private func updateSpendChip() {
        guard let spend, !spend.isEmpty else {
            spendChip.isHidden = true
            return
        }
        spendChip.configuration?.title = spend.badge
        spendChip.isHidden = false
    }

    private func presentSpend() {
        guard let spend, !spend.isEmpty else { return }
        Theme.Haptics.tap()
        let panel = SpendViewController(spend: spend, title: title ?? viewModel.session.title)
        let nav = UINavigationController(rootViewController: panel)
        nav.modalPresentationStyle = .pageSheet
        nav.sheetPresentationController?.detents = [.medium(), .large()]
        nav.sheetPresentationController?.prefersGrabberVisible = true
        present(nav, animated: true)
    }

    /// Asked of the server on the same slow poll as the agents; a backend that cannot account for
    /// the conversation falls back to whatever the transcript already in hand can be made to say.
    private func refreshSpend() {
        let sessionID = viewModel.session.id
        Task { [weak self] in
            guard let self else { return }
            let report = try? await self.viewModel.backend.sessionSpend(sessionID)
            guard self.viewModel.session.id == sessionID else { return }
            self.spend = report.map(SessionSpend.init(report:))
                ?? SessionSpend(messages: self.viewModel.state.messages)
            self.updateSpendChip()
        }
    }

    private func updateContextChip() {
        guard let contextEstimate, viewModel.supportsCompaction else {
            contextChip.isHidden = true
            return
        }
        contextChip.configuration?.title = "~\(StatusFacts.tokens(contextEstimate))"
        contextChip.configuration?.baseForegroundColor =
            contextEstimate > 300_000 ? Theme.Color.warning : Theme.Color.secondaryLabel
        contextChip.isHidden = false
    }

    private static func collectToolStatuses(from steps: [ActivityStep]) -> [String: ToolStatus] {
        var map: [String: ToolStatus] = [:]
        for step in steps {
            if case .tool(let call) = step { map[call.id] = call.status }
        }
        return map
    }

    /// The transcript stays invisible through the initial empty → cached →
    /// refreshed snapshot churn, then fades in once, already scrolled to the
    /// bottom. The fallback timer reveals chats with nothing to show yet —
    /// a spinner while history is still loading, the empty state otherwise.
    private func revealTranscript() {
        guard !hasRevealed else { return }
        hasRevealed = true
        revealFallback?.cancel()
        collectionView.layoutIfNeeded()
        scrollToBottom(animated: false)
        let hasRows =
            !orderedIDs.isEmpty || !viewModel.localEchoes.isEmpty || !viewModel.queued.isEmpty
        updatePlaceholders(hasRows: hasRows, for: viewModel.state)
        UIView.animate(withDuration: 0.22, delay: 0, options: .curveEaseOut) {
            self.collectionView.alpha = 1
        }
    }

    private func withdrawResolvedRequests(previousPermission: String?, previousQuestion: String?) {
        var stale: [String] = []
        if let previousPermission, previousPermission != pendingPermission?.id {
            stale.append("perm:\(previousPermission)")
        }
        if let previousQuestion, previousQuestion != pendingQuestion?.id {
            stale.append("question:\(previousQuestion)")
        }
        NotificationManager.withdraw(identifiers: stale)
    }

    private func isActivity(_ row: ChatRow) -> Bool {
        if case .activity = row.content { return true }
        return false
    }

    #if DEBUG
        /// Opens the first attached image full screen, so the viewer can be
        /// captured from a script the way every other screen already can be.
        private func openFirstAttachment() {
            for cell in collectionView.visibleCells {
                guard let cell = cell as? ImageBubbleCell, let image = cell.displayedImage else {
                    continue
                }
                imageBubbleCell(cell, didTap: image, from: cell.imageContainer)
                return
            }
        }

        /// Runs the save an attachment's context menu would run, so the photo
        /// library path can be exercised from a script the way the viewer can.
        private func saveFirstAttachment() {
            for cell in collectionView.visibleCells {
                guard let payload = (cell as? ImageBubbleCell)?.payload else { continue }
                saveToPhotos(payload)
                return
            }
        }
    #endif

    /// Re-runs one row's cell provider so a now-decoded image is laid out at
    /// its real aspect ratio instead of the placeholder's.
    private func remeasureRow(_ id: String) {
        var snapshot = dataSource.snapshot()
        guard snapshot.itemIdentifiers.contains(id) else { return }
        snapshot.reconfigureItems([id])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func toggleReasoning(_ id: String) {
        if expandedReasoning.contains(id) {
            expandedReasoning.remove(id)
        } else {
            expandedReasoning.insert(id)
        }
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems([id])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// The extra breathing room above a row that opens a new turn. Rows that
    /// share their message and role stay tight, so a turn reads as one cluster
    /// and the transcript moves in a rhythm instead of a uniform grid.
    private func turnGap(at indexPath: IndexPath) -> CGFloat {
        let order = renderedIDOrder
        guard indexPath.item > 0, indexPath.item < order.count else { return 0 }
        let previousID = order[indexPath.item - 1]
        guard let previous = rowsByID[previousID] else { return Theme.Spacing.m }
        guard let current = rowsByID[order[indexPath.item]] else { return Theme.Spacing.m }
        return (current.messageID != previous.messageID || current.role != previous.role)
            ? Theme.Spacing.m : 0
    }

    private func loadModels() async {
        availableModels = await viewModel.availableModels()
        updateNavControls()
    }

    private func updateNavControls() {
        var items: [UIBarButtonItem] = []
        if viewModel.supportsModelSelection || viewModel.supportsReasoningEffort {
            items.append(modelBarButton())
        }
        items.append(overflowBarButton())
        navigationItem.rightBarButtonItems = items
        refreshAttachmentGating()
        composer.ultracodeEffort = viewModel.currentEffort
        composer.ultracodeInFlight = viewModel.ultracodeInFlight
    }

    /// A model that takes no images can still take files — the agent opens those
    /// on the server — so the affordance survives a switch to a text-only model.
    private var canAttachAnything: Bool {
        viewModel.canAttachImages || viewModel.canAttachFiles
    }

    /// Keeps the attach affordance in sync with what the selected model can
    /// actually see: hides the picker for text-only models and drops pending
    /// image attachments that a model switch made unsendable.
    private func refreshAttachmentGating() {
        if !viewModel.canAttachImages, pendingAttachments.contains(where: { $0.mime.hasPrefix("image/") }) {
            pendingAttachments.removeAll { $0.mime.hasPrefix("image/") }
            updateAttachmentStrip()
            presentToast(String(localized: "Image removed — this model can't see images."))
        }
        composer.showsAttach = canAttachAnything
    }

    /// Marks the overflow button while a permission waits, by tint rather than by
    /// a badged symbol: `ellipsis.circle.badge.exclamationmark` does not exist, so
    /// asking for it returned nil and blanked the button in the one state where
    /// the menu behind it matters most.
    private func updateOverflowBadge(hasPermission: Bool) {
        guard let barItem = navigationItem.rightBarButtonItems?.last else { return }
        barItem.image = UIImage(systemName: "ellipsis.circle")
        barItem.tintColor = hasPermission ? Theme.Color.warning : nil
    }

    private func overflowBarButton() -> UIBarButtonItem {
        let jump = UIDeferredMenuElement.uncached { [weak self] completion in
            guard let self else { return completion([]) }
            let prompts = self.orderedIDs.compactMap { id -> UIAction? in
                guard let row = self.rowsByID[id], row.role == .user,
                    case .text(let text) = row.content
                else { return nil }
                return UIAction(title: String(text.prefix(50))) { [weak self] _ in
                    self?.scrollTo(id: id)
                }
            }
            guard !prompts.isEmpty else { return completion([]) }
            completion([
                UIMenu(
                    title: String(localized: "Jump to message"),
                    image: UIImage(systemName: "list.bullet"),
                    children: Array(prompts.suffix(20)))
            ])
        }
        let usage = UIDeferredMenuElement.uncached { [weak self] completion in
            Task { @MainActor in
                guard let self, self.viewModel.supportsUsage, let usage = await self.viewModel.usage() else { return completion([]) }
                var parts: [String] = []
                if let tokens = usage.tokens {
                    parts.append(
                        String(localized: "\(tokens.formatted(.number.notation(.compactName))) tokens"))
                }
                if let cost = usage.costUSD {
                    parts.append(String(format: "$%.3f", cost))
                }
                guard !parts.isEmpty else { return completion([]) }
                let item = UIAction(
                    title: String(localized: "Last turn · \(parts.joined(separator: " · "))"),
                    image: UIImage(systemName: "gauge.with.dots.needle.bottom.50percent"),
                    attributes: .disabled
                ) { _ in }
                completion([item])
            }
        }
        let regenerate = UIDeferredMenuElement.uncached { [weak self] completion in
            guard let self, self.viewModel.canRegenerate else { return completion([]) }
            completion([
                UIAction(
                    title: String(localized: "Regenerate"),
                    image: UIImage(systemName: "arrow.clockwise")
                ) {
                    [weak self] _ in
                    Theme.Haptics.tap()
                    self?.viewModel.regenerate()
                }
            ])
        }
        let subagents = UIDeferredMenuElement.uncached { [weak self] completion in
            guard let self, self.viewModel.supportsSubagents else {
                return completion([])
            }
            let agents = self.viewModel.trackedSubagents
            guard !agents.isEmpty else { return completion([]) }
            let live = agents.count(where: \.isActive)
            let title =
                live > 0
                ? String(localized: "Agents (\(agents.count) · \(live) live)")
                : String(localized: "Agents (\(agents.count))")
            completion([
                UIAction(
                    title: title,
                    image: UIImage(systemName: "point.3.connected.trianglepath.dotted")
                ) { [weak self] _ in self?.presentSubagents(agents) }
            ])
        }
        let save = UIDeferredMenuElement.uncached { [weak self] completion in
            guard let self else { return completion([]) }
            let isSaved = SavedChatStore.contains(
                profileID: self.viewModel.contextID, sessionID: self.viewModel.session.id)
            completion([
                UIAction(
                    title: isSaved
                        ? String(localized: "Remove from Saved") : String(localized: "Save chat"),
                    image: UIImage(systemName: isSaved ? "bookmark.fill" : "bookmark")
                ) { [weak self] _ in self?.toggleSaved() }
            ])
        }
        let commands = UIDeferredMenuElement.uncached { [weak self] completion in
            guard let self, !self.viewModel.serverCommands.isEmpty else { return completion([]) }
            completion([
                UIAction(
                    title: String(localized: "Commands (\(self.viewModel.serverCommands.count))"),
                    image: UIImage(systemName: "square.grid.2x2")
                ) { [weak self] _ in self?.presentCommandCatalog() }
            ])
        }
        var children: [UIMenuElement] = [
            UIAction(
                title: String(localized: "Find in conversation"),
                image: UIImage(systemName: "magnifyingglass")
            ) { [weak self] _ in self?.openFind() }
        ]
        children += [commands, jump, subagents, regenerate, usage, save]
        children.append(
            UIAction(
                title: String(localized: "Share transcript"),
                image: UIImage(systemName: "square.and.arrow.up")
            ) { [weak self] _ in self?.shareTranscript() })
        if viewModel.canRename {
            children.append(
                UIAction(
                    title: String(localized: "Rename"), image: UIImage(systemName: "pencil")
                ) {
                    [weak self] _ in self?.promptRename()
                })
        }
        if viewModel.supportsCompaction {
            children.append(
                UIAction(
                    title: String(localized: "Compact conversation"),
                    image: UIImage(systemName: "arrow.down.right.and.arrow.up.left")
                ) { [weak self] _ in self?.presentCompactPreflight() })
        }
        if viewModel.canFork {
            children.append(
                UIAction(
                    title: String(localized: "Fork conversation"),
                    image: UIImage(systemName: "arrow.triangle.branch")
                ) { [weak self] _ in self?.forkConversation() })
        }
        if viewModel.canClear {
            children.append(
                UIAction(
                    title: String(localized: "Clear conversation"),
                    image: UIImage(systemName: "eraser"),
                    attributes: .destructive
                ) { [weak self] _ in self?.confirmClear() })
        }
        return UIBarButtonItem(
            image: UIImage(systemName: "ellipsis.circle"),
            menu: UIMenu(children: children))
    }

    /// Saving from inside a conversation is the moment it usually matters, and
    /// the only entry point where the chat's own title is what gets kept.
    private func toggleSaved() {
        let entry = SessionEntry(
            profileID: viewModel.contextID,
            profileName: viewModel.serverName.isEmpty
                ? viewModel.backend.agentType.displayName : viewModel.serverName,
            host: viewModel.serverName,
            backendType: viewModel.backend.agentType,
            session: viewModel.sessionSnapshot)
        if SavedChatStore.toggle(entry) {
            Theme.Haptics.success()
            presentToast(String(localized: "Saved — find it under Saved in Chats."))
        } else {
            Theme.Haptics.tap()
            presentToast(String(localized: "Removed from Saved."))
        }
    }

    private func scrollTo(id: String) {
        guard let index = dataSource.snapshot().indexOfItem(id) else { return }
        let path = IndexPath(item: index, section: 0)
        #if DEBUG
            if TourDriver.isFilming,
                let attributes = collectionView.layoutAttributesForItem(at: path)
            {
                tourGlide(
                    to: attributes.frame.minY - collectionView.adjustedContentInset.top - 10,
                    duration: 1.35)
                Theme.Haptics.selection()
                return
            }
        #endif
        collectionView.scrollToItem(at: path, at: .top, animated: true)
        Theme.Haptics.selection()
    }

    #if DEBUG
        /// UIKit's `scrollToItem(animated:)` covers any distance in the same ~0.3s, so
        /// a long jump lands as a snap and a growing transcript re-snaps on every
        /// render. A take needs the list to move like a camera instead: eased, and
        /// paced by how far it actually has to travel.
        private func tourGlide(to y: CGFloat, duration: Double) {
            let top = -collectionView.adjustedContentInset.top
            let bottom = max(
                top,
                collectionView.contentSize.height + collectionView.adjustedContentInset.bottom
                    - collectionView.bounds.height)
            let target = min(max(y, top), bottom)
            guard abs(target - collectionView.contentOffset.y) > 0.5 else { return }
            UIView.animate(
                withDuration: duration, delay: 0,
                options: [.curveEaseInOut, .beginFromCurrentState, .allowUserInteraction]
            ) {
                self.collectionView.contentOffset.y = target
            }
        }
    #endif

    /// A spawned agent lives in this conversation, so "open" means scroll to its
    /// card and expand it — never push a second chat the user has to come back from. A filmed
    /// tour animates the expansion: it inserts rows underneath the card, which a plain snapshot
    /// apply would shove into place in one frame.
    private func revealSubagent(id agentID: String) {
        #if DEBUG
            if TourDriver.isFilming { animateNextRender = true }
        #endif
        if !viewModel.isSubagentExpanded(agentID) { viewModel.toggleSubagent(agentID) }
        let rowID = "agent:\(agentID)"
        if !dataSource.snapshot().itemIdentifiers.contains(rowID) {
            let groups = rowsByID.values.compactMap { row -> String? in
                guard case .subagentGroup(let group) = row.content else { return nil }
                return group.id
            }
            expandedAgentGroups.formUnion(groups)
            render(viewModel.state)
        }
        guard dataSource.snapshot().itemIdentifiers.contains(rowID) else {
            presentToast(String(localized: "That agent hasn't reported into this conversation yet."))
            return
        }
        userScrolledUp = true
        scrollTo(id: rowID)
        flash(rowID: rowID)
    }

    private func revealSubagent(spawnedBy call: ToolCall) {
        guard let agent = viewModel.trackedSubagents.first(where: { $0.toolUseID == call.id })
        else {
            presentToast(String(localized: "No transcript for this agent yet."))
            return
        }
        revealSubagent(id: agent.id)
    }

    private func toggleSubagent(_ agentID: String) {
        viewModel.toggleSubagent(agentID)
    }

    /// A workflow agent has no spawning tool call to reveal, so opening one goes straight to its
    /// own transcript inside this conversation — never a chat screen of its own.
    /// A run copied out of the transcript reads as what it did, not as the launch receipt: the
    /// workflow, its phases, its agents, and the answer it came back with.
    private static func workflowMarkdown(_ run: WorkflowRun) -> String {
        var lines = ["**" + String(localized: "Workflow · \(run.name)") + "**"]
        if let summary = run.summary { lines.append(summary) }
        if !run.phases.isEmpty {
            lines.append(run.phases.map(\.title).joined(separator: " → "))
        }
        if !run.agents.isEmpty {
            lines.append(String(localized: "\(run.doneCount) of \(run.agents.count) agents"))
        }
        if let result = run.result, !result.isEmpty { lines.append(result) }
        return lines.joined(separator: "\n\n")
    }

    private func openWorkflowAgent(_ agentID: String) {
        revealSubagent(id: agentID)
    }

    /// The clock every live workflow card is drawn against. A background run outlives the turn that
    /// launched it, so the cards keep their own second hand after the turn ends — a frozen elapsed
    /// reads as a hang.
    private func advanceWorkflowClock() {
        guard workflowRuns.contains(where: \.isLive), let state = lastRenderedState else { return }
        workflowNow = Date()
        render(state)
    }

    /// A background run keeps working after the turn that launched it ended, so its cards need a
    /// second hand the turn's own ticker no longer provides. It stops the moment nothing is live.
    private func updateWorkflowTicker() {
        let live = workflowRuns.contains(where: \.isLive)
        if live, workflowTicker == nil {
            workflowTicker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled else { return }
                    self?.advanceWorkflowClock()
                }
            }
        } else if !live {
            workflowTicker?.cancel()
            workflowTicker = nil
        }
    }

    #if DEBUG
        private func openFirstCompactionSummary() {
            guard let row = orderedIDs.compactMap({ id -> CompactionRow? in
                guard case .compaction(let row) = rowsByID[id]?.content else { return nil }
                return row
            }).first else { return }
            presentCompactionSummary(row)
        }

        private func scrollToFirstAgentGroup() {
            guard let id = orderedIDs.first(where: { id in
                guard case .subagentGroup = rowsByID[id]?.content else { return false }
                return true
            }) else { return }
            userScrolledUp = true
            scrollTo(id: id)
        }

        var tourScrollView: UIScrollView { collectionView }

        func tourRevealFirstSubagent() {
            guard let agent = viewModel.trackedSubagents.first else { return }
            revealSubagent(id: agent.id)
        }

        func tourScrollToCompaction() {
            guard let id = orderedIDs.first(where: { id in
                guard case .compaction = rowsByID[id]?.content else { return false }
                return true
            }) else { return }
            userScrolledUp = true
            scrollTo(id: id)
        }

        func tourAllowPermission() {
            guard let request = pendingPermission else { return }
            viewModel.respond(to: request, decision: .once)
        }

        func tourAnswerQuestion(option: Int) async {
            await answerPendingQuestion(option: option)
        }

        func tourPresentModelPicker() { presentModelPicker() }

        func tourPresentEffortSheet() { presentEffortSheet() }

        func tourPresentSubagents() { presentSubagents(viewModel.trackedSubagents) }

        func tourPresentCompactPreflight() { presentCompactPreflight() }

        func tourOpenCompactionSummary() { openFirstCompactionSummary() }

        func tourPresentFileBrowser() { presentFileBrowser() }

        func tourPresentJumpSheet() { presentJumpSheet() }

        func tourPresentUsage() { presentUsage() }

        func tourScrollToBottom() { scrollToBottom(animated: true) }

        func tourScrollToTop() {
            userScrolledUp = true
            collectionView.setContentOffset(
                CGPoint(x: 0, y: -collectionView.adjustedContentInset.top), animated: false)
        }

        /// The palette is driven by what is in the composer, so the tour opens it the
        /// same way a thumb does — by putting a slash there.
        func tourOpenCommandPalette() {
            composer.setDraft("/", focus: true)
            composerTextDidChange("/")
        }

        func tourClearComposer() {
            composer.clear()
            composerTextDidChange("")
        }

        func tourSetDraft(_ text: String) {
            composer.setDraft(text, focus: true)
            composerTextDidChange(text)
        }

        func tourOpenCommandCatalog() { presentCommandCatalog() }

        func tourType(_ text: String, perCharacter: Double) async {
            for index in text.indices {
                let partial = String(text[text.startIndex...index])
                composer.setDraft(partial, focus: true)
                composerTextDidChange(partial)
                try? await Task.sleep(for: .seconds(perCharacter))
            }
        }

        func tourSend(_ text: String) { composerDidSend(text) }

        func tourDismissSheet() { presentedViewController?.dismiss(animated: true) }

        /// Runs the identical closure a tap on the palette row runs, including the
        /// composer clear, the palette dismissal and the selection haptic.
        func tourRunAppCommand(_ keyword: String) {
            appCommands().first { $0.keywords.contains(keyword) }?.run()
        }

        func tourPickQuestionOption(_ option: Int, question: Int = 0) {
            guard let request = pendingQuestion,
                request.questions.indices.contains(question)
            else { return }
            var picked = questionSelection.picked[question] ?? []
            if request.questions[question].multiple {
                if !picked.insert(option).inserted { picked.remove(option) }
            } else {
                picked = [option]
            }
            questionSelection.picked[question] = picked
            var snapshot = dataSource.snapshot()
            snapshot.reconfigureItems(["question:\(request.id)"])
            dataSource.apply(snapshot, animatingDifferences: false)
        }

        func tourSubmitQuestion() {
            guard let request = pendingQuestion,
                let answers = questionSelection.answers(for: request),
                answeredQuestionIDs.insert(request.id).inserted
            else { return }
            viewModel.answerQuestion(request, answers: answers)
        }

        func tourPromptRename(to newTitle: String) {
            promptRename()
            (presentedViewController as? UIAlertController)?.textFields?.first?.text = newTitle
        }

        func tourConfirmRename(to newTitle: String) {
            presentedViewController?.dismiss(animated: true)
            Task {
                try? await viewModel.rename(to: newTitle)
                self.title = navDisplayTitle
            }
        }

        func tourToggleSaved() { toggleSaved() }

        func tourDismissKeyboard() { view.endEditing(true) }
    #endif

    private func toggleAgentGroup(_ groupID: String) {
        if expandedAgentGroups.remove(groupID) == nil { expandedAgentGroups.insert(groupID) }
        animateNextRender = true
        render(viewModel.state)
    }

    /// A brief highlight after jumping, so a card reached from the agent list is
    /// obvious among the rows around it.
    private func flash(rowID: String) {
        guard let index = dataSource.snapshot().indexOfItem(rowID),
            let cell = collectionView.cellForItem(at: IndexPath(item: index, section: 0))
        else { return }
        cell.contentView.alpha = 0.25
        UIView.animate(withDuration: 0.45, delay: 0.1) { cell.contentView.alpha = 1 }
    }

    private func presentSubagents(_ agents: [SubagentSummary]) {
        let list = SubagentListViewController(
            backend: viewModel.backend, parentSessionID: viewModel.session.id, agents: agents)
        list.onSelect = { [weak self] agentID in
            self?.revealSubagent(id: agentID)
        }
        let nav = UINavigationController(rootViewController: list)
        nav.modalPresentationStyle = .pageSheet
        nav.sheetPresentationController?.detents = [.medium(), .large()]
        nav.sheetPresentationController?.prefersGrabberVisible = true
        nav.presentationController?.delegate = self
        present(nav, animated: true)
    }

    private func promptRename() {
        let alert = UIAlertController(
            title: String(localized: "Rename conversation"), message: nil, preferredStyle: .alert)
        alert.addTextField { [weak self] field in
            field.text = self?.viewModel.title
            field.clearButtonMode = .whileEditing
            field.autocapitalizationType = .sentences
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(
            UIAlertAction(title: String(localized: "Rename"), style: .default) {
                [weak self, weak alert] _ in
            let title = alert?.textFields?.first?.text?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let self, !title.isEmpty, title != self.viewModel.title else { return }
            Task {
                do {
                    try await self.viewModel.rename(to: title)
                    self.title = self.navDisplayTitle
                    Theme.Haptics.success()
                } catch {
                    self.presentToast(String(localized: "Couldn't rename this conversation."))
                }
            }
        })
        present(alert, animated: true)
    }

    private func confirmClear() {
        let alert = UIAlertController(
            title: String(localized: "Clear conversation?"),
            message: String(localized: "This starts a fresh conversation on the agent."),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(
            UIAlertAction(title: String(localized: "Clear"), style: .destructive) { [weak self] _ in
            Theme.Haptics.warning()
            self?.viewModel.clearConversation()
        })
        present(alert, animated: true)
    }

    #if DEBUG
        /// Answers whatever the agent asks with one of its offered options, so the
        /// ask-and-answer round trip can be verified without driving touches.
        private func answerPendingQuestion(option: Int) async {
            for _ in 0..<30 {
                try? await Task.sleep(for: .milliseconds(500))
                guard let request = pendingQuestion,
                    answeredQuestionIDs.insert(request.id).inserted
                else { continue }
                viewModel.answerQuestion(
                    request,
                    answers: request.questions.map { item in
                        item.options.indices.contains(option) ? [item.options[option].label] : []
                    })
                return
            }
        }
    #endif

    private func promptCustomAnswer(for request: QuestionRequest, questionIndex: Int) {
        let item = request.questions[questionIndex]
        let scope = answerDraftScope(for: request, questionIndex: questionIndex)
        let remembered = questionSelection.custom[questionIndex] ?? ""
        let alert = UIAlertController(
            title: item.header.isEmpty ? String(localized: "Your answer") : item.header,
            message: item.question, preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = String(localized: "Type your answer")
            field.text = remembered.isEmpty ? DraftStore.text(for: scope) : remembered
            field.addAction(
                UIAction { [weak field] _ in DraftStore.record(field?.text ?? "", for: scope) },
                for: .editingChanged)
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(
            UIAlertAction(title: String(localized: "Use answer"), style: .default) {
                [weak self] _ in
            guard let self else { return }
            let text = alert.textFields?.first?.text?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            DraftStore.clear(scope)
            questionSelection.custom[questionIndex] = text.isEmpty ? nil : text
            let fastPath = request.questions.count == 1 && !item.multiple
            if fastPath, let answers = questionSelection.answers(for: request) {
                viewModel.answerQuestion(request, answers: answers)
            } else if let id = pendingQuestion?.id {
                var snapshot = dataSource.snapshot()
                snapshot.reconfigureItems(["question:\(id)"])
                dataSource.apply(snapshot, animatingDifferences: false)
            }
        })
        present(alert, animated: true)
    }

    @objc private func dismissKeyboard() { view.endEditing(true) }

    private func forkConversation() {
        Task { @MainActor in
            do {
                let session = try await viewModel.fork()
                let forked = ChatViewModel(
                    backend: viewModel.backend, session: session, contextID: viewModel.contextID,
                    serverName: viewModel.serverName)
                Theme.Haptics.success()
                navigationController?.pushViewController(
                    ChatViewController(viewModel: forked), animated: true)
            } catch {
                presentToast(String(localized: "Couldn't fork this conversation."))
            }
        }
    }

    /// The palette follows the caret through the two halves of a slash invocation: a ranked list
    /// while the command is still being named, that one command's own argument hint once it is
    /// settled. It never simply vanishes on a word the catalog lacks — that reads as the app
    /// losing the draft, when in fact the words are about to be sent as an ordinary message.
    private func updateCommandPalette(for text: String) {
        switch SlashStage.of(text) {
        case .none:
            hideCommandPalette()
        case .naming(let query):
            presentCommandList(query: query)
        case .arguments(let name, let typed):
            presentArgumentHint(name: name, typed: typed)
        }
    }

    private func presentCommandList(query: String) {
        let sections = commandSections(query: query)
        guard sections.contains(where: { !$0.commands.isEmpty }) else {
            guard !query.isEmpty else { return hideCommandPalette() }
            commandPalette.update(with: .noMatch(query: query, browse: browseCommand()))
            showCommandPalette()
            return
        }
        commandPalette.update(with: .commands(sections))
        showCommandPalette()
    }

    /// Only a real server command earns the argument stage: the app's own rows take no arguments,
    /// so holding one on screen while somebody types past it would promise something untrue.
    private func presentArgumentHint(name: String, typed: String) {
        guard let command = viewModel.serverCommands.first(where: { $0.name == name }) else {
            hideCommandPalette()
            return
        }
        commandPalette.update(with: .arguments(command: makeServerCommand(command), typed: typed))
        showCommandPalette()
    }

    private func showCommandPalette() {
        guard commandPalette.isHidden else { return }
        commandPalette.alpha = 0
        commandPalette.isHidden = false
        UIView.animate(withDuration: 0.18) { self.commandPalette.alpha = 1 }
    }

    private func hideCommandPalette() {
        guard !commandPalette.isHidden else { return }
        UIView.animate(
            withDuration: 0.15, animations: { self.commandPalette.alpha = 0 },
            completion: { _ in self.commandPalette.isHidden = true })
    }

    private func makeCommand(
        _ keywords: [String], _ title: String, _ subtitle: String, _ symbol: String,
        _ action: @escaping () -> Void
    ) -> SlashCommand {
        SlashCommand(
            id: "app:\(keywords.first ?? title)", keywords: keywords, title: title,
            subtitle: subtitle, symbol: symbol
        ) { [weak self] in
            self?.composer.clear()
            self?.hideCommandPalette()
            Theme.Haptics.selection()
            action()
        }
    }

    /// `/` addresses two machines: the app and the agent. They stay in separate sections so
    /// nobody expects `/copy` to reach the server or `/compact` to be a local trick — and the
    /// handful of commands this device actually reaches for sits above both, because a phone
    /// types the same three all week.
    private func commandSections(query: String) -> [SlashCommandSection] {
        let recentNames = SlashRecents.surviving(in: viewModel.serverCommands)
        let ranked = SlashCompletion.ranked(
            viewModel.serverCommands, query: query, recents: recentNames)
        let app = appCommands().compactMap { command -> SlashCommand? in
            guard let highlight = Self.appMatch(command, query: query) else { return nil }
            var matched = command
            matched.highlight = highlight
            return matched
        }

        guard !ranked.isEmpty || !viewModel.serverCommands.isEmpty else {
            return [SlashCommandSection(title: "", commands: app)]
        }

        var server = ranked.map { makeServerCommand($0.command, highlight: $0.highlight) }
        let recentRows =
            query.isEmpty
            ? Array(server.prefix { recentNames.contains(commandName(of: $0)) }.prefix(4)) : []
        if !recentRows.isEmpty {
            let taken = Set(recentRows.map(\.id))
            server = server.filter { !taken.contains($0.id) }
        }
        if !server.isEmpty, let browse = browseCommand() { server.append(browse) }

        return [
            SlashCommandSection(title: String(localized: "Recent"), commands: recentRows),
            SlashCommandSection(title: String(localized: "On the server"), commands: server),
            SlashCommandSection(title: String(localized: "In Tailscode"), commands: app),
        ]
    }

    private func commandName(of row: SlashCommand) -> String {
        String(row.id.dropFirst("server:".count))
    }

    /// An app row answers to its own vocabulary — `/m`, `/think`, `/retry` — so the letters that
    /// matched are found against whichever keyword hit, then mapped onto the title when the title
    /// happens to carry them. A keyword-only hit still shows, just without tinted letters.
    private static func appMatch(_ command: SlashCommand, query: String) -> [Int]? {
        guard !query.isEmpty else { return [] }
        let title = command.title.lowercased()
        if let range = title.range(of: query) {
            let start = title.distance(from: title.startIndex, to: range.lowerBound)
            return Array(start..<(start + query.count))
        }
        return command.keywords.contains { $0.hasPrefix(query) } ? [] : nil
    }

    private func browseCommand() -> SlashCommand? {
        let total = viewModel.serverCommands.count
        guard total > 0 else { return nil }
        return SlashCommand(
            id: "app:·browse",
            keywords: ["all", "commands", "browse", "help"],
            title: String(localized: "All commands"),
            subtitle: String(localized: "Browse the \(total) this server offers"),
            symbol: "square.grid.2x2"
        ) { [weak self] in
            self?.hideCommandPalette()
            Theme.Haptics.selection()
            self?.presentCommandCatalog()
        }
    }

    private func makeServerCommand(_ command: AgentCommand, highlight: [Int] = []) -> SlashCommand {
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
        ) { [weak self] in
            self?.hideCommandPalette()
            Theme.Haptics.selection()
            self?.selectServerCommand(command)
        }
    }

    /// Picking a command that takes arguments lands it in the composer to be completed rather than
    /// firing bare — a tap is a choice, not a submission. `/goal` gets a purpose-built prompt
    /// because a stop condition is a different kind of writing from a message.
    private func selectServerCommand(_ command: AgentCommand) {
        SlashRecents.record(command.name)
        if command.name == "goal" {
            composer.clear()
            presentGoalComposer()
            return
        }
        if command.name == "compact", viewModel.supportsCompaction {
            composer.clear()
            presentCompactPreflight()
            return
        }
        guard !command.takesArguments else {
            composer.setDraft("/\(command.name) ", focus: true)
            return
        }
        runServerCommand(command, arguments: nil)
    }

    /// A command the person typed out and sent. Unlike a pick, this is a submission: a command
    /// that wants arguments and was sent without them runs bare, exactly as a terminal would,
    /// rather than being handed back for editing.
    private func runServerCommand(_ command: AgentCommand, arguments: String?) {
        SlashRecents.record(command.name)
        if command.name == "goal", arguments == nil {
            composer.clear()
            presentGoalComposer()
            return
        }
        if command.name == "compact", viewModel.supportsCompaction {
            composer.clear()
            presentCompactPreflight(instruction: arguments ?? "")
            return
        }
        composer.clear()
        DraftStore.clear(draftScope)
        viewModel.run(command, arguments: arguments)
    }

    private func presentCommandCatalog() {
        let catalog = CommandCatalogViewController(commands: viewModel.serverCommands)
        catalog.onPick = { [weak self] command in self?.selectServerCommand(command) }
        let nav = UINavigationController(rootViewController: catalog)
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.large(), .medium()]
            sheet.selectedDetentIdentifier = .large
            sheet.prefersGrabberVisible = true
        }
        present(nav, animated: true)
    }

    private func appCommands() -> [SlashCommand] {
        var list: [SlashCommand] = []
        if viewModel.supportsModelSelection {
            list.append(
                makeCommand(
                    ["model", "m"], String(localized: "Model"),
                    viewModel.selectedModel?.modelID ?? String(localized: "Choose a model"),
                    "cpu"
                ) { [weak self] in self?.presentModelPicker() })
        }
        if viewModel.supportsReasoningEffort {
            list.append(
                makeCommand(
                    ["effort", "reasoning", "think"], String(localized: "Reasoning effort"),
                    viewModel.currentEffort?.capitalized ?? String(localized: "Default"),
                    "gauge.with.dots.needle.50percent"
                ) { [weak self] in self?.presentEffortSheet() })
        }
        if viewModel.canRegenerate {
            list.append(
                makeCommand(
                    ["regenerate", "retry"], String(localized: "Regenerate"),
                    String(localized: "Re-run the last prompt"),
                    "arrow.clockwise"
                ) { [weak self] in self?.viewModel.regenerate() })
        }
        if viewModel.supportsUsage {
            list.append(
                makeCommand(
                    ["usage", "cost", "tokens"], String(localized: "Usage & cost"),
                    String(localized: "Tokens and spend for this session"),
                    "gauge.with.dots.needle.bottom.50percent"
                ) { [weak self] in self?.presentUsage() })
        }
        if viewModel.supportsFileBrowsing {
            list.append(
                makeCommand(
                    ["browse", "file", "path"], String(localized: "Browse files"),
                    String(localized: "Open file browser on server"),
                    "folder.fill"
                ) { [weak self] in self?.presentFileBrowser() })
        }
        if viewModel.canFork {
            list.append(
                makeCommand(
                    ["fork", "branch"], String(localized: "Fork conversation"),
                    String(localized: "Branch to explore a different direction"),
                    "arrow.triangle.branch"
                ) { [weak self] in self?.forkConversation() })
        }
        list.append(
            makeCommand(
                ["jump", "goto"], String(localized: "Jump to message"),
                String(localized: "Scroll to an earlier prompt"), "list.bullet"
            ) { [weak self] in self?.presentJumpSheet() })
        list.append(
            makeCommand(
                ["copy", "transcript"], String(localized: "Copy transcript"),
                String(localized: "Copy the whole conversation"),
                "doc.on.doc"
            ) { [weak self] in self?.copyTranscript() })
        if viewModel.canClear {
            list.append(
                makeCommand(
                    ["clear", "reset"], String(localized: "Clear conversation"),
                    String(localized: "Start fresh on the agent"), "eraser"
                ) { [weak self] in self?.confirmClear() })
        }
        return list
    }

    private func presentEffortSheet() {
        let sheet = UIAlertController(
            title: String(localized: "Reasoning effort"), message: nil,
            preferredStyle: .actionSheet)
        sheet.addAction(
            UIAlertAction(
                title: viewModel.currentEffort == nil
                    ? String(localized: "Default") + " ✓" : String(localized: "Default"),
                style: .default
            ) { [weak self] _ in
                self?.viewModel.setEffort(nil)
                self?.updateNavControls()
            })
        for level in viewModel.reasoningEffortOptions {
            let selected = viewModel.currentEffort == level
            sheet.addAction(
                UIAlertAction(
                    title: selected ? "\(level.capitalized) ✓" : level.capitalized, style: .default
                ) { [weak self] _ in
                    self?.viewModel.setEffort(level)
                    self?.updateNavControls()
                })
        }
        sheet.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = composer
        present(sheet, animated: true)
    }

    private func presentUsage() {
        Task { @MainActor in
            guard viewModel.supportsUsage, let usage = await viewModel.usage(),
                usage.tokens != nil || usage.costUSD != nil
            else {
                self.presentToast(String(localized: "No usage recorded for this session yet."))
                return
            }
            var lines: [String] = []
            if let tokens = usage.tokens {
                lines.append(String(localized: "\(tokens.formatted()) tokens"))
            }
            if let cost = usage.costUSD {
                lines.append(String(format: "$%.4f", cost))
            }
            let alert = UIAlertController(
                title: String(localized: "Last turn usage"),
                message: lines.joined(separator: "\n"),
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
            self.present(alert, animated: true)
        }
    }

    private func presentFileBrowser() {
        guard let fb = viewModel.backend as? any FileBrowsingBackend else { return }
        Theme.Haptics.tap()
        let browser = FileBrowserViewController(backend: fb, profileID: viewModel.contextID)
        browser.onSelect = { [weak self] path in
            guard let self else { return }
            browser.dismiss(animated: true) {
                UIPasteboard.general.string = path
                self.presentToast(String(localized: "Path copied: \(path)"))
                self.composer.appendPath(path)
            }
        }
        let nav = UINavigationController(rootViewController: browser)
        present(nav, animated: true)
    }

    private func presentJumpSheet() {
        let prompts = orderedIDs.compactMap { id -> (String, String)? in
            guard let row = rowsByID[id], row.role == .user, case .text(let text) = row.content
            else { return nil }
            return (id, String(text.prefix(50)))
        }
        guard !prompts.isEmpty else {
            presentToast(String(localized: "No earlier messages to jump to."))
            return
        }
        let sheet = UIAlertController(
            title: String(localized: "Jump to message"), message: nil,
            preferredStyle: .actionSheet)
        for (id, title) in prompts.suffix(15) {
            sheet.addAction(
                UIAlertAction(title: title, style: .default) { [weak self] _ in
                    self?.scrollTo(id: id)
                })
        }
        sheet.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = composer
        present(sheet, animated: true)
    }

    private func transcriptMarkdown() -> String {
        var out: [String] = []
        for id in orderedIDs {
            guard let row = rowsByID[id], !id.hasPrefix("ts:") else { continue }
            let who = row.role == .user ? String(localized: "You") : String(localized: "Agent")
            let body: String
            switch row.content {
            case .text(let text):
                body = text
            case .code(let block):
                let fence = block.language ?? ""
                body = "```\(fence)\n\(block.source)\n```"
            case .activity(let steps):
                body = steps.map {
                    switch $0 {
                    case .reasoning(let text): return text
                    case .tool(let call): return "[\(call.title ?? call.name)]"
                    }
                }.joined(separator: "\n")
            case .subagent(let card):
                body = Self.subagentMarkdown(card)
            case .workflow(let run):
                body = Self.workflowMarkdown(run)
            case .subagentGroup(let group):
                body = "_" + String(localized: "\(group.total) agents") + "_"
            case .file(let file), .image(let file):
                body = "[file: \(file.path ?? file.filename ?? String(localized: "attachment"))]"
            case .compaction(let row):
                out.append(Self.compactionMarkdown(row))
                continue
            case .timestamp, .error:
                continue
            }
            out.append("**\(who):** \(body)")
        }
        return out.joined(separator: "\n\n")
    }

    private func copyTranscript() {
        UIPasteboard.general.string = transcriptMarkdown()
        Theme.Haptics.success()
        presentToast(String(localized: "Transcript copied to clipboard."))
    }

    private func shareTranscript() {
        let name = navDisplayTitle.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name.isEmpty ? "transcript" : name).md")
        do {
            try transcriptMarkdown().write(to: url, atomically: true, encoding: .utf8)
        } catch {
            presentToast(String(localized: "Couldn't export the transcript."))
            return
        }
        let sheet = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = view
        present(sheet, animated: true)
    }

    private func presentToast(_ message: String) {
        let toast = ToastView(message: message)
        toast.flash(in: view, above: composer.topAnchor)
    }

    /// One chip carries both the model and the effort, and names them: which
    /// model a chat is running was previously hidden behind a bare `cpu` icon.
    /// The title reads the displayed derivation — pick, then transcript, then
    /// session record — while the menu's checkmarks stay on the explicit pick,
    /// so "Auto" remains checked for a chat the server is still deciding for.
    private func modelBarButton() -> UIBarButtonItem {
        let choice = ModelChoice(model: viewModel.selectedModel, effort: viewModel.currentEffort)
        let label = ModelBadge.label(
            model: viewModel.displayedModel, effort: viewModel.displayedEffort)
        let elements = ModelMenu.elements(
            models: viewModel.supportsModelSelection ? availableModels : [],
            choice: choice,
            efforts: viewModel.reasoningEffortOptions,
            allowsServerDefault: ChatModelResolver.honoursServerDefault(viewModel.backend),
            actions: ModelMenu.Actions(
                selectModel: { [weak self] selection in
                    Theme.Haptics.selection()
                    self?.viewModel.selectModel(selection)
                    self?.updateNavControls()
                },
                selectEffort: { [weak self] level in
                    Theme.Haptics.selection()
                    self?.viewModel.setEffort(level)
                    self?.updateNavControls()
                },
                browseAll: { [weak self] in self?.presentModelPicker() }))
        let item = UIBarButtonItem(
            title: label, image: nil, primaryAction: nil,
            menu: UIMenu(title: String(localized: "Model"), children: elements))
        item.accessibilityLabel = String(localized: "Model: \(label)")
        return item
    }

    @objc private func presentModelPicker() {
        guard !availableModels.isEmpty else { return }
        Theme.Haptics.tap()
        let picker = ModelPickerViewController(
            sources: ModelFleet.sources(
                profiles: ConnectionController.shared.profiles,
                current: viewModel.contextID, currentModels: availableModels,
                allowsServerDefault: ChatModelResolver.honoursServerDefault(viewModel.backend)),
            selected: viewModel.selectedModel
        ) { [weak self] pick in
            self?.apply(pick)
        }
        let nav = UINavigationController(rootViewController: picker)
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(nav, animated: true)
    }

    /// A model on this server changes what this chat runs. A model on another one cannot — the
    /// conversation is a session on the machine that answers it — so the app says so and offers the
    /// only thing it can honour: the same model, on that machine, in a new chat.
    private func apply(_ pick: ModelPick) {
        guard pick.isElsewhere else {
            viewModel.selectModel(pick.selection)
            updateNavControls()
            return
        }
        let alert = UIAlertController(
            title: ModelFleet.moveTitle(pick), message: ModelFleet.moveBody(pick),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(
            UIAlertAction(title: ModelFleet.moveAction, style: .default) { [weak self] _ in
                ModelFleet.adopt(pick)
                Theme.Haptics.success()
                self?.navigationController?.popToRootViewController(animated: true)
                (self?.navigationController?.viewControllers.first as? HomeViewController)?
                    .aimCompose(at: pick.profileID)
            })
        present(alert, animated: true)
    }

    /// Diagnostic: fires when a still-pending bubble (queued item or local echo)
    /// carries the same text as a message already in the server transcript — the
    /// exact condition that renders a duplicate. Logs the shape so the trigger
    /// (reuse path, resync, stale echo) can be pinned from a device log.
    private static func logPendingPhantom(state: ConversationState, viewModel: ChatViewModel) {
        let pendingTexts = viewModel.queued.map(\.text) + viewModel.localEchoes.map(\.text)
        guard !pendingTexts.isEmpty else { return }
        let serverUserTexts = Set(
            state.messages.filter { $0.role == .user }.map { $0.text })
        let phantoms = pendingTexts.filter { serverUserTexts.contains($0) }
        guard !phantoms.isEmpty else { return }
        AppLogger.chat.error(
            "pending phantom: \(phantoms.count) pending bubble(s) duplicate a server message — "
                + "queued=\(viewModel.queued.count) echoes=\(viewModel.localEchoes.count) "
                + "serverUsers=\(serverUserTexts.count) first=\"\(phantoms[0].prefix(30))\"")
    }

    /// Where each spawned agent's card belongs: against the tool call that
    /// spawned it when the server resolved one, otherwise trailing the workflow
    /// that fanned it out (workflow agents have no spawning call of their own).
    struct SubagentPlacement {
        var byToolUse: [String: SubagentCard] = [:]
        var unattached: [SubagentCard] = []
        var expandedGroups: Set<String> = []
    }

    /// Backends that never name the spawning call — opencode's child sessions, or a bridge that
    /// hasn't resolved the id yet — get their cards seated in order against the spawn calls
    /// still free, so a card still lands where its work began.
    private var workflowRuns: [WorkflowRun] = []
    private var workflowNow: Date = Date()
    private var workflowTicker: Task<Void, Never>?
    private var lastRenderedState: ConversationState?

    private func subagentPlacement(for messages: [ChatMessage]) -> SubagentPlacement {
        guard viewModel.supportsSubagents, !viewModel.trackedSubagents.isEmpty else {
            return SubagentPlacement()
        }
        let spawnIDs = messages.flatMap { message in
            message.parts.compactMap { part -> String? in
                guard case .tool(let call) = part.kind, call.spawnsSubagent else { return nil }
                return call.id
            }
        }
        let known = Set(spawnIDs)
        var placement = SubagentPlacement(expandedGroups: expandedAgentGroups)
        var unmatched: [SubagentCard] = []
        for agent in viewModel.trackedSubagents.sorted(by: { $0.updatedAt < $1.updatedAt }) {
            let card = subagentCard(for: agent)
            if let toolUseID = agent.toolUseID, known.contains(toolUseID) {
                placement.byToolUse[toolUseID] = card
            } else {
                unmatched.append(card)
            }
        }
        var free = spawnIDs.filter { placement.byToolUse[$0] == nil }[...]
        for card in unmatched {
            guard let slot = free.first else {
                placement.unattached.append(card)
                continue
            }
            free = free.dropFirst()
            placement.byToolUse[slot] = card
        }
        return placement
    }

    private func subagentCard(for agent: SubagentSummary) -> SubagentCard {
        let digest = ChatRowBuilder.digest(viewModel.subagentTranscripts[agent.id])
        return SubagentCard(
            agentID: agent.id,
            title: agent.title,
            agentType: agent.agentType,
            isActive: agent.isActive,
            isCompleted: agent.isCompleted,
            updatedAt: agent.updatedAt,
            expanded: viewModel.isSubagentExpanded(agent.id),
            isLoading: viewModel.loadingSubagents.contains(agent.id),
            steps: digest.steps,
            report: digest.report,
            progress: ChatRowBuilder.liveProgress(agent))
    }

    /// One line saying what a live agent is doing: its todo position when it keeps a list,
    /// otherwise its tool trail — count, the current tool, and elapsed time.
    /// A subagent transcript reads as a run of work plus one answer: its thoughts
    /// and tool calls become steps, and its final message is what it reported to
    /// the conversation that spawned it.
    /// Merges any adjacent activity rows into one, so a run of thinking/tool steps (even across
    /// message boundaries) reads as a single collapsible group.
    private func isNearBottom() -> Bool {
        let offsetY = collectionView.contentOffset.y
        let height = collectionView.contentSize.height
        let visible = collectionView.bounds.height
        return height <= visible || offsetY > height - visible - 120
    }

    private func scrollToBottom(animated: Bool) {
        let count = dataSource.snapshot().numberOfItems
        guard count > 0 else { return }
        let indexPath = IndexPath(item: count - 1, section: 0)
        #if DEBUG
            if TourDriver.isFilming, animated,
                let attributes = collectionView.layoutAttributesForItem(at: indexPath)
            {
                tourGlide(
                    to: attributes.frame.maxY + collectionView.adjustedContentInset.bottom
                        - collectionView.bounds.height,
                    duration: 0.6)
                return
            }
        #endif
        collectionView.scrollToItem(at: indexPath, at: .bottom, animated: animated)
    }

    private func presentError(_ message: String) {
        let alert = UIAlertController(
            title: String(localized: "Error"), message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        present(alert, animated: true)
    }
}

extension ChatViewController: ComposerViewDelegate {
    /// A typed slash goes where the palette would have sent it — the person who types the whole
    /// command should not get different behaviour from the person who tapped the row. Anything
    /// the server has never heard of goes out as the words that were written: the server is the
    /// authority on its own grammar.
    func composerDidSend(_ text: String) {
        hideCommandPalette()
        switch SlashDispatch.decide(
            text: text, commands: viewModel.serverCommands,
            supportsCompaction: viewModel.supportsCompaction,
            resolvesFromPromptText: viewModel.resolvesCommandsFromPromptText)
        {
        case .compactPreflight(let instruction):
            DraftStore.clear(draftScope)
            SlashRecents.record("compact")
            presentCompactPreflight(instruction: instruction)
        case .run(let command, let arguments):
            runServerCommand(command, arguments: arguments)
        case .plainText:
            sendDraft(text)
        }
    }

    private func sendDraft(_ text: String, model: ModelSelection? = nil, effort: String? = nil) {
        let attachments = pendingAttachments
        pendingAttachments = []
        composer.showsAttach = canAttachAnything
        updateAttachmentStrip()
        userScrolledUp = false
        animateNextRender = true
        isHandingOffEmptyState = !emptyState.isHidden && emptyState.alpha > 0
        DraftStore.clear(draftScope)
        viewModel.send(text, model: model, effort: effort, attachments: attachments)
    }

    func composerTextDidChange(_ text: String) {
        DraftStore.record(text, for: draftScope)
        updateCommandPalette(for: text)
        guard !isApplyingEnhancedPrompt else { return }
        enhancement.updateInput(text)
        enhanceOverlay?.requestDismiss()
    }

    /// Holding Send always raises the on-device enhancement deck for a non-empty
    /// draft; `requestNow` decides whether to generate, ask for a little more
    /// detail, or explain that Apple Intelligence is unavailable. Model/effort
    /// selection lives on the nav bar, never here.
    func composerDidLongPressSend(from view: UIView) {
        let text = composer.currentText
        guard !text.isEmpty else { return }
        AppLogger.ui.info(
            "enhance: long-press chars=\(text.count) available=\(enhancement.isAvailable) enhanceable=\(PromptEnhancementController.isEnhanceable(text))")
        enhancement.requestNow(for: text)
        presentEnhanceOverlay(original: text)
    }

    func composerDidPasteLargeText(_ text: String) {
        guard viewModel.canAttachFiles else {
            composer.insertText(text)
            return
        }
        composer.deleteSelection()
        guard let data = text.data(using: .utf8) else { return }
        pendingAttachments.append(
            PromptAttachment(
                mime: "text/plain", filename: "pasted-\(UUID().uuidString.prefix(8)).txt",
                data: data))
        composer.showsAttach = true
        updateAttachmentStrip()
        Theme.Haptics.success()
        presentToast(
            String(
                localized:
                    "Attached \(text.count.formatted()) characters — sent with your next message."))
    }

    func composerDidTapStop() {
        Theme.Haptics.tap()
        viewModel.abort()
    }

    func composerDidBeginEditing() {
        enhancement.prewarm()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.scrollToBottom(animated: true)
        }
    }

    private func presentEnhanceOverlay(original: String) {
        hideCommandPalette()
        enhanceOverlay?.removeFromSuperview()
        let overlay = PromptEnhanceOverlay()
        overlay.delegate = self
        overlay.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: view.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: composer.topAnchor),
        ])
        enhanceOverlay = overlay
        overlay.render(enhancement.status, original: original)
        view.layoutIfNeeded()
        let anchor = composer.sendControlAnchor
        let origin = anchor.convert(
            CGPoint(x: anchor.bounds.midX, y: anchor.bounds.midY), to: overlay)
        overlay.animateIn(fromButtonCenter: origin)
        AppLogger.ui.info("enhance: overlay presented")
    }

    private func handleEnhancementStatus(_ status: PromptEnhancementController.Status) {
        composer.setEnhanceHint(enhancement.hasFreshSuggestions)
        enhanceOverlay?.render(status, original: enhancement.latestInput)
    }

    /// Photos and files are different enough errands to be asked about rather
    /// than guessed at: an image goes to the model's vision input, a file lands
    /// on the server for the agent to open. Only the sources the current model
    /// can actually accept are offered.
    func composerAttachOptions() -> [UIMenuElement] {
        var actions: [UIMenuElement] = []
        if viewModel.canAttachImages {
            actions.append(
                UIAction(
                    title: String(localized: "Photo Library"),
                    image: UIImage(systemName: "photo.on.rectangle")
                ) { [weak self] _ in self?.presentPhotoPicker() })
        }
        if viewModel.canAttachFiles {
            actions.append(
                UIAction(
                    title: String(localized: "Files"), image: UIImage(systemName: "folder")
                ) { [weak self] _ in
                    self?.presentDocumentPicker()
                })
        }
        return actions
    }

    private func presentPhotoPicker() {
        Theme.Haptics.tap()
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }

    private func presentDocumentPicker() {
        Theme.Haptics.tap()
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.delegate = self
        picker.allowsMultipleSelection = false
        present(picker, animated: true)
    }
}

extension ChatViewController: UIDocumentPickerDelegate {
    func documentPicker(
        _ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]
    ) {
        guard let url = urls.first else { return }
        attachFile(at: url)
    }

    /// The whole payload rides base64-encoded inside the send, whose timeout
    /// scales with its size — so an oversized file is refused up front instead
    /// of failing halfway into a turn.
    private static let attachmentSizeLimit = 8 * 1024 * 1024

    private func attachFile(at url: URL) {
        let name = url.lastPathComponent
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            presentToast(String(localized: "Couldn't read \(name)."))
            return
        }
        guard data.count <= Self.attachmentSizeLimit else {
            let size = ByteCountFormatter.string(fromByteCount: Int64(data.count), countStyle: .file)
            presentToast(String(localized: "\(name) is \(size) — attachments are capped at 8 MB."))
            return
        }
        let mime =
            UTType(filenameExtension: url.pathExtension)?.preferredMIMEType
            ?? "application/octet-stream"
        guard !mime.hasPrefix("image/") || viewModel.canAttachImages else {
            presentToast(String(localized: "This model can't see images."))
            return
        }
        pendingAttachments.append(PromptAttachment(mime: mime, filename: name, data: data))
        Theme.Haptics.success()
        updateAttachmentStrip()
        presentToast(String(localized: "\(name) attached — it'll be sent with your next message."))
    }
}

extension ChatViewController: PromptEnhanceOverlayDelegate {
    func enhanceOverlay(_ overlay: PromptEnhanceOverlay, didChoose prompt: EnhancedPrompt) {
        AppLogger.ui.info("enhance: chose card \"\(prompt.label)\" (\(prompt.text.count) chars)")
        Theme.Haptics.success()
        isApplyingEnhancedPrompt = true
        composer.setDraft(prompt.text, focus: true)
        isApplyingEnhancedPrompt = false
        flushDraft()
        overlay.requestDismiss()
    }

    func enhanceOverlay(_ overlay: PromptEnhanceOverlay, didCopy prompt: EnhancedPrompt) {
        UIPasteboard.general.string = prompt.text
        Theme.Haptics.success()
        presentToast(String(localized: "Enhanced prompt copied."))
    }

    func enhanceOverlayDidRequestRetry(_ overlay: PromptEnhanceOverlay) {
        Theme.Haptics.tap()
        enhancement.retry()
    }

    func enhanceOverlayDidDismiss(_ overlay: PromptEnhanceOverlay) {
        if enhanceOverlay === overlay { enhanceOverlay = nil }
        composer.setEnhanceHint(enhancement.hasFreshSuggestions)
    }
}

extension ChatViewController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)
        guard let provider = results.first?.itemProvider,
            provider.canLoadObject(ofClass: UIImage.self)
        else { return }
        provider.loadDataRepresentation(forTypeIdentifier: "public.image") { [weak self] data, _ in
            guard let data else { return }
            let (mime, ext) = Self.imageType(of: data)
            Task { @MainActor in
                self?.pendingAttachments.append(
                    PromptAttachment(
                        mime: mime, filename: "image-\(UUID().uuidString.prefix(8)).\(ext)",
                        data: data))
                self?.presentAttachmentToast()
            }
        }
    }

    /// Sniffs the container format from magic bytes so the declared mime
    /// matches the actual data (PHPicker returns HEIC/PNG originals, not JPEG).
    private nonisolated static func imageType(of data: Data) -> (mime: String, ext: String) {
        if data.starts(with: [0xFF, 0xD8, 0xFF]) { return ("image/jpeg", "jpg") }
        if data.starts(with: [0x89, 0x50, 0x4E, 0x47]) { return ("image/png", "png") }
        if data.count >= 12, data[4...7].elementsEqual("ftyp".utf8) { return ("image/heic", "heic") }
        if data.starts(with: [0x47, 0x49, 0x46]) { return ("image/gif", "gif") }
        return ("image/jpeg", "jpg")
    }

    private func presentAttachmentToast() {
        Theme.Haptics.success()
        updateAttachmentStrip()
        presentToast(String(localized: "Image attached — it'll be sent with your next message."))
    }

    private func updateAttachmentStrip() {
        attachmentStrip.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for (index, attachment) in pendingAttachments.enumerated() {
            let image = attachment.mime.hasPrefix("image/") && attachment.data != nil
                ? UIImage(data: attachment.data!) : nil
            let chip = AttachmentChip(
                label: attachment.filename ?? attachment.mime, image: image
            ) { [weak self] in
                guard let self, self.pendingAttachments.indices.contains(index) else { return }
                self.pendingAttachments.remove(at: index)
                self.updateAttachmentStrip()
                if self.pendingAttachments.isEmpty {
                    self.composer.showsAttach = self.canAttachAnything
                }
            }
            attachmentStrip.addArrangedSubview(chip)
        }
        attachmentStrip.isHidden = pendingAttachments.isEmpty
        view.setNeedsLayout()
    }
}

extension ChatViewController: UICollectionViewDelegate {
    func collectionView(
        _ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        let id = dataSource.itemIdentifier(for: indexPath)
        decorateFindRing(cell, on: id != nil && id == findHighlightedID)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first,
            let id = dataSource.itemIdentifier(for: indexPath)
        else { return nil }
        if id.hasPrefix("queued:"),
            let message = viewModel.queued.first(where: { "queued:\($0.id.uuidString)" == id })
        {
            return UIContextMenuConfiguration(identifier: id as NSString, previewProvider: nil) {
                [weak self] _ in
                UIMenu(children: [
                    UIAction(
                        title: String(localized: "Edit"), image: UIImage(systemName: "pencil")
                    ) { _ in
                        guard let self, let removed = self.viewModel.removeQueued(id: message.id)
                        else { return }
                        self.composer.setDraft(removed.text)
                        if !removed.attachments.isEmpty {
                            self.pendingAttachments.append(contentsOf: removed.attachments)
                            self.composer.showsAttach = true
                            self.updateAttachmentStrip()
                        }
                    },
                    UIAction(
                        title: String(localized: "Remove from queue"),
                        image: UIImage(systemName: "trash"),
                        attributes: .destructive
                    ) { _ in
                        Theme.Haptics.warning()
                        _ = self?.viewModel.removeQueued(id: message.id)
                    },
                ])
            }
        }
        guard let text = messageText(for: id), !text.isEmpty else { return nil }

        return UIContextMenuConfiguration(identifier: id as NSString, previewProvider: nil) {
            [weak self] _ in
            var actions: [UIAction] = [
                UIAction(
                    title: String(localized: "Copy"), image: UIImage(systemName: "doc.on.doc")
                ) { _ in
                    UIPasteboard.general.string = text
                    Theme.Haptics.success()
                }
            ]
            if let code = Self.firstCodeBlock(in: text) {
                actions.append(
                    UIAction(
                        title: String(localized: "Copy code"),
                        image: UIImage(systemName: "curlybraces")
                    ) { _ in
                        UIPasteboard.general.string = code
                        Theme.Haptics.success()
                    })
            }
            actions.append(
                UIAction(
                    title: String(localized: "Quote"),
                    image: UIImage(systemName: "quote.opening")
                ) { _ in
                    self?.composer.insertQuote(text)
                })
            actions.append(
                UIAction(
                    title: String(localized: "Share"),
                    image: UIImage(systemName: "square.and.arrow.up")
                ) { _ in
                    self?.shareText(text)
                })
            return UIMenu(children: actions)
        }
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        syncFAB()
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        userScrolledUp = true
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        if isNearBottom() { userScrolledUp = false }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate && isNearBottom() { userScrolledUp = false }
    }

    private func messageText(for id: String) -> String? {
        guard let row = rowsByID[id] else { return nil }
        switch row.content {
        case .text(let text):
            return text
        case .code(let block):
            return block.source
        case .activity(let steps):
            return steps.map { step in
                switch step {
                case .reasoning(let text): return text
                case .tool(let call): return call.output ?? call.title ?? call.name
                }
            }.joined(separator: "\n\n")
        case .subagent(let card):
            return Self.subagentMarkdown(card)
        case .workflow(let run):
            return Self.workflowMarkdown(run)
        case .subagentGroup:
            return nil
        case .file(let file), .image(let file):
            return file.filename ?? file.mime
        case .compaction(let row):
            return row.compaction?.summary
        case .timestamp, .error:
            return nil
        }
    }

    /// A shared transcript has to keep the seam: the messages above it are still there to read, but
    /// they stopped being what the agent knew.
    private static func compactionMarkdown(_ row: CompactionRow) -> String {
        let compacted = String(localized: "Context compacted")
        guard let compaction = row.compaction else { return "---\n\n_\(compacted)._" }
        var line = "---\n\n_\(compacted)"
        if let before = compaction.tokensBefore, let after = compaction.tokensAfter {
            line += ": "
                + String(
                    localized:
                        "\(CompactionCell.tokens(before)) → \(CompactionCell.tokens(after)) tokens")
        }
        line += " — "
            + String(localized: "everything above this point was replaced by a summary.") + "_"
        guard let summary = compaction.summary, !summary.isEmpty else { return line }
        let heading = String(localized: "Summary")
        return line
            + "\n\n<details><summary>\(heading)</summary>\n\n\(summary)\n\n</details>"
    }

    /// A shared transcript keeps a spawned agent inside the conversation it
    /// belongs to, indented under the line that spawned it.
    private static func subagentMarkdown(_ card: SubagentCard) -> String {
        var lines = [
            "_" + String(localized: "Agent") + "\(card.agentType.map { " · \($0)" } ?? "")"
                + "_: \(card.title)"
        ]
        for step in card.steps {
            switch step {
            case .reasoning(let text): lines.append("> \(text)")
            case .tool(let call): lines.append("> [\(call.title ?? call.name)]")
            }
        }
        if let report = card.report { lines.append("> \(report)") }
        return lines.joined(separator: "\n")
    }

    private func shareText(_ text: String) {
        let sheet = UIActivityViewController(activityItems: [text], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = view
        present(sheet, animated: true)
    }

    private static func firstCodeBlock(in text: String) -> String? {
        let parts = text.components(separatedBy: "```")
        guard parts.count >= 3 else { return nil }
        var block = parts[1]
        if let newline = block.firstIndex(of: "\n") {
            block = String(block[block.index(after: newline)...])
        }
        let trimmed = block.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

extension ChatViewController: UIAdaptivePresentationControllerDelegate {
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        refreshAgentsChip()
    }
}

extension ChatViewController: ImageBubbleCellDelegate {
    func imageBubbleCell(_ cell: ImageBubbleCell, didTap image: UIImage, from view: UIView) {
        let items = galleryImages()
        let id = collectionView.indexPath(for: cell).flatMap { dataSource.itemIdentifier(for: $0) }
        let start = items.firstIndex { $0.id == id } ?? 0
        guard !items.isEmpty else { return }
        present(
            ImageViewerViewController(
                items: items, startIndex: start, backend: viewModel.backend, from: view),
            animated: false)
    }

    func imageBubbleCell(_ cell: ImageBubbleCell, menuFor payload: ImagePayload) -> UIMenu {
        UIMenu(children: [
            UIAction(
                title: String(localized: "Save to Photos"),
                image: UIImage(systemName: "square.and.arrow.down")
            ) { [weak self] _ in self?.saveToPhotos(payload) },
            UIAction(title: String(localized: "Copy"), image: UIImage(systemName: "doc.on.doc")) {
                _ in
                ImageExport.copy(payload)
                Theme.Haptics.success()
            },
            UIAction(
                title: String(localized: "Save to Files"),
                image: UIImage(systemName: "folder")
            ) { [weak self] _ in self?.exportToFiles(payload) },
            UIAction(
                title: String(localized: "Share"),
                image: UIImage(systemName: "square.and.arrow.up")
            ) { [weak self] _ in self?.shareImage(payload, from: cell) },
        ])
    }

    /// Every picture in the conversation, in the order it was said, so the
    /// viewer can swipe across the whole chat from whichever one was tapped.
    private func galleryImages() -> [GalleryImage] {
        dataSource.snapshot().itemIdentifiers.compactMap { id in
            if case .image(let file)? = rowsByID[id]?.content {
                return GalleryImage(id: id, file: file, localData: nil)
            }
            guard id.hasPrefix("local:"), id.contains(":img"),
                let echo = viewModel.localEchoes.first(where: {
                    id.hasPrefix("local:\($0.id.uuidString):img")
                }),
                let index = Int(id.components(separatedBy: ":img").last ?? ""),
                echo.attachments.indices.contains(index)
            else { return nil }
            let attachment = echo.attachments[index]
            return GalleryImage(
                id: id,
                file: FileReference(
                    path: nil, mime: attachment.mime,
                    url: "local:\(echo.id.uuidString):\(index)", filename: attachment.filename),
                localData: attachment.data)
        }
    }

    private func saveToPhotos(_ payload: ImagePayload) {
        Task { [weak self] in
            switch await ImageExport.saveToPhotos(payload) {
            case .saved:
                Theme.Haptics.success()
                self?.presentToast(String(localized: "Saved to Photos"))
            case .denied:
                Theme.Haptics.warning()
                self?.presentToast(
                    String(localized: "Allow photo access in Settings to save pictures."))
            case .failed:
                Theme.Haptics.error()
                self?.presentToast(String(localized: "Couldn't save to Photos"))
            }
        }
    }

    private func exportToFiles(_ payload: ImagePayload) {
        guard let url = ImageExport.temporaryFile(payload) else {
            presentToast(String(localized: "Couldn't export the picture."))
            return
        }
        present(UIDocumentPickerViewController(forExporting: [url], asCopy: true), animated: true)
    }

    private func shareImage(_ payload: ImagePayload, from source: UIView) {
        let item: Any = ImageExport.temporaryFile(payload) ?? payload.image
        let sheet = UIActivityViewController(activityItems: [item], applicationActivities: nil)
        sheet.popoverPresentationController?.sourceView = source
        sheet.popoverPresentationController?.sourceRect = source.bounds
        present(sheet, animated: true)
    }
}

extension ChatViewController: TextBubbleCellDelegate {
    func textBubbleCell(_ cell: TextBubbleCell, didTapLink url: URL) {
        if let path = TextBubbleCell.path(fromActionURL: url) {
            presentPathActions(path)
            return
        }
        openWebLink(url)
    }

    /// Every link here originates in model or tool output, and the markdown
    /// renderer preserves both an arbitrary label and an arbitrary scheme — so
    /// a transcript can present "docs" over `sms:`, `facetime:` or another
    /// app's deep link. Web links open in-app; anything else has to be
    /// confirmed against its real destination before it leaves the app.
    func openWebLink(_ url: URL) {
        switch url.scheme?.lowercased() {
        case "http", "https":
            present(SFSafariViewController(url: url), animated: true)
        default:
            confirmExternalOpen(url)
        }
    }

    private func confirmExternalOpen(_ url: URL) {
        let sheet = UIAlertController(
            title: String(localized: "Open outside Tailscode?"),
            message: url.absoluteString, preferredStyle: .alert)
        sheet.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        sheet.addAction(
            UIAlertAction(title: String(localized: "Open"), style: .default) { _ in
                UIApplication.shared.open(url)
            })
        sheet.addAction(
            UIAlertAction(title: String(localized: "Copy link"), style: .default) { [weak self] _ in
                UIPasteboard.general.string = url.absoluteString
                self?.presentToast(String(localized: "Link copied."))
            })
        present(sheet, animated: true)
    }

    private func presentPathActions(_ path: String) {
        Theme.Haptics.tap()
        let sheet = UIAlertController(title: path, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(
            UIAlertAction(title: String(localized: "Copy path"), style: .default) { [weak self] _ in
                UIPasteboard.general.string = path
                Theme.Haptics.success()
                self?.presentToast(String(localized: "Path copied."))
            })
        sheet.addAction(
            UIAlertAction(title: String(localized: "Add to message"), style: .default) {
                [weak self] _ in
                self?.composer.appendPath(path)
            })
        sheet.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        sheet.popoverPresentationController?.sourceView = composer
        present(sheet, animated: true)
    }
}

extension ChatViewController: KeyActionHost {
    var keyContext: KeyContext {
        composer.isEditing || findField.isFirstResponder ? .insert : .normal
    }

    var keyAwaitingApproval: Bool { pendingPermission != nil }

    /// The conversation's answers to the shared registry — the same verbs the desktops
    /// dispatch, spoken through this screen's own controls. False lets a press fall through.
    func performKeyAction(_ action: KeyAction) -> Bool {
        switch action {
        case .scrollDown:
            nudgeTranscript(by: 80)
        case .scrollUp:
            nudgeTranscript(by: -80)
        case .halfPageDown:
            nudgeTranscript(by: collectionView.bounds.height * 0.5)
        case .halfPageUp:
            nudgeTranscript(by: -collectionView.bounds.height * 0.5)
        case .scrollTop:
            userScrolledUp = true
            collectionView.setContentOffset(
                CGPoint(x: 0, y: -collectionView.adjustedContentInset.top), animated: true)
        case .scrollBottom:
            scrollToBottom(animated: true)
        case .findInConversation:
            openFind()
        case .insert:
            composer.focus()
        case .leaveInsert:
            if findVisible {
                closeFind()
                becomeFirstResponder()
            } else if composer.isEditing {
                composer.unfocus()
                becomeFirstResponder()
            } else {
                return false
            }
        case .send:
            guard composer.isEditing else { return false }
            composer.triggerSend()
        case .stop:
            guard viewModel.isBusy else { return false }
            composerDidTapStop()
        case .commandPalette:
            composer.setDraft("/")
        case .toggleSaved:
            toggleSaved()
        case .archiveSelected:
            let archived = ArchivedChatStore.toggle(
                profileID: viewModel.contextID, sessionID: viewModel.session.id)
            presentToast(
                archived
                    ? String(localized: "Archived — hidden from the list, kept on the server")
                    : String(localized: "Back in the chat list"))
        case .renameSelected:
            guard viewModel.canRename else { return false }
            promptRename()
        case .forkSelected:
            guard viewModel.canFork else { return false }
            forkConversation()
        case .allowOnce:
            guard let permission = pendingPermission else { return false }
            viewModel.respond(to: permission, decision: .once)
        case .allowAlways:
            guard let permission = pendingPermission else { return false }
            viewModel.respond(to: permission, decision: .always)
        case .deny:
            guard let permission = pendingPermission else { return false }
            viewModel.respond(to: permission, decision: .reject)
        case .toggleHelp:
            ShortcutCheatsheetViewController.present(from: self)
        default:
            return false
        }
        return true
    }

    private func nudgeTranscript(by delta: CGFloat) {
        let inset = collectionView.adjustedContentInset
        let minY = -inset.top
        let maxY = max(minY, collectionView.contentSize.height - collectionView.bounds.height + inset.bottom)
        let target = min(maxY, max(minY, collectionView.contentOffset.y + delta))
        if delta < 0 { userScrolledUp = true }
        collectionView.setContentOffset(CGPoint(x: 0, y: target), animated: true)
    }
}
