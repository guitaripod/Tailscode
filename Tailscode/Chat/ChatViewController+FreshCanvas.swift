import MidgarCore
import TailscodeCore
import UIKit

extension ChatViewController {
    /// The prompt block's frame, first row through last, from the rows the canvas is holding.
    /// When the rows it was holding have left the list — the server's account has replaced them —
    /// it looks once for the rows that replaced them, and only lets go when there are none.
    private func canvasPromptFrame() -> CGRect? {
        guard !canvasPromptIDs.isEmpty else { return nil }
        if let frame = unionFrame(of: canvasPromptIDs) { return frame }
        guard let replacement = serverRows(replacing: canvasPromptIDs),
            let frame = unionFrame(of: replacement)
        else { return nil }
        canvasPromptIDs = replacement
        return frame
    }

    private func unionFrame(of ids: [String]) -> CGRect? {
        var union: CGRect?
        for id in ids {
            guard let indexPath = dataSource.indexPath(for: id),
                let attributes = collectionView.layoutAttributesForItem(at: indexPath)
            else { continue }
            union = union.map { $0.union(attributes.frame) } ?? attributes.frame
        }
        return union
    }

    /// The server's rows for the message a set of pending rows became: the last user message in
    /// the transcript, provided it landed where the pending rows were.
    private func serverRows(replacing pendingIDs: [String]) -> [String]? {
        guard pendingIDs.contains(where: { $0.hasPrefix("pending:") }),
            let lastUser = orderedIDs.lastIndex(where: { rowsByID[$0]?.role == .user }),
            let messageID = rowsByID[orderedIDs[lastUser]]?.messageID
        else { return nil }
        let rows = orderedIDs.filter {
            rowsByID[$0]?.messageID == messageID && rowsByID[$0]?.role == .user
        }
        guard let first = rows.first.flatMap({ orderedIDs.firstIndex(of: $0) }),
            first >= canvasFloor - 2
        else { return nil }
        return rows
    }

    /// The room to hold under the transcript, measured from the page rather than from a tally of
    /// its rows. `chrome` is what the composer and the banner cover, which is the only part of the
    /// inset that is not the room itself.
    func freshCanvasPadding(chrome: CGFloat) -> CGFloat {
        guard !canvasPromptIDs.isEmpty else { return 0 }
        guard let frame = canvasPromptFrame() else {
            if canvasRising { return canvasPadding }
            releaseCanvas()
            return 0
        }
        // A live row nobody can see is not a live row under *this* prompt: the canvas keeps the
        // answer directly beneath the question, so the row being written is the one on screen. A
        // reading that could not be taken used to leave the room at whatever it last was — which
        // on the frame the canvas opens is none at all, and a rise with no room under it is a
        // rise the scroll cannot reach and the prompt stops halfway up the page.
        let end = visibleEnd() ?? collectionView.contentSize.height
        let room = FreshCanvas.room(
            promptTop: Double(frame.minY), viewport: Double(collectionView.bounds.height),
            end: Double(end + chrome))
        if room <= 0, !canvasRising { releaseCanvas() }
        return CGFloat(room)
    }

    func releaseCanvas() {
        canvasPromptIDs = []
        canvasPinned = false
        canvasRiseDeadline = nil
    }

    /// Where the scroll must be for the prompt block to rest at the headroom, in the transcript's
    /// own offset. Read again on every layout while the canvas holds rather than once when it
    /// opened, because the page under it is still settling.
    private func canvasOffset(for frame: CGRect) -> CGFloat {
        let inset = collectionView.adjustedContentInset
        let offset = FreshCanvas.offset(
            promptTop: Double(frame.minY),
            contentHeight: Double(collectionView.contentSize.height + inset.top + inset.bottom),
            viewport: Double(collectionView.bounds.height))
        return CGFloat(offset) - inset.top
    }

