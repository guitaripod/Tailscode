import CodingAgentKit
import TailscodeCore
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
        case table(MarkdownTable)
        case activity([ActivityStep])
        case subagent(SubagentCard)
        case workflow(WorkflowRun)
        case subagentGroup(SubagentGroup)
        case compaction(CompactionRow)
        case taskBoard(TaskBoard)
        case file(FileReference)
        case image(FileReference)
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

extension MessageSegment {
    /// The shared splitter's rows in this client's grammar, so every consumer maps a segment the
    /// same way.
    var chatContent: ChatRow.Content {
        switch self {
        case .prose(let text):
            return .text(text)
        case .code(let language, let body):
            return .code(CodeBlock(language: language, source: body))
        case .table(let table):
            return .table(table)
        }
    }
}

final class TextBubbleCell: UICollectionViewCell {
    static let reuseID = "TextBubbleCell"
    weak var linkDelegate: TextBubbleCellDelegate?

    private let bubble = UIView()
    private let textView = UITextView()
    private var leadingPin: NSLayoutConstraint!
    private var trailingPin: NSLayoutConstraint!
    private var textInsetLeading: NSLayoutConstraint!
    private var textInsetTrailing: NSLayoutConstraint!
    private var maxWidth: NSLayoutConstraint!
    private var timestampLeading: NSLayoutConstraint?
    private var timestampTrailing: NSLayoutConstraint?
    private var bubbleTop: NSLayoutConstraint!

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
        textInsetLeading = textView.leadingAnchor.constraint(
            equalTo: bubble.leadingAnchor, constant: Theme.Spacing.m)
        textInsetTrailing = textView.trailingAnchor.constraint(
            equalTo: bubble.trailingAnchor, constant: -Theme.Spacing.m)
        maxWidth = bubble.widthAnchor.constraint(
            lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.82)
        bubbleTop = bubble.topAnchor.constraint(
            equalTo: contentView.topAnchor, constant: Theme.Spacing.xs)

        NSLayoutConstraint.activate([
            bubbleTop,
            bubble.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Theme.Spacing.xs),
            maxWidth,
            bubble.leadingAnchor.constraint(greaterThanOrEqualTo: contentView.leadingAnchor),
            bubble.trailingAnchor.constraint(lessThanOrEqualTo: contentView.trailingAnchor),
            textInsetLeading,
            textInsetTrailing,
            textView.topAnchor.constraint(equalTo: bubble.topAnchor, constant: Theme.Spacing.s),
            textView.bottomAnchor.constraint(equalTo: bubble.bottomAnchor, constant: -Theme.Spacing.s),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Extra gap above the bubble when this row opens a new turn; set by the
    /// transcript so a turn breathes without re-templating the cell.
    var turnInset: CGFloat = 0 {
        didSet { bubbleTop.constant = Theme.Spacing.xs + turnInset }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        contentView.layer.removeAllAnimations()
        contentView.alpha = 1
        contentView.transform = .identity
        textView.textAlignment = .natural
        timestampLeading?.isActive = false
        timestampTrailing?.isActive = false
    }

    /// The answer bubble hugs its text tighter than the other rows: the surface is
    /// the point, so the chrome around the words shrinks to the tokens above.
    private func applyHorizontalInsets(outer: CGFloat, inner: CGFloat) {
        leadingPin.constant = outer
        trailingPin.constant = -outer
        textInsetLeading.constant = inner
        textInsetTrailing.constant = -inner
    }

    func configureError(_ text: String) {
        applyHorizontalInsets(outer: Theme.Spacing.l, inner: Theme.Spacing.m)
        timestampLeading?.isActive = false
        timestampTrailing?.isActive = false
        maxWidth.isActive = true
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

    func configure(
        text: String, role: MessageRole, reasoning: Bool, timestamp: Bool = false,
        cascade: CascadeTail? = nil
    ) {
        let isUser = role == .user

        timestampLeading?.isActive = false
        timestampTrailing?.isActive = false
        applyHorizontalInsets(
            outer: isUser || reasoning || timestamp ? Theme.Spacing.l : Theme.Spacing.s,
            inner: isUser || reasoning || timestamp ? Theme.Spacing.m : Theme.Spacing.s)

        if timestamp {
            bubble.backgroundColor = .clear
            textView.textColor = Theme.Color.tertiaryLabel
            textView.font = .preferredFont(forTextStyle: .caption2)
            textView.textAlignment = .center
            textView.text = text
            leadingPin.isActive = false
            trailingPin.isActive = false
            maxWidth.isActive = false
            if timestampLeading == nil {
                timestampLeading = bubble.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Spacing.l)
                timestampTrailing = bubble.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.l)
            }
            timestampLeading?.isActive = true
            timestampTrailing?.isActive = true
            return
        }

        maxWidth.isActive = true
        leadingPin.isActive = !isUser
        trailingPin.isActive = isUser
        textView.textAlignment = .natural

        if reasoning {
            bubble.backgroundColor = .clear
            textView.textColor = Theme.Color.secondaryLabel
            textView.font = Theme.Type.font(.thought)
            if let cascade {
                let string = NSAttributedString(
                    string: text,
                    attributes: Theme.Type.attributes(
                        .thought, color: Theme.Color.secondaryLabel))
                textView.attributedText = cascade.paint(
                    string, settled: Theme.Color.secondaryLabel)
            } else {
                textView.text = text
            }
            textView.linkTextAttributes = [
                .foregroundColor: Theme.Color.secondaryLabel,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ]
        } else if isUser {
            bubble.backgroundColor = Theme.Color.userBubble
            textView.textColor = Theme.Color.onAccent
            textView.font = Theme.Type.font(.prompt)
            textView.attributedText = NSAttributedString(
                string: text,
                attributes: Theme.Type.attributes(.prompt, color: Theme.Color.onAccent))
            textView.linkTextAttributes = [.foregroundColor: Theme.Color.onAccent]
        } else {
            bubble.backgroundColor = Theme.Color.assistantBubble
            textView.textColor = Theme.Color.label
            textView.font = Theme.Type.font(.answer)
            let rendered = Self.rendered(text, color: Theme.Color.label)
            textView.attributedText =
                cascade.map { $0.paint(rendered, settled: Theme.Color.label) } ?? rendered
            textView.linkTextAttributes = [
                .foregroundColor: Theme.Color.accent,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ]
        }
    }

