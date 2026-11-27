import MidgarCore
import TailscodeCore
import CodingAgentKit
import Foundation

extension ChatViewModel {
    /// Reusing a still-running view model (reopened while a turn is in flight)
    /// must not spawn a second `states()` loop — it would double every render
    /// and leak the old task. Re-emit the current state so the freshly bound
    /// view controller paints immediately, including any queued messages.
    func start() {
        let vmTag = String(UInt(bitPattern: ObjectIdentifier(self).hashValue) & 0xffff, radix: 16)
        guard streamTask == nil else {
            MidgarLog.info(
                "start reuse vm=\(vmTag) session=\(session.id) queued=\(queue.count) echoes=\(pending.count)", category: .chat)
            onState?(state)
            readAgainIfTheHeldTranscriptIsOld()
            return
        }
        MidgarLog.info(
            "start fresh vm=\(vmTag) session=\(session.id) queued=\(queue.count) echoes=\(pending.count)", category: .chat)
        streamGeneration += 1
        let generation = streamGeneration
        streamTask = Task { [weak self] in
            guard let self else { return }
            for await state in await self.conversation.states() {
                guard generation == self.streamGeneration else { break }
                #if DEBUG
                    let probe = LiveLoadProbe.begin()
                    defer { LiveLoadProbe.end(probe, session: self.session.id, bound: self.isBound) }
                #endif
                if state.connection == .live { self.streamRestarts = 0 }
                self.reconcileOptimisticState(with: state)
                if self.state.status == .running, state.status != .running {
                    if TurnSuccessReading.succeeded(state) {
                        ReviewPromptCoordinator.shared.turnCompleted()
                        ProInvitation.recordSuccessfulTurn()
                        if !ConnectionController.shared.isDemoMode { MidgarSignals.noteValue() }
                    }
                    self.cachedUsage = nil
                    self.refreshTitleFromServer()
                    self.refreshTitleFromServer(delay: .seconds(12))
                    self.refreshTitleFromServer(delay: .seconds(40))
                    if self.ultracodeInFlight {
                        self.ultracodeInFlight = false
                        self.onModelChange?()
                    }
                }
                if Ultracode.turnInvoked(state), !self.ultracodeInFlight {
                    self.ultracodeInFlight = true
                    self.onModelChange?()
                }
                let displayedBefore = (self.displayedModel, self.displayedEffort)
                let cameBack = state.connection == .live && self.state.connection != .live
                self.noteTranscriptMovement(state)
                self.state = state
                if let waited = self.firstAnswer.answered(state) {
                    MidgarLog.info(
                        "journey firstAnswer session=\(self.session.id) ms=\(waited)", category: .performance)
                }
                if (self.displayedModel, self.displayedEffort) != displayedBefore {
                    self.onModelChange?()
                }
                if state.status == .running {
                    self.queueHeldAfterFailure = false
                    self.queueHold = nil
                    self.queueHoldSince = nil
                    self.queueHoldAttempts = 0
                    self.queueHoldClock?.cancel()
                }
                self.onState?(state)
                if state.hasLoadedTranscript, !self.heldSendsRestored {
                    self.heldSendsRestored = true
                    self.restoreHeldSends()
                }
                if cameBack || (state.status != .running && !self.pending.waiting.isEmpty) {
                    self.nudgeSendWaits()
                }
                if self.queueHeldAfterFailure, state.connection == .live { self.releaseQueueHold() }
                let awaiting =
                    state.pendingPermissions.first != nil || state.pendingQuestions.first != nil
                SessionActivity.shared.update(
                    sessionID: self.session.id, profileID: self.contextID,
                    title: self.alertTitle,
                    presence: self.presence(for: state),
                    keepAlive: self)
                self.handOverQueue()
                if state.status != .running { self.flushQueue() }
                self.syncLiveActivity(with: state)
                if self.canRest(awaiting: awaiting) {
                    self.stopOnceRested()
                } else {
                    self.restingStop?.cancel()
                    self.restingStop = nil
                }
            }
            self.handleStreamTermination(generation: generation)
        }
        Task { await loadDefaultModelIfNeeded() }
    }

