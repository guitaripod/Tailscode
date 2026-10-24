import MidgarCore
import TailscodeCore
import CodingAgentKit
import Foundation

extension ChatViewModel {
    /// How this conversation's backend takes a queued message, read each time because a bridge
    /// says whether it keeps a queue only after the first request to it.
    var queueRouting: QueueRouting {
        QueueRouting(capabilities: backend.capabilities, profileID: contextID)
    }

    /// The whole queue as it is drawn: what the server holds for every client of the
    /// conversation, then what this device still holds.
    var queueDisplay: QueueDisplay { queue.display(state, routing: queueRouting) }

    /// Writes a message behind a running turn. Where the server keeps the queue it is handed over
    /// at once, under its own id; elsewhere, or while the server cannot be reached, it waits here.
    func hold(_ send: QueuedSend) {
        queue.append(send)
        onPending?()
        handOverQueue()
    }

    /// Hands the server every message this device holds for it. Asked on every state, so a
    /// message written offline goes the moment the server answers and one left in the store by a
    /// version that held everything locally goes on the first connection.
    func handOverQueue() {
        let routing = queueRouting
        guard queue.holdsServerBound(routing: routing) else { return }
        let queue = queue
        let conversation = conversation
        Task { [weak self] in
            let changed = await queue.flush(through: conversation, routing: routing)
            if changed { self?.onPending?() }
        }
    }

    /// A copy of the queue that another view model on this conversation has already sent from
    /// still draws as waiting until something here tries to drain it, which a running turn never
    /// lets happen. The store is the one account of what is waiting, so a message it no longer
    /// holds is dropped here the moment it is noticed. Ids are compared rather than the messages,
    /// because this runs on every state and a picture's bytes are not worth reading each time.
    func dropQueueSentElsewhere() {
        guard !queue.isEmpty else { return }
        let held = queue.local.items.map(\.id)
        guard queue.adopt() else { return }
        MidgarLog.info(
            "queue adopted from store session=\(session.id) held=\(held.count) stored=\(queue.count)", category: .chat)
        onPending?()
    }

    var queued: [QueueRow] { queueDisplay.rows }

    /// Takes a message out of the queue, wherever it is held. One the server had already started
    /// is said to be sent, and its row goes either way.
    func removeQueued(_ row: QueueRow) {
        queue.cancel(row, through: conversation) { [weak self] outcome in
            Task { @MainActor in self?.report(outcome) }
        }
        onPending?()
    }

    /// Rewrites a waiting message in place, keeping its turn in the order. `ifStarted` runs when
    /// the server had already started the message, so the words that were being written can be
    /// handed back instead of being lost.
    func replaceQueued(
        _ row: QueueRow, text: String, attachments: [PromptAttachment],
        ifStarted: @escaping @MainActor () -> Void
    ) {
        queue.edit(row, text: text, attachments: attachments, through: conversation) {
            [weak self] outcome in
            Task { @MainActor in
                if outcome == .alreadyStarted { ifStarted() }
                self?.report(outcome)
            }
        }
        onPending?()
    }

    /// Lifts the pause a Stop left on the server's queue.
    func resumeQueue() {
        Task { [weak self] in
            guard let self else { return }
            report(await queue.resume(through: conversation))
        }
    }

    func report(_ outcome: QueueOutcome) {
        onPending?()
        if let message = outcome.message { onError?(message) }
    }

    func flushQueue() {
        guard !isBusy, queue.holdsDeviceHead(routing: queueRouting), !queueHeldAfterFailure,
            SendQueueDrain.mayDrain(state)
        else { return }
        let next = queue.takeDeviceHead(routing: queueRouting)
        guard let next else {
            onPending?()
            return
        }
        MidgarLog.info("queue drain session=\(session.id) left=\(queue.count)", category: .chat)
        if case .command(let name, let arguments) = next.kind {
            runNow(
                AgentCommand(name: name, details: "", source: .builtin),
                arguments: arguments.isEmpty ? nil : arguments, model: next.model,
                effort: next.effort)
            return
        }
        deliver(next.text, model: next.model, effort: next.effort, attachments: next.attachments)
    }

