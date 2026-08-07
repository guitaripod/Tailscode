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
    /// without its closer. How much of what it rendered is actually on screen is the painter's
    /// business, applied to the widget after the diff has built it.
    func pacedByCascade(_ rows: [TranscriptRow], running: Bool) -> [TranscriptRow] {
        let live = running ? rows.last.flatMap { $0.streamedText == nil ? nil : $0 } : nil
        let released = cascade.key
        guard let live, let source = live.streamedText else {
            cascade.release()
            if let released { settleCascade(on: released, in: rows) }
            return rows
        }
        let safe = LiveCascade.renderable(source, sealed: !running)
        var paced = rows
        let row = safe == source ? live : live.truncated(to: safe)
        paced[paced.count - 1] = row
        guard let markup = Self.cascadeMarkup(for: row) else {
            cascade.release()
            if let released { settleCascade(on: released, in: rows) }
            return rows
        }
        cascade.focus(
            row.key, markup: markup, sealed: !running,
            ultracode: auraActive || ultracodeInFlight, clock: transcriptBox)
        lastStreamedKey = row.key
        if let released, released != cascade.key { settleCascade(on: released, in: paced) }
        return paced
    }

    /// One frame of the wave, painted into the live row's own label. The markup is parsed once by
    /// the shim and cached, so a frame is a substring and an attribute list — never a markdown
    /// parse and never a widget rebuild, which is what lets a selection survive the sentence it is
    /// in being written.
    func paintCascade() {
        guard let key = cascade.key, !placeholderShown, !renderedRows.isEmpty else { return }
        let index = renderedRows.count - 1
        guard index < rowWidgets.count, renderedRows[index].key == key,
            let raw = UnsafeMutableRawPointer(bitPattern: rowWidgets[index]),
            let label = Self.streamedLabel(in: ptr(raw), kind: renderedRows[index].kind),
            let markup = Self.cascadeMarkup(for: renderedRows[index])
        else { return }
        cascade.paint(label, markup: markup)
        if followsBottom { scrollToBottom() }
    }
}
