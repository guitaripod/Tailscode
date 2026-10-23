import TailscodeCore
import CodingAgentKit
import Foundation

extension ChatViewModel {
    func stop() {
        streamGeneration += 1
        streamTask?.cancel()
        streamTask = nil
        resumeClock?.cancel()
        resumeClock = nil
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
        if isBusy {
            AppLogger.chat.info(
                "send queued session=\(session.id) queue=\(queue.count + 1)")
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
    nonisolated private static var harnessFault: (any Error)? {
        #if DEBUG
            guard let reason = ProcessInfo.processInfo.environment["TAILSCODE_FAIL_SEND"] else {
                return nil
            }
            return HarnessFault(reason: reason)
        #else
            return nil
        #endif
    }

    private struct HarnessFault: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    private struct SendTimeout: LocalizedError {
        var errorDescription: String? {
            String(localized: "The server didn't respond — check your connection.")
        }
    }

    func deliver(
        _ text: String, model: ModelSelection?, effort: String?, attachments: [PromptAttachment],
        reusing row: UUID? = nil
    ) {
        AppLogger.chat.info(
            "send session=\(session.id) chars=\(text.count) attachments=\(attachments.count)")
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
        if let row, pending.restart(id: row, userMessages: userCount) != nil {
            echoID = row
        } else {
            echoID = pending.begin(
                text: text, attachments: attachments, model: model ?? selectedModel,
                effort: effort ?? currentEffort, userMessages: userCount).id
        }
        optimisticThinking = true
        onPending?()
        let activityTitle = AgentSession.isPlaceholderTitle(displayTitle)
            ? AgentSession.provisionalTitle(fromPrompt: text) : displayTitle
        AppActivityController.shared.start(
            sessionID: session.id, sessionTitle: activityTitle, serverName: serverName,
            onPushToken: cardPushSink(title: activityTitle))
        turnSawRunning = false
        cardSettled = false
        let resolvedModel = model ?? selectedModel
        let resolvedEffort = ModelEffort.surviving(
            effort ?? currentEffort, options: reasoningEffortOptions)
        if Ultracode.invokes(text) || resolvedEffort == Ultracode.effortLevel {
            ultracodeInFlight = true
            onModelChange?()
        }
        let payloadBytes = attachments.reduce(0) { $0 + ($1.data?.count ?? 0) }
        let sendBound = 15 + payloadBytes / 50_000
        sendTask = Task {
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { [conversation] in
                        try await Self.harnessDelay()
                        if let fault = Self.harnessFault { throw fault }
                        try await conversation.send(
                            text, model: resolvedModel, reasoningEffort: resolvedEffort,
                            attachments: attachments)
                    }
                    group.addTask {
                        try await Task.sleep(for: .seconds(sendBound))
                        throw SendTimeout()
                    }
                    try await group.next()
                    group.cancelAll()
                }
                // The server has it. Which is a different fact from the turn having started, and
                // the row says so rather than sitting on "sending" until the transcript catches up.
                if generation == sendGeneration, pending.mark(id: echoID, .accepted) {
                    onPending?()
                }
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, generation == sendGeneration else { return }
                if optimisticThinking, !turnSawRunning {
                    optimisticThinking = false
                    settleCard(.noResponse)
                    recoverFailedSend(
                        outgoing, row: echoID,
                        reason: String(localized: "the machine never picked it up"))
                }
            } catch {
                let cancelled = error is CancellationError
                guard generation == sendGeneration else {
                    pending.remove(id: echoID)
                    onPending?()
                    return
                }
                optimisticThinking = false
                if !turnSawRunning {
                    if cancelled {
                        AppActivityController.shared.withdraw(session.id)
                    } else {
                        settleCard(.sendFailed)
                    }
                }
                if cancelled {
                    pending.remove(id: echoID)
                    onPending?()
                } else {
                    AppLogger.chat.error("send failed: \(Self.readable(error))")
                    let reason = Self.readable(error)
                    recoverFailedSend(outgoing, row: echoID, reason: reason)
                    armResume(row: echoID, reason: reason)
                }
            }
        }
    }

    /// Stop always does something: a send still in flight is cancelled
    /// locally, AND the server is asked to abort in case the prompt already
    /// landed; a running turn is aborted server-side.
    func abort() {
        if optimisticThinking, !turnSawRunning {
            sendTask?.cancel()
            optimisticThinking = false
            pending.removeAll()
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
        AppLogger.chat.info("permission \(permission.toolName ?? "?") -> \(decision.rawValue)")
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
        AppLogger.chat.info("question \(question.id) answered")
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
        AppLogger.chat.info("interrupted turn resumed")
        runPress(.pickUp) { [weak self] in
            guard let self else { return }
            try await self.conversation.resumeInterruptedTurn()
        }
    }

    /// Lets the interrupted turn go. Nothing in the transcript changes; only the offer stops.
    func dismissInterruptedTurn() {
        AppLogger.chat.info("interrupted turn dismissed")
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
                AppLogger.chat.error("interrupted turn press failed: \(Self.readable(error))")
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
        AppLogger.chat.info("revert to \(messageID)")
        isReverting = true
        Task {
            do {
                try await conversation.revert(to: messageID)
            } catch {
                AppLogger.chat.error("revert failed: \(Self.readable(error))")
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
        AppLogger.chat.info("revert restore")
        isRestoringRevert = true
        onRevertChange?()
        Task {
            do {
                try await conversation.restoreRevert()
                isRestoringRevert = false
                onRevertRestored?()
            } catch {
                AppLogger.chat.error("revert restore failed: \(Self.readable(error))")
                isRestoringRevert = false
                onRevertChange?()
                onError?(RevertReading.failure(restoring: true, error))
            }
        }
    }

    func rejectQuestion(_ question: QuestionRequest) {
        AppLogger.chat.info("question \(question.id) skipped")
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
