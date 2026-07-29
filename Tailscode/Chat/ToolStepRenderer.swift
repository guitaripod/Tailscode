import CodingAgentKit
import UIKit

/// Builds the view for one agent step — a thought or a tool call — from its
/// semantic summary. Shared by the activity card in a conversation and the
/// subagent card nested inside it, so a spawned agent's work reads in exactly
/// the same vocabulary as its parent's.
@MainActor
final class ToolStepRenderer {
    private(set) var tappableRows: [(view: UIView, action: () -> Void)] = []
    var onToolTap: ((ToolCall) -> Void)?
    var onLinkTap: ((URL) -> Void)?

    func reset() { tappableRows = [] }

    func view(for step: ActivityStep) -> UIView {
        switch step {
        case .reasoning(let text):
            let label = UILabel()
            label.numberOfLines = 0
            label.font = UIFont.preferredFont(forTextStyle: .subheadline).withTraits(.traitItalic)
            label.textColor = Theme.Color.secondaryLabel
            label.text = text
            return label
        case .tool(let call):
            return toolView(call)
        }
    }

    /// Runs the action of whichever tappable row contains `location` in the
    /// hosting cell's coordinate space; false when the touch landed elsewhere
    /// and the caller should fall back to its own handling.
    func handleTap(at location: CGPoint, in view: UIView) -> Bool {
        for (row, action) in tappableRows where row.superview != nil {
            if row.bounds.contains(view.convert(location, to: row)) {
                action()
                return true
            }
        }
        return false
    }

    private func toolView(_ call: ToolCall) -> UIView {
        let summary = call.summary
        let statusColor = ToolIconography.statusColor(call.status)
        let linkable = onToolTap != nil && summary.kind == .subagent
        let header = UILabel()
        header.numberOfLines = 1
        let attributed = NSMutableAttributedString()
        if let icon = UIImage(
            systemName: ToolIconography.symbol(for: summary.kind),
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))?
            .withTintColor(ToolIconography.tint(for: summary.kind), renderingMode: .alwaysOriginal)
        {
            attributed.append(NSAttributedString(attachment: NSTextAttachment(image: icon)))
            attributed.append(NSAttributedString(string: " "))
        }
        attributed.append(
            NSAttributedString(
                string: "\(call.name)  ",
                attributes: [.font: UIFont.preferredFont(forTextStyle: .footnote).withTraits(.traitBold)]))
        attributed.append(
            NSAttributedString(
                string: call.status.rawValue,
                attributes: [
                    .foregroundColor: statusColor,
                    .font: UIFont.preferredFont(forTextStyle: .caption1),
                ]))
        if linkable, let chevron = UIImage(
            systemName: "chevron.right.circle.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))?
            .withTintColor(Theme.Color.accent, renderingMode: .alwaysOriginal)
        {
            attributed.append(NSAttributedString(string: "  "))
            attributed.append(NSAttributedString(attachment: NSTextAttachment(image: chevron)))
        }
        header.attributedText = attributed

        let column = UIStackView(arrangedSubviews: [header])
        column.axis = .vertical
        column.spacing = 2

        if let todos = Self.todoChecklist(for: call) {
            column.addArrangedSubview(todos)
        } else {
            addBody(of: call, summary: summary, to: column)
        }
        if linkable {
            tappableRows.append((column, { [weak self] in self?.onToolTap?(call) }))
        }
        return column
    }

