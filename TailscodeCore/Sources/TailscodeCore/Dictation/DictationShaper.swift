import Foundation

/// Turns what a voice said into what a hand would have typed, using only words the chat already
/// knows: "composer view dot swift" becomes `ComposerView.swift` because that file is in the
/// conversation, and "slash compact" at the start of the box becomes `/compact` because the server
/// offers it. Nothing is invented: a spoken run is replaced only by a term whose letters it matches
/// exactly, so the worst a miss can do is leave the words as they were heard.
public struct DictationShaper: Sendable {
    public static let longestRun = 5

    private let table: [String: String]
    private let commands: Set<String>

    public init(_ vocabulary: DictationVocabulary) {
        var table: [String: String] = [:]
        for term in vocabulary.terms where Self.isWorthSnapping(term) {
            let key = Self.key(term)
            if key.count >= 3, table[key] == nil { table[key] = term }
        }
        self.table = table
        self.commands = Set(vocabulary.commands.map { $0.lowercased() })
    }

    public static let passthrough = DictationShaper(.empty)

    /// The words shaped. `atStart` says the take begins at the very start of the box, where a
    /// spoken command can be one.
    public func shape(_ text: String, atStart: Bool) -> String {
        guard !text.isEmpty else { return text }
        var out = table.isEmpty ? text : snapped(text)
        if atStart { out = commanded(out) }
        return out
    }

    private func snapped(_ text: String) -> String {
        let words = Self.words(in: text)
        guard !words.isEmpty else { return text }
        var pieces: [String] = []
        var index = 0
        var cursor = text.startIndex
        while index < words.count {
            var matched: (length: Int, term: String)?
            for length in stride(from: min(Self.longestRun, words.count - index), through: 1, by: -1) {
                let run = words[index..<(index + length)]
                let spoken = run.map { Self.spokenKey($0.core) }.joined()
                guard let term = table[spoken] else { continue }
                if length == 1, run.first?.core == term { break }
                matched = (length, term)
                break
            }
            if let matched {
                let first = words[index]
                let last = words[index + matched.length - 1]
                pieces.append(String(text[cursor..<first.range.lowerBound]))
                pieces.append(first.leading + matched.term + last.trailing)
                cursor = last.range.upperBound
                index += matched.length
            } else {
                index += 1
            }
        }
        pieces.append(String(text[cursor...]))
        return pieces.joined()
    }

    private func commanded(_ text: String) -> String {
        let trimmed = text.drop(while: \.isWhitespace)
        let parts = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0].lowercased().trimmingCharacters(in: .punctuationCharacters) == "slash"
        else { return text }
        let name = parts[1].lowercased().trimmingCharacters(in: .punctuationCharacters)
        guard commands.contains(name) else { return text }
        let rest = parts.count > 2 ? " " + parts[2] : ""
        return "/" + name + rest
    }

    private struct Word {
        let range: Range<String.Index>
        let leading: String
        let core: String
        let trailing: String
    }

    private static func words(in text: String) -> [Word] {
        var out: [Word] = []
        var start: String.Index?
        var index = text.startIndex
        while index <= text.endIndex {
            let atEnd = index == text.endIndex
            if !atEnd, !text[index].isWhitespace {
                if start == nil { start = index }
            } else if let open = start {
                let raw = String(text[open..<index])
                let leading = String(raw.prefix(while: { "(\"“'‘[".contains($0) }))
                let rest = raw.dropFirst(leading.count)
                let trailing = String(rest.reversed().prefix(while: { ",;:!?)\"”'’]…".contains($0) || $0 == "." }).reversed())
                var core = String(rest.dropLast(trailing.count))
                var tail = trailing
                if core.isEmpty {
                    core = String(rest)
                    tail = ""
                }
                out.append(Word(range: open..<index, leading: leading, core: core, trailing: tail))
                start = nil
            }
            if atEnd { break }
            index = text.index(after: index)
        }
        return out
    }

    /// A term worth snapping to is one a recognizer would not spell by itself: it has an inner
    /// capital, a separator or a digit. A plain word is already spelled right.
    static func isWorthSnapping(_ term: String) -> Bool {
        DictationVocabulary.isCodeShaped(term) || term.contains(".")
    }

    static func key(_ term: String) -> String {
        String(term.lowercased().filter { $0.isLetter || $0.isNumber || "._-/".contains($0) })
    }

    private static let spoken: [String: String] = [
        "dot": ".", "period": ".", "point": ".", "underscore": "_", "dash": "-", "hyphen": "-", "slash": "/",
    ]

    static func spokenKey(_ word: String) -> String {
        let lowered = word.lowercased()
        if let symbol = spoken[lowered] { return symbol }
        return key(lowered)
    }
}
