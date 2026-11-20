import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

extension ChatPane {
    /// The baseline a send written before the transcript loaded carries until it has: no count of
    /// the server's account can pass it, so it is never retired by a transcript nobody has read.
    static let unloadedBaseline = Int.max / 2

    var liveKey: LiveKey? { entry.map(LiveKey.init) }

    /// Whether the transcript's last turn is open as this pane reads it right now.
    var turnOpenNow: Bool { pending.turnIsOpen(running: lastState?.status == .running) }

    /// The rows of a state built here rather than through the feed, with the turn read as this
    /// pane reads it: a prompt not yet echoed leaves the turn before it closed.
    func paneRows(for state: ConversationState) -> [TranscriptRow] {
        rowBuilder.rows(
            state: state,
            turnOpen: PendingSendLedger.turnIsOpen(
                running: state.status == .running, messages: state.messages,
                echoBaseline: pending.echoBaseline))
    }

    /// The rows this device docks at the end for each send the server's account does not hold
    /// yet (`TranscriptRow.echoRows`), with the pictures decoded from the bytes still in memory.
    func dockPending(_ rows: inout [TranscriptRow]) {
        guard !pending.isEmpty else { return }
        if !rows.isEmpty {
            rows.append(TranscriptRow(key: "pending:break", kind: .turnBreak))
        }
        for send in pending.sends {
            for (index, picture) in send.pictures.enumerated() {
                seedEchoPicture(picture, key: TranscriptRow.echoPictureKey(send.id, index))
            }
            rows.append(contentsOf: TranscriptRow.echoRows(send, plan: resume.plan(for: send.id)))
        }
    }

    /// Decodes a picture the person just sent from the bytes still in memory, off the main thread,
    /// so the echo shows it before the server has been asked for anything.
    func seedEchoPicture(_ picture: PromptAttachment, key: String) {
        let store = PictureStore.shared
        guard let data = picture.data, !store.has(key),
            store.claim(key, urgent: true, at: ProcessInfo.processInfo.systemUptime)
        else { return }
        Task.detached(priority: .userInitiated) {
            let preview = await ImageDecodeGate.shared.run(urgent: true) {
                PictureDecode.preview(of: data)
            }
            Gtk.onMain {
                if let preview, let preview {
                    store.store(preview, forKey: key)
                } else {
                    store.fail(key, at: ProcessInfo.processInfo.systemUptime)
                }
            }
        }
    }

    /// The server's account of a send this device drew from memory has arrived: its pictures are
    /// the same pictures, so the server's rows take the previews and the bytes the echo already
    /// had instead of fetching them, and the swap shows the same picture at the same size.
    func handPicturesOver(_ retired: [PendingSend], in messages: [ChatMessage]) {
        let sent = retired.filter { !$0.pictures.isEmpty }
        guard !sent.isEmpty else { return }
        let users = messages.filter { $0.role == .user }
        let store = PictureStore.shared
        for send in sent {
            guard send.baselineUserCount < users.count else { continue }
            let message = users[send.baselineUserCount]
            let files = message.parts.compactMap { part -> (String, FileReference)? in
                guard case .file(let reference) = part.kind,
                    (reference.mime ?? "").hasPrefix("image/")
                else { return nil }
                return ("\(message.id):\(part.id)", reference)
            }
            for (index, (key, reference)) in zip(send.pictures.indices, files) {
                let picture = send.pictures[index]
                if let data = picture.data, !ImageCache.exists(reference) {
                    Task.detached(priority: .utility) { ImageCache.save(data, for: reference) }
                }
                let echoKey = TranscriptRow.echoPictureKey(send.id, index)
                let bits = store.texture(forKey: echoKey)
                guard bits != 0, !store.has(key),
                    let texture = UnsafeMutableRawPointer(bitPattern: bits),
                    let size = store.dimensions(forKey: echoKey)
                else { continue }
                g_object_ref(texture)
                store.store(DecodedPreview(bits: bits, width: size.0, height: size.1), forKey: key)
            }
        }
    }

    /// Whether a send must keep its place rather than go now: a turn is running or compacting, or
    /// the last send has not shown its turn yet.
    var sendsBusy: Bool {
        lastState?.status == .running || lastState?.compaction?.isRunning == true || handoff.isOpen
    }

