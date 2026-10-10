import Foundation

/// What a page says about itself in its head: a title and an icon. The card shows only these —
/// the fetch is a metadata read, never a page embed, and never the conversation's context.
public struct LinkPreviewMetadata: Sendable, Equatable {
    public let title: String?
    public let faviconURL: URL?

    public init(title: String?, faviconURL: URL?) {
        self.title = title
        self.faviconURL = faviconURL
    }
}

/// Reads a page's head for what a card needs. Deliberately loose: HTML in the wild is broken, so a
/// byte scanner over the first part of the document, entities decoded, is the whole grammar.
///
/// The scan is linear in the size of the head and bounded per tag, because the bytes come from
/// whatever a stranger's server sent: a quarter-megabyte of `<meta ` with no closing bracket must
/// cost a pass over the bytes, never a pass per tag.
public enum LinkPreviewParser {
    private static let tagLimit = 4096
    private static let titleLimit = 2000
    private static let sniffWindow = 2048
    private static let wasteLimit = 2_000_000

    /// The title and icon of a document, or nil when it declares neither. `charset` is the
    /// transport's own word on the encoding (a `Content-Type` parameter); the document's `<meta>`
    /// is the fallback, and valid UTF-8 the last guess.
    public static func parse(_ data: Data, finalURL: URL, charset: String? = nil)
        -> LinkPreviewMetadata?
    {
        let html = decode(data, charset: charset)
        let head = headSection(of: html)
        let bytes = Array(head.utf8)
        let tags = scanTags(in: bytes)
        let title = ogTitle(tags) ?? plainTitle(in: bytes) ?? metaTitle(tags)
        let favicon = faviconURL(in: tags, finalURL: finalURL)
        guard title != nil || favicon != nil else { return nil }
        return LinkPreviewMetadata(
            title: title.map { String($0.prefix(titleLimit)) }, faviconURL: favicon)
    }

    private static func metaTitle(_ tags: [Tag]) -> String? {
        for tag in tags where tag.name == "meta" && tag.attributes["name"]?.lowercased() == "title" {
            let cleaned = clean(tag.attributes["content"] ?? "")
            if !cleaned.isEmpty { return cleaned }
        }
        return nil
    }

