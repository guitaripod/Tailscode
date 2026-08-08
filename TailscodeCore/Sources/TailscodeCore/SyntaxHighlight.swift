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

/// The grammar of one language family, as data rather than code. Nearly every language an agent
/// writes is a comment style, a string style, a keyword list and a couple of habits, so they are
/// spelled out in a table and lexed by one scanner — a new language is a table entry, not a parser.
struct SyntaxGrammar: Sendable {
    struct Block: Sendable {
        let open: String
        let close: String
        let nests: Bool

        init(_ open: String, _ close: String, nests: Bool = false) {
            self.open = open
            self.close = close
            self.nests = nests
        }
    }

    /// A hole in a string where code goes: `\(name)` in Swift, `${…}` in a shell or a template
    /// literal, a bare `$VAR` where the shell needs no braces. A `close` of nil means the hole ends
    /// where the identifier does.
    struct Interpolation: Sendable {
        let open: String
        let close: String?

        init(_ open: String, _ close: String? = nil) {
            self.open = open
            self.close = close
        }
    }

    struct Quote: Sendable {
        let open: String
        let close: String
        let escape: Character?
        let multiline: Bool
        /// Only the quote styles that actually interpolate carry these, which is why a shell's
        /// single quotes leave `$HOME` alone and its double quotes do not.
        let interpolations: [Interpolation]

        init(
            _ open: String, _ close: String? = nil, escape: Character? = "\\",
            multiline: Bool = false, interpolations: [Interpolation] = []
        ) {
            self.open = open
            self.close = close ?? open
            self.escape = escape
            self.multiline = multiline
            self.interpolations = interpolations
        }
    }

    var lineComments: [String] = []
    var blocks: [Block] = []
    var quotes: [Quote] = []
    var keywords: Set<String> = []
    var builtins: Set<String> = []
    var caseInsensitive = false
    var capitalizedIsType = false
    var callIsFunction = true
    /// `@decorator`, `#[derive]`, `#include` — a mark on the code rather than code.
    var attributeSigils: [String] = []
    /// `$VAR` and `${VAR}` in the shells, `$name` in PHP.
    var dollarVariables = false
    var identifierExtras: Set<Character> = ["_"]
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
        var scanner = Scanner(source)
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

/// Which of the six passes a tag is lexed by. Most languages are `general`; the rest earn a pass
/// because their meaning is not carried by keywords — a diff's meaning is in its first column, a
/// config file's in what sits left of the colon.
enum SyntaxDialect: Sendable {
    case general(SyntaxGrammar)
    case diff
    case markup
    case style
    case keyed(KeyedFlavour)
    case markdown
}

/// The shape of a key/value file: what opens a comment, and whether `[section]` headers exist.
struct KeyedFlavour: Sendable {
    let lineComments: [String]
    let sections: Bool
    let quotesValues: Bool
    /// JSON has no bare keys, so a quoted run before a colon is the key rather than a string.
    let quotedKeys: Bool
}

private struct Scanner {
    private let chars: [Character]
    private var index = 0
    private var offset = 0
    private(set) var tokens: [SyntaxToken] = []

    init(_ source: String) {
        chars = Array(source)
        tokens.reserveCapacity(64)
    }

    private var isAtEnd: Bool { index >= chars.count }

    private func peek(_ ahead: Int = 0) -> Character? {
        let position = index + ahead
        guard position >= 0, position < chars.count else { return nil }
        return chars[position]
    }

    private mutating func advance() {
        guard !isAtEnd else { return }
        offset += chars[index].utf16.count
        index += 1
    }

    private mutating func advance(_ count: Int) {
        for _ in 0..<count where !isAtEnd { advance() }
    }

    private func matches(_ text: String, at ahead: Int = 0) -> Bool {
        var position = index + ahead
        for character in text {
            guard position < chars.count, chars[position] == character else { return false }
            position += 1
        }
        return true
    }

    private mutating func emit(from start: Int, _ role: SyntaxRole) {
        guard offset > start else { return }
        tokens.append(SyntaxToken(offset: start, length: offset - start, role: role))
    }

    private var atLineStart: Bool {
        var position = index - 1
        while position >= 0 {
            let character = chars[position]
            if character == "\n" { return true }
            if !character.isWhitespace { return false }
            position -= 1
        }
        return true
    }

    private mutating func skipToLineEnd() {
        while !isAtEnd, peek() != "\n" { advance() }
    }

    private mutating func consumeLineComment() {
        skipToLineEnd()
    }

    private mutating func consumeBlock(_ block: SyntaxGrammar.Block) {
        advance(block.open.count)
        var depth = 1
        while !isAtEnd {
            if block.nests, matches(block.open) {
                depth += 1
                advance(block.open.count)
                continue
            }
            if matches(block.close) {
                advance(block.close.count)
                depth -= 1
                if depth == 0 { return }
                continue
            }
            advance()
        }
    }

    private mutating func consumeQuote(_ quote: SyntaxGrammar.Quote) {
        advance(quote.open.count)
        while !isAtEnd {
            if let escape = quote.escape, peek() == escape {
                advance(2)
                continue
            }
            if !quote.multiline, peek() == "\n" { return }
            if matches(quote.close) {
                advance(quote.close.count)
                return
            }
            advance()
        }
    }

    /// A string, emitted as the runs it is actually made of. A quote that interpolates is not one
    /// colour: `"deploying ${TARGET} now"` is two pieces of text with a piece of code between them,
    /// and colouring the variable as string is how a reader misses that the line has a hole in it.
    /// The hole is checked before the escape, because Swift's `\(` opens one with the same
    /// character that escapes.
    private mutating func scanString(_ quote: SyntaxGrammar.Quote, _ extras: Set<Character>) {
        var runStart = offset
        advance(quote.open.count)
        while !isAtEnd {
            if let hole = quote.interpolations.first(where: { matches($0.open) }) {
                emit(from: runStart, .string)
                let holeStart = offset
                consumeInterpolation(hole, extras)
                emit(from: holeStart, .attribute)
                runStart = offset
                continue
            }
            if let escape = quote.escape, peek() == escape {
                advance(2)
                continue
            }
            if !quote.multiline, peek() == "\n" { break }
            if matches(quote.close) {
                advance(quote.close.count)
                break
            }
            advance()
        }
        emit(from: runStart, .string)
    }

    private mutating func consumeInterpolation(
        _ hole: SyntaxGrammar.Interpolation, _ extras: Set<Character>
    ) {
        advance(hole.open.count)
        guard let close = hole.close else {
            _ = consumeIdentifier(extras)
            return
        }
        var depth = 1
        while !isAtEnd, depth > 0 {
            if matches(hole.open) {
                depth += 1
                advance(hole.open.count)
                continue
            }
            if matches(close) {
                depth -= 1
                advance(close.count)
                continue
            }
            advance()
        }
    }

