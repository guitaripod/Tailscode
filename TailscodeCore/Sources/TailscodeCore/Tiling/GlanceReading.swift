import CodingAgentKit
import Foundation

/// What a glance tile says about a conversation, read from its tail and never from the whole of it.
///
/// A glance is refreshed at the shed level's rate for every peer pane, so anything it costs is paid
/// per pane per tick. Everything here reads at most the last three messages plus the turn in
/// flight; spend and an estimated context fill are left out on purpose because both walk the
/// whole transcript.
public struct GlanceReading: Sendable, Equatable {
    /// The longest tail a reading keeps, which is also what `tail` is cut to.
    public static let tailLimit = 600
    /// How far back the turn's start and its model are looked for before the reading stops asking.
    static let turnScanLimit = 64
    /// How much of the newest message's text is read; a tile never shows more than a few lines.
    static let sourceLimit = 4000

    public let activity: ActivityKind?
    public let session: SessionPresence
    /// The newest words as plain text: inline marks stripped, a code block as one `⟨code⟩` line,
    /// the last `tailLimit` characters cut at a word.
    public let tail: String
    /// The awaiting question, or the pending permission's one-line summary.
    public let question: String?
    public let model: String?
    /// The level the answer was asked for in, in the model's own spelling. `ModelEffort` is a
    /// namespace of rules rather than a value, so the level travels as the word on the wire.
    public let effort: String?
    public let turnStartedAt: Date?
    public let queued: Int
    public let background: BackgroundWork?
    private let plain: String

    public init(
        activity: ActivityKind?, session: SessionPresence, plain: String, question: String?,
        model: String?, effort: String?, turnStartedAt: Date?, queued: Int,
        background: BackgroundWork?
    ) {
        self.activity = activity
        self.session = session
        self.plain = plain
        self.tail = Self.cut(plain, to: Self.tailLimit)
        self.question = question
        self.model = model
        self.effort = effort
        self.turnStartedAt = turnStartedAt
        self.queued = queued
        self.background = background
    }

    /// Reads a conversation state. `queued` is what this device is holding for it; `step` is the
    /// tool the turn is on when the caller already knows it.
    public init(state: ConversationState, queued: Int = 0, step: String? = nil) {
        let messages = state.messages
        let recent = messages.suffix(3)
        let turn = Self.turnFacts(messages, running: state.status == .running)
        self.init(
            activity: ActivityKind.inFlight(in: state),
            session: SessionPresence.reading(state, step: step),
            plain: Self.plainTail(of: recent),
            question: Self.question(state, recent: recent),
            model: turn.model,
            effort: turn.effort,
            turnStartedAt: turn.startedAt,
            queued: queued,
            background: state.backgroundWork)
    }

    /// The tail cut to what a tile of a given size can show: `columns × lines` characters.
    public func tail(maxChars: Int) -> String {
        Self.cut(plain, to: min(maxChars, Self.tailLimit))
    }

    private static func question(
        _ state: ConversationState, recent: ArraySlice<ChatMessage>
    ) -> String? {
        let asked =
            state.pendingQuestions.first
            ?? QuestionRequest.awaitingAnswer(in: Array(recent), sessionID: "").first
        if let text = asked?.questions.first?.question, !text.isEmpty { return text }
        if let permission = state.pendingPermissions.first {
            let summary = permission.title ?? permission.toolName
            if let summary, !summary.isEmpty { return Self.firstLine(summary) }
            return Localized.text("Permission needed")
        }
        return nil
    }

    private struct TurnFacts {
        var startedAt: Date?
        var model: String?
        var effort: String?
    }

    /// The running turn's start and the model answering, found within `turnScanLimit` messages of
    /// the end. A turn longer than that has no start this reading can afford to find.
    private static func turnFacts(_ messages: [ChatMessage], running: Bool) -> TurnFacts {
        var facts = TurnFacts()
        var foundStart = !running
        var index = messages.endIndex
        let floor = max(messages.startIndex, messages.endIndex - turnScanLimit)
        while index > floor {
            index -= 1
            let message = messages[index]
            if facts.model == nil, message.role == .assistant, let model = message.modelID {
                facts.model = model
                facts.effort = message.reasoningEffort
            }
            if !foundStart, message.role == .user {
                facts.startedAt = message.createdAt
                foundStart = true
            }
            if foundStart, facts.model != nil { break }
        }
        return facts
    }

    /// The text of the newest message among the recent ones that says anything.
    private static func plainTail(of recent: ArraySlice<ChatMessage>) -> String {
        for message in recent.reversed() {
            let text = message.parts.compactMap { part -> String? in
                if case .text(let value) = part.kind, !value.isEmpty { return value }
                return nil
            }.joined(separator: "\n")
            if !text.isEmpty { return plain(text) }
        }
        return ""
    }

