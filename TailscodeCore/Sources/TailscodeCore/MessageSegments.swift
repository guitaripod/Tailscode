import Foundation

/// A text part split on its block structure, so prose renders as prose, code renders as a block
/// with its language and a copy that is byte-exact — a fence pasted back must round-trip — and a
/// pipe table renders as columns instead of punctuation. Prose never carries more than one blank
/// line in a row: extra emptiness is the model exhaling, not paragraph structure, and a
/// transcript is read by the screenful.
public enum MessageSegment: Hashable, Sendable {
    case prose(String)
    case code(language: String?, body: String)
    case table(MarkdownTable)

    /// - Parameter sealed: whether the text is finished. While an answer is still arriving its last
    ///   line is half-written, and a table read from it draws a row with a cell cut in half and
    ///   rewrites it a moment later — the columns jump, the rows shuffle, and the reader is trying
    ///   to read the rows already there. So while unsealed a trailing pipe row is simply not
    ///   offered yet: it lands whole on the next arrival, which is a table growing a row at a time
    ///   rather than a table rearranging itself under the writing.
    public static func split(_ text: String, sealed: Bool = true) -> [MessageSegment] {
        var segments: [MessageSegment] = []
        var prose: [String] = []
        var code: [String] = []
        var language: String?
        var inFence = false

        func flushProse() {
            let joined = prose.joined(separator: "\n").trimmingCharacters(
                in: .whitespacesAndNewlines)
            if !joined.isEmpty { segments.append(.prose(joined)) }
            prose = []
        }

        func appendProse(_ line: String) {
            let blank = line.trimmingCharacters(in: .whitespaces).isEmpty
            if blank, prose.last?.trimmingCharacters(in: .whitespaces).isEmpty != false {
                return
            }
            prose.append(line)
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        // The last line with anything on it: a text that ends in a newline has an empty line after
        // its final row, and the row is still the last thing the model has written.
        let lastWritten = lines.lastIndex { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? -1
        // Where a table may read to. A line the model is still typing is not a row: drawn, it puts
        // a cell cut in half on the page and rewrites it a moment later. This is only ever about
        // tables — a fence carries its own lines through untouched, because a shell pipeline is
        // full of pipes and a code block that lagged a line behind the writing would be worse than
        // anything it fixed.
        let readable = !sealed && !text.hasSuffix("\n") ? lastWritten : lines.count
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if inFence {
                    segments.append(.code(language: language, body: code.joined(separator: "\n")))
                    code = []
                    inFence = false
                } else {
                    flushProse()
                    let tag = trimmed.dropFirst(3).trimmingCharacters(in: .whitespaces)
                    language = tag.isEmpty ? nil : tag
                    inFence = true
                }
                index += 1
                continue
            }
            if inFence {
                code.append(line)
                index += 1
                continue
            }
            if let scanned = MarkdownTable.scan(lines, from: index, limit: readable) {
                flushProse()
                segments.append(.table(scanned.table))
                index = scanned.end
                continue
            }
            // A header whose delimiter row has not arrived yet is a table nobody can see yet, and
            // drawing it as prose puts a line of raw pipes on the page for one arrival and then
            // takes it away again.
            if !sealed, index == lastWritten, MarkdownTable.columns(line) != nil {
                index += 1
                continue
            }
            appendProse(line)
            index += 1
        }
        if inFence {
            flushOpenFence(&segments, language: language, code: code)
        } else {
            flushProse()
        }
        return segments
    }

    /// The block a fence has opened but not yet filled is not a segment.
    ///
    /// A fence line arrives before the code it announces does, so for the arrival where the model
    /// has written "```" and nothing after it there is a block whose body is empty — and an empty
    /// block is a row: an empty card under the paragraph, and the last row of the transcript, which
    /// is the one the wave takes up and tries to write. A moment later the first line lands and the
    /// same row has to be measured again. Nothing is lost by waiting: the block appears with its
    /// first characters, at the index it will keep for the rest of the answer.
    private static func flushOpenFence(
        _ segments: inout [MessageSegment], language: String?, code: [String]
    ) {
        let body = code.joined(separator: "\n")
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        segments.append(.code(language: language, body: body))
    }
}
