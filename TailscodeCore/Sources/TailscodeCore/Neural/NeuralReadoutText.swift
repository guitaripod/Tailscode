import Foundation

/// Reading a tool's output without copying it. An output can be megabytes, a transcript is
/// rebuilt for every token, and a readout asks for the first eight lines, the last eight and the
/// count, so every function here walks the UTF-8 bytes from the end it needs and builds a string
/// only for each line it returns.
enum NeuralReadoutText {
    private static let newline: UInt8 = 10
    private static let carriageReturn: UInt8 = 13
    private static let space: UInt8 = 32
    private static let tab: UInt8 = 9

    /// The longest a line is kept; a longer one is cut and the full text stays in the call.
    static let lineLimit = 400

    private static func isBlank(_ byte: UInt8) -> Bool {
        byte == newline || byte == carriageReturn || byte == space || byte == tab
    }

    /// How many lines the text has, not counting the blank ones at its end.
    static func lineCount(_ text: String) -> Int {
        let counted: Int? = text.utf8.withContiguousStorageIfAvailable { buffer in
            var end = buffer.count
            while end > 0, isBlank(buffer[end - 1]) { end -= 1 }
            guard end > 0 else { return 0 }
            var count = 1
            for index in 0..<end where buffer[index] == newline { count += 1 }
            return count
        }
        if let counted { return counted }
        let bytes = Array(text.utf8)
        var end = bytes.count
        while end > 0, isBlank(bytes[end - 1]) { end -= 1 }
        guard end > 0 else { return 0 }
        return 1 + bytes[0..<end].reduce(0) { $0 + ($1 == newline ? 1 : 0) }
    }

    /// How many lines the text has when a final newline closes the last one and an empty text has
    /// none: what a diff of the string would count.
    static func rawLineCount(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        let newlines: Int =
            text.utf8.withContiguousStorageIfAvailable { buffer in
                var count = 0
                for byte in buffer where byte == newline { count += 1 }
                return count
            } ?? text.utf8.reduce(0) { $0 + ($1 == newline ? 1 : 0) }
        return text.utf8.last == newline ? newlines : newlines + 1
    }

    /// The first `count` lines. Leading blank lines are skipped unless `keepBlank`, and each line
    /// loses what trails it (all blank space, or only the carriage return when `keepBlank`).
    static func firstLines(_ text: String, _ count: Int, keepBlank: Bool = false) -> [String] {
        guard count > 0 else { return [] }
        let utf8 = text.utf8
        var out: [String] = []
        var start = utf8.startIndex
        let end = utf8.endIndex
        while start < end, out.count < count {
            let found = utf8[start...].firstIndex(of: newline)
            let next = found.map { utf8.index(after: $0) } ?? end
            let lineEnd = found ?? end
            let line = trimmed(utf8, from: start, to: lineEnd, keepBlank: keepBlank)
            start = next
            if line.isEmpty && !keepBlank && out.isEmpty { continue }
            out.append(line)
        }
        if !keepBlank { while out.last?.isEmpty == true { out.removeLast() } }
        return out
    }

    /// The last `count` lines, oldest first, ignoring blank space at the end.
    static func lastLines(_ text: String, _ count: Int) -> [String] {
        guard count > 0 else { return [] }
        let utf8 = text.utf8
        var end = utf8.endIndex
        while end > utf8.startIndex, isBlank(utf8[utf8.index(before: end)]) {
            end = utf8.index(before: end)
        }
        var out: [String] = []
        while end > utf8.startIndex, out.count < count {
            var start = end
            while start > utf8.startIndex, utf8[utf8.index(before: start)] != newline {
                start = utf8.index(before: start)
            }
            out.append(trimmed(utf8, from: start, to: end, keepBlank: false))
            end = start > utf8.startIndex ? utf8.index(before: start) : start
        }
        return out.reversed()
    }

    private static func trimmed(
        _ utf8: String.UTF8View, from start: String.Index, to end: String.Index, keepBlank: Bool
    ) -> String {
        var stop = end
        while stop > start {
            let byte = utf8[utf8.index(before: stop)]
            let drop = keepBlank ? byte == carriageReturn : isBlank(byte)
            guard drop else { break }
            stop = utf8.index(before: stop)
        }
        var line = String(decoding: utf8[start..<stop], as: UTF8.self)
        if line.count > lineLimit { line = String(line.prefix(lineLimit)) }
        return line
    }

    /// The first line that is not blank, whole.
    static func firstLine(_ text: String) -> String {
        firstLines(text, 1).first ?? ""
    }

    /// The text on one line: runs of blank space become one space, and it stops at `limit`.
    static func oneLine(_ text: String, limit: Int) -> String {
        var out = ""
        var pendingSpace = false
        var count = 0
        for character in text {
            if character.isWhitespace {
                pendingSpace = !out.isEmpty
                continue
            }
            if pendingSpace {
                out.append(" ")
                count += 1
                pendingSpace = false
            }
            out.append(character)
            count += 1
            if count >= limit { break }
        }
        return out
    }

    /// The text cut at a word boundary to at most `limit` characters, with an ellipsis where it
    /// was cut. The second value says whether anything was left out.
    static func capped(_ text: String, limit: Int) -> (text: String, isCut: Bool) {
        guard let cut = text.index(text.startIndex, offsetBy: limit, limitedBy: text.endIndex),
            cut < text.endIndex
        else { return (text.trimmingCharacters(in: .whitespacesAndNewlines), false) }
        var head = text[..<cut]
        if !text[cut].isWhitespace, let space = head.lastIndex(where: \.isWhitespace) {
            head = head[..<space]
        }
        var out = String(head).trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = out.last, ",;:\u{2014}-".contains(last) { out.removeLast() }
        return (out + "\u{2026}", true)
    }

    /// Whether a line is the one that says what went wrong.
    static func isErrorLine(_ line: String) -> Bool {
        line.contains("FAILED") || line.range(of: "error:", options: .caseInsensitive) != nil
            || line.range(of: "fatal", options: .caseInsensitive) != nil
    }

    /// A path split into the directory (with its trailing slash) and the file name.
    static func split(path: String) -> (directory: String, file: String) {
        guard let slash = path.lastIndex(of: "/") else { return ("", path) }
        let next = path.index(after: slash)
        return (String(path[..<next]), String(path[next...]))
    }

    /// A directory (with its trailing slash) shortened to its last directory after an ellipsis:
    /// "TailscodeLinux/Sources/Chat/" becomes "\u{2026}/Chat/". A directory of one level, or none,
    /// is left whole.
    static func shortDirectory(_ directory: String) -> String {
        let parts = directory.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count > 1, let last = parts.last else { return directory }
        return "\u{2026}/\(last)/"
    }
}
