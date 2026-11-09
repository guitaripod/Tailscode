import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

extension ChatPane {
    /// The chapters panel for this conversation, on the chapter a heading named or on the current
    /// one. A conversation still in its first chapter has nothing to show, and says so.
    func openChapters(at anchor: String?) {
        guard lastState?.chapters.count ?? 0 >= 2 else {
            host?.toast(Localized.text("This chat is still in its first chapter."))
            return
        }
        ChaptersPanel.present(
            parent: host?.windowWidget, focus: anchor,
            goTo: { [weak self] messageID in
                Gtk.onMain { [weak self] in self?.scrollToChapter(messageID) }
            },
            read: { [weak self] in self?.chapterReading() })
    }

    func chapterReading() -> ChapterReading? {
        guard let state = lastState else { return nil }
        return ChapterReading.read(state.chapters, turns: userTally.users(in: state.messages))
    }

    /// Takes the transcript to where a chapter began: its heading when the pane draws one, else
    /// its opening message. A chapter that began above the rows the pane holds widens the window to
    /// it — the message tail the rows are built from and the rows drawn — and lands once those
    /// rows are on screen, rather than doing nothing.
    func scrollToChapter(_ messageID: String) {
        if let index = renderedRows.firstIndex(where: { Self.isChapterRow($0, of: messageID) }) {
            pendingChapterJump = nil
            scrollToRow(at: index)
            return
        }
        guard let state = lastState,
            let position = state.messages.firstIndex(where: { $0.id == messageID })
        else {
            host?.toast(Localized.text("That chapter began before what this chat has loaded."))
            return
        }
        pendingChapterJump = messageID
        followsBottom = false
        let needed = state.messages.count - position + 40
        if needed > rowTailMessages { rowTailMessages = needed }
        windowWidened = true
        apply(state: state, rows: lastFullRows)
        feed.rebuild(state)
    }

    /// Whether a row is where the named chapter begins: its heading, or the first row its opening
    /// message drew.
    static func isChapterRow(_ row: TranscriptRow, of messageID: String) -> Bool {
        row.key == "chapter:" + messageID || row.key.hasPrefix(messageID + ":")
    }

    /// A conversation three chapters long, for photographing the headings, the band's fact and the
    /// panel headlessly: ``ChapterDemo``'s, the same words every client shows.
    func driverChaptersDemo() {
        releaseStream()
        chatLife.cancelAll()
        streamGeneration &+= 1
        let generation = streamGeneration
        feed.update { $0.generation = generation }
        let demo = ChapterDemo.conversation()
        let state = ConversationState(
            messages: demo.messages, status: .idle, hasLoadedTranscript: true,
            chapters: demo.chapters)
        apply(state: state, rows: rowBuilder.rows(state: state))
        updateStatus()
    }
}
