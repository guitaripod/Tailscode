import CodingAgentKit
import UIKit

@MainActor
protocol TextBubbleCellDelegate: AnyObject {
    func textBubbleCell(_ cell: TextBubbleCell, didTapLink url: URL)
}

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
        case timestamp(String)
        case error(String)
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
    weak var linkDelegate: TextBubbleCellDelegate?

    private let bubble = UIView()
    private let textView = UITextView()
    private var leadingPin: NSLayoutConstraint!
    private var trailingPin: NSLayoutConstraint!
    private var timestampLeading: NSLayoutConstraint?
    private var timestampTrailing: NSLayoutConstraint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        bubble.layer.cornerRadius = Theme.Radius.bubble
        bubble.layer.cornerCurve = .continuous
        bubble.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = false
        textView.isScrollEnabled = false
        textView.isSelectable = true
        textView.dataDetectorTypes = [.link]
        textView.backgroundColor = .clear
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.adjustsFontForContentSizeCategory = true
        textView.delegate = self
        contentView.addSubview(bubble)
        bubble.addSubview(textView)

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
            textView.topAnchor.constraint(equalTo: bubble.topAnchor, constant: Theme.Spacing.s),
            textView.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -Theme.Spacing.s),
            textView.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: Theme.Spacing.m),
            textView.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -Theme.Spacing.m),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        contentView.alpha = 1
        textView.textAlignment = .natural
        timestampLeading?.isActive = false
        timestampTrailing?.isActive = false
    }

    func configureError(_ text: String) {
        timestampLeading?.isActive = false
        timestampTrailing?.isActive = false
        leadingPin.isActive = true
        trailingPin.isActive = false
        textView.textAlignment = .natural
        bubble.backgroundColor = Theme.Color.danger.withAlphaComponent(0.08)
        textView.font = .preferredFont(forTextStyle: .footnote)
        textView.textColor = Theme.Color.danger
        let attachment = NSTextAttachment(
            image: UIImage(
                systemName: "exclamationmark.triangle.fill",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))!
                .withTintColor(Theme.Color.danger))
        let string = NSMutableAttributedString(attachment: attachment)
        string.append(NSAttributedString(
            string: "  \(text)",
            attributes: [
                .font: UIFont.preferredFont(forTextStyle: .footnote),
                .foregroundColor: Theme.Color.danger,
            ]))
        textView.attributedText = string
    }

    func configure(text: String, role: MessageRole, reasoning: Bool, timestamp: Bool = false) {
        let isUser = role == .user

        timestampLeading?.isActive = false
        timestampTrailing?.isActive = false

        if timestamp {
            bubble.backgroundColor = .clear
            textView.textColor = Theme.Color.tertiaryLabel
            textView.font = .preferredFont(forTextStyle: .caption2)
            textView.textAlignment = .center
            textView.text = text
            leadingPin.isActive = false
            trailingPin.isActive = false
            if timestampLeading == nil {
                timestampLeading = bubble.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Spacing.l)
                timestampTrailing = bubble.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.l)
            }
            timestampLeading?.isActive = true
            timestampTrailing?.isActive = true
            return
        }

        leadingPin.isActive = !isUser
        trailingPin.isActive = isUser
        textView.textAlignment = .natural

        if reasoning {
            bubble.backgroundColor = .clear
            textView.textColor = Theme.Color.secondaryLabel
            textView.font = UIFont.preferredFont(forTextStyle: .subheadline).withTraits(.traitItalic)
            textView.text = text
            textView.linkTextAttributes = [
                .foregroundColor: Theme.Color.secondaryLabel,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ]
        } else if isUser {
            bubble.backgroundColor = Theme.Color.userBubble
            textView.textColor = .white
            textView.font = Theme.Font.body()
            textView.text = text
            textView.linkTextAttributes = [.foregroundColor: UIColor.white]
        } else {
            bubble.backgroundColor = Theme.Color.assistantBubble
            textView.textColor = Theme.Color.label
            textView.font = Theme.Font.body()
            textView.attributedText = Self.rendered(text, color: Theme.Color.label)
            textView.linkTextAttributes = [
                .foregroundColor: Theme.Color.accent,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ]
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
        let key = "\(text)#\(color.description)" as NSString
        if let cached = renderCache.object(forKey: key) { return cached }
        let base = Theme.Font.body()
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        let result: NSAttributedString
        if var attr = try? AttributedString(markdown: text, options: options) {
            attr.font = base
            attr.foregroundColor = color
            let headingFont = UIFont.preferredFont(forTextStyle: .headline).withTraits(.traitBold)
            for run in attr.runs {
                if run.inlinePresentationIntent?.contains(.code) == true {
                    attr[run.range].font = Theme.Font.mono(base.pointSize - 1)
                    attr[run.range].backgroundColor = Theme.Color.reasoningBackground
                }
                if run.inlinePresentationIntent?.contains(.emphasized) == true {
                    attr[run.range].font = base.withTraits(.traitBold)
                }
            }
            let mutable = NSMutableAttributedString(attr)
            var bulletEdits: [NSRange] = []
            var quoteEdits: [NSRange] = []
            mutable.mutableString.enumerateSubstrings(
                in: NSRange(location: 0, length: mutable.length),
                options: .byLines
            ) { _, substringRange, _, _ in
                let line = mutable.attributedSubstring(from: substringRange).string
                if line.hasPrefix("# ") || line.hasPrefix("## ") || line.hasPrefix("### ")
                    || line.hasPrefix("#### ") || line.hasPrefix("##### ") || line.hasPrefix("###### ")
                {
                    mutable.addAttribute(.font, value: headingFont, range: substringRange)
                    return
                }
                let trimmedStart = line.drop { $0 == " " }
                let indentDepth = line.count - trimmedStart.count
                if trimmedStart.hasPrefix("- ") || trimmedStart.hasPrefix("* ") {
                    let paragraph = NSMutableParagraphStyle()
                    paragraph.firstLineHeadIndent = CGFloat(indentDepth) * 6
                    paragraph.headIndent = CGFloat(indentDepth) * 6 + 14
                    mutable.addAttribute(.paragraphStyle, value: paragraph, range: substringRange)
                    bulletEdits.append(
                        NSRange(location: substringRange.location + indentDepth, length: 2))
                } else if trimmedStart.hasPrefix("> ") {
                    let paragraph = NSMutableParagraphStyle()
                    paragraph.firstLineHeadIndent = 12
                    paragraph.headIndent = 12
                    mutable.addAttribute(.paragraphStyle, value: paragraph, range: substringRange)
                    mutable.addAttribute(
                        .foregroundColor, value: Theme.Color.secondaryLabel, range: substringRange)
                    quoteEdits.append(
                        NSRange(location: substringRange.location + indentDepth, length: 2))
                }
            }
            for range in (bulletEdits + quoteEdits).sorted(by: { $0.location > $1.location }) {
                let replacement = bulletEdits.contains(where: { $0.location == range.location })
                    ? "•  " : ""
                mutable.replaceCharacters(in: range, with: replacement)
            }
            result = mutable
        } else {
            result = NSAttributedString(string: text, attributes: [.font: base, .foregroundColor: color])
        }
        renderCache.setObject(result, forKey: key)
        return result
    }
}

