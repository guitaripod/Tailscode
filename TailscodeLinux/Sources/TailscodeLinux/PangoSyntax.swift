import Foundation
import TailscodeCore

/// A fenced block as Pango markup, coloured by the shared lexer.
///
/// The tokens are Core's and so is the mapping from a role to a slot, which is the whole point: the
/// phone and the Mac ask the same question of the same table and get the same answer, so a block of
/// Swift is the same block of Swift on all three screens and no client can drift by being the one
/// that hand-rolled its own keyword list.
///
/// Two conversions happen here and nowhere else. A token is measured in UTF-16 because that is what
/// Apple's text systems count in, and Pango wants a `String` — so the source is walked once as
/// UTF-16 and cut at the token boundaries. And every run is escaped on its way in, because a `<` in
/// a C++ template or an `&&` in a shell script is code, not markup.
enum PangoSyntax {
    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: String] = [:]
    nonisolated(unsafe) private static var cacheBytes = 0
    /// A block streams in a character at a time, so every arrival is a different key and the memo
    /// fills with five hundred prefixes of the same block. Five hundred entries is a small number
    /// and, of a file being written into the transcript, a large amount of memory — so the bound
    /// is also in bytes.
    private static let cacheLimit = 512
    private static let cacheByteLimit = 8 << 20

    /// Rendering runs once per block per streamed state and a long conversation replays the same
    /// blocks on every token, so the answer is remembered. The palette is part of the key: a theme
    /// change is a different rendering, not a stale hit.
    static func render(_ source: String, language: String?, palette: Palette) -> String {
        let key = "\(palette.name)|\(language ?? "")|\(source)"
        cacheLock.lock()
        if let hit = cache[key] {
            cacheLock.unlock()
            return hit
        }
        cacheLock.unlock()

        let rendered: String
        if SyntaxHighlighter.isDiff(language) {
            rendered = diffMarkup(source, palette)
        } else {
            let tokens = SyntaxHighlighter.tokens(source, language: language)
            rendered = tokens.isEmpty ? PangoMarkdown.escape(source) : markup(source, tokens, palette)
        }

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

    /// A patch as markup: each changed line wrapped in a span carrying its wash — accent for
    /// added, danger for removed, the same colours the diff's own +N/−N labels wear — with the
    /// marker glyph in the diff's full ink and the body in the file's language, every colour
    /// corrected against the wash it actually sits on rather than the plain code background.
    private static func diffMarkup(_ source: String, _ palette: Palette) -> String {
        let diff = SyntaxHighlighter.diff(source)
        let units = Array(source.utf16)
        let plainTable = SyntaxPalette.table(for: palette)
        var washes: [DiffLineKind: (background: String, table: [SyntaxRole: String])] = [:]
        for kind in [DiffLineKind.added, .removed] {
            guard let ground = SyntaxPalette.diffLineBackground(kind, in: palette) else { continue }
            washes[kind] = (ground, SyntaxPalette.table(for: palette, on: ground))
        }

        func slice(_ from: Int, _ to: Int) -> String {
            guard from < to, to <= units.count else { return "" }
            return String(decoding: units[from..<to], as: UTF16.self)
        }

        var result = ""
        result.reserveCapacity(source.count + diff.tokens.count * 32)
        var tokenIndex = 0
        var cursor = 0
        for line in diff.lines {
            result += PangoMarkdown.escape(slice(cursor, line.offset))
            let wash = washes[line.kind]
            let table = wash?.table ?? plainTable
            let lineEnd = line.offset + line.length
            var body = ""
            var lineCursor = line.offset
            while tokenIndex < diff.tokens.count, diff.tokens[tokenIndex].offset < lineEnd {
                let token = diff.tokens[tokenIndex]
                tokenIndex += 1
                guard token.offset >= lineCursor, token.offset + token.length <= units.count
                else { continue }
                body += PangoMarkdown.escape(slice(lineCursor, token.offset))
                let colour = table[token.role] ?? palette.text
                let run = PangoMarkdown.escape(slice(token.offset, token.offset + token.length))
                body += "<span foreground=\"\(colour)\">\(run)</span>"
                lineCursor = token.offset + token.length
            }
            body += PangoMarkdown.escape(slice(lineCursor, lineEnd))
            if let wash {
                result += "<span background=\"\(wash.background)\">\(body)</span>"
            } else {
                result += body
            }
            cursor = lineEnd
        }
        result += PangoMarkdown.escape(slice(cursor, units.count))
        return result
    }

    /// One line of an Edit tool's diff: the marker in the diff's full ink, the body in the file's
    /// language, the whole line over its wash — the same treatment a fenced patch gets, because a
    /// tool's edit and a quoted diff are the same fact arriving by different roads.
    static func diffLine(
        prefix: String, body: String, kind: DiffLineKind, language: String?, palette: Palette
    ) -> String {
        guard let ground = SyntaxPalette.diffLineBackground(kind, in: palette) else {
            return PangoMarkdown.escape("\(prefix) \(body)")
        }
        let table = SyntaxPalette.table(for: palette, on: ground)
        let marker = table[kind == .added ? .added : .removed] ?? palette.text
        let base = table[.plain] ?? palette.text
        var inner = "<span foreground=\"\(marker)\">\(PangoMarkdown.escape(prefix + " "))</span>"
        let tokens = language.map { SyntaxHighlighter.tokens(body, language: $0) } ?? []
        if tokens.isEmpty {
            inner += "<span foreground=\"\(marker)\">\(PangoMarkdown.escape(body))</span>"
        } else {
            let units = Array(body.utf16)
            func slice(_ from: Int, _ to: Int) -> String {
                guard from < to, to <= units.count else { return "" }
                return String(decoding: units[from..<to], as: UTF16.self)
            }
            var runs = ""
            var cursor = 0
            for token in tokens {
                guard token.offset >= cursor, token.offset + token.length <= units.count
                else { continue }
                runs += PangoMarkdown.escape(slice(cursor, token.offset))
                let run = PangoMarkdown.escape(slice(token.offset, token.offset + token.length))
                runs += "<span foreground=\"\(table[token.role] ?? base)\">\(run)</span>"
                cursor = token.offset + token.length
            }
            runs += PangoMarkdown.escape(slice(cursor, units.count))
            inner += "<span foreground=\"\(base)\">\(runs)</span>"
        }
        return "<span background=\"\(ground)\">\(inner)</span>"
    }

    private static func markup(_ source: String, _ tokens: [SyntaxToken], _ palette: Palette)
        -> String
    {
        let units = Array(source.utf16)
        var colours: [SyntaxRole: String] = [:]
        var result = ""
        result.reserveCapacity(source.count + tokens.count * 32)
        var cursor = 0

        func slice(_ from: Int, _ to: Int) -> String {
            guard from < to, to <= units.count else { return "" }
            return String(decoding: units[from..<to], as: UTF16.self)
        }

        for token in tokens {
            guard token.offset >= cursor, token.offset + token.length <= units.count else { continue }
            result += PangoMarkdown.escape(slice(cursor, token.offset))
            let colour: String
            if let hit = colours[token.role] {
                colour = hit
            } else {
                colour = SyntaxPalette.hex(token.role, in: palette)
                colours[token.role] = colour
            }
            let body = PangoMarkdown.escape(slice(token.offset, token.offset + token.length))
            result += "<span foreground=\"\(colour)\">\(body)</span>"
            cursor = token.offset + token.length
        }
        result += PangoMarkdown.escape(slice(cursor, units.count))
        return result
    }
}
