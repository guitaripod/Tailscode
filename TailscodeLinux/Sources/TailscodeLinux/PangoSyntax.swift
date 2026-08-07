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

        let tokens = SyntaxHighlighter.tokens(source, language: language)
        let rendered = tokens.isEmpty ? PangoMarkdown.escape(source) : markup(source, tokens, palette)

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
