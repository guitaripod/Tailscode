import TailscodeCore
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
    /// The symbol comes from the shared vocabulary rather than a second copy here, so the terminal
    /// a shell wears in a tool row is the terminal the status badge shows while that shell runs.
    static func symbol(for kind: ToolCallSummary.Kind) -> String {
        ActivityKind.symbol(forTool: kind)
    }

    /// A tool's colour is its meaning, and under a theme there are only so many meanings to spend.
    /// The system palette can afford a hue per kind because it has the whole spectrum and no
    /// contract; a theme has five signals that each carry exactly one thing, and everything the
    /// agent reached out and touched is one thing — `info`. What stays separate is what is not a
    /// tool at all: a question is attention, and a plan is motion.
    static func tint(for kind: ToolCallSummary.Kind) -> UIColor {
        switch kind {
        case .shell: return ThemePalette.color(\.info, system: .systemOrange)
        case .fileEdit, .fileWrite: return ThemePalette.color(\.info, system: .systemPurple)
        case .webSearch, .webFetch: return ThemePalette.color(\.info, system: .systemIndigo)
        case .fileRead, .fileSearch: return ThemePalette.color(\.info, system: .systemTeal)
        case .subagent, .workflow: return ThemePalette.color(\.info, system: .systemPink)
        case .taskTracking, .skill: return Theme.Color.accent
        case .question: return ThemePalette.color(\.warn, system: .systemYellow)
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
