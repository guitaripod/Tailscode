import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

extension SelfTest {
    /// The chapters a server keeps reach the transcript as headings above each chapter's opening
    /// message — after the turn's rule, before the prompt — and nowhere for a single chapter or a
    /// first chapter named before chapters were kept; the band says how many, last, and gives the
    /// fact up first when it narrows.
    static func checkChapters() throws -> Int {
        var checks = 0
        let demo = ChapterDemo.conversation()
        let state = ConversationState(
            messages: demo.messages, status: .idle, hasLoadedTranscript: true, chapters: demo.chapters)
        let rows = TranscriptRowBuilder().rows(state: state)
        let headings = rows.enumerated().compactMap { index, row -> (Int, ChapterHeading)? in
            if case .chapterHeading(let heading) = row.kind { return (index, heading) }
            return nil
        }
        guard headings.map(\.1.number) == [1, 2, 3] else {
            throw SelfTestFailure("three chapters draw three headings in order: \(headings.map(\.1.number))")
        }
        checks += 1
        for (index, heading) in headings {
            let anchor = demo.chapters[heading.number - 1].messageID ?? ""
            guard rows[index].key == "chapter:" + anchor,
                index + 1 < rows.count, rows[index + 1].key.hasPrefix(anchor + ":")
            else {
                throw SelfTestFailure("chapter \(heading.number)'s heading sits right above its opening message")
            }
            if index > 0, case .turnBreak = rows[index - 1].kind {
            } else if index > 0 {
                throw SelfTestFailure("chapter \(heading.number)'s heading follows the turn's rule")
            }
        }
        checks += 1
        guard headings[1].1.title == demo.chapters[1].title,
            headings[1].1.label == Localized.text("Chapter %d", 2)
        else { throw SelfTestFailure("a heading wears its chapter's number and title") }
        checks += 1

        let one = ConversationState(
            messages: demo.messages, status: .idle, hasLoadedTranscript: true,
            chapters: [demo.chapters[0]])
        guard !TranscriptRowBuilder().rows(state: one).contains(where: { $0.key.hasPrefix("chapter:") })
        else { throw SelfTestFailure("one chapter draws no heading") }
        checks += 1

        var kept = demo.chapters
        kept[0].namedBy = .kept
        let keptState = ConversationState(
            messages: demo.messages, status: .idle, hasLoadedTranscript: true, chapters: kept)
        let keptKeys = TranscriptRowBuilder().rows(state: keptState).map(\.key).filter { $0.hasPrefix("chapter:") }
        guard keptKeys == ["chapter:chapter-demo-u3", "chapter:chapter-demo-u5"] else {
            throw SelfTestFailure("a kept first name draws no heading at the top: \(keptKeys)")
        }
        checks += 1

        let builder = TranscriptRowBuilder()
        _ = builder.rows(state: one)
        guard builder.rows(state: state).filter({ $0.key.hasPrefix("chapter:") }).count == 3 else {
            throw SelfTestFailure("a chapter opening with no new message still draws its heading")
        }
        checks += 1

        if let heading = rows.first(where: { $0.key == "chapter:chapter-demo-u3" }) {
            let widget = heading.makeWidget(context: TranscriptContext())
            g_object_ref_sink(widget)
            g_object_unref(widget)
        }
        checks += 1

        var facts = StatusFacts.from(state: state, agents: [], usage: nil, attachments: 0)
        guard facts.segments.last?.id == "chapters", facts.segments.last?.action == .chapters else {
            throw SelfTestFailure("the band's last fact is the chapter count and opens the panel")
        }
        facts.chapters = 1
        guard !facts.segments.contains(where: { $0.id == "chapters" }) else {
            throw SelfTestFailure("one chapter is no fact")
        }
        guard StatusBand.keepOrder.last == "chapters" else {
            throw SelfTestFailure("the band gives the chapter count up first when it narrows")
        }
        checks += 1

        let reading = ChapterReading.read(state.chapters, turns: 6)
        guard reading.isShown, reading.lines.count == 3, reading.lines.last?.isCurrent == true,
            reading.lines[0].gist != nil, reading.strip?.count == 3
        else { throw SelfTestFailure("the panel reads three chapters, the last current, the strip to scale") }
        checks += 1
        return checks
    }
}
