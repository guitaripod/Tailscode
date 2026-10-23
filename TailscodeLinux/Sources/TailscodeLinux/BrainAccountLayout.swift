import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

extension BrainAccount {
    /// The account's parts for a root of `size`, from the row's metrics: the header, the story
    /// beside the open step's detail when there is room for two columns, and the footer's key
    /// hints, which the narrow account drops.
    func frame(width: Double, height: Double) -> Frame {
        let m = owner.currentMetrics
        let split = m.arrangement == .split
        let twoColumns = split && m.accountLayout == .split
        let headerRect = NeuralRect(x: 0, y: 0, width: width, height: headerHeight)
        let footerH = split ? Self.footerHeight : 0
        let bodyTop = headerHeight
        let bodyHeight = max(0, height - bodyTop - footerH)
        let region = twoColumns ? m.story.width : width
        let padLeft = split ? Self.padLeft : 16
        let cap = split ? Self.storyMax : width
        let box = max(120, min(region, cap) - padLeft - Self.padRight)
        var pins: [(pin: Pin, rect: NeuralRect)] = []
        var cursor = bodyTop
        for pin in [askPin, nowPin, planPin].compactMap({ $0 }) {
            let rect = NeuralRect(x: padLeft, y: cursor + 8, width: box, height: pin.height)
            pins.append((pin, rect))
            cursor = rect.maxY
        }
        let storyTop = pins.isEmpty ? bodyTop : cursor + 8
        let storyRect = NeuralRect(x: 0, y: storyTop, width: region, height: max(0, bodyTop + bodyHeight - storyTop))
        let detail: NeuralRect? = twoColumns
            ? NeuralRect(
                x: m.story.width + NeuralStageMetrics.gutter, y: bodyTop + 4,
                width: max(0, width - m.story.width - NeuralStageMetrics.gutter), height: max(0, bodyHeight - 4))
            : nil
        return Frame(
            width: width, height: height, header: headerRect, pins: pins, story: storyRect,
            footer: split ? NeuralRect(x: 0, y: height - footerH, width: width, height: footerH) : nil,
            detail: detail, boxWidth: box, padLeft: padLeft, split: split, twoColumns: twoColumns)
    }

    /// The part of the root the open step's detail occupies, in the account's own coordinates; nil
    /// when the story holds it in place.
    func detailRect() -> NeuralRect? { frameCache?.detail }

    /// The body, for a dive or a replay that takes the whole of it.
    func bodyRect() -> NeuralRect? {
        guard let frame = frameCache else { return nil }
        return NeuralRect(
            x: 0, y: headerHeight, width: frame.width,
            height: max(0, frame.height - headerHeight - (frame.footer?.height ?? 0)))
    }

    func solveRoot(width: Int, height: Int, sink: OpaquePointer) {
        measureChrome(width: Double(width))
        let f = frame(width: Double(width), height: Double(height))
        frameCache = f
        place(sink, header, NeuralRect(x: 0, y: 0, width: f.width, height: f.header.height))
        for entry in f.pins { place(sink, entry.pin.widget, entry.rect) }
        let takenOver = owner.readoutHoldsBody
        if !takenOver {
            place(sink, story, f.story)
        }
        if let footer = f.footer { place(sink, self.footer, footer) }
        if !takenOver {
            place(sink, scrollbar, NeuralRect(x: f.story.maxX - 8, y: f.story.y, width: 8, height: f.story.height))
            if pillShown {
                let width = pillWidth
                place(
                    sink, pill,
                    NeuralRect(
                        x: f.story.x + (f.story.width - width) / 2,
                        y: f.story.maxY - 12 - 28, width: width, height: 28))
            }
        }
        let first = storyWidth != f.story.width || boxWidth != f.boxWidth || viewHeight != f.story.height
        storyWidth = f.story.width
        boxWidth = f.boxWidth
        setViewHeight(f.story.height)
        if first {
            Gtk.onMain { [weak self] in
                guard let self, !self.disposed else { return }
                self.geometryChanged()
            }
        }
    }

    /// The account's parts for the size the row is about to give it, so the detail beside the story
    /// is placed in the same pass.
    func touchFrame(width: Double, height: Double) {
        frameCache = frame(width: width, height: height)
    }

    /// How visible the story, the pinned ask and the footer are, for the first content landing
    /// after a move.
    func setBodyAlpha(_ alpha: Double) {
        for part in [story, footer, scrollbar] { gtk_widget_set_opacity(part, alpha) }
        for pin in [askPin, nowPin, planPin].compactMap({ $0 }) { gtk_widget_set_opacity(pin.widget, alpha) }
    }

