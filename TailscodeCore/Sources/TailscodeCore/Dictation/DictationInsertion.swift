import Foundation

/// Where a take's words go in a box: at the caret, in place of a selection, with the spacing and
/// the capital a typist would have given them. The box is described by the text before the caret
/// and the text after the selection, so no index unit leaks in here — a client measures the parts
/// in its own (UTF-16 on Apple, characters on GTK).
public struct DictationInsertion: Sendable, Equatable {
    public let before: String
    public let after: String

    public init(before: String, after: String) {
        self.before = before
        self.after = after
    }

    /// The box with a take's words in it. `settled` and `heard` are the take so far; a client draws
    /// `heard` lit and everything else in ink.
    public func compose(settled: String, heard: String) -> DictationComposition {
        let joined = DictationText.join(settled, heard)
        guard !joined.isEmpty else {
            return DictationComposition(lead: before, settled: "", heard: "", tail: after)
        }
        let separator = String(joined.dropFirst(settled.count).dropLast(heard.count))
        var settledPart = settled.isEmpty ? "" : settled + separator
        var heardPart = heard
        if settledPart.isEmpty {
            heardPart = capitalised(heardPart)
        } else {
            settledPart = capitalised(settledPart)
        }
        let words = settledPart + heardPart
        return DictationComposition(
            lead: before + leadingSpace(for: words), settled: settledPart, heard: heardPart,
            tail: trailingSpace(after: words) + after)
    }

    /// The box exactly as it was before the take: what a cancel returns to.
    public var original: String { before + after }

    private func leadingSpace(for words: String) -> String {
        guard let last = before.last, let first = words.first else { return "" }
        if last.isWhitespace || DictationText.opensNext(last) || DictationText.hugsPrevious(first) { return "" }
        return " "
    }

    private func trailingSpace(after words: String) -> String {
        guard let first = after.first, let last = words.last else { return "" }
        if first.isWhitespace || last.isWhitespace || DictationText.hugsPrevious(first) { return "" }
        return " "
    }

    /// A take that starts a sentence starts with a capital, whatever the engine thought. A take
    /// in the middle of one is left as the engine wrote it: lowering a capital would break every
    /// name that happened to be spoken first.
    private func capitalised(_ words: String) -> String {
        guard DictationText.isSentenceStart(after: before), let first = words.first, first.isLowercase else {
            return words
        }
        return first.uppercased() + words.dropFirst()
    }
}

/// A box with a take in it, in four parts: what was before the caret (with the space the take
/// needed), the take's settled words, the words still being heard, and what was after the
/// selection (with its space).
public struct DictationComposition: Sendable, Equatable {
    public let lead: String
    public let settled: String
    public let heard: String
    public let tail: String

    public var text: String { lead + settled + heard + tail }

    /// Where the caret goes: just after the take.
    public var caretUTF16: Int { (lead + settled + heard).utf16.count }

    public var caretCharacters: Int { (lead + settled + heard).count }

    /// The words still being heard, in UTF-16 units, for `NSAttributedString`.
    public var heardUTF16: NSRange {
        NSRange(location: (lead + settled).utf16.count, length: heard.utf16.count)
    }

    /// The same span in characters (Unicode scalars), for a `GtkTextIter`.
    public var heardScalars: Range<Int> {
        let start = (lead + settled).unicodeScalars.count
        return start..<(start + heard.unicodeScalars.count)
    }

    /// The whole take, settled and heard, in UTF-16 units: what a cancel strikes through.
    public var takeUTF16: NSRange {
        NSRange(location: lead.utf16.count, length: (settled + heard).utf16.count)
    }

    public var takeScalars: Range<Int> {
        let start = lead.unicodeScalars.count
        return start..<(start + (settled + heard).unicodeScalars.count)
    }

    public var caretScalars: Int { (lead + settled + heard).unicodeScalars.count }
}
