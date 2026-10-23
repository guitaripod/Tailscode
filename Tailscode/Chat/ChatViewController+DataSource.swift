import TailscodeCore
import CodingAgentKit
import UIKit

extension ChatViewController {
    func configureDataSource() {
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
            [weak self] collectionView, indexPath, id in
            guard let self else { return Self.blankCell(collectionView, indexPath) }
            #if DEBUG
                self.providedItems.append(indexPath.item)
            #endif
            let cell = self.makeCell(collectionView, indexPath, id)
            (cell as? RowGapCell)?.gapAbove = self.gapAbove(forID: id)
            return cell
        }
    }

    /// The cell for one row. The air above it is not decided here: the provider hands every cell
    /// the gap `ChatSpacing` computes for its place, so no case below names a number.
    private func makeCell(
        _ collectionView: UICollectionView, _ indexPath: IndexPath, _ id: String
    ) -> UICollectionViewCell {
        let display = self.viewModel.queueDisplay
        if id.hasPrefix("queued:"), let message = display.row(key: id) {
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: TextBubbleCell.reuseID, for: indexPath) as! TextBubbleCell
            let held = self.viewModel.queueHold != nil
                && message.holder == .device
                && display.rows.first { $0.holder == .device }?.id == message.id
            let position = (display.rows.firstIndex { $0.id == message.id } ?? 0) + 1
            var actions: [UIAccessibilityCustomAction] = []
            if message.canEdit {
                actions.append(
                    UIAccessibilityCustomAction(name: String(localized: "Edit")) {
                        [weak self] _ in
                        self?.editQueued(message)
                        return true
                    })
            }
            actions.append(
                UIAccessibilityCustomAction(name: String(localized: "Remove from queue")) {
                    [weak self] _ in
                    Theme.Haptics.warning()
                    self?.viewModel.removeQueued(message)
                    return true
                })
            cell.configureQueued(
                text: QueueReading.rowLine(message, held: held),
                editing: self.editingQueued == message.id,
                spoken: QueueReading.spoken(message, position: position, of: display.count),
                hint: held
                    ? SendQueueReading.heldHint(reason: self.viewModel.queueHold)
                    : QueueReading.hint(message),
                actions: actions)
            return cell
        }
        if id == Self.queuePausedRowID, display.paused {
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: QueuePausedCell.reuseID, for: indexPath) as! QueuePausedCell
            cell.configure(count: display.count) { [weak self] in
                Theme.Haptics.tap()
                self?.viewModel.resumeQueue()
            }
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
        if id.hasPrefix("pending:"), id.contains(":img"),
            let echo = self.viewModel.pendingSends.first(where: {
                id.hasPrefix("pending:\($0.id.uuidString):img")
            }),
            let index = Int(id.components(separatedBy: ":img").last ?? ""),
            echo.pictures.indices.contains(index)
        {
            let attachment = echo.pictures[index]
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: ImageBubbleCell.reuseID, for: indexPath) as! ImageBubbleCell
            cell.delegate = self
            cell.configure(
                file: FileReference(
                    path: nil, mime: attachment.mime,
                    url: "pending:\(echo.id.uuidString):\(index)",
                    filename: attachment.filename),
                role: .user, backend: self.viewModel.backend, localData: attachment.data)
            return cell
        }
        if id.hasPrefix("pending:"),
            let send = self.viewModel.pendingSends.first(where: {
                "pending:\($0.id.uuidString)" == id
            })
        {
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: PendingSendCell.reuseID, for: indexPath)
                as! PendingSendCell
            cell.configure(
                send, plan: self.viewModel.resumePlan(for: send.id), delegate: self)
            cell.onResize = { [weak self] in self?.remeasure(id) }
            return cell
        }
        if id == Self.interruptedRowID, let turn = self.interrupted {
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: InterruptedTurnCell.reuseID, for: indexPath)
                as! InterruptedTurnCell
            cell.configure(
                turn,
                onResume: { [weak self] in self?.viewModel.resumeInterruptedTurn() },
                onDismiss: { [weak self] in self?.viewModel.dismissInterruptedTurn() })
            return cell
        }
        if id == Self.retryRowID, let retry = self.retryStanding {
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: ProviderRetryCell.reuseID, for: indexPath)
                as! ProviderRetryCell
            cell.configure(retry) { [weak self] url in self?.openWebLink(url) }
            return cell
        }
        if id == Self.revertRowID, let banner = self.revertBanner {
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: RevertBannerCell.reuseID, for: indexPath)
                as! RevertBannerCell
            cell.configure(banner, restoring: self.viewModel.isRestoringRevert) {
                [weak self] in self?.viewModel.restoreRevert()
            }
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
                    guard let self else { return }
                    self.questionSelection = selection
                    self.recordAnswerDrafts(selection, for: request)
                },
                onSubmit: { [weak self] answers in
                    guard let self, self.answeredQuestionIDs.insert(request.id).inserted
                    else { return }
                    self.clearAnswerDrafts(for: request)
                    self.viewModel.answerQuestion(request, answers: answers)
                },
                onEditingBegan: { [weak self] in
                    self?.revealPendingCard()
                },
                onSkip: { [weak self] in
                    guard let self, self.answeredQuestionIDs.insert(request.id).inserted
                    else { return }
                    self.clearAnswerDrafts(for: request)
                    self.viewModel.rejectQuestion(request)
                })
            return cell
        }
        if id.hasPrefix("permission:"), let request = self.pendingPermission {
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: PermissionCell.reuseID, for: indexPath) as! PermissionCell
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
                cascade: self.cascade.tail(for: id, traits: self.traitCollection))
        case .code(let block):
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: CodeBlockCell.reuseID, for: indexPath) as! CodeBlockCell
            cell.configure(
                block, expanded: self.expandedReasoning.contains(id),
                cascade: self.cascade.tail(for: id, traits: self.traitCollection)
            ) {
                [weak self] in self?.toggleReasoning(id)
            }
            return cell
        case .table(let table):
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: TableCell.reuseID, for: indexPath) as! TableCell
            cell.configure(table, width: collectionView.bounds.width, key: row.id)
            return cell
        case .tableDraft(let draft):
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: TableDraftCell.reuseID, for: indexPath) as! TableDraftCell
            cell.configure(draft)
            return cell
        case .activity(let steps):
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: ActivityGroupCell.reuseID, for: indexPath)
                as! ActivityGroupCell
            let streaming = self.viewModel.isBusy && id == self.streamingActivityID
            let toolTap: ((ToolCall) -> Void)? =
                self.viewModel.supportsSubagents
                ? { [weak self] call in self?.revealSubagent(spawnedBy: call) } : nil
            cell.configure(
                steps: steps, expanded: self.expandedReasoning.contains(id),
                streaming: streaming, compact: AppPreferences.compactActivity,
                onToggle: { [weak self] in self?.toggleReasoning(id) },
                onToolTap: toolTap,
                onToolOpen: { [weak self] call in self?.inspect(tool: call) ?? false },
                onLinkTap: { [weak self] url in self?.openWebLink(url) })
            return cell
        case .brain(let brainRow):
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: NeuralBrainCell.reuseID, for: indexPath) as! NeuralBrainCell
            cell.configure(brainRow, store: self.brain.store, actions: self.brainActions)
            return cell
        case .workflow(let run):
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: WorkflowCardCell.reuseID, for: indexPath)
                as! WorkflowCardCell
            cell.configure(
                run, at: self.workflowNow,
                onAgentTap: { [weak self] agentID in self?.openWorkflowAgent(agentID) })
            return cell
        case .subagent(let card):
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: SubagentCardCell.reuseID, for: indexPath)
                as! SubagentCardCell
            cell.configure(
                card,
                onToggle: { [weak self] in self?.toggleSubagent(card.agentID) },
                onLinkTap: { [weak self] url in self?.openWebLink(url) })
            return cell
        case .subagentGroup(let group):
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: SubagentGroupCell.reuseID, for: indexPath)
                as! SubagentGroupCell
            cell.configure(group) { [weak self] in self?.toggleAgentGroup(group.id) }
            return cell
        case .compaction(let compaction):
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: CompactionCell.reuseID, for: indexPath) as! CompactionCell
            cell.configure(compaction) { [weak self] in
                self?.presentCompactionSummary(compaction)
            }
            return cell
        case .taskBoard(let board):
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: TaskBoardCell.reuseID, for: indexPath) as! TaskBoardCell
            cell.configure(board)
            return cell
        case .designBoard(let sighting):
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: DesignBoardCell.reuseID, for: indexPath)
                as! DesignBoardCell
            cell.configure(
                DesignCardReading.make(
                    sighting: sighting, board: self.designBoard(for: sighting, row: row.id))
            ) { [weak self] in self?.openDesign(sighting.source) }
            return cell
        case .file(let file):
            let label = "📎 \(file.filename ?? file.mime ?? String(localized: "attachment"))"
            return self.bubble(collectionView, indexPath, label, row.role, reasoning: false)
        case .image(let file):
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: ImageBubbleCell.reuseID, for: indexPath) as! ImageBubbleCell
            cell.delegate = self
            cell.onLoaded = { [weak self] in self?.remeasureRow(row.id) }
            cell.configure(file: file, role: row.role, backend: self.viewModel.backend)
            return cell
        case .failed(let turn):
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: FailedTurnCell.reuseID, for: indexPath) as! FailedTurnCell
            cell.configure(turn) { [weak self] in self?.retryFailed(turn) }
            return cell
        case .answerless(let turn):
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: AnswerlessTurnCell.reuseID, for: indexPath)
                as! AnswerlessTurnCell
            cell.configure(turn) { [weak self] in self?.askAgain(turn) }
            return cell
        case .responseStats(let stats):
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: ResponseStatsCell.reuseID, for: indexPath)
                as! ResponseStatsCell
            cell.configure(stats)
            return cell
        case .linkRail(let run):
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: LinkRailCell.reuseID, for: indexPath) as! LinkRailCell
            cell.configure(
                run, opened: railExpansion.isOpen(row.id),
                onToggle: { [weak self] in self?.toggleRail(row.id) },
                onOpen: { [weak self] url in self?.openWebLink(url) })
            return cell
        case .pictures(let files):
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: PictureGalleryCell.reuseID, for: indexPath)
                as! PictureGalleryCell
            cell.delegate = self
            cell.configure(files: files, backend: viewModel.backend)
            return cell
        case .note(let line):
            let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: TranscriptNoteCell.reuseID, for: indexPath)
                as! TranscriptNoteCell
            cell.configure(line)
            return cell
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

    func bubble(
        _ collectionView: UICollectionView, _ indexPath: IndexPath, _ text: String,
        _ role: MessageRole, reasoning: Bool, timestamp: Bool = false,
        cascade: CascadeTail? = nil
    ) -> UICollectionViewCell {
        let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: TextBubbleCell.reuseID, for: indexPath) as! TextBubbleCell
        cell.configure(
            text: text, role: role, reasoning: reasoning, timestamp: timestamp, cascade: cascade)
        cell.linkDelegate = self
        return cell
    }
}
