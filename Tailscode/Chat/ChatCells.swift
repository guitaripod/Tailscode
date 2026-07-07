import CodingAgentKit
import UIKit

struct ChatRow: Hashable {
    let id: String
    let messageID: String
    let role: MessageRole
    let content: Content

    enum Content: Hashable {
        case text(String)
        case code(CodeBlock)
        case activity([ActivityStep])
        case file(FileReference)
    }
}

enum ActivityStep: Hashable {
    case reasoning(String)
    case tool(ToolCall)
}

struct CodeBlock: Hashable {
    let language: String?
    let source: String
}

enum MessageSegment {
    case text(String)
    case code(CodeBlock)

    /// Splits assistant text into prose and fenced ``` code blocks, preserving order.
    static func split(_ text: String) -> [MessageSegment] {
        guard text.contains("```") else { return [.text(text)] }
        var segments: [MessageSegment] = []
        var lines = text.components(separatedBy: "\n")[...]
        var prose: [String] = []
        func flushProse() {
            let joined = prose.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { segments.append(.text(joined)) }
            prose = []
        }
        while let line = lines.first {
            lines = lines.dropFirst()
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                flushProse()
                let language = line.trimmingCharacters(in: .whitespaces)
                    .dropFirst(3).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                while let next = lines.first, !next.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    code.append(next)
                    lines = lines.dropFirst()
                }
                if !lines.isEmpty { lines = lines.dropFirst() }
                segments.append(
                    .code(CodeBlock(language: language.isEmpty ? nil : language,
                        source: code.joined(separator: "\n"))))
            } else {
                prose.append(line)
            }
        }
        flushProse()
        return segments.isEmpty ? [.text(text)] : segments
    }
}

final class TextBubbleCell: UICollectionViewCell {
    static let reuseID = "TextBubbleCell"

    private let bubble = UIView()
    private let label = UILabel()
    private var leadingPin: NSLayoutConstraint!
    private var trailingPin: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        bubble.layer.cornerRadius = Theme.Radius.bubble
        bubble.layer.cornerCurve = .continuous
        bubble.translatesAutoresizingMaskIntoConstraints = false
        label.numberOfLines = 0
        label.translatesAutoresizingMaskIntoConstraints = false
        label.adjustsFontForContentSizeCategory = true
        contentView.addSubview(bubble)
        bubble.addSubview(label)

        leadingPin = bubble.leadingAnchor.constraint(
            equalTo: contentView.leadingAnchor, constant: Theme.Spacing.l)
        trailingPin = bubble.trailingAnchor.constraint(
            equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.l)

        NSLayoutConstraint.activate([
            bubble.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Spacing.xs),
            bubble.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Theme.Spacing.xs),
            bubble.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.82),
            bubble.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor, constant: Theme.Spacing.l),
            bubble.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor, constant: -Theme.Spacing.l),
            label.topAnchor.constraint(equalTo: bubble.topAnchor, constant: Theme.Spacing.s),
            label.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -Theme.Spacing.s),
            label.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: Theme.Spacing.m),
            label.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -Theme.Spacing.m),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        contentView.alpha = 1
    }

    func configure(text: String, role: MessageRole, reasoning: Bool) {
        let isUser = role == .user
        leadingPin.isActive = !isUser
        trailingPin.isActive = isUser

        if reasoning {
            bubble.backgroundColor = .clear
            label.textColor = Theme.Color.secondaryLabel
            label.font = UIFont.preferredFont(forTextStyle: .subheadline).withTraits(.traitItalic)
            label.text = text
        } else if isUser {
            bubble.backgroundColor = Theme.Color.userBubble
            label.textColor = .white
            label.font = Theme.Font.body()
            label.text = text
        } else {
            bubble.backgroundColor = Theme.Color.assistantBubble
            label.textColor = Theme.Color.label
            label.font = Theme.Font.body()
            label.attributedText = Self.rendered(text, color: Theme.Color.label)
        }
    }

    /// Renders inline markdown (bold/italic/code/links) while preserving whitespace, and styles
    /// inline `code` spans with a monospaced font and a subtle fill.
    private static let renderCache: NSCache<NSString, NSAttributedString> = {
        let cache = NSCache<NSString, NSAttributedString>()
        cache.countLimit = 200
        return cache
    }()

    static func rendered(_ text: String, color: UIColor) -> NSAttributedString {
        let key = text as NSString
        if let cached = renderCache.object(forKey: key) { return cached }
        let base = Theme.Font.body()
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        let result: NSAttributedString
        if var attr = try? AttributedString(markdown: text, options: options) {
            attr.font = base
            attr.foregroundColor = color
            for run in attr.runs where run.inlinePresentationIntent?.contains(.code) == true {
                attr[run.range].font = Theme.Font.mono(base.pointSize - 1)
                attr[run.range].backgroundColor = Theme.Color.reasoningBackground
            }
            result = NSAttributedString(attr)
        } else {
            result = NSAttributedString(string: text, attributes: [.font: base, .foregroundColor: color])
        }
        renderCache.setObject(result, forKey: key)
        return result
    }
}

