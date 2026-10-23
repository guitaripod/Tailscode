import AppKit
import os
import CodingAgentKit
import TailscodeCore

extension TranscriptViewController {
    /// The cut-off turn's card as this device must draw it: the server's record wearing a press it
    /// has not answered yet. The press is dropped the moment the record itself says anything, which
    /// is what stops a button sitting in flight after the thing it asked for has happened.
    func interruptedCard(_ state: ConversationState) -> InterruptedTurn? {
        guard let card = InterruptedTurnReading.read(state.interruption) else { return nil }
        guard let press = interruptionPress, card.acceptsPress else { return card }
        return InterruptedTurnReading.pressed(card, press)
    }

    /// Runs one press on the cut-off card and keeps this device's account of it honest from the
    /// click to the answer.
    ///
    /// The card is repainted before the request leaves, because a card that looks exactly as it did
    /// tells the person their click did nothing. A refusal is never a dead end: the Kit re-reads the
    /// record before it rethrows one, so the card corrects itself or comes down in the same breath
    /// as the sentence explaining why — and the sentence is the server's own, because it knows why
    /// and this pane does not.
    func pressInterruption(_ press: InterruptedTurnPress) {
        guard let conversation, interruptionPress == nil else { return }
        interruptionPress = press
        redrawInterruption()
        Task { [weak self] in
            do {
                switch press {
                case .pickUp: try await conversation.resumeInterruptedTurn()
                case .letGo: try await conversation.dismissInterruptedTurn()
                }
                self?.settleInterruptionPress(nil)
            } catch {
                self?.settleInterruptionPress(InterruptedTurnReading.refusal(for: error))
            }
        }
    }

    private func settleInterruptionPress(_ refusal: String?) {
        interruptionPress = nil
        redrawInterruption()
        if let refusal { onToast?(refusal) }
    }

    /// Repaints for news this device made rather than the server's — a press taken on the cut-off
    /// card, or the refusal that corrected it. The server's account did not move, so nothing is
    /// refetched and only the docked card is rebuilt.
    private func redrawInterruption() {
        guard let state = lastState else { return }
        apply(state: state, rows: lastFullRows)
    }

    /// Which side of winding a conversation back this device is waiting on an answer for. Both
    /// share one flag rather than two booleans, because a second press must be refused whichever
    /// one is already running: the server will not take a new boundary while it is still acting
    /// on the last one.
    enum RevertOperation { case reverting, restoring }

    /// The card standing where the set-aside messages were: the placeholder from the moment Undo
    /// was pressed until the server answers, then the banner itself for as long as the revert
    /// stands. Never both, and never a banner built from a boundary this device is still asking
    /// the server to move away from.
    func revertCard(_ state: ConversationState) -> TranscriptRow? {
        if revertOperation == .reverting {
            return TranscriptRow(key: "revert:pending", kind: .revertPending)
        }
        guard let banner = RevertReading.read(state.revert, setAside: state.revertedMessages)
        else { return nil }
        return TranscriptRow(
            key: "revert", kind: .revertBanner(banner, restoring: revertOperation == .restoring))
    }

    /// The confirmation `RevertReading` demands before anything happens, in the client's own
    /// destructive-sheet idiom.
    func presentUndoConfirmation(_ messageID: String) {
        guard let state = lastState else { return }
        MacDialogs.confirm(
            on: view.window, title: RevertReading.confirmTitle,
            body: RevertReading.confirmMessage(stopping: state.status == .running),
            confirmLabel: RevertReading.confirmAction
        ) { [weak self] in
            self?.performUndo(messageID)
        }
    }

    /// Winds the conversation back to `messageID`. The conversation this device asked is captured
    /// once here and used again when the answer lands, because a chat switch mid-flight must
    /// never let a stale reply repaint whatever chat is on screen by then: `settleRevert` checks
    /// it is still the open conversation before touching anything.
    private func performUndo(_ messageID: String) {
        guard let conversation, revertOperation == nil else { return }
        revertOperation = .reverting
        redrawRevert()
        Task { [weak self] in
            do {
                try await conversation.revert(to: messageID)
                let fresh = await conversation.state
                self?.settleRevert(conversation, fresh: fresh, failure: nil)
            } catch {
                self?.settleRevert(
                    conversation, fresh: nil,
                    failure: RevertReading.failure(restoring: false, error))
            }
        }
    }

    private func settleRevert(
        _ conversation: AgentConversation, fresh: ConversationState?, failure: String?
    ) {
        guard self.conversation === conversation else { return }
        revertOperation = nil
        if let fresh {
            revertComposerFill = nil
            if let prompt = RevertReading.prompt(in: fresh.revertedMessages),
                composer.fillIfEmpty(prompt)
            {
                revertComposerFill = prompt
            }
            applyFreshState(fresh)
        } else {
            redrawRevert()
        }
        if let failure { onToast?(failure) }
    }

    /// Undoes the standing revert. Guarded and captured exactly as ``performUndo`` is, for the
    /// same reason: the press outlives whatever chat happens to be open when the server answers.
    func performRestore() {
        guard let conversation, revertOperation == nil else { return }
        revertOperation = .restoring
        redrawRevert()
        Task { [weak self] in
            do {
                try await conversation.restoreRevert()
                let fresh = await conversation.state
                self?.settleRestore(conversation, fresh: fresh, failure: nil)
            } catch {
                self?.settleRestore(
                    conversation, fresh: nil,
                    failure: RevertReading.failure(restoring: true, error))
            }
        }
    }

    private func settleRestore(
        _ conversation: AgentConversation, fresh: ConversationState?, failure: String?
    ) {
        guard self.conversation === conversation else { return }
        let offered = revertComposerFill
        revertOperation = nil
        if failure == nil {
            revertComposerFill = nil
            if let offered { composer.clearIfUnchanged(from: offered) }
        }
        if let fresh { applyFreshState(fresh) } else { redrawRevert() }
        if let failure { onToast?(failure) }
    }

    /// Rebuilds the transcript from a snapshot fetched straight off the actor rather than waited
    /// for on the stream, so a revert or its undo is on screen the instant the server confirms it
    /// instead of on whatever runloop hop the subscription next happens to wake on.
    private func applyFreshState(_ fresh: ConversationState) {
        let tail = rowTailMessages
        let messages =
            fresh.messages.count > tail ? Array(fresh.messages.suffix(tail)) : fresh.messages
        apply(
            state: fresh, rows: buildRows(messages, state: fresh))
    }

    /// Repaints for a revert-family press this device made. Nothing the server said has changed,
    /// so only the docked card is rebuilt.
    private func redrawRevert() {
        guard let state = lastState else { return }
        apply(state: state, rows: lastFullRows)
    }

    func armRetryWake(_ retry: TurnRetry?, now: Date) {
        retryWake?.cancel()
        retryWake = nil
        guard let retry, let next = ProviderRetryReading.nextChange(retry, now: now) else {
            return
        }
        let delay = max(0.05, next.timeIntervalSince(now))
        retryWake = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.redrawRetry()
        }
    }

    private func redrawRetry() {
        guard let state = lastState else { return }
        apply(state: state, rows: lastFullRows)
    }
}
