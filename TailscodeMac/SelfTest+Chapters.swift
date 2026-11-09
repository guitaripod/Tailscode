import AppKit
import CodingAgentKit
import TailscodeCore

extension SelfTest {
    /// The chapters a server keeps reach the transcript as headings above each chapter's opening
    /// message — after the turn's rule, before the prompt — and nowhere for one chapter or above a
    /// first chapter named before chapters were kept; a list that changes while the messages do not
    /// still redraws them; the band says how many, last; the popover lists every chapter with the
    /// current one last.
    @MainActor
    static func checkChapters() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("chapters: \(label)") }
            checks += 1
        }
        let demo = ChapterDemo.conversation()
        let builder = TranscriptRowBuilder()
        builder.chapters = demo.chapters
        let rows = builder.rows(for: demo.messages)
        let headingKeys = rows.map(\.key).filter { $0.hasSuffix(":chapter") }
        try expect(
            headingKeys == demo.chapters.compactMap { $0.messageID.map { "\($0):chapter" } },
            "three chapters draw three headings in order: \(headingKeys)")
        for key in headingKeys {
            guard let index = rows.firstIndex(where: { $0.key == key }) else { continue }
            let anchor = String(key.dropLast(":chapter".count))
            try expect(
                index + 1 < rows.count && rows[index + 1].key.hasPrefix(anchor + ":"),
                "the heading sits right above its opening message")
            if index > 0, case .turnBreak = rows[index - 1].kind {
            } else if index > 0 {
                throw SelfTestFailure("chapters: a heading follows its turn's rule")
            }
        }

        builder.chapters = [demo.chapters[0]]
        try expect(
            !builder.rows(for: demo.messages).contains { $0.key.hasSuffix(":chapter") },
            "one chapter draws no heading")
        builder.chapters = demo.chapters
        try expect(
            builder.rows(for: demo.messages).filter { $0.key.hasSuffix(":chapter") }.count == 3,
            "a chapter list that changes under the same messages redraws its headings")

        var kept = demo.chapters
        kept[0].namedBy = .kept
        builder.chapters = kept
        try expect(
            builder.rows(for: demo.messages).map(\.key).filter { $0.hasSuffix(":chapter") }
                == ["chapter-demo-u3:chapter", "chapter-demo-u5:chapter"],
            "a first name kept from before chapters draws no heading at the top")

        let context = TranscriptContext()
        var opened: String??
        context.openChapters = { opened = .some($0) }
        guard let headingRow = rows.first(where: { $0.key == "chapter-demo-u3:chapter" }),
            let view = headingRow.makeView(context: context) as? ChapterHeadingView
        else { throw SelfTestFailure("chapters: a heading row draws a heading view") }
        try expect(view.reading.contains(demo.chapters[1].title), "the heading wears its chapter's title")
        try expect(view.accessibilityPerformPress(), "a heading can be pressed")
        try expect(opened == .some("chapter-demo-u3"), "pressing a heading opens the panel on its chapter")

        let state = ConversationState(
            messages: demo.messages, status: .idle, hasLoadedTranscript: true, chapters: demo.chapters)
        let facts = StatusFacts.from(state: state, agents: [], usage: nil, attachments: 0)
        try expect(
            facts.segments.last?.id == "chapters" && facts.segments.last?.action == .chapters,
            "the band's last fact is the chapter count and opens the panel")

        let panel = ChaptersPanelViewController(
            focus: nil, read: { ChapterReading.read(demo.chapters, turns: 6) }, reveal: { _ in })
        _ = panel.view
        try expect(panel.rows.count == 3, "the popover lists every chapter")
        try expect(panel.rows.last?.line.isCurrent == true, "the last row is the current chapter")
        try expect(panel.rows.first?.line.gist != nil, "a closed chapter says what it came to")
        return checks
    }
}
