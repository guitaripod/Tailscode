import CodingAgentKit
import UIKit

extension AgentType {
    var symbolName: String {
        self == .claudeCode ? "sparkles" : "chevron.left.forwardslash.chevron.right"
    }

    var brandColor: UIColor {
        self == .claudeCode ? Theme.Color.claude : Theme.Color.opencode
    }
}

/// Maps agent tool calls to a stable visual identity (symbol + tint by what the
/// tool *does*: read, mutate, execute, network, orchestrate) and tool statuses
/// to semantic colors, so a glance at an activity card tells the story. The
/// classification itself comes from the Kit's `ToolCallSummary`.
enum ToolIconography {
    static func symbol(for kind: ToolCallSummary.Kind) -> String {
        switch kind {
        case .shell: return "terminal"
        case .fileEdit, .fileWrite: return "pencil.line"
        case .fileRead: return "doc.text"
        case .fileSearch: return "magnifyingglass"
        case .webSearch, .webFetch: return "globe"
        case .taskTracking: return "checklist"
        case .subagent, .workflow: return "person.2"
        case .skill: return "wand.and.stars"
        case .other: return "wrench.and.screwdriver"
        }
    }

    static func tint(for kind: ToolCallSummary.Kind) -> UIColor {
        switch kind {
        case .shell: return .systemOrange
        case .fileEdit, .fileWrite: return .systemPurple
        case .webSearch, .webFetch: return .systemIndigo
        case .fileRead, .fileSearch: return .systemTeal
        case .subagent, .workflow: return .systemPink
        case .taskTracking, .skill: return Theme.Color.accent
        case .other: return Theme.Color.secondaryLabel
        }
    }

    static func statusColor(_ status: ToolStatus) -> UIColor {
        switch status {
        case .pending: return Theme.Color.tertiaryLabel
        case .running: return Theme.Color.accent
        case .completed: return Theme.Color.success
        case .error: return Theme.Color.danger
        }
    }
}