    /// Lays out a tool's expanded body from its semantic summary: the human
    /// title, the exact command or file, and only output worth reading.
    private func addBody(of call: ToolCall, summary: ToolCallSummary, to column: UIStackView) {
        switch summary.kind {
        case .taskTracking:
            if let line = Self.taskGlyphLine(call, summary) {
                column.addArrangedSubview(Self.bodyLabel(attributed: line, lines: 3))
            }
        case .subagent:
            if let title = summary.title ?? Self.fallbackTitle(call) {
                let text = summary.detail.map { "\(title) · \($0)" } ?? title
                column.addArrangedSubview(
                    Self.bodyLabel(
                        attributed: Self.summaryLine(
                            "point.3.connected.trianglepath.dotted", Theme.Color.accent, text),
                        lines: 3))
            }
            if let output = summary.displayOutput {
                column.addArrangedSubview(Self.outputLabel(output))
            }
        case .workflow:
            column.addArrangedSubview(
                Self.bodyLabel(
                    attributed: Self.summaryLine(
                        "point.3.connected.trianglepath.dotted", Theme.Color.accent,
                        summary.title.map { String(localized: "Workflow · \($0)") }
                            ?? String(localized: "Workflow")),
                    lines: 2))
        case .question:
            if let title = summary.title {
                column.addArrangedSubview(
                    Self.bodyLabel(
                        attributed: Self.summaryLine("questionmark.bubble", .systemYellow, title),
                        lines: 4))
            }
            if let answer = summary.detail {
                column.addArrangedSubview(
                    Self.bodyLabel(
                        attributed: Self.summaryLine(
                            "checkmark.circle.fill", Theme.Color.success, answer),
                        lines: 3))
            } else {
                for label in Self.questionOptions(call).prefix(4) {
                    column.addArrangedSubview(Self.titleLabel("• \(label)"))
                }
            }
            if let output = summary.displayOutput {
                column.addArrangedSubview(Self.outputLabel(output))
            }
        case .skill:
            let name = summary.title ?? String(localized: "Skill")
            let text =
                String(localized: "Skill · \(name)") + (summary.detail.map { " \($0)" } ?? "")
            column.addArrangedSubview(
                Self.bodyLabel(
                    attributed: Self.summaryLine("wand.and.stars", Theme.Color.accent, text),
                    lines: 2))
        case .shell:
            if let title = summary.title ?? Self.fallbackTitle(call),
                title != summary.command.map(Self.firstLine)
            {
                column.addArrangedSubview(Self.titleLabel(title))
            }
            if let command = summary.command {
                column.addArrangedSubview(Self.commandLabel(command))
            }
            if let output = summary.displayOutput {
                column.addArrangedSubview(Self.outputLabel(output))
            }
        case .fileRead, .fileEdit, .fileWrite:
            if let line = Self.fileLine(summary) {
                column.addArrangedSubview(Self.bodyLabel(attributed: line, lines: 1))
            } else if let title = Self.fallbackTitle(call) {
                column.addArrangedSubview(Self.titleLabel(title))
            }
            if let directory = summary.detail, !directory.isEmpty {
                column.addArrangedSubview(Self.pathLabel(directory))
            }
            if let output = summary.displayOutput {
                column.addArrangedSubview(Self.outputLabel(output))
            }
            if let diff = Self.editDiff(for: call) {
                let diffLabel = UILabel()
                diffLabel.numberOfLines = 0
                diffLabel.lineBreakMode = .byCharWrapping
                diffLabel.attributedText = diff
                column.addArrangedSubview(diffLabel)
            }
        case .webSearch:
            if let query = summary.title {
                column.addArrangedSubview(Self.titleLabel(query))
            }
            for link in summary.links.prefix(4) {
                column.addArrangedSubview(linkRow(link))
            }
            if summary.links.count > 4 {
                column.addArrangedSubview(
                    Self.pathLabel(String(localized: "+\(summary.links.count - 4) more results")))
            }
        case .webFetch, .fileSearch, .other:
            if let title = summary.title ?? Self.fallbackTitle(call) {
                column.addArrangedSubview(Self.titleLabel(title))
            }
            if let detail = summary.detail {
                column.addArrangedSubview(Self.pathLabel(detail))
            }
            if let output = summary.displayOutput {
                column.addArrangedSubview(Self.outputLabel(output))
            }
        }
    }

    /// The options an unanswered ask is offering, so the transcript shows what
    /// the agent is waiting on even when the answer card has scrolled away.
    private static func questionOptions(_ call: ToolCall) -> [String] {
        QuestionRequest(toolCall: call, sessionID: "")?
            .questions.flatMap { $0.options.map(\.label) } ?? []
    }

    /// opencode tools annotate calls with a server-written `title` instead of
    /// structured input; surface it when the summary extracted nothing.
    static func fallbackTitle(_ call: ToolCall) -> String? {
        guard let title = call.title, title != call.name, !title.isEmpty else { return nil }
        return title
    }

