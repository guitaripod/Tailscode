import CodingAgentKit
import Foundation

/// What travels with a conversation when it moves to another model on another machine: the
/// conversation so far, as text, built on this device and handed over in the first message.
///
/// It is deterministic on purpose. A model-written summary costs a turn and minutes; this costs
/// nothing, reads the same on every client and every backend, and is what a person would paste if
/// they were doing it by hand. Prose only: tool output, reasoning and pictures stay behind, so a
/// secret a tool printed does not travel and a brief never grows with the work the agent did.
public struct ConversationBrief: Sendable, Hashable {
    public let source: String
    public let body: String
    public let kept: Int
    public let total: Int
    public let pictures: Int

    public init(source: String, body: String, kept: Int, total: Int, pictures: Int) {
        self.source = source
        self.body = body
        self.kept = kept
        self.total = total
        self.pictures = pictures
    }

    public var droppedAny: Bool { kept < total }

    public var estimatedTokens: Int { Self.tokens(body) }

    /// The chip on a composer that carries this: where from, and how much of it only when part was
    /// left behind. An uncut carry says where from and nothing else.
    public var chip: String {
        droppedAny ? source + " · " + Self.count(kept: kept, total: total) : source
    }

    /// The text a first message is made of: what the person typed, then the brief.
    public func wrapped(with text: String) -> String {
        CarryMark.wrap(self, text: text)
    }

    static func count(kept: Int, total: Int) -> String {
        Localized.text("%d of %d", kept, total)
    }

    static func tokens(_ text: String) -> Int { text.utf8.count / 4 }
}

extension ConversationBrief {
    /// The most a brief ever holds, however large the window it is going to.
    public static let ceiling = 24_000
    /// What a brief holds when the catalog does not say how large the window is.
    public static let unknownWindow = 12_000
    static let headShare = 0.5
    static let touchedLimit = 12

    /// Two fifths of the window the brief is going to, never past the ceiling: the rest is for the
    /// answer, for the person's next messages, and for the agent's own reading.
    public static func budget(window: Int?) -> Int {
        guard let window, window > 0 else { return unknownWindow }
        return min(Int(Double(window) * 0.4), ceiling)
    }

    /// The brief of a conversation, or nil when there is nothing to carry. `cut` names the message
    /// the brief stops before: a retry carries everything up to the question and not the question.
    public static func make(
        title: String, messages: [ChatMessage], before cut: String? = nil, window: Int?
    ) -> ConversationBrief? {
        var reading = TurnReading()
        for message in messages {
            if message.id == cut { break }
            reading.take(message)
        }
        return reading.brief(source: sourceName(title), budget: budget(window: window))
    }

    /// The question an answer was given to: the nearest user message before it that a person wrote.
    public static func question(before answerID: String, in messages: [ChatMessage]) -> ChatMessage? {
        guard let index = messages.firstIndex(where: { $0.id == answerID }) else { return nil }
        return messages[..<index].last { TurnReading.question(of: $0) != nil }
    }

    /// The words of a question as a person typed them, with any brief it was sent with taken off.
    public static func typed(_ message: ChatMessage) -> String? {
        TurnReading.question(of: message)
    }

    static func sourceName(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return AgentSession.isPlaceholderTitle(trimmed) ? Localized.text("An earlier chat") : trimmed
    }
}

private struct TurnReading {
    struct Turn {
        var user: String
        var assistant: [String] = []
        var touched: [String] = []
        var pictures = 0

        var rendered: String {
            var lines = ["User: " + user]
            let answer = assistant.joined(separator: "\n\n")
            if !answer.isEmpty { lines.append("Assistant: " + answer) }
            return lines.joined(separator: "\n")
        }
    }

    var turns: [Turn] = []
    var head: String?
    var eligibleFrom = 0
    var sawUser = false

    static func question(of message: ChatMessage) -> String? {
        guard message.role == .user else { return nil }
        let raw = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        let text = CarryMark.split(raw)?.rest ?? raw
        guard !text.isEmpty, !isSlashCommand(text) else { return nil }
        return text
    }

    static func isSlashCommand(_ text: String) -> Bool {
        guard text.hasPrefix("/") else { return false }
        let word = text.prefix { !$0.isWhitespace }
        return word.count <= 24 && !word.dropFirst().contains("/")
    }

    mutating func take(_ message: ChatMessage) {
        for part in message.parts {
            if case .compaction(let compaction) = part.kind, let summary = compaction.summary,
                !summary.isEmpty
            {
                head = summary
                eligibleFrom = turns.count
            }
        }
        switch message.role {
        case .user: takeUser(message)
        case .assistant: takeAssistant(message)
        case .system: break
        }
    }

