import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension ChatPane {
    /// How often the chat in front of the reader is marked read as it grows.
    static let readMarkInterval: TimeInterval = 6

    /// A chat being watched is a chat being read, and the servers keep that mark for every other
    /// device: one left unmarked until the reader walks away shows as unread on the phone while its
    /// answer is streaming onto this screen. So whatever arrives in the active pane of the window
    /// the reader is working in is marked as it arrives — at most every few seconds, each mark a
    /// rewrite of the whole seen ledger and a read mark to deliver, and once more when the turn
    /// ends.
    func keepRead(_ state: ConversationState) {
        let running = state.status == .running
        defer { wasRunningWhenMarked = running }
        guard let host, host.windowIsActive, host.activePane === self,
            let sessionID = entry?.session.id
        else { return }
        let now = Date()
        let ended = wasRunningWhenMarked && !running
        guard ended || now.timeIntervalSince(lastReadMark) >= Self.readMarkInterval else { return }
        lastReadMark = now
        SessionSeenStore.markSeen(sessionID)
    }

    /// Whether a state that has no transcript yet should leave the page as it is. A chat opened
    /// again is drawn at once from the rows the window kept of it, and the conversation behind it
    /// opens with an empty state before it has read anything; taking that for the truth wiped the
    /// page to "Loading…" and built every row a second time a moment later. An empty chat is not
    /// this: it says so with a transcript that has loaded.
    func holdsPaintedRows(whenTold rows: [TranscriptRow], by state: ConversationState)
        -> Bool
    {
        rows.isEmpty && !state.hasLoadedTranscript && !placeholderShown && !renderedRows.isEmpty
    }

    func apply(state: ConversationState, rows: [TranscriptRow]) {
        Trace.mark(
            "apply state loaded=\(state.hasLoadedTranscript) rows=\(rows.count) status=\(state.status)")
        lastState = state
        keepRead(state)
        defer { scheduleHoverRefresh() }
        if let entry, spendReading.note(messages: state.messages, for: entry.session.id) {
            updateStatus()
        }
        if ultracodeInFlight, state.status != .running, state.hasLoadedTranscript {
            ultracodeInFlight = false
            refreshUltracodeAura()
        }
        if Ultracode.turnInvoked(state), !ultracodeInFlight {
            ultracodeInFlight = true
            refreshUltracodeAura()
        }
        // Everything this device docks at the end — the echo, the cut-off card, the queue — is
        // added on the way to the screen and then memoized in `lastFullRows`, and three callers
        // hand that memo straight back in. Taking them off first is what makes this idempotent:
        // without it a re-entrant apply appends a second copy and every consumer downstream, which
        // assumes one row per key, tears.
        let held = holdsPaintedRows(whenTold: rows, by: state)
        var rows = Self.withoutDocked(held ? lastFullRows : rows)
        dockRevert(&rows, state: state)
        pending.reconcile(userMessages: userTally.users(in: state.messages))
        armResumeForWalledTurn(state)
        if !pending.isEmpty {
            if !rows.isEmpty {
                rows.append(TranscriptRow(key: "pending:break", kind: .turnBreak))
            }
            for send in pending.sends {
                let plan = resume.plan(for: send.id)
                rows.append(
                    TranscriptRow(
                        key: Self.pendingKey(send.id) + (plan.map { ":wait\($0.attempt)" } ?? ""),
                        kind: .pendingSend(send, plan)))
            }
        }
        // A turn the machine cut off is docked at the very end: it is an account of what already
        // happened, and it belongs below everything that did.
        if let cutOff = interruptedCard(state) {
            if !rows.isEmpty {
                rows.append(TranscriptRow(key: "interrupted:break", kind: .turnBreak))
            }
            rows.append(
                TranscriptRow(
                    key: "interrupted:\(Self.cardKey(cutOff.state))",
                    kind: .interruptedTurn(cutOff)))
        }
        dockRetry(&rows, state: state)
        // What has been written and not sent sits at the very end, in the order it will go.
        let waiting = queueDisplay
        for (index, row) in waiting.rows.enumerated() {
            rows.append(
                TranscriptRow(
                    key: row.key, kind: .queuedSend(row, position: index + 1, of: waiting.count)))
        }
        if waiting.paused {
            rows.append(TranscriptRow(key: "queue-paused", kind: .queuePaused(count: waiting.count)))
        }
        lastFullRows = rows
        noteDoubledRows(rows)
        let turnOpen = state.status == .running
        let turnEnded = context.turnOpen && !turnOpen
        let sameChat = turnSession == sessionID
        turnSession = sessionID
        context.turnOpen = turnOpen
        refreshWorkflowRuns()
        if let sessionID, !rows.isEmpty { host?.rememberRows(rows, for: sessionID) }
        let appended = max(0, rows.count - lastFullCount)
        lastFullCount = rows.count
        let limit = rowLimit
        let windowed = rows.count > limit ? Array(rows.suffix(limit)) : rows
        let hiddenCount = rows.count - windowed.count
        gtk_widget_set_visible(earlierButton, hiddenCount > 0 ? 1 : 0)
        if hiddenCount > 0 {
            gtk_button_set_label(
                ptr(earlierButton),
                Localized.text("… %@ earlier rows — show more", "\(hiddenCount)"))
        }
        if rows.isEmpty {
            cascade.release()
            if state.hasLoadedTranscript || sessionID == freshlyCreatedID {
                showStarters()
            } else {
                showPlaceholder(Localized.text("Loading…"))
            }
        } else {
            applyRows(
                pacedByCascade(windowed, running: state.status == .running), appended: appended)
            settleStreamedTail(in: windowed)
            paintCascade()
        }
        if turnEnded {
            replaceRows(where: \.hasOpenWork)
            if sameChat { announce(LiveActivityReading.settled(from: state).line) }
        }
        renderPendingCards(state)
        syncJumpPill()
        refreshPills()
        updateStatus()
        updateTicker(running: state.status == .running || state.compaction?.isRunning == true)
        scheduleRetryWake()
        handoff.observe(state, sendsInFlight: pending.hasInFlight)
        restateDrainPriority()
        call.stateChanged(state)
    }

    /// A standing revert, docked right where the set-aside messages used to be. It is an account of
    /// what just happened to the transcript above it, so it reads before anything this device is
    /// separately holding or waiting to send. With no revert standing, a Restore press this device
    /// was still wearing is over.
    func dockRevert(_ rows: inout [TranscriptRow], state: ConversationState) {
        guard let revert = state.revert,
            let banner = RevertReading.read(revert, setAside: state.revertedMessages)
        else {
            revertRestoring = false
            return
        }
        if !rows.isEmpty {
            rows.append(TranscriptRow(key: "revert:break", kind: .turnBreak))
        }
        rows.append(
            TranscriptRow(
                key: "revert:\(revert.messageID)" + (revertRestoring ? ":restoring" : ""),
                kind: .revertBanner(banner, restoring: revertRestoring)))
    }

    /// The turn waiting on its provider, docked in the cut-off card's family. The two never stand
    /// together: one is the machine gone, the other is the machine still trying.
    func dockRetry(_ rows: inout [TranscriptRow], state: ConversationState) {
        guard let card = ProviderRetryReading.read(state.retry) else { return }
        if !rows.isEmpty {
            rows.append(TranscriptRow(key: "retry:break", kind: .turnBreak))
        }
        rows.append(TranscriptRow(key: "retry:card", kind: .providerRetry(card)))
    }

    /// The retry card's countdown never ticks blindly: it wakes once, at the exact moment
    /// `ProviderRetryReading` says the words next change, redraws from what this device is already
    /// holding, and re-arms for the moment after that. A retry that has gone (answered, or the
    /// turn over) simply has nothing to arm for, which is how the clock lets go of the card.
    func scheduleRetryWake() {
        guard let retry = lastState?.retry,
            let next = ProviderRetryReading.nextChange(retry, now: Date())
        else { return }
        retryWakeGeneration += 1
        let token = retryWakeGeneration
        let wait = UInt32(max(0, next.timeIntervalSince(Date())) * 1000) + 20
        Gtk.after(wait) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, self.retryWakeGeneration == token else { return }
                self.redrawPending()
            }
        }
    }

    /// An answer that is on the page twice, named in the log the moment it is built.
    ///
    /// The doubling is intermittent and heals itself a few seconds later, which is exactly the
    /// shape of bug that cannot be read off a screenshot: by the time anyone looks, the evidence
    /// has been swept. Both candidate causes leave the same mark here and are told apart by the two
    /// keys alone — one message id under two segment names is the row naming re-identifying settled
    /// prose, two message ids carrying one answer is the transcript holding the same reply twice.
    /// Only lengths, hashes and keys are written: a log a person is invited to paste into a bug
    /// report never carries what was said.
    func noteDoubledRows(_ rows: [TranscriptRow]) {
        let doubled = doubledRows.read(rows)
        for found in doubled where reportedDoubles.insert(found.hash).inserted {
            AppLog.write(
                .ui,
                "doubled row: chars=\(found.chars) hash=\(String(found.hash, radix: 16)) "
                    + "first=\(found.first) second=\(found.second) rows=\(rows.count)")
        }
    }

    /// A cache arrival (a decoded picture, a fetched subagent transcript) redraws exactly the rows
    /// it belongs to, in place. It is not new content — the unseen counter never moves.
    func replaceRows(where predicate: (TranscriptRow) -> Bool) {
        guard !placeholderShown else { return }
        if pointerHeld {
            heldReplacements.formUnion(renderedRows.filter(predicate).map(\.key))
            return
        }
        stampLiveClock()
        for index in renderedRows.indices where predicate(renderedRows[index]) {
            rebuildRow(at: index)
        }
        applyGaps()
    }

    /// What the turn is waiting on, docked where the CLI's prompt would sit: approvals first,
    /// then questions. Rebuilt only when what is pending actually changes.
    func renderPendingCards(_ state: ConversationState) {
        let compactionKey = state.compaction.map {
            $0.failure ?? "compacting:\($0.startedAt.timeIntervalSince1970):\(pending.hasInFlight)"
        } ?? ""
        let signature = (state.pendingPermissions.map(\.id) + state.pendingQuestions.map(\.id))
            .joined(separator: "|") + "|" + compactionKey
        guard signature != pendingSignature else { return }
        pendingSignature = signature
        announceArrivals(in: state)
        compactingElapsed = nil
        compactingStartedAt = nil
        Gtk.removeChildren(of: pendingBox)
        for permission in state.pendingPermissions {
            gtk_box_append(
                ptr(pendingBox),
                PendingCards.permission(
                    permission, hints: host.map { PendingCards.Hints($0.shortcuts) } ?? .init()
                ) { [weak self] decision in
                    self?.respond(to: permission, decision: decision)
                })
        }
        for question in state.pendingQuestions {
            gtk_box_append(
                ptr(pendingBox),
                PendingCards.question(question, in: entry) { [weak self] answers in
                    self?.answer(question, answers: answers)
                })
        }
        if let compaction = state.compaction {
            if let failure = compaction.failure {
                gtk_box_append(ptr(pendingBox), PendingCards.compactionFailure(failure))
            } else {
                compactingStartedAt = compaction.startedAt
                gtk_box_append(
                    ptr(pendingBox),
                    PendingCards.compacting(
                        startedAt: compaction.startedAt, waiting: pending.hasInFlight
                    ) { [weak self] label in
                        self?.compactingElapsed = label
                    })
            }
        }
    }

    /// An approval or a question is said once, the moment it first stands at the end of the
    /// conversation, and again only for the next one.
    func announceArrivals(in state: ConversationState) {
        let permissions = state.pendingPermissions.map(\.id)
        let questions = state.pendingQuestions.map(\.id)
        let known = announcedPending
        announcedPending = Set(permissions).union(questions)
        for id in permissions where !known.contains(id) {
            announce(ActivityKind.needsApproval.spoken)
        }
        for id in questions where !known.contains(id) {
            announce(ActivityKind.needsAnswer.spoken)
        }
    }

    /// The running card's own clock line, moved by the pane's one-second ticker rather than a
    /// rebuild — the card must hold still while its wait counts up.
    func updateCompactingElapsed() {
        guard let label = compactingElapsed, let startedAt = compactingStartedAt else { return }
        gtk_label_set_text(op(label), CompactionStory.elapsedLine(startedAt: startedAt))
    }

    func respond(to permission: PermissionRequest, decision: PermissionDecision) {
        guard let conversation else { return }
        Task { try? await conversation.respond(to: permission, decision: decision) }
    }

    func respondToFirstPermission(_ decision: PermissionDecision) {
        guard let permission = lastState?.pendingPermissions.first else { return }
        respond(to: permission, decision: decision)
    }

    /// Claude answers by message, so the answer goes out through the ordinary send path — a
    /// bridge busy with a live turn refuses a side-channel call but queues a message.
    func answer(_ question: QuestionRequest, answers: [[String]]) {
        guard let conversation else { return }
        let byMessage = backend?.capabilities.answersQuestionsByMessage == true
        Task {
            if byMessage {
                await conversation.markAnswered(question)
                try? await conversation.send(question.answerMessage(answers))
            } else {
                try? await conversation.answer(question, answers: answers)
            }
        }
    }

    /// The band takes its room by sliding open over the length of a glance, so the transcript above
    /// it gives up a strip of height as a motion rather than a jump; a desk that asked for less
    /// movement has it at once. A revealer that is mid-motion when the window is dragged larger just
    /// finishes inside the new allocation, which is why no resize needs asking about here.
    func revealBand(_ shown: Bool) {
        guard let bandReveal else { return }
        gtk_revealer_set_transition_duration(op(bandReveal), RepeatingMotion.allowed ? 180 : 0)
        gtk_revealer_set_reveal_child(op(bandReveal), shown ? 1 : 0)
    }

    /// The band above the prompt box: what the turn is doing, which agents are out, how much of
    /// the context is spent, what the goal is — every fact clickable. Segment text is the gate —
    /// streaming fires many applies a second and the band already paints in place, so an identical
    /// reading is not walked again.
    func updateStatus() {
        guard let state = lastState else { return }
        let running = state.status == .running || state.compaction?.isRunning == true
        let quotas = host?.quotasForStatus() ?? []
        let facts = StatusFacts.from(
            state: state, agents: agents, usage: usage,
            attachments: attachments.count,
            context: contextFill?.rewindowed(
                model: activeModelID, providerID: activeSelection?.providerID, catalog: models),
            quotas: quotas,
            queued: queueDisplay.count, spend: spend, git: git, model: activeModelID,
            selection: activeSelection, trail: RangeStore.trail)
        RangePanel.transcriptChanged()
        if identityActivity != facts.activity {
            identityActivity = facts.activity
            refreshIdentity()
        }
        brains.update(context: brainContext(activity: facts.activity, fill: facts.context))
        let bandNotice = quotaNotice(state: state, quotas: quotas) ?? notice
        let signature =
            facts.segments.map { "\($0.id):\($0.text):\($0.css)" }.joined(separator: "|")
            + "|\(bandNotice ?? "")|\(running)|\(facts.activity.map { String(describing: $0) } ?? "")"
        if signature != lastStatusSignature {
            lastStatusSignature = signature
            StatusBand.render(into: statusBand, state: bandState, facts: facts, notice: bandNotice)
            {
                [weak self] action in
                Gtk.onMain { [weak self] in self?.perform(bandAction: action) }
            }
            let silent = facts.segments.isEmpty && (bandNotice?.isEmpty ?? true)
            revealBand(!silent)
            StatusBand.fit(
                statusBand, state: bandState, width: bandFrame.map { gtk_widget_get_width($0) } ?? 0)
        }
        let sendName = running ? Localized.text("Queue") : Localized.text("Send")
        if let sendWord { gtk_label_set_text(op(sendWord), sendName.lowercased()) }
        tailscode_set_accessible_label(sendButton, sendName)
        gtk_widget_set_tooltip_text(sendButton, sendName)
        if (gtk_widget_get_visible(stopButton) != 0) != running {
            gtk_widget_set_visible(stopButton, running ? 1 : 0)
            queueLaneFit()
        }
        notePresenceChange()
    }

    /// Tells the window when what this pane is watching has actually changed, which is what puts
    /// the conversation being talked in into LIVE NOW without waiting for the server's sweep. Only
    /// a change is reported: a running turn applies state many times a second, and rebuilding two
    /// hundred sidebar rows per lump is the stutter the list spent a rewrite removing.
    func notePresenceChange() {
        let now = presence.sidebarReading
        guard now != lastPresence else { return }
        lastPresence = now
        Gtk.onMain { [weak self] in self?.host?.scheduleSidebarRender() }
    }

    /// Pre-emptive used-up quota on the band while idle — a failed turn already carries the
    /// rewritten phase, so this only speaks when the wall is up before the next send. Only the
    /// chat's own provider family speaks here, and only the wall standing in front of the model
    /// this chat would send with; every other wall is worn where a model is picked.
    func quotaNotice(state: ConversationState, quotas: [UsageQuota]) -> String? {
        if let waiting = resume.plans.values.filter({ !$0.isStale() })
            .min(by: { $0.resumesAt < $1.resumesAt })
        {
            return ResumeReading.short(waiting)
        }
        guard state.status != .running else { return nil }
        let relevant = QuotaSurface.relevantQuotas(for: backend?.agentType, among: quotas)
        let effectiveSelection = activeSelection
        let effectiveModel = activeModelID ?? effectiveSelection?.modelID
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

    /// The used-up windows on this server's account, for marking a model spent where it is picked.
    func modelQuotas() -> [UsageQuota] {
        QuotaSurface.relevantQuotas(
            for: backend?.agentType, among: host?.quotasForStatus() ?? [])
    }

    func perform(bandAction action: StatusFacts.Action) {
        switch action {
        case .stop: stopTurn()
        case .compact: host?.presentCompactPreflight(for: self)
        case .goal: insertIntoComposer("/goal ")
        case .scrollToPending: scroll(toEnd: true)
        case .scrollToAgents: scrollToNewestAgent()
        case .agent(let id): scrollToAgent(id)
        case .git:
            guard let git, let backend, let entry else { return }
            let directory = entry.session.directory
            let sessionID = entry.session.id
            GitPanel.present(
                parent: host?.windowWidget, state: git,
                title: entry.session.title,
                patch: { row in
                    guard let observer = backend as? any GitObservingBackend else { return nil }
                    return try? await observer.gitPatch(
                        directory: directory, sessionID: sessionID, path: row.path,
                        staged: row.staged)?.patch
                },
                commit: { commit in
                    guard let observer = backend as? any GitObservingBackend else { return nil }
                    return try? await observer.gitCommit(
                        directory: directory, sessionID: sessionID, hash: commit.hash)?.patch
                })
        case .spend:
            guard let spend else { return }
            SpendPanel.present(
                parent: host?.windowWidget, spend: spend,
                title: entry.map { $0.session.title } ?? Localized.text("This conversation"))
        case .range:
            var compact: (@Sendable () -> Void)?
            if backend?.capabilities.supportsCompaction != false {
                compact = { [weak self] in
                    Gtk.onMain { [weak self] in
                        guard let self else { return }
                        self.host?.presentCompactPreflight(for: self)
                    }
                }
            }
            RangePanel.present(
                parent: host?.windowWidget,
                title: entry.map { $0.session.title } ?? Localized.text("This conversation"),
                compact: compact,
                goTo: { [weak self] messageID in
                    Gtk.onMain { [weak self] in self?.scrollToMessage(messageID) }
                },
                read: { [weak self] in self?.rangeReading() })
        case .reconnect:
            guard let conversation else { return }
            Task { await conversation.reconnect() }
        }
    }

    /// Everything the Range sheet reads from this conversation, as it stands now: the transcript,
    /// the window rewindowed for the model on the next send, the account's quotas and this device's
    /// history of them.
    func rangeReading() -> RangePanel.Reading? {
        guard let state = lastState else { return nil }
        let fill = contextFill?.rewindowed(
            model: activeModelID, providerID: activeSelection?.providerID, catalog: models)
        let board = RangeBoard.read(
            messages: state.messages, fill: fill, quotas: host?.quotasForStatus() ?? [],
            model: activeModelID, selection: activeSelection,
            isRunning: state.status == .running, trail: RangeStore.trail)
        return RangePanel.Reading(board: board, fill: fill)
    }
}
