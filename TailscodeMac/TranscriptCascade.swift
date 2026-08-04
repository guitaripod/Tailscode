import AppKit
import TailscodeCore

extension TranscriptViewController {
    /// The row the agent is writing into, revealed at reading speed rather than in whatever lumps
    /// the network delivered. Only the last row can be live — anything after it is proof the
    /// stream has moved on — and only prose and code grow a character at a time, so a tool call
    /// landing after a paragraph settles that paragraph rather than freezing it half-written.
    ///
    /// The row is held at its markdown-safe prefix so the renderer never sees `**bold` without its
    /// closer; how much of what it rendered is on screen is the painter's business, applied to the
    /// label after the diff has built it.
    func pacedByCascade(_ rows: [TranscriptRow], running: Bool) -> [TranscriptRow] {
        cascade.host = view
        let live = running ? rows.last.flatMap { $0.streamedText == nil ? nil : $0 } : nil
        let released = cascade.key
        guard let live, let source = live.streamedText else {
            cascade.release()
            if let released { settleCascade(on: released, in: rows) }
            return rows
        }
        let safe = LiveCascade.renderable(source, sealed: !running)
        var paced = rows
        let row = safe == source ? live : live.held(to: safe)
        paced[paced.count - 1] = row
        cascade.focus(
            row.key, rendered: row.renderedText ?? "", sealed: !running,
            ultracode: composer.auraActive)
        if let released, released != cascade.key { settleCascade(on: released, in: paced) }
        return paced
    }

    /// One frame of the wave, painted into the live row's own label instead of through the row
    /// diff: the text a person is reading must not be torn down and rebuilt a hundred times a
    /// second, or a selection cannot survive the sentence it is in being written.
    func paintCascade() {
        guard let key = cascade.key, !placeholderShown, !renderedRows.isEmpty else { return }
        let index = renderedRows.count - 1
        guard index < rowViews.count, renderedRows[index].key == key,
            let label = Self.streamedLabel(in: rowViews[index], kind: renderedRows[index].kind),
            let tail = cascade.tail(for: key)
        else { return }
        switch renderedRows[index].kind {
        case .agentProse(_, let rendered):
            label.attributedStringValue = tail.paint(rendered, settled: MacTheme.Color.label)
        case .codeBlock(_, let body):
            label.attributedStringValue = tail.paint(
                Self.codeRendering(body), settled: MacTheme.Color.label)
        default:
            return
        }
        if followsBottom { scrollToBottom() }
    }
}
