import AppKit
import CodingAgentKit
import TailscodeCore

extension TranscriptViewController {
    /// The chapters popover for this conversation, off the heading that was pressed or off the
    /// band, on the chapter a heading named or on the current one. A conversation still in its
    /// first chapter has nothing to show, and says so.
    func openChapters(at anchor: String?) {
        guard let state = lastState, state.chapters.count >= 2 else {
            onToast?(Localized.text("This chat is still in its first chapter."))
            return
        }
        if let popover = chaptersPopover, popover.isShown, let panel = chaptersPanel {
            panel.focus(on: anchor)
            return
        }
        let panel = ChaptersPanelViewController(
            focus: anchor,
            read: { [weak self] in self?.chapterReading() },
            reveal: { [weak self] messageID in
                self?.chaptersPopover?.close()
                self?.scrollToChapter(messageID)
            })
        let popover = NSPopover()
        popover.behavior = .transient
        popover.ground(panel)
        let source = anchor.flatMap(headingView(for:)) ?? bandAnchor
        popover.show(relativeTo: source.bounds, of: source, preferredEdge: .maxY)
        chaptersPopover = popover
        chaptersPanel = panel
    }

    func chapterReading() -> ChapterReading? {
        guard let state = lastState else { return nil }
        return ChapterReading.read(
            state.chapters, turns: state.messages.reduce(0) { $0 + ($1.role == .user ? 1 : 0) })
    }

    /// Takes the transcript to where a chapter began: its heading when the pane draws one, else
    /// its opening message. A chapter that began above the messages and rows the pane holds widens
    /// both to it and lands there, rather than doing nothing.
    func scrollToChapter(_ messageID: String) {
        if holds(messageID) {
            pendingChapterJump = nil
            scrollToMessage(messageID, part: "\(messageID):chapter")
            return
        }
        guard let state = lastState,
            let position = state.messages.firstIndex(where: { $0.id == messageID })
        else {
            onToast?(Localized.text("That chapter began before what this chat has loaded."))
            return
        }
        followsBottom = false
        chapterWidened = true
        pendingChapterJump = messageID
        rowTailMessages = max(rowTailMessages, state.messages.count - position + 40)
        rebuildRows()
        if let index = lastFullRows.firstIndex(where: { Self.opens($0, messageID) }) {
            windowLimit = max(windowLimit, lastFullRows.count - index + 8)
            rebuildRows()
        }
        if holds(messageID), fillComplete {
            pendingChapterJump = nil
            scrollToMessage(messageID, part: "\(messageID):chapter")
        }
    }

    private func holds(_ messageID: String) -> Bool {
        renderedRows.contains { Self.opens($0, messageID) }
    }

    private static func opens(_ row: TranscriptRow, _ messageID: String) -> Bool {
        row.key.hasPrefix("\(messageID):")
    }

    private func headingView(for messageID: String) -> NSView? {
        guard let index = renderedRows.firstIndex(where: { $0.key == "\(messageID):chapter" }),
            index < rowViews.count
        else { return nil }
        return rowViews[index]
    }

    /// A conversation three chapters long drawn as though it had just arrived — ``ChapterDemo``'s,
    /// the words every client shows — for `--open chapters`, with the popover up (`open`) or the
    /// transcript taken to the second chapter (`jump`).
    func showChapterDemo(opening: String?) {
        let demo = ChapterDemo.conversation()
        let state = ConversationState(
            messages: demo.messages, status: .idle, hasLoadedTranscript: true, chapters: demo.chapters)
        apply(state: state, rows: buildRows(state.messages, state: state))
        switch opening {
        case "open": openChapters(at: nil)
        case "jump": scrollToChapter(demo.chapters[1].messageID ?? "")
        default: break
        }
    }
}
