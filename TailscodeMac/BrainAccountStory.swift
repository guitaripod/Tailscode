import AppKit
import TailscodeCore

/// The story's layout and what exists of it: heights measured when an item is made and estimated
/// while it is not, offsets from them, the scroll that holds the reader's place when a height
/// changes above them, and the items near the viewport made and let go of as it moves.
extension BrainAccountView {

    /// Places every part of the account for the size the row gave it: the header, the pins above
    /// the story, the story, the detail beside it or over it, and the foot.
    func layoutAccount() {
        guard host != nil, bounds.width > 1 else { return }
        let m = metrics
        let width = bounds.width
        let height = bounds.height
        let split = m.arrangement == .split
        isTwoColumns = split && m.accountLayout == .split
        holdsBody = readoutHoldsBody
        padLeft = split ? 20 : 16
        headerHeight = header.fit(width: width)
        header.frame = CGRect(x: 0, y: 0, width: width, height: headerHeight)
        var top = headerHeight
        narrowBar.isHidden = split
        if !split {
            narrowBar.frame = CGRect(x: 0, y: top, width: width, height: 32)
            top += 32
        }
        bodyTop = top
        let footer = split ? Self.footerHeight : 0
        let bodyHeight = max(0, height - bodyTop - footer)
        let region = isTwoColumns ? m.story.width : width
        let cap = split ? NeuralStageMetrics.storyMax : width
        let box = max(120, min(region, cap) - padLeft - Self.padRight)
        var y = bodyTop
        var pinned = false
        for view in [askView, nowView, planView].compactMap({ $0 }) as [AccountBlock] {
            let pinHeight = view.fit(width: box)
            view.frame = CGRect(x: padLeft, y: y + 8, width: box, height: pinHeight)
            y = view.frame.maxY
            pinned = true
        }
        pinsBottom = y
        let storyTop = pinned ? y + 8 : bodyTop
        storyRect = CGRect(x: 0, y: storyTop, width: region, height: max(0, bodyTop + bodyHeight - storyTop))
        scroll.isHidden = holdsBody
        scroll.frame = storyRect
        footerStrip.isHidden = !split
        footerStrip.padLeft = padLeft
        footerStrip.frame = CGRect(x: 0, y: height - footer, width: width, height: footer)
        let pill = followPill.fittingSize
        followPill.frame = CGRect(
            x: storyRect.minX + (storyRect.width - pill.width) / 2, y: storyRect.maxY - 12 - 28,
            width: pill.width, height: 28)
        followPill.frame.size.height = 28
        if isTwoColumns {
            detailRect = CGRect(
                x: m.story.width + NeuralStageMetrics.gutter, y: bodyTop + 4,
                width: max(0, width - m.story.width - NeuralStageMetrics.gutter), height: max(0, bodyHeight - 4))
        } else if holdsBody {
            detailRect = CGRect(x: 0, y: storyTop, width: width, height: storyRect.height)
        } else {
            detailRect = nil
        }
        if let detail, let detailRect { detail.frame = detailRect }
        let widthChanged = abs(box - boxWidth) > 0.5
        let sizeChanged = widthChanged || abs(viewHeight - storyRect.height) > 0.5 || abs(regionWidth - region) > 0.5
        if sizeChanged {
            boxWidth = box
            regionWidth = region
            viewHeight = storyRect.height
            if widthChanged {
                holdAnchorHere()
                holdFor(0.45)
                heights = [:]
                for cell in cells.values { cell.stale = true }
            }
            scheduleRealize()
        }
        updateDocument()
        needsDisplay = true
    }

    func updateDocument() {
        let size = NSSize(width: max(regionWidth, 1), height: max(total, viewHeight))
        if document.frame.size != size { document.setFrameSize(size) }
    }


    func gap(before index: Int) -> CGFloat {
        guard index > 0 else { return 0 }
        if entries[index].isSaid, entries[index - 1].isSaid { return Self.saidGap }
        return Self.gap
    }

