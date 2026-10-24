import MidgarCore
import TailscodeCore
import CodingAgentKit
import UIKit

extension ChatViewController {
    func compose(_ state: ConversationState, rebuild: TranscriptRebuild?) {
        let previousPermissionID = pendingPermission?.id
        let previousQuestionID = pendingQuestion?.id
        pendingPermission = state.pendingPermissions.first
        if pendingQuestion?.id != state.pendingQuestions.first?.id {
            questionSelection = restoredSelection(for: state.pendingQuestions.first)
        }
        pendingQuestion = state.pendingQuestions.first
        withdrawResolvedRequests(
            previousPermission: previousPermissionID, previousQuestion: previousQuestionID)
        var ids = orderedIDs
        var pendingIDs: [String] = []
        for send in viewModel.pendingSends {
            for index in send.pictures.indices {
                pendingIDs.append("pending:\(send.id.uuidString):img\(index)")
            }
            if !send.text.isEmpty || send.pictures.isEmpty {
                pendingIDs.append("pending:\(send.id.uuidString)")
            }
        }
        ids.append(contentsOf: pendingIDs)
        let queueDisplay = viewModel.queueDisplay
        for message in queueDisplay.rows { ids.append(message.key) }
        if queueDisplay.paused { ids.append(Self.queuePausedRowID) }
        revertBanner = RevertReading.read(state.revert, setAside: state.revertedMessages)
        fillComposerAfterRevert(state)
        if revertBanner != nil { ids.append(Self.revertRowID) }
        interrupted = interruptedCard(state)
        if interrupted != nil { ids.append(Self.interruptedRowID) }
        let lastContentRole: MessageRole? =
            viewModel.pendingSends.isEmpty
            ? orderedIDs.last.flatMap { rowsByID[$0]?.role } : .user
        let previousCompaction = liveCompaction
        updateLiveCompaction(
            state.compaction, seams: seamCount,
            queued: !viewModel.pendingSends.isEmpty || !viewModel.queued.isEmpty)
        retryStanding = state.retry
        if let liveCompaction {
            ids.append(liveCompaction.id)
        } else if retryStanding != nil {
            ids.append(Self.retryRowID)
        } else if viewModel.isBusy, pendingPermission == nil, pendingQuestion == nil,
            lastContentRole != .assistant
        {
            ids.append("thinking")
        }
        if let pendingQuestion { ids.append("question:\(pendingQuestion.id)") }
        if let pendingPermission { ids.append("permission:\(pendingPermission.id)") }
        Self.logPendingPhantom(state: state, viewModel: viewModel)
        let uniqueIDs = Self.appendingUnique(
            ids.dropFirst(orderedIDs.count), to: orderedIDs, known: rowsByID)
        let orderUnchanged = renderedIDOrder == uniqueIDs
        if !orderUnchanged { renderedIDOrder = uniqueIDs }
        let idSet = orderUnchanged && !lastRenderedIDs.isEmpty ? lastRenderedIDs : Set(uniqueIDs)
        let previouslyRendered = lastRenderedIDs
        let entranceEligible = hasRevealed && !userScrolledUp
        let entranceBubbles =
            entranceEligible
            ? uniqueIDs.filter {
                !lastRenderedIDs.contains($0)
                    && ($0.hasPrefix("pending:") || $0.hasPrefix("queued:"))
            } : []
        let entranceThinking =
            entranceEligible && uniqueIDs.contains("thinking")
            && !lastRenderedIDs.contains("thinking")
        lastRenderedIDs = idSet

        let handOffEmptyState =
            isHandingOffEmptyState && !emptyState.isHidden && !entranceBubbles.isEmpty
        isHandingOffEmptyState = false
        deferEmptyStateHide = handOffEmptyState
        updatePlaceholders(hasRows: !uniqueIDs.isEmpty, for: state)
        deferEmptyStateHide = false

        let nearBottom = isNearBottom()
        // A send that goes again keeps the row it was written in — retrying a failure, letting a
        // message held for a quota window go now — so its rows are not new to the list and nothing
        // here would see a send at all. The send says so itself instead.
        let goingAgain = canvasForcedSend.map { "pending:\($0.uuidString)" }
        let freshSend = Self.freshSendRows(
            among: pendingIDs.filter { id in
                !previouslyRendered.contains(id)
                    || goingAgain.map { id == $0 || id.hasPrefix($0 + ":") } == true
            })
        // A send this device just made rises wherever the reader was standing: they wrote it, and
        // the desktops have always risen on it unconditionally. Only a finger actually on the
        // transcript holds it back — the words a queue drains are the person's own, and the read
        // that used to gate this could not tell a reader who had wandered off from one who had
        // scrolled up precisely to watch the next answer land.
        if !freshSend.isEmpty, !isFingerDown {
            canvasIntent = freshSend
            canvasFloor = orderedIDs.count
            canvasForcedSend = nil
            MidgarLog.info(
                "fresh canvas wanted: rows=\(freshSend.count) revealed=\(hasRevealed) session=\(viewModel.session.id)",
                category: .chat
            )
        }
        let shownIDs = idsToShow(from: uniqueIDs)
        let shownSet = shownIDs.count == uniqueIDs.count ? idSet : Set(shownIDs)
        let listUnchanged = appliedIDs == shownIDs
        appliedIDs = shownIDs

        var changed: [String] = []
        if let rebuild {
            changed = orderedIDs.filter {
                rebuild.previous[$0] != nil && rebuild.previous[$0] != rowsByID[$0]
            }
        }
        // A row this device is holding changes without the transcript moving — sending becomes
        // sent becomes not-sent, and a queue renumbers itself when one of its messages goes. Only
        // rows that were already on screen are repainted; the ones this pass is adding arrive
        // drawn.
        for id in pendingIDs + queueDisplay.rows.map(\.key) + [Self.queuePausedRowID]
        where lastRenderedIDs.contains(id) && !changed.contains(id) {
            changed.append(id)
        }
        if let liveCompaction, liveCompaction != previousCompaction {
            changed.append(liveCompaction.id)
        }
        if interrupted != lastInterrupted, !changed.contains(Self.interruptedRowID) {
            changed.append(Self.interruptedRowID)
        }
        lastInterrupted = interrupted
        if retryStanding != lastRetryStanding, !changed.contains(Self.retryRowID) {
            changed.append(Self.retryRowID)
        }
        lastRetryStanding = retryStanding
        let restoringRevert = viewModel.isRestoringRevert
        if (revertBanner != lastRevertBanner || restoringRevert != lastRestoringRevert),
            !changed.contains(Self.revertRowID)
        {
            changed.append(Self.revertRowID)
        }
        lastRevertBanner = revertBanner
        lastRestoringRevert = restoringRevert
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
        if let rebuild {
            let currentToolStatuses = Self.collectToolStatuses(
                from: rebuild.rows.lazy.reversed().prefix(while: { $0.role != .user })
                    .flatMap { row -> [ActivityStep] in
                        if case .activity(let steps) = row.content { return steps }
                        return []
                    })
            for (id, previousStatus) in lastToolStatuses {
                if let currentStatus = currentToolStatuses[id],
                    previousStatus != currentStatus, currentStatus == .completed
                {
                    Theme.Haptics.step()
                }
            }
            lastToolStatuses = currentToolStatuses
        }
        let animated = animateNextRender && hasRevealed
        animateNextRender = false
        var marked = Set(changed)
        let metrics = Theme.Chat.metrics
        if orderUnchanged, !appliedGaps.isEmpty, appliedGapMetrics == metrics {
            for id in Array(changed) {
                guard let index = orderIndex(of: id) else { continue }
                for target in [index, index + 1] where uniqueIDs.indices.contains(target) {
                    let key = uniqueIDs[target]
                    let gap = gap(before: target, in: uniqueIDs, metrics: metrics)
                    guard appliedGaps[key] != gap else { continue }
                    appliedGaps[key] = gap
                    if marked.insert(key).inserted { changed.append(key) }
                }
            }
        } else {
            let gapTable = gaps(for: uniqueIDs, metrics: metrics)
            for id in uniqueIDs {
                guard let before = appliedGaps[id], before != gapTable[id], marked.insert(id).inserted
                else { continue }
                changed.append(id)
            }
            appliedGaps = gapTable
            appliedGapMetrics = metrics
        }
        let reconfigurable = changed.filter { shownSet.contains($0) }
        func snapshotToApply() -> NSDiffableDataSourceSnapshot<Section, String> {
            var snapshot = NSDiffableDataSourceSnapshot<Section, String>()
            snapshot.appendSections([.main])
            snapshot.appendItems(shownIDs, toSection: .main)
            if !reconfigurable.isEmpty { snapshot.reconfigureItems(reconfigurable) }
            return snapshot
        }
        let risingSend = !canvasIntent.isEmpty && !Self.freshSendRows(among: entranceBubbles).isEmpty
        if risingSend {
            dataSource.apply(snapshotToApply(), animatingDifferences: false) { [weak self] in
                guard let self else { return }
                if handOffEmptyState { self.animateEmptyStateHandoff() }
                let riders = (entranceBubbles + (entranceThinking ? ["thinking"] : [])).compactMap {
                    id -> UIView? in
                    guard let index = self.dataSource.snapshot().indexOfItem(id) else { return nil }
                    return self.collectionView.cellForItem(at: IndexPath(item: index, section: 0))?
                        .contentView
                }
                self.settleFreshCanvas(fading: riders)
            }
        } else if !entranceBubbles.isEmpty || entranceThinking {
            dataSource.apply(snapshotToApply(), animatingDifferences: false) { [weak self] in
                guard let self else { return }
                self.updateTranscriptInsets()
                self.settleFreshCanvas(fading: [])
                if self.canvasPromptIDs.isEmpty { self.scrollToBottom(animated: false) }
                self.collectionView.layoutIfNeeded()
                if handOffEmptyState { self.animateEmptyStateHandoff() }
                self.pinFreshCanvas()
                self.animateSendEntrance(
                    bubbleIDs: entranceBubbles, includeThinking: entranceThinking)
            }
        } else {
            let finishApply: () -> Void = { [weak self] in
                guard let self else { return }
                self.updateTranscriptInsets()
                self.pinFreshCanvas()
                if let opening = self.opening, !opening.isDone {
                    if self.openingStage == nil {
                        self.finishFirstOpeningStage()
                    } else {
                        self.scheduleOpeningStage()
                    }
                } else if !self.hasRevealed && !self.orderedIDs.isEmpty {
                    self.revealTranscript()
                }
                self.settleFreshCanvas(fading: [])
                if self.canvasPromptIDs.isEmpty, nearBottom, !self.userScrolledUp,
                    !self.isFingerDown
                {
                    self.scrollToBottom(animated: animated)
                }
            }
            if listUnchanged, hasRevealed, opening == nil, !animated,
                reconfigurable.isEmpty || reconfigurable.allSatisfy(rewriteLiveTextInPlace)
            {
                finishApply()
            } else {
                openingStageStart = CACurrentMediaTime()
                dataSource.apply(snapshotToApply(), animatingDifferences: animated) {
                    finishApply()
                }
            }
        }

        composer.setBusy(viewModel.isBusy)
        syncFAB()
        updateNavStatus(for: state, messagesMoved: rebuild != nil, facts: rebuild?.facts)
        if wasRunning && state.status != .running {
            if state.messages.last?.isAnswerless == true {
                Theme.Haptics.warning()
            } else if let last = state.messages.last, FailedTurnReading.read(last, prompt: nil) != nil {
                lastHapticFailure = state.lastFailure?.message ?? lastHapticFailure
                Theme.Haptics.error()
            } else {
                Theme.Haptics.received()
                announceTurnEnd()
                ReviewPromptCoordinator.shared.turnCompleted()
                SupporterInvitation.recordSuccessfulTurn()
                NotificationManager.offerAfterFirstTurn(from: self)
            }
            refreshSpend()
            refreshGit()
        }
        if state.hasLoadedTranscript, !hadLoadedTranscript {
            hadLoadedTranscript = true
            refreshSpend()
        }
        wasRunning = state.status == .running
        if let permission = pendingPermission, permission.id != lastHapticPermissionID {
            lastHapticPermissionID = permission.id
            Theme.Haptics.needsYou()
            announce(ActivityKind.needsApproval.spoken)
        }
        if let permission = pendingPermission, permission.id != lastNotifiedPermissionID,
            claimsNeedsYouBanner()
        {
            lastNotifiedPermissionID = permission.id
            NotificationManager.notify(
                kind: .approval,
                title: viewModel.alertTitle,
                body: permission.toolName.map { String(localized: "Approval needed: \($0)") }
                    ?? String(localized: "Approval needed."),
                identifier: "perm:\(permission.id)", sessionID: viewModel.session.id,
                profileID: viewModel.contextID, permission: permission,
                notice: NoticeReader.wire(approval: permission, in: state).located(
                    on: viewModel.serverName, agent: viewModel.backend.agentType.rawValue),
                activity: .needsApproval)
        }
        if let question = pendingQuestion, question.id != lastNotifiedQuestionID {
            lastNotifiedQuestionID = question.id
            Theme.Haptics.needsYou()
            announce(ActivityKind.needsAnswer.spoken)
        }
        if let question = pendingQuestion, question.id != lastBannerQuestionID, claimsNeedsYouBanner() {
            lastBannerQuestionID = question.id
            NotificationManager.notify(
                kind: .question,
                title: viewModel.alertTitle,
                body: question.questions.first?.question
                    ?? String(localized: "The agent has a question."),
                identifier: "question:\(question.id)", sessionID: viewModel.session.id,
                profileID: viewModel.contextID, question: question,
                notice: NoticeReader.wire(question: question, in: state).located(
                    on: viewModel.serverName, agent: viewModel.backend.agentType.rawValue),
                activity: .needsAnswer)
        }
        updateBanner(for: state)
        updateGoalChip(for: state)
        updateOverflowBadge(hasPermission: pendingPermission != nil)
        if findVisible, !viewModel.isBusy || orderedIDs.count != lastFindRowCount {
            lastFindRowCount = orderedIDs.count
            runFind(retarget: false)
        }
    }
}
