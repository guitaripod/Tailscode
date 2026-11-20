import MidgarCore
import TailscodeCore
import CodingAgentKit
import Foundation

extension ChatViewModel {
    func stop() {
        streamGeneration += 1
        streamTask?.cancel()
        streamTask = nil
        restingStop?.cancel()
        restingStop = nil
        resumeClock?.cancel()
        resumeClock = nil
        SessionActivity.shared.stoppedWatching(self)
    }

    func resync() {
        guard streamTask != nil || isBound, Date().timeIntervalSince(lastResync) > 1 else { return }
        lastResync = Date()
        guard streamTask != nil else {
            start()
            return
        }
        let conversation = self.conversation
        Task { await conversation.reconnect() }
    }

    func send(
        _ text: String, model: ModelSelection? = nil, effort: String? = nil,
        attachments: [PromptAttachment] = []
    ) {
        if isBusy || !pending.waiting.isEmpty || queueHeldAfterFailure
            || queue.holdsDeviceHead(routing: queueRouting)
        {
            MidgarLog.info(
                "send queued session=\(session.id) queue=\(queue.count + 1) waiting=\(pending.waiting.count)",
                category: .chat)
            hold(QueuedSend(text: text, model: model, effort: effort, attachments: attachments))
            return
        }
        deliver(text, model: model, effort: effort, attachments: attachments)
    }

    /// Re-sends the most recent user prompt (regenerate).
    func regenerate() {
        guard let last = lastSent, !isBusy else { return }
        deliver(last.text, model: last.model, effort: last.effort, attachments: last.attachments)
    }

    var canRegenerate: Bool { lastSent != nil && !isBusy }

    /// Holds a send on the wire for as long as `TAILSCODE_HOLD_SEND` says, so the states a fast
    /// server passes through in a frame can be seen and photographed. A screenshot that has to
    /// win a race is a screenshot nobody takes twice.
    nonisolated private static func harnessDelay() async throws {
        #if DEBUG
            guard
                let seconds = ProcessInfo.processInfo.environment["TAILSCODE_HOLD_SEND"]
                    .flatMap(Double.init)
            else { return }
            try await Task.sleep(for: .seconds(seconds))
        #endif
    }

    /// Makes the send fail, which is the one state a working server will not show you.
    /// `TAILSCODE_OFFLINE_SEND=<n>` makes the first n attempts of this launch fail as an offline
    /// device does, so the row held for the connection can be watched going on its own.
    nonisolated private static func harnessFault() -> (any Error)? {
        #if DEBUG
            let environment = ProcessInfo.processInfo.environment
            if let limit = environment["TAILSCODE_OFFLINE_SEND"].flatMap(Int.init),
                HarnessOffline.take(upTo: limit)
            {
                return AgentError.connection(
                    TransportWords.sentence(for: URLError(.notConnectedToInternet)))
            }
            guard let reason = environment["TAILSCODE_FAIL_SEND"] else { return nil }
            return HarnessFault(reason: reason)
        #else
            return nil
        #endif
    }