    /// Keeps the prompt where the rise put it. Nothing here moves a page the reader is holding or
    /// has scrolled away from, and nothing moves at all once the prompt is within a point of the
    /// headroom — which is what makes this cost nothing on the frames where it is already right.
    func pinFreshCanvas() {
        guard canvasPinned, !canvasPromptIDs.isEmpty, !isFingerDown, !userScrolledUp,
            !isPinningCanvas, let frame = canvasPromptFrame(), frame.height > 0
        else { return }
        let inset = collectionView.adjustedContentInset
        let landed = FreshCanvas.hasLanded(
            promptTop: Double(frame.minY), offset: Double(collectionView.contentOffset.y + inset.top))
        guard !landed else { return }
        let target = canvasOffset(for: frame)
        guard abs(target - collectionView.contentOffset.y) > CGFloat(FreshCanvas.landing) else {
            return
        }
        isPinningCanvas = true
        collectionView.setContentOffset(CGPoint(x: 0, y: target), animated: false)
        isPinningCanvas = false
    }

    /// Where the end of the visible conversation is, in content coordinates: the last written
    /// glyph of the live row plus whatever is docked under it, or the end of the content when
    /// nothing is being written.
    ///
    /// Read off the live cell's own geometry rather than off the layout's content size. A row
    /// that was just reconfigured is laid out at its estimated height for a frame before the list
    /// measures it, and the content size dips with it; an offset that followed the content size
    /// followed that dip and came back — the transcript twitched under every arrival. The cell's
    /// top comes from the settled rows above it and the glyph's bottom from its own text, and
    /// neither of those moves when the list re-estimates.
    ///
    /// Nil when there is a live row but no cell on screen to read it from, which is not zero: a
    /// caller that took it for zero would take the whole laid-out paragraph for written.
    ///
    /// The unrevealed text is only ever the end of the page when the live row is the last one.
    /// With a row below it — a tool starting while the words are still being written, a message
    /// waiting its turn — the clear text is a gap above rows that are already real, and an end
    /// that excluded the gap put those rows behind the composer.
    func visibleEnd() -> CGFloat? {
        let contentHeight = collectionView.contentSize.height
        guard let id = cascade.key, let row = rowsByID[id] else { return contentHeight }
        guard let indexPath = dataSource.indexPath(for: id),
            let attributes = collectionView.layoutAttributesForItem(at: indexPath),
            let cell = collectionView.cellForItem(at: indexPath)
        else { return nil }
        guard indexPath.item == collectionView.numberOfItems(inSection: 0) - 1 else {
            return contentHeight
        }
        let bottom: CGFloat
        switch (row.content, cell) {
        case (.text, let bubble as TextBubbleCell):
            bottom = bubble.revealedBottom(cascade.revealed)
        case (.code(let block), let code as CodeBlockCell):
            bottom = code.revealedBottom(
                cascade.revealed, block: block, expanded: expandedReasoning.contains(id))
        default:
            return contentHeight
        }
        return min(contentHeight, attributes.frame.minY + bottom)
    }

    /// How much of the live row is laid out past its reveal — text the reader has not been shown
    /// yet, drawn clear under the wave. Zero when nothing is being written; nil when the row is
    /// being written but is not on screen to be measured.
    func unrevealedHeight() -> CGFloat? {
        guard let end = visibleEnd() else { return nil }
        return max(0, collectionView.contentSize.height - end)
    }

    /// Gives the send that just went its canvas, once its rows are in the list. Asked at the end
    /// of every apply rather than only the one that drew the pending rows, so whichever apply
    /// wins the race with the server's echo is the one that opens it. A transcript not yet
    /// revealed is revealed first, because the rise is a motion on a page somebody can see.
    func settleFreshCanvas(fading cells: [UIView]) {
        guard !canvasIntent.isEmpty else { return }
        let pendingRows = canvasIntent.filter { dataSource.indexPath(for: $0) != nil }
        let rows = pendingRows.isEmpty ? serverRows(replacing: canvasIntent) : pendingRows
        guard let rows, !rows.isEmpty else {
            // A send is held by its identity, not by the shape of its rows: a prompt that is only
            // pictures never draws the bare row this used to look for, so the one send the whole
            // block-of-rows rule exists for was the one whose intent was thrown away every time.
            if !viewModel.pendingSends.contains(where: { send in
                let key = "pending:\(send.id.uuidString)"
                return canvasIntent.contains { $0 == key || $0.hasPrefix(key + ":") }
            }) {
                canvasIntent = []
            }
            return
        }
        canvasIntent = []
        let animated = hasRevealed
        if !hasRevealed { revealTranscript() }
        openFreshCanvas(promptIDs: rows, fading: cells, animated: animated)
    }

