import CodingAgentKit
import Foundation

/// One chapter as the panel lists it: its number, its name, what it came to, where it sits in the
/// conversation, and the message it began at.
public struct ChapterLine: Sendable, Hashable, Identifiable {
    public let id: String
    public let number: Int
    public let title: String
    public let gist: String?
    /// The person's messages it spans and when: "Turns 4–9 · 15:15–16:02", "From turn 13 · since
    /// 16:10".
    public let span: String
    /// Who named it, said only when it was not the server's own model or the first message.
    public let note: String?
    /// The message the chapter began at; a jump goes there.
    public let anchorID: String?
    public let isCurrent: Bool
    /// Everything above in one sentence for a screen reader, number and place first.
    public let spoken: String
}

/// One piece of the strip that draws the conversation's chapters to scale.
public struct ChapterStripPiece: Sendable, Hashable {
    public let number: Int
    public let share: Double
    public let isCurrent: Bool
}

/// The heading a transcript draws above the message a chapter began at.
public struct ChapterHeading: Sendable, Hashable {
    public let number: Int
    public let title: String
    /// "Chapter 3", the line's small label.
    public let label: String
    /// When it began, the way a clock reads it: "16:10", or the day too when that was not today.
    public let time: String
    public let spoken: String
}

/// How a conversation got where it is: the chapters a server keeps, read for the panel, the band
/// and the transcript's headings. Built from the chapter list alone — never by walking the
/// transcript — so nothing here costs the size of the conversation.
public struct ChapterReading: Sendable, Hashable {
    public let lines: [ChapterLine]
    /// "3 chapters · since 13:05".
    public let header: String
    /// The band's and facts row's words: "3 chapters".
    public let fact: String
    /// The chapters drawn to scale by the person's messages in each, or nil when there are too
    /// many to draw as more than slivers — the list says the same thing then.
    public let strip: [ChapterStripPiece]?

    /// The strip draws at most this many chapters.
    public static let stripLimit = 12
    /// No piece of the strip is drawn thinner than this share, so a one-message chapter is still a
    /// mark a finger or a pointer can find.
    public static let stripFloor = 0.04

    /// Whether there is a story to tell: one chapter is only the title again.
    public var isShown: Bool { lines.count >= 2 }

    public var current: ChapterLine? { lines.last }

    /// Reads the chapters. `turns` is how many messages the person has sent, when the caller knows
    /// it, so the current chapter's span can be counted; without it the current chapter reads
    /// "From turn n".
    public static func read(
        _ chapters: [ConversationChapter], turns: Int? = nil, now: Date = Date()
    ) -> ChapterReading {
        let count = chapters.count
        var lines: [ChapterLine] = []
        lines.reserveCapacity(count)
        for (index, chapter) in chapters.enumerated() {
            let next = index + 1 < count ? chapters[index + 1] : nil
            let isCurrent = next == nil
            let span = Self.span(chapter, next: next, turns: turns, now: now)
            let note = Self.note(for: chapter.namedBy)
            var spoken = Localized.text("Chapter %d of %d, %@", index + 1, count, chapter.title)
            if isCurrent { spoken += ", " + Localized.text("current") }
            spoken += ". " + span
            if let note { spoken += ". " + note }
            if let gist = chapter.gist { spoken += ". " + gist }
            lines.append(
                ChapterLine(
                    id: "chapter:\(chapter.turn):\(chapter.messageID ?? "")", number: index + 1,
                    title: chapter.title, gist: chapter.gist, span: span, note: note,
                    anchorID: chapter.messageID, isCurrent: isCurrent, spoken: spoken))
        }
        let since = chapters.first.map { MessageHover.stamp($0.startedAt, now: now) }
        let fact = Localized.text("%d chapters", count)
        let header = since.map { Localized.text("%d chapters · since %@", count, $0) } ?? fact
        return ChapterReading(
            lines: lines, header: header, fact: fact,
            strip: Self.strip(chapters, turns: turns))
    }

