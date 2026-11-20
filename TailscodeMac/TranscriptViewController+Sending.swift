import AppKit
import CodingAgentKit
import TailscodeCore

/// The life of a send after the press: one attempt at a time through Core's `SendCourier`, every
/// outcome landed on the chat it was sent in, a send that could not leave held and tried again on
/// `SendWait`'s clock, and the transcript asked before any send is offered twice.
extension TranscriptViewController {
    static func echoKey(_ id: UUID) -> String { "echo:\(id.uuidString)" }

    static func echoPictureKey(_ id: UUID, _ index: Int) -> String {
        "\(echoKey(id)):img\(index)"
    }

    /// The chat a send belongs to, in the keys every store uses.
    var sendKey: String {
        entry.map { SessionPinStore.key($0.profileID, $0.session.id) } ?? ""
    }

    private var userMessageCount: Int {
        guard let state = lastState, state.hasLoadedTranscript else { return Int.max }
        return state.messages.count { $0.role == .user }
    }

    var sendOwner: SendOwner {
        SendOwner(key: sendKey, profileID: entry?.profileID, sessionID: entry?.session.id)
    }

    /// Whether a turn is running, which a held send waits out rather than posting into.
    var turnHoldsSends: Bool {
        lastState?.status == .running || lastState?.compaction?.isRunning == true
    }

    /// Whether this pane is the one that sends for its chat: a chat open in two panes would
    /// otherwise put the same held words on the wire twice. A pane with no live lease answers for
    /// itself.
    var leadsSends: Bool { attachedKey == nil || ownsQueue }

    /// Puts a send on the wire. A send written before the transcript loaded waits for it, drawn
    /// already. `arrivalBaseline` is where a check looks for the words it might already have
    /// delivered — the count from before this attempt, not from it.
    func dispatchSend(_ id: UUID, checkFirst: Bool, arrivalBaseline: Int? = nil) {
        guard let conversation, let send = pending.send(id: id) else { return }
        guard lastState?.hasLoadedTranscript == true, send.baselineUserCount != Int.max else {
            heldForTranscript.insert(id)
            return
        }
        heldForTranscript.remove(id)
        let owner = sendOwner
        let courier =
            courierFactory?(conversation, send)
            ?? SendCourier.through(
                conversation, text: send.text, model: send.model, effort: send.effort,
                attachments: send.attachments)
        let baseline = min(arrivalBaseline ?? send.baselineUserCount, send.baselineUserCount)
        let token = UUID()
        sendFlights.removeValue(forKey: id)?.task.cancel()
        let task = Task { [weak self] in
            let outcome = await courier.run(
                text: send.text, attachments: send.attachments.count,
                baselineUserCount: baseline, checkFirst: checkFirst)
            self?.land(outcome, of: send, owner: owner, token: token)
        }
        sendFlights[id] = SendFlight(token: token, task: task)
    }

    /// What one attempt came to, applied to the chat it was made for. A pane that has moved on to
    /// another chat keeps the outcome with the chat it belongs to and touches nothing on screen; an
    /// attempt a newer one replaced, or that Stop took back, is not applied at all.
    ///
    /// A row can be gone while its attempt is still out: the account growing past it retires it,
    /// and another device's message grows the account too. An answer that the words never reached
    /// the server puts the row back rather than dropping the words; an answer that they did needs
    /// no row, because the server's account already carries them.
    func land(_ outcome: SendOutcome, of sent: PendingSend, owner: SendOwner, token: UUID) {
        let id = sent.id
        guard sendFlights[id]?.token == token else { return }
        sendFlights.removeValue(forKey: id)
        guard owner.key == sendKey else {
            landElsewhere(outcome, of: sent, owner: owner)
            return
        }
        if pending.send(id: id) == nil {
            switch outcome {
            case .waiting(let reason):
                pending.reinstate(sent, as: .waiting(reason: reason))
            case .failed(let reason):
                pending.reinstate(sent, as: .failed(reason: reason))
            case .accepted, .arrived, .cancelled:
                dropWait(id)
                HeldSendStore.release(id)
                return
            }
        }
        switch outcome {
        case .accepted:
            dropWait(id)
            HeldSendStore.release(id)
            guard pending.mark(id: id, .accepted) else { return }
            armSendWitness()
            nudgeWaitingSends()
            redrawPending()
        case .arrived:
            dropWait(id)
            HeldSendStore.release(id)
            pending.remove(id: id)
            releaseResumePlan(id)
            nudgeWaitingSends()
            redrawPending()
        case .waiting(let reason):
            armSendWait(id: id, reason: reason)
        case .failed(let reason):
            dropWait(id)
            markSendFailed(id, reason: reason)
            nudgeWaitingSends()
        case .cancelled:
            dropWait(id)
            if pending.send(id: id)?.isInFlight == true {
                pending.remove(id: id)
                HeldSendStore.release(id)
            }
            redrawPending()
        }
    }

