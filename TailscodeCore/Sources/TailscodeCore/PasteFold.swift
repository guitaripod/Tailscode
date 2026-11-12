import Foundation

/// A paste too long to sit in a prompt box as words, kept beside the box as one block that opens
/// to be read. It is still words: it rides out inside the message rather than as a file, so every
/// model that reads text reads it, and a model that takes no files loses nothing.
public struct FoldedPaste: Sendable, Hashable, Identifiable {
    public let id: String
    public let text: String
    public let lines: Int
    public let glimpse: String

    public init(text: String, id: String = UUID().uuidString) {
        self.id = id
        self.text = text
        lines = PasteFold.lineCount(text)
        glimpse = PasteFold.glimpse(text)
    }

    /// How long it is: its lines, or its characters when it is one long line.
    public var size: String {
        lines > 1
            ? Localized.text("%d lines", lines)
            : Localized.text("%d characters", text.count)
    }

    /// What a chip and a transcript line call it.
    public var label: String { Localized.text("Pasted · %@", size) }

    /// What the reader says under its title.
    public var summary: String { size + " · " + AttachmentIntake.sizeText(text.utf8.count) }

    public var spoken: String { Localized.text("Pasted text, %@", size) }

    public static var title: String { Localized.text("Pasted text") }
}

/// A message's text read for its folded pastes: the person's words and each block, in the order
/// they were written.
public struct PasteReading: Sendable, Hashable {
    public enum Piece: Sendable, Hashable {
        case words(String)
        case paste(FoldedPaste)
    }

    public let pieces: [Piece]

    public init(pieces: [Piece]) {
        self.pieces = pieces
    }

    public var pastes: [FoldedPaste] {
        pieces.compactMap {
            if case .paste(let paste) = $0 { return paste }
            return nil
        }
    }

    /// Only what the person typed, the blocks taken out.
    public var words: String {
        pieces.compactMap {
            if case .words(let words) = $0 { return words }
            return nil
        }.joined(separator: "\n\n")
    }

    public var isFolded: Bool { pieces.contains { if case .paste = $0 { true } else { false } } }

    /// The message as the person would copy it: the words and every paste in place, no tags.
    public var plain: String {
        pieces.map {
            switch $0 {
            case .words(let words): return words
            case .paste(let paste): return paste.text
            }
        }.joined(separator: "\n\n")
    }

    /// The message for a surface with no room for a block: the words, and each paste by its
    /// label.
    public var glance: String {
        pieces.map {
            switch $0 {
            case .words(let words): return words
            case .paste(let paste): return "[" + paste.label + "]"
            }
        }.joined(separator: " ")
    }
}

/// How a long paste rides in a message, and how a client folds it back.
///
/// The person's words come first and each block after, because everything that names a chat from
/// its first message reads the first line, and that line is the person's. The block is the paste
/// itself between two tag lines, so the model reads it as a delimited document and every installed
/// app can fold it. The tag is added to and never renamed.
public enum PasteFold {
    public static let tag = "pasted-text"
    static let opening = "<" + tag
    static let closing = "</" + tag + ">"

    /// Past either of these a paste has stopped being something a person reads in a prompt box: a
    /// sentence, a short stack trace or a few lines of code still land as words they can edit.
    public static let lineLimit = 10
    public static let characterLimit = 1_000

    public static func folds(_ text: String) -> Bool {
        lineCount(text) > lineLimit || text.count > characterLimit
    }

    /// The text a message is sent as: the words, then each paste as its block. A tag the person
    /// typed is escaped like one inside a paste, so only a block this wrote is ever read as one.
    public static func wrap(_ words: String, pastes: [FoldedPaste]) -> String {
        guard !pastes.isEmpty else { return escape(words) }
        let typed = escape(words.trimmingCharacters(in: .whitespacesAndNewlines))
        let blocks = pastes.map(block).joined(separator: "\n\n")
        return typed.isEmpty ? blocks : typed + "\n\n" + blocks
    }

