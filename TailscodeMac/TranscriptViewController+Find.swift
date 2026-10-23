import AppKit
import os
import CodingAgentKit
import TailscodeCore

extension TranscriptViewController {
    func setFindShown(_ shown: Bool) {
        if shown {
            findBar.isHidden = false
            identityBesideFind?.isActive = true
            findBar.focusField()
            startFindIndex()
            runFind(retarget: false)
        } else {
            guard !findBar.isHidden else { return }
            findIndexToken += 1
            findBar.isHidden = true
            identityBesideFind?.isActive = false
            findBar.clear()
            clearFindHighlight()
            findMatches = []
            view.window?.makeFirstResponder(nil)
        }
    }

    func configureFindBar() {
        findBar.isHidden = true
        findBar.onQueryChanged = { [weak self] _ in self?.runFind(retarget: true) }
        findBar.onStep = { [weak self] delta in self?.stepFind(by: delta) }
        findBar.onClose = { [weak self] in self?.setFindShown(false) }
    }

    /// What find reads in a row: its words, and for a brain the titles, arguments, thoughts and
    /// output lines of the steps it draws, which are the words a person saw in the old rows.
    private func searchText(of row: TranscriptRow) -> String {
        if case .brain(let brain) = row.kind {
            return findIndexed
                ? brains.searchText(turnID: brain.turnID)
                : brains.indexedSearchText(turnID: brain.turnID)
        }
        return row.searchText
    }

    /// Reads the words of the brains for find in slices of two milliseconds, newest first, while the
    /// bar is open and the pane can be seen, and searches again once every brain has been read, so
    /// the first keystroke never pays for the whole conversation.
    func startFindIndex() {
        findIndexed = false
        findIndexToken += 1
        sliceFindIndex(findIndexToken)
    }

    private func sliceFindIndex(_ token: Int) {
        DispatchQueue.main.async { [weak self] in
            guard let self, token == self.findIndexToken, !self.isParked, !self.findBar.isHidden,
                self.view.window != nil
            else { return }
            if self.brains.indexSearch(budget: 0.002) {
                self.findIndexed = true
                self.runFind(retarget: false)
            } else {
                self.sliceFindIndex(token)
            }
        }
    }

    func runFind(retarget: Bool) {
        let needle = findBar.query.lowercased()
        clearFindHighlight()
        guard !needle.isEmpty else {
            findMatches = []
            findBar.setCount("")
            return
        }
        findMatches = renderedRows.indices.filter {
            searchText(of: renderedRows[$0]).lowercased().contains(needle)
        }
        if retarget {
            findCursor = 0
            findStepAfterWidening = false
        }
        if findStepAfterWidening, !findMatches.isEmpty {
            findStepAfterWidening = false
            findCursor = findMatches.count - 1
            updateFindCount()
            applyFindHighlight(scroll: true)
            return
        }
        if findCursor >= findMatches.count { findCursor = max(0, findMatches.count - 1) }
        updateFindCount()
        guard !findMatches.isEmpty else { return }
        applyFindHighlight(scroll: retarget)
    }

    /// Whether the find bar is up with something to step through, for the menu's Find Next.
    var canStepFind: Bool {
        !findBar.isHidden && (!findMatches.isEmpty || earlierFindHits() > 0)
    }

    func stepFind(by delta: Int) {
        guard !findMatches.isEmpty else {
            guard earlierFindHits() > 0 else { return }
            findStepAfterWidening = true
            showEarlierRows()
            return
        }
        let count = findMatches.count
        findCursor = ((findCursor + delta) % count + count) % count
        updateFindCount()
        applyFindHighlight(scroll: true)
    }

    /// "No matches" is a claim about the conversation, and the search only ever ran over the tail
    /// window — so a word waiting behind the "… N earlier rows" button is counted and named. An
    /// absence of results reads as an answer, and that one would be a lie about the transcript.
    private func updateFindCount() {
        guard findMatches.isEmpty else {
            findBar.setCount("\(findCursor + 1)/\(findMatches.count)")
            return
        }
        let earlier = earlierFindHits()
        findBar.setCount(
            earlier > 0
                ? Localized.text("%@ in earlier rows", "\(earlier)")
                : Localized.text("No matches"))
    }

    /// Matches in rows the conversation holds and the window has not drawn.
    private func earlierFindHits() -> Int {
        let needle = findBar.query.lowercased()
        guard !needle.isEmpty else { return 0 }
        let shown = Set(renderedRows.map(\.key))
        return lastFullRows.filter {
            !shown.contains($0.key) && searchText(of: $0).lowercased().contains(needle)
        }.count
    }

    /// Marks the current match with a subtle accent ring, and on an explicit jump scrolls it to
    /// the upper third so the eye lands on the hit rather than hunting for it.
    private func applyFindHighlight(scroll: Bool) {
        guard findMatches.indices.contains(findCursor) else { return }
        let index = findMatches[findCursor]
        guard index < rowViews.count else { return }
        clearFindHighlight()
        let rowView = rowViews[index]
        rowView.wantsLayer = true
        highlightRestore = (
            rowView.layer?.backgroundColor, rowView.layer?.borderColor,
            rowView.layer?.borderWidth ?? 0, rowView.layer?.cornerRadius ?? 0)
        rowView.layer?.borderColor = MacTheme.Color.accent.withAlphaComponent(0.6).cgColor
        rowView.layer?.borderWidth = 2
        rowView.layer?.cornerRadius = 6
        rowView.layer?.backgroundColor = MacTheme.Color.findHit.cgColor
        highlightedView = rowView
        guard scroll else { return }
        if case .brain(let brain) = renderedRows[index].kind {
            brains.landFind(turnID: brain.turnID, needle: findBar.query)
        }
        followsBottom = false
        view.layoutSubtreeIfNeeded()
        let frame = rowView.convert(rowView.bounds, to: canvas)
        adjustScroll { _ in frame.minY - self.scrollView.contentView.bounds.height * 0.3 }
    }

    func clearFindHighlight() {
        if let layer = highlightedView?.layer, let restore = highlightRestore {
            layer.backgroundColor = restore.background
            layer.borderColor = restore.border
            layer.borderWidth = restore.width
            layer.cornerRadius = restore.radius
        }
        highlightRestore = nil
        highlightedView = nil
    }
}