    private func landElsewhere(_ outcome: SendOutcome, of sent: PendingSend, owner: SendOwner) {
        let id = sent.id
        var held = unsentStash[owner.key] ?? PendingSendLedger()
        switch outcome {
        case .accepted:
            held.mark(id: id, .accepted)
            HeldSendStore.release(id)
        case .arrived, .cancelled:
            held.remove(id: id)
            HeldSendStore.release(id)
        case .waiting(let reason):
            if !held.reinstate(sent, as: .waiting(reason: reason)) {
                held.mark(id: id, .waiting(reason: reason))
            }
            if let profileID = owner.profileID, let sessionID = owner.sessionID,
                let row = held.send(id: id)
            {
                HeldSendStore.hold(
                    HeldSend(
                        row, profileID: profileID, sessionID: sessionID, heldSince: Date(),
                        reason: reason))
            }
        case .failed(let reason):
            if !held.reinstate(sent, as: .failed(reason: reason)) {
                held.mark(id: id, .failed(reason: reason))
            }
            HeldSendStore.release(id)
        }
        unsentStash[owner.key] = held.isEmpty ? nil : held
    }

    /// Keeps a held send on disk, so a quit or a crash does not take words nobody else has.
    private func keepHeld(_ id: UUID, reason: String, heldSince: Date) {
        guard let entry, let send = pending.send(id: id) else { return }
        HeldSendStore.hold(
            HeldSend(
                send, profileID: entry.profileID, sessionID: entry.session.id,
                heldSince: heldSince, reason: reason))
    }

    /// Holds a send the machine could not be reached for and sets the clock that tries it again.
    /// The prompt keeps the place it rose to — it is going, only later — and once `SendWait.window`
    /// of unreachable time has passed the row says it did not go.
    func armSendWait(id: UUID, reason: String) {
        let now = Date()
        var hold = sendWaits[id] ?? SendWaitHold(attempts: 0, heldSince: now, reason: reason)
        hold.timer?.cancel()
        hold.timer = nil
        hold.attempting = false
        if let behind = hold.behindSince {
            hold.heldSince = hold.heldSince.addingTimeInterval(now.timeIntervalSince(behind))
            hold.behindSince = nil
        }
        hold.attempts += 1
        hold.reason = reason
        handoff.end()
        if SendWait.givesUp(heldSince: hold.heldSince, now: now) {
            sendWaits.removeValue(forKey: id)
            markSendFailed(id, reason: SendWait.gaveUp(reason))
            return
        }
        pending.mark(id: id, .waiting(reason: reason))
        keepHeld(id, reason: reason, heldSince: hold.heldSince)
        hold.timer = waitClock(id, after: SendWait.delay(afterAttempts: hold.attempts))
        sendWaits[id] = hold
        redrawPending()
    }

