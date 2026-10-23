import AppKit
import os
import CodingAgentKit
import TailscodeCore

extension TranscriptViewController {
    func scrollBy(_ points: CGFloat) {
        adjustScroll { $0 + points }
    }

    func scrollByPages(_ fraction: CGFloat) {
        adjustScroll { $0 + self.scrollView.contentView.bounds.height * fraction }
    }

    func scrollToTop() {
        adjustScroll { _ in -self.scrollView.contentInsets.top }
    }

    /// The previous or next prompt the reader wrote, brought to the top of the page: `-1` goes up
    /// one, `1` goes down one. The ends clamp rather than wrap — above the first prompt the first is
    /// where the page rests, and below the last there is nowhere further to go — and a reader who
    /// has asked for less motion lands at once.
    func scrollToPrompt(_ direction: Int) {
        view.layoutSubtreeIfNeeded()
        let tops = promptTops()
        guard !tops.isEmpty else { return }
        let clip = scrollView.contentView
        let reading = clip.bounds.origin.y + scrollView.contentInsets.top
        let margin: CGFloat = 8
        let tolerance: CGFloat = 4
        let anchors = tops.map { $0 - margin }
        let anchor: CGFloat?
        if direction < 0 {
            anchor = anchors.last { $0 < reading - tolerance } ?? anchors.first
        } else {
            anchor = anchors.first { $0 > reading + tolerance }
        }
        guard let anchor else { return }
        let origin = min(max(-scrollView.contentInsets.top, anchor - scrollView.contentInsets.top), maxScrollOrigin())
        guard abs(origin - clip.bounds.origin.y) > 0.5 else { return }
        followsBottom = false
        guard MotionBudget.animationAllowed else {
            clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: origin))
            scrollView.reflectScrolledClipView(clip)
            return
        }
        NSAnimationContext.runAnimationGroup(
            { context in
                context.duration = 0.2
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                clip.animator().setBoundsOrigin(NSPoint(x: clip.bounds.origin.x, y: origin))
            },
            completionHandler: { [weak self] in
                MainThread.call {
                    guard let self else { return }
                    self.scrollView.reflectScrolledClipView(self.scrollView.contentView)
                }
            })
    }

    /// Where each prompt the reader wrote stands in the page, top-down.
    private func promptTops() -> [CGFloat] {
        var tops: [CGFloat] = []
        for (index, row) in renderedRows.enumerated() where index < rowViews.count {
            switch row.kind {
            case .userText, .pendingSend:
                let view = rowViews[index]
                guard view.superview != nil else { continue }
                tops.append(view.convert(view.bounds, to: canvas).minY)
            default:
                continue
            }
        }
        return tops
    }

    func scrollToBottom() {
        releaseFreshCanvas(animated: false)
        setFollowing(true)
        schedulePinCorrector()
    }

    /// The card for one named agent — matched to the tool call that spawned it, which is the id
    /// the summary carries — expanded in place and its transcript fetched on arrival.
    func scrollToAgent(_ id: String) {
        for (index, row) in renderedRows.enumerated() {
            guard let call = row.kind.spawnedCalls.first(where: { $0.id == id }) else { continue }
            if case .subagentGroup(let fanout) = row.kind,
                let member = fanout.members.first(where: { $0.call.id == id })
            {
                context.expanded.set(member.key, open: true)
            }
            context.expanded.set(row.key, open: true)
            replaceRows { $0.key == row.key }
            fetchSubagent(call)
            scrollToRow(at: index)
            return
        }
        scrollToNewestAgent()
    }

    /// The card of the agent a brain's Task node stands for: the node is a step, named by its part,
    /// and the card is the row that part made, alone or among a fan-out's members.
    func revealAgent(ofStep stepID: String) {
        for row in lastFullRows {
            if row.key == stepID, let call = row.kind.spawnedCalls.first {
                scrollToAgent(call.id)
                return
            }
            if case .subagentGroup(let fanout) = row.kind,
                let member = fanout.members.first(where: { $0.key == stepID })
            {
                scrollToAgent(member.call.id)
                return
            }
        }
    }

    /// The row a message made, found by the part the row carries in its key when there is one and
    /// by the message alone when the part was folded into another row. A message the window does
    /// not hold has no row, and nothing moves.
    func scrollToMessage(_ messageID: String, part itemID: String) {
        let index =
            renderedRows.firstIndex { $0.key == itemID }
            ?? renderedRows.firstIndex { $0.key.hasPrefix(itemID) }
            ?? renderedRows.firstIndex { $0.key.hasPrefix("\(messageID):") }
        guard let index else { return }
        scrollToRow(at: index)
    }

    func scrollToNewestAgent() {
        for (index, row) in renderedRows.enumerated().reversed() {
            guard !row.kind.spawnedCalls.isEmpty else { continue }
            scrollToRow(at: index)
            return
        }
        scrollToBottom()
    }

    private func scrollToRow(at index: Int) {
        guard index < rowViews.count else { return }
        followsBottom = false
        view.layoutSubtreeIfNeeded()
        let rowView = rowViews[index]
        let frame = rowView.convert(rowView.bounds, to: canvas)
        adjustScroll { _ in frame.minY - self.scrollView.contentView.bounds.height * 0.3 }
    }

    /// A change to the column above where somebody is reading is a change to what they are reading.
    /// A stack view in a scroll view anchors nothing by itself, so a picture finishing its decode
    /// forty rows up, a subagent transcript arriving inside a card, or a backfill inserting at the
    /// top of the stack each move the words out from under a reader who has scrolled back — the
    /// heights above them changed and their scroll origin did not. The fixed point is the topmost
    /// row still on screen that the edit left standing: whatever happened to the column, that row is
    /// put back where it was and the origin follows it. A reader at the bottom already has an
    /// anchor — the pin — so
    /// nothing is measured for them, and an edit that only touched the tail moves the anchor by
    /// nothing and scrolls by nothing.
    @discardableResult
    func preservingScroll<T>(_ mutate: () -> T) -> T {
        guard !followsBottom else { return mutate() }
        let anchors = visibleAnchors()
        guard !anchors.isEmpty else { return mutate() }
        let result = mutate()
        view.layoutSubtreeIfNeeded()
        guard let moved = anchorDrift(anchors), abs(moved) > 0.5 else { return result }
        let clip = scrollView.contentView
        isAutoScrolling = true
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: clip.bounds.origin.y + moved))
        scrollView.reflectScrolledClipView(clip)
        isAutoScrolling = false
        return result
    }

    /// The rows with anything of themselves on screen, each named by the key that identifies it and
    /// paired with where it sits in the canvas: the fixed points a reflow has to leave looking
    /// unchanged. Ordered from the topmost down and stopped at the foot of the viewport, because a
    /// correction wants whichever of them survived the edit and none of the rest.
    private func visibleAnchors() -> [(key: String, offset: CGFloat)] {
        let clip = scrollView.contentView
        let top = clip.bounds.origin.y + scrollView.contentInsets.top
        let foot = clip.bounds.origin.y + clip.bounds.height
        var anchors: [(key: String, offset: CGFloat)] = []
        for (index, rowView) in rowViews.enumerated() where rowView.superview != nil {
            guard index < renderedRows.count else { break }
            let frame = rowView.convert(rowView.bounds, to: canvas)
            guard frame.maxY > top else { continue }
            if !anchors.isEmpty, frame.minY > foot { break }
            anchors.append((renderedRows[index].key, frame.minY))
        }
        return anchors
    }

    /// How far the topmost row that survived the edit moved, or nothing if not one of them did.
    ///
    /// The anchor is a key looked up afterwards rather than a view held across the mutation, because
    /// the edits that most need anchoring are the ones that rebuild the very row being read: a batch
    /// repaint takes every stale row's view out and puts a new one back under the same key, so an
    /// anchor holding the old view finds it orphaned and abandons the correction — for every row
    /// below it as well, which is exactly when it was needed. A key that is gone entirely is a row
    /// that genuinely left, and then the next one still standing holds the column in its place.
    private func anchorDrift(_ anchors: [(key: String, offset: CGFloat)]) -> CGFloat? {
        for anchor in anchors {
            guard let index = renderedRows.firstIndex(where: { $0.key == anchor.key }),
                index < rowViews.count
            else { continue }
            let rowView = rowViews[index]
            guard rowView.superview != nil else { continue }
            return rowView.convert(rowView.bounds, to: canvas).minY - anchor.offset
        }
        return nil
    }

    /// Following is a decision, not a measurement: the intent is held here and re-applied
    /// whenever the content actually grows, so an unfocused chat never drifts up as it streams.
    func observeScrolling() {
        guard !scrollObserved else { return }
        scrollObserved = true
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrollBoundsChanged),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        canvas.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(contentGrew),
            name: NSView.frameDidChangeNotification, object: canvas)
    }

    func stopObservingScrolling() {
        guard scrollObserved else { return }
        scrollObserved = false
        NotificationCenter.default.removeObserver(
            self, name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        NotificationCenter.default.removeObserver(
            self, name: NSView.frameDidChangeNotification, object: canvas)
    }

    @objc private func scrollBoundsChanged() {
        scheduleImageSweep()
        brains.viewportMoved()
        hoverBar.refresh()
        railController.rowsChanged()
        railController.reposition()
        guard !isAutoScrolling else { return }
        followClock = nil
        guard canvasHold == nil else {
            followsBottom = false
            // The room shrinking under the prompt drags the scrollable range up with it, and the
            // clip reports that clamp as a scroll nobody made. While the canvas holds, the pinned
            // origin *is* the end of the *visible* range: short of it is a hand on the page, at it
            // is the room being taken back. An answer is laid out whole and revealed a glyph at a
            // time, so the laid-out end runs past the pin by the text nobody has been shown yet,
            // and a pin measured against it let go on the first frame of the answer.
            if scrollView.contentView.bounds.origin.y < visibleScrollOrigin() - 1 {
                canvasPinned = false
                canvasRising = false
                canvasRiseDeadline = nil
            }
            return
        }
        let atBottom = isNearBottom()
        followsBottom = atBottom
    }

    @objc private func contentGrew() {
        railController.reposition()
        if canvasHold != nil {
            recomputeFreshCanvas()
            return
        }
        guard followsBottom else { return }
        schedulePinCorrector()
    }

    /// A reader following a glide is a few points behind the written end by design, so while a
    /// row is being written the reading is generous enough to keep them following.
    func isNearBottom() -> Bool {
        let clip = scrollView.contentView
        let ceiling = visibleScrollOrigin()
        let slack: CGFloat = cascade.key == nil ? 8 : 80
        return clip.bounds.origin.y >= ceiling - slack
    }

    private func maxScrollOrigin() -> CGFloat {
        let clip = scrollView.contentView
        return max(
            -scrollView.contentInsets.top,
            canvas.frame.height - clip.bounds.height + scrollView.contentInsets.bottom)
    }

    /// The origin that puts the last *written* line at the bottom of the window. The same as the
    /// end of the content whenever nothing is being written; while an answer is, the laid-out
    /// remainder of the live row is left below the fold, so the page is pushed up by the writing
    /// rather than by the layout that ran ahead of it.
    private func visibleScrollOrigin() -> CGFloat {
        max(-scrollView.contentInsets.top, maxScrollOrigin() - unrevealedHeight())
    }

    func setFollowing(_ following: Bool) {
        followsBottom = following
        if following { pinToBottom() }
    }

    /// Gliding, the origin eases toward the written end on `FreshCanvas.followTime` rather than
    /// landing on it: the end moves a line at a time, and a page that jumped a line every time the
    /// reveal crossed one twitched under the writing. A glide never moves back — the writing only
    /// grows — while an ordinary pin lands wherever the end now is.
    func pinToBottom(gliding: Bool = false) {
        let clip = scrollView.contentView
        let target = visibleScrollOrigin()
        let current = clip.bounds.origin.y
        let next: CGFloat
        if gliding, cascade.key != nil,
            !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        {
            let now = CACurrentMediaTime()
            let elapsed = min(max(now - (followClock ?? now), 0), 0.1)
            followClock = now
            next = CGFloat(FreshCanvas.glide(current: current, target: target, elapsed: elapsed))
        } else {
            followClock = nil
            next = target
        }
        guard abs(current - next) > 0.01 else { return }
        isAutoScrolling = true
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: next))
        scrollView.reflectScrolledClipView(clip)
        isAutoScrolling = false
    }

    /// Runs after the current layout pass has settled, so the pixels always match the intent. A
    /// fill still hidden when it completes is revealed here, already settled at the bottom rather
    /// than sliding into place — `applyRows` shows it from its tail first, so this is the net.
    func schedulePinCorrector() {
        guard !pinScheduled else { return }
        pinScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pinScheduled = false
            self.view.layoutSubtreeIfNeeded()
            if self.followsBottom { self.pinToBottom() }
            if self.pendingReveal, self.fillComplete {
                self.pendingReveal = false
                self.canvas.alphaValue = 1
            }
        }
    }

    func adjustScroll(_ transform: (CGFloat) -> CGFloat) {
        let clip = scrollView.contentView
        let target = min(
            max(-scrollView.contentInsets.top, transform(clip.bounds.origin.y)),
            maxScrollOrigin())
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: target))
        scrollView.reflectScrolledClipView(clip)
    }

    /// The gentlest scroll that shows a just-opened body: down only as far as the body's end (or
    /// the page can hold), and never past the point where the clicked header would leave the top —
    /// a header that flies off the screen is the person losing the very thing they pointed at.
    /// Runs on the next hop, once the body has its layout; a row already torn down by then is no
    /// longer in the canvas and moves nothing.
    func revealDisclosure(_ row: NSView) {
        guard row.window != nil, row.isDescendant(of: canvas) else { return }
        view.layoutSubtreeIfNeeded()
        let frame = row.convert(row.bounds, to: canvas)
        scrollToShow(frame)
    }

    /// The same scroll for a row that has begun to open: the page is moved at once, so the window
    /// holds all of what the move reveals while it comes in, and the render server eases the page
    /// from where it was over the length of the move. The row keeps the frame it will rest at, so
    /// the page knows how far it has to go before the move has grown the row to it.
    func revealAhead(of row: NSView, height: CGFloat) {
        guard row.window != nil, row.isDescendant(of: canvas) else { return }
        var frame = row.convert(row.bounds, to: canvas)
        frame.size.height = height
        let clip = scrollView.contentView
        let margin: CGFloat = 8
        let visibleTop = clip.bounds.origin.y + scrollView.contentInsets.top
        let visibleBottom =
            clip.bounds.origin.y + clip.bounds.height - scrollView.contentInsets.bottom
        let delta = min(
            frame.maxY + margin - visibleBottom, frame.minY - margin - visibleTop)
        guard delta > 0 else { return }
        let from = clip.bounds.origin.y
        isAutoScrolling = true
        adjustScroll { $0 + delta }
        isAutoScrolling = false
        let to = clip.bounds.origin.y
        guard let layer = clip.layer, to != from, ActivityPulse.motionAllowed else { return }
        let ease = CABasicAnimation(keyPath: "bounds.origin.y")
        ease.fromValue = from
        ease.toValue = to
        ease.duration = NeuralTransition.openDuration
        ease.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(ease, forKey: "reveal.ahead")
    }

    private func scrollToShow(_ frame: CGRect) {
        let clip = scrollView.contentView
        let margin: CGFloat = 8
        let visibleTop = clip.bounds.origin.y + scrollView.contentInsets.top
        let visibleBottom =
            clip.bounds.origin.y + clip.bounds.height - scrollView.contentInsets.bottom
        let needed = frame.maxY + margin - visibleBottom
        let slack = frame.minY - margin - visibleTop
        let delta = min(needed, slack)
        guard delta > 0 else { return }
        isAutoScrolling = true
        adjustScroll { $0 + delta }
        isAutoScrolling = false
    }

    /// The pill is a way back, not a counter: it shows whenever the reader has left the bottom
    /// of a transcript that has one, and never while a fresh canvas is deliberately holding the
    /// prompt at the top.
    func syncJumpPill() {
        let show = !followsBottom && canvasHold == nil && !rowViews.isEmpty && draw == nil && preview == nil
        jumpGlass?.isHidden = !show
        if show { applyJumpReading() }
    }
}
