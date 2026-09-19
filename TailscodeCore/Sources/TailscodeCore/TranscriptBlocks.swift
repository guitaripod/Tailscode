import Foundation

/// How much of a block of machine text — a tool's output, a fenced code block — a transcript
/// shows before the reader asks for the rest, decided once so the three clients agree.
///
/// A block never scrolls inside the transcript vertically. A scroller inside a scroller is two
/// gestures fighting over one wheel, and a toolkit that measures a wrapping label at its unwrapped
/// width collapses the inner one to a couple of lines, which is how a three-line command ended up
/// half behind a scrollbar. A short block is drawn whole; a long one shows its first lines and a
/// button that names how many are behind it, and opening it grows the block in the page, where
/// the transcript's own scroll — the one the reader already has a hand on — carries it. Code
/// still scrolls sideways, because code that rewraps is code you cannot read.
public enum TranscriptBlocks {
    /// Lines a block may have and still be drawn in full.
    public static let inlineLines = 26

    /// What a block shows right now: the text to draw, how many of its lines that is, and the
    /// words on the button that would show the rest, if there is a rest.
    public struct Fold: Equatable, Sendable {
        public let shown: String
        public let shownLines: Int
        public let totalLines: Int
        /// Lines the block shows while folded; the block is foldable when it has more than this.
        public let limit: Int

        public var foldable: Bool { totalLines > limit }
        public var isFolded: Bool { shownLines < totalLines }
        public var hiddenLines: Int { totalLines - shownLines }

        /// The button under a long block, or nothing under a short one.
        public var toggleLabel: String? {
            guard foldable else { return nil }
            return isFolded
                ? Localized.text("Show all %@ lines", "\(totalLines)")
                : Localized.text("Show first %@ lines", "\(limit)")
        }

        /// What a screen reader is told a folded block is holding back.
        public var spokenState: String? {
            guard foldable, isFolded else { return nil }
            return Localized.text("%@ more lines", "\(hiddenLines)")
        }
    }

    public static func fold(_ text: String, expanded: Bool, limit: Int = inlineLines) -> Fold {
        let total = lineCount(text)
        guard total > limit, !expanded else {
            return Fold(shown: text, shownLines: total, totalLines: total, limit: limit)
        }
        let shown = text.split(separator: "\n", maxSplits: limit, omittingEmptySubsequences: false)
            .prefix(limit).joined(separator: "\n")
        return Fold(shown: shown, shownLines: limit, totalLines: total, limit: limit)
    }

    public static func lineCount(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return text.reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
    }

    /// The gutter beside a block: one number per shown line, right-aligned to the widest.
    public static func lineNumbers(_ fold: Fold) -> String {
        guard fold.shownLines > 0 else { return "" }
        let width = String(fold.totalLines).count
        return (1...fold.shownLines).map { String(repeating: " ", count: width - String($0).count) + String($0) }
            .joined(separator: "\n")
    }
}