    private static func isIdentifierStart(_ character: Character, _ extras: Set<Character>) -> Bool {
        character.isLetter || extras.contains(character)
    }

    private static func isIdentifierBody(_ character: Character, _ extras: Set<Character>) -> Bool {
        character.isLetter || character.isNumber || extras.contains(character)
    }

    private mutating func consumeIdentifier(_ extras: Set<Character>) -> String {
        var word = ""
        while let character = peek(), Self.isIdentifierBody(character, extras) {
            word.append(character)
            advance()
        }
        return word
    }

    /// Digits, and everything a language lets a reader write inside a number: radix prefixes,
    /// group separators, an exponent with its sign, and a trailing width or unit suffix. Stopping
    /// at the first non-digit would break `0xFF`, `1_000_000` and `1.5e-3` into three tokens each.
    private mutating func consumeNumber() {
        var previous: Character = "0"
        var isHex = false
        while let character = peek() {
            guard continuesNumber(character, previous: previous, isHex: isHex) else { break }
            if character == "x" || character == "X" { isHex = true }
            previous = character
            advance()
        }
    }

    /// Whether a character still belongs to the number being read: a digit of any radix, a group
    /// separator, a fractional part, a width or radix suffix, or the sign of an exponent. The sign
    /// is only a sign directly after an exponent marker, and in a hex literal `e` is a digit rather
    /// than a marker — otherwise `1.5e-3` loses its exponent and `0xFFe-1` swallows a minus.
    private func continuesNumber(_ character: Character, previous: Character, isHex: Bool) -> Bool {
        if character.isHexDigit || character == "_" || character == "'" { return true }
        if character == "+" || character == "-" {
            return (isHex ? "pP" : "eEpP").contains(previous)
        }
        if character == ".", let next = peek(1), next.isNumber { return true }
        return "xXoObBuUlLfFdDnpP".contains(character)
    }

    private mutating func skipSpacesOnLine() -> Int {
        var skipped = 0
        while let character = peek(), character == " " || character == "\t" {
            advance()
            skipped += 1
        }
        return skipped
    }

    mutating func scanGeneral(_ grammar: SyntaxGrammar) {
        while !isAtEnd {
            let start = offset

            if let comment = grammar.lineComments.first(where: { matches($0) }) {
                advance(comment.count)
                consumeLineComment()
                emit(from: start, .comment)
                continue
            }

            if let block = grammar.blocks.first(where: { matches($0.open) }) {
                consumeBlock(block)
                emit(from: start, .comment)
                continue
            }

            if let quote = grammar.quotes.first(where: { matches($0.open) }) {
                scanString(quote, grammar.identifierExtras)
                continue
            }

            if let sigil = grammar.attributeSigils.first(where: { matches($0) }) {
                if consumeAttribute(sigil, grammar) {
                    emit(from: start, .attribute)
                    continue
                }
            }

            if grammar.dollarVariables, peek() == "$" {
                advance()
                if peek() == "{" {
                    while !isAtEnd, peek() != "}" { advance() }
                    advance()
                } else {
                    _ = consumeIdentifier(grammar.identifierExtras)
                }
                emit(from: start, .attribute)
                continue
            }

            if let character = peek(), character.isNumber {
                consumeNumber()
                emit(from: start, .number)
                continue
            }

            if let character = peek(), Self.isIdentifierStart(character, grammar.identifierExtras) {
                let word = consumeIdentifier(grammar.identifierExtras)
                emit(from: start, role(of: word, grammar))
                continue
            }

            advance()
        }
    }

    /// An attribute is only an attribute where one can start: `#include` at the head of a line is
    /// a directive, `a #b` inside an expression is not. Rust's `#[…]` carries its own brackets and
    /// is claimed whole so a derive list does not lex as a slice.
    private mutating func consumeAttribute(_ sigil: String, _ grammar: SyntaxGrammar) -> Bool {
        if sigil == "#" && !atLineStart { return false }
        if sigil == "#[" {
            guard atLineStart || peek(-1) == nil || (peek(-1)?.isWhitespace ?? true) else { return false }
            advance(2)
            var depth = 1
            while !isAtEnd, depth > 0 {
                if peek() == "[" { depth += 1 }
                if peek() == "]" { depth -= 1 }
                advance()
            }
            return true
        }
        guard let next = peek(sigil.count),
            Self.isIdentifierStart(next, grammar.identifierExtras)
        else { return false }
        advance(sigil.count)
        _ = consumeIdentifier(grammar.identifierExtras)
        return true
    }

    private mutating func role(of word: String, _ grammar: SyntaxGrammar) -> SyntaxRole {
        let probe = grammar.caseInsensitive ? word.lowercased() : word
        if grammar.keywords.contains(probe) { return .keyword }
        if grammar.builtins.contains(probe) { return .type }
        if grammar.callIsFunction {
            var ahead = 0
            while let character = peek(ahead), character == " " { ahead += 1 }
            if peek(ahead) == "(" { return .function }
        }
        if grammar.capitalizedIsType, let first = word.first, first.isUppercase { return .type }
        return .plain
    }

    /// A diff's meaning lives in the first column, so it is lexed by line and nothing inside a line
    /// is coloured — a `-` line stays one red run whether or not the code on it happens to parse.
    mutating func scanDiff() {
        while !isAtEnd {
            let start = offset
            let head = peek()
            if matches("+++") || matches("---") || matches("diff ") || matches("index ") {
                skipToLineEnd()
                emit(from: start, .attribute)
            } else if matches("@@") {
                skipToLineEnd()
                emit(from: start, .type)
            } else if head == "+" {
                skipToLineEnd()
                emit(from: start, .added)
            } else if head == "-" {
                skipToLineEnd()
                emit(from: start, .removed)
            } else if head == "\\" {
                skipToLineEnd()
                emit(from: start, .comment)
            } else {
                skipToLineEnd()
            }
            advance()
        }
    }

    mutating func scanMarkup() {
        while !isAtEnd {
            let start = offset
            if matches("<!--") {
                consumeBlock(SyntaxGrammar.Block("<!--", "-->"))
                emit(from: start, .comment)
                continue
            }
            if peek() == "&" {
                advance()
                let entity = consumeIdentifier(["_", "#"])
                if peek() == ";", !entity.isEmpty {
                    advance()
                    emit(from: start, .number)
                    continue
                }
                continue
            }
            guard peek() == "<" else {
                advance()
                continue
            }
            advance()
            if peek() == "/" { advance() }
            if peek() == "!" || peek() == "?" { advance() }
            _ = consumeIdentifier(["_", "-", ":"])
            emit(from: start, .keyword)
            scanMarkupAttributes()
        }
    }