    /// What a prompt box is kept as between visits: exactly the keystrokes that were in it, then
    /// the blocks, so `undraft` hands back the same box.
    public static func draft(_ raw: String, pastes: [FoldedPaste]) -> String {
        guard !pastes.isEmpty else { return escape(raw) }
        let blocks = pastes.map(block).joined(separator: "\n\n")
        return raw.isEmpty ? blocks : escape(raw) + "\n\n" + blocks
    }

    /// The words and every paste as plain text with no tags, for a box that takes the whole of it
    /// as one argument: a command's, a goal's, a studio brief's.
    public static func inline(_ words: String, pastes: [FoldedPaste]) -> String {
        let typed = words.trimmingCharacters(in: .whitespacesAndNewlines)
        return ([typed] + pastes.map(\.text)).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// A kept or sent text taken apart for a prompt box: the words go back in the box and each
    /// block becomes a paste beside it again.
    public static func undraft(_ text: String) -> (words: String, pastes: [FoldedPaste]) {
        let found = blocks(in: text)
        guard let first = found.first else { return (unescape(text), []) }
        var words = [unescape(droppingSeparator(String(text[..<first.range.lowerBound])))]
        for (index, current) in found.enumerated() {
            let end = index + 1 < found.count ? found[index + 1].range.lowerBound : text.endIndex
            let between = text[current.range.upperBound..<end]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !between.isEmpty { words.append(unescape(between)) }
        }
        let typed = words.filter { !$0.isEmpty }.joined(separator: "\n\n")
        return (typed, found.map { FoldedPaste(text: $0.body) })
    }

    /// The words before the first block without the blank line `draft` put between them, taken
    /// off as scalars: keystrokes ending in a carriage return fuse with that line into one
    /// character, and a character count would take the return with it.
    private static func droppingSeparator(_ lead: String) -> String {
        var scalars = Array(lead.unicodeScalars)
        guard scalars.count >= 2, scalars[scalars.count - 1] == "\n",
            scalars[scalars.count - 2] == "\n"
        else { return lead }
        scalars.removeLast(2)
        var kept = String.UnicodeScalarView()
        kept.append(contentsOf: scalars)
        return String(kept)
    }

    /// A message's text read into the person's words and its folded blocks. `id` names the blocks
    /// so a transcript row keeps its identity across rebuilds.
    public static func split(_ text: String, id: String = "paste") -> PasteReading {
        let found = blocks(in: text)
        guard !found.isEmpty else { return PasteReading(pieces: [.words(unescape(text))]) }
        var pieces: [PasteReading.Piece] = []
        var cursor = text.startIndex
        for (index, current) in found.enumerated() {
            let before = text[cursor..<current.range.lowerBound]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !before.isEmpty { pieces.append(.words(unescape(before))) }
            pieces.append(.paste(FoldedPaste(text: current.body, id: "\(id):\(index)")))
            cursor = current.range.upperBound
        }
        let after = text[cursor...].trimmingCharacters(in: .whitespacesAndNewlines)
        if !after.isEmpty { pieces.append(.words(unescape(after))) }
        return PasteReading(pieces: pieces)
    }

    /// Whether a text names the tag at all — a block, or a tag escaped inside words — cheap
    /// enough to ask of every message before reading it properly.
    public static func mayHold(_ text: String) -> Bool {
        text.utf8.count >= tag.utf8.count && text.contains(tag)
    }

    /// The message as the person would copy it, the tags taken off.
    public static func plain(_ text: String) -> String {
        mayHold(text) ? split(text).plain : text
    }

    /// The message with each paste by its label, for a surface with no room for a block.
    public static func glance(_ text: String) -> String {
        mayHold(text) ? split(text).glance : text
    }

    static func block(_ paste: FoldedPaste) -> String {
        opening + ">\n" + escape(paste.text) + "\n" + closing
    }

    struct Found {
        let range: Range<String.Index>
        let body: String
    }

    /// Every block in a text, in order. An opening tag counts only on a line of its own and a
    /// closing one only on a line of its own, so a sentence that merely mentions the tag stays
    /// words, and a block with no end is words too. Line ends are read as scalars: a paste that
    /// ends in a carriage return would otherwise fuse with the newline after it into one character.
    static func blocks(in text: String) -> [Found] {
        guard mayHold(text) else { return [] }
        let scalars = text.unicodeScalars
        var found: [Found] = []
        var search = text.startIndex
        while let open = text.range(of: opening, range: search..<text.endIndex) {
            search = open.upperBound
            guard startsLine(open.lowerBound, in: text),
                let tagEnd = scalars[open.upperBound...].firstIndex(where: {
                    $0 == ">" || $0 == "\n"
                }),
                scalars[tagEnd] == ">",
                open.upperBound == tagEnd || scalars[open.upperBound] == " "
            else { continue }
            let newline = scalars.index(after: tagEnd)
            guard newline < scalars.endIndex, scalars[newline] == "\n" else { continue }
            let contentStart = scalars.index(after: newline)
            guard let close = closingLine(in: text, from: newline) else { continue }
            let contentEnd = scalars.index(before: close.lowerBound)
            let content =
                contentEnd > contentStart
                ? String(String.UnicodeScalarView(scalars[contentStart..<contentEnd])) : ""
            found.append(Found(range: open.lowerBound..<close.upperBound, body: unescape(content)))
            search = close.upperBound
        }
        return found
    }

    /// The closing tag that ends a block whose opening line ends at `newline`: the first one
    /// alone on its own line.
    private static func closingLine(
        in text: String, from newline: String.Index
    ) -> Range<String.Index>? {
        var search = text.unicodeScalars.index(after: newline)
        while search <= text.endIndex,
            let close = text.range(of: closing, range: search..<text.endIndex)
        {
            search = close.upperBound
            if startsLine(close.lowerBound, in: text), endsLine(close.upperBound, in: text) {
                return close
            }
        }
        return nil
    }

    private static func startsLine(_ index: String.Index, in text: String) -> Bool {
        guard index > text.startIndex else { return true }
        return text.unicodeScalars[text.unicodeScalars.index(before: index)] == "\n"
    }

    private static func endsLine(_ index: String.Index, in text: String) -> Bool {
        guard index < text.endIndex else { return true }
        let next = text.unicodeScalars[index]
        return next == "\n" || next == "\r"
    }

    private static let escapable = try? NSRegularExpression(pattern: "<(\\\\*)(/?)" + tag)
    private static let escaped = try? NSRegularExpression(pattern: "<\\\\(\\\\*)(/?)" + tag)

    /// A tag inside a paste or typed among the words gains one backslash after its angle
    /// bracket, and one that already had backslashes gains one more, so only a block this wrote
    /// reads as one and taking one off hands back exactly what was there.
    static func escape(_ body: String) -> String {
        guard body.contains(tag), let escapable else { return body }
        let range = NSRange(body.startIndex..., in: body)
        return escapable.stringByReplacingMatches(
            in: body, range: range, withTemplate: "<\\\\$1$2" + tag)
    }

    static func unescape(_ body: String) -> String {
        guard body.contains(tag), let escaped else { return body }
        let range = NSRange(body.startIndex..., in: body)
        return escaped.stringByReplacingMatches(in: body, range: range, withTemplate: "<$1$2" + tag)
    }

    /// Lines however they end — a newline, a carriage return and newline, or a lone carriage
    /// return — with a break at the very end not starting another.
    static func lineCount(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        var lines = 1
        var afterReturn = false
        for byte in text.utf8 {
            if byte == 0x0A {
                if !afterReturn { lines += 1 }
                afterReturn = false
            } else if byte == 0x0D {
                lines += 1
                afterReturn = true
            } else {
                afterReturn = false
            }
        }
        if let last = text.utf8.last, last == 0x0A || last == 0x0D { lines -= 1 }
        return lines
    }

    static let glimpseLength = 80

    /// The first line that says anything, trimmed, cut where a single line of a chip ends.
    static func glimpse(_ text: String) -> String {
        var line = ""
        for candidate in text.split(omittingEmptySubsequences: true, whereSeparator: \.isNewline) {
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                line = trimmed
                break
            }
        }
        guard line.count > glimpseLength else { return line }
        return String(line.prefix(glimpseLength)).trimmingCharacters(in: .whitespaces) + "…"
    }
}
