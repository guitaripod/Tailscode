import TailscodeCore
import CodingAgentKit
import UIKit

extension ChatViewController {
    /// One frame of the wave. The live row is repainted in place: the paragraph is measured once
    /// when its text arrives and never again, so a frame that only moves colours — the reveal and
    /// the band both — never touches the data source or the layout, and the transcript cannot
    /// jump under the reader. Only a row with no cell on screen falls back to a reconfigure.
    ///
    /// That fallback is charged for, so it is asked for only when it can pay. The band moves every
    /// frame and the reveal does not, so a row scrolled out of view was answering every frame with
    /// a whole-list snapshot copy and an apply — a hundred and twenty times a second, on the main
    /// thread, against the scroll the reader is doing, and worse the longer the transcript. A frame
    /// that only moved the band has nothing to say to a cell nobody can see.
    ///
    /// And what reports the debt paid is not the branch that painted, it is the absence of anybody
    /// looking. `landed` is the wave's proof that its arithmetic reached a reader, so the question
    /// is whether a reader is being kept waiting: a row with a cell on screen that this frame could
    /// not paint is withholding text from someone and must leave the debt standing for the watchdog,
    /// while a row scrolled out of the visible set is withholding it from nobody — there is nothing
    /// to be missing. Timing the debt against a reveal nobody could see either way is how a second's
    /// scroll away from the live row came back as a stall and handed the answer over whole.
    func repaintCascade(revealMoved: Bool) {
        guard let id = cascade.key else { return }
        let paint = repaintLiveCellInPlace(id)
        if paint != .refused { cascade.landed() }
        if paint != .painted, revealMoved, dataSource.indexPath(for: id) != nil {
            var snapshot = dataSource.snapshot()
            snapshot.reconfigureItems([id])
            dataSource.apply(snapshot, animatingDifferences: false)
        }
        if paint == .painted { followWriting(revealMoved: revealMoved) }
        guard let settled = settleDrainedCascade(), dataSource.indexPath(for: settled) != nil
        else { return }
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems([settled])
        dataSource.apply(snapshot, animatingDifferences: false)
        settledCascadeRows.remove(settled)
    }

    /// The words of the row being written changed and nothing else did: the cell on screen is given
    /// them and asked to be measured again, and the list is not told at all. Telling the list is a
    /// snapshot of every row, a diff, a batch update and a look at every cell on screen, to reach one
    /// paragraph; and none of it can change which cell shows which row, because the order did not move.
    func rewriteLiveTextInPlace(_ id: String) -> Bool {
        guard let path = dataSource.indexPath(for: id),
            let bubble = collectionView.cellForItem(at: path) as? TextBubbleCell,
            let row = rowsByID[id], row.role != .user, case .text(let text) = row.content,
            let tail = cascade.tail(for: id, traits: traitCollection)
        else { return false }
        bubble.applyCascade(tail, text: text, reasoning: false)
        bubble.contentView.invalidateIntrinsicContentSize()
        return true
    }

    /// Whether the turn writing the live row is over, which is not the same question as whether the
    /// app is busy.
    ///
    /// A turn stops being busy for as long as it is waiting on the reader — a permission to run
    /// something, an answer to a question — and the row it was writing is not finished, it is
    /// paused. Sealing there would drain the buffer at the end-of-turn cadence, let the row go, and
    /// then take the same row up again from nothing the moment approval came back: the answer
    /// rewinds under the reader, which is a worse lie than the pause.
    private var turnIsOver: Bool {
        guard !viewModel.isBusy else { return false }
        let state = viewModel.state
        return state.pendingPermissions.isEmpty && state.pendingQuestions.isEmpty
    }

    /// Lets go of the live row once the hand has caught up with it, and says which row that was.
    ///
    /// The end of a turn is not the end of the reveal. The pacer trails what has arrived by design
    /// — that is the whole of the smoothing — so there is always text still owed when the last
    /// characters land, and cutting the wave loose there hands the row over whole in one frame:
    /// every answer ended with half a second of writing appearing at once instead of a hand slowing
    /// to a stop. So the row stays focused, sealed, and drains at the sealed cadence; only when the
    /// reveal has actually reached the end is it handed back.
    @discardableResult
    private func settleDrainedCascade() -> String? {
        guard turnIsOver, cascade.isSettled, let key = cascade.key else { return nil }
        cascade.release()
        if let whole = wholeCascadeRow, whole.id == key { rowsByID[key] = whole }
        wholeCascadeRow = nil
        settledCascadeRows.insert(key)
        return key
    }

