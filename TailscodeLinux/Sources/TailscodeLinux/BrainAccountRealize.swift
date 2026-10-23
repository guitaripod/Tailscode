import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

extension BrainAccount {
    /// The range of entries within a screen of the viewport on either side.
    func wanted() -> Range<Int> {
        guard !entries.isEmpty, offsets.count == entries.count else { return 0..<0 }
        let overscan = max(480, viewHeight * 0.8)
        let top = scroll - overscan
        let bottom = scroll + viewHeight + overscan
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
        guard viewHeight > 0 else { return false }
        let range = wanted()
        let want = Set(range.map { entries[$0].id })
        return want != Set(cells.keys)
    }

    /// The next few items of a story that is being made a few at a time.
    func continueRealize() {
        guard pendingRealize else { return }
        pendingRealize = false
        realize()
    }

    /// Every item the story still wants, when the move that was making them a few at a time ends.
    func finishRealize() {
        makeCap = nil
        guard pendingRealize else { return }
        pendingRealize = false
        realize()
    }

    func scheduleRealize() {
        guard !realizeScheduled, !disposed else { return }
        realizeScheduled = true
        Gtk.onMain { [weak self] in
            guard let self, !self.disposed else { return }
            self.realizeScheduled = false
            self.realize()
        }
    }

    /// Makes the items near the viewport and lets go of the rest, then lays out once more.
    func realize() {
        guard !disposed, viewHeight > 0, boxWidth > 0 else { return }
        let begun = DispatchTime.now().uptimeNanoseconds
        defer { realizeNanoseconds += DispatchTime.now().uptimeNanoseconds - begun }
        realizeCount += 1
        if offsets.count != entries.count { recomputeOffsets() }
        let range = wanted()
        let want = Set(range.map { entries[$0].id })
        for id in Array(cells.keys) where !want.contains(id) || entryIndex[id] == nil { drop(id) }
        var made = 0
        var capped = false
        for index in range {
            let entry = entries[index]
            let key = cellKey(entry)
            if let held = cells[entry.id] {
                if held.key == key, !held.stale { continue }
                drop(entry.id)
            }
            if let cap = makeCap, made >= cap {
                capped = true
                break
            }
            make(entry, key: key)
            made += 1
        }
        pendingRealize = capped
        syncHeights()
        clampScroll()
        let again = wanted()
        if !capped, Set(again.map { entries[$0].id }) != Set(cells.keys) { scheduleRealize() }
        tailscode_brain_row_invalidate(story)
        tailscode_brain_row_invalidate(root)
    }

    func make(_ entry: AccountEntry, key: String) {
        buildCount += 1
        let cell = buildCell(entry, key: key)
        cells[entry.id] = cell
        tailscode_brain_row_add(story, cell.widget)
    }

    /// Takes an item off the story. The keyboard is moved to the story itself first, so no widget
    /// that has focus is ever unparented.
    func drop(_ id: String) {
        guard let cell = cells.removeValue(forKey: id) else { return }
        releaseFocus(in: cell.widget)
        cell.teardown()
        tailscode_brain_row_remove(story, cell.widget)
    }

    func releaseFocus(in widget: UnsafeMutablePointer<GtkWidget>) {
        guard let window = gtk_widget_get_root(story),
            let focused = gtk_root_get_focus(OpaquePointer(UnsafeMutableRawPointer(window)))
        else { return }
        guard focused == widget || gtk_widget_is_ancestor(focused, widget) != 0 else { return }
        gtk_widget_grab_focus(story)
    }

    func teardown() {
        disposed = true
        for id in Array(cells.keys) {
            cells[id]?.teardown()
            cells[id] = nil
        }
    }