    private mutating func scanMarkupAttributes() {
        while !isAtEnd, peek() != ">" {
            if peek()?.isWhitespace == true {
                advance()
                continue
            }
            let start = offset
            if matches("\"") || matches("'") {
                consumeQuote(SyntaxGrammar.Quote(String(peek() ?? "\""), multiline: true))
                emit(from: start, .string)
                continue
            }
            if let character = peek(), Self.isIdentifierStart(character, ["_", "-", ":", "@"]) {
                _ = consumeIdentifier(["_", "-", ":", "@"])
                emit(from: start, .attribute)
                continue
            }
            advance()
        }
        let start = offset
        if peek() == ">" {
            advance()
            emit(from: start, .keyword)
        }
    }

    /// A stylesheet reads as selector → property → value, and the three want different colours, so
    /// the pass tracks whether it is inside a rule body rather than matching a keyword list.
    mutating func scanStyle() {
        var inBody = false
        while !isAtEnd {
            let start = offset
            if matches("/*") {
                consumeBlock(SyntaxGrammar.Block("/*", "*/"))
                emit(from: start, .comment)
                continue
            }
            if matches("//") {
                advance(2)
                consumeLineComment()
                emit(from: start, .comment)
                continue
            }
            if matches("\"") || matches("'") {
                consumeQuote(SyntaxGrammar.Quote(String(peek() ?? "\"")))
                emit(from: start, .string)
                continue
            }
            if peek() == "{" {
                inBody = true
                advance()
                continue
            }
            if peek() == "}" {
                inBody = false
                advance()
                continue
            }
            if peek() == "@" {
                advance()
                _ = consumeIdentifier(["_", "-"])
                emit(from: start, .keyword)
                continue
            }
            if peek() == "$" || peek() == "-" && matches("--") {
                advance()
                _ = consumeIdentifier(["_", "-"])
                emit(from: start, .attribute)
                continue
            }
            if let character = peek(), character.isNumber {
                consumeNumber()
                _ = consumeIdentifier(["%"])
                emit(from: start, .number)
                continue
            }
            if let character = peek(), Self.isIdentifierStart(character, ["_", "-"]) {
                _ = consumeIdentifier(["_", "-"])
                if inBody {
                    var ahead = 0
                    while let probe = peek(ahead), probe == " " { ahead += 1 }
                    emit(from: start, peek(ahead) == ":" ? .attribute : .type)
                } else {
                    emit(from: start, .type)
                }
                continue
            }
            advance()
        }
    }

    mutating func scanKeyed(_ flavour: KeyedFlavour) {
        var lineHandled = false
        while !isAtEnd {
            if peek() == "\n" {
                lineHandled = false
                advance()
                continue
            }
            if !lineHandled, atLineStart {
                lineHandled = true
                let lineStart = offset
                if flavour.sections, peek() == "[" {
                    skipToLineEnd()
                    emit(from: lineStart, .type)
                    continue
                }
                _ = skipSpacesOnLine()
                while peek() == "-", peek(1) == " " { advance(2) }
                if scanKey(flavour) { continue }
            }
            let start = offset
            if let comment = flavour.lineComments.first(where: { matches($0) }) {
                advance(comment.count)
                consumeLineComment()
                emit(from: start, .comment)
                continue
            }
            if matches("\"") || matches("'") {
                consumeQuote(SyntaxGrammar.Quote(String(peek() ?? "\"")))
                emit(from: start, .string)
                continue
            }
            if let character = peek(), character.isNumber,
                !Self.isIdentifierBody(peek(-1) ?? " ", ["_"])
            {
                consumeNumber()
                emit(from: start, .number)
                continue
            }
            if let character = peek(), Self.isIdentifierStart(character, ["_"]) {
                let word = consumeIdentifier(["_", "-"])
                if Self.literals.contains(word.lowercased()) { emit(from: start, .keyword) }
                continue
            }
            advance()
        }
    }

    /// A key is a bare or quoted word with a colon or an equals after it, and only the word is
    /// coloured — the separator and the value belong to the passes that follow. A word without a
    /// separator is not a key, so the scanner is put back where it started and the line is read as
    /// a value: a YAML list of bare strings must not come out looking like a list of keys.
    private mutating func scanKey(_ flavour: KeyedFlavour) -> Bool {
        let mark = (index: index, offset: offset, tokens: tokens.count)
        if let character = peek(), character == "\"" || character == "'" {
            guard flavour.quotedKeys || character == "\"" else { return false }
            consumeQuote(SyntaxGrammar.Quote(String(character)))
        } else if let character = peek(), Self.isIdentifierStart(character, ["_"]) {
            _ = consumeIdentifier(["_", "-", ".", "/"])
        } else {
            return false
        }
        let keyEnd = (index: index, offset: offset)
        _ = skipSpacesOnLine()
        let isKey = peek() == ":" || peek() == "="
        index = keyEnd.index
        offset = keyEnd.offset
        guard isKey else {
            index = mark.index
            offset = mark.offset
            tokens.removeLast(tokens.count - mark.tokens)
            return false
        }
        tokens.removeLast(tokens.count - mark.tokens)
        emit(from: mark.offset, .attribute)
        return true
    }

    mutating func scanMarkdown() {
        while !isAtEnd {
            let start = offset
            if atLineStart, peek() == "#" {
                skipToLineEnd()
                emit(from: start, .keyword)
                continue
            }
            if atLineStart, peek() == ">" {
                skipToLineEnd()
                emit(from: start, .comment)
                continue
            }
            if matches("```") || matches("~~~") {
                let fence = String(chars[index]) + String(chars[index]) + String(chars[index])
                advance(3)
                skipToLineEnd()
                while !isAtEnd, !matches(fence) { advance() }
                advance(3)
                emit(from: start, .string)
                continue
            }
            if peek() == "`" {
                consumeQuote(SyntaxGrammar.Quote("`", escape: nil))
                emit(from: start, .string)
                continue
            }
            if peek() == "[" {
                while !isAtEnd, peek() != "]", peek() != "\n" { advance() }
                advance()
                if peek() == "(" {
                    while !isAtEnd, peek() != ")", peek() != "\n" { advance() }
                    advance()
                }
                emit(from: start, .type)
                continue
            }
            if atLineStart, peek() == "-" || peek() == "*" || peek() == "+" {
                if peek(1) == " " {
                    advance()
                    emit(from: start, .attribute)
                    continue
                }
            }
            advance()
        }
    }

    private static let literals: Set<String> = [
        "true", "false", "null", "nil", "none", "yes", "no", "on", "off",
    ]
}

extension SyntaxHighlighter {
    /// What a fence tag is called once resolved, for the header a code block wears. Only the tags
    /// whose spelling differs from the name a reader expects need an entry.
    static let canonicalNames: [String: String] = [
        "py": "python", "rb": "ruby", "rs": "rust", "js": "javascript", "ts": "typescript",
        "kt": "kotlin", "yml": "yaml", "sh": "bash", "zsh": "bash", "shell": "bash",
        "console": "bash", "objc": "objective-c", "cpp": "c++", "cc": "c++", "cs": "c#",
        "csharp": "c#", "md": "markdown", "patch": "diff", "jl": "julia", "ex": "elixir",
        "exs": "elixir", "hs": "haskell", "pl": "perl", "ps1": "powershell", "tf": "terraform",
    ]