    /// The row the agent is writing into, revealed at reading speed rather than in whatever lumps
    /// the network delivered. Only the last row can be live — anything after it is proof the
    /// stream has moved on — and only prose and code grow a character at a time, so a tool call
    /// landing after a paragraph settles that paragraph rather than freezing it half-written.
    ///
    /// The row is held at its markdown-safe prefix so the renderer never sees `**bold` without its
    /// closer; how much of what it rendered is on screen is the cell's business, from the plan the
    /// driver hands it.
    ///
    /// A row is taken up only while its turn is running, and let go of only once the reveal has
    /// caught up with it. Those are two different moments and treating them as one was the whole
    /// bug: the wave was released the instant the turn stopped, which is exactly when the buffer is
    /// fullest, so the last half-second of every answer arrived in a single frame. Reading the last
    /// row unconditionally is what makes the drain possible; refusing to take up a row the wave was
    /// not already on once the turn is over is what keeps a chat opened on finished history from
    /// starting a display link it has nothing to write.
    func paceCascade(_ rows: [ChatRow]) {
        let last = rows.last.flatMap { $0.streamedText == nil ? nil : $0 }
        let live = (turnIsOver && cascade.key != last?.id) ? nil : last
        let released = cascade.key
        if let abandonedCascadeRow, abandonedCascadeRow != live?.id { self.abandonedCascadeRow = nil }
        guard let live, let source = live.streamedText, live.id != abandonedCascadeRow else {
            if drainStrandedCascade(in: rows) { return }
            cascade.release()
            if let released {
                if let whole = wholeCascadeRow, whole.id == released, rowsByID[released] == nil {
                    rowsByID[released] = whole
                }
                wholeCascadeRow = nil
                settledCascadeRows.insert(released)
            }
            return
        }
        let sealed = turnIsOver
        let safe = cascade.renderable(
            row: live.id, source, sealed: sealed, markdown: live.streamsMarkdown)
        let row = safe == source ? live : live.held(to: safe)
        cascade.focus(
            row.id, length: renderedLength(of: row), sealed: sealed, ultracode: cascadeUltracode,
            source: row.streamedText)
        guard cascade.key == row.id else {
            if rowsByID[live.id] != live {
                rowsByID[live.id] = live
                settledCascadeRows.insert(live.id)
            }
            wholeCascadeRow = nil
            if let released, released != live.id { settledCascadeRows.insert(released) }
            return
        }
        wholeCascadeRow = live
        rowsByID[row.id] = row
        if let released, released != cascade.key { settledCascadeRows.insert(released) }
        settleDrainedCascade()
    }

    /// A stall that is only the gate holding is not a stall in the writing.
    ///
    /// The renderer is held at the last position where no inline token is half-open, against a
    /// closer that is a few characters behind — a wait the buffer exists to absorb. But a part ends
    /// where it ends, and a marker that was going to close sometimes never does, so Core stops
    /// waiting after `patience`. It only ever answers that question when a client asks it, and the
    /// one thing that has stopped happening in a stall is text arriving, so nobody asks: the row is
    /// handed over whole and then abandoned for the rest of the turn, and everything the agent
    /// writes after it lands as a paste.
    ///
    /// So the stall asks. If the gate gives up and there are still characters to write, the row goes
    /// on being written — the reveal keeps its place and the wave keeps the row. Only a row with
    /// nothing left to say is given up, which is what the give-up was always for.
    private func reopenGatedCascade(_ key: String) -> Bool {
        guard let whole = wholeCascadeRow, whole.id == key, let source = whole.streamedText,
            dataSource.indexPath(for: key) != nil
        else { return false }
        let sealed = turnIsOver
        let safe = cascade.renderable(
            row: key, source, sealed: sealed, markdown: whole.streamsMarkdown)
        let row = safe == source ? whole : whole.held(to: safe)
        let length = renderedLength(of: row)
        guard length > cascade.revealed else { return false }
        cascade.focus(
            key, length: length, sealed: sealed, ultracode: cascadeUltracode,
            source: row.streamedText)
        guard cascade.key == key else { return false }
        rowsByID[key] = row
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems([key])
        dataSource.apply(snapshot, animatingDifferences: false)
        return true
    }