    /// Everything a new state says about the sends this pane holds, before the rows are drawn:
    /// the ones the transcript now carries are retired (and their pictures handed to the server's
    /// rows), a held or failed one whose words turn up is let go with any wait it was under, a
    /// send written before the transcript loaded goes now that it has, the sends held across a quit
    /// come back once there is a transcript to count them against, and a stream that has just come
    /// back live, or a turn that has just ended, is the moment every held send is tried.
    func settleSends(with state: ConversationState) {
        let before = pending.sends
        pending.reconcile(userMessages: userTally.users(in: state.messages))
        let counted = before.filter { sent in !pending.sends.contains { $0.id == sent.id } }
        let arrived = pending.retireArrived(in: state.messages)
        for send in arrived {
            sendTasks.removeValue(forKey: send.id)?.task.cancel()
        }
        let retired = counted + arrived
        for send in retired {
            sendWaits[send.id] = nil
            HeldSends.release(send.id)
            if resume.plan(for: send.id) != nil {
                resume.drop(send.id)
                ResumeStore.release(send.id)
            }
        }
        if !retired.isEmpty {
            handPicturesOver(retired, in: state.messages)
            if !arrived.isEmpty {
                AppLog.write(.session, "retired \(arrived.count) send(s) the transcript already holds")
            }
        }
        var firstLoad = false
        if state.hasLoadedTranscript, !sendsSawLoad {
            sendsSawLoad = true
            firstLoad = true
            restoreHeldSends(state)
        }
        feed.update { $0.echoBaseline = pending.echoBaseline }
        if let liveKey { host?.live.edges.noteUnsent(liveKey, pending.hasUnsent) }
        if state.hasLoadedTranscript { postSendsAwaitingLoad(state) }
        let cameBack = state.connection == .live && lastConnection != .live && lastConnection != nil
        lastConnection = state.connection
        let idleNow = state.hasLoadedTranscript && !sendsBusy
        let behind = pending.waiting.contains {
            sendTasks[$0.id] == nil && $0.phase == .waiting(reason: SendWait.behindTurn)
        }
        if cameBack || firstLoad || (idleNow && behind),
            pending.waiting.contains(where: { sendTasks[$0.id] == nil })
        {
            Gtk.onMain { [weak self] in self?.retryWaitingNow() }
        }
        if !arrived.isEmpty, !pending.hasUnsent {
            Gtk.onMain { [weak self] in
                guard let self, let state = self.lastState else { return }
                self.drainHeldQueue(state)
            }
        }
    }

    /// Puts back what this chat was holding for the connection when the app last ran, now that
    /// there is a transcript to count it against, and tries it.
    private func restoreHeldSends(_ state: ConversationState) {
        guard let liveKey else { return }
        let clocks = HeldSends.restore(liveKey, into: &pending, messages: state.messages)
        guard !clocks.isEmpty else { return }
        for (id, clock) in clocks where sendWaits[id] == nil { sendWaits[id] = clock }
        for send in pending.retireArrived(in: state.messages) {
            sendWaits[send.id] = nil
            HeldSends.release(send.id)
        }
        AppLog.write(.session, "put back \(clocks.count) send(s) held across a quit")
    }

    /// Sends written while the transcript was still loading are drawn at once and posted only once
    /// it has, so the count their echo is reconciled against is a count of something.
    func postSendsAwaitingLoad(_ state: ConversationState) {
        let waiting = pending.sends.filter {
            $0.isInFlight && $0.baselineUserCount == Self.unloadedBaseline && sendTasks[$0.id] == nil
        }
        guard !waiting.isEmpty, let conversation else { return }
        let users = userTally.users(in: state.messages)
        for send in waiting {
            pending.restart(id: send.id, userMessages: users)
            post(send.id, through: conversation, checkFirst: false)
        }
        feed.update { $0.echoBaseline = pending.echoBaseline }
    }

