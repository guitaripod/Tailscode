import Foundation

/// Which steps of a turn an answer is talking about, by literal match and nothing else. An answer
/// names a file or a path; a step that touched that file carries the same words in its argument or
/// its output. Nothing is inferred, so a token no step carries lights nothing.
public enum NeuralProvenance {
    /// A path-like word in an answer, and where it sits in the text.
    public struct Token: Sendable, Hashable {
        public let text: String
        public let range: Range<String.Index>
    }

    static let minimumLength = 7

    static let extensions: Set<String> = [
        "mp4", "swift", "json", "flac", "sh", "md", "ts", "py", "rs", "c", "h", "yml", "toml", "png",
        "jpg", "txt",
    ]

    private static let leadingTrim: Set<Character> = [
        "\"", "'", "\u{201C}", "\u{2018}", "`", "*", "_", "(", "[", "{", "<",
    ]

    private static let trailingTrim: Set<Character> = [
        "\"", "'", "\u{201D}", "\u{2019}", "`", "*", "_", ")", "]", "}", ">", ",", ".", ";", ":", "!",
        "?", "\u{2026}",
    ]

    /// The path-like words of `text`: a word with a slash between path characters, or a file name
    /// ending in a known extension, longer than six characters once its quotes, brackets and
    /// closing punctuation are trimmed and a trailing `:line` is dropped.
    public static func tokens(in text: String) -> [Token] {
        var out: [Token] = []
        var cursor = text.startIndex
        while cursor < text.endIndex {
            while cursor < text.endIndex, text[cursor].isWhitespace {
                cursor = text.index(after: cursor)
            }
            let start = cursor
            while cursor < text.endIndex, !text[cursor].isWhitespace {
                cursor = text.index(after: cursor)
            }
            guard start < cursor, let trimmed = trimmed(text, start..<cursor) else { continue }
            let word = text[trimmed]
            if word.count >= minimumLength, isPathLike(word) {
                out.append(Token(text: String(word), range: trimmed))
            }
        }
        return out
    }

    /// The ids of the steps whose argument or printed lines contain `token` exactly, in turn order.
    public static func steps(touching token: String, in steps: [NeuralStep]) -> [String] {
        guard !token.isEmpty else { return [] }
        return steps.compactMap { step in
            if step.detail.contains(token) || step.outputLines.contains(where: { $0.contains(token) }) {
                return step.id
            }
            return nil
        }
    }

    private static func trimmed(_ text: String, _ range: Range<String.Index>) -> Range<String.Index>? {
        var lower = range.lowerBound
        var upper = range.upperBound
        while lower < upper, leadingTrim.contains(text[lower]) { lower = text.index(after: lower) }
        while true {
            while lower < upper {
                let last = text.index(before: upper)
                guard trailingTrim.contains(text[last]) else { break }
                upper = last
            }
            let stripped = withoutLineSuffix(text, lower..<upper)
            if stripped == upper { break }
            upper = stripped
        }
        return lower < upper ? lower..<upper : nil
    }

    /// `path.swift:212` and `path.swift:212:9` read as `path.swift`.
    private static func withoutLineSuffix(_ text: String, _ range: Range<String.Index>)
        -> String.Index
    {
        var index = range.upperBound
        var digits = 0
        while index > range.lowerBound {
            let before = text.index(before: index)
            guard text[before].isASCII, text[before].isNumber else { break }
            index = before
            digits += 1
        }
        guard digits > 0, index > range.lowerBound else { return range.upperBound }
        let colon = text.index(before: index)
        guard text[colon] == ":", colon > range.lowerBound else { return range.upperBound }
        return colon
    }

    private static func isPathLike(_ word: Substring) -> Bool {
        hasSlashBetweenPathCharacters(word) || endsInKnownExtension(word)
    }

    private static func isPathCharacter(_ character: Character) -> Bool {
        character == "." || character == "/" || character == "-" || character == "_"
            || (character.isASCII && (character.isLetter || character.isNumber))
    }

    private static func hasSlashBetweenPathCharacters(_ word: Substring) -> Bool {
        var previous: Character?
        var pendingSlash = false
        for character in word {
            if pendingSlash, isPathCharacter(character) { return true }
            pendingSlash = character == "/" && previous.map(isPathCharacter) == true
            previous = character
        }
        return false
    }

    private static func endsInKnownExtension(_ word: Substring) -> Bool {
        guard let dot = word.lastIndex(of: "."), dot > word.startIndex else { return false }
        let before = word[word.index(before: dot)]
        guard before == "-" || before == "_" || (before.isASCII && (before.isLetter || before.isNumber))
        else { return false }
        let ending = word[word.index(after: dot)...].lowercased()
        return extensions.contains(ending)
    }
}
