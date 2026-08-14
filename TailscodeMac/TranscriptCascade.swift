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
    /// (the live row is not the last one rendered, its view is gone, the label is not where a row
    /// of that kind keeps its words) is a promise the transcript has to know it cannot keep.
    @discardableResult
    func paintCascade() -> Bool {
        guard let key = cascade.key, !placeholderShown, !renderedRows.isEmpty else { return false }
        let index = renderedRows.count - 1
        guard index < rowViews.count, renderedRows[index].key == key,
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
