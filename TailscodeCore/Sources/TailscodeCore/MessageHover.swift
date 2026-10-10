import CodingAgentKit
import Foundation

/// What a pointer resting on a message reads off it: when it was written, and the words Copy
/// would take. One reading for every desk, so the capsule says the same thing wherever it floats.
public enum MessageHover {
    /// A message's own words as it wrote them — the markdown an answer was written in, which is
    /// what a paste into anywhere else wants — with the harness's own markup taken out. Only what
    /// it said: a part's `text` also answers for a thought, and a thought is not the answer.
    public static func words(of message: ChatMessage) -> String {
        message.parts.compactMap { part -> String? in
            guard case .text(let value) = part.kind else { return nil }
            return value
        }
        .map { AgentMarkup.strip($0).trimmingCharacters(in: .whitespacesAndNewlines) }
        .filter { !$0.isEmpty }
        .joined(separator: "\n\n")
    }

    /// When a message was written, as a clock reads it: the time alone today, and the system's own
    /// words for the day before that.
    public static func stamp(_ date: Date, now: Date = Date()) -> String {
        if Calendar.current.isDate(date, inSameDayAs: now) {
            return date.formatted(date: .omitted, time: .shortened)
        }
        return relative.string(from: date)
    }

    private static let relative: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()

    /// Whether the capsule offers Copy: only a message with words to take.
    public static func offersCopy(_ message: ChatMessage) -> Bool {
        !words(of: message).isEmpty
    }

    /// What the capsule on one message says and offers: when it was written, Copy where there are
    /// words, and — on a prompt a server can wind back to — Undo from here.
    public struct Verbs: Equatable, Sendable {
        public let stamp: String
        public let fullDate: String
        public let copy: Bool
        public let undo: Bool
    }

    public static func verbs(
        for message: ChatMessage, isPrompt: Bool, capabilities: BackendCapabilities?,
        now: Date = Date()
    ) -> Verbs {
        Verbs(
            stamp: stamp(message.createdAt, now: now),
            fullDate: message.createdAt.formatted(date: .complete, time: .standard),
            copy: offersCopy(message),
            undo: isPrompt
                && capabilities.map { RevertReading.offersUndo(on: message, capabilities: $0) }
                    == true)
    }
}

/// Which row, and which message, a pointer is on — found from where the rows stand rather than by
/// asking each one, so a pointer crossing a long conversation costs a binary search per move.
public enum PointerRows {
    /// A message under the pointer: the one whose words the rows draw, and the run of rows that
    /// draws them.
    public struct Hit: Equatable, Sendable {
        public let owner: String
        public let rows: ClosedRange<Int>

        public init(owner: String, rows: ClosedRange<Int>) {
            self.owner = owner
            self.rows = rows
        }
    }

    /// The row a vertical position falls in. `span` gives each row's top and bottom in one
    /// coordinate space, in order from the top of the list; a position in the room between two rows
    /// belongs to neither.
    public static func row(
        atY y: Double, count: Int, span: (Int) -> ClosedRange<Double>?
    ) -> Int? {
        guard let index = rowAtOrAbove(y, count: count, span: span),
            let own = span(index), y <= own.upperBound
        else { return nil }
        return index
    }

    /// The message under a vertical position. `owner` names the message a row draws the words of,
    /// and nil for a row that is the agent working. The room between two rows of one message is
    /// still on that message, so a pointer crossing from a paragraph to the code under it does not
    /// let go of the capsule.
    public static func message(
        atY y: Double, count: Int, span: (Int) -> ClosedRange<Double>?, owner: (Int) -> String?
    ) -> Hit? {
        guard let above = rowAtOrAbove(y, count: count, span: span), let own = span(above)
        else { return nil }
        guard let id = owner(above) else { return nil }
        if y > own.upperBound, !(above + 1 < count && owner(above + 1) == id) { return nil }
        var first = above
        while first > 0, owner(first - 1) == id { first -= 1 }
        var last = above
        while last + 1 < count, owner(last + 1) == id { last += 1 }
        return Hit(owner: id, rows: first...last)
    }

    /// The last row whose top is at or above the position.
    private static func rowAtOrAbove(
        _ y: Double, count: Int, span: (Int) -> ClosedRange<Double>?
    ) -> Int? {
        var low = 0
        var high = count - 1
        var found: Int?
        while low <= high {
            let middle = (low + high) / 2
            guard let bounds = span(middle) else { return nil }
            if bounds.lowerBound <= y {
                found = middle
                low = middle + 1
            } else {
                high = middle - 1
            }
        }
        return found
    }
}