    /// A chat opened onto a conversation this process is already streaming is shown what the
    /// stream last said and nothing else. A message written while that stream was quiet lives in
    /// the server's transcript and nowhere this device holds — opencode's event bus belongs to one
    /// process, so a prompt sent from another process on that machine never reaches a socket here —
    /// and the one road that finds it is a refetch. Leaving the chat and coming back takes that
    /// road; opening it has to take it too, or the message is missing until the record follower's
    /// next tick. `ChatOpenRead` decides whether the held transcript is old enough to be worth
    /// asking about; what moved a moment ago — the warm conversation a press starts, a turn already
    /// streaming onto the page — is current and is not asked for twice.
    private func readAgainIfTheHeldTranscriptIsOld() {
        let now = Date()
        guard
            ChatOpenRead.needed(
                hasTranscript: state.hasLoadedTranscript,
                changedAt: transcriptChangedAt?.timeIntervalSinceReferenceDate,
                lastAsked: lastOpenReadAt?.timeIntervalSinceReferenceDate,
                now: now.timeIntervalSinceReferenceDate)
        else { return }
        lastOpenReadAt = now
        let age = transcriptChangedAt.map { now.timeIntervalSince($0) } ?? -1
        MidgarLog.info(
            "open read session=\(session.id) age=\(age >= 0 ? Int(age) : -1)s", category: .chat)
        refresh()
    }

    /// Whether the transcript this view model holds moved — a message arriving, or more of one
    /// being written — rather than only a status, a queue or a connection. A cheap digest, so a
    /// streamed token costs a handful of comparisons and nothing proportional to the conversation.
    private func noteTranscriptMovement(_ state: ConversationState) {
        var hasher = Hasher()
        hasher.combine(state.messages.count)
        if let last = state.messages.last {
            hasher.combine(last.id)
            hasher.combine(last.completedAt)
            hasher.combine(last.parts.count)
            if let part = last.parts.last {
                hasher.combine(part.text?.utf8.count ?? 0)
                if case .tool(let call) = part.kind {
                    hasher.combine(call.status)
                    hasher.combine(call.output?.utf8.count ?? 0)
                }
            }
        }
        let signature = hasher.finalize()
        guard signature != transcriptSignature else { return }
        transcriptSignature = signature
        guard state.hasLoadedTranscript else { return }
        transcriptChangedAt = Date()
    }

    /// Whether a view model nobody has on screen has nothing left to watch: the turn is over,
    /// nothing waits on the person, and nothing this device holds is still to go.
    private func canRest(awaiting: Bool) -> Bool {
        state.status != .unknown && !isBusy && !awaiting && !isBound && queue.isEmpty
            && resume.isEmpty && pending.waiting.isEmpty
    }

    /// Lets the conversation go once it has stayed at rest for the settle grace. A turn that ends
    /// is often followed at once by the next — a prompt the server held in its queue, a send from
    /// the desk — and that turn takes the card back; a card taken back with nothing left to watch
    /// it would say it is working long after the work had ended.
    private func stopOnceRested() {
        guard restingStop == nil else { return }
        let generation = streamGeneration
        restingStop = Task { [weak self] in
            try? await Task.sleep(for: .seconds(WorkSettle.grace))
            guard let self, !Task.isCancelled, generation == self.streamGeneration else { return }
            self.restingStop = nil
            let awaiting =
                self.state.pendingPermissions.first != nil || self.state.pendingQuestions.first != nil
            guard self.canRest(awaiting: awaiting) else { return }
            self.stop()
        }
    }

    /// What this device can honestly say about the turn: the reading every client shares, raised
    /// only by a send whose echo is still local. A conversation that has just been handed over
    /// reads as unsettled and settles nothing; one this device has just sent to is running here
    /// whatever the server has got around to saying.
    private func presence(for state: ConversationState) -> SessionPresence {
        let reading = SessionPresence.reading(state, step: nil)
        let sending = SessionPresence.running(nil)
        guard optimisticThinking, reading.rank < sending.rank else { return reading }
        return sending
    }

    /// Runs when the states() stream ends on its own — a terminal failure or
    /// reconnect exhaustion, not a `stop()`/`resync()` (those bump the
    /// generation first). The dead task must not masquerade as a live
    /// subscription: clearing it lets `resync`/reopen build a fresh stream,
    /// and releasing the activity entry stops Home showing a phantom live
    /// session for a turn nothing on this device can observe anymore.
    private func handleStreamTermination(generation: Int) {
        guard generation == streamGeneration, streamTask != nil else { return }
        MidgarLog.info("stream terminated for \(session.id); releasing busy state", category: .chat)
        streamTask = nil
        SessionActivity.shared.markUnobserved(sessionID: session.id)
        onState?(state)
        scheduleStreamRestart()
    }

    private func scheduleStreamRestart() {
        guard isBound else { return }
        streamRestarts += 1
        let delay = min(30.0, pow(2.0, Double(min(streamRestarts, 5))))
        let generation = streamGeneration
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, self.isBound, self.streamTask == nil,
                generation == self.streamGeneration
            else { return }
            self.start()
        }
    }
}
