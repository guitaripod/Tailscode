import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension ChatPane {
    /// The rendering path, shaped around what a person is looking at: tail-first fill, chunked
    /// backfill on idle, widget reuse for every row whose identity survived, and a follow decision
    /// that is the person's, not the scrollbar's. `renderedRows` is always a contiguous slice of
    /// the applied row list that reaches its end.
    ///
    /// Every consumer of a row list here assumes each key names one row: the anchor search below
    /// takes the first key it finds, `enteredRows` is a set, and `context.expanded` is keyed by the
    /// same string. A duplicate is therefore not a cosmetic problem but a torn tail on every
    /// arrival, so a build that produces one says so where it is produced rather than being
    /// diagnosed later from the flicker.
    func applyRows(_ rows: [TranscriptRow], appended: Int = 0) {
        Trace.mark("applyRows begin \(rows.count) rendered=\(renderedRows.count)")
        defer { Trace.mark("applyRows end") }
        stampLiveClock()
        assert(
            Set(rows.map(\.key)).count == rows.count,
            "transcript rows share a key: "
                + Dictionary(grouping: rows, by: \.key).filter { $0.value.count > 1 }
                    .keys.sorted().joined(separator: ", "))
        if updatedLastRowInPlace(rows) { return }
        if pointerHeld, !placeholderShown, fillComplete {
            let first = heldRows == nil
            heldRows = rows
            if first {
                Gtk.after(Self.pointerHoldCeiling) { [weak self] in
                    Gtk.onMain { [weak self] in self?.releasePointer() }
                }
            }
            return
        }
        let initialFill = placeholderShown
        if placeholderShown {
            Gtk.removeChildren(of: transcriptBox)
            forgetRowWidgets()
            placeholderShown = false
            currentPlaceholder = nil
            gtk_widget_set_opacity(transcriptBox, 0)
            pendingReveal = true
        }
        // A canvas holding a prompt at the top is not a page to pin to its own bottom, and the
        // first fill of a chat opened on a message it is about to send is exactly that page.
        // A canvas *holding* a prompt at the top is not a page to pin to its own bottom. A canvas
        // that has only been asked for is: until the prompt can be measured and the rise happens,
        // the newest thing on the page is the message just sent, and it belongs on screen.
        let stick = (initialFill || followsBottom) && !canvasPinned
        let chunk = firstFillRows()

        var start = 0
        if !renderedRows.isEmpty {
            var anchor: (rendered: Int, row: Int)?
            if let head = renderedRows.first?.key, let index = rows.firstIndex(where: { $0.key == head }) {
                anchor = (0, index)
            } else {
                var indexByKey = [String: Int](minimumCapacity: rows.count)
                for (index, row) in rows.enumerated() where indexByKey[row.key] == nil {
                    indexByKey[row.key] = index
                }
                for (rendered, row) in renderedRows.enumerated() {
                    if let index = indexByKey[row.key] {
                        anchor = (rendered, index)
                        break
                    }
                }
            }
            if let anchor {
                for _ in 0..<anchor.rendered { removeRowWidget(at: 0) }
                start = anchor.row
            } else {
                tearDownAllRows()
            }
        }

        if renderedRows.isEmpty {
            start = max(0, rows.count - chunk)
            appendRowWidgets(rows[start...])
        } else {
            reconcileRows(with: rows, from: start)
        }

        let tailDone = start + renderedRows.count >= rows.count
        if tailDone, start > 0, !initialFill {
            let from = max(0, start - FillTurns.chunk(level: CascadeBudget.level))
            holdingThePlace {
                var previous: UnsafeMutablePointer<GtkWidget>?
                var bits: [UInt] = []
                for row in rows[from..<start] {
                    let widget = row.makeWidget(context: context)
                    gtk_box_insert_child_after(ptr(transcriptBox), widget, previous)
                    previous = widget
                    bits.append(UInt(bitPattern: widget))
                }
                renderedRows.insert(contentsOf: rows[from..<start], at: 0)
                rowWidgets.insert(contentsOf: bits, at: 0)
                markGaps(from: 0)
                applyGaps()
                enteredRows.formUnion(rows[from..<start].lazy.map(\.key))
            }
            start = from
        }

        applyGaps()
        let complete = tailDone && start == 0
        fillComplete = complete
        openTimer.rows(renderedRows.count, drawnIn: ptr(transcriptBox))
        if complete { openTimer.filled(renderedRows.count) }
        if !complete {
            if stick { followsBottom = true }
            if !isFillingInChunks {
                isFillingInChunks = true
                FillTurns.take(
                    on: root, owner: self,
                    urgent: { [weak self] in self?.pageNeedsRows ?? false }
                ) { [weak self] in
                    guard let self else { return }
                    self.isFillingInChunks = false
                    guard !self.isParked else { return }
                    if let state = self.lastState {
                        self.apply(state: state, rows: self.lastFullRows)
                    } else {
                        let limit = self.rowLimit
                        let rows = self.lastFullRows
                        self.applyRows(rows.count > limit ? Array(rows.suffix(limit)) : rows)
                    }
                }
            }
        }

        if stick { scrollToBottom() }
        syncJumpPill()
        if complete, gtk_widget_get_visible(findBar) != 0 { runFind(retarget: false) }
    }

    /// A press the toolkit never finishes — a gesture claimed and then dropped without a cancel —
    /// must not stop the transcript for the rest of the turn. Long enough that no click reaches it.
    static let pointerHoldCeiling: UInt32 = 1200

    func releasePointer() {
        pointerHeld = false
        let replacements = heldReplacements
        heldReplacements = []
        if let rows = heldRows {
            heldRows = nil
            applyRows(rows)
        }
        guard !replacements.isEmpty else { return }
        replaceRows { replacements.contains($0.key) }
    }

    func reconcileRows(with rows: [TranscriptRow], from start: Int) {
        let window = start == 0 ? rows : Array(rows[start...])
        let steady =
            renderedRows.count == window.count
            && zip(renderedRows, window).allSatisfy { $0.key == $1.key }
        if !steady {
            let plan = RowDiff.plan(from: renderedRows.map(\.key), to: window.map(\.key))
            if !plan.isOrderPreserving {
                for index in plan.removals.reversed() { removeRowWidget(at: index) }
                for index in plan.insertions { insertRowWidget(window[index], at: index) }
            }
        }
        guard renderedRows.count == window.count else {
            tearDownAllRows()
            appendRowWidgets(window[...])
            return
        }
        for index in renderedRows.indices where renderedRows[index] != window[index] {
            if renderedRows[index].chatClass != window[index].chatClass { markGaps(from: index) }
            renderedRows[index] = window[index]
            if restatedPending(at: index) || restatedBrain(at: index) { continue }
            rebuildRow(at: index)
        }
    }

    /// A brain whose turn moved on keeps its widget: the head and the line are restated in place.
    func restatedBrain(at index: Int) -> Bool {
        guard case .brain(let brain) = renderedRows[index].kind, index < rowWidgets.count,
            let raw = UnsafeMutableRawPointer(bitPattern: rowWidgets[index]),
            let view = BrainView.current(of: ptr(raw))
        else { return false }
        view.restate(brain)
        return true
    }

    /// A pending row whose send moved phase keeps its widget: the ink fills in on it.
    func restatedPending(at index: Int) -> Bool {
        guard case .pendingSend(let send, let plan) = renderedRows[index].kind,
            index < rowWidgets.count,
            let raw = UnsafeMutableRawPointer(bitPattern: rowWidgets[index])
        else { return false }
        return TranscriptRow.restatePending(on: ptr(raw), send: send, plan: plan)
    }

    func appendRowWidgets(_ rows: ArraySlice<TranscriptRow>) {
        markGaps(from: renderedRows.count)
        for row in rows {
            let widget = row.makeWidget(context: context)
            gtk_box_append(ptr(transcriptBox), widget)
            rowWidgets.append(UInt(bitPattern: widget))
            renderedRows.append(row)
            noteEntrance(of: widget, for: row)
        }
    }

    /// A row arriving somewhere other than the end, put in the box between the neighbours it will
    /// have. The insertions are applied in ascending order, so everything before this index is
    /// already the row it should be and the widget before it is the one to insert after.
    func insertRowWidget(_ row: TranscriptRow, at index: Int) {
        guard index <= rowWidgets.count else { return }
        let widget = row.makeWidget(context: context)
        let previous: UnsafeMutablePointer<GtkWidget>? =
            index > 0
            ? UnsafeMutableRawPointer(bitPattern: rowWidgets[index - 1]).map { ptr($0) } : nil
        gtk_box_insert_child_after(ptr(transcriptBox), widget, previous)
        rowWidgets.insert(UInt(bitPattern: widget), at: index)
        renderedRows.insert(row, at: index)
        markGaps(from: index)
        noteEntrance(of: widget, for: row)
    }

    func removeRowWidget(at index: Int) {
        guard index < rowWidgets.count, index < renderedRows.count else { return }
        let bits = rowWidgets[index]
        if bits == highlightedRow { clearFindHighlight() }
        if entranceInFlight[renderedRows[index].key] == bits {
            entranceInFlight[renderedRows[index].key] = nil
        }
        CascadeEntrance.cancel(bits)
        if let raw = UnsafeMutableRawPointer(bitPattern: bits) {
            gtk_box_remove(ptr(transcriptBox), ptr(raw) as UnsafeMutablePointer<GtkWidget>)
        }
        rowWidgets.remove(at: index)
        renderedRows.remove(at: index)
        markGaps(from: index)
    }

    /// One row's widget remade where it stands, which is the whole answer to a row whose value
    /// changed and whose identity did not: it keeps its place in the box, its neighbours are not
    /// touched, and a fade it was still in the middle of is carried across rather than restarted or
    /// left running on the widget being thrown away.
    /// The moment this pass reads its live rows at. It belongs to the pass rather than to the row:
    /// a row that read the wall clock as it was built would time an agent against whoever is
    /// looking, which is exactly the reading `AgentHold` exists to refuse.
    func stampLiveClock() { context.liveNow = Date() }

    func rebuildRow(at index: Int) {
        guard index < rowWidgets.count, index < renderedRows.count,
            let raw = UnsafeMutableRawPointer(bitPattern: rowWidgets[index])
        else { return }
        if rowWidgets[index] == highlightedRow { clearFindHighlight() }
        let key = renderedRows[index].key
        let carried = takeEntrance(of: rowWidgets[index], for: key)
        let old: UnsafeMutablePointer<GtkWidget> = ptr(raw)
        let previous: UnsafeMutablePointer<GtkWidget>? =
            index > 0
            ? UnsafeMutableRawPointer(bitPattern: rowWidgets[index - 1]).map { ptr($0) } : nil
        gtk_box_remove(ptr(transcriptBox), old)
        let widget = renderedRows[index].makeWidget(context: context)
        gtk_box_insert_child_after(ptr(transcriptBox), widget, previous)
        rowWidgets[index] = UInt(bitPattern: widget)
        markGaps(from: index)
        if let carried { beginEntrance(of: widget, for: key, delay: 0, from: carried) }
    }

    /// Whether a row appearing on screen fades in, and when it may start.
    ///
    /// The stagger belongs to the pane rather than to the batch a row happened to arrive in. Given
    /// a position within one slice, a state carrying seven rows starts the last of them a third of
    /// a second out while the next state's first row starts immediately — so a newer row below is
    /// readable while the gap above it is still blank. Queued against one clock the batches simply
    /// follow each other, and the ceiling keeps a burst from staggering for two seconds.
    func noteEntrance(of widget: UnsafeMutablePointer<GtkWidget>, for row: TranscriptRow) {
        let firstSight = enteredRows.insert(row.key).inserted
        guard !placeholderShown, !pendingReveal, fillComplete, followsBottom, firstSight,
            row.announcesArrival, row.key != cascade.key
        else { return }
        let now = CascadePainter.now
        let at = min(max(now, nextEntranceAt), now + StreamCascade.entranceCeiling)
        nextEntranceAt = at + StreamCascade.entranceStep
        beginEntrance(of: widget, for: row.key, delay: at - now)
    }

    func beginEntrance(
        of widget: UnsafeMutablePointer<GtkWidget>, for key: String, delay: Double,
        from opacity: Double = 0
    ) {
        let bits = UInt(bitPattern: widget)
        entranceInFlight[key] = bits
        CascadeEntrance.animate(widget, delay: delay, from: opacity) { [weak self] in
            guard let self, self.entranceInFlight[key] == bits else { return }
            self.entranceInFlight[key] = nil
        }
    }

    /// How far into its entrance a row had got, and the end of that run. A rebuilt row's old widget
    /// has nothing left to fade in, but the fade does not know that: it goes on setting the opacity
    /// of something detached while the replacement — whose key `enteredRows` has already seen, so
    /// it does not animate — is drawn at full strength. The row pops mid-fade. Handing the opacity
    /// over instead continues the same curve on the new widget.
    func takeEntrance(of bits: UInt, for key: String) -> Double? {
        guard entranceInFlight[key] == bits, let raw = UnsafeMutableRawPointer(bitPattern: bits)
        else { return nil }
        entranceInFlight[key] = nil
        CascadeEntrance.cancel(bits)
        return gtk_widget_get_opacity(ptr(raw) as UnsafeMutablePointer<GtkWidget>)
    }

    func tearDownAllRows() {
        for bits in rowWidgets {
            CascadeEntrance.cancel(bits)
            guard let raw = UnsafeMutableRawPointer(bitPattern: bits) else { continue }
            gtk_box_remove(ptr(transcriptBox), ptr(raw) as UnsafeMutablePointer<GtkWidget>)
        }
        forgetRowWidgets()
    }

    /// Drops everything the pane believes about the widgets it had, for the paths that empty the
    /// transcript box wholesale. The entrance clock goes with them: a queue built up for rows that
    /// no longer exist would delay the first row of whatever fills the pane next.
    ///
    /// This is the single answer to "the pane no longer has these rows", so every ledger keyed by a
    /// row key is emptied here rather than by the caller that happened to notice. `enteredRows` is
    /// the one that matters: its keys are `messageID:partID`, unique per session, so a pane that
    /// only ever cleared it on the teardown path grew the set for the life of the window — a chat
    /// switch reaches `showPlaceholder` or the placeholder branch of `applyRows`, and neither of
    /// those tears rows down, because the box was already emptied.
    func forgetRowWidgets() {
        messageBar.dismiss()
        rails.dismiss()
        hoverVerbs = nil
        hoverOwners.removeAll(keepingCapacity: true)
        renderedRows = []
        rowWidgets = []
        gapsDirtyFrom = 0
        highlightedRow = 0
        enteredRows.removeAll(keepingCapacity: true)
        entranceInFlight.removeAll(keepingCapacity: true)
        nextEntranceAt = 0
    }

    /// Disk first, tailnet second: a picture this machine has ever shown comes back in one frame.
    /// The read and the decode go through the device-wide gate and land in the device-wide store
    /// (`PictureLoader`), downsampled — the transcript shows a reference, not the original, and the
    /// original costs megabytes of VRAM a bubble has no use for. The gallery decodes the original
    /// itself, one page at a time. Asking again for a picture that is on its way, or that failed a
    /// moment ago, costs nothing, so every rebuild of every row may ask.
    func fetchImage(_ reference: FileReference, key: String, urgent: Bool = false) {
        PictureLoader.request(
            reference, key: key, backend: backend, urgent: urgent, rank: rowIndex(showing: key))
    }

    /// Where in the transcript a picture is drawn, so the decode gate serves the newest rows
    /// first — the end of the conversation is what is on screen when a chat opens. A row not
    /// built yet is the newest thing there is.
    func rowIndex(showing key: String) -> Int {
        let at = renderedRows.lastIndex { row in
            if row.key == key { return true }
            guard case .pictures(let pictures) = row.kind else { return false }
            return pictures.contains { $0.key == key }
        }
        return at ?? .max
    }

    /// A picture landing in the store, from whichever pane asked for it. Landings are gathered
    /// and the rows that show them are redrawn once, because a transcript of a hundred pictures
    /// opening used to rebuild the whole page once per picture: one pass over the union costs the
    /// same however many landed in the window, and a row with several pictures is built once.
    func pictureLanded(_ key: String) {
        landedPictures.insert(key)
        guard !landingFlushPending else { return }
        landingFlushPending = true
        let window: UInt32 = CascadeBudget.level >= .loaded ? 160 : 50
        Gtk.after(window) { [weak self] in
            Gtk.onMain { [weak self] in self?.flushLandedPictures() }
        }
    }

    func flushLandedPictures() {
        landingFlushPending = false
        let keys = landedPictures
        landedPictures = []
        guard !keys.isEmpty, !placeholderShown else { return }
        let shows: (TranscriptRow) -> Bool = { row in
            if keys.contains(row.key) { return true }
            guard case .pictures(let pictures) = row.kind else { return false }
            return pictures.contains { keys.contains($0.key) }
        }
        guard renderedRows.contains(where: shows) else { return }
        replaceRows(where: shows)
    }

    /// A workflow's runs, rebuilt from the transcript and the live fan-out. Only the cards whose
    /// run actually changed are replaced: a run reports every second and a full rebuild of the
    /// transcript for a spinner frame is a flicker.
    func refreshWorkflowRuns() {
        guard let state = lastState else { return }
        let runs = workflowFold.runs(messages: state.messages, agents: agents)
        if runs != workflowRuns {
            var byCall: [String: WorkflowRun] = [:]
            for run in runs { byCall[run.id] = run }
            let stale = Set(
                byCall.keys.filter { context.workflowRuns[$0] != byCall[$0] }
                    + context.workflowRuns.keys.filter { byCall[$0] == nil })
            workflowRuns = runs
            context.workflowRuns = byCall
            refreshWorkflowCards(stale)
        }
        updateTicker(running: state.status == .running)
    }

    /// A changed run is written into the card it already has; only a card whose structure no
    /// longer matches — an agent appeared, the result landed — is rebuilt, and only that card.
    /// A rebuild destroys the widget under the pointer and the click that was in flight with it,
    /// so it is the exception, never the once-a-second path.
    func refreshWorkflowCards(_ ids: Set<String>) {
        guard !ids.isEmpty, !placeholderShown else { return }
        var rebuilt: Set<String> = []
        for index in renderedRows.indices {
            guard case .workflow(let call) = renderedRows[index].kind, ids.contains(call.id),
                index < rowWidgets.count,
                let raw = UnsafeMutableRawPointer(bitPattern: rowWidgets[index])
            else { continue }
            if !WorkflowCardView.restate(ptr(raw), call: call, context: context) {
                rebuilt.insert(renderedRows[index].key)
            }
        }
        if !rebuilt.isEmpty { replaceRows { rebuilt.contains($0.key) } }
    }

    /// Whether anything on screen still needs a clock: a turn in flight, a workflow that outlived
    /// it, a compaction counting up, or a pending send whose caption ages. A background run keeps
    /// four agents working for minutes after the turn that launched it ended, and a card whose
    /// elapsed reading froze at launch reads as a hang.
    var needsTicker: Bool {
        lastState?.status == .running
            || lastState?.compaction?.isRunning == true
            || workflowRuns.contains(where: \.isLive)
            || (!pending.isEmpty && !resume.isEmpty)
    }

    /// The clock every live reading in this transcript is drawn against, moved once a second so
    /// spinners turn and elapsed readings climb without a state event. Only a live workflow is
    /// restated for it: everything else on the clock is redrawn by the pass that changed it, and
    /// rebuilding a transcript once a second to age one label is a frame nobody asked for.
    func advanceLiveClock() {
        stampLiveClock()
        guard workflowRuns.contains(where: \.isLive) else { return }
        let live = Set(workflowRuns.filter(\.isLive).map(\.id))
        refreshWorkflowRuns()
        refreshWorkflowCards(live)
    }

    func fetchWorkflowAgent(_ agentID: String) {
        guard let backend, let entry, !inFlightSubagents.contains(agentID) else { return }
        inFlightSubagents.insert(agentID)
        let sessionID = entry.session.id
        track(Task { [weak self] in
            let messages =
                (try? await backend.subagentMessages(sessionID: sessionID, agentID: agentID)) ?? []
            let rows = TranscriptRow.rows(for: messages)
            Gtk.onMain { [weak self] in
                guard let self, self.sessionID == sessionID else { return }
                self.inFlightSubagents.remove(agentID)
                self.context.subagentRows[WorkflowAgentRows.key(agentID)] = rows
                self.replaceRows {
                    guard case .workflow(let call) = $0.kind else { return false }
                    return self.context.workflowRuns[call.id]?.agents
                        .contains { $0.id == agentID } ?? true
                }
            }
        })
    }

    func fetchSubagent(_ call: ToolCall) {
        guard let backend, let entry,
            !inFlightSubagents.contains(call.id)
        else { return }
        inFlightSubagents.insert(call.id)
        let sessionID = entry.session.id
        track(Task { [weak self] in
            let agents = (try? await backend.subagents(for: sessionID)) ?? []
            let match = agents.first { $0.toolUseID == call.id }
            let messages: [ChatMessage]
            if let match {
                messages = (try? await backend.subagentMessages(
                    sessionID: sessionID, agentID: match.id)) ?? []
            } else {
                messages = []
            }
            let rows = TranscriptRow.rows(for: messages)
            let callID = call.id
            Gtk.onMain { [weak self] in
                guard let self, self.sessionID == sessionID else { return }
                self.context.subagentRows[callID] = rows
                self.replaceRows {
                    switch $0.kind {
                    case .subagent(let spawned): return spawned.id == callID
                    case .subagentGroup(let members):
                        return members.contains { $0.call.id == callID }
                    default: return false
                    }
                }
            }
        })
    }
}
