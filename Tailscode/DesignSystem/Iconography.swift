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

    /// A tool's colour is its meaning, and the meaning is Core's to name — `tintSlot` decides that
    /// everything the agent reached out and touched is one thing, `info`. What stays per-kind here
    /// is only the system-palette garnish: the no-theme default can afford a hue per kind because
    /// it has the whole spectrum and no contract.
    static func tint(for kind: ToolCallSummary.Kind) -> UIColor {
        switch ActivityKind.tintSlot(forTool: kind) {
        case .info: return ThemePalette.color(\.info, system: systemHue(for: kind))
        case .accent: return Theme.Color.accent
        case .attention: return ThemePalette.color(\.warn, system: .systemYellow)
        case .muted: return Theme.Color.secondaryLabel
        }
    }

    private static func systemHue(for kind: ToolCallSummary.Kind) -> UIColor {
        switch kind {
        case .shell: return .systemOrange
        case .fileEdit, .fileWrite: return .systemPurple
        case .webSearch, .webFetch: return .systemIndigo
        case .fileRead, .fileSearch: return .systemTeal
        case .subagent, .workflow: return .systemPink
        case .taskTracking, .skill, .question, .other: return .systemGray
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
