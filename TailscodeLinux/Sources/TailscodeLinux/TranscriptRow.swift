import CAdw
import CodingAgentKit
import Foundation

/// One line of the transcript, in the CLIs' grammar: the prompt behind an accent rule, the
/// agent's answer as prose at full measure, reasoning collapsed, and every tool call as one dense
/// monospace line. No bubbles — the material lives in the chrome around this.
enum TranscriptRow {
    case userText(String)
    case agentText(String)
    case reasoning(String)
    case tool(ToolCall)
    case file(String)

    static func rows(for message: ChatMessage) -> [TranscriptRow] {
        message.parts.compactMap { part in
            switch part.kind {
            case .text(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return message.role == .user ? .userText(trimmed) : .agentText(trimmed)
            case .reasoning(let text):
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return .reasoning(trimmed)
            case .tool(let call):
                return .tool(call)
            case .file(let reference):
                return .file(reference.filename ?? reference.path ?? "file")
            case .compaction, .unknown:
                return nil
            }
        }
    }

    func makeWidget() -> UnsafeMutablePointer<GtkWidget> {
        switch self {
        case .userText(let text):
            return Self.prompt(text)
        case .agentText(let text):
            return Gtk.label(text, css: "agent-text", wrap: true)
        case .reasoning(let text):
            return Gtk.label(Self.thoughtSummary(text), css: "dim", wrap: false)
        case .tool(let call):
            return Self.toolLine(call)
        case .file(let name):
            return Gtk.label("📎 \(name)", css: "dim")
        }
    }

    private static func prompt(_ text: String) -> UnsafeMutablePointer<GtkWidget> {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
        let rule = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        Gtk.addClass(rule, "prompt-rule")
        gtk_widget_set_size_request(rule, 2, -1)
        let label = Gtk.label(text, css: "agent-text", wrap: true)
        gtk_widget_set_hexpand(label, 1)
        gtk_box_append(ptr(row), rule)
        gtk_box_append(ptr(row), label)
        return row
    }

    private static func toolLine(_ call: ToolCall) -> UnsafeMutablePointer<GtkWidget> {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        gtk_box_append(
            ptr(row), Gtk.label(glyph(call.status), css: "tool-line", selectable: false))
        gtk_box_append(ptr(row), Gtk.label(call.name, css: "tool-line"))
        let detail = Gtk.label(summary(of: call), css: "tool-line")
        Gtk.addClass(detail, "dim")
        gtk_widget_set_hexpand(detail, 1)
        gtk_box_append(ptr(row), detail)
        return row
    }

    private static func glyph(_ status: ToolStatus) -> String {
        switch status {
        case .completed: return "⏺"
        case .error: return "✗"
        case .running: return "◐"
        case .pending: return "○"
        }
    }

    private static func summary(of call: ToolCall) -> String {
        let fromInput = call.input?.objectValue?.values
            .compactMap(\.stringValue).first(where: { !$0.isEmpty })
        let fromTitle = call.title.flatMap { $0 == call.name ? nil : $0 }
        let raw = fromInput ?? fromTitle ?? ""
        return String(raw.replacingOccurrences(of: "\n", with: " ").prefix(120))
    }

    private static func thoughtSummary(_ text: String) -> String {
        "⌄ thought · \(text.split(separator: " ").count) words"
    }
}
