import AppKit

/// The agent writes markdown; a label that shows the asterisks is showing the punctuation instead
/// of the emphasis. This turns a prose segment into an attributed string — the same grammar the
/// Linux app renders through Pango: bold, italic, inline code, strikethrough, links, headings,
/// bullets, numbered lists, block quotes and rules.
///
/// Fenced code never reaches here: it is split out upstream into its own block with a copy button,
/// because code that reflows is code you cannot paste.
@MainActor
enum MacMarkdown {
    private static var cache: [String: NSAttributedString] = [:]

    /// Rendering runs once per prose segment per streamed state, and a long conversation replays
    /// the same three hundred segments on every token — so the answer is remembered. Colors are
    /// semantic and resolve at draw time, so appearance changes never stale the cache.
    /// A growing prefix is a different string every frame, so the stream cascade renders with
    /// `cache: false` — remembering sixty renderings a second of text nobody will ask for again
    /// would evict the three hundred settled segments the memo exists for.
    static func render(_ text: String, cache useCache: Bool = true) -> NSAttributedString {
        if useCache, let hit = cache[text] { return hit }
        var lines: [NSAttributedString] = []
        for raw in text.components(separatedBy: "\n") {
            lines.append(block(raw))
        }
        while let last = lines.last, last.length == 0 { lines.removeLast() }
        let rendered = NSMutableAttributedString()
        for (index, line) in lines.enumerated() {
            if index > 0 { rendered.append(NSAttributedString(string: "\n", attributes: attributes(Style()))) }
            rendered.append(line)
        }
        guard useCache else { return rendered }
        if cache.count > 4096 { cache.removeAll(keepingCapacity: true) }
        cache[text] = rendered
        return rendered
    }

    /// One inline span's whole styling, carried through the walk so nested emphasis composes
    /// instead of replacing.
    private struct Style {
        var size: CGFloat = 13
        var bold = false
        var italic = false
        var strike = false
        var mono = false
        var color: NSColor = .labelColor
        var background: NSColor?
        var link: URL?
    }

