import MidgarCore
import TailscodeCore
import CodingAgentKit
import UIKit

extension ChatViewController {
    func bind() {
        cascade.onFrame = { [weak self] moved in self?.repaintCascade(revealMoved: moved) }
        cascade.onStalled = { [weak self] in self?.giveUpCascade() }
        viewModel.onState = { [weak self] state in self?.offer(state) }
        viewModel.onSignInStateChanged = { [weak self] in
            guard let self else { return }
            self.updateBanner(for: self.viewModel.state)
        }
        viewModel.onModelChange = { [weak self] in
            guard let self else { return }
            self.updateNavControls()
            self.redrawBrainsForEffort()
            self.updateBanner(for: self.viewModel.state)
            self.updateNavStatus(for: self.viewModel.state, messagesMoved: false)
        }
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
        viewModel.onInterruptionChange = { [weak self] in
            guard let self else { return }
            self.render(self.viewModel.state)
        }
        viewModel.onInterruptionRefused = { [weak self] said in
            self?.presentToast(said, duration: 5.0)
        }
        viewModel.onRevertChange = { [weak self] in
            guard let self else { return }
            self.render(self.viewModel.state)
        }
        viewModel.onRevertRestored = { [weak self] in
            guard let self else { return }
            if self.composer.currentText == self.revertComposerFill { self.composer.clear() }
            self.revertComposerFill = nil
        }
        viewModel.onResumeChange = { [weak self] plan in
            guard let self else { return }
            if let plan {
                NotificationManager.scheduleResumeNotice(plan)
            } else {
                for row in self.viewModel.pendingSends.map(\.id) {
                    NotificationManager.withdrawResumeNotice(row)
                }
            }
            self.updateBanner(for: self.viewModel.state)
        }
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
        viewModel.onPending = { [weak self] in
            guard let self else { return }
            let failures = self.viewModel.pendingSends.filter(\.isFailed).map(\.id)
            if Set(failures) != self.announcedFailedSends {
                if !Set(failures).subtracting(self.announcedFailedSends).isEmpty {
                    Theme.Haptics.error()
                }
                self.announcedFailedSends = Set(failures)
            }
            self.renderPending()
        }
    }
}