    /// Where the transcript draws a heading, keyed by the message it goes above. Only when there
    /// is more than one chapter, and never above a first chapter whose name was kept from before
    /// chapters were: that name may say what the conversation became rather than how it began.
    public static func headings(_ chapters: [ConversationChapter], now: Date = Date())
        -> [String: ChapterHeading]
    {
        guard chapters.count >= 2 else { return [:] }
        var result: [String: ChapterHeading] = [:]
        for (index, chapter) in chapters.enumerated() {
            guard let anchor = chapter.messageID else { continue }
            if index == 0, chapter.namedBy == .kept { continue }
            let label = Localized.text("Chapter %d", index + 1)
            let time = MessageHover.stamp(chapter.startedAt, now: now)
            result[anchor] = ChapterHeading(
                number: index + 1, title: chapter.title, label: label, time: time,
                spoken: Localized.text("Chapter %d: %@", index + 1, chapter.title))
        }
        return result
    }

    /// The panel's row for the chapter a heading belongs to, so pressing a heading can open the
    /// panel on it.
    public func line(for anchorID: String) -> ChapterLine? {
        lines.first { $0.anchorID == anchorID }
    }

    private static func span(
        _ chapter: ConversationChapter, next: ConversationChapter?, turns: Int?, now: Date
    ) -> String {
        let start = MessageHover.stamp(chapter.startedAt, now: now)
        guard let next else {
            let last = turns.map { max($0, chapter.turn) }
            let messages: String
            if let last, last > chapter.turn {
                messages = Localized.text("Turns %d–%d", chapter.turn, last)
            } else if last == chapter.turn {
                messages = Localized.text("Turn %d", chapter.turn)
            } else {
                messages = Localized.text("From turn %d", chapter.turn)
            }
            return messages + " · " + Localized.text("since %@", start)
        }
        let lastTurn = max(chapter.turn, next.turn - 1)
        let messages = lastTurn > chapter.turn
            ? Localized.text("Turns %d–%d", chapter.turn, lastTurn)
            : Localized.text("Turn %d", chapter.turn)
        let end = Calendar.current.isDate(chapter.startedAt, inSameDayAs: next.startedAt)
            ? next.startedAt.formatted(date: .omitted, time: .shortened)
            : MessageHover.stamp(next.startedAt, now: now)
        return messages + " · " + start + "–" + end
    }

    private static func note(for namer: ConversationChapter.Namer) -> String? {
        switch namer {
        case .model, .prompt: return nil
        case .person: return Localized.text("Named by you")
        case .agent: return Localized.text("Named by the agent")
        case .schedule: return Localized.text("Named by its schedule")
        case .fork: return Localized.text("Named when it was forked")
        case .kept: return Localized.text("Earlier names not kept")
        }
    }

    private static func strip(_ chapters: [ConversationChapter], turns: Int?) -> [ChapterStripPiece]? {
        guard chapters.count >= 2, chapters.count <= stripLimit else { return nil }
        let lastTurn = max(turns ?? 0, chapters.last?.turn ?? 1)
        let sizes = chapters.enumerated().map { index, chapter -> Double in
            let end = index + 1 < chapters.count ? chapters[index + 1].turn : lastTurn + 1
            return Double(max(1, end - chapter.turn))
        }
        let shares = floored(sizes)
        return shares.enumerated().map { index, share in
            ChapterStripPiece(
                number: index + 1, share: share, isCurrent: index == chapters.count - 1)
        }
    }

    /// Shares of the whole in proportion to `sizes`, none below ``stripFloor``: a piece that would
    /// fall under it is pinned there and the rest share what is left in proportion, until nothing
    /// more falls under. Always possible, because ``stripLimit`` pieces at the floor take less than
    /// half the strip.
    static func floored(_ sizes: [Double]) -> [Double] {
        var pinned = Set<Int>()
        var shares = sizes
        while true {
            let free = sizes.indices.filter { !pinned.contains($0) }
            let freeTotal = free.reduce(0) { $0 + sizes[$1] }
            let room = 1 - Double(pinned.count) * stripFloor
            var fell = false
            for index in free {
                shares[index] = freeTotal > 0 ? sizes[index] / freeTotal * room : room / Double(free.count)
                if shares[index] < stripFloor {
                    pinned.insert(index)
                    fell = true
                }
            }
            for index in pinned { shares[index] = stripFloor }
            if !fell { return shares }
        }
    }
}