    /// The scroll itself: the prompt rises to `FreshCanvas.headroom` under the top edge in one
    /// motion from wherever the reader was, with the padding already in place so the offset is
    /// reachable. The bubble fades in as it rides rather than springing up on its own, because
    /// two movements on one row read as a stutter.
    private func openFreshCanvas(promptIDs: [String], fading cells: [UIView], animated: Bool) {
        canvasRiseDeadline = CACurrentMediaTime() + FreshCanvas.patience
        riseFreshCanvas(promptIDs: promptIDs, fading: cells, animated: animated)
    }

    /// A row appended this frame has no height until the list has laid it out, and a rise that
    /// read a row it could not measure as a row that was not there gave up on the one motion the
    /// send exists to make — silently, on exactly the sends where the transcript had the most work
    /// to do. So it asks again, frame by frame, for as long as `FreshCanvas.patience`.
    private func riseFreshCanvas(promptIDs: [String], fading cells: [UIView], animated: Bool) {
        canvasPromptIDs = promptIDs
        canvasRising = true
        userScrolledUp = false
        view.layoutIfNeeded()
        updateTranscriptInsets()
        collectionView.layoutIfNeeded()
        guard let frame = canvasPromptFrame(), frame.height > 0 else {
            guard let deadline = canvasRiseDeadline, CACurrentMediaTime() < deadline else {
                MidgarLog.info(
                    "fresh canvas: prompt row never measured session=\(viewModel.session.id)", category: .chat)
                canvasRising = false
                releaseCanvas()
                for cell in cells { cell.alpha = 1 }
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60.0) { [weak self] in
                guard let self, self.canvasRising else { return }
                self.riseFreshCanvas(promptIDs: promptIDs, fading: cells, animated: animated)
            }
            return
        }
        canvasRiseDeadline = nil
        let offset = canvasOffset(for: frame)
        MidgarLog.info(
            "fresh canvas: rows=\(promptIDs.count) prompt=\(Int(frame.height)) offset=\(Int(offset)) padding=\(Int(canvasPadding)) session=\(viewModel.session.id)",
            category: .chat
        )
        let target = CGPoint(x: 0, y: offset)
        for cell in cells { cell.alpha = 0 }
        guard animated, !UIAccessibility.isReduceMotionEnabled else {
            collectionView.setContentOffset(target, animated: false)
            for cell in cells { cell.alpha = 1 }
            landFreshCanvas()
            return
        }
        UIView.animate(
            withDuration: 0.5, delay: 0, usingSpringWithDamping: 0.9,
            initialSpringVelocity: 0.3, options: [.allowUserInteraction, .beginFromCurrentState]
        ) {
            self.collectionView.contentOffset = target
            for cell in cells { cell.alpha = 1 }
        } completion: { [weak self] _ in
            self?.landFreshCanvas()
        }
    }

    /// The motion is over, so the keeping begins: from here the prompt's place is checked against
    /// the page after every layout instead of being assumed from the scroll that aimed at it.
    private func landFreshCanvas() {
        canvasRising = false
        guard !canvasPromptIDs.isEmpty, !userScrolledUp else { return }
        canvasPinned = true
        updateTranscriptInsets()
        pinFreshCanvas()
    }

    /// Every row of the send that just went — its pictures and its words — so the block that rises
    /// is the whole prompt. A picture is docked above the words it was clipped to, and raising the
    /// words alone put it one row above the top edge, exactly where nobody looks.
    static func freshSendRows(among ids: [String]) -> [String] {
        guard let last = ids.last(where: { $0.hasPrefix("pending:") }) else { return [] }
        let send = last.split(separator: ":", maxSplits: 2).prefix(2).joined(separator: ":")
        return ids.filter { $0 == send || $0.hasPrefix(send + ":") }
    }

    /// A row this device is holding changed height on its own clock — its caption strip came or
    /// went — so the list is asked to measure it again, and the canvas offset is held through it.
    func remeasure(_ id: String) {
        var snapshot = dataSource.snapshot()
        guard snapshot.itemIdentifiers.contains(id) else { return }
        snapshot.reconfigureItems([id])
        dataSource.apply(snapshot, animatingDifferences: false)
    }
}
