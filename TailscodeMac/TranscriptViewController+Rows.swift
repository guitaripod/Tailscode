import AppKit
import os
import CodingAgentKit
import TailscodeCore

extension TranscriptViewController {
    /// The rendering path, shaped around what a person is looking at. On first paint the tail —
    /// the rows the window actually shows — goes up immediately, and everything earlier backfills
    /// above it one chunk per pass, so a huge conversation is readable in one frame instead of
    /// after a ten-chunk climb. Once it is up, every row whose key survives keeps its view — and its
    /// disclosure state, its selection, its scroll cost — wherever the edit moved it, and a token
    /// appended to the last message rebuilds one row, not the conversation.
    ///
    /// `renderedRows` is always a contiguous slice of the applied row list that reaches its end;
    /// where that slice starts is re-found by key on every pass, because the window slides.
    /// A streamed token changes exactly one row, and rebuilding its view for every arrival is what
    /// makes a live answer flicker: the label is torn down and remade dozens of times a second,
    /// which restarts its entrance, drops any selection inside it, and asks the whole column to lay
    /// out again. When the only difference is more words in a row that can take them where it
    /// stands — the answer the painter is holding, or a thought counting itself up — the change is
    /// written into the view and the bookkeeping moves with it. Preview cards docked under the
    /// paragraph being written are the paragraph's own and do not make it any less the last row.
    ///
    /// A painter with no hands on the row is served here too, and settles it whole. Reduce Motion
    /// releases the wave on every arrival, so demanding the painter hold the row would send the one
    /// row a person is reading down the rebuild path dozens of times a second — the very flicker
    /// this exists to prevent, on the machine that asked for less movement.
    private func updatedLastRowInPlace(_ rows: [TranscriptRow]) -> Bool {
        guard !placeholderShown, fillComplete,
            renderedRows.count == rows.count,
            let last = rows.lastIndex(where: { !$0.isLinkRail }), last > 0,
            renderedRows[last].key == rows[last].key, renderedRows[last] != rows[last],
            last < rowViews.count,
            renderedRows.prefix(last).elementsEqual(rows.prefix(last)),
            renderedRows.suffix(from: last + 1).elementsEqual(rows.suffix(from: last + 1))
        else { return false }
        switch (renderedRows[last].kind, rows[last].kind) {
        case (.brain, .brain(let brain)):
            guard let view = rowViews[last] as? BrainRowView else { return false }
            view.restate(brain)
            renderedRows[last] = rows[last]
            if followsBottom { scrollToBottom() }
            return true
        case (.agentProse, .agentProse), (.codeBlock, .codeBlock):
            let painting = cascade.isActive
            guard rows[last].key == cascade.key || !painting else { return false }
            let previous = renderedRows[last]
            renderedRows[last] = rows[last]
            guard painting ? paintCascade() : settleCascade(on: rows[last].key, in: rows) else {
                renderedRows[last] = previous
                return false
            }
            if !painting, followsBottom { scrollToBottom() }
            return true
        case (.reasoning, .reasoning(let text)):
            guard let disclosure = rowViews[last] as? DisclosureRow else { return false }
            context.liveReasoning[rows[last].key] = text
            disclosure.restate(header: ToolRowView.thoughtHeader(text))
            disclosure.restateBody(text)
        default:
            return false
        }
        renderedRows[last] = rows[last]
        if followsBottom { scrollToBottom() }
        return true
    }

    /// Forgets everything the transcript believes about the row the wave was painting and the rows
    /// after it, so the next fill cannot compare them equal and skip them. The words are the
    /// transcript's own, so nothing is refetched — only redrawn.
    ///
    /// Redrawn means the whole list `apply` draws, docked turn included. This clock is the path a
    /// failed settle takes, which is the path a turn cut off mid-stream takes — so rebuilding from
    /// the echo alone would delete the account of the interruption, with its resume and its dismiss,
    /// at exactly the moment it was written, and a turn that ended sends no state to put it back.
    func rebuildStreamedTail(from key: String) {
        guard !placeholderShown, let index = renderedRows.lastIndex(where: { $0.key == key }),
            index < rowViews.count
        else { return }
        for viewToDrop in rowViews[index...] {
            if viewToDrop === highlightedView { clearFindHighlight() }
            viewToDrop.removeFromSuperview()
        }
        forgetWantedImages(renderedRows[index...])
        rowViews.removeSubrange(index...)
        renderedRows.removeSubrange(index...)
        let limit = rowLimit
        let rows = lastState.map { docked(echoed(lastFullRows), state: $0) } ?? echoed(lastFullRows)
        applyRows(rows.count > limit ? Array(rows.suffix(limit)) : rows)
    }

