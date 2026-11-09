import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

private let morning: Date = {
    var parts = DateComponents()
    parts.year = 2026
    parts.month = 11
    parts.day = 9
    parts.hour = 13
    parts.minute = 5
    return Calendar.current.date(from: parts)!
}()

private func at(_ minutes: Double) -> Date { morning.addingTimeInterval(minutes * 60) }

private func chapter(
    _ title: String, turn: Int, at minutes: Double, gist: String? = nil,
    by namer: ConversationChapter.Namer = .model, anchored: Bool = true
) -> ConversationChapter {
    ConversationChapter(
        title: title, turn: turn, messageID: anchored ? "u\(turn)" : nil, startedAt: at(minutes),
        gist: gist, namedBy: namer)
}

private let story = [
    chapter("Fix stream freeze on resume", turn: 1, at: 0, gist: "Traced the freeze to a 401 hang."),
    chapter("Bridge restarts wait for quiet", turn: 7, at: 130),
    chapter("Chat title history as chapters", turn: 13, at: 185, by: .person),
]

@Suite struct ChapterReadingTests {
    @Test func everyChapterReadsAsALineAndTheLastIsCurrent() {
        let reading = ChapterReading.read(story, turns: 17, now: at(240))
        #expect(reading.isShown)
        #expect(reading.lines.map(\.number) == [1, 2, 3])
        #expect(reading.lines.map(\.isCurrent) == [false, false, true])
        #expect(reading.lines[0].gist == "Traced the freeze to a 401 hang.")
        #expect(reading.lines[0].span.hasPrefix("Turns 1–6 · "))
        #expect(reading.lines[1].span.hasPrefix("Turns 7–12 · "))
        #expect(reading.lines[2].span.hasPrefix("Turns 13–17 · since "))
        #expect(reading.lines[2].note == "Named by you")
        #expect(reading.lines[0].note == nil)
        #expect(reading.lines[1].anchorID == "u7")
        #expect(reading.current?.title == "Chat title history as chapters")
        #expect(reading.fact == "3 chapters")
        #expect(reading.header.hasPrefix("3 chapters · since "))
        #expect(reading.lines[2].spoken.hasPrefix("Chapter 3 of 3, Chat title history as chapters, current."))
    }

    @Test func withoutACountTheCurrentChapterSaysWhereItBegan() {
        let reading = ChapterReading.read(story, now: at(240))
        #expect(reading.lines[2].span.hasPrefix("From turn 13 · since "))
        let single = ChapterReading.read([story[0], chapter("B", turn: 2, at: 10)], turns: 2, now: at(20))
        #expect(single.lines[0].span.hasPrefix("Turn 1 · "))
        #expect(single.lines[1].span.hasPrefix("Turn 2 · since "))
    }

    @Test func oneChapterOrNoneIsNothingToShow() {
        #expect(!ChapterReading.read([story[0]]).isShown)
        #expect(!ChapterReading.read([]).isShown)
        #expect(ChapterReading.headings([story[0]]).isEmpty)
    }

    @Test func theStripIsToScaleWithAFloorAndStopsPastTwelve() throws {
        let strip = try #require(ChapterReading.read(story, turns: 17).strip)
        #expect(strip.map(\.number) == [1, 2, 3])
        #expect(abs(strip.map(\.share).reduce(0, +) - 1) < 0.0001)
        #expect(strip[0].share > strip[2].share)
        #expect(strip.last?.isCurrent == true)

        let lopsided = [chapter("A", turn: 1, at: 0), chapter("B", turn: 200, at: 10)]
        let floored = try #require(ChapterReading.read(lopsided, turns: 200).strip)
        #expect(floored[1].share >= ChapterReading.stripFloor - 1e-9)

        let slivers = (0..<11).map { chapter("S\($0)", turn: $0 + 1, at: Double($0)) }
            + [chapter("Long", turn: 12, at: 20)]
        let pinned = try #require(ChapterReading.read(slivers, turns: 1011).strip)
        #expect(pinned.allSatisfy { $0.share >= ChapterReading.stripFloor - 1e-9 })
        #expect(abs(pinned.map(\.share).reduce(0, +) - 1) < 0.0001)
        #expect(pinned.last!.share > 0.5)

        let many = (0..<13).map { chapter("C\($0)", turn: $0 * 3 + 1, at: Double($0)) }
        #expect(ChapterReading.read(many).strip == nil)
        #expect(ChapterReading.read(Array(many.prefix(12))).strip?.count == 12)
    }

    @Test func headingsGoAboveEachOpeningMessageButNeverAboveAKeptFirstName() {
        let headings = ChapterReading.headings(story, now: at(240))
        #expect(Set(headings.keys) == ["u1", "u7", "u13"])
        #expect(headings["u7"]?.label == "Chapter 2")
        #expect(headings["u7"]?.title == "Bridge restarts wait for quiet")
        #expect(headings["u13"]?.spoken == "Chapter 3: Chat title history as chapters")

        let kept = [chapter("Old name", turn: 1, at: 0, by: .kept), chapter("New topic", turn: 9, at: 60)]
        #expect(Set(ChapterReading.headings(kept).keys) == ["u9"])
        #expect(ChapterReading.read(kept).lines[0].note == "Earlier names not kept")

        let unanchored = [story[0], chapter("Lost", turn: 5, at: 30, anchored: false)]
        #expect(Set(ChapterReading.headings(unanchored).keys) == ["u1"])
    }

    @Test func aHeadingFindsItsLineForThePanel() {
        let reading = ChapterReading.read(story)
        #expect(reading.line(for: "u7")?.number == 2)
        #expect(reading.line(for: "nope") == nil)
    }

    @Test func theBandSaysHowManyChaptersOnlyFromTwoAndLast() {
        var facts = StatusFacts()
        facts.chapters = 1
        #expect(!facts.segments.contains { $0.id == "chapters" })
        facts.chapters = 3
        facts.attachments = 1
        let segments = facts.segments
        #expect(segments.last?.id == "chapters")
        #expect(segments.last?.text == "§ 3 chapters")
        #expect(segments.last?.action == .chapters)
    }

    @Test func theChaptersKeyIsBoundAndItsSequenceDoesNotShadowTheTop() {
        let set = ShortcutSet.build(overrides: [:])
        #expect(set.issues.isEmpty)
        #expect(ShortcutRegistry.all.contains { $0.id == "chat.chapters" && $0.action == .showChapters })
        #expect(set.actions[.normal]?.values.contains(.showChapters) == true)
        #expect(set.actions[.normal]?.values.contains(.scrollTop) == true)
    }
}
