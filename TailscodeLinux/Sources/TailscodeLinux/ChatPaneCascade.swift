import CAdw
import CodingAgentKit
import CGtkShim
import Foundation
import TailscodeCore

extension ChatPane {
    /// The row the agent is writing into, revealed at reading speed rather than in whatever lumps
    /// the network delivered. Only the last row can be live — anything after it is proof the
    /// stream has moved on — and only the kinds that grow a character at a time qualify, so a tool
    /// call landing after a paragraph settles that paragraph rather than freezing it half-written.
    ///
    /// The row itself is held at its markdown-safe prefix, so the renderer never sees `**bold`
    /// without its closer. A code block is exempt: its punctuation is the language's rather than
    /// markdown's, and judged as markdown it is nothing but unclosed tokens, so it is handed over
    /// as it arrives. How much of what it rendered is actually on screen is the painter's
    /// business, applied to the widget after the diff has built it — and if the painter will not
    /// take the row (reduced motion, markup the parser refuses) the cut goes with it: a prefix
    /// nothing is going to reveal is just an answer with its last words missing.
    func pacedByCascade(_ rows: [TranscriptRow], running: Bool) -> [TranscriptRow] {
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
        let row = safe == source ? live : live.truncated(to: safe)
        paced[paced.count - 1] = row
        guard let markup = Self.cascadeMarkup(for: row) else {
            cascade.release()
            if let released { handOver(released, in: rows) }
            return rows
        }
        cascade.focus(
            row.key, markup: markup, sealed: !running,
            ultracode: auraActive || ultracodeInFlight, clock: transcriptBox)
        guard cascade.key == row.key else {
            if let released { handOver(released, in: rows) }
            return rows
        }
        lastStreamedKey = row.key
        if let released, released != cascade.key { handOver(released, in: paced) }
        return paced
    }

    /// Finishes writing a row the stream has already moved on from.
    ///
    /// The pacer trails what has arrived by design — that is the whole of the smoothing — so at the
    /// moment the agent stops writing a paragraph and goes off to run something, or the turn simply
    /// ends, there are still a couple of hundred characters owed on that row. Letting go there
    /// settles it, and settling hands every one of them over in a single frame: the answer is
    /// written beautifully right up to the seam and the last sentence of it appears at once. An
    /// agent that works calls tools several times a minute, so most of a reply arrived as a hand
    /// and every seam of it as a paste.
    ///
    /// So a row the stream has left is *sealed* rather than let go. Nothing more is coming, so the
    /// gate stops holding it against a closer that will never arrive and the buffer drains at the
    /// end-of-turn cadence; the wave comes off only once the reveal has actually reached the end,
    /// which is the ordinary release path one state later. Taking a row up and letting go of it
    /// were already two different moments — this is the other way a row stops being written, and it
    /// now obeys the same rule.
    ///
    /// Returns whether the wave is still on the row. A row that has caught up, one given up as
    /// stalled, and one the transcript no longer holds all say no, and the caller lets go exactly
    /// as before.
    private func drainStrandedCascade(in rows: [TranscriptRow]) -> Bool {
        guard let key = cascade.key, cascade.owes, key != abandoned,
            let row = rows.last(where: { $0.key == key })
                ?? lastFullRows.last(where: { $0.key == key }),
            let source = row.streamedText,
            let markup = Self.cascadeMarkup(for: row)
        else { return false }
        _ = cascade.renderable(row: key, source, sealed: true, markdown: row.streamsMarkdown)
        cascade.focus(
            key, markup: markup, sealed: true, ultracode: auraActive || ultracodeInFlight,
            clock: transcriptBox)
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
    func reopenGatedCascade() -> Bool {
        guard let key = cascade.key,
            let row = lastFullRows.last(where: { $0.key == key }),
            let source = row.streamedText
        else { return false }
        let sealed = lastState?.status != .running
        let safe = cascade.renderable(
            row: key, source, sealed: sealed, markdown: row.streamsMarkdown)
        let held = safe == source ? row : row.truncated(to: safe)
        guard let markup = Self.cascadeMarkup(for: held),
            let rendered = CascadePainter.renderedText(of: markup),
            rendered.unicodeScalars.count > cascade.revealed
        else { return false }
        cascade.focus(
            key, markup: markup, sealed: sealed, ultracode: auraActive || ultracodeInFlight,
            clock: transcriptBox)
        guard cascade.key == key else { return false }
        lastStreamedKey = key
        paintCascade()
        return true
    }

    /// The wave letting go of a row, made good. A settle that could not be made here is put on the
    /// repair clock rather than dropped: this is the last state the pane will see for a turn that
    /// just ended, and the wave has already given up the frame clock it would have needed.
    private func handOver(_ key: String, in rows: [TranscriptRow]) {
        if settleCascade(on: key, in: rows) {
            if lastStreamedKey == key { lastStreamedKey = nil }
            return
        }
        scheduleTailRepair(on: key)
    }

    /// One frame of the wave, painted into the live row's own label. The markup is the one the
    /// painter was pointed at when the stream last moved, so a frame is a substring and an
    /// attribute list — never a markdown parse, never a fresh copy of the answer, and never a
    /// widget rebuild, which is what lets a selection survive the sentence it is in being written.
    ///
    /// Returns whether the words are where the row says they are. Painting in place is a promise
    /// made to the diff — the row is marked rendered and left alone — so every reason this can fail
    /// (the row is gone, its widget with it, the label is not where a row of that kind keeps its
    /// words) is a promise the pane has to know it cannot keep.
    ///
    /// The row is found by its key rather than taken to be the last one. It usually is the last
    /// one — only the last row can be *taken up* — but a row the stream has moved on from goes on
    /// being written while a tool call sits below it, and assuming the bottom of the transcript
    /// would refuse every one of those frames and leave the drain to the watchdog.
    @discardableResult
    func paintCascade() -> Bool {
        guard let key = cascade.key, !placeholderShown, !renderedRows.isEmpty,
            let index = renderedRows.lastIndex(where: { $0.key == key })
        else { return false }
        guard index < rowWidgets.count,
            let raw = UnsafeMutableRawPointer(bitPattern: rowWidgets[index]),
            let label = Self.streamedLabel(in: ptr(raw), kind: renderedRows[index].kind)
        else { return false }
        guard cascade.paint(label) else { return false }
        if canvasPromptKey != nil {
            settleFreshCanvas()
        } else if followsBottom {
            pinToBottom()
        }
        return true
    }
}
