import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension ChatPane {
    /// The moment the turn yields, the next thing written goes. Never while one is running and
    /// never while the composer is holding one open for rewriting: sending it out from under the
    /// person editing it is the one thing the queue exists to prevent. Asked by the conversation's
    /// edge service, once per conversation however many panes show it, and the head is taken from
    /// the store atomically, so no other pane, watch or process can send the same message.
    func drainHeldQueue(_ state: ConversationState) {
        handOverQueue()
        guard let queue, let conversation, !draining, !pending.hasUnsent,
            SendQueueDrain.mayDrain(state, editing: editingQueued != nil, handoff: handoff),
            queue.holdsDeviceHead(routing: queueRouting)
        else { return }
        draining = true
        defer { draining = false }
        guard let next = queue.takeDeviceHead(routing: queueRouting) else { return }
        deliver(next, through: conversation)
    }

    /// Re-reads this conversation's queue from the store, after something else took from it or put
    /// back into it, and redraws the waiting rows.
    func reloadQueue() {
        queue?.adopt()
        if let state = lastState { apply(state: state, rows: lastFullRows) }
    }

    /// How this conversation's backend takes a queued message, read each time because a bridge
    /// says whether it keeps a queue only after the first request to it.
    var queueRouting: QueueRouting {
        guard let backend, let entry else { return .device }
        return QueueRouting(capabilities: backend.capabilities, profileID: entry.profileID)
    }

    /// The whole queue as it is drawn: what the server holds for every client of the
    /// conversation, then what this device still holds.
    var queueDisplay: QueueDisplay {
        queue?.display(lastState, routing: queueRouting) ?? .empty
    }

    /// Writes a message behind a running turn. Where the server keeps the queue it is handed over
    /// at once, under its own id; elsewhere, or while the server cannot be reached, it waits here.
    func hold(_ send: QueuedSend) {
        queue?.append(send)
        handOverQueue()
    }

    /// Hands the server every message this device holds for it. Asked on every state, so a
    /// message written offline goes the moment the server answers and one left in the store by a
    /// version that held everything locally goes on the first connection — but never past a send
    /// of this device's that did not go, which the server's queue would otherwise run first.
    func handOverQueue() {
        guard let queue, let conversation, !pending.hasUnsent else { return }
        let routing = queueRouting
        guard queue.holdsServerBound(routing: routing) else { return }
        Task { [weak self] in
            let changed = await queue.flush(through: conversation, routing: routing)
            if changed { Gtk.onMain { [weak self] in self?.redrawPending() } }
        }
    }

    /// Reports what became of a press on a queued row; a message the server had already started
    /// is said to be sent, and its row is gone either way.
    func report(_ outcome: QueueOutcome) {
        redrawPending()
        if let message = outcome.message { setNotice(message) }
    }

    func resumeQueue() {
        guard let queue, let conversation else { return }
        Task { [weak self] in
            let outcome = await queue.resume(through: conversation)
            Gtk.onMain { [weak self] in self?.report(outcome) }
        }
    }

    func openHandoff() {
        handoff.begin(after: lastState)
        if let entry { host?.live.edges.beganSend(LiveKey(entry), after: lastState) }
        handoffWakeGeneration += 1
        let token = handoffWakeGeneration
        Gtk.after(UInt32((TurnHandoff.patience + 1) * 1000)) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, self.handoffWakeGeneration == token, self.handoff.isOpen else {
                    return
                }
                self.redrawPending()
            }
        }
    }

    /// A send that never left ends the handoff it opened, here and in the conversation's edges.
    func endHandoff() {
        handoff.end()
        if let entry { host?.live.edges.endedSend(LiveKey(entry)) }
    }

    /// A compaction is a turn like any other, so one asked for while a turn runs waits behind
    /// it rather than cutting it off — oh-my-pi aborts the active turn for a compaction, and
    /// every server refuses two turns at once. It is queued as the command it is, so the
    /// waiting row reads `/compact` and drains through the command route, never as words.
    func requestCompaction(instruction: String) {
        guard let conversation else { return }
        let arguments = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        enqueueOrRun(
            QueuedSend(
                text: arguments, model: chosenModel,
                effort: ModelEffort.surviving(chosenEffort, options: effortOptions()),
                kind: .command(name: "compact", arguments: arguments)),
            through: conversation)
    }

    /// A prompt written while a turn runs, while the last one is still being handed over, or behind
    /// messages already waiting is held here, not handed over: a message you can still change is
    /// worth more than a message one place further along, and the order somebody wrote things in
    /// is the order they go. The page follows the queue only when the reader was already at the
    /// end; somebody reading higher up keeps their place.
    func enqueueOrRun(_ send: QueuedSend, through conversation: AgentConversation) {
        guard
            !SendGate.holdsNewSend(
                busy: sendsBusy, queueEmpty: queueDisplay.isEmpty,
                waitingAhead: !pending.waiting.isEmpty)
        else {
            let following = followsBottom
            hold(send)
            if let state = lastState { apply(state: state, rows: lastFullRows) }
            if following { scrollToBottom() }
            return
        }
        deliver(send, through: conversation)
    }

    /// A command goes out without an echo row: it is a turn the server runs from its own
    /// catalog, and no backend writes a user message for an echo to reconcile against, so a
    /// pending row would say "still sending" for the rest of the conversation.
    func runCommand(_ send: QueuedSend, through conversation: AgentConversation) {
        guard case .command(let name, let arguments) = send.kind else { return }
        SlashRecents.record(name)
        Task { [weak self] in
            do {
                try await conversation.run(
                    AgentCommand(name: name, details: "", source: .builtin),
                    arguments: arguments.isEmpty ? nil : arguments, model: send.model,
                    reasoningEffort: send.effort)
            } catch {
                Gtk.onMain { [weak self] in
                    self?.endHandoff()
                    self?.setNotice(AgentErrorText.readable(error))
                }
            }
        }
    }

    /// The key never carries the phase: a send that becomes sent is the same row filling its ink
    /// in, restated in place rather than rebuilt.
    static func pendingKey(_ id: UUID) -> String { "pending:\(id.uuidString)" }

    /// Redraws what this device is holding without rebuilding the transcript from the server's
    /// account of the conversation — the account did not move, and walking it again to add one
    /// row of one's own is the whole reason a long conversation used to swallow a send.
    ///
    /// Before the chat's first state there is no account to redraw onto, and an empty one stood in
    /// for it must not be kept: a rebuild reads the pane's last state, and one that said "nothing
    /// loaded" overtook the real transcript arriving in the same moment and left the chat empty
    /// with every held send waiting on a load that had already happened.
    func redrawPending() {
        let known = lastState
        apply(state: known ?? ConversationState(), rows: lastFullRows)
        if known == nil { lastState = nil }
        scheduleCaptionWake()
    }

    /// Wakes the pending rows at the one moment a caption changes on its own — the wait becoming
    /// news — rather than ticking every second under a row with nothing to say.
    func scheduleCaptionWake() {
        let now = Date()
        guard let next = pending.sends.compactMap({ PendingSendReading.nextCaptionChange($0, now: now) }).min()
        else { return }
        captionWakeGeneration += 1
        let token = captionWakeGeneration
        let wait = UInt32(max(0, next.timeIntervalSince(now)) * 1000) + 20
        Gtk.after(wait) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, self.captionWakeGeneration == token else { return }
                if self.pendingRowsAllDrawn {
                    self.restatePendingRows()
                } else {
                    self.redrawPending()
                }
                self.scheduleCaptionWake()
            }
        }
    }

    func restatePendingRows() {
        let now = Date()
        for index in renderedRows.indices {
            guard case .pendingSend(let send, let plan) = renderedRows[index].kind,
                index < rowWidgets.count,
                let raw = UnsafeMutableRawPointer(bitPattern: rowWidgets[index])
            else { continue }
            TranscriptRow.restatePending(
                on: ptr(raw), send: send, plan: plan, now: now, context: context)
        }
    }

    /// Whether every send this pane holds has a row that can speak for it. A send of pictures or
    /// pastes alone draws its speaking row only once it has something to say, so a caption coming
    /// due for one of those is a redraw rather than a restate.
    var pendingRowsAllDrawn: Bool {
        let drawn = Set(
            renderedRows.compactMap { row -> UUID? in
                if case .pendingSend(let send, _) = row.kind { return send.id }
                return nil
            })
        return pending.sends.allSatisfy { drawn.contains($0.id) }
    }

    /// Whether this pane waits out a spent window on the person's behalf.
    var resumeEnabled: Bool {
        Preferences.autoResume
    }

    /// The windows that stand in front of what this chat would send with — the same reading the
    /// band and the model picker use, so a wall never means one thing in one place and another
    /// somewhere else.
    func resumeQuotas() -> [UsageQuota] {
        QuotaSurface.relevantQuotas(
            for: backend?.agentType, among: host?.quotasForStatus() ?? [])
    }

    /// A send a wall stopped is held rather than left as a failure nobody will come back to.
    /// Anything that is not a wall keeps its own sentence and never reaches this.
    func armResume(row: UUID, reason: String) {
        guard let entry, let send = pending.send(id: row) else { return }
        let verdict = AutoResume.decide(
            row: row, profileID: entry.profileID, sessionID: entry.session.id, trigger: .refused,
            failure: reason, quotas: resumeQuotas(), model: activeModelID,
            selection: activeSelection, enabled: resumeEnabled, attempt: resumeAttempts)
        adopt(verdict, text: send.text, attachments: send.attachments, model: send.model,
            effort: send.effort)
    }

    /// A turn that reached the server, ran into the wall and produced nothing is the commonest
    /// shape of this on a Claude machine: the prompt is already in the transcript, so the words
    /// come from there rather than from a send this device happens to remember.
    func armResumeForWalledTurn(_ state: ConversationState) {
        guard let entry, let failure = state.lastFailure else {
            resumeAttempts = 0
            return
        }
        guard !resume.plans.values.contains(where: { $0.trigger == .answerless }) else { return }
        guard let asked = state.messages.last(where: { $0.role == .user }) else { return }
        let words = asked.parts.compactMap(\.text).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        let answer = state.messages.last { $0.role == .assistant && $0.createdAt >= asked.createdAt }
        guard answer == nil || AutoResume.mayAskAgain(answer) else {
            if QuotaSurface.isQuotaFailure(failure.message) {
                setNotice(ResumeReading.obstacle(.turnHadStarted))
            }
            return
        }
        let verdict = AutoResume.decide(
            row: UUID(), profileID: entry.profileID, sessionID: entry.session.id,
            trigger: .answerless, failure: failure.message, quotas: resumeQuotas(),
            model: activeModelID, selection: activeSelection, enabled: resumeEnabled,
            attempt: resumeAttempts)
        adopt(verdict, text: words, attachments: [], model: chosenModel, effort: chosenEffort)
    }

    /// Takes a verdict and does the one thing it asks for: hold the words and start the clock, or
    /// say out loud why nothing is being waited for.
    func adopt(
        _ verdict: ResumeVerdict, text: String, attachments: [PromptAttachment],
        model: ModelSelection?, effort: String?
    ) {
        switch verdict {
        case .notAWall:
            return
        case .cannot(let obstacle):
            setNotice(ResumeReading.obstacle(obstacle))
        case .resume(let plan):
            resume.hold(plan)
            ResumeStore.hold(
                ResumeRecord(
                    plan: plan, text: text, attachments: attachments, model: model,
                    effort: effort))
            startResumeClock()
            redrawPending()
        }
    }

    /// One clock for the whole pane. A countdown written in minutes needs nothing finer than this,
    /// and the grace this policy adds to every reset is three times the slop — so a wait measured
    /// in hours costs a quarter-minute wakeup that touches one label, rather than a per-second
    /// tick dragging the status band and its network facts along behind it.
    func startResumeClock() {
        guard resumeTask == nil, !resume.isEmpty else { return }
        resumeTask = track(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.resumeTickSeconds))
                guard !Task.isCancelled else { break }
                Gtk.onMain { [weak self] in self?.serviceResume() }
            }
        })
    }

    static let resumeTickSeconds: TimeInterval = 15

    /// The moment a plan is due: look at the gauges rather than assume, then send, wait again, or
    /// stop and say why.
    func serviceResume() {
        guard !resume.isEmpty else {
            resumeTask?.cancel()
            resumeTask = nil
            return
        }
        for plan in resume.stale() {
            resume.drop(plan.id)
            ResumeStore.release(plan.id)
            setNotice(ResumeReading.missed(plan))
        }
        for plan in resume.due() {
            let resending = pending.send(id: plan.id)?.model ?? activeSelection
            switch AutoResume.recheck(
                plan, quotas: resumeQuotas(), model: resending?.modelID, selection: resending,
                enabled: resumeEnabled)
            {
            case .send:
                setNotice(ResumeReading.firing(plan))
                fireResume(plan)
            case .wait(let next):
                resume.hold(next)
                ResumeStore.replan(next)
            case .cancel(let obstacle):
                resume.drop(plan.id)
                ResumeStore.release(plan.id)
                setNotice(ResumeReading.obstacle(obstacle))
            }
        }
        updatePendingCaptions()
        redrawPending()
        if resume.isEmpty {
            resumeTask?.cancel()
            resumeTask = nil
        }
    }

    /// Sends what a plan was holding, through the pane's own send so a resumed message is a
    /// message like any other rather than a second road into the backend.
    func fireResume(_ plan: ResumePlan) {
        guard let conversation else { return }
        resumeAttempts = plan.attempt + 1
        let record = ResumeStore.release(plan.id)
        resume.drop(plan.id)
        let held = pending.send(id: plan.id)
        let text = held?.text ?? record?.text ?? ""
        guard !text.isEmpty else { return }
        let outgoing = QueuedSend(
            text: text, model: held?.model ?? record?.model,
            effort: held?.effort ?? record?.effort,
            attachments: held?.attachments ?? record?.attachments ?? [])
        if held != nil {
            deliver(outgoing, through: conversation, reusing: plan.id)
        } else {
            deliver(outgoing, through: conversation)
        }
    }

    func actOnResume(_ id: UUID, _ act: ResumeReading.Act) {
        guard let plan = resume.plan(for: id) else { return }
        switch act {
        case .sendNow:
            fireResume(plan)
        case .edit:
            resume.drop(id)
            ResumeStore.release(id)
            actOnPending(id, .edit)
        case .stopWaiting:
            resume.drop(id)
            ResumeStore.release(id)
            setNotice(ResumeReading.stopped(plan))
            redrawPending()
        }
        if resume.isEmpty {
            resumeTask?.cancel()
            resumeTask = nil
        }
    }

    /// Picks back up what this device was holding for this conversation when it was last running.
    /// A plan whose window opened while nothing was awake is reported rather than fired.
    func restoreHeldMessages() {
        guard let entry else { return }
        let records = ResumeStore.records(
            profileID: entry.profileID, sessionID: entry.session.id)
        guard !records.isEmpty else { return }
        let userMessages = lastState?.messages.count { $0.role == .user } ?? 0
        for record in records {
            if record.plan.isStale() {
                ResumeStore.release(record.id)
                setNotice(ResumeReading.missed(record.plan))
                continue
            }
            if pending.send(id: record.id) == nil {
                let restored = pending.begin(
                    text: record.text, attachments: record.attachments, model: record.model,
                    effort: record.effort, userMessages: userMessages, now: record.plan.plannedAt,
                    id: record.id)
                pending.mark(
                    id: restored.id,
                    .failed(
                        reason: Localized.text(
                            "%@ %@ is used up", record.plan.provider, record.plan.window)))
            }
            resume.hold(record.plan)
        }
        startResumeClock()
        redrawPending()
    }

    /// Opens a waiting message for rewriting. It keeps its place in the queue; only sending
    /// replaces it.
    func editQueued(_ id: String) {
        guard let row = queueDisplay.row(id: id), row.canEdit else { return }
        let waiting = row.editable
        guard !composerHoldsWords else {
            setNotice(Localized.text("Send or clear what is in the composer first."))
            return
        }
        editingQueued = id
        fillComposer(with: waiting.text)
        gtk_widget_grab_focus(entryView)
        attachments = waiting.attachments.map {
            PendingAttachment(
                name: $0.filename ?? "attachment", mime: $0.mime, data: $0.data ?? Data())
        }
        renderAttachments()
        if let state = lastState { apply(state: state, rows: lastFullRows) }
    }

    /// ↑ in an empty composer takes back the last thing written — the one being reconsidered.
    /// Only from an empty box: in a half-typed paragraph that key is moving the caret.
    func takeBackLastQueued() -> Bool {
        let display = queueDisplay
        guard
            QueueReading.upArrowOpensLast(composerText: draftText(), display: display),
            let last = display.last
        else { return false }
        editQueued(last.id)
        return true
    }

    /// The rows the server reported, without what this device docked after them. Everything docked
    /// is appended at the end, so the walk stops at the first row that is the server's and a
    /// transcript with nothing docked — nearly every state — is handed back as it is, not copied.
    static func withoutDocked(_ rows: [TranscriptRow]) -> [TranscriptRow] {
        var end = rows.count
        while end > 0, dockedKey(rows[end - 1].key) { end -= 1 }
        return end == rows.count ? rows : Array(rows[..<end])
    }

    /// Whether a row is one this device docks at the end rather than one the server reported.
    static func dockedKey(_ key: String) -> Bool {
        key.hasPrefix("echo:") || key.hasPrefix("pending:") || key.hasPrefix("queued:")
            || key == "queue-paused" || key.hasPrefix("interrupted") || key.hasPrefix("revert:")
            || key.hasPrefix("retry")
    }
}
