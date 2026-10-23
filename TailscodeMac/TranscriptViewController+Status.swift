import AppKit
import os
import CodingAgentKit
import TailscodeCore

extension TranscriptViewController {
    /// The same edges the phone reports to the hand, read before the new state replaces the old:
    /// a tool call landing while you wait, the turn ending, the agent stopping to ask. The cues
    /// are the waiting group's — the wait is what the app asks of someone, so the wait is what
    /// the trackpad reports.
    func noteHapticEdges(state: ConversationState) {
        if rowBuilder.takeCompletions() > 0 { MacHaptics.shared.play(.step) }
        if wasRunningForHaptics && state.status != .running {
            MacHaptics.shared.play(.received)
            if view.window?.isKeyWindow == true, state.messages.last?.error == nil {
                announce(Localized.text("Your agent finished."))
            }
            if state.messages.last?.isAnswerless != true {
                MacReviewPrompt.shared.turnCompleted()
                SupporterInvitation.recordSuccessfulTurn()
            }
        }
        wasRunningForHaptics = state.status == .running
        if let permission = state.pendingPermissions.first, permission.id != hapticPermissionID {
            hapticPermissionID = permission.id
            MacHaptics.shared.play(.needsYou)
            announce(ActivityKind.needsApproval.spoken)
        }
        if let question = state.pendingQuestions.first, question.id != hapticQuestionID {
            hapticQuestionID = question.id
            MacHaptics.shared.play(.needsYou)
            announce(ActivityKind.needsAnswer.spoken)
        }
    }

    /// Said once, at high priority, to whoever is listening: the app is in front and this window is
    /// on screen. A screen reader cannot see a card dock itself at the end of a conversation or a
    /// turn end quietly, and a window nobody is looking at has nobody to tell.
    func announce(_ text: String) {
        guard NSApp.isActive, view.window?.isVisible == true else { return }
        NSAccessibility.post(
            element: NSApp as Any, notification: .announcementRequested,
            userInfo: [
                .announcement: announcement(saying: text),
                .priority: NSAccessibilityPriorityLevel.high.rawValue,
            ])
    }

    /// With several panes on screen the words alone do not say whose they are, so the chat's title
    /// leads them; a lone pane has nothing to tell apart and says the words.
    private func announcement(saying text: String) -> String {
        guard identityStrip?.isHidden == false else { return text }
        let title = identityLabel.stringValue
        return title.isEmpty ? text : "\(title). \(text)"
    }

    /// The band between transcript and composer: what the turn is doing, which agents are out,
    /// how much of the context is spent, what the goal is — every fact clickable, so reading the
    /// status and steering the turn are one gesture rather than two.
    func updateStatus() {
        guard let state = lastState else {
            lastFacts = nil
            statusBand.render(facts: nil, notice: notice)
            showBand(statusBand.hasContent)
            return
        }
        let quotas = quotasForStatus?() ?? []
        contextFill = transcriptFill?.rewindowed(
            model: composer.activeModelID, providerID: composer.activeSelection?.providerID,
            catalog: composer.catalog)
        let facts = StatusFacts.from(
            state: state, agents: agents, usage: usage,
            attachments: composer.attachmentCount, context: contextFill, quotas: quotas,
            queued: queueDisplay.count, spend: spend, git: git, model: composer.activeModelID,
            selection: composer.activeSelection, trail: RangeStore.trail)
        lastFacts = facts
        noteBrainContext(facts)
        let bandNotice = quotaNotice(state: state, quotas: quotas) ?? notice
        statusBand.render(facts: facts, notice: bandNotice)
        showBand(statusBand.hasContent)
    }

