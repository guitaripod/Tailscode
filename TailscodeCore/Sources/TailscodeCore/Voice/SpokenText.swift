import CodingAgentKit
import Foundation

extension SpokenDigest {
    /// The first `count` sentences of a message as a voice would say them, kept whole while they
    /// fit in `limit` characters. The first is always kept, and cut at a word if it alone is too long.
    public static func firstSentences(of text: String, count: Int, limit: Int) -> String {
        let sentences = split(plain(text))
        guard var spoken = sentences.first else { return "" }
        for sentence in sentences.dropFirst().prefix(max(0, count - 1)) {
            let joined = spoken + " " + sentence
            guard joined.count <= limit else { break }
            spoken = joined
        }
        return VoiceText.ascii(spoken, limit: limit)
    }

    /// Markdown reduced to sentences: code blocks, tables, headings and links' targets gone, list
    /// items and paragraphs closed with a full stop so they do not run into each other, and any
    /// address or long path dropped.
    static func plain(_ markdown: String) -> String {
        var blocks: [String] = []
        var paragraph: [String] = []
        var fenced = false

        func close() {
            guard !paragraph.isEmpty else { return }
            blocks.append(closed(paragraph.joined(separator: " ")))
            paragraph = []
        }

        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                close()
                fenced.toggle()
                continue
            }
            if fenced { continue }
            if line.isEmpty || line.hasPrefix("#") || line.hasPrefix("|") || isRule(line) {
                close()
                continue
            }
            let unquoted = stripQuote(line)
            if let item = listItem(unquoted) {
                close()
                let cleaned = inline(item)
                if !cleaned.isEmpty { blocks.append(closed(cleaned)) }
            } else {
                let body = inline(unquoted)
                if !body.isEmpty { paragraph.append(body) }
            }
        }
        close()
        return blocks.joined(separator: " ")
    }

    private static func stripQuote(_ line: String) -> String {
        var text = Substring(line)
        while text.hasPrefix(">") { text = text.dropFirst().drop(while: { $0 == " " }) }
        return String(text)
    }

    private static func isRule(_ line: String) -> Bool {
        let marks = line.filter { !$0.isWhitespace }
        return marks.count >= 3 && Set(marks).count == 1 && "-*_=".contains(marks.first!)
    }

    private static func listItem(_ line: String) -> String? {
        let range = line.range(of: #"^([-*+•]|\d{1,3}[.)])\s+(\[[ xX]\]\s+)?"#, options: .regularExpression)
        guard let range else { return nil }
        return String(line[range.upperBound...])
    }

    private static func closed(_ text: String) -> String {
        var trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix(":") || trimmed.hasSuffix(";") || trimmed.hasSuffix(",") { trimmed.removeLast() }
        guard let last = trimmed.last else { return "" }
        return ".!?".contains(last) ? trimmed : trimmed + "."
    }

    private static func inline(_ text: String) -> String {
        var result = text
        let rules: [(String, String)] = [
            (#"!\[[^\]]*\]\([^)]*\)"#, ""),
            (#"\[([^\]]*)\]\([^)]*\)"#, "$1"),
            (#"<[^>]+>"#, ""),
            (#"(https?://|www\.)\S+"#, ""),
            (#"\*\*|__|~~"#, ""),
            (#"(^|\s)\*+(?=\S)|(?<=\S)\*+(?=\s|$)"#, "$1"),
        ]
        for (pattern, template) in rules {
            result = result.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
        }
        result = result.replacingOccurrences(of: "`", with: "")
        let kept = result.split(separator: " ").filter { !isLongPath(String($0)) }
        return kept.joined(separator: " ")
    }

    private static func isLongPath(_ word: String) -> Bool {
        let core = word.trimmingCharacters(in: .punctuationCharacters.subtracting(CharacterSet(charactersIn: "/~.")))
        let slashes = core.filter { $0 == "/" }.count
        guard slashes > 0 else { return false }
        if core.count >= 20 { return true }
        return slashes >= 3 || ((core.hasPrefix("/") || core.hasPrefix("~/")) && slashes >= 2)
    }

    private static let abbreviations: Set<String> = ["e.g", "i.e", "vs", "etc", "approx", "mr", "mrs", "dr"]

    private static func split(_ text: String) -> [String] {
        var sentences: [String] = []
        var current = ""
        let characters = Array(text)
        for (index, character) in characters.enumerated() {
            current.append(character)
            guard ".!?".contains(character) else { continue }
            let atEnd = index + 1 == characters.count
            guard atEnd || characters[index + 1].isWhitespace else { continue }
            if character == "." && !atEnd && isAbbreviation(current) { continue }
            let sentence = current.trimmingCharacters(in: .whitespaces)
            if !sentence.isEmpty { sentences.append(sentence) }
            current = ""
        }
        let rest = current.trimmingCharacters(in: .whitespaces)
        if !rest.isEmpty { sentences.append(rest) }
        return sentences
    }

    private static func isAbbreviation(_ sentence: String) -> Bool {
        let word = sentence.dropLast().split(whereSeparator: { $0.isWhitespace }).last.map(String.init) ?? ""
        let lowered = word.lowercased()
        return abbreviations.contains(lowered) || (word.count == 1 && word.first!.isLetter)
    }
}