    func estimate(_ entry: AccountEntry) -> CGFloat {
        let measure = max(160, min(boxWidth - 72, proseProbe.em * 36))
        let perLine = max(8, measure / (proseProbe.em * 0.52))
        let line = proseProbe.line
        switch entry.kind {
        case .said(let said):
            let lines = said.text.split(separator: "\n", omittingEmptySubsequences: false).reduce(0) {
                $0 + max(1, Int((CGFloat($1.count) / perLine).rounded(.up)))
            }
            let shown = expandedText.contains(entry.id) ? lines : min(lines, NeuralAccount.saidCollapsedLines)
            return 4 + (said.showsSpeaker ? 20 : 0) + CGFloat(shown) * line
                + (lines > NeuralAccount.saidCollapsedLines ? 22 : 0)
        case .thought:
            return expandedText.contains(entry.id) ? 64 : 24
        case .work(let work):
            guard isOpen(entry, work: work) else { return 36 }
            return 36 + CGFloat(min(work.stepIDs.count, rowCap(entry.id))) * 28 + 10
        case .asked:
            return 56
        case .plan(let plan):
            return planStoryOpen(entry, plan) ? CGFloat(6 + 24 + 4 + plan.items.count * 24 + 8) : 38
        case .result(let result):
            return CGFloat(40 + (result.changes.count + result.checks.count + result.unfixed.count) * 28 + 90)
        }
    }

    func recomputeOffsets() {
        var y: CGFloat = 0
        var made: [CGFloat] = []
        made.reserveCapacity(entries.count)
        for (index, entry) in entries.enumerated() {
            y += gap(before: index)
            made.append(y)
            y += heights[entry.id] ?? estimate(entry)
        }
        offsets = made
        total = y + 16
        updateDocument()
    }

    /// The entry at the top of the viewport and how far the viewport is below its top: held across
    /// a change of heights so what is being read does not move.
    func anchor() -> (index: Int, delta: CGFloat)? {
        guard !entries.isEmpty, offsets.count == entries.count else { return nil }
        if let reveal = pendingReveal, let at = entryIndex[reveal.id] { return (at, scrollY - offsets[at]) }
        var low = 0
        var high = entries.count - 1
        let y = scrollY
        while low < high {
            let mid = (low + high) / 2
            let bottom = offsets[mid] + (heights[entries[mid].id] ?? estimate(entries[mid]))
            if bottom > y { high = mid } else { low = mid + 1 }
        }
        return (low, y - offsets[low])
    }

    func holdAnchorHere() {
        if holdAnchor == nil, let held = anchor(), held.index < entries.count {
            holdAnchor = (entries[held.index].id, held.delta)
        }
    }

