import Foundation

/// The agent writes markdown; a label that shows the asterisks is showing the punctuation instead
/// of the emphasis. This turns a prose segment into Pango markup — the only rich text GTK labels
/// speak — covering what an agent actually emits: bold, italic, inline code, strikethrough, links,
/// headings, bullets, numbered lists, block quotes and rules.
///
/// Fenced code never reaches here: it is split out upstream into its own block with a copy button,
/// because code that reflows is code you cannot paste.
enum PangoMarkdown {
    static func render(_ text: String, dim: String, code: String, accent: String) -> String {
        var lines: [String] = []
        for raw in text.components(separatedBy: "\n") {
            lines.append(block(raw, dim: dim, code: code, accent: accent))
        }
        // Trailing blank lines add nothing but height in a bubble-less transcript.
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        return lines.joined(separator: "\n")
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
    /// a tag we emit is never re-escaped.
    static func inline(_ text: String, code: String, accent: String) -> String {
        var result = escape(text)
        result = replacePairs(in: result, delimiter: "`", open: "<span foreground=\"\(code)\"><tt>", close: "</tt></span>")
        result = replaceLinks(in: result, accent: accent)
        result = replacePairs(in: result, delimiter: "**", open: "<b>", close: "</b>")
        result = replacePairs(in: result, delimiter: "__", open: "<b>", close: "</b>")
        result = replacePairs(in: result, delimiter: "~~", open: "<s>", close: "</s>")
        result = replaceSingleEmphasis(in: result)
        return result
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
    /// two italics, and skipped inside words so `a_b_c` and `2 * 3 * 4` stay literal.
    private static func replaceSingleEmphasis(in text: String) -> String {
        var result = ""
        var buffer = ""
        var open = false
        var previous: Character?
        for character in text {
            if character == "*" || character == "_" {
                if open {
                    result += "<i>" + buffer + "</i>"
                    buffer = ""
                    open = false
                    previous = character
                    continue
                }
                open = true
                previous = character
                continue
            }
            if open {
                buffer.append(character)
                if buffer.count > 200 {
                    result += String(previous ?? "*") + buffer
                    buffer = ""
                    open = false
                }
            } else {
                result.append(character)
            }
            previous = character
        }
        if open { result += "*" + buffer }
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