/// An inline, in-stream approval card for a pending tool permission — replaces the blocking alert
/// so the decision reads next to the action it authorizes.
final class PermissionCell: UICollectionViewCell {
    static let reuseID = "PermissionCell"

    private let bar = Theme.Glass.view()
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let allowButton = UIButton(type: .system)
    private let alwaysButton = UIButton(type: .system)
    private let denyButton = UIButton(type: .system)
    private var onDecision: ((PermissionDecision) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        bar.translatesAutoresizingMaskIntoConstraints = false
        bar.layer.cornerRadius = Theme.Radius.card
        bar.layer.cornerCurve = .continuous
        bar.clipsToBounds = true
        bar.isUserInteractionEnabled = false
        contentView.addSubview(bar)

        iconView.image = UIImage(
            systemName: "hand.raised.fill", withConfiguration:
                UIImage.SymbolConfiguration(pointSize: 14, weight: .semibold))
        iconView.tintColor = Theme.Color.warning
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .preferredFont(forTextStyle: .subheadline).withTraits(.traitBold)
        titleLabel.textColor = Theme.Color.label
        titleLabel.numberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.font = .preferredFont(forTextStyle: .footnote)
        detailLabel.textColor = Theme.Color.secondaryLabel
        detailLabel.numberOfLines = 0
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        configureButton(allowButton, title: "Allow once", tint: Theme.Color.accent, filled: true)
        configureButton(alwaysButton, title: "Always", tint: Theme.Color.accent, filled: false)
        configureButton(denyButton, title: "Deny", tint: Theme.Color.danger, filled: false)
        allowButton.addTarget(self, action: #selector(allowTapped), for: .touchUpInside)
        alwaysButton.addTarget(self, action: #selector(alwaysTapped), for: .touchUpInside)
        denyButton.addTarget(self, action: #selector(denyTapped), for: .touchUpInside)

        let buttons = UIStackView(arrangedSubviews: [allowButton, alwaysButton, denyButton])
        buttons.axis = .horizontal
        buttons.spacing = Theme.Spacing.s
        buttons.distribution = .fillEqually
        buttons.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(iconView)
        contentView.addSubview(titleLabel)
        contentView.addSubview(detailLabel)
        contentView.addSubview(buttons)

        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Spacing.xs),
            bar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Theme.Spacing.xs),
            bar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Spacing.l),
            bar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.l),

