import CodingAgentKit
import Foundation

/// What a tool call is, asked once per distinct tool name.
///
/// The Kit reads a call's kind off its name by lowercasing it and searching it for two dozen
/// words, which is cheap once and not cheap for every call of a conversation on every token a
/// turn streams: a transcript of a few hundred tool calls spent most of a millisecond per arrival
/// answering a question whose answer is a handful of names long.
public enum ToolKinds {
    public static func kind(of call: ToolCall) -> ToolCallSummary.Kind {
        memo.kind(named: call.name)
    }

    private static let memo = NameMemo()

    private final class NameMemo: @unchecked Sendable {
        private static let limit = 2048
        private let lock = NSLock()
        private var answers: [String: ToolCallSummary.Kind] = [:]

        func kind(named name: String) -> ToolCallSummary.Kind {
            lock.lock()
            defer { lock.unlock() }
            if let known = answers[name] { return known }
            let kind = ToolCall(id: "", name: name, status: .running).summaryKind
            if answers.count >= Self.limit { answers.removeAll(keepingCapacity: true) }
            answers[name] = kind
            return kind
        }
    }
}
