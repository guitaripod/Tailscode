import Foundation

/// How much of a long prompt the transcript shows before the reader asks for the rest.
///
/// A prompt is the one voice in a conversation its reader never needs to read back in full: they
/// wrote it. A dictated paragraph or a carefully listed brief is also the tallest thing in the
/// history, more than a screen on a phone. So a prompt that would run past `foldsPast` lines at
/// the width it is drawn shows `shownLines`, ends on the toolkit's own ellipsis, and carries the
/// fold line a long code block carries.
///
/// The count is an estimate, made from the words and from how many characters fit a line, and it
/// is only used to decide; the limit a folded prompt is drawn under is the toolkit's and exact.
/// The gap between the two numbers is what keeps the estimate honest: it would have to be wrong by
/// a third for a fold line to open onto nothing.
public enum PromptFold {
    /// A prompt estimated at more lines than this folds.
    public static let foldsPast = 10
    /// The lines a folded prompt shows.
    public static let shownLines = 7

    public struct Reading: Sendable, Equatable {
        /// Whether the prompt is long enough to carry a fold line at all.
        public let foldable: Bool
        /// Whether it is drawn folded right now.
        public let folded: Bool

        /// The most lines the prompt may be drawn in, or nil for all of them.
        public var lineLimit: Int? { folded ? PromptFold.shownLines : nil }

        /// The words on the fold line, or nothing under a prompt short enough to show whole.
        public var toggleLabel: String? {
            guard foldable else { return nil }
            return folded ? Localized.text("Show more") : Localized.text("Show less")
        }

        public static let whole = Reading(foldable: false, folded: false)
    }

    /// The key a prompt's opening is remembered under, beside the transcript's other expansions.
    public static func key(messageID: String) -> String { "prompt:" + messageID }

    /// How many characters fit a line `width` wide in type `fontSize` tall: a proportional face
    /// averages about half its size a character, a monospaced one six tenths.
    public static func columns(width: Double, fontSize: Double, monospaced: Bool) -> Int {
        guard width.isFinite, fontSize.isFinite, width > 0, fontSize > 0 else { return 1 }
        return max(1, Int(width / (fontSize * (monospaced ? 0.6 : 0.5))))
    }

    /// The lines these words come to when a line holds `columns` characters: every written line is
    /// at least one, and a long one wraps.
    public static func estimatedLines(_ text: String, columns: Int) -> Int {
        guard !text.isEmpty else { return 0 }
        let room = max(1, columns)
        var lines = 0
        for written in text.split(separator: "\n", omittingEmptySubsequences: false) {
            lines += max(1, (written.count + room - 1) / room)
            if lines > 4 * foldsPast { break }
        }
        return lines
    }

    /// The words that fill a folded prompt's lines when a line holds `columns` characters, ending
    /// on an ellipsis: for a toolkit whose own line limit counts each paragraph apart, which
    /// would let a listed prompt through whole. A wrapped line holds a little less than it could,
    /// so the last paragraph is cut a little short of its room rather than a line over it.
    public static func cut(_ text: String, columns: Int) -> String {
        let room = max(1, columns)
        var lines = 0
        var kept: [Substring] = []
        for written in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let needs = max(1, (written.count + room - 1) / room)
            if lines + needs <= shownLines {
                kept.append(written)
                lines += needs
                if lines == shownLines { break }
                continue
            }
            let fits = Int(Double((shownLines - lines) * room) * 0.92)
            kept.append(written.prefix(max(1, fits)))
            break
        }
        var words = kept.joined(separator: "\n")
        while let last = words.last, last.isWhitespace || last.isNewline { words.removeLast() }
        return words + "…"
    }

    public static func read(_ text: String, columns: Int, expanded: Bool) -> Reading {
        guard estimatedLines(text, columns: columns) > foldsPast else { return .whole }
        return Reading(foldable: true, folded: !expanded)
    }
}