    private mutating func takeUser(_ message: ChatMessage) {
        let raw = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !sawUser, !raw.isEmpty {
            sawUser = true
            if let carried = CarryMark.split(raw) {
                head = carried.reading.brief
            }
        }
        guard let text = Self.question(of: message) else { return }
        turns.append(Turn(user: text))
        addPictures(of: message)
    }

    private mutating func takeAssistant(_ message: ChatMessage) {
        guard !message.isStreaming, !turns.isEmpty else { return }
        for part in message.parts {
            switch part.kind {
            case .text(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty { turns[turns.count - 1].assistant.append(trimmed) }
            case .tool(let call):
                if let file = Self.touchedFile(call) { turns[turns.count - 1].touched.append(file) }
            default: break
            }
        }
        addPictures(of: message)
    }

    private mutating func addPictures(of message: ChatMessage) {
        guard !turns.isEmpty else { return }
        let count = message.parts.filter { part in
            guard case .file(let reference) = part.kind else { return false }
            return reference.mime?.hasPrefix("image/") ?? false
        }.count
        turns[turns.count - 1].pictures += count
    }

    private static let editingTools: Set<String> = [
        "edit", "write", "multiedit", "notebookedit", "patch", "apply_patch",
    ]
    private static let pathKeys = ["file_path", "filePath", "path", "notebook_path"]

    static func touchedFile(_ call: ToolCall) -> String? {
        guard editingTools.contains(call.name.lowercased()), case .object(let input)? = call.input
        else { return nil }
        for key in pathKeys {
            if case .string(let path)? = input[key], !path.isEmpty {
                return path.split(separator: "/").last.map(String.init) ?? path
            }
        }
        return nil
    }

    func brief(source: String, budget: Int) -> ConversationBrief? {
        let eligible = Array(turns[min(eligibleFrom, turns.count)...])
        var remaining = budget
        let earlier = head.map { Self.clipped($0, tokens: Int(Double(budget) * ConversationBrief.headShare), keeping: .start) }
        remaining -= earlier.map(ConversationBrief.tokens) ?? 0

        var kept: [Turn] = []
        for turn in eligible.reversed() {
            let cost = ConversationBrief.tokens(turn.rendered)
            if kept.isEmpty {
                kept.append(cost <= remaining ? turn : Self.cut(turn, tokens: max(remaining, 1)))
                remaining -= min(cost, remaining)
            } else if cost <= remaining {
                kept.append(turn)
                remaining -= cost
            } else {
                break
            }
        }
        guard earlier != nil || !kept.isEmpty else { return nil }
        kept.reverse()

        var lines = [
            "Carried from the chat \u{201C}\(source)\u{201D}. The conversation so far:",
        ]
        if let earlier { lines.append("Earlier: " + earlier) }
        lines.append(contentsOf: kept.map(\.rendered))
        let touched = Self.unique(kept.flatMap(\.touched)).prefix(ConversationBrief.touchedLimit)
        if !touched.isEmpty { lines.append("Touched: " + touched.joined(separator: ", ")) }
        return ConversationBrief(
            source: source, body: lines.joined(separator: "\n"), kept: kept.count,
            total: turns.count, pictures: kept.reduce(0) { $0 + $1.pictures })
    }

    private static func unique(_ names: [String]) -> [String] {
        var seen = Set<String>()
        return names.filter { seen.insert($0).inserted }
    }

    private static func cut(_ turn: Turn, tokens: Int) -> Turn {
        var cut = turn
        let allowance = max(tokens * 4 - turn.user.utf8.count - 16, 0)
        if allowance == 0 {
            cut.user = clipped(turn.user, tokens: tokens, keeping: .end)
            cut.assistant = []
        } else {
            cut.assistant = [clipped(turn.assistant.joined(separator: "\n\n"), tokens: allowance / 4, keeping: .end)]
        }
        return cut
    }

    enum Keeping { case start, end }

    static func clipped(_ text: String, tokens: Int, keeping: Keeping) -> String {
        let limit = max(tokens, 0) * 4
        guard text.utf8.count > limit else { return text }
        var bytes = 0
        var characters: [Character] = []
        let sequence: [Character] = keeping == .start ? Array(text) : Array(text.reversed())
        for character in sequence {
            let size = String(character).utf8.count
            if bytes + size > limit { break }
            bytes += size
            characters.append(character)
        }
        return keeping == .start
            ? String(characters) + "…"
            : "…" + String(characters.reversed())
    }
}

/// What a carried conversation reads as once its first message is split from what the person typed.
public struct CarryReading: Sendable, Hashable {
    public let source: String
    public let kept: Int
    public let total: Int
    public let pictures: Int
    public let brief: String

