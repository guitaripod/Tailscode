import CodingAgentKit
import UIKit

/// The sheet `/compact` opens instead of firing the command bare. Compaction is destructive to the
/// agent's memory and takes minutes, so it gets a decision screen: what it does, what it costs, and
/// a place to say what the summary must not lose.
@MainActor
final class CompactPreflightViewController: UIViewController {
    private let messageCount: Int
    private let lastCompaction: Compaction?
    private let onCompact: (String?) -> Void
    private let instructions = UITextField()
    private let scroll = UIScrollView()

    init(messageCount: Int, lastCompaction: Compaction?, onCompact: @escaping (String?) -> Void) {
        self.messageCount = messageCount
        self.lastCompaction = lastCompaction
        self.onCompact = onCompact
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.groupedBackground
        title = "Compact"
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .cancel,
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        build()
    }

    private func build() {
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.keyboardDismissMode = .interactive
        view.addSubview(scroll)

        let stack = UIStackView(arrangedSubviews: [
            hero(),
            body(
                "The agent re-reads this conversation, writes a summary of it, and carries the "
                    + "summary forward instead of the whole transcript."),
            body("Nothing here disappears — you keep every message. Only the agent's memory shrinks."),
            instructionsField(),
            previously(),
            body(
                "Takes a minute or two, and the conversation is busy until it finishes.",
                color: Theme.Color.tertiaryLabel),
        ].compactMap { $0 })
        stack.axis = .vertical
        stack.spacing = Theme.Spacing.m
        stack.setCustomSpacing(Theme.Spacing.xl, after: stack.arrangedSubviews[0])
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        let action = compactButton()
        action.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(action)

        let content = scroll.contentLayoutGuide
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: action.topAnchor, constant: -Theme.Spacing.m),

            action.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Theme.Spacing.l),
            action.trailingAnchor.constraint(
                equalTo: view.trailingAnchor, constant: -Theme.Spacing.l),
            action.bottomAnchor.constraint(
                equalTo: view.keyboardLayoutGuide.topAnchor, constant: -Theme.Spacing.l),

            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: Theme.Spacing.l),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -Theme.Spacing.l),
            stack.leadingAnchor.constraint(
                equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: Theme.Spacing.l),
            stack.trailingAnchor.constraint(
                equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -Theme.Spacing.l),
        ])
    }

    private func hero() -> UIView {
        let icon = UIImageView(
            image: UIImage(
                systemName: "arrow.down.right.and.arrow.up.left",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 26, weight: .semibold)))
        icon.tintColor = Theme.Color.accent
        icon.contentMode = .center
        icon.backgroundColor = Theme.Color.accent.withAlphaComponent(0.12)
        icon.layer.cornerRadius = 28
        icon.layer.cornerCurve = .continuous
        icon.translatesAutoresizingMaskIntoConstraints = false

        let headline = UILabel()
        headline.text = "Free up the context window"
        headline.font = UIFont.preferredFont(forTextStyle: .title3).withTraits(.traitBold)
        headline.adjustsFontForContentSizeCategory = true
        headline.numberOfLines = 0
        headline.textAlignment = .center

        let subtitle = UILabel()
        subtitle.text =
            messageCount > 0
            ? "\(messageCount) message\(messageCount == 1 ? "" : "s") in this conversation"
            : "This conversation"
        subtitle.font = .preferredFont(forTextStyle: .footnote)
        subtitle.adjustsFontForContentSizeCategory = true
        subtitle.textColor = Theme.Color.secondaryLabel
        subtitle.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [icon, headline, subtitle])
        stack.axis = .vertical
        stack.alignment = .center
        stack.spacing = Theme.Spacing.s
        stack.setCustomSpacing(Theme.Spacing.m, after: icon)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 56),
            icon.heightAnchor.constraint(equalToConstant: 56),
        ])
        return stack
    }

    private func body(_ text: String, color: UIColor = Theme.Color.secondaryLabel) -> UIView {
        let label = UILabel()
        label.text = text
        label.font = .preferredFont(forTextStyle: .subheadline)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = color
        label.numberOfLines = 0
        return label
    }

    private func instructionsField() -> UIView {
        let caption = UILabel()
        caption.text = "WHAT MUST THE SUMMARY KEEP?"
        caption.font = .preferredFont(forTextStyle: .caption2)
        caption.adjustsFontForContentSizeCategory = true
        caption.textColor = Theme.Color.tertiaryLabel

        instructions.placeholder = "Optional — e.g. the failing test names"
        instructions.font = Theme.Font.body()
        instructions.adjustsFontForContentSizeCategory = true
        instructions.borderStyle = .none
        instructions.autocapitalizationType = .none
        instructions.returnKeyType = .done
        instructions.clearButtonMode = .whileEditing
        instructions.addAction(
            UIAction { [weak self] _ in self?.instructions.resignFirstResponder() },
            for: .editingDidEndOnExit)

        let field = UIView()
        field.backgroundColor = Theme.Color.secondaryBackground
        field.layer.cornerRadius = Theme.Radius.control
        field.layer.cornerCurve = .continuous
        instructions.translatesAutoresizingMaskIntoConstraints = false
        field.addSubview(instructions)
        NSLayoutConstraint.activate([
            instructions.topAnchor.constraint(equalTo: field.topAnchor, constant: Theme.Spacing.m),
            instructions.bottomAnchor.constraint(
                equalTo: field.bottomAnchor, constant: -Theme.Spacing.m),
            instructions.leadingAnchor.constraint(
                equalTo: field.leadingAnchor, constant: Theme.Spacing.m),
            instructions.trailingAnchor.constraint(
                equalTo: field.trailingAnchor, constant: -Theme.Spacing.m),
        ])

        let stack = UIStackView(arrangedSubviews: [caption, field])
        stack.axis = .vertical
        stack.spacing = Theme.Spacing.s
        return stack
    }

    /// A conversation compacted once usually compacts again; showing the last result sets the
    /// expectation for this one instead of leaving the wait unexplained.
    private func previously() -> UIView? {
        guard let lastCompaction, let before = lastCompaction.tokensBefore,
            let after = lastCompaction.tokensAfter
        else { return nil }
        var text =
            "Last time: \(CompactionCell.tokens(before)) → \(CompactionCell.tokens(after)) tokens"
        if let duration = lastCompaction.duration, duration >= 1 {
            text += " in \(CompactionCell.elapsed(duration))"
        }
        return body(text + ".", color: Theme.Color.tertiaryLabel)
    }

    private func compactButton() -> UIView {
        var config = Theme.Glass.buttonConfiguration(prominent: true)
        config.title = "Compact conversation"
        config.baseBackgroundColor = Theme.Color.accent
        config.contentInsets = NSDirectionalEdgeInsets(
            top: 14, leading: 20, bottom: 14, trailing: 20)
        let button = UIButton(configuration: config)
        button.addAction(
            UIAction { [weak self] _ in
                guard let self else { return }
                Theme.Haptics.send()
                let text = self.instructions.text?.trimmingCharacters(in: .whitespacesAndNewlines)
                self.dismiss(animated: true) { [onCompact = self.onCompact] in
                    onCompact(text?.isEmpty == false ? text : nil)
                }
            }, for: .touchUpInside)
        return button
    }
}