    /// A frame of the wave. When the glyphs did not change, only colours move, so the storage is
    /// re-tinted in place and nothing re-measures; when text arrived, the full render lands at
    /// once. Either way the paragraph is measured once per arrival and never again.
    func applyCascade(_ cascade: CascadeTail, text: String, reasoning: Bool) {
        if reasoning {
            let string = NSAttributedString(
                string: text,
                attributes: Theme.Type.attributes(.thought, color: Theme.Color.secondaryLabel))
            textView.attributedText = cascade.paint(string, settled: Theme.Color.secondaryLabel)
            return
        }
        let rendered = Self.rendered(text, color: Theme.Color.label)
        if textView.textStorage.length == rendered.length,
            textView.textStorage.string == rendered.string
        {
            cascade.repaint(textView.textStorage, base: rendered, settled: Theme.Color.label)
        } else {
            textView.attributedText = cascade.paint(rendered, settled: Theme.Color.label)
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
        let base = Theme.Type.font(.answer)
        var options = AttributedString.MarkdownParsingOptions()
        options.interpretedSyntax = .inlineOnlyPreservingWhitespace
        let result: NSAttributedString
        if var attr = try? AttributedString(markdown: text, options: options) {
            attr.font = base
            attr.foregroundColor = color
            let headingFont = Theme.Type.font(.cardTitle)
            for run in attr.runs {
                if run.inlinePresentationIntent?.contains(.code) == true {
                    attr[run.range].font = Theme.Type.font(.code)
                    attr[run.range].backgroundColor = Theme.Color.reasoningBackground
                }
                if run.inlinePresentationIntent?.contains(.emphasized) == true {
                    attr[run.range].font = base.withTraits(.traitBold)
                }
            }
            let mutable = NSMutableAttributedString(attr)
            mutable.addAttribute(
                .paragraphStyle, value: Self.prose(),
                range: NSRange(location: 0, length: mutable.length))
            var edits: [(range: NSRange, replacement: String)] = []
            mutable.mutableString.enumerateSubstrings(
                in: NSRange(location: 0, length: mutable.length),
                options: .byLines
            ) { _, substringRange, _, _ in
                let line = mutable.attributedSubstring(from: substringRange).string
                let marks = line.prefix(while: { $0 == "#" }).count
                if marks >= 1, marks <= 6, line.dropFirst(marks).hasPrefix(" ") {
                    let font = marks <= 2 ? Theme.Type.font(.headline) : headingFont
                    mutable.addAttribute(.font, value: font, range: substringRange)
                    edits.append(
                        (NSRange(location: substringRange.location, length: marks + 1), ""))
                    return
                }
                let trimmedStart = line.drop { $0 == " " }
                let indentDepth = line.count - trimmedStart.count
                if trimmedStart.hasPrefix("- ") || trimmedStart.hasPrefix("* ") {
                    let paragraph = Self.prose()
                    paragraph.firstLineHeadIndent = CGFloat(indentDepth) * 6
                    paragraph.headIndent = CGFloat(indentDepth) * 6 + 14
                    paragraph.paragraphSpacing = Self.listItemSpacing
                    mutable.addAttribute(.paragraphStyle, value: paragraph, range: substringRange)
                    let item = trimmedStart.dropFirst(2)
                    if let box = ["[ ] ": "☐  ", "[x] ": "☑  ", "[X] ": "☑  "]
                        .first(where: { item.hasPrefix($0.key) })
                    {
                        edits.append((
                            NSRange(location: substringRange.location + indentDepth, length: 6),
                            box.value
                        ))
                    } else {
                        edits.append((
                            NSRange(location: substringRange.location + indentDepth, length: 2),
                            indentDepth >= 2 ? "◦  " : "•  "
                        ))
                    }
                } else if let digits = Self.orderedListPrefixLength(trimmedStart) {
                    let paragraph = Self.prose()
                    paragraph.firstLineHeadIndent = CGFloat(indentDepth) * 6
                    paragraph.headIndent = CGFloat(indentDepth) * 6 + CGFloat(digits + 1) * 8
                    paragraph.paragraphSpacing = Self.listItemSpacing
                    mutable.addAttribute(.paragraphStyle, value: paragraph, range: substringRange)
                } else if trimmedStart.hasPrefix("> ") {
                    let paragraph = Self.prose()
                    paragraph.firstLineHeadIndent = 12
                    paragraph.headIndent = 12
                    mutable.addAttribute(.paragraphStyle, value: paragraph, range: substringRange)
                    mutable.addAttribute(
                        .foregroundColor, value: Theme.Color.secondaryLabel, range: substringRange)
                    edits.append((
                        NSRange(location: substringRange.location + indentDepth, length: 2), ""
                    ))
                }
            }
            for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
                mutable.replaceCharacters(in: edit.range, with: edit.replacement)
            }
            linkFilePaths(in: mutable)
            result = mutable
        } else {
            let mutable = NSMutableAttributedString(
                string: text, attributes: [.font: base, .foregroundColor: color])
            linkFilePaths(in: mutable)
            result = mutable
        }
        renderCache.setObject(result, forKey: key)
        return result
    }

