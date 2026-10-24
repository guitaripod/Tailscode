import AppKit
import os
import CodingAgentKit
import TailscodeCore

extension TranscriptViewController {
    /// How often the chat in front of the reader is marked read as it grows.
    private static let readMarkInterval: TimeInterval = 2.5

    /// A chat being watched is a chat being read, and the servers keep that mark for every other
    /// device: one left unmarked until the reader walks away shows as unread on the phone while its
    /// answer is streaming onto this screen. So whatever arrives in the focused pane of the window
    /// the reader is working in is marked as it arrives — at most every couple of seconds, and
    /// once more when the turn ends.
    private func keepRead(_ state: ConversationState) {
        let running = state.status == .running
        defer { wasRunningWhenMarked = running }
        guard isFocusedPane, NSApp.isActive, view.window?.isKeyWindow == true,
            let sessionID = entry?.session.id
        else { return }
        let now = Date()
        let ended = wasRunningWhenMarked && !running
        guard ended || now.timeIntervalSince(lastReadMark) >= Self.readMarkInterval else { return }
        lastReadMark = now
        SessionSeenStore.markSeen(sessionID)
    }

    func apply(state: ConversationState, rows: [TranscriptRow]) {
        let interval = Pace.signposter.beginInterval("apply")
        defer { Pace.signposter.endInterval("apply", interval) }
        noteHapticEdges(state: state)
        lastState = state
        keepRead(state)
        if let entry, spendReading.note(messages: state.messages, for: entry.session.id) {
            updateStatus()
        }
        onState?(state)
        let turnOpen = state.status == .running
        let turnEnded = context.turnOpen && !turnOpen
        context.turnOpen = turnOpen
        pending.reconcile(userMessages: state.messages.count { $0.role == .user })
        armResumeForWalledTurn(state)
        armRetryWake(state.retry, now: Date())
        if state.revert == nil, revertOperation != .restoring { revertComposerFill = nil }
        showRows(state: state, rows: rows)
        if turnEnded { replaceRows(where: \.hasOpenWork) }
        renderPendingCards(state)
        composer.noteState(state)
        transcriptFill = ContextFill.read(
            messages: state.messages, sessionModel: entry?.session.model,
            sessionProvider: entry?.session.modelProviderID, catalog: composer.catalog)

        updateStatus()
        refreshWorkflowRuns()
        updateTicker(running: state.status == .running || state.compaction?.isRunning == true)
        handoff.observe(state, sendsInFlight: pending.hasInFlight)
        handOverQueue()
        drainQueue()
        calls.conversationChanged()
    }

    /// The transcript drawn from these rows: remembered for the next visit, docked with what this
    /// device holds, windowed to the rows shown, and handed to the diff. Everything `apply` does
    /// about the state around the rows is left to it, so a choice that only changes the rows (a
    /// Megatron opened or closed, its old rows listed) costs the rows and not the conversation.
    func showRows(state: ConversationState, rows: [TranscriptRow]) {
        var confirmed = rows
        if rows.last?.key.hasPrefix("echo:") == true {
            confirmed.removeAll { $0.key.hasPrefix("echo:") }
        }
        lastFullRows = confirmed
        if let entry {
            rememberRows(confirmed, for: SessionPinStore.key(entry.profileID, entry.session.id))
        }
        let shown = docked(echoed(confirmed), state: state)
        let limit = rowLimit
        let windowed = shown.count > limit ? Array(shown.suffix(limit)) : shown
        let hiddenCount = shown.count - windowed.count
        earlierButton.isHidden = hiddenCount <= 0
        if hiddenCount > 0 {
            earlierButton.title = Localized.text(
                "… %@ earlier rows — show more", "\(hiddenCount)")
        }
        if shown.isEmpty {
            cascade.release()
            showPlaceholder(
                state.hasLoadedTranscript
                    ? ChatSuggestion.headline : Localized.text("Loading…"),
                starting: state.hasLoadedTranscript)
        } else {
            applyRows(pacedByCascade(windowed, running: state.status == .running))
            settleStreamedTail(in: windowed)
            paintCascade()
        }
    }