    /// How many rows go up in one runloop hop while a fill is still climbing, and the size of edit
    /// past which an arrival is treated as a fill rather than as growth.
    private static let rowChunk = 40

    func applyRows(_ rows: [TranscriptRow]) {
        assert(
            Set(rows.map(\.key)).count == rows.count,
            "the transcript handed one key to two rows")
        if updatedLastRowInPlace(rows) { return }
        if pointerHeld, !placeholderShown, fillComplete {
            holdRows(rows)
            return
        }
        let initialFill = placeholderShown
        if placeholderShown {
            tearDownAllRows()
            placeholderShown = false
            currentPlaceholder = nil
            hideEmptyState()
            canvas.alphaValue = 0
            pendingReveal = true
        }
        let stick = (initialFill || followsBottom) && canvasHold == nil

        let edit = preservingScroll { editRows(rows) }
        repaintChangedRows(rows, from: edit.start)
        if canvasHold != nil { recomputeFreshCanvas() }
        fillComplete = edit.complete
        let revealing = pendingReveal && edit.start + renderedRows.count >= rows.count
        if !edit.complete {
            if stick { followsBottom = true }
            if !isFillingInChunks {
                isFillingInChunks = true
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.isFillingInChunks = false
                    if let state = self.lastState {
                        self.apply(state: state, rows: self.lastFullRows)
                    } else {
                        let limit = self.rowLimit
                        let rows = self.echoed(self.lastFullRows)
                        self.applyRows(rows.count > limit ? Array(rows.suffix(limit)) : rows)
                    }
                }
            }
        }