    /// A failed send must never drain the queue into the same dead connection.
    /// Flushing on failure sent the next message straight back into the fault,
    /// and each successive failure overwrote the previous one's recovery slot —
    /// message 1 to the composer, message 2 to the pasteboard, message 3 over
    /// that — so one tailnet blip silently destroyed everything the user had
    /// queued. The queue is preserved and drains from the state loop once the
    /// server answers again.
    ///
    /// Where the words end up follows from what else is waiting. With nothing behind it the
    /// message stays exactly where it was written, as its own row, now saying it did not go and
    /// offering to send it again — the words are never moved out from under the reader into a
    /// composer or a pasteboard they have to go looking in. With messages already queued behind
    /// it, it returns to the head of the queue instead, because the order somebody wrote things
    /// in outranks the row they were written on.
    func recoverFailedSend(_ send: QueuedSend, row: UUID, reason: String) {
        defer { retireDeliveredFailures(in: state) }
        if queue.isEmpty {
            pending.mark(id: row, .failed(reason: reason))
            queueHold = nil
        } else {
            heldBaseline = pending.send(id: row)?.baselineUserCount
            pending.remove(id: row)
            queue.requeueAtHead(send)
            queueHeldAfterFailure = true
            queueHold = reason
        }
        onPending?()
    }

    /// A send that errored may still have arrived, and the transcript is the witness that settles
    /// it: a failed row or a held queue head whose words appear as a user message written after
    /// the send began is retired instead of being offered again.
    func retireDeliveredFailures(in state: ConversationState) {
        guard pending.sends.contains(where: \.isFailed) || queueHeldAfterFailure else { return }
        let userTexts = state.messages.filter { $0.role == .user }.map(\.text)
        var changed = false
        for send in pending.retireArrived(userTexts: userTexts) {
            releaseResume(for: send.id)
            changed = true
        }
        if queueHeldAfterFailure, let baseline = heldBaseline, let head = queue.local.items.first,
            !head.isCommand,
            SendArrival.arrived(head.text, baselineUserCount: baseline, userTexts: userTexts)
        {
            queue.removeFirst()
            heldBaseline = nil
            if queue.isEmpty {
                queueHeldAfterFailure = false
                queueHold = nil
            }
            changed = true
        }
        if changed {
            MidgarLog.info("retired delivered failure session=\(session.id)", category: .chat)
            onPending?()
        }
    }

    /// Lets go of a plan that was holding a message for a send that turned out to have arrived, so
    /// the window opening later cannot send the same words a second time.
    private func releaseResume(for row: UUID) {
        guard resume.plan(for: row) != nil else { return }
        resume.drop(row)
        ResumeStore.release(row)
        onResumeChange?(nil)
        stopResumeClockIfIdle()
    }

    /// Sends a failed row again, keeping its place and its identity — with a turn now running it
    /// joins the queue like anything else written during one.
    func retryPending(id: UUID) {
        guard let send = pending.send(id: id), send.isFailed else { return }
        let attachments = send.attachments
        let text = send.text
        guard !isBusy else {
            pending.remove(id: id)
            hold(QueuedSend(text: text, attachments: attachments))
            return
        }
        deliver(
            text, model: send.model ?? selectedModel, effort: send.effort ?? currentEffort,
            attachments: attachments, reusing: id)
    }

    /// Takes a failed row back to be rewritten. The row goes; its words are the caller's now.
    @discardableResult
    func takeBackPending(id: UUID) -> PendingSend? {
        let taken = pending.remove(id: id)
        if taken != nil { onPending?() }
        return taken
    }

    @discardableResult
    func discardPending(id: UUID) -> PendingSend? {
        let dropped = pending.remove(id: id)
        if dropped != nil { onPending?() }
        return dropped
    }
}