    private static func taskGlyphLine(
        _ call: ToolCall, _ summary: ToolCallSummary
    ) -> NSAttributedString? {
        guard let title = summary.title else { return nil }
        let isCreate = call.name.lowercased().contains("create")
        let glyph: (String, UIColor)
        switch summary.detail {
        case "completed": glyph = ("checkmark.circle.fill", Theme.Color.success)
        case "in progress": glyph = ("circle.lefthalf.filled", Theme.Color.accent)
        case "deleted": glyph = ("trash.circle", Theme.Color.danger)
        default:
            glyph = isCreate
                ? ("plus.circle.fill", Theme.Color.accent) : ("circle", Theme.Color.tertiaryLabel)
        }
        var text = title
        if let status = summary.detail, !isCreate { text += " → \(status)" }
        return summaryLine(glyph.0, glyph.1, text)
    }

    private static func fileLine(_ summary: ToolCallSummary) -> NSAttributedString? {
        guard let name = summary.title else { return nil }
        let line = NSMutableAttributedString(
            string: name,
            attributes: [
                .font: UIFont.preferredFont(forTextStyle: .footnote).withTraits(.traitBold),
                .foregroundColor: Theme.Color.label,
            ])
        if let metric = summary.metric {
            line.append(NSAttributedString(
                string: "  ·  \(metric)",
                attributes: [
                    .font: UIFont.preferredFont(forTextStyle: .caption1),
                    .foregroundColor: Theme.Color.secondaryLabel,
                ]))
        }
        if let stats = summary.diffStats {
            if stats.added > 0 {
                line.append(NSAttributedString(
                    string: "  +\(stats.added)",
                    attributes: [
                        .font: Theme.Font.mono(11),
                        .foregroundColor: Theme.Color.success,
                    ]))
            }
            if stats.removed > 0 {
                line.append(NSAttributedString(
                    string: "  −\(stats.removed)",
                    attributes: [
                        .font: Theme.Font.mono(11),
                        .foregroundColor: Theme.Color.danger,
                    ]))
            }
        }
        return line
    }