            iconView.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: Theme.Spacing.m),
            iconView.topAnchor.constraint(equalTo: bar.topAnchor, constant: Theme.Spacing.m),
            iconView.widthAnchor.constraint(equalToConstant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: Theme.Spacing.s),
            titleLabel.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -Theme.Spacing.m),

            detailLabel.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: Theme.Spacing.s),
            detailLabel.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: Theme.Spacing.m),
            detailLabel.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -Theme.Spacing.m),

            buttons.topAnchor.constraint(equalTo: detailLabel.bottomAnchor, constant: Theme.Spacing.m),
            buttons.leadingAnchor.constraint(equalTo: bar.leadingAnchor, constant: Theme.Spacing.m),
            buttons.trailingAnchor.constraint(equalTo: bar.trailingAnchor, constant: -Theme.Spacing.m),
            buttons.bottomAnchor.constraint(equalTo: bar.bottomAnchor, constant: -Theme.Spacing.m),
            buttons.heightAnchor.constraint(equalToConstant: 40),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func configureButton(_ button: UIButton, title: String, tint: UIColor, filled: Bool) {
        var config = filled ? UIButton.Configuration.filled() : UIButton.Configuration.tinted()
        config.title = title
        config.baseBackgroundColor = tint
        config.baseForegroundColor = filled ? .white : tint
        config.cornerStyle = .large
        config.buttonSize = .medium
        button.configuration = config
        button.translatesAutoresizingMaskIntoConstraints = false
    }

    func configure(title: String, detail: String, onDecision: @escaping (PermissionDecision) -> Void) {
        titleLabel.text = title
        detailLabel.text = detail
        self.onDecision = onDecision
    }

    @objc private func allowTapped() { Theme.Haptics.success(); onDecision?(.once) }
    @objc private func alwaysTapped() { Theme.Haptics.success(); onDecision?(.always) }
    @objc private func denyTapped() { Theme.Haptics.warning(); onDecision?(.reject) }
}

/// Renders a fenced code block with a language header, one-tap raw copy, and collapse for long
/// blocks — a native client owning the exact clipboard string.
final class CodeBlockCell: UICollectionViewCell {
    static let reuseID = "CodeBlockCell"
    private static let collapsedLineLimit = 14

    private let container = UIView()
    private let langLabel = UILabel()
    private let copyButton = UIButton(type: .system)
    private let codeLabel = UILabel()
    private let toggleButton = UIButton(type: .system)
    private var source = ""
    private var onToggle: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        container.backgroundColor = Theme.Color.codeBackground
        container.layer.cornerRadius = Theme.Radius.card
        container.layer.cornerCurve = .continuous
        container.translatesAutoresizingMaskIntoConstraints = false

        langLabel.font = Theme.Font.mono(11)
        langLabel.textColor = Theme.Color.tertiaryLabel
        langLabel.translatesAutoresizingMaskIntoConstraints = false

        var copyConfig = UIButton.Configuration.plain()
        copyConfig.image = UIImage(
            systemName: "doc.on.doc", withConfiguration:
                UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        copyConfig.baseForegroundColor = Theme.Color.secondaryLabel
        copyConfig.contentInsets = .zero
        copyButton.configuration = copyConfig
        copyButton.translatesAutoresizingMaskIntoConstraints = false
        copyButton.addTarget(self, action: #selector(copyTapped), for: .touchUpInside)

        codeLabel.numberOfLines = 0
        codeLabel.font = Theme.Font.mono(12)
        codeLabel.textColor = Theme.Color.label
        codeLabel.lineBreakMode = .byCharWrapping
        codeLabel.translatesAutoresizingMaskIntoConstraints = false

        toggleButton.titleLabel?.font = .preferredFont(forTextStyle: .caption1)
        toggleButton.setTitleColor(Theme.Color.accent, for: .normal)
        toggleButton.contentHorizontalAlignment = .leading
        toggleButton.translatesAutoresizingMaskIntoConstraints = false
        toggleButton.addTarget(self, action: #selector(toggleTapped), for: .touchUpInside)

        contentView.addSubview(container)
        [langLabel, copyButton, codeLabel, toggleButton].forEach(container.addSubview)

        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Spacing.xs),
            container.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Theme.Spacing.xs),
            container.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Spacing.l),
            container.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.l),

            langLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: Theme.Spacing.s),
            langLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Theme.Spacing.m),
            copyButton.centerYAnchor.constraint(equalTo: langLabel.centerYAnchor),
            copyButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Theme.Spacing.m),

            codeLabel.topAnchor.constraint(equalTo: langLabel.bottomAnchor, constant: Theme.Spacing.xs),
            codeLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Theme.Spacing.m),
            codeLabel.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Theme.Spacing.m),

            toggleButton.topAnchor.constraint(equalTo: codeLabel.bottomAnchor, constant: Theme.Spacing.xs),
            toggleButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Theme.Spacing.m),
            toggleButton.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -Theme.Spacing.m),
            toggleButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Theme.Spacing.s),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(_ block: CodeBlock, expanded: Bool, onToggle: @escaping () -> Void) {
        self.source = block.source
        self.onToggle = onToggle
        langLabel.text = (block.language ?? "code").lowercased()
        let lines = block.source.components(separatedBy: "\n")
        let isLong = lines.count > Self.collapsedLineLimit
        if isLong && !expanded {
            codeLabel.text = lines.prefix(Self.collapsedLineLimit).joined(separator: "\n")
            toggleButton.setTitle("Show all \(lines.count) lines", for: .normal)
            toggleButton.isHidden = false
        } else {
            codeLabel.text = block.source
            toggleButton.setTitle("Collapse", for: .normal)
            toggleButton.isHidden = !isLong
        }
    }

    @objc private func copyTapped() {
        UIPasteboard.general.string = source
        Theme.Haptics.success()
        var config = copyButton.configuration
        config?.image = UIImage(
            systemName: "checkmark", withConfiguration:
                UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        copyButton.configuration = config
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            guard let self else { return }
            var reset = copyButton.configuration
            reset?.image = UIImage(
                systemName: "doc.on.doc", withConfiguration:
                    UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
            copyButton.configuration = reset
        }
    }

    @objc private func toggleTapped() {
        Theme.Haptics.selection()
        onToggle?()
    }
}