    public init(source: String, kept: Int, total: Int, pictures: Int, brief: String) {
        self.source = source
        self.kept = kept
        self.total = total
        self.pictures = pictures
        self.brief = brief
    }

    public var droppedAny: Bool { kept < total }

    /// The row at the top of a carried chat. The count is there only when something was left behind.
    public var line: String {
        let lead = Localized.text("Continued from %@", source)
        return droppedAny ? lead + " · " + ConversationBrief.count(kept: kept, total: total) : lead
    }

    /// What the reader says above the brief: how much came, and what did not.
    public var summary: String {
        var parts = [
            droppedAny
                ? Localized.text("Last %d of %d turns", kept, total)
                : Localized.text("All %d turns", total)
        ]
        if pictures == 1 {
            parts.append(Localized.text("1 picture left out"))
        } else if pictures > 1 {
            parts.append(Localized.text("%d pictures left out", pictures))
        }
        return parts.joined(separator: " · ")
    }
}

/// How a brief rides in a message, and how a client takes it off again.
///
/// The words come first and the brief after, because everything that names a chat from its first
/// message — the title, a notification, the Live Activity — reads the first line, and that line is
/// the person's. The tag and its attributes are read by every installed app: they are added to and
/// never renamed.
public enum CarryMark {
    public static let tag = "carried-conversation"
    static let open = "<" + tag + " "
    static let close = "</" + tag + ">"

    public static func wrap(_ brief: ConversationBrief, text: String) -> String {
        let typed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let attributes = [
            ("from", brief.source), ("kept", String(brief.kept)), ("of", String(brief.total)),
            ("pictures", String(brief.pictures)),
        ].map { "\($0.0)=\"\(escapeAttribute($0.1))\"" }.joined(separator: " ")
        let block = open + attributes + ">\n" + escapeBody(brief.body) + "\n" + close
        return typed.isEmpty ? block : typed + "\n\n" + block
    }

    /// The reading and the person's own words, or nil when the text carries no brief.
    public static func split(_ text: String) -> (reading: CarryReading, rest: String)? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasSuffix(close), let start = trimmed.range(of: open, options: .backwards),
            start.lowerBound == trimmed.startIndex
                || trimmed[trimmed.index(before: start.lowerBound)] == "\n",
            let tagEnd = trimmed[start.upperBound...].firstIndex(of: ">")
        else { return nil }
        let attributes = parse(String(trimmed[start.upperBound..<tagEnd]))
        guard let source = attributes["from"], let kept = attributes["kept"].flatMap(Int.init),
            let total = attributes["of"].flatMap(Int.init)
        else { return nil }
        let bodyStart = trimmed.index(after: tagEnd)
        let bodyEnd = trimmed.index(trimmed.endIndex, offsetBy: -close.count)
        guard bodyStart <= bodyEnd else { return nil }
        let body = trimmed[bodyStart..<bodyEnd].trimmingCharacters(in: .whitespacesAndNewlines)
        let reading = CarryReading(
            source: source, kept: kept, total: total,
            pictures: attributes["pictures"].flatMap(Int.init) ?? 0, brief: unescapeBody(body))
        let rest = trimmed[..<start.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        return (reading, rest)
    }

    private static let attribute = try? NSRegularExpression(pattern: "([a-z]+)=\"([^\"]*)\"")

    private static func parse(_ text: String) -> [String: String] {
        guard let attribute else { return [:] }
        var found: [String: String] = [:]
        let range = NSRange(text.startIndex..., in: text)
        for match in attribute.matches(in: text, range: range) {
            guard let key = Range(match.range(at: 1), in: text),
                let value = Range(match.range(at: 2), in: text)
            else { continue }
            found[String(text[key])] = unescapeAttribute(String(text[value]))
        }
        return found
    }

    private static func escapeAttribute(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func unescapeAttribute(_ value: String) -> String {
        value.replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&amp;", with: "&")
    }

    private static func escapeBody(_ body: String) -> String {
        body.replacingOccurrences(of: "</" + tag, with: "<\\/" + tag)
            .replacingOccurrences(of: "<" + tag, with: "<\\" + tag)
    }

    private static func unescapeBody(_ body: String) -> String {
        body.replacingOccurrences(of: "<\\/" + tag, with: "</" + tag)
            .replacingOccurrences(of: "<\\" + tag, with: "<" + tag)
    }
}