extension TextBubbleCell: UITextViewDelegate {
    func textView(
        _ textView: UITextView,
        shouldInteractWith URL: URL,
        in characterRange: NSRange,
        interaction: UITextItemInteraction
    ) -> Bool {
        linkDelegate?.textBubbleCell(self, didTapLink: URL)
        return false
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
    private let codeScroll = UIScrollView()
    private let codeLabel = UILabel()
    private let lineNumberLabel = UILabel()
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

        codeScroll.showsVerticalScrollIndicator = false
        codeScroll.showsHorizontalScrollIndicator = true
        codeScroll.alwaysBounceVertical = false
        codeScroll.translatesAutoresizingMaskIntoConstraints = false

        codeLabel.numberOfLines = 0
        codeLabel.font = Theme.Font.mono(12)
        codeLabel.textColor = Theme.Color.label
        codeLabel.lineBreakMode = .byClipping
        codeLabel.translatesAutoresizingMaskIntoConstraints = false

        lineNumberLabel.numberOfLines = 0
        lineNumberLabel.font = Theme.Font.mono(12)
        lineNumberLabel.textColor = Theme.Color.tertiaryLabel
        lineNumberLabel.textAlignment = .right
        lineNumberLabel.translatesAutoresizingMaskIntoConstraints = false

        toggleButton.titleLabel?.font = .preferredFont(forTextStyle: .caption1)
        toggleButton.setTitleColor(Theme.Color.accent, for: .normal)
        toggleButton.contentHorizontalAlignment = .leading
        toggleButton.translatesAutoresizingMaskIntoConstraints = false
        toggleButton.addTarget(self, action: #selector(toggleTapped), for: .touchUpInside)

        contentView.addSubview(container)
        [langLabel, copyButton, codeScroll, toggleButton].forEach(container.addSubview)
        [lineNumberLabel, codeLabel].forEach(codeScroll.addSubview)

        let content = codeScroll.contentLayoutGuide
        let frame = codeScroll.frameLayoutGuide
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Spacing.xs),
            container.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Theme.Spacing.xs),
            container.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Spacing.l),
            container.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.l),

            langLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: Theme.Spacing.s),
            langLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Theme.Spacing.m),
            copyButton.centerYAnchor.constraint(equalTo: langLabel.centerYAnchor),
            copyButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Theme.Spacing.m),

            codeScroll.topAnchor.constraint(equalTo: langLabel.bottomAnchor, constant: Theme.Spacing.xs),
            codeScroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Theme.Spacing.m),
            codeScroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Theme.Spacing.m),
            frame.heightAnchor.constraint(equalTo: content.heightAnchor),

            lineNumberLabel.topAnchor.constraint(equalTo: content.topAnchor),
            lineNumberLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            lineNumberLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 28),

            codeLabel.topAnchor.constraint(equalTo: content.topAnchor),
            codeLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            codeLabel.leadingAnchor.constraint(equalTo: lineNumberLabel.trailingAnchor, constant: Theme.Spacing.s),
            codeLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -Theme.Spacing.s),

            toggleButton.topAnchor.constraint(equalTo: codeScroll.bottomAnchor, constant: Theme.Spacing.xs),
            toggleButton.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Theme.Spacing.m),
            toggleButton.trailingAnchor.constraint(lessThanOrEqualTo: container.trailingAnchor, constant: -Theme.Spacing.m),
            toggleButton.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -Theme.Spacing.s),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(_ block: CodeBlock, expanded: Bool, onToggle: @escaping () -> Void) {
        self.source = block.source
        self.onToggle = onToggle
        codeScroll.setContentOffset(.zero, animated: false)
        langLabel.text = (block.language ?? "code").lowercased()
        var copyConfig = copyButton.configuration ?? .plain()
        copyConfig.image = UIImage(
            systemName: "doc.on.doc", withConfiguration:
                UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        copyButton.configuration = copyConfig
        let lines = block.source.components(separatedBy: "\n")
        let isLong = lines.count > Self.collapsedLineLimit
        if isLong && !expanded {
            let shortSource = lines.prefix(Self.collapsedLineLimit).joined(separator: "\n")
            codeLabel.attributedText = Self.highlightedCode(shortSource, language: block.language)
            lineNumberLabel.text = Self.lineNumbers(count: Self.collapsedLineLimit)
            toggleButton.setTitle("Show all \(lines.count) lines", for: .normal)
            toggleButton.isHidden = false
        } else {
            codeLabel.attributedText = Self.highlightedCode(block.source, language: block.language)
            lineNumberLabel.text = Self.lineNumbers(count: lines.count)
            toggleButton.setTitle("Collapse", for: .normal)
            toggleButton.isHidden = !isLong
        }
    }

    private static func lineNumbers(count: Int) -> String {
        (1...count).map { "\($0)" }.joined(separator: "\n")
    }

    private static let keywordPatterns: [String] = [
        "\\b(func|var|let|class|struct|enum|protocol|extension|import|return|if|else|guard|switch|case|default|for|while|repeat|in|break|continue|throw|throws|try|catch|do|where|as|is|nil|true|false|self|super|init|deinit|public|private|internal|fileprivate|open|static|final|override|mutating|nonmutating|associatedtype|typealias|some|any|async|await|actor|nonisolated|Task)\\b",
        "\\b(def|return|if|elif|else|for|while|import|from|class|try|except|raise|pass|with|as|in|is|not|and|or|True|False|None|yield|lambda|async|await)\\b",
        "\\b(function|const|let|var|return|if|else|for|while|do|switch|case|break|continue|throw|try|catch|class|extends|import|export|default|new|this|typeof|instanceof|async|await|of|in|from|true|false|null|undefined)\\b",
        "\\b(fn|let|mut|impl|trait|enum|struct|match|if|else|loop|while|for|in|return|use|mod|pub|self|super|where|as|move|async|await|unsafe|dyn|ref|type|true|false|None|Some|Ok|Err|Box|Vec|String|Option|Result)\\b",
    ]

    private static let commentPatterns: [String] = [
        "//[^\n]*",
        "/\\*[\\s\\S]*?\\*/",
        "#[^\n]*",
    ]

    private static let stringPattern = "\"(?:[^\"\\\\]|\\\\.)*\""

    private static let numberPattern = "\\b\\d+\\.?\\d*\\b"

    private static let monoFont = Theme.Font.mono(12)

    static func highlightedCode(_ source: String, language: String?) -> NSAttributedString {
        let result = NSMutableAttributedString(string: source, attributes: [
            .font: monoFont, .foregroundColor: Theme.Color.label,
        ])
        let nsSource = source as NSString
        let range = NSRange(location: 0, length: nsSource.length)

        let lowerLang = (language ?? "").lowercased()
        let kwSet: Set<String>
        if lowerLang == "swift" { kwSet = [keywordPatterns[0]] }
        else if lowerLang == "python" || lowerLang == "py" { kwSet = [keywordPatterns[1]] }
        else if lowerLang == "javascript" || lowerLang == "js" || lowerLang == "typescript" || lowerLang == "ts" { kwSet = [keywordPatterns[2]] }
        else if lowerLang == "rust" || lowerLang == "rs" { kwSet = [keywordPatterns[3]] }
        else { kwSet = [] }

        for pattern in commentPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            regex.enumerateMatches(in: source, range: range) { match, _, _ in
                guard let match else { return }
                result.addAttribute(.foregroundColor, value: Theme.Color.tertiaryLabel, range: match.range)
            }
        }

        guard let stringRegex = try? NSRegularExpression(pattern: stringPattern) else { return result }
        stringRegex.enumerateMatches(in: source, range: range) { match, _, _ in
            guard let match else { return }
            result.addAttribute(.foregroundColor, value: Theme.Color.warning, range: match.range)
        }

        guard let numRegex = try? NSRegularExpression(pattern: numberPattern) else { return result }
        numRegex.enumerateMatches(in: source, range: range) { match, _, _ in
            guard let match else { return }
            result.addAttribute(.foregroundColor, value: UIColor.systemTeal, range: match.range)
        }

        for kwPattern in kwSet {
            guard let regex = try? NSRegularExpression(pattern: kwPattern) else { continue }
            regex.enumerateMatches(in: source, range: range) { match, _, _ in
                guard let match else { return }
                result.addAttribute(.foregroundColor, value: UIColor.systemPink, range: match.range)
            }
        }

        return result
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
            toggle.bottomAnchor.constraint(equalTo: container.bottomAnchor),
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
        var thinkingCount = 0
        for step in steps {
            switch step {
            case .tool(let call): if !names.contains(call.name) { names.append(call.name) }
            case .reasoning: thinkingCount += 1
            }
        }
        var parts: [String] = []
        if thinkingCount == 1 { parts.append("Thought") }
        else if thinkingCount > 1 { parts.append("\(thinkingCount) thoughts") }
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

/// The "agent is working" placeholder shown before any assistant content
/// arrives for the current turn: three softly pulsing dots in a bubble.
final class ThinkingCell: UICollectionViewCell {
    static let reuseID = "ThinkingCell"

    private let bubble = UIView()
    private let dots = (0..<3).map { _ in UIView() }

    override init(frame: CGRect) {
        super.init(frame: frame)
        bubble.backgroundColor = Theme.Color.assistantBubble
        bubble.layer.cornerRadius = Theme.Radius.bubble
        bubble.layer.cornerCurve = .continuous
        bubble.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(bubble)

        let stack = UIStackView(arrangedSubviews: dots)
        stack.axis = .horizontal
        stack.spacing = 5
        stack.translatesAutoresizingMaskIntoConstraints = false
        bubble.addSubview(stack)

        for dot in dots {
            dot.backgroundColor = Theme.Color.secondaryLabel
            dot.layer.cornerRadius = 4
            dot.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                dot.widthAnchor.constraint(equalToConstant: 8),
                dot.heightAnchor.constraint(equalToConstant: 8),
            ])
        }

        NSLayoutConstraint.activate([
            bubble.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Spacing.xs),
            bubble.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor, constant: -Theme.Spacing.xs),
            bubble.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: Theme.Spacing.l),
            bubble.heightAnchor.constraint(equalToConstant: 38),

            stack.centerYAnchor.constraint(equalTo: bubble.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: bubble.leadingAnchor, constant: Theme.Spacing.l),
            stack.trailingAnchor.constraint(equalTo: bubble.trailingAnchor, constant: -Theme.Spacing.l),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { startPulsing() }
    }

    private func startPulsing() {
        for (index, dot) in dots.enumerated() {
            dot.layer.removeAnimation(forKey: "pulse")
            let pulse = CABasicAnimation(keyPath: "opacity")
            pulse.fromValue = 0.25
            pulse.toValue = 1.0
            pulse.duration = 0.55
            pulse.autoreverses = true
            pulse.repeatCount = .infinity
            pulse.timeOffset = Double(index) * 0.18
            dot.layer.add(pulse, forKey: "pulse")
        }
    }
}