    /// Holds a send behind the turn that is running: it goes when the turn ends, ahead of anything
    /// written after it. Time spent here is not time the machine was out of reach, so it neither
    /// counts as an attempt nor brings the end of the window closer.
    func holdBehindTurn(_ id: UUID) {
        guard pending.send(id: id) != nil else { return }
        let now = Date()
        var hold =
            sendWaits[id] ?? SendWaitHold(attempts: 0, heldSince: now, reason: SendWait.behindTurn)
        hold.timer?.cancel()
        hold.attempting = false
        hold.behindSince = hold.behindSince ?? now
        hold.reason = SendWait.behindTurn
        pending.mark(id: id, .waiting(reason: SendWait.behindTurn))
        keepHeld(id, reason: SendWait.behindTurn, heldSince: hold.heldSince)
        hold.timer = waitClock(id, after: SendWait.delay(afterAttempts: SendWait.delays.count))
        sendWaits[id] = hold
        if !settlingSends { redrawPending() }
    }

    private func waitClock(_ id: UUID, after delay: TimeInterval) -> Task<Void, Never>? {
        guard !isParked else { return nil }
        return Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled else { return }
            self?.attemptWaiting(id)
        }
    }

    /// Tries a held send now — its clock came round, the stream came back, the turn it waited
    /// behind ended, or the person pressed Send now. Only the oldest held send is tried; the rest
    /// go after it, in the order written. A turn still running holds it there, and every attempt
    /// asks the server first, because a held row may stand for words it already has.
    ///
    /// While the attempt is out the row goes on reading as held (`echoed` keeps its words), and
    /// the ledger reads it as on its way, so nothing above it is drawn as the open turn.
    func attemptWaiting(_ id: UUID) {
        guard let send = pending.send(id: id), send.isWaiting else { return }
        if let first = pending.waiting.first, first.id != id { return }
        guard !turnHoldsSends, !handoff.isOpen else {
            holdBehindTurn(id)
            return
        }
        let now = Date()
        var hold =
            sendWaits[id]
            ?? SendWaitHold(attempts: 0, heldSince: send.startedAt, reason: Self.reason(of: send))
        guard !hold.attempting else { return }
        hold.timer?.cancel()
        hold.timer = nil
        hold.attempting = true
        if let behind = hold.behindSince {
            hold.heldSince = hold.heldSince.addingTimeInterval(now.timeIntervalSince(behind))
            hold.behindSince = nil
        }
        sendWaits[id] = hold
        let before = send.baselineUserCount
        guard pending.restart(id: id, userMessages: userMessageCount) != nil else { return }
        openHandoff()
        dispatchSend(id, checkFirst: true, arrivalBaseline: before)
    }

    /// The stream coming back live, or the turn a send waited behind ending, is the best news a
    /// held send can have: the oldest goes at once rather than at the end of its back-off.
    func nudgeWaitingSends() {
        guard let first = pending.waiting.first else { return }
        attemptWaiting(first.id)
    }

    static func reason(of send: PendingSend) -> String {
        if case .waiting(let reason) = send.phase { return reason }
        return ""
    }

    func dropWait(_ id: UUID) {
        sendWaits.removeValue(forKey: id)?.timer?.cancel()
    }

    func dropAllWaits() {
        for hold in sendWaits.values { hold.timer?.cancel() }
        sendWaits = [:]
        sendWitness?.cancel()
        sendWitness = nil
    }

    /// The server said it has the prompt; if the transcript still does not show it after
    /// `SendWitness.after`, the stream carrying the conversation is what to doubt.
    func armSendWitness() {
        let now = Date()
        let due = pending.sends.filter { $0.phase == .accepted }
            .map { $0.startedAt.addingTimeInterval(SendWitness.after) }.min()
        sendWitness?.cancel()
        sendWitness = nil
        guard let due else { return }
        guard !isParked else { return }
        let key = sendKey
        sendWitness = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0.5, due.timeIntervalSince(now))))
            guard !Task.isCancelled, let self, key == self.sendKey else { return }
            self.sendWitness = nil
            guard !self.pending.unwitnessed(now: Date()).isEmpty else {
                self.armSendWitness()
                return
            }
            self.reconnect()
        }
    }

    /// Send again on a failure, or Send now on a held send. Either asks the server first. With a
    /// turn running — or an older send still held — the row stays where it was written and waits,
    /// held on this device, and goes first when the way is clear: moved into the queue it would be
    /// sent unchecked, and behind whatever was written after it.
    func retryUnsent(_ id: UUID) {
        guard let send = pending.send(id: id), send.isUnsent else { return }
        if send.isWaiting {
            attemptWaiting(id)
            return
        }
        let olderHeld = pending.waiting.first.map { $0.id != id } ?? false
        if turnHoldsSends || handoff.isOpen || olderHeld {
            holdBehindTurn(id)
            return
        }
        let firstBaseline = send.baselineUserCount
        guard pending.restart(id: id, userMessages: userMessageCount) != nil else { return }
        MacHaptics.shared.play(.send)
        openHandoff()
        redrawPending()
        riseFreshCanvas(rowKey: Self.echoKey(id))
        dispatchSend(id, checkFirst: true, arrivalBaseline: firstBaseline)
    }

    /// A row that stops standing for its words — sent elsewhere, retired, taken back: its clock,
    /// its attempt, its copy on disk and any plan holding it for a spent window go with it.
    func retireRow(_ id: UUID) {
        sendFlights.removeValue(forKey: id)?.task.cancel()
        dropWait(id)
        heldForTranscript.remove(id)
        pending.remove(id: id)
        HeldSendStore.release(id)
        releaseResumePlan(id)
    }

    func releaseResumePlan(_ id: UUID) {
        guard resume.plan(for: id) != nil else { return }
        resume.drop(id)
        ResumeStore.release(id)
    }

    /// Stop takes back what is on its way and nothing else: a failure or a held send keeps the
    /// words nobody else has. Says whether there was anything to take back.
    @discardableResult
    func stopSendsInFlight() -> Bool {
        let flying = pending.sends.filter(\.isInFlight).map(\.id)
        guard !flying.isEmpty else { return false }
        for id in flying {
            sendFlights.removeValue(forKey: id)?.task.cancel()
            dropWait(id)
            heldForTranscript.remove(id)
            HeldSendStore.release(id)
        }
        pending.removeInFlight()
        handoff.end()
        releaseFreshCanvas(animated: false)
        armSendWitness()
        redrawPending()
        return true
    }

    /// Brings this device's account of what it sent up to the server's, before anything is built
    /// from the state: what the transcript now carries is retired, a send written before the
    /// transcript loaded goes out against its real count, the held messages of a spent window and
    /// the sends held for the connection before a quit come back as rows, and the stream coming back
    /// live — or the turn a send was held behind ending — tries the oldest held send at once.
    /// Idempotent, so the row build and the apply can both ask; the row build, which runs before
    /// the pane takes the state as its own, only settles what the transcript retired and leaves
    /// everything that sends to the apply.
    func settlePending(with state: ConversationState, acting: Bool = true) {
        guard acting else {
            guard state.hasLoadedTranscript, !pending.isEmpty else { return }
            retire(against: state)
            return
        }
        settlingSends = true
        defer { settlingSends = false }
        let connection = state.connection
        let cameBack = lastConnection != nil && lastConnection != .live && connection == .live
        lastConnection = connection
        guard state.hasLoadedTranscript else { return }
        let userMessages = state.messages.count { $0.role == .user }
        if !heldMessagesRestored {
            heldMessagesRestored = true
            restoreHeldMessages(userMessages: userMessages)
            restoreHeldSends(in: state, userMessages: userMessages)
        }
        guard !pending.isEmpty else { return }
        let held = pending.sends.filter { heldForTranscript.contains($0.id) }.map(\.id)
        for id in held {
            heldForTranscript.remove(id)
            let waiting = sendWaits[id] != nil
            guard pending.restart(id: id, userMessages: userMessages) != nil else { continue }
            if waiting { sendWaits[id]?.attempting = true }
            dispatchSend(id, checkFirst: waiting)
        }
        retire(against: state)
        if cameBack { nudgeWaitingSends() }
    }

    /// A send held behind a turn goes the moment the turn has ended and the handoff after the last
    /// send has closed — asked after the state has been taken in, so the turn's end is the one this
    /// state reports.
    func sendWhatWaitedBehindTurn() {
        guard !turnHoldsSends, !handoff.isOpen, let first = pending.waiting.first,
            Self.reason(of: first) == SendWait.behindTurn
        else { return }
        attemptWaiting(first.id)
    }

    /// Retires what the server's account now carries: a send on its way by the count, and a
    /// failure or a held send by its own words, with its attempt, its clock, its copy on disk and
    /// any plan that held it.
    private func retire(against state: ConversationState) {
        let before = pending.sends
        pending.reconcile(userMessages: state.messages.count { $0.role == .user })
        for send in pending.retireArrived(in: state.messages) {
            sendFlights.removeValue(forKey: send.id)?.task.cancel()
            dropWait(send.id)
            HeldSendStore.release(send.id)
            releaseResumePlan(send.id)
        }
        let gone = before.filter { pending.send(id: $0.id) == nil }
        guard !gone.isEmpty else { return }
        handOverPictures(of: gone, in: state.messages)
        if !pending.sends.contains(where: { $0.phase == .accepted }) {
            sendWitness?.cancel()
            sendWitness = nil
        }
    }

    /// Puts back the sends this chat was holding for the connection when the app last ran — once
    /// the transcript has loaded, so each row's baseline is the transcript's own count — unless the
    /// transcript shows the words were written after the send started waiting, which is a send that
    /// went before the app went away. Only the pane that sends for the chat takes them up.
    private func restoreHeldSends(in state: ConversationState, userMessages: Int) {
        guard let entry, leadsSends else { return }
        let records = HeldSendStore.records(profileID: entry.profileID, sessionID: entry.session.id)
        guard !records.isEmpty else { return }
        let users = state.messages.filter { $0.role == .user }
        for record in records {
            let landed = users.contains {
                $0.createdAt >= record.heldSince.addingTimeInterval(-60)
                    && SendArrival.arrived(
                        record.text, attachments: record.attachments.count, baselineUserCount: 0,
                        in: [$0])
            }
            if landed {
                HeldSendStore.release(record.id)
                continue
            }
            guard pending.restore(record, userMessages: userMessages) != nil else { continue }
            var hold = SendWaitHold(attempts: 0, heldSince: record.heldSince, reason: record.reason)
            hold.timer = waitClock(record.id, after: SendWait.delay(afterAttempts: 1))
            sendWaits[record.id] = hold
        }
    }

    /// Leaving a chat in this pane keeps whatever this device still holds for it — a send on its
    /// way, held for the connection, or failed — with the chat rather than with the pane. The
    /// attempts on the wire land in the stash.
    func stashPending() {
        let key = sendKey
        for hold in sendWaits.values { hold.timer?.cancel() }
        sendWaits = [:]
        sendWitness?.cancel()
        sendWitness = nil
        heldForTranscript = []
        lastConnection = nil
        if entry != nil, !pending.isEmpty { unsentStash[key] = pending }
        pending = PendingSendLedger()
    }

    /// Opening a chat again in this pane puts back what it was holding: a send written before the
    /// transcript loaded waits for it again, and one held for the connection is tried soon after.
    func restoreStash() {
        pending = unsentStash.removeValue(forKey: sendKey) ?? PendingSendLedger()
        for send in pending.sends {
            if send.baselineUserCount == Int.max { heldForTranscript.insert(send.id) }
            if send.isWaiting {
                var hold = SendWaitHold(
                    attempts: 0, heldSince: send.startedAt, reason: Self.reason(of: send))
                hold.timer = waitClock(send.id, after: SendWait.delay(afterAttempts: 1))
                sendWaits[send.id] = hold
            }
        }
        armSendWitness()
    }

    /// Re-arms the clocks a parked pane let go of: a held send is tried again, and a send the
    /// server took is witnessed.
    func rearmSendClocks() {
        nudgeWaitingSends()
        armSendWitness()
    }

    /// A send that did not go gives back the room it rose into without moving the page under the
    /// reader: the room under the transcript shrinks only as far as the content lets the clip stay
    /// where it is, and the rest eases away on the send's own clock.
    func letCanvasGoGently() {
        guard canvasHold != nil || canvasPadding > 0 else {
            releaseFreshCanvas(animated: false)
            return
        }
        let clip = scrollView.contentView
        let origin = clip.bounds.origin.y
        let bare = canvas.frame.height - clip.bounds.height + chromeInsets.bottom
        let keep = max(0, origin - bare)
        canvasKey = nil
        canvasPinned = false
        canvasRising = false
        canvasRiseDeadline = nil
        canvasHold = nil
        canvasPadding = keep > 0.5 ? keep : 0
        applyInsets()
        guard keep > 0.5 else { return }
        let target = NSPoint(x: clip.bounds.origin.x, y: max(-scrollView.contentInsets.top, bare))
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            clip.scroll(to: target)
            scrollView.reflectScrolledClipView(clip)
            closeLetGoRoom()
            return
        }
        isAutoScrolling = true
        NSAnimationContext.runAnimationGroup(
            { animation in
                animation.duration = SendMotion.duration
                animation.timingFunction = SendMotion.curve
                clip.animator().setBoundsOrigin(target)
            },
            completionHandler: { [weak self] in
                MainThread.call {
                    self?.isAutoScrolling = false
                    self?.closeLetGoRoom()
                }
            })
    }

    /// The last of the room goes once the page has eased onto the content's own end — unless a
    /// newer send has made room of its own in the meantime.
    private func closeLetGoRoom() {
        guard canvasHold == nil, !canvasRising else { return }
        canvasPadding = 0
        applyInsets()
        scrollView.reflectScrolledClipView(scrollView.contentView)
    }

    /// Decodes the pictures a send carries from the bytes already in hand, off the main thread,
    /// under the keys its echo rows draw from; the shape is read from the header at once so the
    /// rows are laid out at their own proportions from the press.
    func stageEchoPictures(of id: UUID) {
        guard let send = pending.send(id: id) else { return }
        for (index, picture) in send.pictures.enumerated() {
            let key = Self.echoPictureKey(id, index)
            guard ImageStore.shared.entry(forKey: key) == nil, let data = picture.data else {
                continue
            }
            if let shape = ImageStore.pixelSize(of: data) {
                ImageStore.shared.store(shape: shape, forKey: key)
            }
            Task { [weak self] in
                let decoded = await Task.detached { ImageStore.decode(data) }.value
                guard let decoded else { return }
                ImageStore.shared.store(decoded, forKey: key)
                self?.replaceRows { $0.key == key }
            }
        }
    }

    /// The server's account of a send carries its pictures as file parts this device has not
    /// fetched; the picture it just drew from memory is handed to those rows, so the swap shows the
    /// same picture rather than a placeholder and a second download, and the bytes go to the disk
    /// cache under the server's path for the next time the chat opens.
    private func handOverPictures(of sends: [PendingSend], in messages: [ChatMessage]) {
        let users = messages.filter { $0.role == .user }
        for send in sends where !send.pictures.isEmpty {
            let after = users.dropFirst(min(max(0, send.baselineUserCount), users.count))
            guard
                let message = after.first(where: { SendArrival.arrived(send, in: [$0]) })
                    ?? after.first
            else { continue }
            let files = message.parts.compactMap { part -> (key: String, reference: FileReference)? in
                guard case .file(let reference) = part.kind,
                    (reference.mime ?? "").hasPrefix("image/")
                else { return nil }
                return ("\(message.id):\(part.id)", reference)
            }
            for (index, file) in files.enumerated() where index < send.pictures.count {
                guard ImageStore.shared.entry(forKey: file.key) == nil,
                    let entry = ImageStore.shared.entry(forKey: Self.echoPictureKey(send.id, index))
                else { continue }
                ImageStore.shared.store(entry, forKey: file.key)
                let reference = file.reference
                let bytes = entry.data
                Task.detached { ImageDisk.save(bytes, for: reference) }
            }
        }
    }
}

/// The one motion of the send moment on the Mac: the rise, the composer settling to one line and a
/// failed send letting its room go all run on this clock, so they read as one hand.
enum SendMotion {
    static let duration: TimeInterval = 0.3
    static var curve: CAMediaTimingFunction { CAMediaTimingFunction(name: .easeOut) }
    /// A phase changing on a row that then holds still.
    static let ink: TimeInterval = 0.22

    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
}
