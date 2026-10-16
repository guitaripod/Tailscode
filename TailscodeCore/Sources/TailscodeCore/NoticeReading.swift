import CodingAgentKit
import Foundation

/// Reads a conversation into the notice about it: the facts of the turn that just ended, the
/// command that wants approving, the question being asked. What it makes is the same `NoticeWire`
/// a bridge pushes, so a notice raised here and one raised by a server go through one set of words.
public enum NoticeReader {
    public static let excerptLimit = NoticeWords.excerptLimit
    public static let choiceLimit = NoticeWords.choiceLimit
    public static let choiceWidth = NoticeWords.choiceWidth

    /// The longest raw passage a notice carries; the words cut it shorter where they need to.
    static let rawLimit = 800

    public static func turnEnded(in state: ConversationState) -> NoticeReading {
        NoticeWords.reading(wire(turnEnded: state))
    }

    public static func turnFailed(in state: ConversationState) -> NoticeReading {
        NoticeWords.reading(wire(turnFailed: state))
    }

    public static func approval(
        _ permission: PermissionRequest, in state: ConversationState
    ) -> NoticeReading {
        NoticeWords.reading(wire(approval: permission, in: state))
    }

    public static func question(_ request: QuestionRequest) -> NoticeReading {
        NoticeWords.reading(wire(question: request))
    }

    public static func wire(turnEnded state: ConversationState) -> NoticeWire {
        let calls = LiveActivityReading.turnCalls(in: state)
        let tally = ToolDiff.tally(calls)
        return NoticeWire(
            kind: .done, seconds: elapsed(in: state).map { Int($0.rounded()) }, tools: calls.count,
            added: tally.added, removed: tally.removed,
            text: raw(turnText(in: state)))
    }

    public static func wire(turnFailed state: ConversationState) -> NoticeWire {
        let reason = state.lastFailure?.message ?? LiveActivityReading.turnAnswer(in: state)?.error
            ?? ""
        return NoticeWire(
            kind: .failed, seconds: elapsed(in: state).map { Int($0.rounded()) },
            tools: LiveActivityReading.turnCalls(in: state).count, text: raw(reason),
            prompt: lastPrompt(in: state))
    }

    public static func wire(
        approval permission: PermissionRequest, in state: ConversationState
    ) -> NoticeWire {
        let tool = permission.toolName ?? permission.title
        let call = LiveActivityReading.turnCalls(in: state).last {
            ($0.status == .pending || $0.status == .running)
                && (permission.toolName == nil || $0.name == permission.toolName)
        }
        let described = call.flatMap(describe) ?? permission.title.flatMap { $0 == tool ? nil : $0 }
        return NoticeWire(kind: .approval, text: raw(described ?? ""), subject: tool)
    }

    public static func wire(question request: QuestionRequest) -> NoticeWire {
        let items = request.questions
        let single = items.count == 1 ? items.first : nil
        return NoticeWire(
            kind: .question, text: raw(items.first?.question ?? ""),
            options: single.map { item in
                item.options.map {
                    NoticeWire.Option(
                        label: $0.label, detail: $0.description.isEmpty ? nil : $0.description)
                }
            },
            multiple: single?.multiple, free: single.map { $0.custom || $0.options.isEmpty } ?? false)
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

    private static func raw(_ text: String) -> String? {
        let words = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return words.isEmpty ? nil : String(words.prefix(rawLimit))
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

    public static func sentence(_ word: String) -> String { NoticeWords.sentence(word) }

    static func plain(_ markdown: String) -> String { NoticeWords.plain(markdown) }

    static func cut(_ text: String, to limit: Int) -> String { NoticeWords.cut(text, to: limit) }
}
