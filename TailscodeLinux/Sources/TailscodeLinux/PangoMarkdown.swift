import Foundation
import TailscodeCore

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
    nonisolated(unsafe) private static var cacheBytes = 0
    /// What the memo may hold, in entries and in bytes. A count alone is not a bound: three
    /// hundred settled segments of ordinary prose and three hundred segments of a forty-thousand
    /// word answer are the same number and two orders of magnitude apart in memory.
    private static let cacheLimit = 4096
    private static let cacheByteLimit = 8 << 20

    /// Rendering runs once per prose segment per streamed state, and a long conversation replays
    /// the same three hundred segments on every token — so the answer is remembered. The colors
    /// are part of the key: a palette change is a different rendering, not a stale hit. Trailing
    /// blank lines are dropped — they add nothing but height in a bubble-less transcript.
    /// A growing prefix is a different string every frame, so the stream cascade renders with
    /// `cache: false` — remembering sixty renderings a second of text nobody will ask for again
    /// would evict the three hundred settled segments the memo exists for.
    static func render(
        _ text: String, dim: String, code: String, accent: String, cache useCache: Bool = true
    ) -> String {
        let key = "\(dim)|\(code)|\(accent)|\(text)"
        if useCache {
            cacheLock.lock()
            if let hit = cache[key] {
                cacheLock.unlock()
                return hit
            }
            cacheLock.unlock()
        }
        var lines: [String] = []
        for raw in text.components(separatedBy: "\n") {
            lines.append(block(raw, dim: dim, code: code, accent: accent))
        }
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        let rendered = lines.joined(separator: "\n")
        guard useCache else { return rendered }
        cacheLock.lock()
        if cache.count > cacheLimit || cacheBytes > cacheByteLimit {
            cache.removeAll(keepingCapacity: true)
            cacheBytes = 0
        }
        if cache.updateValue(rendered, forKey: key) == nil {
            cacheBytes += key.utf8.count + rendered.utf8.count
        }
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
            if hashes <= 6, trimmed.dropFirst(hashes).first == " " {
                let body = trimmed.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
                let size = hashes <= 1 ? "x-large" : hashes == 2 ? "large" : "medium"
                return "<span size=\"\(size)\" weight=\"bold\">\(inline(body, code: code, accent: accent))</span>"
            }
        }
        if trimmed.hasPrefix("> ") {
            let body = String(trimmed.dropFirst(2))
            return
                "<span foreground=\"\(dim)\">│ <i>\(inline(body, code: code, accent: accent))</i></span>"
        }
        if let marker = bulletMarker(trimmed) {
            let body = String(trimmed.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            let pad = String(repeating: " ", count: min(8, indent))
            if let box = taskBox(body) {
                let glyph = box.done ? "☑" : "☐"
                let tint = box.done ? accent : dim
                return "\(pad)<span foreground=\"\(tint)\">\(glyph)</span> \(inline(box.body, code: code, accent: accent))"
            }
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
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return String(line.prefix(digits.count + 2))
    }

    /// A `- [ ]` / `- [x]` task item's box and what it carries, or nil for an ordinary bullet.
    private static func taskBox(_ body: String) -> (done: Bool, body: String)? {
        for (marker, done) in [("[ ] ", false), ("[x] ", true), ("[X] ", true)]
        where body.hasPrefix(marker) {
            return (done, String(body.dropFirst(marker.count)))
        }
        return nil
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
        result = autolink(in: result, accent: accent)
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

    /// A run of plain text — a prompt somebody typed, a line a tool printed — with its addresses
    /// made touchable and nothing else about it interpreted. An agent pastes a URL into a sentence
    /// and so does a person, and a transcript that renders one as grey text makes the reader retype
    /// it off a screen they cannot select on. No emphasis, no headings: this is not markdown, it is
    /// what somebody wrote, and the only thing worth finding in it is the address.
    static func plainWithLinks(_ text: String, accent: String) -> String {
        linkify(escape(text), accent: accent)
    }

    /// Addresses pasted bare into prose, made into the same anchors a markdown link produces. It
    /// runs after the markdown form so an anchor already built is stepped over whole — its href
    /// holds an address too, and linking one twice is a tag inside a tag Pango refuses to parse.
    private static func autolink(in text: String, accent: String) -> String {
        guard text.contains("://") || text.contains("www.") else { return text }
        var result = ""
        var rest = Substring(text)
        while let open = rest.range(of: "<a "),
            let close = rest[open.upperBound...].range(of: "</a>")
        {
            result += linkify(String(rest[..<open.lowerBound]), accent: accent)
            result += rest[open.lowerBound..<close.upperBound]
            rest = rest[close.upperBound...]
        }
        return result + linkify(String(rest), accent: accent)
    }

    private static func linkify(_ text: String, accent: String) -> String {
        let spans = Autolink.spans(in: text)
        guard !spans.isEmpty else { return text }
        var result = ""
        var cursor = text.startIndex
        for span in spans {
            result += text[cursor..<span.range.lowerBound]
            result +=
                "<a href=\"\(span.url)\"><span foreground=\"\(accent)\">\(span.text)</span></a>"
            cursor = span.range.upperBound
        }
        return result + text[cursor...]
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