    /// Writes a message into the conversation: drawn at once from memory, risen to the top, and
    /// handed to Core's courier, whose answer decides what the row becomes.
    func deliver(
        _ send: QueuedSend, through conversation: AgentConversation, reusing row: UUID? = nil,
        checkFirst: Bool = false
    ) {
        if send.isCommand {
            openHandoff()
            runCommand(send, through: conversation)
            return
        }
        let loaded = lastState?.hasLoadedTranscript == true
        if let row, loaded, sendsBusy, pending.send(id: row) != nil {
            holdBehindTurn(row, through: conversation)
            redrawPending()
            return
        }
        openHandoff()
        let users = loaded ? userTally.users(in: lastState?.messages ?? []) : Self.unloadedBaseline
        let id: UUID
        if let row, pending.restart(id: row, userMessages: users) != nil {
            id = row
        } else {
            id = pending.begin(
                text: send.text, attachments: send.attachments, model: send.model,
                effort: send.effort, userMessages: users
            ).id
        }
        sendWaits[id] = nil
        HeldSends.release(id)
        redrawPending()
        raiseFreshCanvas(for: id)
        if Ultracode.invokes(send.text) || send.effort == Ultracode.effortLevel {
            ultracodeInFlight = true
            refreshUltracodeAura()
        }
        guard loaded else {
            AppLog.write(.session, "send held until the transcript loads")
            return
        }
        post(id, through: conversation, checkFirst: checkFirst)
    }

    /// One attempt at a send already in the ledger, and never a second beside it. The answer is
    /// applied to the conversation the send was written in — this pane's, another pane that has
    /// opened it since, or the shelf it went to — and only by the attempt that is still the
    /// current one, so a send that lands after a switch never touches the chat now on screen and a
    /// called-back attempt never moves a row.
    func post(_ id: UUID, through conversation: AgentConversation, checkFirst: Bool) {
        guard let send = pending.send(id: id), let key = liveKey,
            SendAttempts.mayStart(sendTasks, id)
        else { return }
        let courier = courier(for: send, through: conversation)
        let token = SendShelf.nextToken()
        let task = Task { [weak self] in
            let outcome = await courier.run(
                text: send.text, attachments: send.attachments.count,
                baselineUserCount: send.baselineUserCount, checkFirst: checkFirst)
            Gtk.onMain { [weak self] in
                self?.land(outcome, of: send, token: token, for: key, through: conversation)
            }
        }
        sendTasks[id] = SendAttempt(token: token, task: task, sent: send)
    }

    private func courier(
        for send: PendingSend, through conversation: AgentConversation
    ) -> SendCourier {
        let real = SendCourier.through(
            conversation, text: send.text, model: send.model, effort: send.effort,
            attachments: send.attachments)
        let slow = sendFault.slow
        let fault = sendFault.next()
        guard fault != nil || slow > 0 else { return real }
        return SendCourier(
            bound: real.bound,
            post: {
                if slow > 0 { try await Task.sleep(nanoseconds: UInt64(slow * 1_000_000_000)) }
                if let fault { throw fault }
                try await real.post()
            }, reread: real.reread)
    }

    /// What one attempt came to, handed to whoever holds that attempt now.
    func land(
        _ outcome: SendOutcome, of sent: PendingSend, token: Int, for key: LiveKey,
        through conversation: AgentConversation
    ) {
        if liveKey == key, SendAttempts.finish(&sendTasks, id: sent.id, token: token) {
            landHere(outcome, of: sent, through: conversation)
            return
        }
        if let other = host?.panes(showing: key).first(where: {
            $0.sendTasks[sent.id]?.token == token
        }), SendAttempts.finish(&other.sendTasks, id: sent.id, token: token) {
            other.landHere(outcome, of: sent, through: other.conversation ?? conversation)
            return
        }
        landOnShelf(outcome, of: sent, token: token, for: key)
    }

    /// An answer for a send of the chat on screen, from the attempt that is still its current one.
    func landHere(
        _ outcome: SendOutcome, of sent: PendingSend, through conversation: AgentConversation
    ) {
        let id = sent.id
        let present = SendLanding.settle(outcome, of: sent, in: &pending)
        let now = Date()
        switch outcome {
        case .accepted:
            sendWaits[id] = nil
            HeldSends.release(id)
            if present { scheduleWitness(for: id, through: conversation) }
        case .arrived, .cancelled:
            sendWaits[id] = nil
            HeldSends.release(id)
        case .waiting(let reason):
            endHandoff()
            var clock = sendWaits[id] ?? SendWaitClock(heldSince: now)
            clock.outOfReach(at: now)
            sendWaits[id] = clock
            if let liveKey {
                HeldSends.hold(
                    pending.send(id: id) ?? sent, key: liveKey, heldSince: clock.heldSince,
                    reason: reason)
            }
            armSendWait(id, through: conversation, counting: true)
        case .failed(let reason):
            sendWaits[id] = nil
            HeldSends.release(id)
            endHandoff()
            armResume(row: id, reason: reason)
        }
        redrawPending()
    }