    /// The charset parameter of a `Content-Type` value, if it names one.
    public static func charset(ofContentType value: String?) -> String? {
        guard let value, let range = value.range(of: "charset=", options: .caseInsensitive)
        else { return nil }
        let rest = value[range.upperBound...]
        let name = rest.prefix { $0 != ";" && !$0.isWhitespace }
        let trimmed = name.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Text from bytes, honouring a declared encoding the app can read and otherwise insisting on
    /// UTF-8. A body cut at the byte limit usually ends inside a multi-byte character, which must
    /// not throw the whole document over to Latin-1 and turn every accent into two letters.
    static func decode(_ data: Data, charset: String?) -> String {
        let declared = charset ?? sniffedCharset(in: data)
        if let declared, let encoding = encoding(named: declared), encoding != .utf8,
            let text = String(data: data, encoding: encoding)
        {
            return text
        }
        if let text = String(data: data, encoding: .utf8) { return text }
        for dropped in 1...3 where data.count > dropped {
            if let text = String(data: data.dropLast(dropped), encoding: .utf8) { return text }
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func sniffedCharset(in data: Data) -> String? {
        let window = String(decoding: data.prefix(sniffWindow), as: UTF8.self)
        guard let range = window.range(of: "charset=", options: .caseInsensitive) else {
            return nil
        }
        let rest = window[range.upperBound...].drop { $0 == "\"" || $0 == "'" }
        let name = rest.prefix { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return name.isEmpty ? nil : String(name)
    }

    private static func encoding(named name: String) -> String.Encoding? {
        switch name.lowercased() {
        case "utf-8", "utf8": return .utf8
        case "iso-8859-1", "latin1", "iso8859-1": return .isoLatin1
        case "windows-1252", "cp1252": return .windowsCP1252
        case "windows-1251", "cp1251": return .windowsCP1251
        case "shift_jis", "shift-jis", "sjis", "x-sjis": return .shiftJIS
        case "euc-jp": return .japaneseEUC
        default: return nil
        }
    }

    /// Everything up to the end of the head. A title in the body belongs to an inline graphic, not
    /// to the page, and stopping here is what keeps a scan off the rest of a large document.
    private static func headSection(of html: String) -> Substring {
        guard let end = html.range(of: "</head", options: .caseInsensitive) else {
            return html[html.startIndex..<html.endIndex]
        }
        return html[html.startIndex..<end.lowerBound]
    }

    private struct Tag {
        let name: String
        let attributes: [String: String]
    }

    /// Every `<meta>` and `<link>` of the head, in order.
    private static func scanTags(in bytes: [UInt8]) -> [Tag] {
        var tags: [Tag] = []
        var index = 0
        var wasted = 0
        let count = bytes.count
        while index < count, wasted < wasteLimit {
            guard bytes[index] == UInt8(ascii: "<") else {
                index += 1
                continue
            }
            let nameStart = index + 1
            var nameEnd = nameStart
            while nameEnd < count, isNameByte(bytes[nameEnd]) { nameEnd += 1 }
            let name = String(decoding: bytes[nameStart..<nameEnd], as: UTF8.self).lowercased()
            guard name == "meta" || name == "link" else {
                index = nameStart
                continue
            }
            let limit = min(count, nameEnd + tagLimit)
            var close = nameEnd
            var quote: UInt8?
            while close < limit {
                let byte = bytes[close]
                if let open = quote {
                    if byte == open { quote = nil }
                } else if byte == UInt8(ascii: "\"") || byte == UInt8(ascii: "'") {
                    quote = byte
                } else if byte == UInt8(ascii: ">") {
                    break
                }
                close += 1
            }
            guard close < limit else {
                wasted += close - nameEnd
                index = nameStart
                continue
            }
            tags.append(Tag(name: name, attributes: attributes(in: bytes[nameEnd..<close])))
            index = close + 1
        }
        return tags
    }

    private static func isNameByte(_ byte: UInt8) -> Bool {
        (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A)
            || (byte >= 0x30 && byte <= 0x39) || byte == UInt8(ascii: "-")
    }

    private static func isSpace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D || byte == 0x0C
    }

    /// `name=value` pairs, quoted either way or bare. A bare attribute (`defer`) has no value and
    /// is not recorded.
    private static func attributes(in slice: ArraySlice<UInt8>) -> [String: String] {
        var result: [String: String] = [:]
        var index = slice.startIndex
        let end = slice.endIndex
        while index < end {
            while index < end, isSpace(slice[index]) || slice[index] == UInt8(ascii: "/") {
                index += 1
            }
            let nameStart = index
            while index < end, !isSpace(slice[index]), slice[index] != UInt8(ascii: "="),
                slice[index] != UInt8(ascii: "/")
            {
                index += 1
            }
            let name = String(decoding: slice[nameStart..<index], as: UTF8.self).lowercased()
            while index < end, isSpace(slice[index]) { index += 1 }
            guard index < end, slice[index] == UInt8(ascii: "=") else { continue }
            index += 1
            while index < end, isSpace(slice[index]) { index += 1 }
            guard index < end else { break }
            let valueStart: Int
            let valueEnd: Int
            if slice[index] == UInt8(ascii: "\"") || slice[index] == UInt8(ascii: "'") {
                let open = slice[index]
                index += 1
                valueStart = index
                while index < end, slice[index] != open { index += 1 }
                valueEnd = index
                if index < end { index += 1 }
            } else {
                valueStart = index
                while index < end, !isSpace(slice[index]) { index += 1 }
                valueEnd = index
            }
            if !name.isEmpty, result[name] == nil {
                result[name] = String(decoding: slice[valueStart..<valueEnd], as: UTF8.self)
            }
        }
        return result
    }

    private static func ogTitle(_ tags: [Tag]) -> String? {
        for tag in tags where tag.name == "meta" {
            let key = (tag.attributes["property"] ?? tag.attributes["name"])?.lowercased()
            guard key == "og:title", let content = tag.attributes["content"] else { continue }
            let cleaned = clean(content)
            if !cleaned.isEmpty { return cleaned }
        }
        return nil
    }

    /// The `<title>` element's text, found without a pattern so an unclosed one costs one scan.
    private static func plainTitle(in bytes: [UInt8]) -> String? {
        let open = Array("<title".utf8)
        var index = 0
        while index + open.count < bytes.count {
            guard matches(open, in: bytes, at: index) else {
                index += 1
                continue
            }
            let after = bytes[index + open.count]
            guard after == UInt8(ascii: ">") || isSpace(after) else {
                index += 1
                continue
            }
            var textStart = index + open.count
            while textStart < bytes.count, bytes[textStart] != UInt8(ascii: ">") { textStart += 1 }
            textStart += 1
            let close = Array("</title".utf8)
            var textEnd = textStart
            while textEnd + close.count <= bytes.count, !matches(close, in: bytes, at: textEnd) {
                textEnd += 1
            }
            guard textEnd + close.count <= bytes.count, textStart <= textEnd else { return nil }
            let inner = String(decoding: bytes[textStart..<min(textEnd, textStart + titleLimit * 4)], as: UTF8.self)
            let cleaned = clean(strippingTags(inner))
            return cleaned.isEmpty ? nil : cleaned
        }
        return nil
    }

    private static func matches(_ word: [UInt8], in bytes: [UInt8], at index: Int) -> Bool {
        guard index + word.count <= bytes.count else { return false }
        for offset in 0..<word.count {
            var byte = bytes[index + offset]
            if byte >= 0x41 && byte <= 0x5A { byte += 0x20 }
            if byte != word[offset] { return false }
        }
        return true
    }

    private static func strippingTags(_ text: String) -> String {
        var result = ""
        var inside = false
        for character in text {
            if character == "<" {
                inside = true
                result.append(" ")
            } else if character == ">", inside {
                inside = false
            } else if !inside {
                result.append(character)
            }
        }
        return result
    }

    /// The best icon a page declares: a touch icon first, then a real `icon` link, and only then any
    /// other `-icon` relation. Masks and SVGs are not icons a card can draw and are skipped, which
    /// is what keeps `fluid-icon` (often dead) and `mask-icon` from beating a page's actual favicon.
    /// Relative and protocol-relative addresses resolve against the final URL, so a redirect that
    /// moved the page still lands the icon.
    private static func faviconURL(in tags: [Tag], finalURL: URL) -> URL? {
        var best: (score: Int, url: URL)?
        for link in tags where link.name == "link" {
            guard let rel = link.attributes["rel"]?.lowercased(),
                let rawHref = link.attributes["href"]
            else { continue }
            let href = clean(rawHref)
            guard !href.isEmpty, !href.lowercased().hasPrefix("data:"),
                link.attributes["type"]?.lowercased().contains("svg") != true,
                let url = URL(string: href, relativeTo: finalURL)?.absoluteURL,
                let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
                url.pathExtension.lowercased() != "svg"
            else { continue }
            let tokens = rel.split(whereSeparator: \.isWhitespace)
            guard !tokens.contains("mask-icon"), !tokens.contains("mask") else { continue }
            let score =
                rel.contains("apple-touch-icon") ? 3
                : tokens.contains("icon") ? 2
                : rel.contains("icon") ? 1
                : 0
            guard score > 0, score > (best?.score ?? 0) else { continue }
            best = (score, url)
        }
        return best?.url
    }

    /// A title read for a human: entities decoded, whitespace back to single spaces.
    private static func clean(_ text: String) -> String {
        var collapsed = ""
        var lastWasSpace = false
        for character in decodeEntities(text) {
            if character.isWhitespace {
                if !lastWasSpace { collapsed.append(" ") }
                lastWasSpace = true
            } else {
                collapsed.append(character)
                lastWasSpace = false
            }
        }
        return collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static let namedEntities: [String: String] = [
        "nbsp": " ", "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "ndash": "–", "mdash": "—", "hellip": "…", "middot": "·", "bull": "•",
        "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”", "laquo": "«", "raquo": "»",
        "copy": "©", "reg": "®", "trade": "™", "times": "×",
    ]

    /// Entities decoded in one pass, so `&amp;lt;` is the five characters `&lt;` and not a bracket.
    private static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var result = ""
        var index = text.startIndex
        while index < text.endIndex {
            let character = text[index]
            guard character == "&",
                let semicolon = text[index...].prefix(12).firstIndex(of: ";")
            else {
                result.append(character)
                index = text.index(after: index)
                continue
            }
            let body = text[text.index(after: index)..<semicolon]
            if let decoded = decode(entity: body) {
                result.append(decoded)
                index = text.index(after: semicolon)
            } else {
                result.append(character)
                index = text.index(after: index)
            }
        }
        return result
    }

    private static func decode(entity body: Substring) -> String? {
        if body.hasPrefix("#") {
            let digits = body.dropFirst()
            let value: UInt32?
            if digits.hasPrefix("x") || digits.hasPrefix("X") {
                value = UInt32(digits.dropFirst(), radix: 16)
            } else {
                value = UInt32(digits, radix: 10)
            }
            guard let value, let scalar = Unicode.Scalar(value) else { return nil }
            return String(Character(scalar))
        }
        return namedEntities[String(body)]
    }
}