/// Folds a run of consecutive agent actions (thinking + tool calls) into one compact,
/// collapsible cell so the transcript stays clean; expand to see each step.
final class ActivityGroupCell: UICollectionViewCell {
    static let reuseID = "ActivityGroupCell"

    private let container = UIView()
    private let iconView = UIImageView()
    private let summaryLabel = UILabel()
    private let chevron = UIImageView()
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let stack = UIStackView()
    private let toggle = UIButton(type: .system)
    private var onToggle: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        container.layer.cornerRadius = Theme.Radius.card
        container.layer.cornerCurve = .continuous
        container.translatesAutoresizingMaskIntoConstraints = false

        let glass = Theme.Glass.view()
        glass.isUserInteractionEnabled = false
        glass.layer.cornerRadius = Theme.Radius.card
        glass.layer.cornerCurve = .continuous
        glass.clipsToBounds = true
        glass.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(glass)
        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: container.topAnchor),
            glass.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: container.trailingAnchor),
        ])

        iconView.tintColor = Theme.Color.accent
        iconView.contentMode = .scaleAspectFit
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.translatesAutoresizingMaskIntoConstraints = false

        summaryLabel.font = .preferredFont(forTextStyle: .subheadline).withTraits(.traitBold)
        summaryLabel.textColor = Theme.Color.secondaryLabel
        summaryLabel.adjustsFontForContentSizeCategory = true
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false

        chevron.image = UIImage(
            systemName: "chevron.down",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        chevron.tintColor = Theme.Color.tertiaryLabel
        chevron.contentMode = .scaleAspectFit
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        chevron.translatesAutoresizingMaskIntoConstraints = false

        spinner.hidesWhenStopped = true
        spinner.translatesAutoresizingMaskIntoConstraints = false

        stack.axis = .vertical
        stack.spacing = Theme.Spacing.s
        stack.translatesAutoresizingMaskIntoConstraints = false

        toggle.translatesAutoresizingMaskIntoConstraints = false
        toggle.addTarget(self, action: #selector(toggleTapped), for: .touchUpInside)

        contentView.addSubview(container)
        [iconView, summaryLabel, spinner, chevron, stack, toggle].forEach(container.addSubview)

        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Spacing.xs),
            container.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Theme.Spacing.xs),
            container.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Spacing.l),
            container.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.l),

            iconView.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Theme.Spacing.m),
            iconView.topAnchor.constraint(equalTo: container.topAnchor, constant: Theme.Spacing.m),
            iconView.widthAnchor.constraint(equalToConstant: 16),
            iconView.heightAnchor.constraint(equalToConstant: 16),
            summaryLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: Theme.Spacing.s),
            summaryLabel.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            spinner.leadingAnchor.constraint(greaterThanOrEqualTo: summaryLabel.trailingAnchor, constant: Theme.Spacing.s),
            spinner.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            chevron.leadingAnchor.constraint(equalTo: spinner.trailingAnchor, constant: Theme.Spacing.s),
            chevron.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Theme.Spacing.m),
            chevron.centerYAnchor.constraint(equalTo: iconView.centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 12),

            stack.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: Theme.Spacing.s),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Theme.Spacing.m),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Theme.Spacing.m),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Theme.Spacing.m),

            toggle.topAnchor.constraint(equalTo: container.topAnchor),
            toggle.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            toggle.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            toggle.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(
        steps: [ActivityStep], expanded: Bool, streaming: Bool, onToggle: @escaping () -> Void
    ) {
        self.onToggle = onToggle
        iconView.image = UIImage(
            systemName: streaming ? "gearshape.2.fill" : "sparkles",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        summaryLabel.text = Self.summary(steps, streaming: streaming)
        chevron.transform = expanded ? CGAffineTransform(rotationAngle: .pi) : .identity
        if streaming { spinner.startAnimating() } else { spinner.stopAnimating() }

        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        stack.isHidden = !expanded
        if expanded {
            for step in steps { stack.addArrangedSubview(Self.stepView(step)) }
        }
    }

    private static func summary(_ steps: [ActivityStep], streaming: Bool) -> String {
        if streaming, let last = steps.last {
            switch last {
            case .tool(let call): return "\(call.name)…"
            case .reasoning: return "Thinking…"
            }
        }
        var names: [String] = []
        var hasThinking = false
        for step in steps {
            switch step {
            case .tool(let call): if !names.contains(call.name) { names.append(call.name) }
            case .reasoning: hasThinking = true
            }
        }
        var parts: [String] = []
        if hasThinking { parts.append("Thought") }
        if !names.isEmpty {
            let shown = names.prefix(3).joined(separator: " · ")
            parts.append(names.count > 3 ? "\(shown) +\(names.count - 3)" : shown)
        }
        return parts.isEmpty ? "\(steps.count) steps" : parts.joined(separator: "  ·  ")
    }

    private static func stepView(_ step: ActivityStep) -> UIView {
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

    private static func toolView(_ call: ToolCall) -> UIView {
        let color: UIColor
        switch call.status {
        case .pending, .running: color = Theme.Color.warning
        case .completed: color = Theme.Color.success
        case .error: color = Theme.Color.danger
        }
        let header = UILabel()
        header.numberOfLines = 1
        let attributed = NSMutableAttributedString(
            string: "● ",
            attributes: [
                .foregroundColor: color,
                .font: UIFont.preferredFont(forTextStyle: .caption2),
            ])
        attributed.append(
            NSAttributedString(
                string: "\(call.name)  ",
                attributes: [.font: UIFont.preferredFont(forTextStyle: .footnote).withTraits(.traitBold)]))
        attributed.append(
            NSAttributedString(
                string: call.status.rawValue,
                attributes: [
                    .foregroundColor: color,
                    .font: UIFont.preferredFont(forTextStyle: .caption1),
                ]))
        header.attributedText = attributed

        let column = UIStackView(arrangedSubviews: [header])
        column.axis = .vertical
        column.spacing = 2

        if let todos = todoChecklist(for: call) {
            column.addArrangedSubview(todos)
        } else if let diff = editDiff(for: call) {
            let diffLabel = UILabel()
            diffLabel.numberOfLines = 0
            diffLabel.lineBreakMode = .byCharWrapping
            diffLabel.attributedText = diff
            column.addArrangedSubview(diffLabel)
        } else {
            let body = call.output ?? (call.title == call.name ? "" : (call.title ?? ""))
            if !body.isEmpty {
                let output = UILabel()
                output.font = Theme.Font.mono(11)
                output.textColor = Theme.Color.secondaryLabel
                output.numberOfLines = 10
                output.lineBreakMode = .byTruncatingTail
                output.text = body
                column.addArrangedSubview(output)
            }
        }
        return column
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
            case "in_progress": symbol = "circle.lefthalf.filled"; color = Theme.Color.warning; done = false
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

    @objc private func toggleTapped() {
        Theme.Haptics.selection()
        onToggle?()
    }
}

extension UIFont {
    func withTraits(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(traits))
        else { return self }
        return UIFont(descriptor: descriptor, size: 0)
    }
}
