import Foundation

/// The agent writes markdown; a label that shows the asterisks is showing the punctuation instead
/// of the emphasis. This turns a prose segment into Pango markup — the only rich text GTK labels
/// speak — covering what an agent actually emits: bold, italic, inline code, strikethrough, links,
/// headings, bullets, numbered lists, block quotes and rules.
///
/// Fenced code never reaches here: it is split out upstream into its own block with a copy button,
/// because code that reflows is code you cannot paste.
enum PangoMarkdown {
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: String] = [:]

    /// Rendering runs once per prose segment per streamed state, and a long conversation replays
    /// the same three hundred segments on every token — so the answer is remembered. The colors
    /// are part of the key: a palette change is a different rendering, not a stale hit. Trailing
    /// blank lines are dropped — they add nothing but height in a bubble-less transcript.
    static func render(_ text: String, dim: String, code: String, accent: String) -> String {
        let key = "\(dim)|\(code)|\(accent)|\(text)"
        cacheLock.lock()
        if let hit = cache[key] {
            cacheLock.unlock()
            return hit
        }
        cacheLock.unlock()
        var lines: [String] = []
        for raw in text.components(separatedBy: "\n") {
            lines.append(block(raw, dim: dim, code: code, accent: accent))
        }
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        let rendered = lines.joined(separator: "\n")
        cacheLock.lock()
        if cache.count > 4096 { cache.removeAll(keepingCapacity: true) }
        cache[key] = rendered
        cacheLock.unlock()
        return rendered
    }

    private static func block(_ raw: String, dim: String, code: String, accent: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let indent = raw.prefix { $0 == " " || $0 == "\t" }.count

        if trimmed == "---" || trimmed == "***" || trimmed == "___" {
            return "<span foreground=\"\(dim)\">──────────</span>"
        }
        if trimmed.hasPrefix("#") {
            let hashes = trimmed.prefix { $0 == "#" }.count
            let body = trimmed.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
            let size = hashes <= 1 ? "x-large" : hashes == 2 ? "large" : "medium"
            return "<span size=\"\(size)\" weight=\"bold\">\(inline(body, code: code, accent: accent))</span>"
        }
        if trimmed.hasPrefix("> ") {
            let body = String(trimmed.dropFirst(2))
            return
                "<span foreground=\"\(dim)\">│ <i>\(inline(body, code: code, accent: accent))</i></span>"
        }
        if let marker = bulletMarker(trimmed) {
            let body = String(trimmed.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            let pad = String(repeating: " ", count: min(8, indent))
            let glyph = indent >= 2 ? "◦" : "•"
            return "\(pad)<span foreground=\"\(accent)\">\(glyph)</span> \(inline(body, code: code, accent: accent))"
        }
        if let number = numberedMarker(trimmed) {
            let body = String(trimmed.dropFirst(number.count)).trimmingCharacters(in: .whitespaces)
            let pad = String(repeating: " ", count: min(8, indent))
            return
                "\(pad)<span foreground=\"\(accent)\">\(escape(number.trimmingCharacters(in: .whitespaces)))</span> \(inline(body, code: code, accent: accent))"
        }
        return inline(raw, code: code, accent: accent)
    }

    private static func bulletMarker(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) { return marker }
        return nil
    }

    private static func numberedMarker(_ line: String) -> String? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, line.dropFirst(digits.count).hasPrefix(". ") else { return nil }
        return String(line.prefix(digits.count + 2))
    }

    /// Inline spans, resolved on the escaped text so a literal `<` in prose never becomes a tag and
    /// a tag we emit is never re-escaped. Code spans are lifted out first and restored last:
    /// `gtk_box_append` must keep its underscores, and `2 * 3` inside a snippet is arithmetic,
    /// not emphasis.
    static func inline(_ text: String, code: String, accent: String) -> String {
        var result = escape(text)
        var codeSpans: [String] = []
        result = extractCodeSpans(in: result, into: &codeSpans, color: code)
        result = replaceLinks(in: result, accent: accent)
        result = replacePairs(in: result, delimiter: "**", open: "<b>", close: "</b>")
        result = replacePairs(in: result, delimiter: "__", open: "<b>", close: "</b>")
        result = replacePairs(in: result, delimiter: "~~", open: "<s>", close: "</s>")
        result = replaceSingleEmphasis(in: result)
        for (index, span) in codeSpans.enumerated() {
            result = result.replacingOccurrences(of: placeholder(index), with: span)
        }
        return result
    }

    /// Private-use sentinels no agent emits, standing in for code spans while emphasis runs.
    private static func placeholder(_ index: Int) -> String { "\u{E000}\(index)\u{E001}" }

    private static func extractCodeSpans(
        in text: String, into spans: inout [String], color: String
    ) -> String {
        var result = ""
        var rest = Substring(text)
        while let start = rest.range(of: "`") {
            let after = rest[start.upperBound...]
            guard let end = after.range(of: "`"), start.upperBound != end.lowerBound else { break }
            result += rest[..<start.lowerBound]
            spans.append(
                "<span foreground=\"\(color)\"><tt>" + after[..<end.lowerBound] + "</tt></span>")
            result += placeholder(spans.count - 1)
            rest = after[end.upperBound...]
        }
        return result + rest
    }

    static func escape(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    private static func replacePairs(
        in text: String, delimiter: String, open: String, close: String
    ) -> String {
        var result = ""
        var rest = Substring(text)
        while let start = rest.range(of: delimiter) {
            let after = rest[start.upperBound...]
            guard let end = after.range(of: delimiter), start.upperBound != end.lowerBound else {
                break
            }
            result += rest[..<start.lowerBound]
            result += open + after[..<end.lowerBound] + close
            rest = after[end.upperBound...]
        }
        return result + rest
    }

    /// `*single*` and `_single_`, done after the doubled forms so `**bold**` is never mistaken for
    /// two italics. An opener must start a word and touch what it emphasizes; a closer must touch
    /// what it ends — so `a_b_c` stays a name and `2 * 3 * 4` stays arithmetic.
    private static func replaceSingleEmphasis(in text: String) -> String {
        var result = ""
        var buffer = ""
        var open = false
        var openDelimiter: Character = "*"
        var previous: Character?
        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "*" || character == "_" {
                if open, character == openDelimiter, previous != " ", !buffer.isEmpty {
                    result += "<i>" + buffer + "</i>"
                    buffer = ""
                    open = false
                    previous = character
                    index += 1
                    continue
                }
                if !open {
                    let next: Character? =
                        index + 1 < characters.count ? characters[index + 1] : nil
                    let touchesContent = next != nil && next != " " && next != character
                    let startsWord =
                        previous == nil || !(previous!.isLetter || previous!.isNumber)
                    if touchesContent, startsWord {
                        open = true
                        openDelimiter = character
                        previous = character
                        index += 1
                        continue
                    }
                }
                if open { buffer.append(character) } else { result.append(character) }
                previous = character
                index += 1
                continue
            }
            if open {
                buffer.append(character)
                if buffer.count > 200 {
                    result += String(openDelimiter) + buffer
                    buffer = ""
                    open = false
                }
            } else {
                result.append(character)
            }
            previous = character
            index += 1
        }
        if open { result += String(openDelimiter) + buffer }
        return result
    }

    private static func replaceLinks(in text: String, accent: String) -> String {
        var result = ""
        var rest = Substring(text)
        while let open = rest.range(of: "[") {
            guard let close = rest[open.upperBound...].range(of: "]("),
                let end = rest[close.upperBound...].range(of: ")")
            else { break }
            let label = rest[open.upperBound..<close.lowerBound]
            let url = rest[close.upperBound..<end.lowerBound]
            result += rest[..<open.lowerBound]
            result += "<a href=\"\(url)\"><span foreground=\"\(accent)\">\(label)</span></a>"
            rest = rest[end.upperBound...]
        }
        return result + rest
    }
}