    static let dialects: [String: SyntaxDialect] = {
        var table: [String: SyntaxDialect] = [:]
        func register(_ tags: [String], _ dialect: SyntaxDialect) {
            for tag in tags { table[tag] = dialect }
        }

        register(["swift"], .general(Grammars.swift))
        register(["rust", "rs"], .general(Grammars.rust))
        register(
            ["javascript", "js", "jsx", "mjs", "cjs", "typescript", "ts", "tsx"],
            .general(Grammars.javascript))
        register(["python", "py"], .general(Grammars.python))
        register(["go", "golang"], .general(Grammars.go))
        register(["c", "h"], .general(Grammars.c))
        register(["cpp", "c++", "cc", "cxx", "hpp", "hh", "objc", "m", "mm", "metal"],
            .general(Grammars.cpp))
        register(["java"], .general(Grammars.java))
        register(["kotlin", "kt", "kts"], .general(Grammars.kotlin))
        register(["cs", "csharp"], .general(Grammars.csharp))
        register(["ruby", "rb"], .general(Grammars.ruby))
        register(
            ["bash", "sh", "zsh", "shell", "console", "fish", "shellsession"],
            .general(Grammars.shell))
        register(["php"], .general(Grammars.php))
        register(["lua"], .general(Grammars.lua))
        register(["sql", "postgres", "psql", "mysql", "sqlite"], .general(Grammars.sql))
        register(["haskell", "hs"], .general(Grammars.haskell))
        register(["elixir", "ex", "exs"], .general(Grammars.elixir))
        register(["zig"], .general(Grammars.zig))
        register(["dart"], .general(Grammars.dart))
        register(["scala"], .general(Grammars.scala))
        register(["perl", "pl"], .general(Grammars.perl))
        register(["r"], .general(Grammars.r))
        register(["julia", "jl"], .general(Grammars.julia))
        register(["nix"], .general(Grammars.nix))
        register(["lisp", "clojure", "clj", "cljs", "scheme", "elisp"], .general(Grammars.lisp))
        register(["powershell", "ps1", "pwsh"], .general(Grammars.powershell))
        register(["groovy", "gradle"], .general(Grammars.java))
        register(["terraform", "tf", "hcl"], .general(Grammars.hcl))
        register(["dockerfile", "docker"], .general(Grammars.dockerfile))
        register(["make", "makefile", "cmake"], .general(Grammars.make))
        register(["vim", "viml"], .general(Grammars.vim))

        register(["diff", "patch"], .diff)
        register(["html", "xml", "svg", "xhtml", "vue", "svelte", "plist"], .markup)
        register(["css", "scss", "sass", "less"], .style)
        register(["markdown", "md", "mdx"], .markdown)

        register(
            ["json", "json5", "jsonc", "geojson"],
            .keyed(KeyedFlavour(
                lineComments: ["//"], sections: false, quotesValues: true, quotedKeys: true)))
        register(
            ["yaml", "yml"],
            .keyed(KeyedFlavour(
                lineComments: ["#"], sections: false, quotesValues: true, quotedKeys: false)))
        register(
            ["toml", "ini", "cfg", "conf", "properties", "env", "dotenv", "editorconfig"],
            .keyed(KeyedFlavour(
                lineComments: ["#", ";"], sections: true, quotesValues: true, quotedKeys: false)))

        return table
    }()
}

/// The language table. Each entry is a comment style, a string style and a word list — the amount
/// of grammar a reader actually decodes by colour. Anything finer (a type inferred, a shadowed
/// binding) belongs to a compiler, not to a transcript.
enum Grammars {
    private static let cQuotes: [SyntaxGrammar.Quote] = [
        SyntaxGrammar.Quote("\""), SyntaxGrammar.Quote("'"),
    ]
    private static let cBlocks = [SyntaxGrammar.Block("/*", "*/")]

    static let swift = SyntaxGrammar(
        lineComments: ["///", "//"],
        blocks: [SyntaxGrammar.Block("/*", "*/", nests: true)],
        quotes: [
            SyntaxGrammar.Quote("\"\"\"", multiline: true, interpolations: [.init("\\(", ")")]),
            SyntaxGrammar.Quote("\"", interpolations: [.init("\\(", ")")]),
        ],
        keywords: [
            "actor", "as", "associatedtype", "async", "await", "borrowing", "break", "case",
            "catch", "class", "consuming", "continue", "convenience", "default", "defer", "deinit",
            "didSet", "do", "dynamic", "each", "else", "enum", "extension", "fallthrough", "false",
            "fileprivate", "final", "for", "func", "get", "guard", "if", "import", "in", "indirect",
            "infix", "init", "inout", "internal", "is", "lazy", "let", "macro", "mutating",
            "nil", "nonisolated", "nonmutating", "open", "operator", "override", "package",
            "postfix", "precedencegroup", "prefix", "private", "protocol", "public", "repeat",
            "required", "rethrows", "return", "self", "sending", "set", "some", "static", "struct",
            "subscript", "super", "switch", "throw", "throws", "true", "try", "typealias", "var",
            "weak", "where", "while", "willSet", "unowned", "unsafe", "any", "consume", "copy",
        ],
        builtins: [
            "Any", "AnyObject", "Array", "Bool", "Character", "Data", "Date", "Dictionary",
            "Double", "Error", "Float", "Int", "Never", "Optional", "Result", "Sendable", "Set",
            "String", "Task", "UInt", "URL", "Void",
        ],
        capitalizedIsType: true,
        attributeSigils: ["@"])

    static let rust = SyntaxGrammar(
        lineComments: ["///", "//!", "//"],
        blocks: [SyntaxGrammar.Block("/*", "*/", nests: true)],
        quotes: [SyntaxGrammar.Quote("r#\"", "\"#", escape: nil, multiline: true),
            SyntaxGrammar.Quote("\"", multiline: true), SyntaxGrammar.Quote("'")],
        keywords: [
            "as", "async", "await", "break", "const", "continue", "crate", "dyn", "else", "enum",
            "extern", "false", "fn", "for", "if", "impl", "in", "let", "loop", "match", "mod",
            "move", "mut", "pub", "ref", "return", "self", "Self", "static", "struct", "super",
            "trait", "true", "type", "union", "unsafe", "use", "where", "while", "yield",
        ],
        builtins: [
            "bool", "char", "f32", "f64", "i8", "i16", "i32", "i64", "i128", "isize", "str",
            "u8", "u16", "u32", "u64", "u128", "usize", "String", "Vec", "Option", "Result",
            "Box", "Rc", "Arc", "HashMap", "HashSet", "Some", "None", "Ok", "Err",
        ],
        capitalizedIsType: true,
        attributeSigils: ["#["])

