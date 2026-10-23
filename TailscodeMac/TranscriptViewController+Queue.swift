import AppKit
import os
import CodingAgentKit
import TailscodeCore

extension TranscriptViewController {
    /// How this conversation's backend takes a queued message, read each time because a bridge
    /// says whether it keeps a queue only after the first request to it.
    private var queueRouting: QueueRouting {
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
    /// version that held everything locally goes on the first connection.
    func handOverQueue() {
        guard let queue, let conversation else { return }
        let routing = queueRouting
        guard queue.holdsServerBound(routing: routing) else { return }
        Task { [weak self] in
            if await queue.flush(through: conversation, routing: routing) { self?.redrawPending() }
        }
    }

    /// Reports what became of a press on a queued row; a message the server had already started
    /// is said to be sent, and its row is gone either way.
    private func report(_ outcome: QueueOutcome) {
        redrawPending()
        if let message = outcome.message { onToast?(message) }
    }

    /// The words of a message the server started while it was being rewritten go back into the
    /// box, because the rewrite can no longer land and losing them would be the worse outcome.
    private func giveBackEditedWords(_ text: String, attachments: [PromptAttachment]) {
        _ = composer.adoptForEditing(QueuedSend(text: text, attachments: attachments))
    }

    func resumeQueue() {
        guard let queue, let conversation else { return }
        Task { [weak self] in
            guard let self else { return }
            self.report(await queue.resume(through: conversation))
        }
    }

    func sendPrompt(
        _ text: String, model: ModelSelection?, effort: String?,
        attachments: [PromptAttachment], reusing: UUID? = nil, spoken: Bool = false
    ) {
        guard let conversation else { return }
        if !spoken, let id = editingQueued {
            editingQueued = nil
            if let queue, let row = queueDisplay.row(id: id) {
                queue.edit(row, text: text, attachments: attachments, through: conversation) {
                    [weak self] outcome in
                    Task { @MainActor in
                        if outcome == .alreadyStarted {
                            self?.giveBackEditedWords(text, attachments: attachments)
                        }
                        self?.report(outcome)
                    }
                }
            } else {
                giveBackEditedWords(text, attachments: attachments)
                onToast?(QueueReading.alreadySent)
            }
            if let state = lastState { apply(state: state, rows: lastFullRows) }
            return
        }
        let send = QueuedSend(text: text, model: model, effort: effort, attachments: attachments)
        // A prompt written while a turn runs is held here, not handed over: a message you can
        // still change is worth more than a message one place further along.
        if lastState?.status == .running || lastState?.compaction?.isRunning == true
            || handoff.isOpen
        {
            hold(send)
            MacHaptics.shared.play(.send)
            if let state = lastState { apply(state: state, rows: lastFullRows) }
            scrollToBottom()
            return
        }
        MacHaptics.shared.play(.send)
        openHandoff()
        let userMessages = lastState?.messages.count { $0.role == .user } ?? 0
        let row: UUID
        if let reusing, pending.restart(id: reusing, userMessages: userMessages) != nil {
            row = reusing
        } else {
            row = pending.begin(
                text: text, attachments: attachments, model: model, effort: effort,
                userMessages: userMessages).id
        }
        apply(state: lastState ?? ConversationState(), rows: lastFullRows)
        riseFreshCanvas(rowKey: "echo:\(row.uuidString)")
        Task { [weak self] in
            do {
                try await conversation.send(
                    text, model: model, reasoningEffort: effort, attachments: attachments)
                guard let self, self.pending.mark(id: row, .accepted) else { return }
                self.redrawPending()
            } catch {
                MacHaptics.shared.play(.error)
                NSSound.beep()
                self?.markSendFailed(row, error: error)
            }
        }
    }

    /// What a call's voice heard goes out exactly as typed words do — pending ink, queue, marks —
    /// with the model and effort the composer would send with, and leaves the box and a waiting
    /// message that is being rewritten alone.
    private func sendSpoken(_ text: String) -> Bool {
        guard conversation != nil else { return false }
        let choice = composer.promptChoice
        sendPrompt(text, model: choice.model, effort: choice.effort, attachments: [], spoken: true)
        return true
    }

    private var callTitle: String {
        guard let entry else { return "" }
        return entry.session.hasPlaceholderTitle ? Localized.text("New conversation") : entry.session.title
    }

    /// What the call needs of this pane and nothing else: the conversation as it stands, the same
    /// send path a typed message takes, the ordinary stop, and somewhere to say things.
    var callHost: PaneCallController.Host {
        PaneCallController.Host(
            state: { [weak self] in self?.lastState ?? ConversationState() },
            sending: { [weak self] in self?.pending.hasInFlight ?? false },
            title: { [weak self] in self?.callTitle ?? "" },
            deliver: { [weak self] text in self?.sendSpoken(text) ?? false },
            stopTurn: { [weak self] in self?.stopTurn() },
            toast: { [weak self] text in self?.onToast?(text) },
            window: { [weak self] in self?.view.window },
            announce: { [weak self] text in self?.announce(text) })
    }

    #if DEBUG
        /// `TAILSCODE_DRIVE_SEND=<text>` — a send fired from the environment once the chat is open,
        /// so a headless run can watch a prompt rise and be measured with `--tree`.
        func driveSend(_ text: String) {
            sendPrompt(text, model: nil, effort: nil, attachments: [])
        }
    #endif

    /// The moment the turn yields, the next thing written goes. Never while one is running and
    /// never while the composer is holding one open for rewriting: sending it out from under the
    /// person editing it is the one thing the queue exists to prevent.
    func drainQueue() {
        guard let state = lastState,
            SendQueueDrain.mayDrain(state, editing: editingQueued != nil, handoff: handoff),
            let queue, queue.holdsDeviceHead(routing: queueRouting), !draining, ownsQueue
        else { return }
        draining = true
        defer { draining = false }
        guard let next = queue.takeDeviceHead(routing: queueRouting) else { return }
        if next.isCommand {
            runCommand(next)
            return
        }
        sendPrompt(
            next.text, model: next.model, effort: next.effort, attachments: next.attachments)
    }

    func openHandoff() {
        handoff.begin(after: lastState)
        handoffWakeGeneration += 1
        let token = handoffWakeGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + TurnHandoff.patience + 1) { [weak self] in
            guard let self, self.handoffWakeGeneration == token, self.handoff.isOpen,
                let state = self.lastState
            else { return }
            self.apply(state: state, rows: self.lastFullRows)
        }
    }