    /// Markdown read down to the words a person would say aloud, from the last `sourceLimit`
    /// characters only. Whether the window opens inside a code block is settled by counting the
    /// fences before it, which is a byte scan rather than a parse.
    static func plain(_ text: String) -> String {
        var window = Substring(text)
        var insideFence = false
        if text.utf8.count > sourceLimit {
            let start = text.index(text.endIndex, offsetBy: -sourceLimit, limitedBy: text.startIndex)
                ?? text.startIndex
            let lineStart = text[start...].firstIndex(of: "\n").map { text.index(after: $0) } ?? start
            insideFence = fenceCount(text[..<lineStart]) % 2 == 1
            window = text[lineStart...]
        }
        var lines: [String] = []
        var codeShown = false
        if insideFence {
            lines.append("⟨code⟩")
            codeShown = true
        }
        for raw in window.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                insideFence.toggle()
                if insideFence {
                    lines.append("⟨code⟩")
                    codeShown = true
                } else {
                    codeShown = false
                }
                continue
            }
            if insideFence {
                if !codeShown {
                    lines.append("⟨code⟩")
                    codeShown = true
                }
                continue
            }
            let line = inline(block(trimmed))
            if line.isEmpty {
                if let last = lines.last, !last.isEmpty { lines.append("") }
                continue
            }
            lines.append(line)
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        while lines.first?.isEmpty == true { lines.removeFirst() }
        return lines.joined(separator: "\n")
    }

    /// Fence lines in `text`, counted over its bytes: a line whose first non-blank characters are
    /// three backticks or three tildes.
    private static func fenceCount(_ text: Substring) -> Int {
        var count = 0
        var atLineStart = true
        var run: UInt8 = 0
        var runLength = 0
        for byte in text.utf8 {
            if byte == 0x0A {
                atLineStart = true
                runLength = 0
                continue
            }
            guard atLineStart else { continue }
            if runLength == 0, byte == 0x20 || byte == 0x09 { continue }
            if byte == 0x60 || byte == 0x7E, runLength == 0 || byte == run {
                run = byte
                runLength += 1
                if runLength == 3 {
                    count += 1
                    atLineStart = false
                }
                continue
            }
            atLineStart = false
        }
        return count
    }

    /// Block marks at the start of a line: headings, quotes, bullets, numbered items keep their
    /// words and lose their syntax; a horizontal rule and a table divider say nothing.
    private static func block(_ line: String) -> String {
        var line = Substring(line)
        if line.allSatisfy({ "-*_= ".contains($0) }), line.count >= 3 { return "" }
        if line.hasPrefix("|"), line.allSatisfy({ "|-: ".contains($0) }) { return "" }
        while line.hasPrefix(">") { line = line.dropFirst().drop { $0 == " " } }
        if line.hasPrefix("#") {
            let hashes = line.prefix { $0 == "#" }
            if hashes.count <= 6, line.dropFirst(hashes.count).first == " " {
                line = line.dropFirst(hashes.count + 1)
            }
        }
        for bullet in ["- [ ] ", "- [x] ", "* [ ] ", "* [x] ", "- ", "* ", "+ "]
        where line.hasPrefix(bullet) {
            return "• " + line.dropFirst(bullet.count)
        }
        return String(line)
    }

    /// Inline marks: emphasis, strike, code spans, links and images keep their words.
    private static func inline(_ line: String) -> String {
        guard line.contains(where: { "*_`~[!<".contains($0) }) else { return line }
        var out = ""
        out.reserveCapacity(line.count)
        let chars = Array(line)
        var index = 0
        while index < chars.count {
            let char = chars[index]
            switch char {
            case "*", "`":
                index += 1
                continue
            case "~" where index + 1 < chars.count && chars[index + 1] == "~":
                index += 2
                continue
            case "_":
                let before = index > 0 ? chars[index - 1] : " "
                let after = index + 1 < chars.count ? chars[index + 1] : " "
                if before.isLetter || before.isNumber, after.isLetter || after.isNumber {
                    out.append(char)
                }
                index += 1
                continue
            case "!" where index + 1 < chars.count && chars[index + 1] == "[":
                index += 1
                continue
            case "[":
                if let close = chars[index...].firstIndex(of: "]"),
                    close + 1 < chars.count, chars[close + 1] == "(",
                    let end = chars[(close + 1)...].firstIndex(of: ")")
                {
                    out.append(contentsOf: inline(String(chars[(index + 1)..<close])))
                    index = end + 1
                    continue
                }
            case "<":
                if let close = chars[index...].firstIndex(of: ">") {
                    let inside = String(chars[(index + 1)..<close])
                    if inside.hasPrefix("http") || inside.hasPrefix("mailto:") {
                        out.append(contentsOf: inside)
                        index = close + 1
                        continue
                    }
                }
            default:
                break
            }
            out.append(char)
            index += 1
        }
        return out
    }

    /// The last `limit` characters, starting at a word: the partial word the cut lands in is
    /// dropped and an ellipsis says something came before.
    static func cut(_ text: String, to limit: Int) -> String {
        guard limit > 0 else { return "" }
        guard text.count > limit else { return text }
        let start = text.index(text.endIndex, offsetBy: -(limit - 1))
        var window = text[start...]
        if let space = window.firstIndex(where: { $0 == " " || $0 == "\n" }),
            window.distance(from: window.startIndex, to: space) < limit / 2
        {
            window = window[window.index(after: space)...]
        }
        return "…" + window
    }

    private static func firstLine(_ text: String) -> String {
        String(text.split(separator: "\n", maxSplits: 1).first ?? "")
            .trimmingCharacters(in: .whitespaces)
    }
}
