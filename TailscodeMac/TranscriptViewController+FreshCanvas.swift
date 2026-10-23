import AppKit
import os
import CodingAgentKit
import TailscodeCore

extension TranscriptViewController {
    private static let canvasLog = Logger(subsystem: "com.guitaripod.tailscode", category: "chat")

    /// The prompt just sent rises to the top: the padding is made, the follow-the-bottom pin is
    /// let go, and the move is one motion on the platform's clock from wherever the reader was.
    func riseFreshCanvas(rowKey: String) {
        canvasKey = rowKey
        canvasFloor = renderedRows.firstIndex { $0.key == rowKey } ?? renderedRows.count
        canvasRiseDeadline = CACurrentMediaTime() + FreshCanvas.patience
        canvasRising = true
        canvasPinned = false
        attemptFreshCanvasRise()
    }

    /// A row appended this pass has no frame until the stack has laid it out, and a rise that read
    /// an unmeasured row as a row that was not there gave the whole motion up — once, silently,
    /// with nothing left to notice. So it asks again for as long as `FreshCanvas.patience`.
    private func attemptFreshCanvasRise() {
        guard canvasRising else { return }
        view.layoutSubtreeIfNeeded()
        guard let block = promptBlock(), block.height > 0 else {
            guard let deadline = canvasRiseDeadline, CACurrentMediaTime() < deadline else {
                Self.canvasLog.notice("fresh canvas: prompt row never measured")
                canvasRising = false
                canvasRiseDeadline = nil
                canvasKey = nil
                return
            }
            DispatchQueue.main.async { [weak self] in self?.attemptFreshCanvasRise() }
            return
        }
        canvasRiseDeadline = nil
        let clip = scrollView.contentView
        canvasHold = (block.minY, block.height)
        followsBottom = false
        canvasPadding = freshCanvasRoom(promptTop: block.minY)
        applyInsets()
        view.layoutSubtreeIfNeeded()
        let target = NSPoint(x: clip.bounds.origin.x, y: canvasOrigin(promptTop: block.minY))
        Self.canvasLog.notice(
            "fresh canvas: prompt=\(block.height) padding=\(self.canvasPadding)")
        isAutoScrolling = true
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            clip.scroll(to: target)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            isAutoScrolling = false
            landFreshCanvas()
        } else {
            NSAnimationContext.runAnimationGroup(
                { animation in
                    animation.duration = 0.3
                    animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    clip.animator().setBoundsOrigin(target)
                },
                completionHandler: { [weak self] in
                    MainThread.call {
                        guard let self else { return }
                        self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
                        self.isAutoScrolling = false
                        self.landFreshCanvas()
                    }
                })
        }
    }

    /// The motion is over, so the keeping begins: from here the prompt's place is checked against
    /// the page after every layout instead of being assumed from the scroll that aimed at it.
    private func landFreshCanvas() {
        canvasRising = false
        guard canvasHold != nil else { return }
        canvasPinned = true
        recomputeFreshCanvas()
    }

    /// The block that rises: the row the send was keyed to and every row of the person's own
    /// touching it, because a picture is drawn above the words it was clipped to and raising the
    /// words alone leaves it one row above the top edge. The key follows the send across the swap
    /// from the echo to the server's account of it, and never back past the send it was made for.
    private func promptBlock() -> NSRect? {
        guard let key = canvasKey else { return nil }
        var index = renderedRows.firstIndex { $0.key == key }
        if index == nil, key.hasPrefix("echo:"),
            let last = renderedRows.lastIndex(where: {
                if case .userText = $0.kind { return true }
                return false
            }), last >= canvasFloor - 2
        {
            canvasKey = renderedRows[last].key
            index = last
        }
        guard let index, index < rowViews.count else { return nil }
        var first = index
        while first > 0, renderedRows[first - 1].isPromptBlock { first -= 1 }
        var last = index
        while last + 1 < renderedRows.count, last + 1 < rowViews.count,
            renderedRows[last + 1].isPromptBlock
        { last += 1 }
        var union: NSRect?
        for row in first...last where rowViews[row].superview != nil {
            let frame = rowViews[row].convert(rowViews[row].bounds, to: canvas)
            union = union.map { $0.union(frame) } ?? frame
        }
        return union
    }

    /// Where the clip must stand for the prompt to rest at `FreshCanvas.headroom` under the top of
    /// what the chrome leaves visible.
    private func canvasOrigin(promptTop: CGFloat) -> CGFloat {
        let offset = FreshCanvas.offset(
            promptTop: Double(promptTop),
            contentHeight: Double(
                canvas.frame.height + scrollView.contentInsets.top
                    + scrollView.contentInsets.bottom),
            viewport: Double(scrollView.contentView.bounds.height))
        return CGFloat(offset) - chromeInsets.top
    }

    /// Keeps the prompt where the rise put it. Nothing moves once it is within a point of the
    /// headroom, so this costs nothing on the frames where it is already right.
    private func pinFreshCanvas() {
        guard canvasPinned, !canvasRising, !isPinningCanvas, let block = promptBlock(),
            block.height > 0
        else { return }
        let clip = scrollView.contentView
        let landed = FreshCanvas.hasLanded(
            promptTop: Double(block.minY), offset: Double(clip.bounds.origin.y + chromeInsets.top))
        guard !landed else { return }
        let target = canvasOrigin(promptTop: block.minY)
        guard abs(target - clip.bounds.origin.y) > CGFloat(FreshCanvas.landing) else { return }
        isPinningCanvas = true
        isAutoScrolling = true
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: target))
        scrollView.reflectScrolledClipView(clip)
        isAutoScrolling = false
        isPinningCanvas = false
    }

    /// The answer growing under the prompt takes the room back, until what is under the prompt
    /// fills the window on its own and ordinary following resumes. The block is measured again
    /// every time — its top as well as its height — because the echo is one card and the server's
    /// account of the same send is a row per picture and one for the words, and a hold frozen at
    /// the place the echo stood counts the room from somewhere the prompt no longer is.
    func recomputeFreshCanvas() {
        guard canvasHold != nil, let block = promptBlock(), block.height > 0 else { return }
        canvasHold = (block.minY, block.height)
        let room = freshCanvasRoom(promptTop: block.minY)
        guard canvasRising || FreshCanvas.holds(room: room) else {
            releaseFreshCanvas(animated: false)
            setFollowing(isNearBottom())
            return
        }
        canvasPadding = room
        applyInsets()
        pinFreshCanvas()
    }

    /// The room to hold, measured from the page rather than from a tally of its rows: the whole
    /// scrollable extent less the room already in it and less the part of the live row laid out
    /// ahead of its reveal.
    private func freshCanvasRoom(promptTop: CGFloat) -> CGFloat {
        let end =
            canvas.frame.height + scrollView.contentInsets.top + scrollView.contentInsets.bottom
            - canvasPadding - unrevealedHeight()
        return CGFloat(
            FreshCanvas.room(
                promptTop: Double(promptTop),
                viewport: Double(scrollView.contentView.bounds.height), end: Double(end)))
    }

    /// How much of the live row is laid out past its reveal: text the reader has not been shown
    /// yet, drawn clear under the wave. Zero when nothing is being written.
    func unrevealedHeight() -> CGFloat {
        guard let key = cascade.key, !placeholderShown,
            let index = renderedRows.lastIndex(where: { $0.key == key }), index < rowViews.count,
            let label = Self.streamedLabel(in: rowViews[index], kind: renderedRows[index].kind)
        else { return 0 }
        let rendered = label.attributedStringValue
        let shown = min(max(cascade.revealed, 0), rendered.length)
        guard shown < rendered.length, label.bounds.width > 0 else { return 0 }
        guard shown > 0 else { return label.bounds.height }
        let wraps: Bool
        if case .agentProse = renderedRows[index].kind { wraps = true } else { wraps = false }
        let prefix = rendered.attributedSubstring(from: NSRange(location: 0, length: shown))
        let size = NSSize(
            width: wraps ? label.bounds.width : .greatestFiniteMagnitude,
            height: .greatestFiniteMagnitude)
        let written = prefix.boundingRect(
            with: size, options: [.usesLineFragmentOrigin, .usesFontLeading]
        ).height
        return max(0, label.bounds.height - ceil(written))
    }

    /// The room goes: with the reader at the bottom the transcript settles onto its end, and
    /// anywhere else nothing moves that they did not move.
    func releaseFreshCanvas(animated: Bool) {
        canvasKey = nil
        canvasPinned = false
        canvasRising = false
        canvasRiseDeadline = nil
        guard canvasHold != nil || canvasPadding > 0 else { return }
        canvasHold = nil
        canvasPadding = 0
        applyInsets()
        if animated {
            setFollowing(true)
        } else {
            adjustScroll { $0 }
        }
    }
}