    private static func block(_ raw: String) -> NSAttributedString {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let indent = raw.prefix { $0 == " " || $0 == "\t" }.count

        if trimmed == "---" || trimmed == "***" || trimmed == "___" {
            var style = Style()
            style.color = .secondaryLabelColor
            return NSAttributedString(string: "──────────", attributes: attributes(style))
        }
        if trimmed.hasPrefix("#") {
            let hashes = trimmed.prefix { $0 == "#" }.count
            let body = trimmed.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
            var style = Style()
            style.size = hashes <= 1 ? 19 : hashes == 2 ? 16 : 13
            style.bold = true
            return inline(body, base: style)
        }
        if trimmed.hasPrefix("> ") {
            let body = String(trimmed.dropFirst(2))
            var style = Style()
            style.italic = true
            style.color = .secondaryLabelColor
            let quoted = NSMutableAttributedString(string: "│ ", attributes: attributes(style))
            quoted.append(inline(body, base: style))
            return quoted
        }
        if let marker = bulletMarker(trimmed) {
            let body = String(trimmed.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            let pad = String(repeating: " ", count: min(8, indent))
            let glyph = indent >= 2 ? "◦" : "•"
            let line = NSMutableAttributedString(string: pad, attributes: attributes(Style()))
            var accent = Style()
            accent.color = .controlAccentColor
            line.append(NSAttributedString(string: glyph, attributes: attributes(accent)))
            line.append(NSAttributedString(string: " ", attributes: attributes(Style())))
            line.append(inline(body, base: Style()))
            return line
        }
        if let number = numberedMarker(trimmed) {
            let body = String(trimmed.dropFirst(number.count)).trimmingCharacters(in: .whitespaces)
            let pad = String(repeating: " ", count: min(8, indent))
            let line = NSMutableAttributedString(string: pad, attributes: attributes(Style()))
            var accent = Style()
            accent.color = .controlAccentColor
            line.append(
                NSAttributedString(
                    string: number.trimmingCharacters(in: .whitespaces),
                    attributes: attributes(accent)))
            line.append(NSAttributedString(string: " ", attributes: attributes(Style())))
            line.append(inline(body, base: Style()))
            return line
        }
        return inline(raw, base: Style())
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

    /// Inline spans, resolved with code spans lifted out first and restored last: `gtk_box_append`
    /// must keep its underscores, and `2 * 3` inside a snippet is arithmetic, not emphasis.
    private static func inline(_ text: String, base: Style) -> NSAttributedString {
        var result = text
        var codeSpans: [String] = []
        result = extractCodeSpans(in: result, into: &codeSpans)
        var links: [(label: String, url: String)] = []
        result = extractLinks(in: result, into: &links)
        result = replacePairs(in: result, delimiter: "**", open: Marker.boldOpen, close: Marker.boldClose)
        result = replacePairs(in: result, delimiter: "__", open: Marker.boldOpen, close: Marker.boldClose)
        result = replacePairs(in: result, delimiter: "~~", open: Marker.strikeOpen, close: Marker.strikeClose)
        result = replaceSingleEmphasis(in: result)
        return assemble(result, base: base, codeSpans: codeSpans, links: links)
    }

    /// Private-use sentinels no agent emits, standing in for lifted spans while emphasis runs.
    private enum Marker {
        static let codeOpen: Character = "\u{E000}"
        static let codeClose: Character = "\u{E001}"
        static let linkOpen: Character = "\u{E002}"
        static let linkClose: Character = "\u{E003}"
        static let boldOpen = "\u{E010}"
        static let boldClose = "\u{E011}"
        static let strikeOpen = "\u{E012}"
        static let strikeClose = "\u{E013}"
        static let italicOpen = "\u{E014}"
        static let italicClose = "\u{E015}"
    }

    private static func extractCodeSpans(in text: String, into spans: inout [String]) -> String {
        var result = ""
        var rest = Substring(text)
        while let start = rest.range(of: "`") {
            let after = rest[start.upperBound...]
            guard let end = after.range(of: "`"), start.upperBound != end.lowerBound else { break }
            result += rest[..<start.lowerBound]
            spans.append(String(after[..<end.lowerBound]))
            result += "\(Marker.codeOpen)\(spans.count - 1)\(Marker.codeClose)"
            rest = after[end.upperBound...]
        }
        return result + rest
    }

    private static func extractLinks(
        in text: String, into links: inout [(label: String, url: String)]
    ) -> String {
        var result = ""
        var rest = Substring(text)
        while let open = rest.range(of: "[") {
            guard let close = rest[open.upperBound...].range(of: "]("),
                let end = rest[close.upperBound...].range(of: ")")
            else { break }
            let label = String(rest[open.upperBound..<close.lowerBound])
            let url = String(rest[close.upperBound..<end.lowerBound])
            result += rest[..<open.lowerBound]
            links.append((label, url))
            result += "\(Marker.linkOpen)\(links.count - 1)\(Marker.linkClose)"
            rest = rest[end.upperBound...]
        }
        return result + rest
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
                    result += Marker.italicOpen + buffer + Marker.italicClose
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

    /// The final pass: markers toggle styles, placeholders splice the lifted spans back in — code
    /// in monospace over a subtle fill, links as tappable accent text.
    private static func assemble(
        _ text: String, base: Style, codeSpans: [String], links: [(label: String, url: String)]
    ) -> NSAttributedString {
        let assembled = NSMutableAttributedString()
        var style = base
        var buffer = ""

        func flush() {
            guard !buffer.isEmpty else { return }
            assembled.append(NSAttributedString(string: buffer, attributes: attributes(style)))
            buffer = ""
        }

        let characters = Array(text)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            switch character {
            case Character(Marker.boldOpen): flush(); style.bold = true
            case Character(Marker.boldClose): flush(); style.bold = base.bold
            case Character(Marker.strikeOpen): flush(); style.strike = true
            case Character(Marker.strikeClose): flush(); style.strike = base.strike
            case Character(Marker.italicOpen): flush(); style.italic = true
            case Character(Marker.italicClose): flush(); style.italic = base.italic
            case Marker.codeOpen, Marker.linkOpen:
                flush()
                let isCode = character == Marker.codeOpen
                let terminator = isCode ? Marker.codeClose : Marker.linkClose
                var digits = ""
                var cursor = index + 1
                while cursor < characters.count, characters[cursor] != terminator {
                    digits.append(characters[cursor])
                    cursor += 1
                }
                index = cursor
                if isCode, let span = Int(digits), codeSpans.indices.contains(span) {
                    var code = style
                    code.mono = true
                    code.size = max(11, style.size - 1)
                    code.background = .quaternarySystemFill
                    assembled.append(
                        NSAttributedString(string: codeSpans[span], attributes: attributes(code)))
                } else if !isCode, let span = Int(digits), links.indices.contains(span) {
                    var linked = style
                    linked.color = .controlAccentColor
                    linked.link = URL(string: links[span].url)
                    assembled.append(
                        assemble(links[span].label, base: linked, codeSpans: codeSpans, links: []))
                }
            default:
                buffer.append(character)
            }
            index += 1
        }
        flush()
        return assembled
    }

    private static func attributes(_ style: Style) -> [NSAttributedString.Key: Any] {
        let size = style.size * MacTheme.UIScale.factor
        var font: NSFont =
            style.mono
            ? .monospacedSystemFont(ofSize: size, weight: style.bold ? .semibold : .regular)
            : .systemFont(ofSize: size, weight: style.bold ? .semibold : .regular)
        if style.italic {
            font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)
        }
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: style.color,
        ]
        if style.strike {
            attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
        }
        if let background = style.background {
            attributes[.backgroundColor] = background
        }
        if let link = style.link {
            attributes[.link] = link
        }
        return attributes
    }
}