    /// The model changed: a step arrived, a status moved, a filter was set, the cursor or the hover
    /// went elsewhere. The account is read again, and what is on screen is brought to it.
    func refresh(immediate: Bool = false) {
        guard !disposed else { return }
        let begun = DispatchTime.now().uptimeNanoseconds
        defer {
            refreshNanoseconds += DispatchTime.now().uptimeNanoseconds - begun
            refreshes += 1
        }
        let now = BrainClock.now
        if !immediate, now - lastRefresh < 0.06 {
            guard !refreshPending else { return }
            refreshPending = true
            Gtk.after(60) { [weak self] in
                Gtk.onMain { [weak self] in
                    guard let self, !self.disposed else { return }
                    self.refreshPending = false
                    self.refresh(immediate: true)
                }
            }
            return
        }
        lastRefresh = now
        let model = owner.model
        let list = model.browseState.list
        let next = model.account(
            answer: owner.row.answer.isEmpty ? nil : owner.row.answer, prompt: owner.row.prompt)
        let stamp = ReadStamp(
            reads: model.accountReads, filter: list.filter, total: list.total, visible: list.visibleCount,
            following: list.isFollowing, outcome: model.turn.outcome, answer: owner.row.answer.utf8.count)
        guard stamp != readStamp || entries.isEmpty else {
            followCursor()
            clampScroll()
            scheduleRealize()
            owner.listAnimationChanged()
            return
        }
        readStamp = stamp
        account = next
        let made = AccountEntries.make(model: model, account: next, list: list)
        let live = model.turn.outcome == .running
        let fresh = made.filter { !knownIDs.contains($0.id) }
        if seeded, live, list.isFollowing, !BrainBudget.reduceMotion {
            for entry in fresh {
                arrivals[entry.id] = now
                if entry.isSaid { justNow[entry.id] = now }
            }
        }
        knownIDs.formUnion(made.map(\.id))
        seeded = true
        entries = made
        entryIndex = Dictionary(uniqueKeysWithValues: made.enumerated().map { ($1.id, $0) })
        heights = heights.filter { entryIndex[$0.key] != nil }
        workStamps = [:]
        for entry in made {
            guard case .work(let work) = entry.kind else { continue }
            var hasher = Hasher()
            for id in work.stepIDs {
                guard let step = model.step(id: id) else { continue }
                hasher.combine(id)
                hasher.combine(step.status)
                hasher.combine(step.outputLines.count)
                hasher.combine(step.call?.call.output?.utf8.count ?? 0)
            }
            workStamps[entry.id] = hasher.finalize()
        }
        recomputeOffsets()
        refreshChrome()
        followCursor()
        followNewest()
        clampScroll()
        scheduleRealize()
        tailscode_brain_row_invalidate(root)
        tailscode_brain_row_invalidate(story)
        gtk_widget_queue_draw(scrollbar)
        owner.listAnimationChanged()
    }

    /// While a turn runs and the reader has not scrolled away, the account sits at its newest item.
    func followNewest() {
        let model = owner.model
        guard model.turn.outcome == .running, model.stepList.isFollowing else { return }
        pendingReveal = nil
        target = maxScroll
        if BrainBudget.reduceMotion || (scroll == 0 && target > viewHeight * 3) { scroll = target }
    }

    /// A cursor that moved from somewhere else (a row, a node, a key) brings its item into view:
    /// aligned to the note that came before the work, so what it said is read with what it did.
    func followCursor() {
        let cursor = owner.model.pinnedStep
        defer { lastCursor = cursor }
        guard let cursor, cursor != lastCursor else { return }
        if suppressReveal == cursor {
            suppressReveal = nil
            return
        }
        revealStep(cursor)
    }

    func revealStep(_ stepID: String) {
        guard let item = account.item(containing: stepID), var at = entryIndex[item.id] else {
            return
        }
        if entries[at].isWork, at > 0, entries[at - 1].isSaid { at -= 1 }
        pendingReveal = (entries[at].id, 8)
        target = min(max(offsets[at] - 8, 0), maxScroll)
        if BrainBudget.reduceMotion { scroll = target }
        owner.listAnimationChanged()
    }
}
