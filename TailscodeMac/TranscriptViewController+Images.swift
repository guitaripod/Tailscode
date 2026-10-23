import AppKit
import os
import CodingAgentKit
import TailscodeCore

extension TranscriptViewController {
    /// Whether a row draws the pixels cached under `key`: the picture's own row, or the gallery a
    /// group of agent pictures rests in.
    private func rowHolds(_ row: TranscriptRow, _ key: String) -> Bool {
        if row.key == key { return true }
        guard case .pictures(let pictures) = row.kind else { return false }
        return pictures.contains { $0.key == key }
    }

    /// A row with no picture yet says so as it is built; whether those bytes are worth crossing the
    /// tailnet for right now is the transcript's call rather than the row's.
    func noteImageWanted(_ reference: FileReference, key: String) {
        guard ImageStore.shared.entry(forKey: key) == nil else { return }
        wantedImages[key] = reference
        scheduleImageSweep()
    }

    /// Rows leaving the stack take their unmet picture requests with them, wherever they leave from
    /// — a plan's removals, a window sliding, the tail being handed back to be redrawn.
    ///
    /// A want the transcript declined because its row was off screen must not become a fetch the
    /// moment that row falls out of the window: there is nothing left to paint it into, and the
    /// bytes would cross the tailnet for a picture nobody can see. Pruning is also what lets an
    /// absent key keep its one honest meaning in the sweep — a row the flow never rendered at all,
    /// which is a picture inside a card somebody has just opened. A row that comes back asks again
    /// as it is built, so nothing is lost by forgetting.
    func forgetWantedImages(_ rows: some Sequence<TranscriptRow>) {
        guard !wantedImages.isEmpty else { return }
        for row in rows {
            wantedImages.removeValue(forKey: row.key)
            guard case .pictures(let pictures) = row.kind else { continue }
            for picture in pictures { wantedImages.removeValue(forKey: picture.key) }
        }
    }

