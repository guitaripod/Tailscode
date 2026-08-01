import AppKit
import CodingAgentKit

/// One line of the transcript. The grammar is the CLIs': a user turn behind an accent rule,
/// reasoning collapsed to how long it took, a tool call as a single dense line, and the agent's
/// prose at full measure with no chrome at all.
enum TranscriptRow {
    case userText(String)
    case agentText(String)
    case reasoning(String)
    case tool(ToolCall)
    case file(FileReference)

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
                return .file(reference)
            case .compaction:
                return nil
            case .unknown:
                return nil
            }
        }
    }

    @MainActor
    func makeView(width: CGFloat) -> NSView {
        switch self {
        case .userText(let text):
            return Self.prompt(text)
        case .agentText(let text):
            return Self.prose(text)
        case .reasoning(let text):
            return Self.dimmed(Self.thoughtSummary(text))
        case .tool(let call):
            return Self.toolLine(call)
        case .file(let reference):
            return Self.dimmed("📎 \(reference.filename ?? reference.path)")
        }
    }

    @MainActor
    private static func prompt(_ text: String) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = MacTheme.Spacing.s

        let rule = NSView()
        rule.wantsLayer = true
        rule.layer?.backgroundColor = MacTheme.Color.accent.cgColor
        rule.translatesAutoresizingMaskIntoConstraints = false
        rule.widthAnchor.constraint(equalToConstant: 2).isActive = true

        let label = wrapping(text, font: MacTheme.Font.body(), color: MacTheme.Color.label)
        row.addArrangedSubview(rule)
        row.addArrangedSubview(label)
        rule.heightAnchor.constraint(equalTo: label.heightAnchor).isActive = true
        return row
    }

    @MainActor
    private static func prose(_ text: String) -> NSView {
        wrapping(text, font: MacTheme.Font.body(), color: MacTheme.Color.label)
    }

    @MainActor
    private static func dimmed(_ text: String) -> NSView {
        wrapping(text, font: MacTheme.Font.caption(), color: MacTheme.Color.secondaryLabel)
    }

    @MainActor
    private static func toolLine(_ call: ToolCall) -> NSView {
        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .firstBaseline
        row.spacing = MacTheme.Spacing.s

        let glyph = NSTextField(labelWithString: statusGlyph(call.status))
        glyph.font = MacTheme.Font.mono(11)
        glyph.textColor = tint(for: call.status)

        let name = NSTextField(labelWithString: call.name)
        name.font = MacTheme.Font.mono(12)
        name.textColor = MacTheme.Color.label

        let detail = NSTextField(labelWithString: summary(of: call))
        detail.font = MacTheme.Font.mono(11)
        detail.textColor = MacTheme.Color.secondaryLabel
        detail.lineBreakMode = .byTruncatingMiddle

        row.addArrangedSubview(glyph)
        row.addArrangedSubview(name)
        row.addArrangedSubview(detail)
        return row
    }

    private static func statusGlyph(_ status: ToolStatus) -> String {
        switch status {
        case .completed: return "⏺"
        case .error: return "✗"
        case .running: return "◐"
        case .pending: return "○"
        }
    }

    @MainActor
    private static func tint(for status: ToolStatus) -> NSColor {
        switch status {
        case .completed: return MacTheme.Color.success
        case .error: return MacTheme.Color.danger
        case .running: return MacTheme.Color.accent
        case .pending: return MacTheme.Color.tertiaryLabel
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
        let words = text.split(separator: " ").count
        return "⌄ thought · \(words) words"
    }

    @MainActor
    private static func wrapping(_ text: String, font: NSFont, color: NSColor) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = font
        label.textColor = color
        label.isSelectable = true
        label.drawsBackground = false
        label.isBezeled = false
        label.preferredMaxLayoutWidth = 720
        return label
    }
}
