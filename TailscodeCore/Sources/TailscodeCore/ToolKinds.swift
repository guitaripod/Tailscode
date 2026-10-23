import CodingAgentKit
import Foundation

/// What a tool call is, answered from the one memo of tool names (``ToolCall/cachedKind``): the Kit
/// reads a call's kind off its name by searching it for two dozen words, which is not cheap for
/// every call of a conversation on every token a turn streams.
public enum ToolKinds {
    public static func kind(of call: ToolCall) -> ToolCallSummary.Kind { call.cachedKind }
}
