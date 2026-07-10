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
/// to semantic colors, so a glance at an activity card tells the story.
enum ToolIconography {
    static func symbol(for toolName: String) -> String {
        let name = toolName.lowercased()
        if name.contains("todo") { return "checklist" }
        if name.contains("bash") || name.contains("shell") || name.contains("terminal")
            || name.contains("command") || name.contains("exec")
        { return "terminal" }
        if name.contains("edit") || name.contains("write") || name.contains("patch")
            || name.contains("str_replace") || name.contains("create") || name.contains("apply")
        { return "pencil.line" }
        if name.contains("websearch") || name.contains("webfetch") || name.contains("web")
            || name.contains("fetch") || name.contains("http") || name.contains("url")
        { return "globe" }
        if name.contains("grep") || name.contains("glob") || name.contains("search")
            || name.contains("find") || name == "ls" || name.contains("list")
        { return "magnifyingglass" }
        if name.contains("read") || name.contains("cat") || name.contains("view")
            || name.contains("open") || name.contains("notebook")
        { return "doc.text" }
        if name.contains("task") || name.contains("agent") || name.contains("skill")
            || name.contains("workflow")
        { return "person.2" }
        if name.contains("question") || name.contains("ask") || name.contains("permission")
        { return "questionmark.circle" }
        if name.contains("mcp") { return "puzzlepiece.extension" }
        if name.contains("plan") { return "map" }
        return "wrench.and.screwdriver"
    }

    static func tint(for toolName: String) -> UIColor {
        switch symbol(for: toolName) {
        case "terminal": return .systemOrange
        case "pencil.line": return .systemPurple
        case "globe": return .systemIndigo
        case "magnifyingglass", "doc.text": return .systemTeal
        case "person.2", "map": return .systemPink
        case "checklist": return Theme.Color.accent
        case "questionmark.circle": return Theme.Color.warning
        default: return Theme.Color.secondaryLabel
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