    /// Coalesced to once a runloop hop: a sweep costs a layout pass and a scroll delivers its
    /// notification many times a frame.
    func scheduleImageSweep() {
        guard !imageSweepScheduled, !wantedImages.isEmpty else { return }
        imageSweepScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.imageSweepScheduled = false
            self.sweepWantedImages()
        }
    }

    /// Pictures fetch themselves when a reader is within a screen of them, and not before. A
    /// placeholder is a fixed frame and the thumbnail that replaces it is the picture's own shape,
    /// so every image in a four-hundred-row transcript decoding on the first fill is four hundred
    /// height changes, most of them above whoever has scrolled back. A key the flow does not render
    /// is inside a card somebody has just opened — opening it *was* the request — so those are
    /// fetched at once rather than waited on, which holds only because a row that leaves takes its
    /// want with it (`forgetWantedImages`) and so cannot arrive here wearing a card's meaning.
    private func sweepWantedImages() {
        guard !wantedImages.isEmpty, !placeholderShown else { return }
        view.layoutSubtreeIfNeeded()
        let clip = scrollView.contentView
        let margin = max(clip.bounds.height, 400)
        let top = clip.bounds.origin.y - margin
        let bottom = clip.bounds.origin.y + clip.bounds.height + margin
        var reach: [String: Bool] = [:]
        for (index, row) in renderedRows.enumerated()
        where index < rowViews.count && wantedImages.keys.contains(where: { rowHolds(row, $0) }) {
            let frame = rowViews[index].convert(rowViews[index].bounds, to: canvas)
            let onScreen = frame.maxY >= top && frame.minY <= bottom
            for key in wantedImages.keys where rowHolds(row, key) {
                reach[key] = onScreen
            }
        }
        let ready = wantedImages.filter { reach[$0.key] ?? true }
        for (key, reference) in ready {
            wantedImages.removeValue(forKey: key)
            fetchImage(reference, key: key)
        }
    }

    /// What the turn is waiting on, docked where the CLI's prompt would sit: approvals first,
    /// then questions. Rebuilt only when what is pending actually changes — this runs on every
    /// streamed token, and cards that flicker under a click swallow the click.
    func renderPendingCards(_ state: ConversationState) {
        let compactionKey = state.compaction.map {
            $0.failure ?? "compacting:\($0.startedAt.timeIntervalSince1970):\(pending.hasInFlight)"
        } ?? ""
        let signature =
            (state.pendingPermissions.map(\.id) + state.pendingQuestions.map(\.id))
            .joined(separator: "|") + "|" + compactionKey
        guard signature != pendingSignature else { return }
        pendingSignature = signature
        compactingElapsed = nil
        pendingStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for permission in state.pendingPermissions {
            pendingStack.addArrangedSubview(
                PendingCards.permission(
                    permission,
                    keys: { [weak self] id in
                        (self?.view.window?.windowController as? MainWindowController)?
                            .shortcutKeys(for: id)
                    }
                ) { [weak self] decision in
                    self?.respond(to: permission, decision: decision)
                })
        }
        for question in state.pendingQuestions {
            pendingStack.addArrangedSubview(
                PendingCards.question(question, in: entry) { [weak self] answers in
                    self?.answer(question, answers: answers)
                })
        }
        if let compaction = state.compaction {
            if let failure = compaction.failure {
                pendingStack.addArrangedSubview(PendingCards.compactionFailure(failure))
            } else {
                pendingStack.addArrangedSubview(
                    PendingCards.compacting(
                        startedAt: compaction.startedAt, waiting: pending.hasInFlight
                    ) { [weak self] label in
                        self?.compactingElapsed = label
                    })
            }
        }
        syncJumpPill()
        if followsBottom { schedulePinCorrector() }
    }

    /// The running card's own clock line, moved by the transcript's one-second ticker rather than
    /// a rebuild — the card must hold still while its wait counts up.
    func updateCompactingElapsed() {
        guard let label = compactingElapsed,
            let compaction = lastState?.compaction, compaction.isRunning
        else { return }
        label.stringValue = CompactionStory.elapsedLine(startedAt: compaction.startedAt)
    }

    /// Disk first, tailnet second: a picture this machine has ever shown comes back in one frame,
    /// and only a genuinely new one crosses the network — then joins the cache. The decode
    /// happens off the main actor, because a large PNG decoded on the UI loop is a visible freeze.
    ///
    /// A picture stays asked-for only while it is on its way. Once it lands the memory cache owns
    /// it, and that cache is shared by every pane and bounded — a picture it lets go is asked for
    /// again from disk when its row next wants it, rather than sitting on an empty frame until the
    /// chat is reopened.
    func fetchImage(_ reference: FileReference, key: String) {
        guard !inFlightImages.contains(key), !refusedImages.contains(key) else { return }
        inFlightImages.insert(key)
        let backend = backend
        Task { [weak self] in
            var data = await Task.detached { ImageDisk.load(reference) }.value
            if data == nil, let backend {
                data = try? await backend.attachmentData(reference)
                if let fetched = data {
                    await Task.detached { ImageDisk.save(fetched, for: reference) }.value
                }
            }
            var decoded: DecodedImage?
            if let bytes = data {
                decoded = await Task.detached { ImageStore.decode(bytes) }.value
            }
            guard let self else { return }
            self.inFlightImages.remove(key)
            guard let decoded else {
                guard data != nil else { return }
                self.refusedImages.insert(key)
                self.replaceRows { self.rowHolds($0, key) }
                return
            }
            ImageStore.shared.store(decoded, forKey: key)
            self.replaceRows { self.rowHolds($0, key) }
        }
    }

    func fetchSubagent(_ call: ToolCall) {
        guard let backend, let entry, !inFlightSubagents.contains(call.id) else { return }
        inFlightSubagents.insert(call.id)
        let sessionID = entry.session.id
        Task { [weak self] in
            let agents = (try? await backend.subagents(for: sessionID)) ?? []
            let match = agents.first { $0.toolUseID == call.id }
            let messages: [ChatMessage]
            if let match {
                messages =
                    (try? await backend.subagentMessages(
                        sessionID: sessionID, agentID: match.id)) ?? []
            } else {
                messages = []
            }
            guard let self else { return }
            let rows = TranscriptRow.rows(for: messages)
            let callID = call.id
            self.context.subagentRows[callID] = rows
            self.replaceRows { $0.kind.spawnedCalls.contains { $0.id == callID } }
        }
    }
}