    /// What the transcript draws: the rows the server has confirmed, plus the prompt this device is
    /// still echoing on its behalf.
    ///
    /// The echo never enters `lastFullRows`. It used to be appended to the row list that was then
    /// stored as that memo, and three callers hand the memo straight back in — the chunked fill on
    /// every runloop hop, the widening window, the next send — so each re-entry appended a second
    /// pair while the echo was pending. Nothing de-duplicates rows on the way to the stack and the
    /// diff's key index is first-occurrence-wins, so a cosmetic double prompt became an anchor
    /// resolved against the wrong row and a wrong-slice rebuild. The memo is what the server said;
    /// the echo is added on the way to the screen and nowhere else.
    func echoed(_ rows: [TranscriptRow]) -> [TranscriptRow] {
        guard !pending.isEmpty else { return rows }
        var rows = rows
        let now = Date()
        if !rows.isEmpty {
            rows.append(TranscriptRow(key: "echo:break", kind: .turnBreak))
        }
        for send in pending.sends {
            let plan = resume.plan(for: send.id)
            var shown = send
            if let carried = CarryMark.split(send.text) {
                shown.text = carried.rest
                rows.append(
                    TranscriptRow(
                        key: "echo:\(send.id.uuidString):carried", kind: .carried(carried.reading)))
            }
            rows.append(
                TranscriptRow(
                    key: "echo:\(send.id.uuidString)" + (plan.map { ":wait\($0.attempt)" } ?? ""),
                    kind: .pendingSend(shown, plan, now: now)))
        }
        armCaptionWake(now: now)
        return rows
    }

    private func armCaptionWake(now: Date) {
        captionWake?.cancel()
        captionWake = nil
        let next = pending.sends.compactMap { PendingSendReading.nextCaptionChange($0, now: now) }
            .min()
        guard let next else { return }
        let delay = max(0.05, next.timeIntervalSince(now))
        captionWake = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.redrawPending()
        }
    }

    /// Redraws what this device is holding without rebuilding the transcript from the server's
    /// account of the conversation — the account did not move, and walking it again to add one
    /// row of one's own is why a long conversation used to swallow a send.
    func redrawPending() {
        guard let state = lastState else { return }
        apply(state: state, rows: lastFullRows)
    }

    func actOnPending(_ id: UUID, _ act: PendingSend.Act) {
        guard let send = pending.send(id: id), send.isFailed else { return }
        switch act {
        case .retry:
            sendPrompt(
                send.text, model: send.model, effort: send.effort,
                attachments: send.attachments, reusing: id)
        case .edit:
            let words = QueuedSend(
                text: send.text, model: send.model, effort: send.effort,
                attachments: send.attachments)
            guard composer.adoptForEditing(words) else {
                onToast?(Localized.text("Send or clear what is in the composer first."))
                return
            }
            pending.remove(id: id)
            redrawPending()
        case .discard:
            pending.remove(id: id)
            redrawPending()
        }
    }

    /// A turn the machine cut off is docked at the very end: it is an account of what already
    /// happened, and it belongs below everything that did. Like the echo, it is added on the way
    /// to the screen and never memoized — the server owns it, not this device.
    func docked(_ rows: [TranscriptRow], state: ConversationState) -> [TranscriptRow] {
        var rows = rows
        if let revert = revertCard(state) {
            if !rows.isEmpty { rows.append(TranscriptRow(key: "revert:break", kind: .turnBreak)) }
            rows.append(revert)
        }
        if let cutOff = interruptedCard(state) {
            if !rows.isEmpty {
                rows.append(TranscriptRow(key: "interrupted:break", kind: .turnBreak))
            }
            rows.append(TranscriptRow(key: "interrupted", kind: .interruptedTurn(cutOff)))
        }
        if let card = ProviderRetryReading.read(state.retry) {
            if !rows.isEmpty { rows.append(TranscriptRow(key: "retry:break", kind: .turnBreak)) }
            rows.append(TranscriptRow(key: "retry", kind: .providerRetry(card)))
        }
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
        return rows
    }
}
