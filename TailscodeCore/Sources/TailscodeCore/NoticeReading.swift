import CodingAgentKit
import Foundation

/// What a system notification says once it is told more than that something happened: how long the
/// turn took and how much it did, the first of what it answered, the command it wants to run, the
/// question it is asking and the few answers that fit on a button.
///
/// It is read from state the client already holds, so a notice never waits on the tailnet, and it
/// is words and facts rather than markup: each desktop draws them in whatever its daemon can show.
/// A client that cannot draw buttons or a reply field simply ignores `choices` and
/// `replyPlaceholder`, and the notice is still a better sentence than "Your agent finished."
public struct NoticeReading: Sendable, Equatable {
    public let headline: String
    public let facts: [String]
    public let excerpt: String
    public let detail: String
    /// The answers a question can be given at one press, in the words the agent offered. Empty
    /// unless exactly one question was asked, takes exactly one answer, and every option is short
    /// enough to be a button.
    public let choices: [String]
    /// What the reply field asks for, or nil where a reply would have nowhere to go.
    public let replyPlaceholder: String?
    /// The words that began a turn that failed, ready to be sent again.
    public let retryPrompt: String?

    public init(
        headline: String, facts: [String] = [], excerpt: String = "", detail: String = "",
        choices: [String] = [], replyPlaceholder: String? = nil, retryPrompt: String? = nil
    ) {
        self.headline = headline
        self.facts = facts
        self.excerpt = excerpt
        self.detail = detail
        self.choices = choices
        self.replyPlaceholder = replyPlaceholder
        self.retryPrompt = retryPrompt
    }

    /// The first line: what it is, then what it took.
    public var lead: String { ([headline] + facts).joined(separator: " · ") }

    /// The lines under the lead, in order, none of them empty.
    public var rest: [String] { [excerpt, detail].filter { !$0.isEmpty } }
}

public enum NoticeReader {
    public static let excerptLimit = 220
    public static let choiceLimit = 3
    public static let choiceWidth = 32

    public static func turnEnded(in state: ConversationState) -> NoticeReading {
        let calls = LiveActivityReading.turnCalls(in: state)
        var facts = turnFacts(in: state, calls: calls)
        let tally = ToolDiff.tally(calls)
        if tally.added + tally.removed > 0 { facts.append("+\(tally.added) −\(tally.removed)") }
        return NoticeReading(
            headline: sentence(Localized.text("finished")), facts: facts,
            excerpt: cut(plain(turnText(in: state)), to: excerptLimit),
            replyPlaceholder: Localized.text("Message your agent…"))
    }

    public static func turnFailed(in state: ConversationState) -> NoticeReading {
        let reason = state.lastFailure?.message ?? LiveActivityReading.turnAnswer(in: state)?.error
            ?? ""
        return NoticeReading(
            headline: sentence(Localized.text("failed")),
            facts: turnFacts(in: state, calls: LiveActivityReading.turnCalls(in: state)),
            excerpt: cut(FailedTurnReading.tidy(reason), to: excerptLimit),
            replyPlaceholder: Localized.text("Message your agent…"),
            retryPrompt: lastPrompt(in: state))
    }

    public static func approval(
        _ permission: PermissionRequest, in state: ConversationState
    ) -> NoticeReading {
        let tool = permission.toolName ?? permission.title ?? Localized.text("a tool")
        let call = LiveActivityReading.turnCalls(in: state).last {
            ($0.status == .pending || $0.status == .running)
                && (permission.toolName == nil || $0.name == permission.toolName)
        }
        let described = call.flatMap(describe) ?? permission.title.flatMap { $0 == tool ? nil : $0 }
        return NoticeReading(
            headline: sentence(Localized.text("needs approval")), facts: [tool],
            excerpt: cut(described ?? "", to: excerptLimit))
    }