    static let javascript = SyntaxGrammar(
        lineComments: ["//"],
        blocks: cBlocks,
        quotes: [
            SyntaxGrammar.Quote("`", multiline: true, interpolations: [.init("${", "}")]),
            SyntaxGrammar.Quote("\""), SyntaxGrammar.Quote("'"),
        ],
        keywords: [
            "abstract", "as", "async", "await", "break", "case", "catch", "class", "const",
            "continue", "declare", "default", "delete", "do", "else", "enum", "export", "extends",
            "false", "finally", "for", "from", "function", "get", "if", "implements", "import",
            "in", "instanceof", "interface", "keyof", "let", "namespace", "new", "null", "of",
            "private", "protected", "public", "readonly", "return", "satisfies", "set", "static",
            "super", "switch", "this", "throw", "true", "try", "type", "typeof", "undefined",
            "var", "void", "while", "yield",
        ],
        builtins: [
            "Array", "Boolean", "Date", "Error", "JSON", "Map", "Math", "Number", "Object",
            "Promise", "RegExp", "Set", "String", "Symbol", "any", "bigint", "boolean", "never",
            "number", "object", "string", "unknown", "console", "document", "window",
        ],
        capitalizedIsType: true,
        attributeSigils: ["@"],
        identifierExtras: ["_", "$"])

    static let python = SyntaxGrammar(
        lineComments: ["#"],
        quotes: [SyntaxGrammar.Quote("\"\"\"", multiline: true),
            SyntaxGrammar.Quote("'''", multiline: true), SyntaxGrammar.Quote("\""),
            SyntaxGrammar.Quote("'")],
        keywords: [
            "and", "as", "assert", "async", "await", "break", "class", "continue", "def", "del",
            "elif", "else", "except", "False", "finally", "for", "from", "global", "if", "import",
            "in", "is", "lambda", "match", "None", "nonlocal", "not", "or", "pass", "raise",
            "return", "True", "try", "while", "with", "yield",
        ],
        builtins: [
            "bool", "bytes", "dict", "float", "int", "list", "set", "str", "tuple", "type",
            "self", "cls", "print", "len", "range", "open", "super", "Exception",
        ],
        attributeSigils: ["@"])

    static let go = SyntaxGrammar(
        lineComments: ["//"],
        blocks: cBlocks,
        quotes: [SyntaxGrammar.Quote("`", escape: nil, multiline: true),
            SyntaxGrammar.Quote("\""), SyntaxGrammar.Quote("'")],
        keywords: [
            "break", "case", "chan", "const", "continue", "default", "defer", "else",
            "fallthrough", "for", "func", "go", "goto", "if", "import", "interface", "map",
            "package", "range", "return", "select", "struct", "switch", "type", "var",
        ],
        builtins: [
            "any", "bool", "byte", "complex64", "complex128", "error", "float32", "float64",
            "int", "int8", "int16", "int32", "int64", "rune", "string", "uint", "uint8", "uint16",
            "uint32", "uint64", "uintptr", "nil", "true", "false", "make", "new", "len", "cap",
            "append", "copy", "delete", "panic", "recover",
        ])

    static let c = SyntaxGrammar(
        lineComments: ["//"],
        blocks: cBlocks,
        quotes: cQuotes,
        keywords: [
            "auto", "break", "case", "const", "continue", "default", "do", "else", "enum",
            "extern", "for", "goto", "if", "inline", "register", "restrict", "return", "sizeof",
            "static", "struct", "switch", "typedef", "union", "volatile", "while", "_Atomic",
        ],
        builtins: [
            "bool", "char", "double", "float", "int", "long", "short", "signed", "size_t",
            "unsigned", "void", "NULL", "true", "false", "uint8_t", "uint32_t", "int32_t",
        ],
        attributeSigils: ["#"])

    static let cpp = SyntaxGrammar(
        lineComments: ["//"],
        blocks: cBlocks,
        quotes: cQuotes,
        keywords: c.keywords.union([
            "class", "namespace", "template", "typename", "public", "private", "protected",
            "virtual", "override", "final", "friend", "operator", "new", "delete", "this",
            "using", "try", "catch", "throw", "noexcept", "constexpr", "consteval", "concept",
            "requires", "co_await", "co_return", "co_yield", "mutable", "explicit",
            "interface", "implementation", "property", "synthesize", "end", "selector",
        ]),
        builtins: c.builtins.union([
            "std", "string", "vector", "map", "set", "nullptr", "auto", "id", "BOOL", "NSString",
            "NSArray", "NSDictionary", "YES", "NO",
        ]),
        capitalizedIsType: true,
        attributeSigils: ["#", "@"])

    static let java = SyntaxGrammar(
        lineComments: ["//"],
        blocks: cBlocks,
        quotes: [SyntaxGrammar.Quote("\"\"\"", multiline: true), SyntaxGrammar.Quote("\""),
            SyntaxGrammar.Quote("'")],
        keywords: [
            "abstract", "assert", "break", "case", "catch", "class", "const", "continue",
            "default", "do", "else", "enum", "extends", "final", "finally", "for", "if",
            "implements", "import", "instanceof", "interface", "native", "new", "package",
            "private", "protected", "public", "record", "return", "sealed", "static", "super",
            "switch", "synchronized", "this", "throw", "throws", "transient", "try", "var",
            "void", "volatile", "while", "yield", "def", "trait",
        ],
        builtins: [
            "boolean", "byte", "char", "double", "float", "int", "long", "short", "String",
            "Object", "List", "Map", "Set", "Integer", "Boolean", "Double", "null", "true",
            "false",
        ],
        capitalizedIsType: true,
        attributeSigils: ["@"])

    static let kotlin = SyntaxGrammar(
        lineComments: ["//"],
        blocks: [SyntaxGrammar.Block("/*", "*/", nests: true)],
        quotes: [
            SyntaxGrammar.Quote(
                "\"\"\"", multiline: true, interpolations: [.init("${", "}"), .init("$")]),
            SyntaxGrammar.Quote("\"", interpolations: [.init("${", "}"), .init("$")]),
            SyntaxGrammar.Quote("'"),
        ],
        keywords: [
            "abstract", "actual", "as", "break", "by", "catch", "class", "companion", "const",
            "constructor", "continue", "crossinline", "data", "delegate", "do", "else", "enum",
            "expect", "external", "false", "final", "finally", "for", "fun", "get", "if", "import",
            "in", "infix", "init", "inline", "inner", "interface", "internal", "is", "lateinit",
            "no", "null", "object", "open", "operator", "out", "override", "package", "private",
            "protected", "public", "reified", "return", "sealed", "set", "super", "suspend",
            "this", "throw", "true", "try", "typealias", "val", "var", "vararg", "when", "where",
            "while",
        ],
        builtins: [
            "Any", "Array", "Boolean", "Byte", "Char", "Double", "Float", "Int", "List", "Long",
            "Map", "Nothing", "Set", "Short", "String", "Unit",
        ],
        capitalizedIsType: true,
        attributeSigils: ["@"])

