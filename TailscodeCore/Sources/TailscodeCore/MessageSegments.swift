import Foundation

/// A text part split on fenced code, so prose renders as prose and code renders as a block with
/// its language and a copy that is byte-exact — a fence pasted back must round-trip.
public enum MessageSegment: Hashable, Sendable {
    case prose(String)
    case code(language: String?, body: String)

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

        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
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
                continue
            }
            if inFence {
                code.append(String(line))
            } else {
                prose.append(String(line))
            }
        }
        if inFence {
            segments.append(.code(language: language, body: code.joined(separator: "\n")))
        } else {
            flushProse()
        }
        return segments
    }
}
