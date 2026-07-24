import CodingAgentKit
import PhotosUI
import SafariServices
import UIKit

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
    private var pendingAttachments: [PromptAttachment] = []
    private var pendingPermission: PermissionRequest?
    private var pendingQuestion: QuestionRequest?
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
    private let composerAccessories = UIStackView()
    private var agentsPollTask: Task<Void, Never>?
    private var lastAgents: [SubagentSummary] = []
    private let navTitleContainer = UIView()
    private let navSpinner = UIActivityIndicatorView(style: .medium)
    private let attachmentStrip = UIStackView()
    private var suppressBannerUntil: Date = .distantPast
    private var userScrolledUp = false
    private var lastRenderedIDs: Set<String> = []
    private let enhancement = PromptEnhancementController()
    private var enhanceOverlay: PromptEnhanceOverlay?
    private var isApplyingEnhancedPrompt = false

    var sessionID: String { viewModel.session.id }
    private let isReadOnly: Bool

    init(viewModel: ChatViewModel, readOnly: Bool = false) {
        self.viewModel = viewModel
        self.isReadOnly = readOnly
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    deinit {
        agentsPollTask?.cancel()
        elapsedTicker?.cancel()
        revealFallback?.cancel()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = navDisplayTitle
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.backButtonDisplayMode = .minimal
        view.backgroundColor = Theme.Color.background
        configureLayout()
        configureFAB()
        configureAgentsChip()
        configureNavTitleView()
        configureDataSource()
        composer.delegate = self
        composer.showsAttach = viewModel.canAttachImages
        if !isReadOnly {
            enhancement.onStatusChange = { [weak self] status in
                self?.handleEnhancementStatus(status)
            }
        }
        NotificationManager.requestAuthorizationIfNeeded()
        NotificationCenter.default.addObserver(
            self, selector: #selector(sceneDidActivate),
            name: UIApplication.didBecomeActiveNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(sceneWillResign),
            name: UIApplication.willResignActiveNotification, object: nil)
        collectionView.alpha = 0
        revealFallback = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            self?.revealTranscript()
        }
        bind()
        viewModel.start()
        #if DEBUG
            if let auto = ProcessInfo.processInfo.environment["TAILSCODE_AUTOSEND"], !isReadOnly {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    self?.composerDidSend(auto)
                }
            }
            if ProcessInfo.processInfo.environment["TAILSCODE_OPEN_AGENTS"] != nil, !isReadOnly {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    guard let self else { return }
                    let agents = await self.viewModel.subagents()
                    if !agents.isEmpty { self.presentSubagents(agents) }
                }
            }
            if ProcessInfo.processInfo.environment["TAILSCODE_OPEN_MODELS"] != nil, !isReadOnly {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    self?.presentModelPicker()
                }
            }
        #endif
        if !isReadOnly, let draft = UserDefaults.standard.string(forKey: draftKey), !draft.isEmpty {
            composer.setDraft(draft, focus: false)
        }
        if viewModel.supportsModelSelection || viewModel.supportsReasoningEffort {
            Task { await loadModels() }
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        viewModel.isBound = true
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        saveDraft()
        SessionSeenStore.markSeen(viewModel.session.id)
        if isMovingFromParent || isBeingDismissed || navigationController?.isBeingDismissed == true {
            viewModel.isBound = false
            if isReadOnly || !viewModel.isBusy { viewModel.stop() }
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

    private var draftKey: String { "tailscode.draft.\(viewModel.contextID)/\(viewModel.session.id)" }

    @objc private func saveDraft() {
        guard !isReadOnly else { return }
        let text = composer.currentText
        if text.isEmpty {
            UserDefaults.standard.removeObject(forKey: draftKey)
        } else {
            UserDefaults.standard.set(text, forKey: draftKey)
        }
    }

    @objc private func sceneWillResign() { saveDraft() }

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
        collectionView.register(PermissionCell.self, forCellWithReuseIdentifier: PermissionCell.reuseID)
        collectionView.register(
            ActivityGroupCell.self, forCellWithReuseIdentifier: ActivityGroupCell.reuseID)
        collectionView.register(
            ThinkingCell.self, forCellWithReuseIdentifier: ThinkingCell.reuseID)
        collectionView.register(
            QuestionCell.self, forCellWithReuseIdentifier: QuestionCell.reuseID)

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
        composerAccessories.axis = .vertical
        composerAccessories.spacing = Theme.Spacing.xs
        composerAccessories.alignment = .leading
        composerAccessories.translatesAutoresizingMaskIntoConstraints = false
        composerAccessories.addArrangedSubview(attachmentStrip)
        composerAccessories.addArrangedSubview(agentsChip)
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
            isReadOnly
                ? composer.topAnchor.constraint(equalTo: view.bottomAnchor)
                : composer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
        composer.isHidden = isReadOnly

        commandPalette.isHidden = true
        view.addSubview(commandPalette)
        NSLayoutConstraint.activate([
            commandPalette.leadingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: Theme.Spacing.l),
            commandPalette.trailingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -Theme.Spacing.l),
            commandPalette.bottomAnchor.constraint(
                equalTo: composerAccessories.topAnchor, constant: -Theme.Spacing.xs),
        ])

        NSLayoutConstraint.activate([
            composerAccessories.leadingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: Theme.Spacing.l),
            composerAccessories.trailingAnchor.constraint(
                lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -Theme.Spacing.l),
            composerAccessories.bottomAnchor.constraint(
                equalTo: composer.topAnchor, constant: -Theme.Spacing.xs),
        ])

        if !isReadOnly {
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
        }

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
        guard viewModel.supportsSubagents, !isReadOnly else { return }
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
                guard let self, !self.lastAgents.isEmpty else { return }
                self.presentSubagents(self.lastAgents)
            }, for: .touchUpInside)
        agentsPollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refreshAgentsChip()
                try? await Task.sleep(for: .seconds(8))
            }
        }
    }

    private func refreshAgentsChip() async {
        let agents = await viewModel.subagents()
        lastAgents = agents
        let live = agents.count(where: \.isActive)
        guard live > 0 else {
            agentsChip.isHidden = true
            return
        }
        agentsChip.configuration?.title = "\(live) agent\(live == 1 ? "" : "s") working"
        agentsChip.isHidden = false
    }

    private func configureFAB() {
        fab.configuration = fabConfiguration()
        fab.accessibilityLabel = "Scroll to bottom"
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
        navSpinner.hidesWhenStopped = true
        navSpinner.color = Theme.Color.secondaryLabel
        navStatusLabel.font = .preferredFont(forTextStyle: .footnote)
        navStatusLabel.textColor = Theme.Color.secondaryLabel
        navStatusLabel.adjustsFontSizeToFitWidth = true
        navStatusLabel.minimumScaleFactor = 0.8
        let stack = UIStackView(arrangedSubviews: [navSpinner, navStatusLabel])
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
        viewModel.acknowledgeFailure()
        banner.hide()
        viewModel.refresh()
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
                return cell
            }
            if id.hasPrefix("permission:"), let request = self.pendingPermission {
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: PermissionCell.reuseID, for: indexPath) as! PermissionCell
                cell.configure(
                    title: request.toolName.map { "Allow \($0)?" } ?? "Permission requested",
                    detail: request.title ?? "The agent needs your approval to continue."
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
                return self.bubble(collectionView, indexPath, text, row.role, reasoning: false)
            case .code(let block):
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: CodeBlockCell.reuseID, for: indexPath) as! CodeBlockCell
                cell.configure(block, expanded: self.expandedReasoning.contains(id)) {
                    [weak self] in self?.toggleReasoning(id)
                }
                return cell
            case .activity(let steps):
                let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: ActivityGroupCell.reuseID, for: indexPath)
                    as! ActivityGroupCell
                let streaming = self.viewModel.isBusy && id == self.orderedIDs.last
                let toolTap: ((ToolCall) -> Void)? =
                    self.viewModel.supportsSubagents
                    ? { [weak self] call in self?.openSubagentTranscript(for: call) } : nil
                cell.configure(
                    steps: steps, expanded: self.expandedReasoning.contains(id),
                    streaming: streaming,
                    onToggle: { [weak self] in self?.toggleReasoning(id) },
                    onToolTap: toolTap)
                return cell
            case .file(let file):
                let label = "📎 \(file.filename ?? file.mime ?? "attachment")"
                return self.bubble(collectionView, indexPath, label, row.role, reasoning: false)
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
        _ role: MessageRole, reasoning: Bool, timestamp: Bool = false
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: TextBubbleCell.reuseID, for: indexPath) as! TextBubbleCell
        cell.configure(text: text, role: role, reasoning: reasoning, timestamp: timestamp)
        cell.linkDelegate = self
        return cell
    }

    private func bind() {
        viewModel.onState = { [weak self] state in self?.render(state) }
        viewModel.onModelChange = { [weak self] in self?.updateNavControls() }
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
                self.saveDraft()
                self.presentToast("Not sent — your message is back in the composer.")
            } else {
                UIPasteboard.general.string = text
                self.presentToast("Not sent — message copied to clipboard.")
            }
        }
    }

    private func render(_ state: ConversationState) {
        let rows = Self.makeRows(from: state.messages)
        let previous = rowsByID
        rowsByID = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        orderedIDs = rows.map(\.id)

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

        pendingPermission = state.pendingPermissions.first
        if pendingQuestion?.id != state.pendingQuestions.first?.id {
            questionSelection = QuestionCell.Selection()
        }
        pendingQuestion = state.pendingQuestions.first
        var ids = orderedIDs
        for echo in viewModel.localEchoes { ids.append("local:\(echo.id.uuidString)") }
        let lastContentRole: MessageRole? =
            viewModel.localEchoes.isEmpty
            ? orderedIDs.last.flatMap { rowsByID[$0]?.role } : .user
        if viewModel.isBusy, pendingPermission == nil, pendingQuestion == nil,
            lastContentRole != .assistant
        {
            ids.append("thinking")
        }
        if let pendingQuestion { ids.append("question:\(pendingQuestion.id)") }
        if let pendingPermission { ids.append("permission:\(pendingPermission.id)") }
        for message in viewModel.queued { ids.append("queued:\(message.id.uuidString)") }
        Self.logPendingPhantom(state: state, viewModel: viewModel)
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
        let streamingID = viewModel.isBusy ? orderedIDs.last : nil
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
        if wasRunning && state.status != .running { Theme.Haptics.received() }
        wasRunning = state.status == .running
        if let permission = pendingPermission, permission.id != lastHapticPermissionID {
            lastHapticPermissionID = permission.id
            Theme.Haptics.warning()
        }
        if let permission = pendingPermission, permission.id != lastNotifiedPermissionID {
            lastNotifiedPermissionID = permission.id
            NotificationManager.notify(
                title: viewModel.title,
                body: permission.toolName.map { "Approval needed: \($0)" } ?? "Approval needed.",
                identifier: "perm:\(permission.id)", sessionID: viewModel.session.id)
        }
        if let question = pendingQuestion, question.id != lastNotifiedQuestionID {
            lastNotifiedQuestionID = question.id
            Theme.Haptics.warning()
            NotificationManager.notify(
                title: viewModel.title,
                body: question.questions.first?.question ?? "The agent has a question.",
                identifier: "question:\(question.id)", sessionID: viewModel.session.id)
        }
        updateBanner(for: state)
        updateOverflowBadge(hasPermission: pendingPermission != nil)
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
        guard !isReadOnly else { return }
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
        switch state.connection {
        case .reconnecting:
            if Date() > suppressBannerUntil {
                banner.show("Reconnecting…", color: Theme.Color.warning, symbol: "wifi.exclamationmark")
            }
        case .offline:
            if Date() > suppressBannerUntil {
                banner.show(
                    "Offline — tap to retry", color: Theme.Color.danger, symbol: "wifi.slash")
            }
        case .connecting, .live:
            if let failure = state.lastFailure, failure != viewModel.dismissedFailure,
                state.status != .running, Date() > suppressBannerUntil {
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
        fab.accessibilityLabel = "Scroll to bottom, \(unreadCount) new"
    }

    private func clearUnread() {
        guard unreadCount != 0 else { return }
        unreadCount = 0
        fab.configuration = fabConfiguration()
        fab.accessibilityLabel = "Scroll to bottom"
    }

    private var turnStartedAt: Date?
    private var elapsedTicker: Task<Void, Never>?
    private var lastStatusPhaseText = ""

    private func updateNavStatus(for state: ConversationState) {
        guard viewModel.isBusy else {
            navSpinner.stopAnimating()
            navigationItem.titleView = nil
            turnStartedAt = nil
            elapsedTicker?.cancel()
            elapsedTicker = nil
            lastStatusPhaseText = ""
            return
        }
        if turnStartedAt == nil {
            turnStartedAt = Date()
            elapsedTicker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    self?.renderNavStatus()
                }
            }
        }
        let live = ChatViewModel.liveStatus(for: state)
        if navigationItem.titleView == nil {
            navTitleContainer.frame = CGRect(x: 0, y: 0, width: 190, height: 30)
            navigationItem.titleView = navTitleContainer
        }
        navSpinner.startAnimating()
        let color = live.phase == .approval ? Theme.Color.warning : Theme.Color.secondaryLabel
        if lastStatusPhaseText != live.text {
            lastStatusPhaseText = live.text
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
        guard let started = turnStartedAt, !lastStatusPhaseText.isEmpty else { return }
        let seconds = Int(Date().timeIntervalSince(started))
        let elapsed = seconds >= 60
            ? String(format: "%d:%02d", seconds / 60, seconds % 60) : "\(seconds)s"
        navStatusLabel.text = seconds >= 3
            ? "\(lastStatusPhaseText) · \(elapsed)" : lastStatusPhaseText
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

    private func isActivity(_ row: ChatRow) -> Bool {
        if case .activity = row.content { return true }
        return false
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

    private func loadModels() async {
        availableModels = await viewModel.availableModels()
        updateNavControls()
    }

    private func updateNavControls() {
        var items: [UIBarButtonItem] = []
        if viewModel.supportsModelSelection {
            items.append(modelBarButton())
        }
        if viewModel.supportsReasoningEffort {
            items.append(effortBarButton())
        }
        items.append(overflowBarButton())
        navigationItem.rightBarButtonItems = items
        refreshAttachmentGating()
    }

    /// Keeps the attach affordance in sync with what the selected model can
    /// actually see: hides the picker for text-only models and drops pending
    /// image attachments that a model switch made unsendable.
    private func refreshAttachmentGating() {
        if !viewModel.canAttachImages, pendingAttachments.contains(where: { $0.mime.hasPrefix("image/") }) {
            pendingAttachments.removeAll { $0.mime.hasPrefix("image/") }
            updateAttachmentStrip()
            presentToast("Image removed — this model can't see images.")
        }
        composer.showsAttach = viewModel.canAttachImages
    }

    private func updateOverflowBadge(hasPermission: Bool) {
        guard let barItem = navigationItem.rightBarButtonItems?.last else { return }
        if hasPermission {
            barItem.image = UIImage(
                systemName: "ellipsis.circle.badge.exclamationmark",
                withConfiguration: UIImage.SymbolConfiguration(paletteColors: [Theme.Color.label, Theme.Color.warning]))
        } else {
            barItem.image = UIImage(systemName: "ellipsis.circle")
        }
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
                    title: "Jump to message", image: UIImage(systemName: "list.bullet"),
                    children: Array(prompts.suffix(20)))
            ])
        }
        let usage = UIDeferredMenuElement.uncached { [weak self] completion in
            Task { @MainActor in
                guard let self, self.viewModel.supportsUsage, let usage = await self.viewModel.usage() else { return completion([]) }
                var parts: [String] = []
                if let tokens = usage.tokens {
                    parts.append("\(tokens.formatted(.number.notation(.compactName))) tokens")
                }
                if let cost = usage.costUSD {
                    parts.append(String(format: "$%.3f", cost))
                }
                guard !parts.isEmpty else { return completion([]) }
                let item = UIAction(
                    title: "Last turn · \(parts.joined(separator: " · "))",
                    image: UIImage(systemName: "gauge.with.dots.needle.bottom.50percent"),
                    attributes: .disabled
                ) { _ in }
                completion([item])
            }
        }
        let regenerate = UIDeferredMenuElement.uncached { [weak self] completion in
            guard let self, self.viewModel.canRegenerate else { return completion([]) }
            completion([
                UIAction(title: "Regenerate", image: UIImage(systemName: "arrow.clockwise")) {
                    [weak self] _ in
                    Theme.Haptics.tap()
                    self?.viewModel.regenerate()
                }
            ])
        }
        let subagents = UIDeferredMenuElement.uncached { [weak self] completion in
            Task { @MainActor in
                guard let self, self.viewModel.supportsSubagents, !self.isReadOnly else {
                    return completion([])
                }
                let agents = await self.viewModel.subagents()
                guard !agents.isEmpty else { return completion([]) }
                let live = agents.count(where: \.isActive)
                let title = live > 0 ? "Agents (\(agents.count) · \(live) live)" : "Agents (\(agents.count))"
                completion([
                    UIAction(
                        title: title,
                        image: UIImage(systemName: "point.3.connected.trianglepath.dotted")
                    ) { [weak self] _ in self?.presentSubagents(agents) }
                ])
            }
        }
        var children: [UIMenuElement] = [jump, subagents, regenerate, usage]
        children.append(
            UIAction(
                title: "Share transcript", image: UIImage(systemName: "square.and.arrow.up")
            ) { [weak self] _ in self?.shareTranscript() })
        if viewModel.canRename {
            children.append(
                UIAction(title: "Rename", image: UIImage(systemName: "pencil")) {
                    [weak self] _ in self?.promptRename()
                })
        }
        if viewModel.canFork {
            children.append(
                UIAction(
                    title: "Fork conversation",
                    image: UIImage(systemName: "arrow.triangle.branch")
                ) { [weak self] _ in self?.forkConversation() })
        }
        if viewModel.canClear {
            children.append(
                UIAction(
                    title: "Clear conversation", image: UIImage(systemName: "eraser"),
                    attributes: .destructive
                ) { [weak self] _ in self?.confirmClear() })
        }
        return UIBarButtonItem(
            image: UIImage(systemName: "ellipsis.circle"),
            menu: UIMenu(children: children))
    }

    private func scrollTo(id: String) {
        guard let index = dataSource.snapshot().indexOfItem(id) else { return }
        collectionView.scrollToItem(
            at: IndexPath(item: index, section: 0), at: .top, animated: true)
        Theme.Haptics.selection()
    }

    /// Opens the transcript of the subagent a Task/Agent tool call spawned,
    /// matched by tool-use id.
    private func openSubagentTranscript(for call: ToolCall) {
        Task { @MainActor in
            let agents = await viewModel.subagents()
            guard let match = agents.first(where: { $0.toolUseID == call.id }) else {
                presentToast("No transcript for this agent yet.")
                return
            }
            navigationController?.pushViewController(
                SubagentListViewController.transcriptViewController(
                    backend: viewModel.backend, parentSessionID: viewModel.session.id,
                    agent: match),
                animated: true)
        }
    }

    private func presentSubagents(_ agents: [SubagentSummary]) {
        let list = SubagentListViewController(
            backend: viewModel.backend, parentSessionID: viewModel.session.id, agents: agents)
        list.onDismiss = { [weak self] in
            Task { await self?.refreshAgentsChip() }
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
            title: "Rename conversation", message: nil, preferredStyle: .alert)
        alert.addTextField { [weak self] field in
            field.text = self?.viewModel.title
            field.clearButtonMode = .whileEditing
            field.autocapitalizationType = .sentences
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Rename", style: .default) { [weak self, weak alert] _ in
            let title = alert?.textFields?.first?.text?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard let self, !title.isEmpty, title != self.viewModel.title else { return }
            Task {
                do {
                    try await self.viewModel.rename(to: title)
                    self.title = self.navDisplayTitle
                    Theme.Haptics.success()
                } catch {
                    self.presentToast("Couldn't rename this conversation.")
                }
            }
        })
        present(alert, animated: true)
    }

    private func confirmClear() {
        let alert = UIAlertController(
            title: "Clear conversation?",
            message: "This starts a fresh conversation on the agent.", preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Clear", style: .destructive) { [weak self] _ in
            Theme.Haptics.warning()
            self?.viewModel.clearConversation()
        })
        present(alert, animated: true)
    }

    private func promptCustomAnswer(for request: QuestionRequest, questionIndex: Int) {
        let item = request.questions[questionIndex]
        let alert = UIAlertController(title: item.header.isEmpty ? "Your answer" : item.header,
            message: item.question, preferredStyle: .alert)
        alert.addTextField { field in
            field.placeholder = "Type your answer"
            field.text = self.questionSelection.custom[questionIndex]
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Use answer", style: .default) { [weak self] _ in
            guard let self else { return }
            let text = alert.textFields?.first?.text?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
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
                presentToast("Couldn't fork this conversation.")
            }
        }
    }

    private func updateCommandPalette(for text: String) {
        guard text.hasPrefix("/"), !text.contains(" "), !text.contains("\n") else {
            hideCommandPalette()
            return
        }
        let query = String(text.dropFirst()).lowercased()
        let matches = allCommands().filter { command in
            query.isEmpty
                || command.keywords.contains { $0.hasPrefix(query) }
                || command.title.lowercased().contains(query)
        }
        guard !matches.isEmpty else {
            hideCommandPalette()
            return
        }
        commandPalette.update(with: matches)
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
        SlashCommand(keywords: keywords, title: title, subtitle: subtitle, symbol: symbol) {
            [weak self] in
            self?.composer.clear()
            self?.hideCommandPalette()
            Theme.Haptics.selection()
            action()
        }
    }

    private func allCommands() -> [SlashCommand] {
        var list: [SlashCommand] = []
        if viewModel.supportsModelSelection {
            list.append(
                makeCommand(
                    ["model", "m"], "Model", viewModel.selectedModel?.modelID ?? "Choose a model",
                    "cpu"
                ) { [weak self] in self?.presentModelPicker() })
        }
        if viewModel.supportsReasoningEffort {
            list.append(
                makeCommand(
                    ["effort", "reasoning", "think"], "Reasoning effort",
                    (viewModel.currentEffort ?? "default").capitalized,
                    "gauge.with.dots.needle.50percent"
                ) { [weak self] in self?.presentEffortSheet() })
        }
        if viewModel.canRegenerate {
            list.append(
                makeCommand(
                    ["regenerate", "retry"], "Regenerate", "Re-run the last prompt",
                    "arrow.clockwise"
                ) { [weak self] in self?.viewModel.regenerate() })
        }
        if viewModel.supportsUsage {
            list.append(
                makeCommand(
                    ["usage", "cost", "tokens"], "Usage & cost", "Tokens and spend for this session",
                    "gauge.with.dots.needle.bottom.50percent"
                ) { [weak self] in self?.presentUsage() })
        }
        if viewModel.supportsFileBrowsing {
            list.append(
                makeCommand(
                    ["browse", "file", "path"], "Browse files", "Open file browser on server",
                    "folder.fill"
                ) { [weak self] in self?.presentFileBrowser() })
        }
        if viewModel.canFork {
            list.append(
                makeCommand(
                    ["fork", "branch"], "Fork conversation",
                    "Branch to explore a different direction", "arrow.triangle.branch"
                ) { [weak self] in self?.forkConversation() })
        }
        list.append(
            makeCommand(
                ["jump", "goto"], "Jump to message", "Scroll to an earlier prompt", "list.bullet"
            ) { [weak self] in self?.presentJumpSheet() })
        list.append(
            makeCommand(
                ["copy", "transcript"], "Copy transcript", "Copy the whole conversation",
                "doc.on.doc"
            ) { [weak self] in self?.copyTranscript() })
        if viewModel.canClear {
            list.append(
                makeCommand(
                    ["clear", "reset"], "Clear conversation", "Start fresh on the agent", "eraser"
                ) { [weak self] in self?.confirmClear() })
        }
        return list
    }

    private func presentEffortSheet() {
        let sheet = UIAlertController(
            title: "Reasoning effort", message: nil, preferredStyle: .actionSheet)
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
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = composer
        present(sheet, animated: true)
    }

    private func presentUsage() {
        Task { @MainActor in
            guard viewModel.supportsUsage, let usage = await viewModel.usage(),
                usage.tokens != nil || usage.costUSD != nil
            else {
                self.presentToast("No usage recorded for this session yet.")
                return
            }
            var lines: [String] = []
            if let tokens = usage.tokens {
                lines.append("\(tokens.formatted()) tokens")
            }
            if let cost = usage.costUSD {
                lines.append(String(format: "$%.4f", cost))
            }
            let alert = UIAlertController(
                title: "Last turn usage", message: lines.joined(separator: "\n"),
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
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
                self.presentToast("Path copied: \(path)")
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
            presentToast("No earlier messages to jump to.")
            return
        }
        let sheet = UIAlertController(
            title: "Jump to message", message: nil, preferredStyle: .actionSheet)
        for (id, title) in prompts.suffix(15) {
            sheet.addAction(
                UIAlertAction(title: title, style: .default) { [weak self] _ in
                    self?.scrollTo(id: id)
                })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = composer
        present(sheet, animated: true)
    }

    private func transcriptMarkdown() -> String {
        var out: [String] = []
        for id in orderedIDs {
            guard let row = rowsByID[id], !id.hasPrefix("ts:") else { continue }
            let who = row.role == .user ? "You" : "Agent"
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
            case .file(let file):
                body = "[file: \(file.path ?? file.filename ?? "attachment")]"
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
        presentToast("Transcript copied to clipboard.")
    }

    private func shareTranscript() {
        let name = navDisplayTitle.replacingOccurrences(of: "/", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(name.isEmpty ? "transcript" : name).md")
        do {
            try transcriptMarkdown().write(to: url, atomically: true, encoding: .utf8)
        } catch {
            presentToast("Couldn't export the transcript.")
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

    private func modelBarButton() -> UIBarButtonItem {
        let current = viewModel.selectedModel
        let currentName = current?.modelID ?? "Model"
        var providers: [String: [ModelInfo]] = [:]
        for model in availableModels {
            providers[model.providerID, default: []].append(model)
        }
        let sortedProviders = providers.keys.sorted()
        let header = UIAction(
            title: currentName, subtitle: "Model", attributes: .disabled, handler: { _ in })
        var menuChildren: [UIMenuElement] = [header]
        for providerID in sortedProviders {
            guard let models = providers[providerID] else { continue }
            let actions = models.map { model in
                UIAction(
                    title: model.name,
                    state: current?.modelID == model.id && current?.providerID == model.providerID
                        ? .on : .off
                ) { [weak self] _ in
                    Theme.Haptics.selection()
                    self?.viewModel.selectModel(model.selection)
                    self?.updateNavControls()
                }
            }
            if sortedProviders.count > 1 {
                menuChildren.append(UIMenu(title: providerID, children: actions))
            } else {
                menuChildren.append(contentsOf: actions)
            }
        }
        return UIBarButtonItem(
            image: UIImage(systemName: "cpu"),
            menu: UIMenu(title: "Model", children: menuChildren))
    }

    private func effortBarButton() -> UIBarButtonItem {
        let current = viewModel.currentEffort
        let actions = viewModel.reasoningEffortOptions.map { level in
            UIAction(
                title: level.capitalized,
                state: current == level ? .on : .off
            ) { [weak self] _ in
                Theme.Haptics.selection()
                self?.viewModel.setEffort(level)
                self?.updateNavControls()
            }
        }
        return UIBarButtonItem(
            image: UIImage(systemName: "gauge.with.dots.needle.50percent"),
            menu: UIMenu(title: "Reasoning effort", children: actions))
    }

    @objc private func presentModelPicker() {
        guard !availableModels.isEmpty else { return }
        Theme.Haptics.tap()
        let picker = ModelPickerViewController(
            models: availableModels, selected: viewModel.selectedModel
        ) { [weak self] selection in
            self?.viewModel.selectModel(selection)
            self?.updateNavControls()
        }
        let nav = UINavigationController(rootViewController: picker)
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(nav, animated: true)
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

    /// Folds consecutive agent actions (thinking + tools) into one `.activity` row; text and files
    /// break the group and render on their own.
    private static func makeRows(from messages: [ChatMessage]) -> [ChatRow] {
        var rows: [ChatRow] = []
        var lastDate: Date?
        for message in messages {
            if let prev = lastDate, message.createdAt.timeIntervalSince(prev) > 300 {
                rows.append(ChatRow(
                    id: "ts:\(message.id)", messageID: message.id, role: .system,
                    content: .timestamp(Self.relativeTimestamp(message.createdAt))))
            }
            if lastDate == nil || message.createdAt > (lastDate ?? .distantPast) {
                lastDate = message.createdAt
            }
            var steps: [ActivityStep] = []
            var groupID: String?

            func flushActivity() {
                guard !steps.isEmpty, let groupID else { return }
                rows.append(
                    ChatRow(
                        id: "\(message.id):activity:\(groupID)", messageID: message.id,
                        role: message.role, content: .activity(steps)))
                steps = []
            }

            for part in message.parts {
                let id = "\(message.id):\(part.id)"
                switch part.kind {
                case .reasoning(let text):
                    if text.isEmpty { continue }
                    if steps.isEmpty { groupID = part.id }
                    steps.append(.reasoning(text))
                case .tool(let call):
                    if steps.isEmpty { groupID = part.id }
                    steps.append(.tool(call))
                case .text(let text):
                    flushActivity()
                    if text.isEmpty { continue }
                    if message.role == .user {
                        rows.append(
                            ChatRow(id: id, messageID: message.id, role: message.role, content: .text(text)))
                    } else {
                        let segments = MessageSegment.split(text)
                        for (index, segment) in segments.enumerated() {
                            let segID = segments.count == 1 ? id : "\(id):seg\(index)"
                            let content: ChatRow.Content
                            switch segment {
                            case .text(let value): content = .text(value)
                            case .code(let block): content = .code(block)
                            }
                            rows.append(
                                ChatRow(id: segID, messageID: message.id, role: message.role, content: content))
                        }
                    }
                case .file(let file):
                    flushActivity()
                    rows.append(
                        ChatRow(id: id, messageID: message.id, role: message.role, content: .file(file)))
                case .unknown:
                    continue
                }
            }
            flushActivity()
            if let error = message.error, !error.isEmpty, message.role == .assistant {
                rows.append(ChatRow(
                    id: "\(message.id):error", messageID: message.id, role: message.role,
                    content: .error(error)))
            }
        }
        return fuseActivity(rows)
    }

    private static func relativeTimestamp(_ date: Date) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if Calendar.current.isDateInToday(date) { return "Today \(time)" }
        if Calendar.current.isDateInYesterday(date) { return "Yesterday \(time)" }
        return "\(date.formatted(.dateTime.month(.abbreviated).day())), \(time)"
    }

    /// Merges any adjacent activity rows into one, so a run of thinking/tool steps (even across
    /// message boundaries) reads as a single collapsible group.
    private static func fuseActivity(_ rows: [ChatRow]) -> [ChatRow] {
        var merged: [ChatRow] = []
        for row in rows {
            if case .activity(let steps) = row.content, let last = merged.last,
                case .activity(let prior) = last.content
            {
                merged[merged.count - 1] = ChatRow(
                    id: last.id, messageID: last.messageID, role: last.role,
                    content: .activity(prior + steps))
            } else {
                merged.append(row)
            }
        }
        return merged
    }

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
        collectionView.scrollToItem(at: indexPath, at: .bottom, animated: animated)
    }

    private func presentError(_ message: String) {
        let alert = UIAlertController(title: "Error", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

extension ChatViewController: ComposerViewDelegate {
    func composerDidSend(_ text: String) {
        hideCommandPalette()
        sendDraft(text)
    }

    private func sendDraft(_ text: String, model: ModelSelection? = nil, effort: String? = nil) {
        let attachments = pendingAttachments
        pendingAttachments = []
        composer.showsAttach = viewModel.canAttachImages
        updateAttachmentStrip()
        userScrolledUp = false
        animateNextRender = true
        isHandingOffEmptyState = !isReadOnly && !emptyState.isHidden && emptyState.alpha > 0
        UserDefaults.standard.removeObject(forKey: draftKey)
        viewModel.send(text, model: model, effort: effort, attachments: attachments)
    }

    func composerTextDidChange(_ text: String) {
        updateCommandPalette(for: text)
        guard !isReadOnly, !isApplyingEnhancedPrompt else { return }
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
        presentToast("Attached \(text.count.formatted()) characters — sent with your next message.")
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

    func composerDidTapAttach() {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        present(picker, animated: true)
    }
}

extension ChatViewController: PromptEnhanceOverlayDelegate {
    func enhanceOverlay(_ overlay: PromptEnhanceOverlay, didChoose prompt: EnhancedPrompt) {
        AppLogger.ui.info("enhance: chose card \"\(prompt.label)\" (\(prompt.text.count) chars)")
        Theme.Haptics.success()
        isApplyingEnhancedPrompt = true
        composer.setDraft(prompt.text, focus: true)
        isApplyingEnhancedPrompt = false
        saveDraft()
        overlay.requestDismiss()
    }

    func enhanceOverlay(_ overlay: PromptEnhanceOverlay, didCopy prompt: EnhancedPrompt) {
        UIPasteboard.general.string = prompt.text
        Theme.Haptics.success()
        presentToast("Enhanced prompt copied.")
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
        presentToast("Image attached — it'll be sent with your next message.")
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
                    self.composer.showsAttach = self.viewModel.canAttachImages
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
                    UIAction(title: "Edit", image: UIImage(systemName: "pencil")) { _ in
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
                        title: "Remove from queue", image: UIImage(systemName: "trash"),
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
                UIAction(title: "Copy", image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.string = text
                    Theme.Haptics.success()
                }
            ]
            if let code = Self.firstCodeBlock(in: text) {
                actions.append(
                    UIAction(title: "Copy code", image: UIImage(systemName: "curlybraces")) { _ in
                        UIPasteboard.general.string = code
                        Theme.Haptics.success()
                    })
            }
            actions.append(
                UIAction(title: "Quote", image: UIImage(systemName: "quote.opening")) { _ in
                    self?.composer.insertQuote(text)
                })
            actions.append(
                UIAction(title: "Share", image: UIImage(systemName: "square.and.arrow.up")) { _ in
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
        case .file(let file):
            return file.filename ?? file.mime
        case .timestamp, .error:
            return nil
        }
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
        Task { await refreshAgentsChip() }
    }
}

extension ChatViewController: TextBubbleCellDelegate {
    func textBubbleCell(_ cell: TextBubbleCell, didTapLink url: URL) {
        if let path = TextBubbleCell.path(fromActionURL: url) {
            presentPathActions(path)
            return
        }
        switch url.scheme?.lowercased() {
        case "http", "https":
            present(SFSafariViewController(url: url), animated: true)
        default:
            UIApplication.shared.open(url)
        }
    }

    private func presentPathActions(_ path: String) {
        Theme.Haptics.tap()
        let sheet = UIAlertController(title: path, message: nil, preferredStyle: .actionSheet)
        sheet.addAction(UIAlertAction(title: "Copy path", style: .default) { [weak self] _ in
            UIPasteboard.general.string = path
            Theme.Haptics.success()
            self?.presentToast("Path copied.")
        })
        if !isReadOnly {
            sheet.addAction(UIAlertAction(title: "Add to message", style: .default) { [weak self] _ in
                self?.composer.appendPath(path)
            })
        }
        sheet.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        sheet.popoverPresentationController?.sourceView = composer
        present(sheet, animated: true)
    }
}
