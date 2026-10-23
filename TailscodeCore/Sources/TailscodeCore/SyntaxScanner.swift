import Foundation

struct SyntaxScanner {
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
