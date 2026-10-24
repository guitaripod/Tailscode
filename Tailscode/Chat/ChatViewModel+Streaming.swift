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
            return
        }
        MidgarLog.info(
            "start fresh vm=\(vmTag) session=\(session.id) queued=\(queue.count) echoes=\(pending.count)", category: .chat)
        streamGeneration += 1
        let generation = streamGeneration
        streamTask = Task { [weak self] in
            guard let self else { return }
            for await state in await self.conversation.states() {
                if state.connection == .live { self.streamRestarts = 0 }
                self.reconcileOptimisticState(with: state)
                if self.state.status == .running, state.status != .running {
                    self.cachedUsage = nil
                    self.refreshTitleFromServer()
                    self.refreshTitleFromServer(delay: .seconds(12))
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
                }
                self.onState?(state)
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
                if state.status != .unknown, !self.isBusy, !awaiting, !self.isBound,
                    self.queue.isEmpty, self.resume.isEmpty
                {
                    self.stop()
                }
            }
            self.handleStreamTermination(generation: generation)
        }
        Task { await loadDefaultModelIfNeeded() }
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
