import AppKit
import TailscodeCore

extension TranscriptViewController {
    /// The row the agent is writing into, revealed at reading speed rather than in whatever lumps
    /// the network delivered. Only the last row can be live — anything after it is proof the
    /// stream has moved on — and only prose and code grow a character at a time, so a tool call
    /// landing after a paragraph settles that paragraph rather than freezing it half-written.
    ///
    /// A prose row is held at its markdown-safe prefix so the renderer never sees `**bold` without
    /// its closer; a code row is not held at all, because the gate reads markdown and code's
    /// punctuation is its own language's. How much of what was rendered is on screen is the
    /// painter's business, applied to the label after the diff has built it.
    func pacedByCascade(_ rows: [TranscriptRow], running: Bool) -> [TranscriptRow] {
        cascade.host = view
        let live = running ? rows.last.flatMap { $0.streamedText == nil ? nil : $0 } : nil
        let released = cascade.key
        if let abandoned, abandoned != live?.key { self.abandoned = nil }
        guard let live, let source = live.streamedText, live.key != abandoned else {
            if drainStrandedCascade(in: rows) { return rows }
            cascade.release()
            if let released { handOver(released, in: rows) }
            return rows
        }
        let safe = cascade.renderable(
            row: live.key, source, sealed: !running, markdown: live.streamsMarkdown)
        var paced = rows
        let row = safe == source ? live : live.held(to: safe)
        paced[paced.count - 1] = row
        cascade.focus(
            row.key, length: Self.renderedLength(of: row), sealed: !running,
            ultracode: composer.auraActive)
        guard cascade.key == row.key else {
            if let released { handOver(released, in: rows) }
            return rows
        }
        lastStreamedKey = row.key
        if let released, released != cascade.key { handOver(released, in: paced) }
        return paced
    }

    /// What the reveal counts, measured in the units `CascadeTail` indexes the label's storage by:
    /// UTF-16 code units. Counting graphemes here and slicing UTF-16 there is one number apart per
    /// emoji, and the row's last characters stay painted clear for good while the pacer reports it
    /// settled.
    static func renderedLength(of row: TranscriptRow) -> Int {
        switch row.kind {
        case .agentProse(_, let rendered): return rendered.length
        case .codeBlock(let language, let body):
            return codeRendering(body, language: language).length
        default: return 0
        }
    }

    /// Finishes writing a row the stream has already moved on from.
    ///
    /// The pacer trails what has arrived by design — that is the whole of the smoothing — so at the
    /// moment the agent stops writing a paragraph and goes off to run something, or the turn simply
    /// ends, there are still a couple of hundred characters owed on that row. Letting go there
    /// settles it, and settling hands every one of them over in a single frame: the answer is
    /// written beautifully right up to the seam and its last sentence appears at once. An agent that
    /// works calls tools several times a minute, so most of a reply arrived as a hand and every seam
    /// of it as a paste.
    ///
    /// So a row the stream has left is *sealed* rather than let go. Nothing more is coming, so the
    /// gate stops holding it against a closer that will never arrive and the buffer drains at the
    /// end-of-turn cadence; the wave comes off only once the reveal has actually reached the end.
    /// Taking a row up and letting go of it were already two different moments — this is the other
    /// way a row stops being written, and it now obeys the same rule.
    ///
    /// Returns whether the wave is still on the row. A row that has caught up, one given up as
    /// stalled, and one the transcript no longer holds all say no, and the caller lets go exactly
    /// as before.
    private func drainStrandedCascade(in rows: [TranscriptRow]) -> Bool {
        guard let key = cascade.key, cascade.owes, key != abandoned,
            let row = rows.last(where: { $0.key == key })
                ?? lastFullRows.last(where: { $0.key == key }),
            let source = row.streamedText
        else { return false }
        _ = cascade.renderable(row: key, source, sealed: true, markdown: row.streamsMarkdown)
        cascade.focus(
            key, length: Self.renderedLength(of: row), sealed: true,
            ultracode: composer.auraActive)
        guard cascade.key == key, cascade.owes else { return false }
        lastStreamedKey = key
        return true
    }

    /// A stall that is only the gate holding is not a stall in the writing.
    ///
    /// The renderer is held at the last position where no inline token is half-open, against a
    /// closer that is a few characters behind — a wait the buffer exists to absorb. But a part ends
    /// where it ends, and a marker that was going to close sometimes never does, so Core stops
    /// waiting after its patience. It only ever answers that question when a client asks it, and
    /// the one thing that has stopped happening in a stall is text arriving, so nobody asks: the
    /// row was handed over whole and then abandoned for the rest of the turn, which made every
    /// later part of that answer land as a paste too.
    ///
    /// So the stall asks. If the gate gives up and there are still characters to write, the row
    /// goes on being written. Only a row with nothing left to say is given up, which is what the
    /// give-up was always for.
    private func reopenGatedCascade() -> Bool {
        guard let key = cascade.key,
            let row = lastFullRows.last(where: { $0.key == key }),
            let source = row.streamedText
        else { return false }
        let sealed = lastState?.status != .running
        let safe = cascade.renderable(
            row: key, source, sealed: sealed, markdown: row.streamsMarkdown)
        let held = safe == source ? row : row.held(to: safe)
        let length = Self.renderedLength(of: held)
        guard length > cascade.revealed else { return false }
        cascade.focus(key, length: length, sealed: sealed, ultracode: composer.auraActive)
        guard cascade.key == key else { return false }
        lastStreamedKey = key
        paintCascade()
        return true
    }

