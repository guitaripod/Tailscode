import CodingAgentKit
import Foundation

/// What the end of a transcript says about the turn in front of it, read in one walk back from the
/// last message.
///
/// The band, the Live Activity and the pane's glance each used to ask for their own fact — when the
/// turn began, which tool is out, when the person last spoke, what the activity is — and each asked
/// by walking back through the messages, so a state emitted for a token walked the end of the
/// conversation four times and copied every tool call it passed on the way. Here the facts come
/// from one walk that stops at the first message every one of them has been settled by, and a tool
/// call is looked at in place and copied only when it is the one that was wanted.
struct TurnScan: Sendable {
    var lastPromptAt: Date?
    var turnStart: Date?
    var runningCall: ToolCall?

    /// - Parameter wantsStart: whether the turn's start is wanted, which is only asked of a
    ///   conversation that is working: an idle one has no turn to date.
    static func read(_ messages: [ChatMessage], wantsStart: Bool) -> TurnScan {
        var scan = TurnScan()
        var searchingTool = true
        var searchingStart = wantsStart
        var searchingPrompt = true
        var openerAt: Date?
        var hasOpener = false
        for message in messages.reversed() {
            if searchingTool {
                for part in message.parts.reversed() {
                    if let call = part.kind.runningCall {
                        scan.runningCall = call
                        searchingTool = false
                        break
                    }
                }
                if message.role == .user { searchingTool = false }
            }
            if searchingStart {
                if message.role == .assistant, Self.isSettled(message, hasOpener: hasOpener) {
                    searchingStart = false
                } else if message.role == .user {
                    openerAt = message.createdAt
                    hasOpener = true
                }
            }
            if searchingPrompt, message.role == .user {
                scan.lastPromptAt = message.createdAt
                searchingPrompt = false
            }
            if !searchingTool, !searchingStart, !searchingPrompt { break }
        }
        if wantsStart { scan.turnStart = openerAt ?? scan.lastPromptAt }
        return scan
    }

    /// Whether an assistant message closed its turn. A stamped `completedAt` says so outright; a
    /// backend that never stamps one (claude-bridge) leaves nil on every message it ever sent,
    /// so there a message that is not streaming and already has a later prompt after it is the
    /// end of an earlier turn rather than the one still running — otherwise every clock would
    /// count from the first prompt in the chat.
    static func isSettled(_ message: ChatMessage, hasOpener: Bool) -> Bool {
        if message.completedAt != nil { return true }
        return !message.isStreaming && hasOpener
    }
}

extension MessagePart.Kind {
    /// The call this part holds when it is a tool still out on the machine, and nothing otherwise.
    var runningCall: ToolCall? {
        guard case .tool(let call) = self, call.status == .running else { return nil }
        return call
    }
}
