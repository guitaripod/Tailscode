import Foundation

/// What a run of code *is*, rather than what colour it should be. A client turns a role into its
/// own toolkit's colour through `SyntaxPalette`; nothing here knows about a colour, a font or a
/// text system, which is what lets one lexer serve UIKit's attributed strings, AppKit's, and
/// Pango's markup without any of the three drifting from the others.
public enum SyntaxRole: String, CaseIterable, Sendable, Hashable {
    case plain
    case keyword
    case type
    case function
    case string
    case number
    case comment
    case attribute
    case added
    case removed
}

/// What a diff line *is*, held apart from the code written on it. The kind is the line's ground:
/// added and removed lines wear a wash of the same accent and danger the diff's own +N/−N labels
/// wear, while the code on the line keeps the language's own colours — so what changed and what
/// the change says stay separately readable instead of fighting over one foreground.
public enum DiffLineKind: String, CaseIterable, Sendable, Hashable {
    case added
    case removed
    case context
    case hunk
    case meta
    case note
}

/// One line of a diff, measured like a token: UTF-16 offset and length, newline excluded. `row`
/// is the line's index in the source, for a renderer that paints grounds by geometry — code never
/// wraps in a code block, so a source row is a drawn row.
public struct DiffLineSpan: Equatable, Sendable, Hashable {
    public let offset: Int
    public let length: Int
    public let kind: DiffLineKind
    public let row: Int

    public init(offset: Int, length: Int, kind: DiffLineKind, row: Int) {
        self.offset = offset
        self.length = length
        self.kind = kind
        self.row = row
    }
}

/// A diff read twice: once by its first column, which says what happened to each line, and once
/// by the language the file is written in, which says what each line means. A client paints the
/// line spans as grounds and the tokens as ink; when no language identifies itself the tokens
/// fall back to one run per changed line, which is exactly the old whole-line red and green.
public struct DiffHighlight: Equatable, Sendable {
    public let lines: [DiffLineSpan]
    public let tokens: [SyntaxToken]
    /// The fence's own tag when it named a real language, else the language the patch's `+++`/
    /// `---`/`diff --git` headers point at; nil when nothing identifies the file.
    public let language: String?

    public init(lines: [DiffLineSpan], tokens: [SyntaxToken], language: String?) {
        self.lines = lines
        self.tokens = tokens
        self.language = language
    }

    /// The kind of the line a token sits on, for a client choosing ink against that line's ground.
    /// Both lists are ordered, so a renderer walking tokens in order can two-pointer this itself;
    /// this is the simple form for callers that touch a token at a time.
    public func kind(at offset: Int) -> DiffLineKind {
        var low = 0
        var high = lines.count - 1
        while low <= high {
            let middle = (low + high) / 2
            let line = lines[middle]
            if offset < line.offset {
                high = middle - 1
            } else if offset >= line.offset + line.length + 1 {
                low = middle + 1
            } else {
                return line.kind
            }
        }
        return .context
    }
}

/// A coloured run, measured in UTF-16 units because that is the unit both `NSRange` and every
/// text system on Apple's side count in; the Pango client converts once on its way out.
public struct SyntaxToken: Equatable, Sendable, Hashable {
    public let offset: Int
    public let length: Int
    public let role: SyntaxRole

    public init(offset: Int, length: Int, role: SyntaxRole) {
        self.offset = offset
        self.length = length
        self.role = role
    }
}

/// The one lexer the three clients share.
///
/// Not a parser: an answer arrives a lump at a time and the last block in it is nearly always
/// half-written, so a highlighter that needs a valid tree has nothing to say about the code being
/// typed in front of the reader. This one is a single left-to-right pass that claims comments and
/// strings first and can therefore never colour a `//` inside a string or a keyword inside a
/// comment, and an unterminated run simply owns the rest of the block — which is exactly right
/// while it is still being written.
public enum SyntaxHighlighter {
    /// Past this, the block is data rather than code — a pasted log, a base64 blob, a lockfile —
    /// and the pass is skipped rather than run over something no one is reading as syntax.
    public static let sourceLimit = 40_000

    /// The canonical name for a fence tag, for the header a block wears. An unknown tag keeps its
    /// own spelling rather than being called "text": the agent named it for a reason.
    public static func displayName(for tag: String?) -> String {
        guard let tag = normalized(tag), !tag.isEmpty else { return "code" }
        return canonicalNames[tag] ?? tag
    }