    /// Opens a waiting message for rewriting. It keeps its place in the queue; only sending
    /// replaces it.
    func editQueued(_ id: String) {
        guard let waiting = queueDisplay.row(id: id), waiting.canEdit else { return }
        guard composer.adoptForEditing(waiting.editable) else {
            onToast?(Localized.text("Send or clear what is in the composer first."))
            return
        }
        editingQueued = id
        if let state = lastState { apply(state: state, rows: lastFullRows) }
    }

    /// ↑ in an empty composer takes the last thing written back — the one being reconsidered.
    func takeBackLastQueued() -> Bool {
        let display = queueDisplay
        guard
            QueueReading.upArrowOpensLast(composerText: composer.currentText, display: display),
            let last = display.last
        else { return false }
        editQueued(last.id)
        return true
    }

    /// A send that never reached the server is not a turn, and a beep under a prompt that still
    /// looks sent is the one outcome this path must not leave behind. The row stays exactly where
    /// the words were written, says it did not go, and offers to send them again — which is a
    /// better answer than pushing them back into a composer the reader has to notice.
    private func markSendFailed(_ row: UUID, error: Error) {
        handoff.end()
        let reason = AgentErrorText.readable(error)
        pending.mark(id: row, .failed(reason: reason))
        armResume(row: row, reason: reason)
        releaseFreshCanvas(animated: false)
        redrawPending()
    }
}
