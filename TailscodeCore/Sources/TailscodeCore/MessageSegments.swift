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

    public static func split(_ text: String) -> [MessageSegment] {
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
            if let scanned = MarkdownTable.scan(lines, from: index) {
                flushProse()
                segments.append(.table(scanned.table))
                index = scanned.end
                continue
            }
            appendProse(line)
            index += 1
        }
        if inFence {
            segments.append(.code(language: language, body: code.joined(separator: "\n")))
        } else {
            flushProse()
        }
        return segments
    }
}