    /// The answer to a send whose chat no pane shows. The words stay with their conversation; its
    /// handoff ends in the edges if the send did not go, and nothing on screen moves.
    private func landOnShelf(
        _ outcome: SendOutcome, of sent: PendingSend, token: Int, for key: LiveKey
    ) {
        let now = Date()
        var landed = false
        SendShelf.change(key) { shelved in
            guard SendAttempts.finish(&shelved.attempts, id: sent.id, token: token) else { return }
            landed = true
            SendLanding.settle(outcome, of: sent, in: &shelved.ledger)
            if case .waiting(let reason) = outcome {
                var clock = shelved.waits[sent.id] ?? SendWaitClock(heldSince: now)
                clock.outOfReach(at: now)
                shelved.waits[sent.id] = clock
                HeldSends.hold(
                    shelved.ledger.send(id: sent.id) ?? sent, key: key,
                    heldSince: clock.heldSince, reason: reason)
            } else {
                shelved.waits[sent.id] = nil
                HeldSends.release(sent.id)
            }
        }
        guard landed else { return }
        switch outcome {
        case .waiting, .failed: host?.live.edges.endedSend(key)
        case .accepted, .arrived, .cancelled: break
        }
        host?.live.edges.noteUnsent(key, SendShelf.hasUnsent(key))
    }