    /// Finishes writing a row the stream has already moved on from.
    ///
    /// The pacer trails what has arrived by design — that is the whole of the smoothing — so at the
    /// moment the agent stops writing a paragraph and goes off to run something, there are still a
    /// couple of hundred characters owed on it. Letting the row go there hands every one of them
    /// over in a single frame, and that is the same failure the end of a turn used to have, just
    /// moved into the middle: the answer is written beautifully right up until the tool call, and
    /// then its last sentence appears at once. An agent that works calls tools several times a
    /// minute, so in practice most of an answer arrived as a hand and every seam of it as a paste.
    ///
    /// A row the stream has left is therefore *sealed* rather than dropped. Nothing more is coming,
    /// so the gate stops holding it against a closer that will never arrive and the buffer drains at
    /// the end-of-turn cadence; the wave comes off only once the reveal has actually reached the
    /// end. Which is the same rule the end of a turn already keeps — taking a row up and letting go
    /// of it are two different moments — applied to the other way a row stops being written.
    ///
    /// Returns whether the wave is still on the row. A row that has caught up, one that has been
    /// given up as stalled, and one the transcript no longer contains all say no, and the caller
    /// lets go of it exactly as before.
    private func drainStrandedCascade(in rows: [ChatRow]) -> Bool {
        guard let key = cascade.key, cascade.owes, key != abandonedCascadeRow,
            let whole = wholeCascadeRow, whole.id == key, let source = whole.streamedText,
            rows.contains(where: { $0.id == key })
        else { return false }
        let safe = cascade.renderable(
            row: key, source, sealed: true, markdown: whole.streamsMarkdown)
        let row = safe == source ? whole : whole.held(to: safe)
        rowsByID[key] = row
        cascade.focus(
            key, length: renderedLength(of: row), sealed: true, ultracode: cascadeUltracode,
            source: row.streamedText)
        return cascade.owes
    }

    /// Whether the wave paints the unlocked colours: the turn in flight was sent with ultracode on,
    /// or the session is set to the effort ultracode is.
    private var cascadeUltracode: Bool {
        viewModel.ultracodeInFlight || viewModel.currentEffort == Ultracode.effortLevel
    }

    /// Re-measures the live row after a toggle changed how much of it is laid out.
    ///
    /// The reveal counts the characters the cell will actually draw, and a collapsed code block
    /// draws its first fourteen lines. Opening one on the row the wave is holding leaves the reveal
    /// standing at the folded count while the cell now lays out the whole block, and everything past
    /// it is painted clear — the lines the person just asked to see are invisible until some
    /// unrelated state event happens to re-measure the row. During a live stream that is a flicker;
    /// on a turn that has just gone quiet nothing else is coming. A row the wave is not holding has
    /// no reveal to correct.
    func refocusCascade(on id: String) {
        guard cascade.key == id, let row = rowsByID[id] else { return }
        cascade.focus(
            id, length: renderedLength(of: row), sealed: turnIsOver, ultracode: cascadeUltracode,
            source: row.streamedText)
    }