    /// Every paragraph in an answer starts from the ramp's leading, so an indented list item is not
    /// set tighter than the prose above it merely for having asked to be indented.
    private static func prose() -> NSMutableParagraphStyle {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineHeightMultiple = Typography.spec(.answer).lineHeight
        return paragraph
    }

    /// A list reads as a list when the gap between two items is bigger than the gap inside one.
    /// Equal spacing everywhere is what makes a wrapped item look like two items — the hanging
    /// indent says where an item continues, and this says where the next one starts.
    static let listItemSpacing: CGFloat = 3

    /// The digit count of a `1. ` / `12) ` ordered-list marker, or nil when
    /// the line is not a list item — used to hang wrapped lines past the number.
    private static func orderedListPrefixLength(_ line: Substring) -> Int? {
        let digits = line.prefix(while: \.isNumber)
        guard !digits.isEmpty, digits.count <= 3 else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return digits.count
    }

    private static let filePathRegex = try? NSRegularExpression(
        pattern: "(?<![\\w/~.-])(~?/(?:[\\w.@%+-]+/)+[\\w.@%+-]+(:\\d+)?)")

    /// Absolute and home-relative paths in assistant prose become tappable
    /// links (`tailscode-path` scheme) so a mentioned file can be copied or
    /// dropped into the composer without hand-selecting text.
    static func pathActionURL(for path: String) -> URL? {
        var components = URLComponents()
        components.scheme = "tailscode-path"
        components.host = "path"
        components.queryItems = [URLQueryItem(name: "p", value: path)]
        return components.url
    }

    static func path(fromActionURL url: URL) -> String? {
        guard url.scheme == "tailscode-path" else { return nil }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "p" })?.value
    }

    private static func linkFilePaths(in text: NSMutableAttributedString) {
        guard let regex = filePathRegex, text.length <= 12_000, text.string.contains("/")
        else { return }
        let matches = regex.matches(
            in: text.string, range: NSRange(location: 0, length: text.length))
        for match in matches.reversed() {
            var range = match.range(at: 1)
            var hasLink = false
            text.enumerateAttribute(.link, in: range, options: []) { value, _, stop in
                if value != nil {
                    hasLink = true
                    stop.pointee = true
                }
            }
            guard !hasLink else { continue }
            var token = (text.string as NSString).substring(with: range)
            while let last = token.last, ".,;:)".contains(last) {
                token.removeLast()
                range.length -= 1
            }
            guard token.dropFirst().contains("/"), let url = pathActionURL(for: token) else { continue }
            text.addAttribute(.link, value: url, range: range)
        }
    }
}