/// A native answer card for a structured agent question (opencode's question
/// tool): header chip, question text, tappable options with descriptions,
/// multi-select and free-form support. Selection state lives in the view
/// controller so cell reconfiguration can't drop an in-progress choice.
final class QuestionCell: UICollectionViewCell {
    static let reuseID = "QuestionCell"

    struct Selection {
        var picked: [Int: Set<Int>] = [:]
        var custom: [Int: String] = [:]

        func answers(for request: QuestionRequest) -> [[String]]? {
            var result: [[String]] = []
            for (index, item) in request.questions.enumerated() {
                var labels = (picked[index] ?? []).sorted().compactMap { optionIndex in
                    item.options.indices.contains(optionIndex)
                        ? item.options[optionIndex].label : nil
                }
                if let custom = custom[index], !custom.isEmpty { labels.append(custom) }
                guard !labels.isEmpty else { return nil }
                result.append(labels)
            }
            return result
        }
    }

    private let glass = Theme.Glass.view()
    private let stack = UIStackView()
    private var request: QuestionRequest?
    private var selection = Selection()
    private var onSubmit: (([[String]]) -> Void)?
    private var onSkip: (() -> Void)?
    private var onCustom: ((Int) -> Void)?
    private var onSelectionChanged: ((Selection) -> Void)?
    private let submitButton = PrimaryButton(title: "Answer")
    private let skipButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.layer.cornerRadius = Theme.Radius.card
        glass.layer.cornerCurve = .continuous
        glass.clipsToBounds = true
        glass.isUserInteractionEnabled = false
        contentView.addSubview(glass)