    static let csharp = SyntaxGrammar(
        lineComments: ["///", "//"],
        blocks: cBlocks,
        quotes: [SyntaxGrammar.Quote("@\"", "\"", escape: nil, multiline: true),
            SyntaxGrammar.Quote("$\"", "\"", interpolations: [.init("{", "}")]),
            SyntaxGrammar.Quote("\""),
            SyntaxGrammar.Quote("'")],
        keywords: [
            "abstract", "as", "async", "await", "base", "break", "case", "catch", "checked",
            "class", "const", "continue", "default", "delegate", "do", "else", "enum", "event",
            "explicit", "extern", "false", "finally", "fixed", "for", "foreach", "get", "goto",
            "if", "implicit", "in", "init", "interface", "internal", "is", "lock", "namespace",
            "new", "null", "operator", "out", "override", "params", "private", "protected",
            "public", "readonly", "record", "ref", "return", "sealed", "set", "sizeof",
            "stackalloc", "static", "struct", "switch", "this", "throw", "true", "try", "typeof",
            "unchecked", "unsafe", "using", "var", "virtual", "void", "volatile", "when", "where",
            "while", "yield",
        ],
        builtins: [
            "bool", "byte", "char", "decimal", "double", "dynamic", "float", "int", "long",
            "nint", "object", "sbyte", "short", "string", "uint", "ulong", "ushort", "Task",
            "List", "Dictionary",
        ],
        capitalizedIsType: true,
        attributeSigils: ["#"])

    static let ruby = SyntaxGrammar(
        lineComments: ["#"],
        blocks: [SyntaxGrammar.Block("=begin", "=end")],
        quotes: [
            SyntaxGrammar.Quote("\"", interpolations: [.init("#{", "}")]),
            SyntaxGrammar.Quote("'"), SyntaxGrammar.Quote("%w(", ")"),
        ],
        keywords: [
            "alias", "and", "begin", "break", "case", "class", "def", "defined?", "do", "else",
            "elsif", "end", "ensure", "false", "for", "if", "in", "module", "next", "nil", "not",
            "or", "redo", "rescue", "retry", "return", "self", "super", "then", "true", "undef",
            "unless", "until", "when", "while", "yield", "attr_accessor", "attr_reader",
            "attr_writer", "require", "require_relative", "include", "extend",
        ],
        builtins: ["Array", "Hash", "String", "Symbol", "Integer", "Float", "Proc", "Struct"],
        capitalizedIsType: true,
        identifierExtras: ["_", "?", "!"])

    static let shell = SyntaxGrammar(
        lineComments: ["#"],
        quotes: [
            SyntaxGrammar.Quote(
                "\"", multiline: true, interpolations: [.init("${", "}"), .init("$")]),
            SyntaxGrammar.Quote("'", escape: nil, multiline: true),
        ],
        keywords: [
            "case", "do", "done", "elif", "else", "esac", "fi", "for", "function", "if", "in",
            "return", "select", "then", "time", "until", "while", "export", "local", "readonly",
            "declare", "source", "alias", "unset", "shift", "trap", "set",
        ],
        builtins: [
            "echo", "cd", "ls", "cat", "grep", "sed", "awk", "curl", "git", "rm", "cp", "mv",
            "mkdir", "sudo", "chmod", "chown", "find", "xargs", "make", "docker", "kubectl",
            "npm", "cargo", "swift", "python", "python3", "pip", "brew", "apt", "pacman", "ssh",
            "rsync", "true", "false", "exit",
        ],
        callIsFunction: false,
        dollarVariables: true,
        identifierExtras: ["_", "-"])

    static let php = SyntaxGrammar(
        lineComments: ["//", "#"],
        blocks: cBlocks,
        quotes: [
            SyntaxGrammar.Quote("\"", interpolations: [.init("${", "}"), .init("$")]),
            SyntaxGrammar.Quote("'"),
        ],
        keywords: [
            "abstract", "and", "array", "as", "break", "callable", "case", "catch", "class",
            "clone", "const", "continue", "declare", "default", "do", "echo", "else", "elseif",
            "empty", "enddeclare", "endfor", "endforeach", "endif", "endswitch", "endwhile",
            "enum", "extends", "final", "finally", "fn", "for", "foreach", "function", "global",
            "goto", "if", "implements", "include", "instanceof", "insteadof", "interface", "isset",
            "list", "match", "namespace", "new", "or", "print", "private", "protected", "public",
            "readonly", "require", "return", "static", "switch", "throw", "trait", "try", "unset",
            "use", "var", "while", "xor", "yield", "true", "false", "null",
        ],
        capitalizedIsType: true,
        dollarVariables: true)

    static let lua = SyntaxGrammar(
        lineComments: ["--"],
        blocks: [SyntaxGrammar.Block("--[[", "]]")],
        quotes: [SyntaxGrammar.Quote("[[", "]]", escape: nil, multiline: true),
            SyntaxGrammar.Quote("\""), SyntaxGrammar.Quote("'")],
        keywords: [
            "and", "break", "do", "else", "elseif", "end", "false", "for", "function", "goto",
            "if", "in", "local", "nil", "not", "or", "repeat", "return", "then", "true", "until",
            "while",
        ],
        builtins: ["print", "pairs", "ipairs", "require", "table", "string", "math", "io", "os"])

    static let sql = SyntaxGrammar(
        lineComments: ["--"],
        blocks: cBlocks,
        quotes: [SyntaxGrammar.Quote("'", escape: nil), SyntaxGrammar.Quote("\"", escape: nil)],
        keywords: [
            "add", "all", "alter", "and", "as", "asc", "begin", "between", "by", "case", "cast",
            "column", "commit", "constraint", "create", "cross", "database", "default", "delete",
            "desc", "distinct", "drop", "else", "end", "exists", "foreign", "from", "full",
            "group", "having", "if", "in", "index", "inner", "insert", "into", "is", "join",
            "key", "left", "like", "limit", "not", "null", "offset", "on", "or", "order", "outer",
            "primary", "references", "returning", "right", "rollback", "select", "set", "table",
            "then", "transaction", "union", "unique", "update", "using", "values", "view", "when",
            "where", "with",
        ],
        builtins: [
            "bigint", "blob", "boolean", "char", "date", "datetime", "decimal", "double", "float",
            "int", "integer", "json", "numeric", "real", "serial", "smallint", "text", "time",
            "timestamp", "uuid", "varchar", "count", "sum", "avg", "min", "max", "coalesce",
        ],
        caseInsensitive: true)