extension TextBubbleCell: UITextViewDelegate {
    func textView(
        _ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction
    ) -> UIAction? {
        guard case .link(let url) = textItem.content else { return defaultAction }
        return UIAction { [weak self] _ in
            guard let self else { return }
            self.linkDelegate?.textBubbleCell(self, didTapLink: url)
        }
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
    private var barTop: NSLayoutConstraint!

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

        titleLabel.font = Theme.Type.font(.cardTitle)
        titleLabel.textColor = Theme.Color.label
        titleLabel.numberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.font = Theme.Type.font(.cardBody)
        detailLabel.textColor = Theme.Color.secondaryLabel
        detailLabel.numberOfLines = 0
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        configureButton(
            allowButton, title: String(localized: "Allow once"), tint: Theme.Color.accent,
            filled: true)
        configureButton(
            alwaysButton, title: String(localized: "Always"), tint: Theme.Color.accent, filled: false)
        configureButton(
            denyButton, title: String(localized: "Deny"), tint: Theme.Color.danger, filled: false)
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

        barTop = bar.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Spacing.xs)
        NSLayoutConstraint.activate([
            barTop,
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

    /// Extra gap above the card when this row opens a new turn.
    var turnInset: CGFloat = 0 {
        didSet { barTop.constant = Theme.Spacing.xs + turnInset }
    }

    private func configureButton(_ button: UIButton, title: String, tint: UIColor, filled: Bool) {
        var config = filled ? UIButton.Configuration.filled() : UIButton.Configuration.tinted()
        config.title = title
        config.baseBackgroundColor = tint
        config.baseForegroundColor = filled ? Theme.Color.onAccent : tint
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

/// A label that paints a diff's washes itself, the full width of the line. A background attribute
/// covers only glyph runs, so an attribute-painted wash stops at the last glyph and reads as a
/// rendering bug rather than a ground. Code never wraps in this label, so a source row is a drawn
/// row and the rect is arithmetic — row × lineHeight, edge to edge.
final class DiffWashLabel: UILabel {
    var washes: [(row: Int, color: UIColor)] = [] {
        didSet { setNeedsDisplay() }
    }
    private var settledSize: CGSize?
    private var settledWidth: CGFloat = .nan
    private var isRepainting = false

    /// A frame of the wave: the same glyphs, freshly tinted.
    ///
    /// `attributedText` is a copy on a label, so unlike a text view there is no storage to tint
    /// where it stands and the assignment cannot be avoided. What can be avoided is what the
    /// assignment costs: every one of them invalidates the intrinsic size, and a self-sizing cell
    /// answers that by measuring the whole block again — on the display's clock, up to a hundred
    /// and twenty times a second, for a size that cannot have moved because only the colours did.
    /// So a repaint keeps the measurement and any other assignment drops it: a frame may change
    /// light, never a size the layout depends on.
    func repaint(_ text: NSAttributedString) {
        isRepainting = true
        attributedText = text
        isRepainting = false
    }

    override var attributedText: NSAttributedString? {
        didSet { if !isRepainting { forget() } }
    }

    /// Everything that is not a repaint drops the measurement, and this is the only place that can
    /// know about most of them.
    ///
    /// A memo that outlives its reasons is worse than no memo. A wrapping label is measured twice:
    /// UIKit asks with no preferred width and gets the unwrapped size, then sets the width from the
    /// bounds it was given and invalidates for the real answer — and a memo that swallowed the
    /// second question would leave the label laid out at its one-line-per-newline height, clipping
    /// or spilling out of whatever holds it. A font, a line-break mode, a trait, a text change made
    /// through any road but `attributedText`: all of them arrive here and none of them are colour.
    override func invalidateIntrinsicContentSize() {
        if !isRepainting { forget() }
        super.invalidateIntrinsicContentSize()
    }

    /// The width the answer was measured against, so a memo can only ever be handed back to the
    /// question it answered. `preferredMaxLayoutWidth` is what a wrapping label wraps at once
    /// layout has told it; before that there is only the bounds.
    private var measuredWidth: CGFloat {
        preferredMaxLayoutWidth > 0 ? preferredMaxLayoutWidth : bounds.width
    }

    private func forget() {
        settledSize = nil
        settledWidth = .nan
    }

    override var intrinsicContentSize: CGSize {
        let width = measuredWidth
        if let settledSize, settledWidth == width { return settledSize }
        let size = super.intrinsicContentSize
        settledSize = size
        settledWidth = width
        return size
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        contentMode = .redraw
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeIdentityTrait.self]) {
            (label: DiffWashLabel, _) in label.setNeedsDisplay()
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func draw(_ rect: CGRect) {
        if !washes.isEmpty, let font {
            let height = font.lineHeight
            for wash in washes {
                wash.color.setFill()
                UIRectFill(CGRect(
                    x: 0, y: CGFloat(wash.row) * height, width: bounds.width, height: height))
            }
        }
        super.draw(rect)
    }
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
    private let codeLabel = DiffWashLabel()
    private let lineNumberLabel = UILabel()
    private let toggleButton = UIButton(type: .system)
    private var source = ""
    private var onToggle: (() -> Void)?
    private var containerTop: NSLayoutConstraint!
    /// The glyphs the label is currently showing, kept so a frame of the wave can be tinted over
    /// them rather than built again from the highlighter's output.
    private var paintedStorage: NSMutableAttributedString?
    /// The text the label was last given, which is what decides whether this row is still the row
    /// the reader was reading sideways.
    private var laidOutText = ""

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
        copyButton.accessibilityLabel = String(localized: "Copy code")
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
        lineNumberLabel.isAccessibilityElement = false
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
        containerTop = container.topAnchor.constraint(
            equalTo: contentView.topAnchor, constant: Theme.Spacing.xs)
        NSLayoutConstraint.activate([
            containerTop,
            container.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Theme.Spacing.xs),
            container.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Spacing.s),
            container.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.s),

            langLabel.topAnchor.constraint(equalTo: container.topAnchor, constant: Theme.Spacing.s),
            langLabel.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Theme.Spacing.m),
            copyButton.centerYAnchor.constraint(equalTo: langLabel.centerYAnchor),
            copyButton.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Theme.Spacing.m),

            codeScroll.topAnchor.constraint(equalTo: langLabel.bottomAnchor, constant: Theme.Spacing.xs),
            codeScroll.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Theme.Spacing.m),
            codeScroll.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Theme.Spacing.m),
            frame.heightAnchor.constraint(equalTo: content.heightAnchor),
            content.widthAnchor.constraint(greaterThanOrEqualTo: frame.widthAnchor),

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

    /// Extra gap above the block when this row opens a new turn.
    var turnInset: CGFloat = 0 {
        didSet { containerTop.constant = Theme.Spacing.xs + turnInset }
    }

    func configure(
        _ block: CodeBlock, expanded: Bool, cascade: CascadeTail? = nil,
        onToggle: @escaping () -> Void
    ) {
        self.onToggle = onToggle
        source = block.source
        langLabel.text = SyntaxHighlighter.displayName(for: block.language, source: block.source)
        var copyConfig = copyButton.configuration ?? .plain()
        copyConfig.image = UIImage(
            systemName: "doc.on.doc", withConfiguration:
                UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        copyButton.configuration = copyConfig
        let layout = Self.laidOut(block.source, expanded: expanded)
        rewindIfAnotherBlock(layout.text)
        let base = Self.highlightedCode(layout.text, language: block.language)
        let storage = NSMutableAttributedString(
            attributedString: cascade.map { $0.paint(base, settled: Theme.Color.label) } ?? base)
        paintedStorage = storage
        codeLabel.attributedText = storage
        codeLabel.washes = Self.washes(layout.text, language: block.language)
        lineNumberLabel.text = Self.lineNumbers(count: layout.shownLines)
        let title =
            layout.isLong && !expanded
            ? String(localized: "Show all \(layout.totalLines) lines")
            : String(localized: "Collapse")
        toggleButton.setTitle(title, for: .normal)
        toggleButton.isHidden = !layout.isLong
    }

    /// Puts the block back at its first column, but only when it is a different block.
    ///
    /// A code row scrolls sideways because a line is longer than the phone, and where the reader
    /// scrolled it to is theirs. `configure` runs again for every streamed arrival, for a frame the
    /// wave could not paint in place, for an image elsewhere finishing its decode, for the toggle
    /// and for the hand-back at the end of a turn — and rewinding on all of them meant a long line
    /// could not be read at all: the next token pulled it back to column one. Text that continues
    /// what was already there is the same block still being written, and it keeps its place; a cell
    /// recycled onto another block, or a block collapsed back down, starts over.
    private func rewindIfAnotherBlock(_ text: String) {
        defer { laidOutText = text }
        guard !text.hasPrefix(laidOutText) else { return }
        codeScroll.setContentOffset(.zero, animated: false)
    }

    /// What the block actually lays out, which everything that touches the row has to agree on.
    ///
    /// A long block shows its first lines until the reader opens it, and that decision was being
    /// made three times over: `configure` laid out the prefix, a frame of the wave painted the
    /// whole source, and the pacer counted the whole source's characters. So the cell alternated
    /// two different heights — opaque on every arrival, faded on every frame — and the reveal
    /// finished while the reader was still fourteen lines behind, because the pacer was counting
    /// characters the cell would never lay out. One answer, asked here, keyed off whether the
    /// reader has opened the row and never off what the toggle button's title happens to say in
    /// the language the phone is set to.
    static func laidOut(_ source: String, expanded: Bool)
        -> (text: String, shownLines: Int, totalLines: Int, isLong: Bool)
    {
        let lines = source.components(separatedBy: "\n")
        let isLong = lines.count > collapsedLineLimit
        guard isLong, !expanded else {
            return (source, lines.count, lines.count, isLong)
        }
        return (
            lines.prefix(collapsedLineLimit).joined(separator: "\n"), collapsedLineLimit,
            lines.count, true
        )
    }

    /// The grounds under a diff's changed lines, as geometry for `DiffWashLabel` to paint. Any
    /// other language has none.
    static func washes(_ source: String, language: String?) -> [(row: Int, color: UIColor)] {
        guard SyntaxHighlighter.isDiff(language) else { return [] }
        return SyntaxHighlighter.diffLines(source).compactMap { line in
            guard line.kind == .added || line.kind == .removed else { return nil }
            return (line.row, Theme.Color.diffBackground(line.kind))
        }
    }

    /// A frame that moved only the band: the same glyphs, freshly tinted. The highlighter's own
    /// colours are the settled ones, so a keyword leaves the wave the keyword colour rather than
    /// the prose colour — the cascade tints what is there rather than replacing it.
    ///
    /// The glyphs are whatever `configure` laid out, which for a long block the reader has not
    /// opened is its first fourteen lines. Painting the whole source here instead would grow the
    /// cell to the full block on the display's clock and shrink it back on the next arrival, with
    /// the gutter still numbering fourteen — a frame is allowed to change light, never a size the
    /// layout depends on.
    func applyCascade(_ cascade: CascadeTail, block: CodeBlock, expanded: Bool) {
        let base = Self.highlightedCode(
            Self.laidOut(block.source, expanded: expanded).text, language: block.language)
        if let storage = paintedStorage, storage.length == base.length,
            storage.string == base.string
        {
            cascade.repaint(storage, base: base, settled: Theme.Color.label)
            codeLabel.repaint(storage)
            return
        }
        let storage = NSMutableAttributedString(
            attributedString: cascade.paint(base, settled: Theme.Color.label))
        paintedStorage = storage
        codeLabel.attributedText = storage
    }

    private static func lineNumbers(count: Int) -> String {
        (1...count).map { "\($0)" }.joined(separator: "\n")
    }

    static let monoFont = Theme.Font.mono(12)

    private static let highlightCache: NSCache<NSString, NSAttributedString> = {
        let cache = NSCache<NSString, NSAttributedString>()
        cache.countLimit = 60
        return cache
    }()

    /// The shared lexer's tokens, painted in this theme's colours. Nothing about which run is a
    /// keyword is decided here — that answer is Core's, and the Linux and Mac clients ask it the
    /// same question, which is what keeps one block of code looking like itself on three screens.
    ///
    /// The cache needs no theme in its key: the colours put in are dynamic, so the text system
    /// resolves them against the trait collection of whatever draws them, and a cached block
    /// repaints itself when the theme changes rather than going stale.
    static func highlightedCode(
        _ source: String, language: String?, font: UIFont = monoFont
    ) -> NSAttributedString {
        let key = "\(font.pointSize)#\(language ?? "")#\(source)" as NSString
        if let cached = highlightCache.object(forKey: key) { return cached }
        let result: NSAttributedString
        if SyntaxHighlighter.isDiff(language) {
            result = diffAttributed(source, font: font)
        } else {
            let plain = NSMutableAttributedString(string: source, attributes: [
                .font: font, .foregroundColor: Theme.Color.label,
            ])
            let length = plain.length
            for token in SyntaxHighlighter.tokens(source, language: language) {
                let range = NSRange(location: token.offset, length: token.length)
                guard NSMaxRange(range) <= length else { continue }
                plain.addAttribute(
                    .foregroundColor, value: Theme.Color.syntax(token.role), range: range)
            }
            result = plain
        }
        highlightCache.setObject(result, forKey: key)
        return result
    }

    /// A patch's ink. The wash under each changed line carries the diff's meaning — painted by
    /// the hosting view, full width, never as a background attribute that stops at the last
    /// glyph — which frees the foreground for the file's own language: the marker glyph keeps
    /// the diff's full ink, and every token on a washed line is coloured against the wash it
    /// actually sits on. A patch that names no file keeps the old whole-line red and green,
    /// because guessing a language would colour code as something it is not.
    static func diffAttributed(
        _ source: String, language: String? = nil, font: UIFont
    ) -> NSAttributedString {
        let diff = SyntaxHighlighter.diff(source, language: language)
        let result = NSMutableAttributedString(string: source, attributes: [
            .font: font, .foregroundColor: Theme.Color.label,
        ])
        let length = result.length
        for token in diff.tokens {
            let range = NSRange(location: token.offset, length: token.length)
            guard NSMaxRange(range) <= length else { continue }
            let kind = diff.kind(at: token.offset)
            let color = kind == .added || kind == .removed
                ? Theme.Color.syntax(token.role, on: kind) : Theme.Color.syntax(token.role)
            result.addAttribute(.foregroundColor, value: color, range: range)
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
/// Collapsed, the run reads as a slim glass strip — status glyph, what the tools were,
/// the turning ring while the work is live — and only grows into the roomy card when opened.
final class ActivityGroupCell: UICollectionViewCell {
    static let reuseID = "ActivityGroupCell"

    private let container = UIView()
    private let glass = Theme.Glass.view()
    private let tile = UIView()
    private let iconView = UIImageView()
    private let summaryLabel = UILabel()
    private let chevron = UIImageView()
    private let liveMark = ActivityBadgeView(pointSize: 11)
    private let stack = UIStackView()
    private let toggle = UIButton(type: .system)
    private let renderer = ToolStepRenderer()
    private var onToggle: (() -> Void)?

    private var topConstraint: NSLayoutConstraint!
    private var tileTopInset: NSLayoutConstraint!
    private var tileSize: NSLayoutConstraint!
    private var iconSize: NSLayoutConstraint!
    private var stackSpacing: NSLayoutConstraint!
    private var stackBottomInset: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        container.layer.cornerCurve = .continuous
        container.translatesAutoresizingMaskIntoConstraints = false

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

        tile.layer.cornerCurve = .continuous
        tile.translatesAutoresizingMaskIntoConstraints = false

        iconView.tintColor = Theme.Color.accent
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false

        summaryLabel.adjustsFontForContentSizeCategory = true
        summaryLabel.isAccessibilityElement = false
        summaryLabel.translatesAutoresizingMaskIntoConstraints = false

        chevron.image = UIImage(
            systemName: "chevron.down",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        chevron.tintColor = Theme.Color.tertiaryLabel
        chevron.contentMode = .scaleAspectFit
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        chevron.translatesAutoresizingMaskIntoConstraints = false

        liveMark.translatesAutoresizingMaskIntoConstraints = false

        stack.axis = .vertical
        stack.spacing = Theme.Spacing.s
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false

        toggle.translatesAutoresizingMaskIntoConstraints = false
        toggle.addTarget(self, action: #selector(toggleTapped(_:event:)), for: .touchUpInside)

        contentView.addSubview(container)
        [tile, summaryLabel, liveMark, chevron, stack, toggle].forEach(container.addSubview)
        tile.addSubview(iconView)

        tileTopInset = tile.topAnchor.constraint(equalTo: container.topAnchor, constant: 7)
        tileSize = tile.widthAnchor.constraint(equalToConstant: 16)
        iconSize = iconView.widthAnchor.constraint(equalToConstant: 15)
        stackSpacing = stack.topAnchor.constraint(equalTo: tile.bottomAnchor, constant: 6)
        stackBottomInset = stack.bottomAnchor.constraint(
            equalTo: container.bottomAnchor, constant: -7)
        topConstraint = container.topAnchor.constraint(
            equalTo: contentView.topAnchor, constant: Theme.Spacing.xs)

        NSLayoutConstraint.activate([
            topConstraint,
            container.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor, constant: -Theme.Spacing.xs),
            container.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: Theme.Spacing.l),
            container.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.l),

            tileTopInset,
            tile.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Theme.Spacing.m),
            tileSize,
            tile.heightAnchor.constraint(equalTo: tile.widthAnchor),
            iconView.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            iconSize,
            iconView.heightAnchor.constraint(equalTo: iconView.widthAnchor),

            summaryLabel.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: Theme.Spacing.s),
            summaryLabel.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            liveMark.leadingAnchor.constraint(
                greaterThanOrEqualTo: summaryLabel.trailingAnchor, constant: Theme.Spacing.s),
            liveMark.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            chevron.leadingAnchor.constraint(equalTo: liveMark.trailingAnchor, constant: Theme.Spacing.s),
            chevron.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Theme.Spacing.m),
            chevron.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            chevron.widthAnchor.constraint(equalToConstant: 12),

            stackSpacing,
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: Theme.Spacing.m),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -Theme.Spacing.m),
            stackBottomInset,

            toggle.topAnchor.constraint(equalTo: container.topAnchor),
            toggle.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            toggle.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            toggle.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// How much the whole card sits below the row before it; a turn boundary
    /// breathes, rows inside the same turn stay tight.
    var turnInset: CGFloat = 0 {
        didSet { topConstraint.constant = Theme.Spacing.xs + turnInset }
    }

    func configure(
        steps: [ActivityStep], expanded: Bool, streaming: Bool, compact: Bool,
        onToggle: @escaping () -> Void, onToolTap: ((ToolCall) -> Void)? = nil,
        onLinkTap: ((URL) -> Void)? = nil
    ) {
        self.onToggle = onToggle
        renderer.onToolTap = onToolTap
        renderer.onLinkTap = onLinkTap
        let failed = !streaming && steps.contains {
            if case .tool(let call) = $0, call.status == .error { return true }
            return false
        }
        iconView.image = UIImage(
            systemName: streaming
                ? "gearshape.2.fill" : (failed ? "exclamationmark.triangle.fill" : "sparkles"),
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 13, weight: .semibold))
        let iconTint = failed ? Theme.Color.warning : Theme.Color.accent
        iconView.tintColor = iconTint
        summaryLabel.text = Self.summary(steps, streaming: streaming)
        toggle.accessibilityLabel = summaryLabel.text
        toggle.accessibilityValue =
            expanded ? String(localized: "Expanded") : String(localized: "Collapsed")
        toggle.accessibilityHint = expanded
            ? String(localized: "Double tap to hide agent steps")
            : String(localized: "Double tap to show agent steps")
        chevron.transform = expanded ? CGAffineTransform(rotationAngle: .pi) : .identity
        liveMark.show(
            streaming ? .openWork : nil, spoken: String(localized: "Still working"))

        let isCompact = compact && !expanded
        tileTopInset.constant = isCompact ? 7 : 10
        tileSize.constant = isCompact ? 16 : 26
        iconSize.constant = isCompact ? 15 : 18
        stackSpacing.constant = isCompact ? 6 : Theme.Spacing.s
        stackBottomInset.constant = isCompact ? -7 : -Theme.Spacing.m
        tile.layer.cornerRadius = isCompact ? 5 : 7
        tile.backgroundColor = isCompact
            ? .clear
            : (failed ? Theme.Color.warning : Theme.Color.accent).withAlphaComponent(0.12)
        container.layer.cornerRadius = isCompact ? 12 : Theme.Radius.card
        glass.layer.cornerRadius = container.layer.cornerRadius
        summaryLabel.font = isCompact
            ? UIFont.preferredFont(forTextStyle: .footnote).withTraits(.traitBold)
            : UIFont.preferredFont(forTextStyle: .subheadline).withTraits(.traitBold)
        summaryLabel.textColor = failed ? Theme.Color.warning : Theme.Color.secondaryLabel

        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        stack.isHidden = !expanded
        renderer.reset()
        if expanded {
            for step in steps { stack.addArrangedSubview(renderer.view(for: step)) }
        }
    }

    /// The whole card is one button — a gesture recognizer here would lose
    /// the recognition race against the chat's keyboard-dismiss tap, so the
    /// step rows stay non-interactive and taps dispatch by touch location:
    /// a subagent-spawn or link row runs its action, anywhere else toggles.
    @objc private func toggleTapped(_ sender: UIButton, event: UIEvent) {
        if let touch = event.allTouches?.first,
            renderer.handleTap(at: touch.location(in: container), in: container)
        {
            Theme.Haptics.tap()
            return
        }
        Theme.Haptics.selection()
        onToggle?()
    }

    /// A collapsed row names the tools it hides, which says nothing when the
    /// step is the agent asking something — there the question is the point.
    private static func stepName(_ call: ToolCall) -> String {
        guard call.summary.kind == .question, let question = call.summary.title else {
            return call.name
        }
        return String(localized: "Asked · \(question)")
    }

    private static func summary(_ steps: [ActivityStep], streaming: Bool) -> String {
        if streaming, let last = steps.last {
            switch last {
            case .tool(let call):
                if call.summary.kind == .question { return Self.stepName(call) }
                if let title = call.summary.title {
                    return "\(call.name) · \(title)"
                }
                return "\(call.name)…"
            case .reasoning: return String(localized: "Thinking…")
            }
        }
        var names: [String] = []
        var thinkingCount = 0
        for step in steps {
            switch step {
            case .tool(let call):
                let name = Self.stepName(call)
                if !names.contains(name) { names.append(name) }
            case .reasoning: thinkingCount += 1
            }
        }
        var parts: [String] = []
        if thinkingCount > 0 { parts.append(String(localized: "\(thinkingCount) thoughts")) }
        if !names.isEmpty {
            let shown = names.prefix(3).joined(separator: " · ")
            parts.append(names.count > 3 ? "\(shown) +\(names.count - 3)" : shown)
        }
        return parts.isEmpty
            ? String(localized: "\(steps.count) steps") : parts.joined(separator: "  ·  ")
    }
}