    /// The band floats over the transcript, whose inset follows the composer alone, so it arriving
    /// at the start of a turn moves nothing the person is reading; it fades in over the length of a
    /// glance instead of snapping on. It never animates while the window is being dragged to a new
    /// size, where a fade would trail the edge, or under reduced motion.
    private func showBand(_ shown: Bool) {
        guard let band = bandGlass, shown != bandShown else { return }
        bandShown = shown
        bandFade += 1
        let generation = bandFade
        guard view.window != nil, !view.inLiveResize, MotionBudget.animationAllowed else {
            band.alphaValue = 1
            band.isHidden = !shown
            return
        }
        if shown {
            band.alphaValue = 0
            band.isHidden = false
        }
        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                band.animator().alphaValue = shown ? 1 : 0
            },
            completionHandler: { [weak self, weak band] in
                MainThread.call {
                    guard let self, let band, self.bandFade == generation else { return }
                    band.isHidden = !shown
                    band.alphaValue = 1
                }
            })
    }

    /// What the machine is doing, how full the window is and whether a call is open, handed to the
    /// newest brain so its head wears the same state the band says in words. The model changes and
    /// the rows do not, so the views are restated here rather than through a rebuild. The level
    /// the composer's pill shows goes with it, for the newest turn and every older one.
    func noteBrainContext(_ facts: StatusFacts) {
        guard brains.isActive else { return }
        let context = NeuralBrainContext(
            facts: facts, call: calls.face, effortOptions: composer.shownEffortOptions,
            effort: composer.shownEffort)
        guard brains.setContext(context) else { return }
        brains.restateViews()
    }

    /// Pre-emptive used-up quota on the band while idle — a failed turn already carries the
    /// rewritten phase, so this only speaks when the wall is up before the next send. Only the
    /// chat's own provider family speaks here, and only the wall standing in front of the model
    /// this chat would send with; every other wall is worn where a model is picked.
    private func quotaNotice(state: ConversationState, quotas: [UsageQuota]) -> String? {
        if let waiting = resume.plans.values.filter({ !$0.isStale() })
            .min(by: { $0.resumesAt < $1.resumesAt })
        {
            return ResumeReading.short(waiting)
        }
        guard state.status != .running else { return nil }
        let relevant = QuotaSurface.relevantQuotas(for: backend?.agentType, among: quotas)
        let effectiveSelection = composer.activeSelection
        let effectiveModel = composer.activeModelID ?? effectiveSelection?.modelID
        if let failure = state.lastFailure,
            QuotaSurface.read(
                failure: failure.message, quotas: relevant, model: effectiveModel,
                selection: effectiveSelection, failedOn: ActiveModel.failedTurn(in: state.messages)
            ) != .moved
        {
            return nil
        }
        return QuotaSurface.hottestExhausted(
            in: QuotaSurface.billingQuotas(
                in: relevant, selection: effectiveSelection, model: effectiveModel),
            model: effectiveModel
        )
        .map(QuotaSurface.short)
    }

    /// A once-a-second nudge while a turn runs, so elapsed time moves without any state event;
    /// every fifth tick also re-asks the server for agents and cost.
    func updateTicker(running: Bool) {
        let running = running || workflowRuns.contains(where: \.isLive)
        if running, tickerTask == nil {
            tickerTask = Task { [weak self] in
                var tick = 0
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled, let self else { return }
                    tick += 1
                    self.updateStatus()
                    self.brains.restateLive()
                    self.updateCompactingElapsed()
                    self.advanceWorkflowClock()
                    if tick % 5 == 0 { self.refreshTurnFacts() }
                }
            }
        } else if !running, tickerTask != nil {
            tickerTask?.cancel()
            tickerTask = nil
            refreshTurnFacts()
        }
    }

    /// Subagents and cost are polled rather than streamed: the bridge reports both on request
    /// only, and a fan-out is worth watching while it runs. One final refresh after the turn
    /// stops settles the agents list on "done" instead of freezing mid-flight glyphs, and one
    /// when the chat opens: a conversation started on another machine is never running here, so
    /// waiting for a turn tick meant its account, its usage and its branch never arrived at all.
    func refreshTurnFacts() {
        guard let backend, let entry else { return }
        factsReadAt = Date()
        startAgentStreamIfAvailable()
        let sessionID = entry.session.id
        let skipAgents = agentStreamSessionID == sessionID && agentStreamTask != nil
        Task { [weak self] in
            let agents = skipAgents ? nil : ((try? await backend.subagents(for: sessionID)) ?? [])
            let usage = (try? await backend.sessionUsage(sessionID)) ?? nil
            let report = (try? await backend.sessionSpend(sessionID)) ?? nil
            let repository = await Self.readGit(backend: backend, session: entry.session)
            guard let self, self.entry?.session.id == sessionID else { return }
            self.usage = usage
            self.git = repository.map { GitState(snapshot: $0) }
            self.spendReading.note(report: report, for: sessionID)
            self.spendReading.note(messages: self.lastState?.messages ?? [], for: sessionID)
            if let agents {
                self.applyAgentSummaries(agents)
            } else {
                self.updateStatus()
            }
        }
    }

    /// The repository the conversation is working in, when the server can read one. A backend
    /// without the routes, or a directory outside version control, answers nil and the band simply
    /// has one fewer fact — never an error about a repository nobody asked for.
    private static func readGit(backend: any CodingAgentBackend, session: AgentSession) async
        -> GitSnapshot?
    {
        guard let observer = backend as? any GitObservingBackend else { return nil }
        let snapshot = try? await observer.gitSnapshot(
            directory: session.directory, sessionID: session.id)
        return (snapshot?.repo == true) ? snapshot : nil
    }

    /// A proto-2 bridge pushes each fan-out's live facts as they change; older servers are
    /// polled. Started on the first fact refresh after a chat opens.
    private func startAgentStreamIfAvailable() {
        guard agentStreamSessionID != entry?.session.id else { return }
        guard let backend, let entry else { return }
        agentStreamSessionID = entry.session.id
        let sessionID = entry.session.id
        agentStreamTask?.cancel()
        agentStreamTask = Task { [weak self] in
            guard let streaming = backend as? SubagentStreaming,
                let changes = await streaming.subagentChanges(for: sessionID)
            else {
                self?.agentStreamSessionID = nil
                return
            }
            for await agents in changes {
                guard let self, !Task.isCancelled, self.entry?.session.id == sessionID
                else { return }
                self.applyAgentSummaries(agents)
            }
        }
    }

    /// This conversation's workflow runs, rebuilt from the transcript and the live fan-out. Only
    /// the cards whose run actually changed are replaced.
    ///
    /// The fold is handed no clock, so it cannot reach for one: every fact a run carries is a fact
    /// the transcript recorded, and the same conversation folds to the same runs whenever it is
    /// read. The clock belongs to the cards, which are drawn against the context's own
    /// ``TranscriptContext/workflowNow``.
    func refreshWorkflowRuns() {
        guard let state = lastState else { return }
        let runs = workflowFold.runs(messages: state.messages, agents: agents)
        if runs != workflowRuns {
            var byCall: [String: WorkflowRun] = [:]
            for run in runs { byCall[run.id] = run }
            let stale = Set(
                byCall.keys.filter { context.workflowRuns[$0] != byCall[$0] }
                    + context.workflowRuns.keys.filter { byCall[$0] == nil })
            workflowRuns = runs
            context.workflowRuns = byCall
            refreshWorkflowCards(stale)
        }
        updateTicker(running: state.status == .running || state.compaction?.isRunning == true)
    }

    /// A changed run is written into the card it already has; only a card whose structure no
    /// longer matches — an agent appeared, the result landed — is rebuilt, and only that card.
    /// A rebuild destroys the view under the pointer and the click that was in flight with it,
    /// so it is the exception, never the once-a-second path.
    private func refreshWorkflowCards(_ ids: Set<String>) {
        guard !ids.isEmpty, !placeholderShown else { return }
        var rebuilt: Set<String> = []
        for index in renderedRows.indices {
            guard case .workflow(let call) = renderedRows[index].kind, ids.contains(call.id),
                index < rowViews.count
            else { continue }
            if !WorkflowCardView.restate(rowViews[index], call: call, context: context) {
                rebuilt.insert(renderedRows[index].key)
            }
        }
        if !rebuilt.isEmpty { replaceRows { rebuilt.contains($0.key) } }
    }

    /// A background run outlives the turn that launched it, so the clock every live card is drawn
    /// against keeps moving after the turn ends — a frozen elapsed reads as a hang.
    private func advanceWorkflowClock() {
        guard workflowRuns.contains(where: \.isLive) else { return }
        context.workflowNow = Date()
        let live = Set(workflowRuns.filter(\.isLive).map(\.id))
        refreshWorkflowRuns()
        refreshWorkflowCards(live)
    }

    func fetchWorkflowAgent(_ agentID: String) {
        guard let backend, let entry, !inFlightSubagents.contains(agentID) else { return }
        inFlightSubagents.insert(agentID)
        let sessionID = entry.session.id
        Task { [weak self] in
            let messages =
                (try? await backend.subagentMessages(sessionID: sessionID, agentID: agentID)) ?? []
            let rows = TranscriptRow.rows(for: messages)
            guard let self else { return }
            self.inFlightSubagents.remove(agentID)
            self.context.subagentRows[WorkflowAgentRows.key(agentID)] = rows
            self.replaceRows {
                guard case .workflow(let call) = $0.kind else { return false }
                return self.context.workflowRuns[call.id]?.agents
                    .contains { $0.id == agentID } ?? true
            }
        }
    }

    private func applyAgentSummaries(_ agents: [SubagentSummary]) {
        self.agents = agents
        var keyed: [String: SubagentSummary] = [:]
        for agent in agents {
            if let toolUseID = agent.toolUseID { keyed[toolUseID] = agent }
        }
        applyAgentFacts(keyed)
        refreshWorkflowRuns()
        updateStatus()
    }
}