    private struct HarnessFault: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    func deliver(
        _ text: String, model: ModelSelection?, effort: String?, attachments: [PromptAttachment],
        reusing row: UUID? = nil, checkFirst: Bool = false
    ) {
        MidgarLog.info(
            "send session=\(session.id) chars=\(text.count) attachments=\(attachments.count) again=\(row != nil)",
            category: .chat)
        queueHeldAfterFailure = false
        queueHold = nil
        sendTask?.cancel()
        sendGeneration += 1
        let generation = sendGeneration
        dismissedFailure = nil
        let outgoing = QueuedSend(
            text: text, model: model, effort: effort, attachments: attachments)
        lastSent = outgoing
        let userCount = state.messages.count { $0.role == .user }
        firstAnswer.sent(promptsBefore: userCount)
        let echoID: UUID
        let earlier = row.flatMap { pending.send(id: $0) }
        let retryingWait = earlier?.isWaiting == true
        if let row, pending.restart(id: row, userMessages: userCount) != nil {
            echoID = row
        } else {
            echoID = pending.begin(
                text: text, attachments: attachments, model: model ?? selectedModel,
                effort: effort ?? currentEffort, userMessages: userCount).id
        }
        optimisticThinking = true
        if streamTask == nil { start() }
        onPending?()
        if !retryingWait { openSendCard(for: text) }
        turnSawRunning = false
        let resolvedModel = model ?? selectedModel
        let resolvedEffort = ModelEffort.surviving(
            effort ?? currentEffort, options: reasoningEffortOptions)
        if Ultracode.invokes(text) || resolvedEffort == Ultracode.effortLevel {
            ultracodeInFlight = true
            onModelChange?()
        }
        let conversation = self.conversation
        let base = SendCourier.through(
            conversation, text: text, model: resolvedModel, effort: resolvedEffort,
            attachments: attachments)
        let courier = SendCourier(
            bound: base.bound,
            post: {
                try await Self.harnessDelay()
                if let fault = Self.harnessFault() { throw fault }
                try await base.post()
            },
            reread: base.reread)
        let sent = pending.send(id: echoID)
        let baseline = min(
            earlier?.baselineUserCount ?? userCount, sent?.baselineUserCount ?? userCount)
        sendTask = Task {
            let outcome = await courier.run(
                text: text, attachments: attachments.count, baselineUserCount: baseline,
                checkFirst: checkFirst)
            if let sent, pending.send(id: echoID) == nil, case .waiting(let reason) = outcome {
                pending.reinstate(sent, as: .waiting(reason: reason))
            } else if let sent, pending.send(id: echoID) == nil, case .failed(let reason) = outcome {
                pending.reinstate(sent, as: .failed(reason: reason))
            }
            guard generation == sendGeneration else {
                landSuperseded(outcome, row: echoID)
                return
            }
            settle(outcome, of: outgoing, row: echoID, retryingWait: retryingWait)
        }
    }

    /// An attempt a newer send overtook still says what became of its own row, and only of its
    /// row: the conversation's busy state, its card and its queue belong to the newer send. A row
    /// the newer send cancelled before an answer came is not left reading "sending" forever, and
    /// never vanishes with its words — it says it did not go and offers them again.
    private func landSuperseded(_ outcome: SendOutcome, row: UUID) {
        guard let send = pending.send(id: row), send.phase == .sending || send.isUnsent else {
            return
        }
        switch outcome {
        case .accepted:
            pending.mark(id: row, .accepted)
        case .arrived:
            pending.remove(id: row)
            HeldSendStore.release(row)
        case .waiting(let reason):
            pending.mark(id: row, .waiting(reason: reason))
            armSendWait(row: row, reason: reason)
        case .failed(let reason):
            pending.mark(id: row, .failed(reason: reason))
            HeldSendStore.release(row)
        case .cancelled:
            guard send.phase == .sending else { return }
            pending.mark(id: row, .failed(reason: ""))
        }
        onPending?()
    }

    /// Opens the conversation's Live Activity for a send, titled the way the chat will be.
    private func openSendCard(for text: String) {
        let activityTitle = AgentSession.isPlaceholderTitle(displayTitle)
            ? AgentSession.provisionalTitle(fromPrompt: text) : displayTitle
        AppActivityController.shared.start(
            sessionID: session.id, sessionTitle: activityTitle, serverName: serverName,
            profileID: contextID, onPushToken: cardPushSink(title: activityTitle),
            serverAlerts: cardServerAlerts)
        cardSettled = false
        cardPulse.reset()
        heldCardBrief = nil
    }