extension UIFont {
    func withTraits(_ traits: UIFontDescriptor.SymbolicTraits) -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(fontDescriptor.symbolicTraits.union(traits))
        else { return self }
        return UIFont(descriptor: descriptor, size: 0)
    }

    /// Digits of one width, for anything that changes while a person is looking at it.
    func monospacedDigits() -> UIFont {
        let settings: [UIFontDescriptor.FeatureKey: Int] = [
            .type: kNumberSpacingType, .selector: kMonospacedNumbersSelector,
        ]
        return UIFont(
            descriptor: fontDescriptor.addingAttributes([.featureSettings: [settings]]), size: 0)
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

        NotificationCenter.default.addObserver(
            self, selector: #selector(restartPulsing),
            name: UIApplication.willEnterForegroundNotification, object: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func prepareForReuse() {
        super.prepareForReuse()
        contentView.layer.removeAllAnimations()
        contentView.alpha = 1
        contentView.transform = .identity
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { startPulsing() }
    }

    /// Backgrounding strips repeating CAAnimations while the cell stays in the
    /// window, so didMoveToWindow never refires; restart on foreground instead.
    @objc private func restartPulsing() {
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
    private var submitted = false
    private var onSubmit: (([[String]]) -> Void)?
    private var onSkip: (() -> Void)?
    private var onCustom: ((Int) -> Void)?
    private var onSelectionChanged: ((Selection) -> Void)?
    private let submitButton = PrimaryButton(title: String(localized: "Answer"))
    private let skipButton = UIButton(type: .system)
    private var glassTop: NSLayoutConstraint!

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

        glassTop = glass.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Spacing.xs)
        NSLayoutConstraint.activate([
            glassTop,
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

    /// Extra gap above the card when this row opens a new turn.
    var turnInset: CGFloat = 0 {
        didSet { glassTop.constant = Theme.Spacing.xs + turnInset }
    }

    func configure(
        request: QuestionRequest,
        selection: Selection,
        submitted: Bool = false,
        onSelectionChanged: @escaping (Selection) -> Void,
        onSubmit: @escaping ([[String]]) -> Void,
        onCustom: @escaping (Int) -> Void,
        onSkip: @escaping () -> Void
    ) {
        self.submitted = submitted
        stack.isUserInteractionEnabled = !submitted
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
        title.text = String(localized: "The agent has a question")
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
        skipButton.setTitle(String(localized: "Skip"), for: .normal)
        skipButton.titleLabel?.font = Theme.Font.caption()
        skipButton.setTitleColor(Theme.Color.secondaryLabel, for: .normal)
        skipButton.addTarget(self, action: #selector(skipTapped), for: .touchUpInside)
        footer.addArrangedSubview(skipButton)
        if !isSingleTapFastPath {
            submitButton.setTitle(String(localized: "Answer"))
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
        var titleAttr = AttributedString(
            custom?.isEmpty == false ? custom! : String(localized: "Other…"))
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

    /// Answering resolves the pending question server-side exactly once, so
    /// the card stops accepting taps until it is configured with a new request.
    private func markSubmitted() {
        submitted = true
        stack.isUserInteractionEnabled = false
    }

    private func optionTapped(questionIndex: Int, optionIndex: Int, multiple: Bool) {
        Theme.Haptics.selection()
        guard let request, !submitted else { return }
        var picked = selection.picked[questionIndex] ?? []
        if multiple {
            if picked.contains(optionIndex) { picked.remove(optionIndex) } else { picked.insert(optionIndex) }
        } else {
            picked = [optionIndex]
        }
        selection.picked[questionIndex] = picked
        onSelectionChanged?(selection)
        if isSingleTapFastPath, let answers = selection.answers(for: request) {
            markSubmitted()
            rebuild()
            onSubmit?(answers)
            return
        }
        rebuild()
    }

    @objc private func submitTapped() {
        guard let request, !submitted, let answers = selection.answers(for: request) else { return }
        Theme.Haptics.send()
        markSubmitted()
        onSubmit?(answers)
    }

    @objc private func skipTapped() {
        guard !submitted else { return }
        Theme.Haptics.warning()
        markSubmitted()
        onSkip?()
    }
}