        stack.axis = .vertical
        stack.spacing = Theme.Spacing.m
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)

        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Spacing.xs),
            glass.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Theme.Spacing.xs),
            glass.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Spacing.l),
            glass.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.l),

            stack.topAnchor.constraint(equalTo: glass.topAnchor, constant: Theme.Spacing.l),
            stack.bottomAnchor.constraint(equalTo: glass.bottomAnchor, constant: -Theme.Spacing.l),
            stack.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: Theme.Spacing.l),
            stack.trailingAnchor.constraint(equalTo: glass.trailingAnchor, constant: -Theme.Spacing.l),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(
        request: QuestionRequest,
        selection: Selection,
        onSelectionChanged: @escaping (Selection) -> Void,
        onSubmit: @escaping ([[String]]) -> Void,
        onCustom: @escaping (Int) -> Void,
        onSkip: @escaping () -> Void
    ) {
        self.request = request
        self.selection = selection
        self.onSelectionChanged = onSelectionChanged
        self.onSubmit = onSubmit
        self.onCustom = onCustom
        self.onSkip = onSkip
        rebuild()
    }

    private var isSingleTapFastPath: Bool {
        guard let request else { return false }
        return request.questions.count == 1
            && !(request.questions.first?.multiple ?? false)
    }

    private func rebuild() {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let request else { return }

        let title = UILabel()
        title.text = "The agent has a question"
        title.font = .preferredFont(forTextStyle: .caption1)
        title.textColor = Theme.Color.secondaryLabel
        stack.addArrangedSubview(title)

        for (questionIndex, item) in request.questions.enumerated() {
            if !item.header.isEmpty {
                let header = UILabel()
                header.text = item.header.uppercased()
                header.font = .systemFont(ofSize: 11, weight: .bold)
                header.textColor = Theme.Color.accent
                stack.addArrangedSubview(header)
                stack.setCustomSpacing(Theme.Spacing.xs, after: header)
            }
            let question = UILabel()
            question.text = item.question
            question.font = Theme.Font.headline()
            question.numberOfLines = 0
            stack.addArrangedSubview(question)

            for (optionIndex, option) in item.options.enumerated() {
                let selected = selection.picked[questionIndex]?.contains(optionIndex) ?? false
                stack.addArrangedSubview(
                    optionRow(
                        option: option, selected: selected,
                        questionIndex: questionIndex, optionIndex: optionIndex,
                        multiple: item.multiple))
            }
            if item.custom {
                stack.addArrangedSubview(customRow(questionIndex: questionIndex))
            }
            if questionIndex < request.questions.count - 1 {
                stack.setCustomSpacing(Theme.Spacing.xl, after: stack.arrangedSubviews.last!)
            }
        }

        let footer = UIStackView()
        footer.axis = .horizontal
        footer.spacing = Theme.Spacing.m
        skipButton.setTitle("Skip", for: .normal)
        skipButton.titleLabel?.font = Theme.Font.caption()
        skipButton.setTitleColor(Theme.Color.secondaryLabel, for: .normal)
        skipButton.addTarget(self, action: #selector(skipTapped), for: .touchUpInside)
        footer.addArrangedSubview(skipButton)
        if !isSingleTapFastPath {
            submitButton.setTitle("Answer")
            submitButton.isEnabled = selection.answers(for: request) != nil
            submitButton.addTarget(self, action: #selector(submitTapped), for: .touchUpInside)
            footer.addArrangedSubview(submitButton)
        }
        stack.setCustomSpacing(Theme.Spacing.l, after: stack.arrangedSubviews.last!)
        stack.addArrangedSubview(footer)
    }

    private func optionRow(
        option: QuestionRequest.Option, selected: Bool,
        questionIndex: Int, optionIndex: Int, multiple: Bool
    ) -> UIView {
        var config = UIButton.Configuration.plain()
        config.baseForegroundColor = Theme.Color.label
        config.background.backgroundColor =
            selected
            ? Theme.Color.accent.withAlphaComponent(0.18)
            : Theme.Color.secondaryBackground
        config.background.cornerRadius = Theme.Radius.control
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
        var titleAttr = AttributedString(option.label)
        titleAttr.font = UIFont.preferredFont(forTextStyle: .subheadline).withTraits(.traitBold)
        config.attributedTitle = titleAttr
        if !option.description.isEmpty {
            var subAttr = AttributedString(option.description)
            subAttr.font = UIFont.preferredFont(forTextStyle: .caption1)
            subAttr.foregroundColor = Theme.Color.secondaryLabel
            config.attributedSubtitle = subAttr
            config.titlePadding = 2
        }
        config.image = UIImage(
            systemName: selected
                ? (multiple ? "checkmark.square.fill" : "largecircle.fill.circle")
                : (multiple ? "square" : "circle"),
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .medium))
        config.imagePadding = Theme.Spacing.m
        config.baseForegroundColor = Theme.Color.label
        let button = UIButton(configuration: config)
        button.contentHorizontalAlignment = .leading
        button.tintColor = selected ? Theme.Color.accent : Theme.Color.tertiaryLabel
        button.addAction(
            UIAction { [weak self] _ in
                self?.optionTapped(questionIndex: questionIndex, optionIndex: optionIndex, multiple: multiple)
            }, for: .touchUpInside)
        return button
    }

    private func customRow(questionIndex: Int) -> UIView {
        var config = UIButton.Configuration.plain()
        config.background.backgroundColor = Theme.Color.secondaryBackground
        config.background.cornerRadius = Theme.Radius.control
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
        let custom = selection.custom[questionIndex]
        var titleAttr = AttributedString(custom?.isEmpty == false ? custom! : "Other…")
        titleAttr.font = UIFont.preferredFont(forTextStyle: .subheadline)
        config.attributedTitle = titleAttr
        config.image = UIImage(
            systemName: custom?.isEmpty == false ? "pencil.circle.fill" : "pencil.circle",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .medium))
        config.imagePadding = Theme.Spacing.m
        config.baseForegroundColor =
            custom?.isEmpty == false ? Theme.Color.label : Theme.Color.secondaryLabel
        let button = UIButton(configuration: config)
        button.contentHorizontalAlignment = .leading
        button.addAction(
            UIAction { [weak self] _ in self?.onCustom?(questionIndex) }, for: .touchUpInside)
        return button
    }

    private func optionTapped(questionIndex: Int, optionIndex: Int, multiple: Bool) {
        Theme.Haptics.selection()
        guard let request else { return }
        var picked = selection.picked[questionIndex] ?? []
        if multiple {
            if picked.contains(optionIndex) { picked.remove(optionIndex) } else { picked.insert(optionIndex) }
        } else {
            picked = [optionIndex]
        }
        selection.picked[questionIndex] = picked
        onSelectionChanged?(selection)
        if isSingleTapFastPath, let answers = selection.answers(for: request) {
            onSubmit?(answers)
            return
        }
        rebuild()
    }

    @objc private func submitTapped() {
        guard let request, let answers = selection.answers(for: request) else { return }
        Theme.Haptics.send()
        onSubmit?(answers)
    }

    @objc private func skipTapped() {
        Theme.Haptics.warning()
        onSkip?()
    }
}