    /// Does the one thing an attempt's outcome asks for. Everything that decided the outcome is
    /// Core's, so the three clients read a send the same way.
    private func settle(
        _ outcome: SendOutcome, of outgoing: QueuedSend, row: UUID, retryingWait: Bool
    ) {
        switch outcome {
        case .accepted, .arrived:
            sendWaits[row]?.clock?.cancel()
            sendWaits[row] = nil
            HeldSendStore.release(row)
            if retryingWait { openSendCard(for: outgoing.text) }
            if outcome == .arrived {
                MidgarLog.info("send arrived despite the wire session=\(session.id)", category: .chat)
                pending.remove(id: row)
            } else {
                pending.mark(id: row, .accepted)
            }
            onPending?()
            handOverQueue()
            armSendWitness()
        case .waiting(let reason):
            MidgarLog.info(
                "send held for the connection session=\(session.id) reason=\(reason)", category: .chat)
            optimisticThinking = false
            if !turnSawRunning { AppActivityController.shared.withdraw(session.id) }
            pending.mark(id: row, .waiting(reason: reason))
            onPending?()
            armSendWait(row: row, reason: reason)
        case .failed(let reason):
            sendWaits[row]?.clock?.cancel()
            sendWaits[row] = nil
            HeldSendStore.release(row)
            optimisticThinking = false
            if !turnSawRunning { settleCard(.sendFailed) }
            MidgarLog.error("send failed: \(reason)", category: .chat)
            recoverFailedSend(outgoing, row: row, reason: reason)
            armResume(row: row, reason: reason)
        case .cancelled:
            optimisticThinking = false
            if !turnSawRunning { AppActivityController.shared.withdraw(session.id) }
            pending.remove(id: row)
            HeldSendStore.release(row)
            onPending?()
        }
    }