    /// The wave letting go of a row, made good. A settle that could not be made here is put on the
    /// repair clock rather than dropped: this is the last state the transcript will see for a turn
    /// that just ended, and the wave has already given up the display link it would have needed.
    private func handOver(_ key: String, in rows: [TranscriptRow]) {
        if settleCascade(on: key, in: rows) {
            if lastStreamedKey == key { lastStreamedKey = nil }
            return
        }
        scheduleTailRepair(on: key)
    }

    /// A row that stopped being written ends up whole, whatever the wave was doing when it let go.
    ///
    /// Settling is normally the release path's job, but that path can only settle the row the
    /// painter still holds: a key that changed as the message completed, a view rebuilt between
    /// frames, a turn that ended in the same update its last words arrived in, or a painter that
    /// declined the row all leave it holding nothing. So the transcript remembers the row the wave
    /// last had its hands on and hands it back the first state where the wave is no longer on it —
    /// which is any state at all, not only one that says the turn is over. A stream that simply
    /// stops sending never says that, and the rows are equal by then, so the diff sees nothing to
    /// do and nothing else would ever put the rest of the sentence back.
    func settleStreamedTail(in rows: [TranscriptRow]) {
        guard let key = lastStreamedKey, key != cascade.key else { return }
        if settleCascade(on: key, in: rows) || !lastFullRows.contains(where: { $0.key == key }) {
            lastStreamedKey = nil
            return
        }
        scheduleTailRepair(on: key)
    }

    /// A settle that could not be made, tried again on a clock of its own.
    ///
    /// Every other road back to a whole row runs through a state arriving: the diff, the release
    /// path, the tail settle. A turn that has just ended sends no more states, and the wave let go
    /// of its display link and its watchdog in the same breath — so a settle that failed at exactly
    /// that moment is the last thing anybody was ever going to try, and the row keeps the prefix
    /// for as long as the chat is open. This is the clock nothing else can take down.
    ///
    /// It gives up on being polite before it gives up on the reader: three refusals and the row's
    /// bookkeeping is thrown away so the ordinary diff has to build it again from the words the
    /// transcript actually holds.
    func scheduleTailRepair(on key: String) {
        repairKey = key
        guard tailRepair == nil else { return }
        var attempts = 0
        tailRepair = Timer.scheduledTimer(withTimeInterval: 0.32, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let key = self.repairKey, key != self.cascade.key else {
                    self.stopTailRepair()
                    return
                }
                if self.settleCascade(on: key, in: self.lastFullRows) {
                    if self.lastStreamedKey == key { self.lastStreamedKey = nil }
                    self.stopTailRepair()
                    return
                }
                attempts += 1
                guard attempts >= 3 else { return }
                self.stopTailRepair()
                if self.lastStreamedKey == key { self.lastStreamedKey = nil }
                self.rebuildStreamedTail(from: key)
            }
        }
    }

    func stopTailRepair() {
        tailRepair?.invalidate()
        tailRepair = nil
        repairKey = nil
    }

    /// The reveal stopped moving while it still owed the reader text — the display link died under
    /// it, or the words stopped arriving. Either way the hand is not coming back, so the row is
    /// given up and shown whole rather than left mid-sentence.
    ///
    /// Given up means for good, for as long as that row is the one being written: taking it back on
    /// the next arrival would start its reveal again from nothing, and an answer that snapped to
    /// whole and then rewound would be a worse lie than the stall.
    func giveUpCascade() {
        if reopenGatedCascade() { return }
        let key = cascade.key ?? lastStreamedKey
        cascade.release()
        abandoned = key
        lastStreamedKey = key
        guard let key else { return }
        if settleCascade(on: key, in: lastFullRows) {
            lastStreamedKey = nil
        } else {
            scheduleTailRepair(on: key)
        }
    }

    /// One frame of the wave, painted into the live row's own label instead of through the row
    /// diff: the text a person is reading must not be torn down and rebuilt a hundred times a
    /// second, or a selection cannot survive the sentence it is in being written.
    ///
    /// Returns whether the words are where the row says they are. Painting in place is a promise
    /// made to the diff — the row is marked rendered and left alone — so every reason this can fail
    /// (the row is gone, its view with it, the label is not where a row of that kind keeps its
    /// words) is a promise the transcript has to know it cannot keep.
    ///
    /// The row is found by its key rather than taken to be the last one. It usually is the last one
    /// — only the last row can be *taken up* — but a row the stream has moved on from goes on being
    /// written while a tool call sits below it, and assuming the bottom of the transcript would
    /// refuse every one of those frames and leave the drain to the watchdog.
    @discardableResult
    func paintCascade() -> Bool {
        guard let key = cascade.key, !placeholderShown, !renderedRows.isEmpty,
            let index = renderedRows.lastIndex(where: { $0.key == key })
        else { return false }
        guard index < rowViews.count,
            let label = Self.streamedLabel(in: rowViews[index], kind: renderedRows[index].kind),
            let tail = cascade.tail(for: key)
        else { return false }
        switch renderedRows[index].kind {
        case .agentProse(_, let rendered):
            label.attributedStringValue = tail.paint(rendered, settled: MacTheme.Color.label)
        case .codeBlock(let language, let body):
            label.attributedStringValue = tail.paint(
                Self.codeRendering(body, language: language), settled: MacTheme.Color.label)
        default:
            return false
        }
        cascade.landed()
        if followsBottom { scrollToBottom() }
        return true
    }
}