    public static func question(_ request: QuestionRequest) -> NoticeReading {
        let items = request.questions
        let first = items.first
        let single = items.count == 1 ? first : nil
        let options = single?.options.map(\.label) ?? []
        let takesOne = single.map { !$0.multiple } ?? false
        let fitsButtons =
            takesOne && !options.isEmpty && Set(options).count == options.count
            && options.allSatisfy { !$0.isEmpty && $0.count <= choiceWidth }
        let choices = fitsButtons ? Array(options.prefix(choiceLimit)) : []
        let askedFree = single.map { $0.custom || $0.options.isEmpty } ?? false
        return NoticeReading(
            headline: sentence(Localized.text("has a question")),
            excerpt: cut(collapse(first?.question ?? ""), to: excerptLimit),
            detail: options.count > choiceLimit
                ? cut(options.joined(separator: " · "), to: excerptLimit) : "",
            choices: choices,
            replyPlaceholder: askedFree ? Localized.text("Your answer") : nil)
    }

    private static func turnFacts(in state: ConversationState, calls: [ToolCall]) -> [String] {
        var facts: [String] = []
        if let seconds = elapsed(in: state), seconds >= 5 {
            facts.append(InterruptedTurnReading.duration(seconds))
        }
        if calls.count == 1 {
            facts.append(Localized.text("1 tool"))
        } else if calls.count > 1 {
            facts.append(Localized.text("%lld tools", calls.count))
        }
        return facts
    }

    /// The server's own measure of the wait wins; otherwise the turn's stamps, from the prompt.
    private static func elapsed(in state: ConversationState) -> TimeInterval? {
        guard let answer = LiveActivityReading.turnAnswer(in: state) else { return nil }
        if let reported = answer.duration, reported > 0 { return reported }
        guard let end = answer.completedAt, let start = LiveActivityReading.turnStart(in: state)
        else { return nil }
        let span = end.timeIntervalSince(start)
        return span > 0 ? span : nil
    }

    /// The words of the turn's last answer that has any, searched back only as far as the last
    /// thing the person said.
    private static func turnText(in state: ConversationState) -> String {
        for message in state.messages.reversed() {
            if message.role == .user { return "" }
            guard message.role == .assistant else { continue }
            let words = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !words.isEmpty { return words }
        }
        return ""
    }

    private static func lastPrompt(in state: ConversationState) -> String? {
        guard let message = state.messages.last(where: { $0.role == .user }) else { return nil }
        let words = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return words.isEmpty ? nil : words
    }

    /// What a call is about to do, in one line: the command a shell would run, the file an edit
    /// would change and by how much.
    private static func describe(_ call: ToolCall) -> String? {
        let summary = call.summary
        switch summary.kind {
        case .shell:
            return summary.command ?? summary.title
        case .fileEdit, .fileWrite:
            guard let path = summary.filePath ?? summary.title else { return nil }
            guard let stats = summary.diffStats, stats.added + stats.removed > 0 else {
                return path
            }
            return "\(path) +\(stats.added) −\(stats.removed)"
        default:
            return summary.title ?? summary.command ?? summary.detail
        }
    }

    /// A word as the first of a sentence.
    public static func sentence(_ word: String) -> String {
        guard let first = word.first else { return word }
        return first.uppercased() + word.dropFirst()
    }

    /// Markdown read as the words it holds: fenced code left out, the marks that only shape a page
    /// taken off, a link left as its label, and the lines run into one.
    static func plain(_ markdown: String) -> String {
        var kept: [String] = []
        var fenced = false
        for raw in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("```") {
                fenced.toggle()
                continue
            }
            guard !fenced, !line.isEmpty else { continue }
            line = line.replacingOccurrences(
                of: #"^(#{1,6}\s+|>\s*|[-*•]\s+|\d+[.)]\s+)"#, with: "", options: .regularExpression)
            line = line.replacingOccurrences(
                of: #"\[([^\]]*)\]\([^)]*\)"#, with: "$1", options: .regularExpression)
            line = line.replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "`", with: "")
            kept.append(line)
        }
        return collapse(kept.joined(separator: " "))
    }

    private static func collapse(_ text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Cut at a word, and marked.
    static func cut(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let head = String(text.prefix(limit))
        let whole = head.lastIndex(of: " ").map { String(head[..<$0]) } ?? head
        return whole.trimmingCharacters(in: .punctuationCharacters.union(.whitespaces)) + "…"
    }
}