    static let haskell = SyntaxGrammar(
        lineComments: ["--"],
        blocks: [SyntaxGrammar.Block("{-", "-}", nests: true)],
        quotes: cQuotes,
        keywords: [
            "case", "class", "data", "default", "deriving", "do", "else", "foreign", "if",
            "import", "in", "infix", "infixl", "infixr", "instance", "let", "module", "newtype",
            "of", "then", "type", "where",
        ],
        builtins: ["Bool", "Char", "Double", "Either", "Int", "Integer", "IO", "Maybe", "String"],
        capitalizedIsType: true,
        identifierExtras: ["_", "'"])

    static let elixir = SyntaxGrammar(
        lineComments: ["#"],
        quotes: [
            SyntaxGrammar.Quote("\"\"\"", multiline: true, interpolations: [.init("#{", "}")]),
            SyntaxGrammar.Quote("\"", interpolations: [.init("#{", "}")]),
            SyntaxGrammar.Quote("'"),
        ],
        keywords: [
            "after", "and", "case", "catch", "cond", "def", "defexception", "defimpl", "defmacro",
            "defmodule", "defp", "defprotocol", "defstruct", "do", "else", "end", "false", "fn",
            "for", "if", "import", "in", "nil", "not", "or", "quote", "raise", "receive",
            "require", "rescue", "true", "try", "unless", "unquote", "use", "when", "with",
        ],
        capitalizedIsType: true,
        attributeSigils: ["@"],
        identifierExtras: ["_", "?", "!"])

    static let zig = SyntaxGrammar(
        lineComments: ["///", "//"],
        quotes: [SyntaxGrammar.Quote("\""), SyntaxGrammar.Quote("'")],
        keywords: [
            "align", "allowzero", "and", "anyframe", "anytype", "asm", "async", "await", "break",
            "callconv", "catch", "comptime", "const", "continue", "defer", "else", "enum",
            "errdefer", "error", "export", "extern", "fn", "for", "if", "inline", "noalias",
            "nosuspend", "opaque", "or", "orelse", "packed", "pub", "resume", "return", "struct",
            "suspend", "switch", "test", "threadlocal", "try", "union", "unreachable", "usingnamespace",
            "var", "volatile", "while",
        ],
        builtins: [
            "bool", "f16", "f32", "f64", "i8", "i16", "i32", "i64", "isize", "u8", "u16", "u32",
            "u64", "usize", "void", "type", "null", "true", "false", "undefined", "anyerror",
        ],
        capitalizedIsType: true,
        attributeSigils: ["@"])

    static let dart = SyntaxGrammar(
        lineComments: ["///", "//"],
        blocks: cBlocks,
        quotes: [SyntaxGrammar.Quote("'''", multiline: true),
            SyntaxGrammar.Quote("\"\"\"", multiline: true), SyntaxGrammar.Quote("\""),
            SyntaxGrammar.Quote("'")],
        keywords: [
            "abstract", "as", "assert", "async", "await", "base", "break", "case", "catch",
            "class", "const", "continue", "covariant", "default", "deferred", "do", "dynamic",
            "else", "enum", "export", "extends", "extension", "external", "factory", "false",
            "final", "finally", "for", "get", "hide", "if", "implements", "import", "in",
            "interface", "is", "late", "library", "mixin", "new", "null", "on", "operator",
            "part", "required", "rethrow", "return", "sealed", "set", "show", "static", "super",
            "switch", "sync", "this", "throw", "true", "try", "typedef", "var", "void", "when",
            "while", "with", "yield",
        ],
        builtins: ["bool", "double", "int", "num", "String", "List", "Map", "Set", "Future", "Stream"],
        capitalizedIsType: true,
        attributeSigils: ["@"])

    static let scala = SyntaxGrammar(
        lineComments: ["//"],
        blocks: [SyntaxGrammar.Block("/*", "*/", nests: true)],
        quotes: [SyntaxGrammar.Quote("\"\"\"", multiline: true), SyntaxGrammar.Quote("\""),
            SyntaxGrammar.Quote("'")],
        keywords: [
            "abstract", "case", "catch", "class", "def", "do", "else", "enum", "extends", "false",
            "final", "finally", "for", "forSome", "given", "if", "implicit", "import", "lazy",
            "match", "new", "null", "object", "override", "package", "private", "protected",
            "return", "sealed", "super", "this", "throw", "trait", "true", "try", "type", "using",
            "val", "var", "while", "with", "yield",
        ],
        builtins: ["Any", "Boolean", "Double", "Int", "List", "Map", "Option", "Seq", "String", "Unit"],
        capitalizedIsType: true,
        attributeSigils: ["@"])

    static let perl = SyntaxGrammar(
        lineComments: ["#"],
        quotes: cQuotes,
        keywords: [
            "and", "cmp", "continue", "do", "else", "elsif", "eq", "exit", "for", "foreach",
            "if", "last", "local", "my", "ne", "next", "no", "not", "or", "our", "package",
            "redo", "require", "return", "sub", "unless", "until", "use", "wantarray", "while",
            "xor",
        ],
        dollarVariables: true)

    static let r = SyntaxGrammar(
        lineComments: ["#"],
        quotes: cQuotes,
        keywords: [
            "break", "else", "for", "function", "if", "in", "next", "repeat", "return", "while",
            "TRUE", "FALSE", "NULL", "NA", "Inf", "NaN", "library", "require",
        ],
        identifierExtras: ["_", "."])

    static let julia = SyntaxGrammar(
        lineComments: ["#"],
        blocks: [SyntaxGrammar.Block("#=", "=#", nests: true)],
        quotes: [SyntaxGrammar.Quote("\"\"\"", multiline: true), SyntaxGrammar.Quote("\""),
            SyntaxGrammar.Quote("'")],
        keywords: [
            "abstract", "baremodule", "begin", "break", "catch", "const", "continue", "do",
            "else", "elseif", "end", "export", "false", "finally", "for", "function", "global",
            "if", "import", "let", "local", "macro", "module", "mutable", "primitive", "quote",
            "return", "struct", "true", "try", "type", "using", "where", "while",
        ],
        builtins: ["Bool", "Float64", "Int", "Int64", "String", "Vector", "Matrix", "Dict", "Array"],
        capitalizedIsType: true,
        attributeSigils: ["@"],
        identifierExtras: ["_", "!"])

    static let nix = SyntaxGrammar(
        lineComments: ["#"],
        blocks: cBlocks,
        quotes: [SyntaxGrammar.Quote("''", multiline: true), SyntaxGrammar.Quote("\"")],
        keywords: [
            "assert", "else", "if", "in", "inherit", "let", "or", "rec", "then", "with",
            "true", "false", "null", "import",
        ],
        identifierExtras: ["_", "-", "'"])