    /// Holds a send and wakes it on `SendWait`'s clock: soon at first, then every half minute. A
    /// wait for the network counts as an attempt; a wait for a transcript to load or a turn to end
    /// does not. A stream coming back live, or a turn ending, tries it at once.
    func armSendWait(_ id: UUID, through conversation: AgentConversation, counting: Bool) {
        var clock = sendWaits[id] ?? SendWaitClock(heldSince: Date())
        if counting { clock.attempts += 1 }
        sendWaits[id] = clock
        sendWaitGeneration += 1
        let token = sendWaitGeneration
        let key = liveKey
        let delay = SendWait.delay(afterAttempts: max(1, clock.attempts))
        Gtk.after(UInt32(delay * 1000)) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, self.liveKey == key, self.sendWaitGeneration == token else {
                    return
                }
                self.tryWaiting(through: self.conversation ?? conversation)
            }
        }
    }

    /// Tries every held send that has nothing on the wire, or lets one go as not sent once the
    /// machine has been out of reach for the whole window.
    private func tryWaiting(through conversation: AgentConversation) {
        let now = Date()
        for send in pending.waiting where sendTasks[send.id] == nil {
            let clock = sendWaits[send.id] ?? SendWaitClock(heldSince: now)
            sendWaits[send.id] = clock
            if clock.givesUp(at: now) {
                sendWaits[send.id] = nil
                HeldSends.release(send.id)
                let reason: String
                if case .waiting(let held) = send.phase { reason = held } else { reason = "" }
                pending.mark(id: send.id, .failed(reason: SendWait.gaveUp(reason)))
                continue
            }
            retryHeld(send.id, through: conversation)
        }
        redrawPending()
    }

    /// Keeps a send's words as a held row that goes first when the turn ends, rather than moving
    /// them behind anything written later. Time spent here never counts toward giving up.
    private func holdBehindTurn(_ id: UUID, through conversation: AgentConversation) {
        let now = Date()
        var clock = sendWaits[id] ?? SendWaitClock(heldSince: now)
        clock.reachable(at: now)
        sendWaits[id] = clock
        let reason = SendWait.behindTurn
        if pending.send(id: id)?.phase != .waiting(reason: reason) {
            pending.mark(id: id, .waiting(reason: reason))
        }
        if let liveKey, let send = pending.send(id: id) {
            HeldSends.hold(send, key: liveKey, heldSince: clock.heldSince, reason: reason)
        }
        armSendWait(id, through: conversation, counting: false)
    }

    /// One more attempt at a held send, once there is a transcript to count it against and nothing
    /// running for it to collide with. The row keeps its place, its words and its line while the
    /// attempt is on the wire, takes a fresh baseline — the server's account may have moved while
    /// it waited — and asks the server first, because it may be standing in for words the server
    /// already has.
    private func retryHeld(_ id: UUID, through conversation: AgentConversation) {
        guard let send = pending.send(id: id), send.isWaiting, sendTasks[id] == nil else { return }
        switch SendGate.attempt(loaded: lastState?.hasLoadedTranscript == true, busy: sendsBusy) {
        case .awaitLoad:
            armSendWait(id, through: conversation, counting: false)
        case .behindTurn:
            holdBehindTurn(id, through: conversation)
        case .post:
            let users = userTally.users(in: lastState?.messages ?? [])
            pending.restart(id: id, userMessages: users)
            pending.mark(id: id, send.phase)
            sendWaits[id]?.reachable(at: Date())
            openHandoff()
            post(id, through: conversation, checkFirst: true)
        }
    }

    /// The stream came back live, a turn ended, or the person said Send now: every held send with
    /// nothing on the wire is tried at once rather than on its next tick, in the order written.
    func retryWaitingNow() {
        guard let conversation else { return }
        sendWaitGeneration += 1
        for send in pending.waiting where sendTasks[send.id] == nil {
            retryHeld(send.id, through: conversation)
        }
        redrawPending()
    }

    /// A send the server took whose prompt the stream has not shown after `SendWitness.after` is
    /// this device's view going stale, never the message: the stream is redialled.
    func scheduleWitness(for id: UUID, through conversation: AgentConversation) {
        witnessGeneration += 1
        let token = witnessGeneration
        let key = liveKey
        Gtk.after(UInt32(SendWitness.after * 1000) + 50) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, self.liveKey == key, self.witnessGeneration == token,
                    self.pending.unwitnessed(now: Date()).contains(where: { $0.id == id })
                else { return }
                AppLog.write(.session, "send unseen for \(Int(SendWitness.after)) s — redialling")
                Task { await conversation.reconnect() }
            }
        }
    }

    /// Stop calls back every attempt on the wire and leaves what is held: a send still in flight
    /// goes with the turn it would have started, and a failure or a send waiting for the
    /// connection keeps the words nobody else has and tries again on its clock, asking the server
    /// first in case the attempt called back had already landed.
    func stopSendsInFlight() {
        guard !sendTasks.isEmpty || pending.hasInFlight else { return }
        SendAttempts.callBackAll(&sendTasks)
        pending.removeInFlight()
        endHandoff()
        if let conversation {
            for send in pending.waiting {
                armSendWait(send.id, through: conversation, counting: false)
            }
        }
        redrawPending()
    }

    /// What the person pressed on a row this device is holding. Nothing moves a row whose attempt
    /// is still on the wire: its answer decides what it becomes.
    func actOnPending(_ id: UUID, _ act: PendingSend.Act) {
        guard let send = pending.send(id: id), send.isUnsent else { return }
        switch act {
        case .retry:
            guard let conversation, SendAttempts.mayStart(sendTasks, id) else { return }
            if send.isWaiting {
                sendWaitGeneration += 1
                retryHeld(id, through: conversation)
                redrawPending()
                return
            }
            deliver(
                QueuedSend(
                    text: send.text, model: send.model, effort: send.effort,
                    attachments: send.attachments),
                through: conversation, reusing: id, checkFirst: true)
        case .edit:
            guard !composerHoldsWords else {
                setNotice(Localized.text("Send or clear what is in the composer first."))
                return
            }
            letGoOfUnsent(id)
            fillComposer(with: send.text)
            gtk_widget_grab_focus(entryView)
            if !send.attachments.isEmpty {
                attachments = send.attachments.map {
                    PendingAttachment(
                        name: $0.filename ?? "attachment", mime: $0.mime, data: $0.data ?? Data())
                }
                renderAttachments()
            }
            redrawPending()
            drainAfterUnsentResolved()
        case .discard:
            letGoOfUnsent(id)
            redrawPending()
            drainAfterUnsentResolved()
        }
    }

    /// Takes a held or failed row away for good: its attempt is called back, its clock and its
    /// record on disk go with it.
    private func letGoOfUnsent(_ id: UUID) {
        sendTasks.removeValue(forKey: id)?.task.cancel()
        sendWaits[id] = nil
        HeldSends.release(id)
        pending.remove(id: id)
    }

    /// A queue held behind a row that did not go moves again once that row is resolved.
    func drainAfterUnsentResolved() {
        guard !pending.hasUnsent, let state = lastState else { return }
        drainHeldQueue(state)
    }

    /// Puts the sends of the chat this pane is leaving on the shelf with their attempts still
    /// running, and takes up whatever the shelf held for the chat it is opening — attempts still
    /// on the wire included, so nothing is sent twice — to be tried once its transcript loads.
    func shelveSends(leaving previous: LiveKey?, opening next: LiveKey?) {
        if let previous {
            SendShelf.put(
                SendShelf.Shelved(ledger: pending, waits: sendWaits, attempts: sendTasks),
                for: previous)
            host?.live.edges.noteUnsent(previous, pending.hasUnsent)
        }
        sendWaitGeneration += 1
        witnessGeneration += 1
        sendTasks = [:]
        sendsSawLoad = false
        lastConnection = nil
        handoff = TurnHandoff()
        guard let next else {
            pending.removeAll()
            sendWaits = [:]
            return
        }
        let shelved = SendShelf.take(next)
        pending = shelved.ledger
        sendWaits = shelved.waits
        sendTasks = shelved.attempts
        feed.update { $0.echoBaseline = pending.echoBaseline }
    }

    /// Re-arms the sends a chat picked back up from the shelf once its conversation exists. Each
    /// waits for the transcript to load before it is tried.
    func resumeShelvedSends() {
        guard pending.waiting.contains(where: { sendTasks[$0.id] == nil }) else { return }
        retryWaitingNow()
    }

    /// `sendfault=offline:N` / `dropped:N` / `slow:SECONDS` / `none` for the harness.
    func armSendFault(_ spec: String) {
        let parts = spec.split(separator: ":")
        let value = parts.count > 1 ? Double(parts[1]) ?? 1 : 1
        switch parts.first {
        case "offline": sendFault.offline = Int(value)
        case "dropped": sendFault.dropped = Int(value)
        case "slow": sendFault.slow = value
        default: sendFault = SendFault()
        }
    }

    /// How the echo is drawn right now, for the harness: each pending row's opacity, whether the
    /// previous answer is the row being written, and the canvas.
    var echoReading: String {
        var opacities: [String] = []
        for index in renderedRows.indices where index < rowWidgets.count {
            guard case .pendingSend = renderedRows[index].kind,
                let raw = UnsafeMutableRawPointer(bitPattern: rowWidgets[index])
            else { continue }
            opacities.append(String(format: "%.2f", gtk_widget_get_opacity(ptr(raw))))
        }
        let writing = cascade.key ?? "none"
        return "echoOpacity=[\(opacities.joined(separator: ","))] writing=\(writing) \(freshCanvasReading)"
    }

    /// What the pane is holding, for the harness: every send's phase and line, and the queue.
    var sendReading: String {
        let now = Date()
        let rows = pending.sends.map { send -> String in
            let phase: String
            switch send.phase {
            case .sending: phase = "sending"
            case .accepted: phase = "accepted"
            case .failed: phase = "failed"
            case .waiting: phase = "waiting"
            }
            let acts = send.acts.map { PendingSendReading.title($0, for: send) }.joined(separator: "/")
            return "\(phase)[\(PendingSendReading.caption(send, now: now) ?? "-")|\(acts)]"
        }
        return
            "pending=\(pending.count) \(rows.joined(separator: " ")) queue=\(queueDisplay.count) turnOpen=\(turnOpenNow) onWire=\(sendTasks.count) loaded=\(lastState?.hasLoadedTranscript == true) busy=\(sendsBusy) handoff=\(handoff.isOpen) conversation=\(conversation != nil) messages=\(lastState?.messages.count ?? -1) connection=\(lastState.map { "\($0.connection)" } ?? "none") chat=\(sessionID ?? "none")"
    }
}