    private func linkRow(_ link: ToolCallSummary.Link) -> UIView {
        let label = UILabel()
        label.numberOfLines = 2
        let attributed = NSMutableAttributedString()
        if let icon = UIImage(
            systemName: "link",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold))?
            .withTintColor(Theme.Color.accent, renderingMode: .alwaysOriginal)
        {
            attributed.append(NSAttributedString(attachment: NSTextAttachment(image: icon)))
            attributed.append(NSAttributedString(string: " "))
        }
        attributed.append(NSAttributedString(
            string: link.title,
            attributes: [
                .font: UIFont.preferredFont(forTextStyle: .footnote),
                .foregroundColor: Theme.Color.accent,
            ]))
        if let host = link.url.host {
            attributed.append(NSAttributedString(
                string: "  \(host)",
                attributes: [
                    .font: UIFont.preferredFont(forTextStyle: .caption2),
                    .foregroundColor: Theme.Color.tertiaryLabel,
                ]))
        }
        label.attributedText = attributed
        if onLinkTap != nil {
            tappableRows.append((label, { [weak self] in self?.onLinkTap?(link.url) }))
        }
        return label
    }

    static func bodyLabel(attributed: NSAttributedString, lines: Int) -> UILabel {
        let label = UILabel()
        label.numberOfLines = lines
        label.attributedText = attributed
        return label
    }

    static func titleLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 2
        label.font = .preferredFont(forTextStyle: .footnote)
        label.textColor = Theme.Color.label
        label.text = text
        return label
    }

    static func pathLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 1
        label.lineBreakMode = .byTruncatingHead
        label.font = .preferredFont(forTextStyle: .caption2)
        label.textColor = Theme.Color.tertiaryLabel
        label.text = text
        return label
    }

    private static func commandLabel(_ command: String) -> UILabel {
        let label = UILabel()
        label.numberOfLines = 4
        label.lineBreakMode = .byTruncatingTail
        label.font = Theme.Font.mono(11)
        label.textColor = Theme.Color.label
        let attributed = NSMutableAttributedString(
            string: "$ ",
            attributes: [
                .font: Theme.Font.mono(11),
                .foregroundColor: Theme.Color.tertiaryLabel,
            ])
        attributed.append(NSAttributedString(
            string: command,
            attributes: [
                .font: Theme.Font.mono(11),
                .foregroundColor: Theme.Color.label,
            ]))
        label.attributedText = attributed
        return label
    }

    static func outputLabel(_ text: String) -> UILabel {
        let label = UILabel()
        label.font = Theme.Font.mono(11)
        label.textColor = Theme.Color.secondaryLabel
        label.numberOfLines = 10
        label.lineBreakMode = .byTruncatingTail
        label.text = text
        return label
    }

    private static func firstLine(_ text: String) -> String {
        text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? text
    }

    static func summaryLine(
        _ symbol: String, _ color: UIColor, _ text: String
    ) -> NSAttributedString {
        let attributed = NSMutableAttributedString()
        if let image = UIImage(
            systemName: symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))?
            .withTintColor(color, renderingMode: .alwaysOriginal)
        {
            attributed.append(NSAttributedString(attachment: NSTextAttachment(image: image)))
            attributed.append(NSAttributedString(string: "  "))
        }
        attributed.append(NSAttributedString(
            string: text,
            attributes: [
                .font: UIFont.preferredFont(forTextStyle: .footnote),
                .foregroundColor: Theme.Color.label,
            ]))
        return attributed
    }

    /// Renders the agent's task list from a TodoWrite tool call as a live checklist.
    private static func todoChecklist(for call: ToolCall) -> UIView? {
        guard call.name.localizedCaseInsensitiveContains("Todo"), let input = call.input,
            case .array(let todos) = input["todos"]
        else { return nil }
        let stack = UIStackView()
        stack.axis = .vertical
        stack.spacing = 4
        for todo in todos {
            let content = (todo["content"] ?? todo["activeForm"])?.stringValue ?? ""
            guard !content.isEmpty else { continue }
            let status = todo["status"]?.stringValue ?? "pending"
            let symbol: String
            let color: UIColor
            let done: Bool
            switch status {
            case "completed": symbol = "checkmark.circle.fill"; color = Theme.Color.success; done = true
            case "in_progress": symbol = "circle.lefthalf.filled"; color = Theme.Color.accent; done = false
            default: symbol = "circle"; color = Theme.Color.tertiaryLabel; done = false
            }
            let label = UILabel()
            label.numberOfLines = 0
            let attributed = NSMutableAttributedString()
            if let image = UIImage(
                systemName: symbol, withConfiguration:
                    UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))?
                .withTintColor(color, renderingMode: .alwaysOriginal)
            {
                let attachment = NSTextAttachment(image: image)
                attributed.append(NSAttributedString(attachment: attachment))
            }
            var textAttrs: [NSAttributedString.Key: Any] = [
                .font: UIFont.preferredFont(forTextStyle: .footnote),
                .foregroundColor: done ? Theme.Color.tertiaryLabel : Theme.Color.label,
            ]
            if done { textAttrs[.strikethroughStyle] = NSUnderlineStyle.single.rawValue }
            attributed.append(NSAttributedString(string: "  \(content)", attributes: textAttrs))
            label.attributedText = attributed
            stack.addArrangedSubview(label)
        }
        return stack.arrangedSubviews.isEmpty ? nil : stack
    }

    /// Renders a red/green unified diff for Edit/Write tool calls from their structured input.
    private static func editDiff(for call: ToolCall) -> NSAttributedString? {
        let editors = ["Edit", "Write", "MultiEdit", "str_replace", "str_replace_editor", "create"]
        guard editors.contains(where: { call.name.localizedCaseInsensitiveContains($0) }),
            let input = call.input
        else { return nil }
        let mono = Theme.Font.mono(11)
        let result = NSMutableAttributedString()
        func append(_ text: String, prefix: String, color: UIColor) {
            for line in text.components(separatedBy: "\n") {
                result.append(
                    NSAttributedString(
                        string: "\(prefix)\(line)\n",
                        attributes: [
                            .font: mono, .foregroundColor: color,
                            .backgroundColor: color.withAlphaComponent(0.12),
                        ]))
            }
        }
        if let old = input["old_string"]?.stringValue { append(old, prefix: "- ", color: Theme.Color.danger) }
        if let new = input["new_string"]?.stringValue { append(new, prefix: "+ ", color: Theme.Color.success) }
        if let content = input["content"]?.stringValue, input["new_string"] == nil {
            append(content, prefix: "+ ", color: Theme.Color.success)
        }
        return result.length > 0 ? result : nil
    }
}