        if stick {
            if revealing || !edit.complete {
                settleOnTail()
            } else {
                setFollowing(true)
            }
            schedulePinCorrector()
        }
        if revealing {
            pendingReveal = false
            canvas.alphaValue = 1
            endOpenJourney(as: "tail")
        }
        syncJumpPill()
        scheduleImageSweep()
        hoverBar.refresh()
        railController.rowsChanged()
        if edit.complete, !findBar.isHidden { runFind(retarget: false) }
    }

    /// A press this window never sees the end of — a drag that left the app, an up a sheet
    /// swallowed — must not stop the transcript for the rest of the turn. Long enough that no
    /// click reaches it.
    private static let pointerHoldCeiling: TimeInterval = 1.2

    /// Whether a button is down on this window. A press elsewhere on the desk is somebody else's
    /// gesture and holds nothing here.
    var pointerHeld: Bool {
        NSEvent.pressedMouseButtons != 0 && view.window?.isKeyWindow == true
    }

    private func holdRows(_ rows: [TranscriptRow]) {
        heldRows = rows
        watchPointer()
    }

    /// Arms the release once per press: the monitor that fires it, and the ceiling that fires it
    /// for a press this window never sees the end of.
    func watchPointer() {
        guard holdMonitor == nil else { return }
        holdMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseUp, .rightMouseUp, .otherMouseUp]
        ) { [weak self] event in
            DispatchQueue.main.async {
                DispatchQueue.main.async { [weak self] in self?.releasePointer() }
            }
            return event
        }
        holdGeneration += 1
        let generation = holdGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.pointerHoldCeiling) { [weak self] in
            guard let self, self.holdGeneration == generation else { return }
            self.releasePointer()
        }
    }

    /// The release is taken two runloop hops after the mouse-up rather than inside it: the monitor
    /// sees the event before the window dispatches it, and rebuilding the row there would tear down
    /// the header the click is about to land on; the click's own reveal is queued one hop out, and
    /// the row it names must still be the one on screen when it runs.
    private func releasePointer() {
        stopWatchingPointer()
        let replacements = heldReplacements
        heldReplacements = []
        if let rows = heldRows {
            heldRows = nil
            applyRows(rows)
        }
        guard !replacements.isEmpty else { return }
        replaceRows { replacements.contains($0.key) }
    }

    /// What a chat switch does with a held arrival: drops it. The rows belong to the conversation
    /// that produced them, and applying them into the one that replaced it would put a stranger's
    /// turn on screen.
    func forgetHeldRows() {
        stopWatchingPointer()
        heldRows = nil
    }

    private func stopWatchingPointer() {
        if let holdMonitor { NSEvent.removeMonitor(holdMonitor) }
        holdMonitor = nil
        holdGeneration += 1
    }

    /// What has to happen to the rows on screen for them to become `rows`, and whether that leaves
    /// the whole list showing. Also where the rendered slice starts inside `rows`, which is zero for
    /// everything except a fill that is still climbing.
    ///
    /// The steady state diffs by *key*. A row's identity says whether it is the same row; its value
    /// says only whether it needs repainting, and conflating the two is what used to make one
    /// changed row mid-window cost every row below it — `placeBoard` promotes only the last board
    /// call, so every TodoWrite update reverts a row dozens of positions back and tore the tail off
    /// after it. A backfill is still a fill: rows arriving above everything on screen when the
    /// window widens cannot become four hundred views inside one frame.
    private func editRows(_ rows: [TranscriptRow]) -> (complete: Bool, start: Int) {
        guard fillComplete, !renderedRows.isEmpty else { return fillRowsInChunks(rows) }
        let plan = RowDiff.plan(from: renderedRows.map(\.key), to: rows.map(\.key))
        if isBackfill(plan) { return fillRowsInChunks(rows) }
        applyPlan(plan, to: rows)
        return (true, 0)
    }

    /// Whether an edit is better spread over runloop hops than carried out whole — which is a
    /// question about *where* the rows land, never about how many of them there are. The widening
    /// window is the shape worth chunking: several hundred rows arrive above everything on screen,
    /// nothing already up moves, and the climb costs a chunk of view builds a hop instead of the
    /// whole backfill inside one frame.
    ///
    /// It is also the only shape the chunked fill can express without damage. Its walk stops at the
    /// first key that disagrees and tears off every row below that point, so a row arriving — or
    /// leaving — from *between* two rows that stay would collapse and regrow the entire tail under
    /// it, which is precisely what the keyed diff exists to have stopped. Survivors that are
    /// contiguous on both sides are exactly the promise that nothing lands between them; counting
    /// insertions instead was the same mistake in a new place, because forty-one rows appearing in
    /// the middle of a transcript are not a fill.
    ///
    /// A list with no survivor at all is a fill by definition — every row on screen is going either
    /// way — so a big one climbs rather than building itself inside one frame.
    private func isBackfill(_ plan: RowDiff.Plan) -> Bool {
        guard let first = plan.survivors.first, let last = plan.survivors.last else {
            return plan.insertions.count > Self.rowChunk
        }
        let span = plan.survivors.count - 1
        guard last.old - first.old == span, last.new - first.new == span else { return false }
        return plan.insertions.prefix(while: { $0 < first.new }).count > Self.rowChunk
    }

    /// The plan carried out against the stack: removals from the back, so every index still ahead of
    /// the cursor keeps meaning what it meant, then insertions from the front, which is the order
    /// the plan is stated in. Nothing here repaints — a row whose key survived keeps the view it
    /// already has, and whatever its value now says is written into that view afterwards.
    private func applyPlan(_ plan: RowDiff.Plan, to rows: [TranscriptRow]) {
        guard !plan.isOrderPreserving else { return }
        for index in plan.removals.reversed() where index < rowViews.count {
            let doomed = rowViews[index]
            if doomed === highlightedView { clearFindHighlight() }
            doomed.removeFromSuperview()
            forgetWantedImages([renderedRows[index]])
            rowViews.remove(at: index)
            renderedRows.remove(at: index)
        }
        let entering = rowsAnnounceArrival
        for index in plan.insertions {
            let row = rows[index]
            let rowView = row.makeView(context: context)
            let at = min(index, rowViews.count)
            rowColumn.insertArrangedSubview(
                rowView, at: at, spacing: row.spacing)
            rowViews.insert(rowView, at: at)
            renderedRows.insert(row, at: at)
            let firstSight = enteredRows.insert(row.key).inserted
            if entering, firstSight, row.key != cascade.key, row.announcesArrival {
                CascadeEntrance.animate(rowView)
            }
        }
    }

    /// The first fill and the widening window. A transcript of four thousand rows goes up as the
    /// tail the window actually shows, and everything earlier backfills above it a chunk per runloop
    /// hop, so it is readable in one frame instead of after a ten-chunk climb. The walk matches by
    /// key rather than by value: a row whose words changed while the fill was climbing keeps its
    /// place and is repainted after, instead of taking the rest of the fill down with it.
    private func fillRowsInChunks(_ rows: [TranscriptRow]) -> (complete: Bool, start: Int) {
        let chunk = Self.rowChunk
        var start = 0
        if !renderedRows.isEmpty {
            var indexByKey = [String: Int](minimumCapacity: rows.count)
            for (index, row) in rows.enumerated() where indexByKey[row.key] == nil {
                indexByKey[row.key] = index
            }
            var anchor: (rendered: Int, row: Int)?
            for (rendered, row) in renderedRows.enumerated() {
                if let index = indexByKey[row.key] {
                    anchor = (rendered, index)
                    break
                }
            }
            if let anchor {
                for viewToDrop in rowViews[..<anchor.rendered] {
                    if viewToDrop === highlightedView { clearFindHighlight() }
                    viewToDrop.removeFromSuperview()
                }
                forgetWantedImages(renderedRows[..<anchor.rendered])
                rowViews.removeSubrange(..<anchor.rendered)
                renderedRows.removeSubrange(..<anchor.rendered)
                start = anchor.row
            } else {
                tearDownAllRows()
            }
        }

        if renderedRows.isEmpty {
            start = max(0, rows.count - chunk)
            appendRowViews(rows[start...])
        } else {
            var same = 0
            while same < renderedRows.count, start + same < rows.count,
                renderedRows[same].key == rows[start + same].key
            {
                same += 1
            }
            for viewToDrop in rowViews[same...] {
                if viewToDrop === highlightedView { clearFindHighlight() }
                viewToDrop.removeFromSuperview()
            }
            forgetWantedImages(renderedRows[same...])
            rowViews.removeSubrange(same...)
            renderedRows.removeSubrange(same...)
            let tailFrom = start + renderedRows.count
            let tailEnd = min(rows.count, tailFrom + chunk)
            appendRowViews(rows[tailFrom..<tailEnd])
        }

        let tailDone = start + renderedRows.count >= rows.count
        if tailDone, start > 0 {
            let from = max(0, start - chunk)
            var position = 0
            var inserted: [NSView] = []
            for row in rows[from..<start] {
                let rowView = row.makeView(context: context)
                rowColumn.insertArrangedSubview(
                    rowView, at: position, spacing: row.spacing)
                inserted.append(rowView)
                enteredRows.insert(row.key)
                position += 1
            }
            renderedRows.insert(contentsOf: rows[from..<start], at: 0)
            rowViews.insert(contentsOf: inserted, at: 0)
            start = from
        }
        return (tailDone && start == 0, start)
    }

    /// Where the key survived but the value did not. Repainting happens where the row stands — the
    /// alternative is removing the view and putting another one back, which is what restarts an
    /// entrance, drops a selection inside the row and asks the whole column to lay out again.
    private func repaintChangedRows(_ rows: [TranscriptRow], from start: Int) {
        var stale: Set<String> = []
        for index in renderedRows.indices {
            let source = start + index
            guard source >= 0, source < rows.count, renderedRows[index] != rows[source] else {
                continue
            }
            renderedRows[index] = rows[source]
            if case .pendingSend(let send, let plan, let now) = rows[source].kind,
                index < rowViews.count, let held = rowViews[index] as? PendingSendRowView
            {
                held.restate(send: send, plan: plan, now: now)
                continue
            }
            if case .brain(let brain) = rows[source].kind, index < rowViews.count,
                let held = rowViews[index] as? BrainRowView
            {
                held.restate(brain)
                continue
            }
            stale.insert(rows[source].key)
        }
        guard !stale.isEmpty else { return }
        replaceRows { stale.contains($0.key) }
    }

    /// Whether a row arriving now is arriving in front of somebody: the transcript is built and
    /// visible, and they are at the bottom, where new rows land. Anything else is a fill or a
    /// backfill — the transcript coming into existence rather than growing — and fading that in is a
    /// flicker with no event behind it.
    private var rowsAnnounceArrival: Bool {
        !placeholderShown && !pendingReveal && fillComplete && followsBottom
    }

    private func appendRowViews(_ rows: ArraySlice<TranscriptRow>) {
        let entering = rowsAnnounceArrival
        for row in rows {
            let rowView = row.makeView(context: context)
            rowColumn.addArrangedSubview(rowView, spacing: row.spacing)
            let firstSight = enteredRows.insert(row.key).inserted
            if entering, firstSight, row.key != cascade.key, row.announcesArrival {
                CascadeEntrance.animate(rowView)
            }
            rowViews.append(rowView)
            renderedRows.append(row)
        }
    }

    /// The wave letting go of a row is not the same as the row being rebuilt. A turn that simply
    /// ends leaves the rows identical, so the diff has nothing to do and the last glyphs would keep
    /// the heat of a stream that stopped — the row has to be handed back whole by hand.
    ///
    /// Whole means the row's own words, which is what the transcript last received and never what
    /// the pacer handed the label: the paced copy is cut at the last position where no markdown
    /// token is half-open, and settling from it would bake that cut into the finished answer.
    /// Returns whether the row is now whole, so a repair that could not be made is not mistaken for
    /// one that was.
    @discardableResult
    func settleCascade(on key: String, in rows: [TranscriptRow]) -> Bool {
        guard let index = renderedRows.lastIndex(where: { $0.key == key }),
            index < rowViews.count,
            let label = Self.streamedLabel(in: rowViews[index], kind: renderedRows[index].kind)
        else { return false }
        let row =
            lastFullRows.last(where: { $0.key == key })
            ?? rows.last(where: { $0.key == key })
            ?? renderedRows[index]
        switch row.kind {
        case .agentProse(_, let rendered):
            label.attributedStringValue = rendered
        case .codeBlock(let language, let body):
            label.attributedStringValue = Self.codeRendering(body, language: language)
        default:
            return false
        }
        return true
    }

    /// A code block's body as the row already draws it — lexed by the shared highlighter in this
    /// theme's colours — so the wave tints the same glyphs the settled row shows rather than
    /// flattening them on its way past. A flat rendering here is not a frame's worth of drift: the
    /// settled row then equals what was painted, the diff finds nothing to repaint, and every block
    /// written under the reader's eyes stays monochrome beside coloured blocks loaded from history.
    ///
    /// The last rendering is kept because the wave asks for one every frame, and lexing a block that
    /// is still growing at the display's rate is the one cost this path cannot carry. Exactly one
    /// row is ever live, so one entry answers every ask.
    static func codeRendering(_ body: String, language: String?) -> NSAttributedString {
        if let memo = codeMemo, memo.body == body, memo.language == language {
            return memo.rendering
        }
        let font = MacTheme.Ramp.font(.code)
        let rendering: NSAttributedString
        if SyntaxHighlighter.isDiff(language) {
            rendering = RowKit.diffAttributed(body, font: font)
        } else {
            let lexed = NSMutableAttributedString(
                string: body,
                attributes: [.font: font, .foregroundColor: MacTheme.Color.label])
            for token in SyntaxHighlighter.tokens(body, language: language) {
                let range = NSRange(location: token.offset, length: token.length)
                guard NSMaxRange(range) <= lexed.length else { continue }
                lexed.addAttribute(
                    .foregroundColor, value: MacTheme.Color.syntax(token.role), range: range)
            }
            rendering = lexed
        }
        codeMemo = (body, language, rendering)
        return rendering
    }

    static var codeMemo:
        (body: String, language: String?, rendering: NSAttributedString)?

    /// Where a live row keeps the words: prose is the label itself, a code block keeps its body
    /// under the header and behind a scroller once it is tall enough to need one.
    static func streamedLabel(in view: NSView, kind: TranscriptRow.Kind) -> NSTextField? {
        switch kind {
        case .agentProse:
            return view as? NSTextField
        case .codeBlock:
            guard let stack = view as? NSStackView,
                let last = stack.arrangedSubviews.last
            else { return nil }
            if let field = last as? NSTextField { return field }
            return (last as? NSScrollView)?.documentView as? NSTextField
        default:
            return nil
        }
    }
}
