import TailscodeCore
import CodingAgentKit
import UIKit

/// The sheet `/compact` opens instead of firing the command bare. Compaction is destructive to the
/// agent's memory and takes minutes, so it gets a decision screen: what it does, what it costs, and
/// a place to say what the summary must not lose.
@MainActor
final class CompactPreflightViewController: UIViewController {
    private let facts: CompactPreflight
    private let draftScope: DraftScope
    private let onCompact: (String?) -> Void
    private let instructions = UITextField()
    private let scroll = UIScrollView()

    /// A typed-out `/compact keep the failing tests` arrives as the instruction and wins; with
    /// nothing typed the field hands back whatever was last left here, because cancelling this
    /// sheet is the ordinary way to leave it and must not cost the sentence someone composed.
    init(
        messageCount: Int, lastCompaction: Compaction?, initialInstruction: String = "",
        showsInstruction: Bool, draftScope: DraftScope, onCompact: @escaping (String?) -> Void
    ) {
        self.facts = CompactPreflight.make(
            messageCount: messageCount, lastCompaction: lastCompaction,
            showsInstruction: showsInstruction)
        self.draftScope = draftScope
        self.onCompact = onCompact
        super.init(nibName: nil, bundle: nil)
        instructions.text =
            initialInstruction.isEmpty ? DraftStore.text(for: draftScope) : initialInstruction
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.groupedBackground
        title = String(localized: "Compact")
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .cancel,
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        build()
    }

    private func build() {
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.keyboardDismissMode = .interactive
        view.addSubview(scroll)

        let stack = UIStackView(
            arrangedSubviews: [hero()] + facts.paragraphs.map { body($0) } + [
                facts.showsInstruction ? instructionsField() : nil,
                facts.lastTime.map { body($0, color: Theme.Color.tertiaryLabel) },
                body(facts.wait, color: Theme.Color.tertiaryLabel),
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
        headline.text = facts.headline
        headline.font = Theme.Ramp.font(.headline)
        headline.adjustsFontForContentSizeCategory = true
        headline.numberOfLines = 0
        headline.textAlignment = .center

        let subtitle = UILabel()
        subtitle.text = facts.subtitle
        subtitle.font = Theme.Ramp.font(.seamFootnote)
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
        label.font = Theme.Ramp.font(.panelLabel)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = color
        label.numberOfLines = 0
        return label
    }

    private func instructionsField() -> UIView {
        let caption = UILabel()
        caption.text = facts.fieldCaption.uppercased()
        caption.font = Theme.Ramp.font(.metricLabel)
        caption.adjustsFontForContentSizeCategory = true
        caption.textColor = Theme.Color.tertiaryLabel

        instructions.placeholder = facts.fieldPlaceholder
        instructions.font = Theme.Ramp.font(.composer)
        instructions.adjustsFontForContentSizeCategory = true
        instructions.borderStyle = .none
        instructions.autocapitalizationType = .none
        instructions.returnKeyType = .done
        instructions.clearButtonMode = .whileEditing
        instructions.addAction(
            UIAction { [weak self] _ in self?.instructions.resignFirstResponder() },
            for: .editingDidEndOnExit)
        instructions.addAction(
            UIAction { [weak self] _ in
                guard let self else { return }
                DraftStore.record(instructions.text ?? "", for: draftScope)
            }, for: .editingChanged)

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

    private func compactButton() -> UIView {
        var config = Theme.Glass.buttonConfiguration(prominent: true)
        config.title = facts.confirmTitle
        config.baseBackgroundColor = Theme.Color.accent
        config.contentInsets = NSDirectionalEdgeInsets(
            top: 14, leading: 20, bottom: 14, trailing: 20)
        let button = UIButton(configuration: config)
        button.addAction(
            UIAction { [weak self] _ in
                guard let self else { return }
                Theme.Haptics.send()
                let text = self.instructions.text?.trimmingCharacters(in: .whitespacesAndNewlines)
                DraftStore.clear(self.draftScope)
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
        title = String(localized: "Summary")
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
        label.font = Theme.Ramp.font(.seamFootnote)
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
        CompactionStory.summaryHeader(compaction)
    }
}
