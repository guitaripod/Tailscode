import AppKit
import os
import CodingAgentKit
import TailscodeCore

extension TranscriptViewController {
    func open(_ entry: SessionEntry, backend: any CodingAgentBackend) {
        clearSlot()
        hoverBar.dismiss()
        railController.dismiss()
        guard self.entry?.session.id != entry.session.id || self.entry?.profileID != entry.profileID
        else { return }
        beginOpenJourney()
        onStopWatch?(TileRuntime.key(entry))
        keepPage(of: self.entry)
        handToWatchIfInFlight()
        detachLive()
        self.entry = entry
        self.backend = backend
        calls.bind(entry)
        statusBand.resetSlots()
        editingQueued = nil
        queue = ConversationQueue(profileID: entry.profileID, sessionID: entry.session.id)
        lastState = nil
        dismissChooser()
        hideEmptyState()
        composer.isHidden = false
        composer.prepare(for: entry, backend: backend)
        context.expanded.reset()
        forgetHeldRows()
        context.subagentRows = [:]
        context.agentFacts = [:]
        inFlightImages = []
        refusedImages = []
        inFlightSubagents = []
        pending.removeAll()
        interruptionPress = nil
        revertOperation = nil
        revertComposerFill = nil
        retryWake?.cancel()
        retryWake = nil
        resume.removeAll()
        resumeClock?.cancel()
        resumeClock = nil
        restoreHeldMessages()
        ActivityInbox.clear(sessionID: entry.session.id)
        windowLimit = 400
        rowTailMessages = 300
        lastFullRows = []
        lastStreamedKey = nil
        stopTailRepair()
        abandoned = nil
        releaseFreshCanvas(animated: false)
        followsBottom = true
        pendingSignature = "\u{0}"
        pendingStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        setFindShown(false)
        agents = []
        usage = nil
        git = nil
        transcriptFill = nil
        contextFill = nil
        countedMessages = -1
        tickerTask?.cancel()
        tickerTask = nil
        agentStreamTask?.cancel()
        agentStreamTask = nil
        agentStreamSessionID = nil
        wasRunningForHaptics = false
        hapticPermissionID = nil
        hapticQuestionID = nil
        updateStatus()
        refreshAuthBanner()
        refreshIdentity()

        let pageKey = SessionPinStore.key(entry.profileID, entry.session.id)
        if let kept = keptPages.removeValue(forKey: pageKey) {
            keptOrder.removeAll { $0 == pageKey }
            restorePage(kept)
            endOpenJourney(as: "kept")
        } else if let remembered = sessionRows[pageKey] {
            placeholderShown = true
            lastFullRows = remembered
            let limit = rowLimit
            applyRows(remembered.count > limit ? Array(remembered.suffix(limit)) : remembered)
        } else {
            showPlaceholder(Localized.text("Connecting…"))
        }

        conversation = TileRuntime.shared.conversation(for: entry, backend: backend)
        if !isParked { attachLive() }
        refreshTurnFacts()
        if let queued = pendingFirstMessage {
            pendingFirstMessage = nil
            if queued.sessionID == entry.session.id {
                sendQueued(queued.send, attachments: queued.attachments)
            }
        }
    }

    /// A quick ask's words arrive before this pane's conversation exists, so they wait here —
    /// keyed to the session they were minted for — and go out the moment open() builds that
    /// session's conversation. Any other open drops them: the key is what makes sending a question
    /// into a stranger's chat impossible, and the caller queues in the same main-actor turn that
    /// opens the minted chat, so nothing can slip in between.
    func queueFirstMessage(
        _ send: QuickAskSend, attachments: [PendingAttachment] = [], forSession sessionID: String
    ) {
        pendingFirstMessage = (sessionID, send, attachments)
    }