    /// Whether anything is known about this fence tag. A client uses it to decide between a
    /// highlighted block and a plain one without lexing first.
    public static func isKnown(_ tag: String?) -> Bool {
        guard let tag = normalized(tag) else { return false }
        return dialects[tag] != nil
    }

    public static func tokens(_ source: String, language: String?) -> [SyntaxToken] {
        guard source.utf16.count <= sourceLimit else { return [] }
        guard let tag = normalized(language), let dialect = dialects[tag] else { return [] }
        var scanner = SyntaxScanner(source)
        switch dialect {
        case .general(let grammar): scanner.scanGeneral(grammar)
        case .diff: scanner.scanDiff()
        case .markup: scanner.scanMarkup()
        case .style: scanner.scanStyle()
        case .keyed(let flavour): scanner.scanKeyed(flavour)
        case .markdown: scanner.scanMarkdown()
        }
        return scanner.tokens
    }

    /// Whether a fence tag means "this block is a patch", which a client uses to route the block
    /// through `diff(_:language:)` rather than the flat token pass.
    public static func isDiff(_ tag: String?) -> Bool {
        guard let tag = normalized(tag), let dialect = dialects[tag] else { return false }
        if case .diff = dialect { return true }
        return false
    }

    /// The block header's name, aware of what a diff carries: a patch that names its own file wears
    /// both facts — `diff · swift` — because both are true and each answers a different question.
    public static func displayName(for tag: String?, source: String) -> String {
        guard isDiff(tag) else { return displayName(for: tag) }
        guard let inner = diffLanguage(in: source) else { return displayName(for: tag) }
        return displayName(for: tag) + " · " + displayName(for: inner)
    }

