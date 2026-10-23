import AppKit
import os
import CodingAgentKit
import TailscodeCore

extension TranscriptViewController {
    /// A chat's page as it was left: the column of rows already built and everything those rows
    /// were built against — which ones were open, the agents' transcripts fetched into their cards,
    /// the boards read, the pictures still wanted — so coming back to a chat just left is a swap
    /// and a diff instead of building every row again.
    struct KeptPage {
        let column: TranscriptColumn
        let renderedRows: [TranscriptRow]
        let rowViews: [NSView]
        let enteredRows: Set<String>
        let expanded: TranscriptExpansion
        let subagentRows: [String: [TranscriptRow]]
        let designBoards: [String: DesignManifest]
        let wantedImages: [String: FileReference]
        let lastFullRows: [TranscriptRow]
        let windowLimit: Int
        let rowTailMessages: Int
    }

    /// Three chats back is where going back and forth between conversations ends and a day of them
    /// begins; a page is the size of its rows, and a pane keeping every chat it ever showed would
    /// be a pane holding the day.
    private static let keptLimit = 3

    /// Sets the page being left aside for when its chat comes back, if it is a page that can be
    /// shown again as it stands. One still being written, one holding a sent prompt up at the top,
    /// or one not finished building is rebuilt instead: its rows are mid-motion, and a page put back
    /// mid-motion is a page showing a moment that has already passed.
    func keepPage(of leaving: SessionEntry?) {
        guard let leaving, !placeholderShown, fillComplete, cascade.key == nil,
            lastStreamedKey == nil, canvasHold == nil, !rowViews.isEmpty
        else { return }
        let key = SessionPinStore.key(leaving.profileID, leaving.session.id)
        clearFindHighlight()
        let page = KeptPage(
            column: rowColumn, renderedRows: renderedRows, rowViews: rowViews,
            enteredRows: enteredRows, expanded: context.expanded,
            subagentRows: context.subagentRows, designBoards: context.designBoards,
            wantedImages: wantedImages, lastFullRows: lastFullRows, windowLimit: windowLimit,
            rowTailMessages: rowTailMessages)
        placeColumn(TranscriptColumn())
        renderedRows = []
        rowViews = []
        enteredRows = []
        wantedImages = [:]
        placeholderShown = true
        keptPages[key] = page
        keptOrder.removeAll { $0 == key }
        keptOrder.append(key)
        while keptOrder.count > Self.keptLimit {
            keptPages[keptOrder.removeFirst()] = nil
        }
    }

    /// The page kept for this chat, back in the canvas at the end the reader returns to.
    func restorePage(_ page: KeptPage) {
        tearDownAllRows()
        placeColumn(page.column)
        renderedRows = page.renderedRows
        rowViews = page.rowViews
        enteredRows = page.enteredRows
        context.expanded = page.expanded
        context.subagentRows = page.subagentRows
        context.designBoards = page.designBoards
        wantedImages = page.wantedImages
        lastFullRows = page.lastFullRows
        windowLimit = page.windowLimit
        rowTailMessages = page.rowTailMessages
        placeholderShown = false
        currentPlaceholder = nil
        hideEmptyState()
        fillComplete = true
        pendingReveal = false
        canvas.alphaValue = 1
        settleOnTail()
        syncJumpPill()
        scheduleImageSweep()
    }

    /// Puts a column in the canvas where the rows go, between the button that widens the window
    /// and the cards docked under the transcript.
    private func placeColumn(_ column: TranscriptColumn) {
        guard column !== rowColumn else { return }
        let index = canvas.arrangedSubviews.firstIndex(of: rowColumn) ?? 1
        canvas.removeArrangedSubview(rowColumn)
        rowColumn.removeFromSuperview()
        column.spacing = MacTheme.Spacing.m
        column.metrics = ChatLayout.metrics
        column.translatesAutoresizingMaskIntoConstraints = false
        canvas.insertArrangedSubview(column, at: index)
        rowColumn = column
    }

    /// At most a handful of transcripts are kept renderable; the oldest falls out so a long day
    /// of chats does not become a memory of every one of them.
    func rememberRows(_ rows: [TranscriptRow], for pageKey: String) {
        if sessionRows[pageKey] == nil {
            sessionRowOrder.append(pageKey)
            if sessionRowOrder.count > 6 {
                let evicted = sessionRowOrder.removeFirst()
                sessionRows[evicted] = nil
            }
        }
        sessionRows[pageKey] = rows
    }

    func tearDownAllRows() {
        enteredRows.removeAll(keepingCapacity: true)
        wantedImages.removeAll(keepingCapacity: true)
        clearFindHighlight()
        rowViews.forEach { $0.removeFromSuperview() }
        rowViews = []
        renderedRows = []
    }

    /// A cache arrival (a decoded picture, a fetched subagent transcript) redraws exactly the rows
    /// it belongs to, in place: the view is swapped where it stands, every other row keeps its
    /// state, and nothing scrolls. It is not new content — the unseen counter never moves.
    func replaceRows(where predicate: (TranscriptRow) -> Bool) {
        guard !placeholderShown else { return }
        if pointerHeld {
            heldReplacements.formUnion(renderedRows.filter(predicate).map(\.key))
            watchPointer()
            return
        }
        preservingScroll { () -> Void in
            for index in renderedRows.indices where predicate(renderedRows[index]) {
                guard index < rowViews.count else { continue }
                if rowViews[index] === highlightedView { clearFindHighlight() }
                let standing = rowViews[index].superview?.frame.height
                rowViews[index].removeFromSuperview()
                let rowView = renderedRows[index].makeView(context: context)
                rowColumn.insertArrangedSubview(
                    rowView, at: index, spacing: renderedRows[index].spacing,
                    standingIn: standing)
                rowViews[index] = rowView
            }
        }
        if followsBottom { schedulePinCorrector() }
    }
}