    /// The decision the quick ask already made, carried out rather than made again: a command goes
    /// out through the command route exactly as picking it from the list would have sent it, and
    /// everything else is the prompt it was written as. The catalog that could answer a slash is
    /// the aimed machine's, and it was read where the question was typed.
    private func sendQueued(_ send: QuickAskSend, attachments: [PendingAttachment]) {
        let choice = composer.promptChoice
        switch send.kind {
        case .prompt:
            sendPrompt(
                send.text, model: choice.model, effort: choice.effort,
                attachments: attachments.map(\.prompt))
        case .command(let command, let arguments):
            SlashRecents.record(command.name)
            guard let conversation else { return }
            Task {
                try? await conversation.run(
                    command, arguments: arguments, model: choice.model,
                    reasoningEffort: choice.effort)
            }
        }
    }

    /// Re-dials without disturbing the stream — the socket a sleeping Mac wakes up holding looks
    /// alive and delivers nothing.
    func reconnect() {
        guard let conversation else { return }
        Task { await conversation.reconnect() }
        if factsReadAt.map({ Date().timeIntervalSince($0) > Self.factsShelfLife }) ?? true {
            refreshTurnFacts()
        }
    }

    private static let factsShelfLife: TimeInterval = 60

    /// A pane keeps the entry it was opened with, so a conversation the server named after it
    /// arrived, renamed since, or ran a turn on from another desk would wear the answer it had at
    /// birth for as long as it stayed open. The listing is what knows the current one, and the
    /// model and level belong to it too: a chat driven from the Arch box must show that effort
    /// here rather than the server deciding, and a send from here must carry it back. Core decides
    /// what is worth taking (never the untitled placeholder), and the identity line is redrawn
    /// only when something was.
    @discardableResult
    func adopt(_ listed: SessionEntry) -> Bool {
        guard let current = entry, let adopted = current.adoptingListing(from: listed) else {
            return false
        }
        entry = adopted
        composer.adopt(adopted)
        refreshIdentity()
        return true
    }

    /// A closing pane stops talking to the world before its views go: a cancelled stream is the
    /// difference between a closed pane and a leak that keeps rendering into nothing. What was
    /// half-typed into it is written first — closing a pane is not a decision to throw a prompt
    /// away, and the chat it belongs to can be opened again anywhere.
    func shutdownPane() {
        handToWatchIfInFlight()
        composer.stashDraft()
        composer.stopWatching()
        interruptionPress = nil
        draw?.shutdown()
        page?.shutdown()
        preview?.shutdown()
        #if !TAILSCODE_MAS
            video?.shutdown()
        #endif
        lifetime.cancelAll()
        releaseClocks()
    }

    /// A turn still in flight when this pane lets go of its chat is handed to the window's watch,
    /// before the pane's own lease goes, so the stream never has nobody holding it.
    private func handToWatchIfInFlight() {
        guard let entry, let backend, conversation != nil, presence.isInFlight else { return }
        onBackgroundWatch?(entry, backend)
    }

    /// Takes the process's live conversation for this pane's chat: a full lease whose states wake
    /// the frame's drain, and a slot in that drain. Both, and every clock, belong to the lifetime.
    private func attachLive() {
        guard lease == nil, let entry, let backend else { return }
        beginLifetime()
        let runtime = TileRuntime.shared
        let (taken, shared) = runtime.attach(self, entry: entry, backend: backend)
        ConversationWarmer.shared.handOver(entry)
        let key = TileRuntime.key(entry)
        lease = taken
        conversation = shared
        attachedKey = key
        lastSequence = 0
        let token = runtime.drain.register(drainSlot(taken))
        drainToken = token
        let me = ObjectIdentifier(self)
        lifetime.add { taken.cancel() }
        lifetime.add { token.cancel() }
        lifetime.add { MainThread.call { TileRuntime.shared.detach(me, from: key) } }
        let call = calls
        call.paneBecameLive()
        lifetime.add {
            MainThread.call {
                call.paneStopped(because: "the pane let go of its conversation")
            }
        }
    }

    private func detachLive() {
        guard lease != nil else { return }
        lifetime.cancelAll()
    }

    private func drainSlot(_ lease: LiveLease) -> DrainSlot {
        DrainSlot(
            pane: paneID, priority: isFocusedPane ? .focused : .full,
            hasWork: { lease.hasFrame },
            apply: { [weak self] in MainThread.call { self?.applyNewestFrame() } })
    }

