import TailscodeCore
import CodingAgentKit
import UIKit

extension ChatViewController {
    func configureLayout() {
        var config = UICollectionLayoutListConfiguration.themed(.plain)
        config.showsSeparators = false
        config.backgroundColor = .clear
        let layout = TranscriptLayout(config: config)
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = Theme.Color.background
        collectionView.keyboardDismissMode = .interactive
        collectionView.alwaysBounceVertical = true
        collectionView.allowsSelection = false
        collectionView.contentInsetAdjustmentBehavior = .automatic
        collectionView.selfSizingInvalidation = .enabled
        collectionView.delegate = self
        collectionView.scrollsToTop = true
        if #available(iOS 26.0, *) { collectionView.topEdgeEffect.style = .hard }
        let dismissTap = UITapGestureRecognizer(target: self, action: #selector(dismissKeyboard))
        dismissTap.cancelsTouchesInView = false
        dismissTap.delegate = self
        collectionView.addGestureRecognizer(dismissTap)
        transcriptDismissTap = dismissTap
        let touchWatch = UILongPressGestureRecognizer(
            target: self, action: #selector(transcriptTouchChanged))
        touchWatch.minimumPressDuration = 0
        touchWatch.cancelsTouchesInView = false
        touchWatch.delaysTouchesBegan = false
        touchWatch.delegate = self
        collectionView.addGestureRecognizer(touchWatch)
        collectionView.register(TextBubbleCell.self, forCellWithReuseIdentifier: TextBubbleCell.reuseID)
        collectionView.register(
            PendingSendCell.self, forCellWithReuseIdentifier: PendingSendCell.reuseID)
        collectionView.register(CodeBlockCell.self, forCellWithReuseIdentifier: CodeBlockCell.reuseID)
        collectionView.register(TableCell.self, forCellWithReuseIdentifier: TableCell.reuseID)
        collectionView.register(
            TableDraftCell.self, forCellWithReuseIdentifier: TableDraftCell.reuseID)
        collectionView.register(
            ImageBubbleCell.self, forCellWithReuseIdentifier: ImageBubbleCell.reuseID)
        collectionView.register(PermissionCell.self, forCellWithReuseIdentifier: PermissionCell.reuseID)
        collectionView.register(
            ActivityGroupCell.self, forCellWithReuseIdentifier: ActivityGroupCell.reuseID)
        collectionView.register(
            NeuralBrainCell.self, forCellWithReuseIdentifier: NeuralBrainCell.reuseID)
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
        collectionView.register(
            TaskBoardCell.self, forCellWithReuseIdentifier: TaskBoardCell.reuseID)
        collectionView.register(
            AnswerlessTurnCell.self, forCellWithReuseIdentifier: AnswerlessTurnCell.reuseID)
        collectionView.register(
            ResponseStatsCell.self, forCellWithReuseIdentifier: ResponseStatsCell.reuseID)
        collectionView.register(
            InterruptedTurnCell.self, forCellWithReuseIdentifier: InterruptedTurnCell.reuseID)
        collectionView.register(
            DesignBoardCell.self, forCellWithReuseIdentifier: DesignBoardCell.reuseID)
        collectionView.register(
            LinkRailCell.self, forCellWithReuseIdentifier: LinkRailCell.reuseID)
        collectionView.register(
            PictureGalleryCell.self, forCellWithReuseIdentifier: PictureGalleryCell.reuseID)
        collectionView.register(
            TranscriptNoteCell.self, forCellWithReuseIdentifier: TranscriptNoteCell.reuseID)
        collectionView.register(
            ProviderRetryCell.self, forCellWithReuseIdentifier: ProviderRetryCell.reuseID)
        collectionView.register(
            RevertBannerCell.self, forCellWithReuseIdentifier: RevertBannerCell.reuseID)
        collectionView.register(
            FailedTurnCell.self, forCellWithReuseIdentifier: FailedTurnCell.reuseID)
        collectionView.register(
            QueuePausedCell.self, forCellWithReuseIdentifier: QueuePausedCell.reuseID)

        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        composerAccessories.onHeightChange = { [weak self] in self?.updateTranscriptInsets() }
        contentSizeWatch = collectionView.observe(\.contentSize, options: [.old, .new]) {
            [weak self] _, change in
            guard let old = change.oldValue?.height, old != change.newValue?.height else { return }
            MainActor.assumeIsolated {
                self?.contentHeightMoved(from: old)
                #if DEBUG
                    if let self {
                        self.heightProbe.contentMoved(of: self.collectionView) { [weak self] in
                            self?.orderedIDs.count ?? 0
                        }
                    }
                #endif
            }
        }

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
        factsRow.translatesAutoresizingMaskIntoConstraints = false
        factsScrim.translatesAutoresizingMaskIntoConstraints = false
        factsScrim.isHidden = true
        composerAccessories.axis = .vertical
        composerAccessories.spacing = Theme.Spacing.xs
        composerAccessories.alignment = .leading
        composerAccessories.translatesAutoresizingMaskIntoConstraints = false
        composerAccessories.addArrangedSubview(attachmentStrip)
        composerAccessories.addArrangedSubview(factsRow)
        composerAccessories.addArrangedSubview(callController.dock)
        factsRow.widthAnchor.constraint(equalTo: composerAccessories.widthAnchor).isActive = true
        callController.dock.widthAnchor.constraint(equalTo: composerAccessories.widthAnchor).isActive = true
        view.addSubview(factsScrim)
        view.addSubview(composerAccessories)
        factsRow.bleed(to: view)
        NSLayoutConstraint.activate([
            factsScrim.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            factsScrim.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            factsScrim.topAnchor.constraint(
                equalTo: factsRow.topAnchor, constant: -CGFloat(ChatChrome.transcriptToChrome)),
            factsScrim.bottomAnchor.constraint(
                equalTo: composer.topAnchor, constant: Theme.Spacing.xs),
        ])

        transcriptBottom = collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            transcriptBottom,

            banner.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            banner.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            banner.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),

            composer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
        rails.append(ReadableRail(composer, in: view))

        commandPalette.isHidden = true
        view.addSubview(commandPalette)
        NSLayoutConstraint.activate([
            commandPalette.bottomAnchor.constraint(
                equalTo: composerAccessories.topAnchor, constant: -Theme.Spacing.xs),
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

        NSLayoutConstraint.activate([
            composerAccessories.bottomAnchor.constraint(
                equalTo: composer.topAnchor, constant: -Theme.Spacing.xs)
        ])
        rails.append(
            ReadableRail(
                host: view,
                compact: [
                    composerAccessories.leadingAnchor.constraint(
                        equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: Theme.Spacing.l),
                    composerAccessories.trailingAnchor.constraint(
                        equalTo: view.safeAreaLayoutGuide.trailingAnchor,
                        constant: -Theme.Spacing.l),
                ],
                regular: [
                    composerAccessories.leadingAnchor.constraint(
                        equalTo: view.readableContentGuide.leadingAnchor, constant: Theme.Spacing.l),
                    composerAccessories.trailingAnchor.constraint(
                        equalTo: view.readableContentGuide.trailingAnchor,
                        constant: -Theme.Spacing.l),
                ]))

        emptyState.translatesAutoresizingMaskIntoConstraints = false
        emptyState.isHidden = true
        emptyState.onSuggestion = { [weak self] prompt in self?.composer.setDraft(prompt) }
        view.insertSubview(emptyState, belowSubview: composer)
        NSLayoutConstraint.activate([
            emptyState.topAnchor.constraint(equalTo: collectionView.topAnchor),
            emptyState.leadingAnchor.constraint(equalTo: collectionView.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: collectionView.trailingAnchor),
            emptyState.bottomAnchor.constraint(lessThanOrEqualTo: collectionView.bottomAnchor),
            emptyState.bottomAnchor.constraint(equalTo: composer.topAnchor).withPriority(.defaultHigh),
        ])

        loadingState.translatesAutoresizingMaskIntoConstraints = false
        loadingState.isHidden = true
        loadingState.isUserInteractionEnabled = false
        view.insertSubview(loadingState, belowSubview: composer)
        NSLayoutConstraint.activate([
            loadingState.topAnchor.constraint(equalTo: collectionView.topAnchor),
            loadingState.leadingAnchor.constraint(equalTo: collectionView.leadingAnchor),
            loadingState.trailingAnchor.constraint(equalTo: collectionView.trailingAnchor),
            loadingState.bottomAnchor.constraint(lessThanOrEqualTo: collectionView.bottomAnchor),
            loadingState.bottomAnchor.constraint(equalTo: composer.topAnchor).withPriority(.defaultHigh),
        ])
    }

    /// A chip above the composer while subagents are out — a session deep in fan-out work can
    /// leave the main transcript still for minutes, which otherwise reads as "nothing is
    /// happening". It counts only agents that are out now: under a turn that is over, none is.
    func configureAgentsChip() {
        guard viewModel.supportsSubagents else { return }
        agentsChip.setLive(.openWork)
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

    func refreshAgentsChip() {
        let live = viewModel.liveSubagentCount
        defer { factsRow.refresh(); syncFactsScrim() }
        guard live > 0 else {
            agentsChip.isHidden = true
            return
        }
        let words = String(localized: "\(live) agents working")
        agentsChip.text = words
        agentsChip.accessibilityLabel = words
        agentsChip.accessibilityHint = String(localized: "Opens the list of agents.")
        agentsChip.isHidden = false
    }

    func syncFactsScrim() {
        factsScrim.isHidden = !factsRow.hasContent
    }

    func configureBackgroundChip() {
        backgroundChip.addAction(
            UIAction { [weak self] _ in self?.presentBackgroundWork() }, for: .touchUpInside)
    }

    /// Work the machine carries between turns, shown while the conversation is in that state and
    /// not otherwise. It breathes like any work in flight, and stands still under reduced motion.
    func updateBackgroundChip(for facts: StatusFacts) {
        defer { factsRow.refresh(); syncFactsScrim() }
        guard case .background(let tasks) = facts.phase else {
            backgroundChip.isHidden = true
            return
        }
        let kind = ActivityKind.inBackground(tasks: tasks)
        backgroundChip.setLive(kind.icon)
        backgroundChip.text = kind.title
        backgroundChip.accessibilityLabel = kind.spoken
        backgroundChip.accessibilityHint = String(localized: "Opens the agents and background work.")
        backgroundChip.isHidden = false
    }

    private func presentBackgroundWork() {
        Theme.Haptics.tap()
        let agents = viewModel.trackedSubagents
        guard !agents.isEmpty else { return }
        presentSubagents(agents)
    }

    func configureGoalChip() {
        guard viewModel.supportsGoals else { return }
        goalChip.setSymbol("target", tone: .attention)
        goalChip.limitText(toShareOf: factsRow, share: 0.6)
        goalChip.accessibilityHint = String(localized: "Shows the goal the agent is working toward.")
        goalChip.addAction(
            UIAction { [weak self] _ in self?.presentGoalDetail() }, for: .touchUpInside)
    }

    /// The chip is the only place a pursued goal is visible, so it tracks the active goal exactly:
    /// a goal that has been met or cleared leaves nothing behind but the toast that announced it.
    func updateGoalChip(for state: ConversationState) {
        guard viewModel.supportsGoals else { return }
        let previous = lastRenderedGoal
        lastRenderedGoal = state.goal
        if let active = state.activeGoal {
            if goalChip.text != active.condition {
                goalChip.text = active.condition
                goalChip.accessibilityLabel = String(
                    localized: "Working toward: \(active.condition)")
            }
            goalChip.isHidden = false
        } else {
            goalChip.isHidden = true
        }
        factsRow.refresh()
        syncFactsScrim()
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
    func presentGoalComposer() {
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
}

extension ChatViewController {
    /// Lays the conversation out for the fold it is held across, read afresh on every pass. Opened
    /// like a book the transcript and composer keep to the page they started on and the second
    /// page becomes the inspector; closed like a laptop the transcript keeps to the top region.
    func adaptToFold() {
        let reading = FoldReading.read(in: view)
        adaptToBook(reading?.isBook == true ? reading : nil)
        adaptToLaptop(reading?.isLaptop == true ? reading : nil)
    }

    /// Held like a laptop the transcript fills the top region and stops at the fold, and everything
    /// to be touched — the composer, its chips and the dial — stays below it on the base. The
    /// transcript is not a control, so it scrolls in its own region instead of under the crease.
    private func adaptToLaptop(_ fold: FoldReading?) {
        let wanted = fold.map { -(view.bounds.height - $0.frame.minY) } ?? 0
        if abs(transcriptBottom.constant - wanted) > 0.5 { transcriptBottom.constant = wanted }
    }

    private func adaptToBook(_ fold: FoldReading?) {
        guard keepToPageBeforeFold(fold), let fold else {
            navTitleStack.transform = .identity
            return
        }
        centerStatusOnPage(ending: fold.frame.minX)
    }

    /// The status the bar centres over the whole window is moved to the middle of the page the
    /// transcript is on, so it neither lands on the fold nor runs under the second page.
    private func centerStatusOnPage(ending edge: CGFloat) {
        guard navTitleStack.window != nil else { return }
        let resting = navTitleStack.transform.tx
        let current = view.convert(navTitleStack.bounds, from: navTitleStack).midX
        let wanted = edge / 2 - (current - resting)
        guard abs(wanted - resting) > 0.5 else { return }
        navTitleStack.transform = CGAffineTransform(translationX: wanted, y: 0)
    }

    /// What the second page shows when a conversation opens beside it: the repository's state
    /// when the conversation works in one, and a picture otherwise.
    func inspectorRoot() -> UIViewController {
        guard let backend = viewModel.backend as? any GitObservingBackend, git?.isRepository == true
        else { return ChatInspector.placeholder() }
        let panel = GitStatusViewController(
            backend: backend, directory: viewModel.session.directory, sessionID: viewModel.session.id)
        panel.isBesideConversation = true
        return panel
    }

    /// Opens a tool's whole output on the second page when the conversation has one, and says so;
    /// anywhere else the tap keeps meaning what it always did.
    func inspect(tool call: ToolCall) -> Bool {
        guard let inspector = workspace?.inspector, inspector.isInstalled else { return false }
        Theme.Haptics.tap()
        inspector.show(ToolOutputViewController(call: call))
        return true
    }

    func inspectableTable(_ id: String) -> MarkdownTable? {
        guard workspace?.inspector.isInstalled == true, case .table(let table)? = rowsByID[id]?.content
        else { return nil }
        return table
    }

    #if DEBUG
        /// `TAILSCODE_INSPECT=tool|table` puts the first tool output or the first table of the
        /// transcript on the second page, so the open book can be photographed without a tap.
        func inspectForVerification(_ what: String) {
            guard let inspector = workspace?.inspector, inspector.isInstalled else { return }
            for id in orderedIDs {
                switch rowsByID[id]?.content {
                case .table(let table)? where what == "table":
                    inspector.show(TableInspectorViewController(table: table))
                    return
                case .activity(let steps)? where what == "tool":
                    for case .tool(let call) in steps where call.output?.isEmpty == false {
                        inspector.show(ToolOutputViewController(call: call))
                        return
                    }
                default:
                    break
                }
            }
        }
    #endif
}