    /// Schedules the next attempt at a send held for the connection, on Core's clock, and gives
    /// it up — as a failure that keeps its words — once the window has passed.
    func armSendWait(row: UUID, reason: String) {
        var ticket = sendWaits[row] ?? SendWaitTicket(heldSince: Date())
        ticket.clock?.cancel()
        ticket.attempts += 1
        if SendWait.givesUp(heldSince: ticket.heldSince, now: Date()) {
            sendWaits[row] = nil
            HeldSendStore.release(row)
            pending.mark(id: row, .failed(reason: SendWait.gaveUp(reason)))
            onPending?()
            return
        }
        keepHeld(row, reason: reason, since: ticket.heldSince)
        let delay = SendWait.delay(afterAttempts: ticket.attempts)
        ticket.clock = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.fireSendWait(row)
        }
        sendWaits[row] = ticket
    }

    /// Holds a send behind the turn that is running: it says it goes when the turn ends, goes
    /// first when it does — ahead of anything written after it — and the time spent waiting for
    /// a turn is not time the machine was out of reach, so it does not count against the window.
    func holdBehindTurn(_ row: UUID) {
        guard let send = pending.send(id: row), send.isUnsent else { return }
        var ticket = sendWaits[row] ?? SendWaitTicket(heldSince: Date())
        ticket.clock?.cancel()
        ticket.clock = nil
        sendWaits[row] = ticket
        pending.mark(id: row, .waiting(reason: SendWait.behindTurn))
        keepHeld(row, reason: SendWait.behindTurn, since: ticket.heldSince)
        onPending?()
    }

    /// Writes a held send down so a process ended while it waits — the ordinary end of a process
    /// on a phone left offline — puts it back when the conversation is next opened.
    private func keepHeld(_ row: UUID, reason: String, since: Date) {
        guard let send = pending.send(id: row) else { return }
        HeldSendStore.hold(
            HeldSend(
                send, profileID: contextID, sessionID: session.id, heldSince: since,
                reason: reason))
    }

    /// Puts back what this device was holding for the connection when it last ran, and goes on
    /// trying it on the same clock.
    func restoreHeldSends() {
        let records = HeldSendStore.records(profileID: contextID, sessionID: session.id)
        guard !records.isEmpty else { return }
        let users = state.messages.count { $0.role == .user }
        for record in records {
            guard pending.restore(record, userMessages: users) != nil else { continue }
            sendWaits[record.id] = SendWaitTicket(heldSince: record.heldSince)
            armSendWait(row: record.id, reason: record.reason)
        }
        MidgarLog.info(
            "held sends restored session=\(session.id) count=\(records.count)", category: .chat)
        onPending?()
    }

    /// Tries a held send again — the oldest first, so words written offline arrive in the order
    /// they were written, and never into a turn that has started meanwhile.
    func fireSendWait(_ row: UUID) {
        guard let send = pending.send(id: row), send.isWaiting else {
            sendWaits[row]?.clock?.cancel()
            sendWaits[row] = nil
            return
        }
        guard pending.waiting.first?.id == row else {
            armSendWait(row: row, reason: Self.waitingReason(send))
            return
        }
        guard !isBusy else {
            holdBehindTurn(row)
            return
        }
        deliver(
            send.text, model: send.model ?? selectedModel, effort: send.effort ?? currentEffort,
            attachments: send.attachments, reusing: row, checkFirst: true)
    }

    /// Tries the oldest held send now rather than on its clock: the stream came back, or the app
    /// came to the front, which is when a network that was gone usually is not any more.
    func nudgeSendWaits() {
        guard let oldest = pending.waiting.first, !isBusy else { return }
        MidgarLog.info("send wait nudged session=\(session.id)", category: .chat)
        fireSendWait(oldest.id)
    }

    private static func waitingReason(_ send: PendingSend) -> String {
        if case .waiting(let reason) = send.phase { return reason }
        return ""
    }

    /// A send the server accepted that no stream has shown arriving means this device lost sight
    /// of the conversation, never that the machine lost the message: the server already said it
    /// has it. Whatever stream is listening is redialled, and the server's state says what became
    /// of the turn from there.
    private func armSendWitness() {
        sendWitness?.cancel()
        sendWitness = Task { [weak self] in
            try? await Task.sleep(for: .seconds(SendWitness.after))
            guard !Task.isCancelled, let self else { return }
            guard !self.pending.unwitnessed(now: Date()).isEmpty else { return }
            self.reviveWitness()
        }
    }

    private func reviveWitness() {
        MidgarLog.info(
            "send unseen for \(Int(SendWitness.after)) s session=\(session.id) stream=\(streamTask != nil)",
            category: .chat)
        guard streamTask != nil else {
            start()
            return
        }
        let conversation = self.conversation
        Task { await conversation.reconnect() }
    }

    /// Stop always does something: a send still in flight is cancelled
    /// locally, AND the server is asked to abort in case the prompt already
    /// landed; a running turn is aborted server-side.
    func abort() {
        if optimisticThinking, !turnSawRunning {
            sendTask?.cancel()
            optimisticThinking = false
            pending.removeInFlight()
            AppActivityController.shared.withdraw(session.id)
            onPending?()
            if canAbort { Task { try? await conversation.cancelCurrentTurn() } }
            return
        }
        guard canAbort else { return }
        Task {
            do {
                try await conversation.cancelCurrentTurn()
            } catch {
                onError?(Self.readable(error))
            }
        }
    }

    func refresh() {
        Task { try? await conversation.refresh() }
    }

    /// An approval answered from outside the chat — a notification button — through the chat's own
    /// conversation, so the card settles here in the same breath as the server hears it, and a
    /// request the chat has already settled is not asked twice.
    func answerFromNotice(
        _ permission: PermissionRequest, decision: PermissionDecision
    ) async throws -> PermissionAnswer.Outcome {
        try await PermissionAnswer.answer(
            permission, decision: decision, through: conversation, backend: nil)
    }

    func respond(to permission: PermissionRequest, decision: PermissionDecision) {
        MidgarLog.info(
            "permission \(permission.toolName ?? "?") -> \(decision.rawValue)", category: .chat)
        Task {
            do {
                try await conversation.respond(to: permission, decision: decision)
            } catch {
                onError?(Self.readable(error))
            }
        }
    }

    /// An agent that takes its answer as an ordinary message is answered through
    /// the composer's own path: the reply queues behind a turn already running
    /// (which a direct call would be refused for), echoes locally, and reads back
    /// as what the user actually said.
    func answerQuestion(_ question: QuestionRequest, answers: [[String]]) {
        MidgarLog.info("question \(question.id) answered", category: .chat)
        if backend.capabilities.answersQuestionsByMessage {
            let text = question.answerMessage(answers)
            guard !text.isEmpty else { return }
            send(text, model: selectedModel, effort: currentEffort)
            Task { await conversation.markAnswered(question) }
            return
        }
        Task {
            do {
                try await conversation.answer(question, answers: answers)
            } catch {
                onQuestionFailed?(question.id)
                onError?(Self.readable(error))
            }
        }
    }

    /// Continues a turn the server's machine cut off. The work happens on that machine — this is
    /// not a resend — so the card comes down when the server says it took it, not on the press.
    ///
    /// A refusal is never a dead end: the Kit re-reads the record before it rethrows one, so the
    /// card corrects itself or comes down, and what is reported is the server's own sentence about
    /// why rather than a substitute this client wrote.
    func resumeInterruptedTurn() {
        MidgarLog.info("interrupted turn resumed", category: .chat)
        runPress(.pickUp) { [weak self] in
            guard let self else { return }
            try await self.conversation.resumeInterruptedTurn()
        }
    }

    /// Lets the interrupted turn go. Nothing in the transcript changes; only the offer stops.
    func dismissInterruptedTurn() {
        MidgarLog.info("interrupted turn dismissed", category: .chat)
        runPress(.letGo) { [weak self] in
            guard let self else { return }
            try await self.conversation.dismissInterruptedTurn()
        }
    }

    /// Runs one press on the cut-off card and keeps this device's account of it honest from the
    /// tap to the answer.
    ///
    /// The press is recorded before the request leaves so every redraw in between draws a card
    /// that says what was asked of it, and it is dropped the instant anything comes back — an
    /// acknowledgement that outlives its request is a button stuck mid-press. A failure is put
    /// through Core, which is the only thing that decides whether the server refused the press or
    /// the machine simply could not be reached.
    private func runPress(
        _ press: InterruptedTurnPress, _ work: @escaping () async throws -> Void
    ) {
        interruptionPress = press
        onInterruptionChange?()
        Task {
            do {
                try await work()
                finishInterruptionPress(nil)
            } catch {
                MidgarLog.error(
                    "interrupted turn press failed: \(Self.readable(error))", category: .chat)
                finishInterruptionPress(InterruptedTurnReading.refusal(for: error))
            }
        }
    }

    private func finishInterruptionPress(_ refusal: String?) {
        interruptionPress = nil
        onInterruptionChange?()
        if let refusal { onInterruptionRefused?(refusal) }
    }

    /// Winds the conversation back to `messageID`. The Kit stops a running turn first and asks a
    /// busy server again on its own, so this is one call rather than a stop followed by a retry;
    /// the banner appears through the ordinary state stream once the server has done it.
    func revert(to messageID: String) {
        guard !isReverting else { return }
        MidgarLog.info("revert to \(messageID)", category: .chat)
        isReverting = true
        Task {
            do {
                try await conversation.revert(to: messageID)
            } catch {
                MidgarLog.error("revert failed: \(Self.readable(error))", category: .chat)
                onError?(RevertReading.failure(restoring: false, error))
            }
            isReverting = false
        }
    }

    /// Undoes the standing revert. The button renames itself and refuses a second press the moment
    /// this is called; a failure leaves the revert standing and reports why, a success is read off
    /// the state stream like any other change the server made.
    func restoreRevert() {
        guard !isRestoringRevert else { return }
        MidgarLog.info("revert restore", category: .chat)
        isRestoringRevert = true
        onRevertChange?()
        Task {
            do {
                try await conversation.restoreRevert()
                isRestoringRevert = false
                onRevertRestored?()
            } catch {
                MidgarLog.error("revert restore failed: \(Self.readable(error))", category: .chat)
                isRestoringRevert = false
                onRevertChange?()
                onError?(RevertReading.failure(restoring: true, error))
            }
        }
    }

    func rejectQuestion(_ question: QuestionRequest) {
        MidgarLog.info("question \(question.id) skipped", category: .chat)
        Task {
            do {
                try await conversation.reject(question)
            } catch {
                onQuestionFailed?(question.id)
                onError?(Self.readable(error))
            }
        }
    }
}

#if DEBUG
    /// How many sends this launch has failed on purpose for `TAILSCODE_OFFLINE_SEND`.
    enum HarnessOffline {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var taken = 0

        static func take(upTo limit: Int) -> Bool {
            lock.withLock {
                guard taken < limit else { return false }
                taken += 1
                return true
            }
        }
    }
#endif