    /// The frame's turn for this pane: the newest state the hub holds, built and applied once,
    /// however many arrived since the last frame.
    private func applyNewestFrame() {
        guard let frame = lease?.take() else { return }
        if lastSequence > 0, frame.sequence > lastSequence + 1 {
            skippedFrames += Int(frame.sequence - lastSequence - 1)
        }
        lastSequence = frame.sequence
        appliedFrames += 1
        let started = CACurrentMediaTime()
        defer { applyTime += CACurrentMediaTime() - started }
        let state = frame.state
        let tail = rowTailMessages
        let messages =
            state.messages.count > tail ? Array(state.messages.suffix(tail)) : state.messages
        let rows = buildRows(messages, state: state)
        apply(state: state, rows: rows)
    }

    func noteCascadeFrame(_ seconds: TimeInterval) {
        cascadeFrames += 1
        cascadeTime += seconds
    }

    /// How many rows this pane realises. The focused pane keeps the person's window; a full peer
    /// keeps the window the governor's decision gave it — every realised row joins the window's one
    /// layout engine, whose cost grows faster than the row count, so eight panes of full windows is
    /// a window that cannot be laid out. A peer the governor has not ranked yet keeps the window
    /// of the level it is at. From strained up every peer is a glance tile and realises no rows at
    /// all; the one full peer that can exist there sits beside a focused slot, and it keeps the
    /// loaded level's window rather than none.
    var rowLimit: Int {
        let own = max(windowLimit, Self.transcriptWindowPreference)
        guard !isFocusedPane else { return own }
        let window = peerRowWindow ?? TileGovernor.peerRowWindow(level: Seatbelts.shared.level)
        return min(own, window > 0 ? window : TileGovernor.peerRowWindow(level: .loaded))
    }

    /// Takes the row window the governor gave this pane. A narrower window takes effect at the
    /// next state; nothing is torn down here, because the very next frame rebuilds the tail.
    func setRowWindow(_ window: Int?) {
        peerRowWindow = window
    }

    /// Holds the transcript's rows at their current width (clipped or padded by the pane) until
    /// released, when they take the pane's width again in one pass.
    func setLiveResize(_ deferring: Bool) {
        guard deferring != defersRowWidth, isViewLoaded else { return }
        defersRowWidth = deferring
        if deferring {
            let held = canvas.widthAnchor.constraint(equalToConstant: max(1, canvas.frame.width))
            canvasWidth?.isActive = false
            held.isActive = true
            heldCanvasWidth = held
        } else {
            heldCanvasWidth?.isActive = false
            heldCanvasWidth = nil
            canvasWidth?.isActive = true
        }
    }

    /// Lets go of every row view and every kept page while the pane is out of sight, keeping the
    /// conversation it belongs to, the composer's draft and the queue. Taking the chat back
    /// rebuilds the tail from the newest state, the same way a first open does.
    func releaseRows() {
        guard isParked else { return }
        keptPages = [:]
        keptOrder = []
        sessionRows = [:]
        sessionRowOrder = []
        lastStreamedKey = nil
        stopTailRepair()
        abandoned = nil
        releaseFreshCanvas(animated: false)
        tearDownAllRows()
        placeholderShown = true
    }

    /// The focused pane's frames go first when a frame cannot apply every pane.
    func setFocusedPane(_ focused: Bool) {
        guard focused != isFocusedPane else { return }
        isFocusedPane = focused
        if let state = lastState, !placeholderShown { apply(state: state, rows: lastFullRows) }
        guard let lease, let drainToken else { return }
        TileRuntime.shared.drain.update(drainToken, to: drainSlot(lease))
    }

    /// Whether this pane drains its chat's send queue: a chat in two panes drains from the first.
    var ownsQueue: Bool {
        guard let attachedKey else { return false }
        return TileRuntime.shared.ownsQueue(self, of: attachedKey)
    }

