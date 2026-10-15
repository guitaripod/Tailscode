import CodingAgentKit
import Foundation
import TailscodeCore

/// The notices a desktop can raise, made from conversation states the same way a real turn makes
/// them, so `TAILSCODE_DRIVE="2000:notice=approval"` shows a headless session exactly what the
/// daemon is told, buttons and reply field included, without waiting on an agent.
enum NoticeDemo {
    static func raise(_ name: String) {
        let key = "demo-\(name)"
        let running = state(.running)
        Notifier.shared.observeConversation(
            profileID: "demo", sessionID: key, title: title(name), state: running,
            windowActive: false)
        Notifier.shared.observeConversation(
            profileID: "demo", sessionID: key, title: title(name), state: settled(name),
            windowActive: false)
    }

    private static func title(_ name: String) -> String {
        switch name {
        case "failed": return "Release 1.77 notes"
        case "approval": return "Clean the build folder"
        case "question", "choices": return "Pick a database"
        default: return "Enrich Linux notification"
        }
    }

    private static func state(_ status: BackendStatus, _ messages: [ChatMessage] = [])
        -> ConversationState
    {
        var state = ConversationState()
        state.status = status
        state.messages = messages.isEmpty ? [prompt] : messages
        return state
    }

    private static var prompt: ChatMessage {
        ChatMessage(
            id: "u", role: .user, agentType: .claudeCode,
            parts: [MessagePart(id: "u-t", kind: .text("Make the desktop notification better"))],
            createdAt: Date().addingTimeInterval(-222))
    }

    private static func call(_ id: String, _ name: String, _ status: ToolStatus, _ input: JSONValue)
        -> MessagePart
    {
        MessagePart(
            id: id, kind: .tool(ToolCall(id: id, name: name, status: status, input: input)))
    }

    private static func answer(_ parts: [MessagePart], error: String? = nil) -> ChatMessage {
        ChatMessage(
            id: "a", role: .assistant, agentType: .claudeCode, parts: parts,
            createdAt: Date().addingTimeInterval(-220), completedAt: Date(), error: error)
    }

    private static func settled(_ name: String) -> ConversationState {
        let edit = call(
            "e", "Edit", .completed,
            .object([
                "file_path": .string("/repo/Notifier.swift"), "old_string": .string("a"),
                "new_string": .string("a\nb\nc\nd"),
            ]))
        let shell = call("s", "Bash", .completed, .object(["command": .string("swift build")]))
        var state = self.state(.idle)
        switch name {
        case "failed":
            state.lastFailure = BackendFailure(
                message: "The provider returned an error: overloaded, try again shortly")
            state.messages = [prompt, answer([shell], error: "overloaded")]
        case "approval":
            state.status = .running
            let pending = call(
                "p", "Bash", .pending, .object(["command": .string("rm -rf build/ && swift build")]))
            state.messages = [prompt, answer([shell, pending])]
            state.pendingPermissions = [
                PermissionRequest(id: "perm", sessionID: "demo-approval", title: "Run command", toolName: "Bash")
            ]
        case "question", "choices":
            state.status = .running
            let free = name == "question"
            state.pendingQuestions = [
                QuestionRequest(
                    id: "ask", sessionID: "demo-\(name)",
                    questions: [
                        QuestionRequest.Item(
                            question: "Which database should the notes live in?", header: "DB",
                            options: free
                                ? []
                                : [
                                    .init(label: "Postgres", description: ""),
                                    .init(label: "SQLite", description: ""),
                                ])
                    ])
            ]
        default:
            state.messages = [
                prompt,
                answer([
                    shell, edit,
                    MessagePart(
                        id: "t",
                        kind: .text(
                            "Done. The notification now carries a painted face, how long the turn took, the first of what I answered and a reply field. **All selftests pass.**"
                        )),
                ]),
            ]
        }
        return state
    }
}