    /// Keeps the item at the top of the viewport where it is until the heights have settled: after
    /// a resize every item is measured again at its new width, and the page must not move under
    /// the reader while the estimates are replaced by measurements.
    func holdFor(_ seconds: Double) {
        holdTicket += 1
        let ticket = holdTicket
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
            guard let self, self.holdTicket == ticket else { return }
            self.holdAnchor = nil
        }
    }

    func clampScroll() {
        let y = scrollY
        let clamped = min(max(y, 0), maxScroll)
        if abs(clamped - y) > 0.01 { setScrollRaw(clamped) }
    }

    func setScrollRaw(_ y: CGFloat) {
        let clip = scroll.contentView
        let clamped = min(max(y, 0), maxScroll)
        guard abs(clip.bounds.origin.y - clamped) > 0.01 else { return }
        clip.setBoundsOrigin(NSPoint(x: 0, y: clamped))
        scroll.reflectScrolledClipView(clip)
    }

    /// Measures the items that exist at the width they are laid out at; when any is not the height
    /// it was thought to be, the offsets are made again with the reader's place held.
    func syncHeights() {
        var changed = false
        for (id, cell) in cells {
            guard entryIndex[id] != nil else { continue }
            let h = cell.measuredHeight
            if abs((heights[id] ?? -1) - h) > 0.5 {
                heights[id] = h
                changed = true
            }
        }
        guard changed || offsets.count != entries.count else { return }
        let held = anchor()
        let wasAtEnd = maxScroll > 0 && scrollY >= maxScroll - 0.5
        recomputeOffsets()
        if let held, held.index < offsets.count {
            setScrollRaw(offsets[held.index] + held.delta)
        }
        if (wasAtEnd || scrollAnimating) && model.turn.outcome == .running && model.stepList.isFollowing {
            setScrollRaw(maxScroll)
        }
        if let hold = holdAnchor, let at = entryIndex[hold.id], pendingReveal == nil {
            setScrollRaw(offsets[at] + hold.delta)
        }
        clampScroll()
    }


    /// The range of entries within a screen of the viewport on either side.
    func wanted() -> Range<Int> {
        guard !entries.isEmpty, offsets.count == entries.count else { return 0..<0 }
        let overscan = max(480, viewHeight * 0.8)
        let top = scrollY - overscan
        let bottom = scrollY + viewHeight + overscan
        var low = 0
        var high = entries.count
        while low < high {
            let mid = (low + high) / 2
            let end = offsets[mid] + (heights[entries[mid].id] ?? estimate(entries[mid]))
            if end < top { low = mid + 1 } else { high = mid }
        }
        var upper = low
        while upper < entries.count, offsets[upper] <= bottom { upper += 1 }
        return low..<max(low, upper)
    }

    func needsRealizeNow() -> Bool {
        guard viewHeight > 0, boxWidth > 0 else { return false }
        if offsets.count != entries.count { return !entries.isEmpty }
        let want = Set(wanted().map { entries[$0].id })
        return want != Set(cells.keys)
    }

    func scheduleRealize() {
        guard !realizeScheduled else { return }
        realizeScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.realizeScheduled = false
            self.realize()
        }
    }

    /// How many times one `realize` may go round again before it hands the rest to the next run
    /// loop turn: a follow settles in two, and a story that never settles must not hold the main
    /// thread.
    static let realizePassLimit = 4

    /// Makes the items near the viewport and lets go of the rest, then places them.
    ///
    /// A follow that scrolls to the end posts a bounds change, whose observer asks for a realize in
    /// the middle of this one: the nested call is held back and made again right after, here and
    /// not on a later turn of the run loop, because a story that waited a frame for the rows at its
    /// new end showed that frame unrealized. It is a loop rather than the nested call itself, since
    /// a realize that ran itself again on every scroll it made would recurse until the stack ran
    /// out, and it is bounded for a story that never settles.
    func realize() {
        guard viewHeight > 0, boxWidth > 0 else { return }
        guard !realizing else {
            realizeAgain = true
            return
        }
        realizing = true
        defer { realizing = false }
        var passes = 0
        repeat {
            realizeAgain = false
            realizePass()
            passes += 1
        } while realizeAgain && passes < Self.realizePassLimit
        if realizeAgain {
            realizeAgain = false
            scheduleRealize()
        }
    }

    private func realizePass() {
        realizeCount += 1
        if offsets.count != entries.count { recomputeOffsets() }
        let range = wanted()
        let want = Set(range.map { entries[$0].id })
        for id in Array(cells.keys) where !want.contains(id) || entryIndex[id] == nil { drop(id) }
        for index in range {
            let entry = entries[index]
            let key = cellKey(entry)
            if let held = cells[entry.id] {
                if held.key == key, !held.stale { continue }
                drop(entry.id)
            }
            make(entry, key: key)
        }
        syncHeights()
        clampScroll()
        placeCells()
        if model.turn.outcome == .running, model.stepList.isFollowing, pendingReveal == nil { setScrollRaw(maxScroll) }
        let again = wanted()
        if Set(again.map { entries[$0].id }) != Set(cells.keys) { scheduleRealize() }
        for cell in cells.values { cell.visibleChanged(documentVisible) }
        isAnimating = scrollAnimating || !arrivals.isEmpty
    }

    var documentVisible: CGRect {
        CGRect(x: 0, y: scrollY, width: regionWidth, height: viewHeight)
    }

    private func make(_ entry: AccountEntry, key: String) {
        buildCount += 1
        let cell = buildCell(entry, key: key)
        cell.measuredHeight = cell.fit(width: boxWidth)
        cells[entry.id] = cell
        document.addSubview(cell)
        if arrivals[entry.id] != nil { animateArrival(cell) }
    }

    func drop(_ id: String) {
        guard let cell = cells.removeValue(forKey: id) else { return }
        if let window, let responder = window.firstResponder as? NSView, responder.isDescendant(of: cell) {
            window.makeFirstResponder(self)
        }
        cell.teardown()
        cell.removeFromSuperview()
    }

    func placeCells() {
        for (index, entry) in entries.enumerated() {
            guard let cell = cells[entry.id], index < offsets.count else { continue }
            let h = cell.measuredHeight
            let target = CGRect(x: padLeft, y: offsets[index], width: boxWidth, height: h)
            if cell.frame != target { cell.frame = target }
        }
    }

    /// An item changed its own height (a card was opened, a note unfolded): it is measured again
    /// and the story is laid out with the reader's place held.
    func cellHeightChanged(_ cell: AccountCell) {
        guard cells[cell.entryID] === cell else { return }
        cell.measuredHeight = cell.fit(width: boxWidth)
        syncHeights()
        placeCells()
        for held in cells.values { held.visibleChanged(documentVisible) }
    }

    private func animateArrival(_ cell: AccountCell) {
        arrivals[cell.entryID] = nil
        guard !reduceMotion, let layer = cell.layer else { return }
        let slide = CABasicAnimation(keyPath: "transform.translation.y")
        slide.fromValue = -12
        slide.toValue = 0
        slide.duration = Self.arrivalDuration
        slide.timingFunction = CAMediaTimingFunction(name: .easeOut)
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.55
        fade.toValue = 1
        fade.duration = Self.arrivalDuration
        layer.add(slide, forKey: "arrive.slide")
        layer.add(fade, forKey: "arrive.fade")
    }

    func scheduleJustNow(_ id: String) {
        justNow[id] = CACurrentMediaTime()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.justNowDuration + 0.05) { [weak self] in
            guard let self else { return }
            self.justNow[id] = nil
            self.scheduleRealize()
        }
    }


    func scrolled() {
        if needsRealizeNow() { realize() } else {
            for cell in cells.values { cell.visibleChanged(documentVisible) }
        }
    }

    func userScrolled() {
        pendingReveal = nil
        holdAnchor = nil
        scrollAnimating = false
        host?.browse(.scrolled(manual: true), grabFocus: false)
    }

    /// Moves the story to `y`: eased, or at once when the person asked for less movement or the
    /// distance is a long jump.
    func scrollTo(_ y: CGFloat, animated: Bool) {
        let target = min(max(y, 0), maxScroll)
        let clip = scroll.contentView
        guard abs(clip.bounds.origin.y - target) > 0.5 else { return }
        if animated, !reduceMotion, window != nil, host?.isVisible == true {
            scrollAnimating = true
            NSAnimationContext.runAnimationGroup(
                { context in
                    context.duration = 0.2
                    context.allowsImplicitAnimation = true
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    clip.animator().setBoundsOrigin(NSPoint(x: 0, y: target))
                },
                completionHandler: { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.scrollAnimating = false
                        if self.model.turn.outcome == .running, self.model.stepList.isFollowing {
                            self.setScrollRaw(self.maxScroll)
                        }
                        self.scroll.reflectScrolledClipView(self.scroll.contentView)
                        self.scrolled()
                    }
                })
        } else {
            setScrollRaw(target)
        }
    }

    func scrollToEnd(jump: Bool = false) {
        pendingReveal = nil
        scrollTo(maxScroll, animated: !jump)
    }

    func scrollToStart() {
        pendingReveal = nil
        scrollTo(0, animated: true)
    }

    /// After the items near the target have been measured the offsets are the real ones: a reveal
    /// that landed on an estimate is made again, once, without a second animation.
    func verifyReveal() {
        for delay in [0.06, 0.32] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self, self.pendingReveal != nil else { return }
                if !self.scrollAnimating { self.settleReveal() }
                if delay > 0.3 { self.pendingReveal = nil }
            }
        }
    }

    /// Puts a reveal on the real offset of its item, which the estimates it was aimed at may have
    /// moved by the time the items near it were measured.
    func settleReveal() {
        guard let reveal = pendingReveal, let at = entryIndex[reveal.id], at < offsets.count else { return }
        let target = min(max(offsets[at] - reveal.pad, 0), maxScroll)
        if abs(target - scrollY) > 2 { setScrollRaw(target) }
    }

    /// While a turn runs and the reader has not scrolled away, the account sits at its newest item.
    func followNewest() {
        let model = model
        guard model.turn.outcome == .running, model.stepList.isFollowing else { return }
        pendingReveal = nil
        updateDocument()
        let target = maxScroll
        scrollTo(target, animated: !(scrollY == 0 && target > viewHeight * 3))
    }

    /// A cursor that moved from somewhere else (a row, a node, a key) brings its item into view:
    /// aligned to the note that came before the work, so what it said is read with what it did.
    func followCursor() {
        let cursor = model.pinnedStep
        defer { lastCursor = cursor }
        guard let cursor, cursor != lastCursor else { return }
        if suppressReveal == cursor {
            suppressReveal = nil
            return
        }
        revealStep(cursor)
    }

    func jumpToLatest() {
        host?.browse(.jumpToLatest, grabFocus: false)
        scrollToEnd()
    }


    func isOpen(_ entry: AccountEntry, work: AccountEntry.Work) -> Bool {
        if unfolded.contains(entry.id) { return true }
        if let cursor = model.pinnedStep, work.stepIDs.contains(cursor) { return true }
        return liveTip(work: work)
    }

    /// The work line the running turn is writing into stays open while the account follows it.
    func liveTip(work: AccountEntry.Work) -> Bool {
        let model = model
        guard model.turn.outcome == .running, model.stepList.isFollowing, model.pinnedStep == nil,
            let last = model.steps.last?.id
        else { return false }
        return work.stepIDs.last == last
    }

    func rowCap(_ id: String) -> Int { rowCaps[id] ?? Self.initialRows }

    /// A settled turn's plan sits in the story, folded to its header once every item is done.
    func planStoryOpen(_ entry: AccountEntry, _ plan: NeuralAccount.Plan) -> Bool {
        if let override = planStoryOverride[entry.id] { return override }
        return plan.done < plan.total
    }

    func toggleText(_ id: String) {
        if expandedText.contains(id) { expandedText.remove(id) } else { expandedText.insert(id) }
        scheduleRealize()
    }

    /// A press on a work line folds it or opens it. A line holding the cursor is open for that
    /// reason, so folding it lets go of the cursor.
    func toggleWork(_ id: String) {
        guard let at = entryIndex[id], case .work(let work) = entries[at].kind else { return }
        if isOpen(entries[at], work: work) {
            unfolded.remove(id)
            if let cursor = model.pinnedStep, work.stepIDs.contains(cursor) {
                host?.browse(.key(.escape), grabFocus: false)
                if model.pinnedStep != nil { host?.updateModel { $0.clearSelection() } }
            }
        } else {
            unfolded.insert(id)
        }
        refresh(immediate: true)
    }

    func moreRows(_ id: String) {
        rowCaps[id] = min(Self.rowMax, rowCap(id) + Self.rowStride)
        scheduleRealize()
    }

    func togglePlan(_ entryID: String?) {
        if let entryID {
            var shown = false
            if let at = entryIndex[entryID], case .plan(let plan) = entries[at].kind {
                shown = planStoryOpen(entries[at], plan)
            }
            planStoryOverride[entryID] = !shown
        } else {
            let shown = planOpenOverride ?? !pinnedPlanCompact
            planOpenOverride = !shown
        }
        refresh(immediate: true)
    }
}