    /// A diff read by line and, where the file identifies itself, by language. `language` names
    /// the file's language when the caller knows it (an Edit tool knows its path); a nil hint is
    /// inferred from the patch's own headers.
    public static func diff(_ source: String, language hint: String? = nil) -> DiffHighlight {
        guard source.utf16.count <= sourceLimit else {
            return DiffHighlight(lines: [], tokens: [], language: nil)
        }
        let resolved = innerLanguage(hint) ?? diffLanguage(in: source)
        var lines: [DiffLineSpan] = []
        var tokens: [SyntaxToken] = []
        var offset = 0
        var row = 0
        for slice in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(slice)
            let length = line.utf16.count
            defer {
                offset += length + 1
                row += 1
            }
            guard length > 0 else { continue }
            let kind = diffLineKind(line)
            lines.append(DiffLineSpan(offset: offset, length: length, kind: kind, row: row))
            appendDiffTokens(line, kind: kind, at: offset, language: resolved, into: &tokens)
        }
        return DiffHighlight(lines: lines, tokens: tokens, language: resolved)
    }

    /// The line spans alone — what a renderer painting grounds needs, without the cost of lexing
    /// every line's code a second time.
    public static func diffLines(_ source: String) -> [DiffLineSpan] {
        guard source.utf16.count <= sourceLimit else { return [] }
        var lines: [DiffLineSpan] = []
        var offset = 0
        var row = 0
        for slice in source.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(slice)
            let length = line.utf16.count
            if length > 0 {
                lines.append(
                    DiffLineSpan(offset: offset, length: length, kind: diffLineKind(line), row: row))
            }
            offset += length + 1
            row += 1
        }
        return lines
    }

    /// The language a patch's own headers point at: `+++ b/Sources/App.swift` names the file the
    /// hunks below it change, and the file names its language. A bare run of `+`/`-` lines — the
    /// way an agent usually quotes a change — names nothing, and nothing is guessed.
    public static func diffLanguage(in source: String) -> String? {
        for slice in source.split(separator: "\n").prefix(40) {
            let line = String(slice)
            if line.hasPrefix("+++ ") || line.hasPrefix("--- ") {
                if let tag = language(forPath: headerPath(String(line.dropFirst(4)))) { return tag }
            } else if line.hasPrefix("diff --git ") {
                guard let last = line.split(separator: " ").last else { continue }
                if let tag = language(forPath: headerPath(String(last))) { return tag }
            }
        }
        return nil
    }

    /// The fence tag a file path implies, for highlighting code that arrived named by path rather
    /// than by fence — a diff header, an Edit tool's `file_path`.
    public static func language(forPath path: String) -> String? {
        let name = path.split(separator: "/").last.map(String.init) ?? path
        let lowered = name.lowercased()
        if let special = specialFilenames[lowered] { return special }
        if lowered.hasPrefix("dockerfile") { return "dockerfile" }
        if lowered.hasPrefix("makefile") { return "make" }
        guard let dot = lowered.lastIndex(of: "."), dot != lowered.startIndex else { return nil }
        let ext = String(lowered[lowered.index(after: dot)...])
        guard !ext.isEmpty, dialects[ext] != nil else { return nil }
        return ext
    }

    /// A `+++`/`---` path with git's `a/`/`b/` prefix and any trailing tab metadata removed;
    /// `/dev/null` (a created or deleted file's other half) resolves to nothing.
    private static func headerPath(_ raw: String) -> String {
        var path = raw
        if let tab = path.firstIndex(of: "\t") { path = String(path[..<tab]) }
        if path.hasPrefix("a/") || path.hasPrefix("b/") { path = String(path.dropFirst(2)) }
        return path == "/dev/null" ? "" : path
    }

    /// The hint a caller passed, admitted only when it names a real language that is not itself a
    /// diff — `diff` and `patch` are the block's tag, not the code's.
    private static func innerLanguage(_ tag: String?) -> String? {
        guard let tag = normalized(tag), let dialect = dialects[tag] else { return nil }
        if case .diff = dialect { return nil }
        return tag
    }

    private static func diffLineKind(_ line: String) -> DiffLineKind {
        if line.hasPrefix("+++") || line.hasPrefix("---") { return .meta }
        for prefix in ["diff ", "index ", "new file", "deleted file", "rename ", "similarity ",
            "old mode", "new mode", "Binary files"] where line.hasPrefix(prefix) {
            return .meta
        }
        if line.hasPrefix("@@") { return .hunk }
        if line.hasPrefix("+") { return .added }
        if line.hasPrefix("-") { return .removed }
        if line.hasPrefix("\\") { return .note }
        return .context
    }

    /// A changed line is a marker and a body. The marker keeps the diff's own role — it is the one
    /// glyph whose ink must still shout added or removed — and the body is lexed by the file's
    /// language, per line, because a hunk interleaves added, removed and context lines and no
    /// multi-line construct survives that ordering anyway. Without a language the body keeps the
    /// marker's role whole, which is the old single-run look.
    private static func appendDiffTokens(
        _ line: String, kind: DiffLineKind, at offset: Int, language: String?,
        into tokens: inout [SyntaxToken]
    ) {
        switch kind {
        case .meta:
            tokens.append(SyntaxToken(offset: offset, length: line.utf16.count, role: .attribute))
        case .hunk:
            tokens.append(SyntaxToken(offset: offset, length: line.utf16.count, role: .type))
        case .note:
            tokens.append(SyntaxToken(offset: offset, length: line.utf16.count, role: .comment))
        case .added, .removed:
            let role: SyntaxRole = kind == .added ? .added : .removed
            tokens.append(SyntaxToken(offset: offset, length: 1, role: role))
            let body = String(line.dropFirst())
            guard !body.isEmpty else { return }
            if let language {
                for token in Self.tokens(body, language: language) {
                    tokens.append(SyntaxToken(
                        offset: offset + 1 + token.offset, length: token.length, role: token.role))
                }
            } else {
                tokens.append(SyntaxToken(offset: offset + 1, length: body.utf16.count, role: role))
            }
        case .context:
            guard let language else { return }
            for token in Self.tokens(line, language: language) {
                tokens.append(SyntaxToken(
                    offset: offset + token.offset, length: token.length, role: token.role))
            }
        }
    }

    private static let specialFilenames: [String: String] = [
        "gemfile": "ruby", "rakefile": "ruby", "podfile": "ruby", "fastfile": "ruby",
        "cargo.lock": "toml", "cmakelists.txt": "cmake", ".bashrc": "bash", ".zshrc": "bash",
        ".bash_profile": "bash", ".profile": "bash", "justfile": "make",
    ]

    private static func normalized(_ tag: String?) -> String? {
        guard let tag else { return nil }
        let head = tag.split(whereSeparator: { $0 == " " || $0 == "," || $0 == ":" }).first
        guard let head else { return nil }
        return head.lowercased()
    }
}