    /// The reveal stopped moving while it still owed the reader text — the display link stopped
    /// being served, or the words stopped arriving. Either way the hand is not coming back, so the
    /// row is given up and shown whole rather than left mid-sentence.
    ///
    /// Given up means for good, for as long as that row is the one being written: taking it back on
    /// the next arrival would start its reveal again from nothing, and an answer that snapped to
    /// whole and then rewound would be a worse lie than the stall.
    func giveUpCascade() {
        guard let key = cascade.key else { return }
        if reopenGatedCascade(key) { return }
        cascade.release()
        abandonedCascadeRow = key
        settledCascadeRows.insert(key)
        if let whole = wholeCascadeRow, whole.id == key { rowsByID[key] = whole }
        wholeCascadeRow = nil
        var snapshot = dataSource.snapshot()
        guard snapshot.itemIdentifiers.contains(key) else {
            scheduleCascadeRepair(key)
            return
        }
        snapshot.reconfigureItems([key])
        dataSource.apply(snapshot, animatingDifferences: false)
        settledCascadeRows.remove(key)
    }

    /// A row the wave let go of that the data source could not be told about, tried again on a
    /// clock of its own.
    ///
    /// Every other road back to a whole row runs through a state arriving, and a turn that has just
    /// ended sends no more states — while the wave gave up its display link and its watchdog in the
    /// same breath. So a hand-back that could not be made at that moment is the last thing anybody
    /// was ever going to try, and the row keeps the prefix for as long as the chat is open.
    private func scheduleCascadeRepair(_ key: String) {
        cascadeRepair?.cancel()
        cascadeRepair = Task { [weak self] in
            for _ in 0..<6 {
                try? await Task.sleep(for: .milliseconds(320))
                guard !Task.isCancelled, let self, self.cascade.key != key else { return }
                var snapshot = self.dataSource.snapshot()
                guard snapshot.itemIdentifiers.contains(key) else { continue }
                snapshot.reconfigureItems([key])
                await self.dataSource.apply(snapshot, animatingDifferences: false)
                self.settledCascadeRows.remove(key)
                return
            }
        }
    }

    /// What one frame of the wave managed to do with the live row.
    ///
    /// The two ways of painting nothing are not the same failure and must not be answered the same
    /// way. `unseen` is a row the transcript is holding whose cell is not in the visible set: it owes
    /// the reader nothing, because there is no reader on it. `refused` is every other silence — a
    /// cell on screen that would not take the frame, a row the wave is pointed at that the data
    /// source does not have — and those are exactly what the stall watchdog exists to catch, so they
    /// leave the debt standing.
    private enum CascadePaint {
        case painted
        case unseen
        case refused
    }

    /// One frame of the wave over the cell where it stands, so the data source never hears about
    /// a colour change. Anything but `painted` falls the caller back to the data source.
    private func repaintLiveCellInPlace(_ id: String) -> CascadePaint {
        guard let indexPath = dataSource.indexPath(for: id) else { return .refused }
        guard let cell = collectionView.cellForItem(at: indexPath) else { return .unseen }
        guard let tail = cascade.tail(for: id, traits: traitCollection), let row = rowsByID[id] else { return .refused }
        switch (row.content, cell) {
        case (.text(let text), let bubble as TextBubbleCell):
            bubble.applyCascade(tail, text: text, reasoning: false)
            return .painted
        case (.code(let block), let code as CodeBlockCell):
            code.applyCascade(tail, block: block, expanded: expandedReasoning.contains(id))
            return .painted
        default:
            return .refused
        }
    }

    /// What the reveal counts: the characters a reader will actually see, markers already eaten by
    /// the renderer whose output the cell will show — measured in UTF-16 code units, because that
    /// is what `CascadeTail` indexes the cell's storage by. Counting graphemes here and slicing
    /// UTF-16 there is one number apart per emoji, and the row's last characters stay painted clear
    /// for good while the pacer reports it settled.
    ///
    /// A collapsed code block is counted at what it actually lays out, not at what it holds:
    /// counting the whole source of a block showing its first fourteen lines spends the reveal on
    /// characters the cell will never draw, and the wave reports itself finished while the reader
    /// is still most of the block behind.
    private func renderedLength(of row: ChatRow) -> Int {
        switch row.content {
        case .text(let text):
            return TextBubbleCell.rendered(text, color: Theme.Color.label).length
        case .code(let block):
            let laidOut = CodeBlockCell.laidOut(
                block.source, expanded: expandedReasoning.contains(row.id))
            return CodeBlockCell.highlightedCode(laidOut.text, language: block.language).length
        default:
            return 0
        }
    }
}