extension ChatViewController {
    /// A state the stream emitted. Drawing the transcript costs what the conversation weighs, so
    /// words that only got longer wait their turn when drawing is taking more than its share of
    /// the thread, and the newest state is drawn when the wait is over; everything else is drawn
    /// at once.
    func offer(_ state: ConversationState) {
        var growth = lastRenderedState.map { RenderPacer.isGrowth(from: $0, to: state) } ?? false
        #if DEBUG
            if ProcessInfo.processInfo.environment["TAILSCODE_NO_PACER"] != nil { growth = false }
        #endif
        switch pacer.offer(at: CACurrentMediaTime(), isGrowth: growth) {
        case .now:
            heldRender?.cancel()
            heldRender = nil
            drawTimed(state)
        case .after(let wait):
            guard heldRender == nil else { return }
            let item = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.heldRender = nil
                self.drawTimed(self.viewModel.state)
            }
            heldRender = item
            DispatchQueue.main.asyncAfter(deadline: .now() + wait, execute: item)
        }
    }

    private func drawTimed(_ state: ConversationState) {
        let started = CACurrentMediaTime()
        render(state)
        pacer.drew(from: started, to: CACurrentMediaTime())
    }

    /// The server's account of the conversation moved, so every row is built from it again.
    ///
    /// The first account a screen gets is not drawn where it arrives: that is the turn the push
    /// itself is in, and a push, a build of every row and a first layout are three jobs that each
    /// take their own turn of the run loop, so a finger on the screen's edge is answered between them.
    func render(_ state: ConversationState) {
        lastRenderedState = state
        guard hasPainted || state.messages.isEmpty else {
            queueFirstPaint(state)
            return
        }
        paint(state, rebuilt: rebuildTranscript(state))
    }

    func paint(_ state: ConversationState, rebuilt: TranscriptRebuild) {
        hasPainted = hasPainted || !state.messages.isEmpty
        compose(state, rebuild: rebuilt)
        refreshBrainCells()
        noteOpened(state)
        keepRead(state)
        callController.conversationChanged()
    }

    enum FirstPaint {
        case waiting(ConversationState)
        case built(ConversationState, TranscriptRebuild)
    }

    private func queueFirstPaint(_ state: ConversationState) {
        let idle = firstPaint == nil
        firstPaint = .waiting(state)
        if idle { scheduleFirstPaint() }
    }

    private func scheduleFirstPaint() {
        RunLoopTurn.next { [weak self] in self?.advanceFirstPaint() }
    }

    private func advanceFirstPaint() {
        switch firstPaint {
        case .waiting(let state)?:
            firstPaint = .built(state, rebuildTranscript(state))
            scheduleFirstPaint()
        case .built(let state, let rebuilt)?:
            firstPaint = nil
            paint(state, rebuilt: rebuilt)
        case nil:
            break
        }
    }

    /// How often a conversation held open in front of the reader is marked read as it grows.
    private static let readMarkInterval: CFTimeInterval = 2.5

    /// A chat being watched is a chat being read, and the servers keep that mark for every other
    /// device: one left unmarked until the reader walks away shows as unread on the desk while its
    /// answer is streaming onto this screen. So whatever arrives while this screen is the one in
    /// front is marked as it arrives — at most every couple of seconds, plus once when the turn ends
    /// — and nothing is marked while the app is not in the reader's hands.
    private func keepRead(_ state: ConversationState) {
        let running = state.status == .running
        defer { wasRunningWhenMarked = running }
        guard viewIfLoaded?.window != nil, UIApplication.shared.applicationState == .active
        else { return }
        guard !setAsideUnread else { return }
        let now = CACurrentMediaTime()
        let ended = wasRunningWhenMarked && !running
        let stamp = Self.readStamp(state)
        guard ended || (stamp != lastReadStamp && now - lastReadMarkAt >= Self.readMarkInterval)
        else { return }
        lastReadMarkAt = now
        lastReadStamp = stamp
        SessionSeenStore.markSeen(viewModel.session.id)
    }

    /// What the newest message looks like, in one integer: its identity, how many parts it has and
    /// how much it has written. A state that moved something else, a connection phase or a quota,
    /// leaves it as it was and marks nothing, so the seen store is written when there is something
    /// new to have seen.
    private static func readStamp(_ state: ConversationState) -> Int {
        var hasher = Hasher()
        hasher.combine(state.messages.count)
        if let last = state.messages.last {
            hasher.combine(last.id)
            hasher.combine(last.parts.count)
            hasher.combine(last.isStreaming)
            if let part = last.parts.last {
                switch part.kind {
                case .text(let text), .reasoning(let text): hasher.combine(text.utf8.count)
                case .tool(let call): hasher.combine(call.status)
                default: break
                }
            }
        }
        return hasher.finalize()
    }

    /// How long the conversation took to appear, from the moment this screen was made for it to
    /// the first build that had words to draw: the wait a person feels on every tap.
    private func noteOpened(_ state: ConversationState) {
        guard !openTimed, !state.messages.isEmpty else { return }
        openTimed = true
        #if DEBUG
            startBrainWalk()
            startBrainChecks()
        #endif
        MidgarLog.info(
            "journey open session=\(viewModel.session.id) ms=\(FirstAnswerClock.milliseconds(since: openedAt)) messages=\(state.messages.count) rows=\(orderedIDs.count)", category: .performance)
    }

    /// Only what this device is holding changed — a message sent, taken back, failed, or moved in
    /// the queue — and the server's account did not move at all.
    ///
    /// So it is not rebuilt. Rebuilding means walking every message in the conversation and making
    /// a row out of every part of it, which in one of the long ones is most of a second of main
    /// thread, and that second used to sit between pressing Send and seeing the words. What is
    /// redrawn here is the handful of rows docked at the end, which is the whole of what changed.
    func renderPending() {
        compose(lastRenderedState ?? viewModel.state, rebuild: nil)
        callController.conversationChanged()
    }

    /// What a rebuild leaves behind for the compose pass: the rows as they were, so a repaint can
    /// be told from an insertion, and the counts derived from walking them.
    struct TranscriptRebuild {
        let previous: [String: ChatRow]
        let rows: [ChatRow]
        let facts: StatusFacts
    }

    /// A debug launch with `TAILSCODE_NEURAL_LARGE` swaps the conversation for the 174-step demo
    /// turn so the long brain can be looked at without a server holding one, and with
    /// `TAILSCODE_NEURAL_DEMO=write` for the turn that writes a file of a hundred and forty lines.
    private static func stagedState(_ state: ConversationState) -> ConversationState {
        #if DEBUG
            let environment = ProcessInfo.processInfo.environment
            if environment["TAILSCODE_NEURAL_DEMO"] == "write" {
                var staged = state
                staged.messages = NeuralDemo.writing(prefix: "w-")
                return staged
            }
            if let turns = environment["TAILSCODE_NEURAL_TURNS"].flatMap(Int.init), turns > 0 {
                var staged = state
                staged.messages = (0..<turns).flatMap {
                    NeuralDemo.largeTurn(steps: 24, prefix: "t\($0)-", origin: 1_792_000_000 + Double($0) * 4000)
                }
                return staged
            }
            guard let value = environment["TAILSCODE_NEURAL_LARGE"],
                let steps = Int(value), steps > 0
            else { return state }
            var staged = state
            staged.messages = NeuralDemo.largeTurn(steps: steps, prefix: "big-")
            return staged
        #else
            return state
        #endif
    }

    private func rebuildTranscript(_ incoming: ConversationState) -> TranscriptRebuild {
        let state = Self.stagedState(incoming)
        let runs = WorkflowRunAssembly.runs(
            messages: state.messages, agents: viewModel.trackedSubagents)
        workflowRuns = runs
        updateWorkflowTicker()
        refreshTranscriptFill(state)
        let facts = makeFacts(state)
        let stalled: Bool
        if case .stalled = facts.phase { stalled = true } else { stalled = false }
        let reading = brain.reading(of: state, stalled: stalled)
        let effort = viewModel.displayedEffort
        let effortOptions = viewModel.reasoningEffortOptions
        brainEffort = BrainEffortReading(effort: effort, options: effortOptions)
        let layout = brain.layout(
            reading: reading, facts: facts, call: callController.currentFace,
            providerID: viewModel.displayedModel?.providerID,
            effortOptions: effortOptions, effort: effort)
        var rows = ChatRowBuilder.makeRows(
            from: reading.messages, agents: subagentPlacement(for: reading.messages),
            runs: Dictionary(runs.map { ($0.id, $0) }, uniquingKeysWith: { _, latest in latest }),
            turnOpen: reading.running, memo: segmentMemo, brains: layout,
            modelName: { [contextID = viewModel.contextID] selection in
                ModelCatalog.cached(for: contextID).first { $0.selection == selection }?.name
            })
        #if DEBUG
            if let staged = ChatPictureStaging.linkRail() { rows.append(staged) }
            if let staged = ChatPictureStaging.row() { rows.append(staged) }
        #endif
        let previous = rowsByID
        let uniqueRows = Self.dedupeRows(rows)
        rowsByID = Dictionary(uniqueKeysWithValues: uniqueRows.map { ($0.id, $0) })
        orderedIDs = uniqueRows.map(\.id)
        seamCount = uniqueRows.count(where: { Self.isSeam($0) })
        paceCascade(uniqueRows)
        streamingActivityID = orderedIDs.last(where: { id in
            guard let content = rowsByID[id]?.content else { return false }
            if case .activity = content { return true }
            return false
        })

        if AppPreferences.autoExpandThinking {
            for row in uniqueRows where isActivity(row) && !seenReasoning.contains(row.id) {
                seenReasoning.insert(row.id)
                expandedReasoning.insert(row.id)
            }
            if seenReasoning.count > 500 {
                let oldest = seenReasoning.sorted().prefix(seenReasoning.count - 300)
                seenReasoning.subtract(oldest)
                expandedReasoning.subtract(oldest)
            }
        }
        return TranscriptRebuild(previous: previous, rows: rows, facts: facts)
    }

    /// The transcript's own rows are unique by construction, so the rows added to them are the only
    /// ones that need asking: hashing every identity of a conversation on every token was most of
    /// what composing a long one cost.
    static func appendingUnique(
        _ extras: ArraySlice<String>, to ids: [String], known: [String: ChatRow]
    ) -> [String] {
        guard !extras.isEmpty else { return ids }
        var seen = Set<String>()
        var unique = ids
        for id in extras where known[id] == nil && seen.insert(id).inserted { unique.append(id) }
        return unique
    }
}