    static let lisp = SyntaxGrammar(
        lineComments: [";"],
        quotes: [SyntaxGrammar.Quote("\"", multiline: true)],
        keywords: [
            "and", "case", "cond", "def", "defmacro", "defn", "defn-", "defonce", "defparameter",
            "defprotocol", "defrecord", "defstruct", "defun", "defvar", "do", "doseq", "dotimes",
            "fn", "for", "if", "lambda", "let", "let*", "letfn", "loop", "ns", "or", "quote",
            "recur", "require", "setq", "when", "while", "nil", "true", "false",
        ],
        callIsFunction: false,
        identifierExtras: ["_", "-", "*", "?", "!", "+", "/", ">", "<", "="])

    static let powershell = SyntaxGrammar(
        lineComments: ["#"],
        blocks: [SyntaxGrammar.Block("<#", "#>")],
        quotes: [SyntaxGrammar.Quote("\"", escape: "`"), SyntaxGrammar.Quote("'", escape: nil)],
        keywords: [
            "begin", "break", "catch", "class", "continue", "data", "do", "dynamicparam", "else",
            "elseif", "end", "enum", "exit", "filter", "finally", "for", "foreach", "function",
            "if", "in", "param", "process", "return", "switch", "throw", "trap", "try", "until",
            "using", "while",
        ],
        caseInsensitive: true,
        dollarVariables: true,
        identifierExtras: ["_", "-"])

    static let hcl = SyntaxGrammar(
        lineComments: ["#", "//"],
        blocks: cBlocks,
        quotes: [SyntaxGrammar.Quote("\"")],
        keywords: [
            "data", "for", "for_each", "if", "in", "locals", "module", "output", "provider",
            "resource", "terraform", "variable", "true", "false", "null", "depends_on", "count",
        ],
        builtins: ["bool", "list", "map", "number", "object", "set", "string", "tuple", "any"],
        identifierExtras: ["_", "-"])

    static let dockerfile = SyntaxGrammar(
        lineComments: ["#"],
        quotes: cQuotes,
        keywords: [
            "ADD", "ARG", "CMD", "COPY", "ENTRYPOINT", "ENV", "EXPOSE", "FROM", "HEALTHCHECK",
            "LABEL", "MAINTAINER", "ONBUILD", "RUN", "SHELL", "STOPSIGNAL", "USER", "VOLUME",
            "WORKDIR", "AS",
        ],
        caseInsensitive: false,
        callIsFunction: false,
        dollarVariables: true,
        identifierExtras: ["_", "-"])

    static let make = SyntaxGrammar(
        lineComments: ["#"],
        quotes: cQuotes,
        keywords: [
            "define", "else", "endef", "endif", "export", "ifdef", "ifeq", "ifndef", "ifneq",
            "include", "override", "unexport", "vpath", "add_executable", "add_library",
            "find_package", "if", "elseif", "foreach", "function", "endfunction",
            "macro", "endmacro", "set", "target_link_libraries", "project", "cmake_minimum_required",
        ],
        caseInsensitive: true,
        callIsFunction: false,
        dollarVariables: true,
        identifierExtras: ["_", "-", "."])

    static let vim = SyntaxGrammar(
        lineComments: ["\""],
        quotes: [SyntaxGrammar.Quote("'", escape: nil)],
        keywords: [
            "au", "augroup", "autocmd", "call", "command", "echo", "elseif", "else", "endfor",
            "endfunction", "endif", "endwhile", "exe", "execute", "for", "function", "if", "let",
            "map", "nnoremap", "noremap", "return", "set", "setlocal", "source", "vnoremap",
            "while", "inoremap",
        ],
        identifierExtras: ["_", "#", ":"])
}

/// A role's colour, taken from the palette the app is already wearing rather than from a stock
/// syntax theme. Every slot keeps the meaning it has everywhere else — `special` is the standing
/// mark, so it is what a keyword wears; `info` is identity, so it is what a name wears; `accent`
/// and `danger` are addition and subtraction, so a diff needs no colours of its own — which is why
/// seven themes and their fourteen faces all highlight code without a single hex being authored
/// twice, and why a theme that changes stays coherent inside a code block too.
///
/// Nothing here reaches for `accent` outside a diff: the stream cascade heats freshly written text
/// toward `accent`, and a keyword permanently wearing the colour of "this just arrived" would make
/// the wave unreadable.
public enum SyntaxPalette {
    /// The published colour for a role on this palette's code background, corrected the same way
    /// every other slot is: readable text clears 4.5:1, comments are deliberately quiet and clear
    /// 3:1, and a hue that cannot reach its bar falls back to the text register rather than
    /// shipping as something no one can read.
    public static func hex(_ role: SyntaxRole, in palette: Palette) -> String {
        hex(role, in: palette, on: palette.codeBg)
    }

    /// The ground an added or removed line sits on: the same accent and danger the diff's own
    /// +N/−N labels wear, washed most of the way into the code background rather than worn as
    /// ink. The line's identity survives as a field of colour, which frees the foreground for the
    /// language — a diff stays unmistakably a diff while the code on it reads as code.
    public static func diffLineBackground(_ kind: DiffLineKind, in palette: Palette) -> String? {
        switch kind {
        case .added: return Contrast.blend(palette.accent, palette.codeBg, 0.85)
        case .removed: return Contrast.blend(palette.danger, palette.codeBg, 0.85)
        case .context, .hunk, .meta, .note: return nil
        }
    }

    /// The same derivation against a different ground — a diff line's wash — so ink on a tinted
    /// line is corrected by the same arithmetic as ink on the plain block, rather than trusting
    /// that a colour readable on one canvas survives a canvas that moved toward it.
    public static func hex(_ role: SyntaxRole, in palette: Palette, on background: String) -> String {
        switch role {
        case .plain:
            return corrected(palette.text, on: background)
        case .keyword, .attribute:
            return corrected(palette.special, on: background)
        case .type, .function:
            return corrected(palette.info, on: background)
        case .string:
            return corrected(palette.warn, on: background)
        case .number:
            return corrected(palette.accentDim, on: background)
        case .comment:
            let quiet = Contrast.blend(palette.textDim, background, 0.3) ?? palette.textDim
            return Contrast.adjusted(quiet, on: background, ratio: Contrast.secondary)
                ?? palette.textDim
        case .added:
            return corrected(palette.accent, on: background)
        case .removed:
            return corrected(palette.danger, on: background)
        }
    }

    /// Every role's colour for one palette, for a client that builds its colour table once per
    /// theme rather than per token.
    public static func table(for palette: Palette) -> [SyntaxRole: String] {
        table(for: palette, on: palette.codeBg)
    }

    /// The same table against a chosen ground, for a client colouring the code on a diff's added
    /// or removed wash.
    public static func table(for palette: Palette, on background: String) -> [SyntaxRole: String] {
        var table: [SyntaxRole: String] = [:]
        for role in SyntaxRole.allCases { table[role] = hex(role, in: palette, on: background) }
        return table
    }

    private static func corrected(_ hex: String, on background: String) -> String {
        Contrast.adjusted(hex, on: background, ratio: Contrast.readable) ?? hex
    }
}