/// The summary a compaction produced, on demand. It is tens of thousands of characters of
/// machine-facing prose — readable, occasionally essential, and never something to inline in a
/// transcript.
@MainActor
final class CompactionSummaryViewController: UIViewController {
    private let compaction: Compaction
    private let textView = UITextView()

    init(compaction: Compaction) {
        self.compaction = compaction
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.background
        title = "Summary"
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "doc.on.doc"),
            primaryAction: UIAction { [weak self] _ in
                UIPasteboard.general.string = self?.compaction.summary
                Theme.Haptics.success()
            })
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .done,
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        build()
    }

    private func build() {
        textView.isEditable = false
        textView.backgroundColor = .clear
        textView.alwaysBounceVertical = true
        textView.adjustsFontForContentSizeCategory = true
        textView.textContainerInset = UIEdgeInsets(
            top: Theme.Spacing.m, left: Theme.Spacing.l, bottom: Theme.Spacing.xl,
            right: Theme.Spacing.l)
        textView.attributedText = TextBubbleCell.rendered(
            compaction.summary ?? "", color: Theme.Color.label)
        textView.translatesAutoresizingMaskIntoConstraints = false

        let header = statsHeader()
        header.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(header)
        view.addSubview(textView)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            header.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: view.trailingAnchor),

            textView.topAnchor.constraint(equalTo: header.bottomAnchor),
            textView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func statsHeader() -> UIView {
        let container = UIView()
        container.backgroundColor = Theme.Color.secondaryBackground

        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .footnote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = Theme.Color.secondaryLabel
        label.numberOfLines = 0
        label.text = Self.stats(for: compaction)
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: Theme.Spacing.m),
            label.bottomAnchor.constraint(
                equalTo: container.bottomAnchor, constant: -Theme.Spacing.m),
            label.leadingAnchor.constraint(
                equalTo: container.leadingAnchor, constant: Theme.Spacing.l),
            label.trailingAnchor.constraint(
                equalTo: container.trailingAnchor, constant: -Theme.Spacing.l),
        ])
        return container
    }

    private static func stats(for compaction: Compaction) -> String {
        var parts: [String] = []
        if let before = compaction.tokensBefore, let after = compaction.tokensAfter {
            parts.append("\(CompactionCell.tokens(before)) → \(CompactionCell.tokens(after)) tokens")
        }
        if let reduction = compaction.reduction {
            parts.append("\(Int((reduction * 100).rounded()))% freed")
        }
        if let duration = compaction.duration, duration >= 1 {
            parts.append(CompactionCell.elapsed(duration))
        }
        guard !parts.isEmpty else { return "What the agent carries forward from here." }
        return parts.joined(separator: " · ") + " — this is what the agent carries forward."
    }
}
