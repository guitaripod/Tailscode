import AppKit
import TailscodeCore

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
    /// semantic and resolve at draw time, so appearance changes never stale the cache — but a
    /// theme is not an appearance and AppKit has no trait for it, so a change of identity drops
    /// the memo by hand.
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

    static func invalidate() {
        cache.removeAll(keepingCapacity: true)
    }

    /// One inline span's whole styling, carried through the walk so nested emphasis composes
    /// instead of replacing.
    private struct Style {
        var size: CGFloat = MacMarkdown.size(.answer)
        var bold = false
        var italic = false
        var strike = false
        var mono = false
        var tabular = false
        var color: NSColor = MacTheme.Color.label
        var background: NSColor?
        var link: URL?
    }

    private static func block(_ raw: String) -> NSAttributedString {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        let unit = MacTheme.UIScale.factor
        let indent = raw.prefix { $0 == " " || $0 == "\t" }.count

        if trimmed == "---" || trimmed == "***" || trimmed == "___" {
            var style = Style()
            style.color = MacTheme.Color.secondaryLabel
            return NSAttributedString(string: "──────────", attributes: attributes(style))
        }
        if trimmed.hasPrefix("#") {
            let hashes = trimmed.prefix { $0 == "#" }.count
            if hashes <= 6, trimmed.dropFirst(hashes).first == " " {
                let body = trimmed.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
                var style = Style()
                style.size = hashes <= 2 ? size(.headline) : size(.panelTitle)
                style.bold = true
                return heading(inline(body, base: style))
            }
        }
        if trimmed.hasPrefix("> ") {
            let body = String(trimmed.dropFirst(2))
            var style = Style()
            style.italic = true
            style.color = MacTheme.Color.secondaryLabel
            let quoted = NSMutableAttributedString(string: "│ ", attributes: attributes(style))
            quoted.append(inline(body, base: style))
            return indented(quoted, first: 12 * unit, rest: 12 * unit)
        }
        if let marker = bulletMarker(trimmed) {
            let body = String(trimmed.dropFirst(marker.count)).trimmingCharacters(in: .whitespaces)
            let depth = CGFloat(min(8, indent)) * 6 * unit
            if let box = taskBox(body) {
                var tint = Style()
                tint.color = box.done ? MacTheme.Color.accent : MacTheme.Color.secondaryLabel
                let line = NSMutableAttributedString(
                    string: box.done ? "☑  " : "☐  ", attributes: attributes(tint))
                line.append(inline(box.body, base: Style()))
                return indented(line, first: depth, rest: depth + 14 * unit)
            }
            let glyph = indent >= 2 ? "◦" : "•"
            var accent = Style()
            accent.color = MacTheme.Color.accent
            let line = NSMutableAttributedString(
                string: "\(glyph)  ", attributes: attributes(accent))
            line.append(inline(body, base: Style()))
            return indented(line, first: depth, rest: depth + 14 * unit)
        }
        if let number = numberedMarker(trimmed) {
            let body = String(trimmed.dropFirst(number.count)).trimmingCharacters(in: .whitespaces)
            let label = number.trimmingCharacters(in: .whitespaces)
            var accent = Style()
            accent.color = MacTheme.Color.accent
            let line = NSMutableAttributedString(
                string: "\(label) ", attributes: attributes(accent))
            line.append(inline(body, base: Style()))
            let depth = CGFloat(min(8, indent)) * 6 * unit
            return indented(
                line, first: depth, rest: depth + CGFloat(label.count + 1) * 8 * unit)
        }
        return inline(raw, base: Style())
    }

    /// A heading is a heading by the air above it as much as by the weight in it, and every other
    /// block here is one line of an unbroken paragraph stream — so the space has to be asked for
    /// rather than inherited from a margin nothing sets.
    private static func heading(_ line: NSAttributedString) -> NSAttributedString {
        let spaced = paragraph()
        spaced.paragraphSpacingBefore = 6 * MacTheme.UIScale.factor
        let made = NSMutableAttributedString(attributedString: line)
        made.addAttribute(
            .paragraphStyle, value: spaced, range: NSRange(location: 0, length: made.length))
        return made
    }

    /// The leading the ramp writes the answer in. Prose left at the face's own leading is the one
    /// thing a reader notices without being able to name it, and this is the most-read text in the
    /// app.
    private static func paragraph() -> NSMutableParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = CGFloat(Typography.spec(.answer).lineHeight)
        return paragraph
    }

    /// A list item is one paragraph with two left edges: the glyph sits at `first`, everything the
    /// line wraps onto sits at `rest`. Padding it with spaces instead — which is all a single Pango
    /// label can do — puts the second line of an item back under the bullet, where it reads as a
    /// new item rather than the rest of this one.
    private static func indented(
        _ line: NSMutableAttributedString, first: CGFloat, rest: CGFloat
    ) -> NSAttributedString {
        let hanging = paragraph()
        hanging.firstLineHeadIndent = first
        hanging.headIndent = rest
        hanging.paragraphSpacing = 3
        line.addAttribute(
            .paragraphStyle, value: hanging, range: NSRange(location: 0, length: line.length))
        return line
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

    /// One table cell's inline spans at the table's own size — bold and quiet for a header —
    /// without the block grammar, so a dashed cell never becomes a rule.
    static func tableCell(_ text: String, header: Bool) -> NSAttributedString {
        var style = Style()
        style.size = size(.tableCell)
        style.bold = header
        style.tabular = true
        if header { style.color = MacTheme.Color.secondaryLabel }
        return inline(text, base: style)
    }

    /// Inline spans, resolved with code spans lifted out first and restored last: `gtk_box_append`
    /// must keep its underscores, and `2 * 3` inside a snippet is arithmetic, not emphasis.
    private static func inline(_ text: String, base: Style) -> NSAttributedString {
        var result = text
        var codeSpans: [String] = []
        result = extractCodeSpans(in: result, into: &codeSpans)
        var links: [(label: String, url: String)] = []
        result = extractLinks(in: result, into: &links)
        result = extractBareLinks(in: result, into: &links)
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

    /// Addresses pasted bare into prose, lifted into the same spans a markdown link produces. It
    /// runs after the markdown form so an address already lifted is a sentinel here, not text.
    private static func extractBareLinks(
        in text: String, into links: inout [(label: String, url: String)]
    ) -> String {
        let spans = Autolink.spans(in: text)
        guard !spans.isEmpty else { return text }
        var result = ""
        var cursor = text.startIndex
        for span in spans {
            result += text[cursor..<span.range.lowerBound]
            links.append((span.text, span.url))
            result += "\(Marker.linkOpen)\(links.count - 1)\(Marker.linkClose)"
            cursor = span.range.upperBound
        }
        return result + text[cursor...]
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
                    code.size = size(.code)
                    code.background = MacTheme.Color.codeBackground
                    assembled.append(
                        NSAttributedString(string: codeSpans[span], attributes: attributes(code)))
                } else if !isCode, let span = Int(digits), links.indices.contains(span) {
                    var linked = style
                    linked.color = MacTheme.Color.accent
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

    /// A role's size before the window's own type preference is applied — the preference is
    /// multiplied in once, where the font is actually made.
    nonisolated static func size(_ role: TypeRole) -> CGFloat {
        let spec = Typography.spec(role)
        return CGFloat(spec.size(base: spec.axis == .mono ? 13.5 : 14))
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
        if style.tabular {
            font =
                NSFont(
                    descriptor: font.fontDescriptor.addingAttributes([
                        .featureSettings: [[
                            NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                            NSFontDescriptor.FeatureKey.selectorIdentifier:
                                kMonospacedNumbersSelector,
                        ]]
                    ]), size: size) ?? font
        }
        var attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: style.color,
            .paragraphStyle: paragraph(),
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