    /// Says Copied on the note's button for a moment, and on the button of the item that replaces
    /// it if the item is made again meanwhile.
    func flashCopied(_ stepID: String) {
        copiedFlash = (stepID, BrainClock.now + 1.4)
        setCopyLabel(for: stepID)
        Gtk.after(1450) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, !self.disposed, let flash = self.copiedFlash, flash.stepID == stepID,
                    BrainClock.now >= flash.until
                else { return }
                self.copiedFlash = nil
                self.setCopyLabel(for: stepID)
            }
        }
    }

    func setCopyLabel(for stepID: String) {
        guard let item = account.item(containing: stepID), let button = cells[item.id]?.copyButton else { return }
        gtk_button_set_label(ptr(button), copyWord(for: stepID))
    }

    /// What a note's Copy button says: Copied while the press is a moment old.
    func copyWord(for stepID: String) -> String {
        if let flash = copiedFlash, flash.stepID == stepID, BrainClock.now < flash.until { return BrainWords.copied }
        return NeuralReading.copyLabel
    }

    func invalidateFocus() {
        gtk_widget_queue_draw(story)
    }

    var pillShown: Bool { gtk_widget_get_visible(pill) != 0 }

    var pillWidth: Double {
        var minimum: Int32 = 0
        var natural: Int32 = 0
        gtk_widget_measure(pill, GTK_ORIENTATION_HORIZONTAL, -1, &minimum, &natural, nil, nil)
        return Double(natural)
    }

    func place(
        _ sink: OpaquePointer, _ child: UnsafeMutablePointer<GtkWidget>?, _ rect: NeuralRect, dx: Double = 0,
        dy: Double = 0
    ) {
        guard let child else { return }
        tailscode_brain_row_place(
            sink, child, Int32((rect.x + dx).rounded()), Int32((rect.y + dy).rounded()),
            Int32(rect.width.rounded()), Int32(rect.height.rounded()))
    }

    /// The width or height the account's row changed: every item is measured again at the new
    /// width, and the items that exist are made again for it.
    func geometryChanged() {
        if holdAnchor == nil, let held = anchor(), held.index < entries.count {
            holdAnchor = (entries[held.index].id, held.delta)
        }
        holdFor(0.45)
        heights = [:]
        for (_, cell) in cells { cell.stale = true }
        scheduleRealize()
    }

    /// Keeps the item at the top of the viewport where it is until the heights have settled: after a
    /// resize every item is measured again at its new width, and the page must not move under the
    /// reader while the estimates are replaced by measurements.
    func holdFor(_ seconds: Double) {
        holdTicket += 1
        let ticket = holdTicket
        Gtk.after(UInt32(seconds * 1000)) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, self.holdTicket == ticket else { return }
                self.holdAnchor = nil
            }
        }
    }

    func gap(before index: Int) -> Double {
        guard index > 0 else { return 0 }
        if entries[index].isSaid, entries[index - 1].isSaid { return Self.said12 }
        if entries[index].isResult { return Self.gap }
        return Self.gap
    }

    func estimate(_ entry: AccountEntry) -> Double {
        let measure = max(160, min(boxWidth - 72, proseProbe.em * 36))
        let perLine = max(8, measure / (proseProbe.em * 0.52))
        switch entry.kind {
        case .said(let said):
            let lines = said.text.split(separator: "\n", omittingEmptySubsequences: false).reduce(0) {
                $0 + max(1, Int((Double($1.count) / perLine).rounded(.up)))
            }
            let shown = expandedText.contains(entry.id) ? lines : min(lines, 6)
            return 4 + (said.showsSpeaker ? 20 : 0) + Double(shown) * proseProbe.line + (lines > 6 ? 22 : 0)
        case .thought:
            return expandedText.contains(entry.id) ? 64 : 24
        case .work(let work):
            guard isOpen(entry, work: work) else { return 36 }
            return 36 + Double(min(work.stepIDs.count, rowCap(entry.id))) * 28 + 10
        case .asked:
            return 52
        case .plan(let plan):
            return planStoryOpen(entries[0], plan) ? Double(24 + plan.items.count * 24 + 16) : 36
        case .result(let result):
            return Double(40 + (result.changes.count + result.checks.count + result.unfixed.count) * 28 + 90)
        }
    }

    func isOpen(_ entry: AccountEntry, work: AccountEntry.Work) -> Bool {
        if unfolded.contains(entry.id) { return true }
        if let cursor = owner.model.pinnedStep, work.stepIDs.contains(cursor) { return true }
        return liveTip(work: work)
    }

    /// The work line the running turn is writing into stays open while the account follows it.
    func liveTip(work: AccountEntry.Work) -> Bool {
        let model = owner.model
        guard model.turn.outcome == .running, model.stepList.isFollowing, model.pinnedStep == nil,
            let last = model.steps.last?.id
        else { return false }
        return work.stepIDs.last == last
    }

    func rowCap(_ id: String) -> Int { rowCaps[id] ?? Self.initialRows }

    static let initialRows = 40

    static let rowStride = 40

    static let rowMax = 400

    func recomputeOffsets() {
        var y = 0.0
        var made: [Double] = []
        made.reserveCapacity(entries.count)
        for (index, entry) in entries.enumerated() {
            y += gap(before: index)
            made.append(y)
            y += heights[entry.id] ?? estimate(entry)
        }
        offsets = made
        total = y + 16
    }

    var maxScroll: Double { max(0, total - viewHeight) }

    /// The entry at the top of the viewport and how far it stands below the top: held across a
    /// change of heights so what is being read does not move.
    func anchor() -> (index: Int, delta: Double)? {
        guard !entries.isEmpty, offsets.count == entries.count else { return nil }
        var low = 0
        var high = entries.count - 1
        while low < high {
            let mid = (low + high) / 2
            let bottom = offsets[mid] + (heights[entries[mid].id] ?? estimate(entries[mid]))
            if bottom > scroll { high = mid } else { low = mid + 1 }
        }
        return (low, scroll - offsets[low])
    }

    func clampScroll() {
        target = min(max(target, 0), maxScroll)
        scroll = min(max(scroll, 0), maxScroll)
    }

    /// Measures the items that exist at the width they are laid out at; when any is not the height
    /// it was thought to be, the offsets are made again with the reader's place held.
    func syncHeights() {
        var changed = false
        for (id, cell) in cells {
            guard entryIndex[id] != nil else { continue }
            fitHolders(cell)
            let h = cell.measure(width: boxWidth)
            if abs((heights[id] ?? -1) - h) > 0.5 {
                heights[id] = h
                changed = true
            }
        }
        guard changed || offsets.count != entries.count else { return }
        let held = anchor()
        let wasAtEnd = maxScroll > 0 && scroll >= maxScroll - 0.5
        let aimedAtEnd = maxScroll > 0 && target >= maxScroll - 0.5
        recomputeOffsets()
        if let held, held.index < offsets.count {
            let moved = offsets[held.index] + held.delta - scroll
            scroll += moved
            target += moved
        }
        if let hold = holdAnchor, let at = entryIndex[hold.id], pendingReveal == nil {
            scroll = offsets[at] + hold.delta
            target = scroll
        }
        if let reveal = pendingReveal, let at = entryIndex[reveal.id] {
            target = min(max(offsets[at] - reveal.pad, 0), maxScroll)
        } else if owner.model.stepList.isFollowing {
            if wasAtEnd {
                scroll = maxScroll
                target = maxScroll
            } else if aimedAtEnd {
                target = maxScroll
            }
        }
        clampScroll()
    }

    /// Narrows a cell's prose to the box the instant the box narrows, before the cell is made
    /// again for the new width, so the toolkit is never asked to lay a measure out in less room
    /// than it asked for.
    func fitHolders(_ cell: AccountCell) {
        guard !cell.holders.isEmpty, cell.holdersWidth != boxWidth else { return }
        cell.holdersWidth = boxWidth
        for held in cell.holders {
            let measure = max(120, min(proseProbe.em * 36, boxWidth - held.inset))
            gtk_widget_set_size_request(held.widget, Int32(measure.rounded()), -1)
        }
    }

    /// Sets how tall the story's window is. A story that is following its end and was sitting at it
    /// stays there when the window shrinks or grows, which is what a Now line appearing above it
    /// does, rather than being left a few points short of the newest item.
    func setViewHeight(_ height: Double) {
        guard height != viewHeight else { return }
        let atEnd = maxScroll > 0 && scroll >= maxScroll - 0.5 && target >= maxScroll - 0.5
        let aimedAtEnd = maxScroll > 0 && target >= maxScroll - 0.5
        viewHeight = height
        guard owner.model.stepList.isFollowing else { return }
        if atEnd, scroll < maxScroll {
            scroll = maxScroll
            target = maxScroll
        } else if aimedAtEnd {
            target = maxScroll
        }
    }

    func solveStory(width: Int, height: Int, sink: OpaquePointer) {
        let begun = DispatchTime.now().uptimeNanoseconds
        setViewHeight(Double(height))
        syncHeights()
        let now = BrainClock.now
        for index in 0..<entries.count {
            let entry = entries[index]
            guard let cell = cells[entry.id], index < offsets.count else { continue }
            fitHolders(cell)
            let h = heights[entry.id] ?? cell.measure(width: boxWidth)
            var dy = 0.0
            var alpha = 1.0
            if let start = arrivals[entry.id] {
                let t = min(1, max(0, (now - start) / Self.arrivalDuration))
                dy = 12 * (1 - NeuralTransition.easeOutCubic(t))
                alpha = 0.55 + 0.45 * t
            }
            let top = offsets[index] - scroll + dy
            guard top + h > -40, top < Double(height) + 40 else { continue }
            gtk_widget_set_opacity(cell.widget, alpha)
            fitHolders(cell)
            let pad = frameCache?.padLeft ?? Self.padLeft
            tailscode_brain_row_place(sink, cell.widget, Int32(pad), Int32(top.rounded()), Int32(boxWidth.rounded()), Int32(h.rounded()))
        }
        if needsRealizeNow() { scheduleRealize() }
        let spent = DispatchTime.now().uptimeNanoseconds - begun
        solveNanoseconds += spent
        worstSolve = max(worstSolve, spent)
        solves += 1
    }
}