    /// Opens a lifetime generation: one entry that stops every clock this pane may start before
    /// the next `cancelAll`, and the scroll observers.
    func beginLifetime() {
        guard !lifetimeArmed else { return }
        lifetimeArmed = true
        brains.parkViews(false)
        lifetime.add { [weak self] in MainThread.call { self?.releaseClocks() } }
        if isViewLoaded { observeScrolling() }
    }

    /// Every clock, task, monitor and observer the pane may be running, stopped; the lease and the
    /// drain slot go with the lifetime that owns them.
    private func releaseClocks() {
        lifetimeArmed = false
        brains.parkViews(true)
        lease = nil
        drainToken = nil
        attachedKey = nil
        cascade.release()
        stopTailRepair()
        forgetHeldRows()
        tickerTask?.cancel()
        tickerTask = nil
        agentStreamTask?.cancel()
        agentStreamTask = nil
        agentStreamSessionID = nil
        resumeClock?.cancel()
        resumeClock = nil
        retryWake?.cancel()
        retryWake = nil
        captionWake?.cancel()
        captionWake = nil
        handoffWakeGeneration += 1
        stopObservingScrolling()
    }

    /// Hides or shows the pane to its clocks. Parked, it gives up its lease (a turn in flight goes
    /// to the window's watch first) and every clock, and its last rows stay frozen; unparked, it
    /// takes the chat back, and the hub hands it the newest state at once.
    func setParked(_ parked: Bool) {
        guard parked != isParked else { return }
        isParked = parked
        composer.setParked(parked)
        if parked { preview?.park() } else { preview?.unpark() }
        if parked {
            handToWatchIfInFlight()
            lifetime.cancelAll()
            releaseClocks()
            return
        }
        guard let entry else { return }
        onStopWatch?(TileRuntime.key(entry))
        attachLive()
        startResumeClock()
        refreshTurnFacts()
        if !findBar.isHidden, !findIndexed { startFindIndex() }
    }

    /// What a selftest reads to prove a parked or closed pane owns nothing.
    var ownsClocks: Bool {
        lease != nil || drainToken != nil || tickerTask != nil || agentStreamTask != nil
            || resumeClock != nil || retryWake != nil || captionWake != nil || tailRepair != nil
            || holdMonitor != nil || cascade.isLinked || lifetime.count > 0 || scrollObserved
    }

    /// Empties the pane deliberately — a deleted or unresolvable session leaves an explanation,
    /// never a stale transcript that looks alive.
    func resetPane(placeholder: String) {
        shutdownPane()
        conversation = nil
        entry = nil
        backend = nil
        statusBand.resetSlots()
        lastState = nil
        lastFullRows = []
        lastStreamedKey = nil
        stopTailRepair()
        abandoned = nil
        releaseFreshCanvas(animated: false)
        pending.removeAll()
        pendingSignature = "\u{0}"
        pendingStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        composer.isHidden = true
        authGlass?.isHidden = true
        showPlaceholder(placeholder)
        refreshIdentity()
        updateStatus()
    }

    private func beginOpenJourney() {
        if let journey = openJourney { Pace.signposter.endInterval("open", journey.interval) }
        openJourney = (CACurrentMediaTime(), Pace.signposter.beginInterval("open"))
    }

    func endOpenJourney(as kind: StaticString) {
        guard let journey = openJourney else { return }
        openJourney = nil
        Pace.signposter.endInterval("open", journey.interval)
        let elapsed = Int((CACurrentMediaTime() - journey.started) * 1000)
        Pace.log.notice(
            "journey open \(elapsed, privacy: .public)ms \(kind, privacy: .public) rows=\(self.renderedRows.count, privacy: .public)")
    }

    /// A chat opened is shown the moment the rows the window actually holds are up, rather than
    /// once the whole conversation has been built behind them: the tail is one batch, and the
    /// batches above it used to keep the pane blank for half a second while nothing on screen was
    /// waiting for them. Everything that lands above the tail afterwards lands off screen, so the
    /// page is laid out and put back on its end in the same pass as each batch — a pin left to a
    /// later hop would let one frame show the column pushed down by the rows that just arrived.
    func settleOnTail() {
        followsBottom = true
        view.layoutSubtreeIfNeeded()
        pinToBottom()
    }
}
