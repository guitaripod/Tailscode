import CodingAgentKit
import UIKit

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
    private var onEditingBegan: (() -> Void)?
    private var onSelectionChanged: ((Selection) -> Void)?
    private var optionButtons: [String: UIButton] = [:]
    private var answerFields: [Int: AnswerField] = [:]
    private let submitButton = PrimaryButton(title: String(localized: "Answer"))
    private let skipButton = SlopButton(type: .system)
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

        glassTop = glass.topAnchor.constraint(equalTo: contentView.topAnchor)
        NSLayoutConstraint.activate([
            glassTop,
            glass.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Spacing.l),
            glass.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.l),

            stack.topAnchor.constraint(equalTo: glass.topAnchor, constant: Theme.Spacing.l),
            stack.bottomAnchor.constraint(equalTo: glass.bottomAnchor, constant: -Theme.Spacing.l),
            stack.leadingAnchor.constraint(equalTo: glass.leadingAnchor, constant: Theme.Spacing.l),
            stack.trailingAnchor.constraint(equalTo: glass.trailingAnchor, constant: -Theme.Spacing.l),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    var gapAbove: CGFloat = 0 {
        didSet { glassTop.constant = gapAbove }
    }

    func configure(
        request: QuestionRequest,
        selection: Selection,
        submitted: Bool = false,
        onSelectionChanged: @escaping (Selection) -> Void,
        onSubmit: @escaping ([[String]]) -> Void,
        onEditingBegan: @escaping () -> Void,
        onSkip: @escaping () -> Void
    ) {
        if self.request?.id != request.id { discardRows() }
        self.submitted = submitted
        stack.isUserInteractionEnabled = !submitted
        self.request = request
        self.selection = selection
        self.onSelectionChanged = onSelectionChanged
        self.onSubmit = onSubmit
        self.onEditingBegan = onEditingBegan
        self.onSkip = onSkip
        rebuild()
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        endEditing(true)
        request = nil
        discardRows()
    }

    /// The rows a rebuild keeps hold of: the option buttons it restyles in place, and the fields
    /// whose text — and whose keyboard — must survive a card being drawn again around them. They
    /// belong to one ask only, so a cell handed a different question starts from nothing.
    private func discardRows() {
        answerFields.values.forEach { $0.removeFromSuperview() }
        answerFields.removeAll()
        optionButtons.removeAll()
    }

    private var isSingleTapFastPath: Bool {
        guard let request else { return false }
        return request.questions.count == 1
            && !(request.questions.first?.multiple ?? false)
    }

    private func rebuild() {
        let editing = answerFields.first { $0.value.isFirstResponder }?.key
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        optionButtons.removeAll()
        guard let request else { return }

        let title = UILabel()
        title.text = String(localized: "The agent has a question")
        title.font = Theme.Ramp.font(.panelFootnote)
        title.textColor = Theme.Color.secondaryLabel
        stack.addArrangedSubview(title)

        for (questionIndex, item) in request.questions.enumerated() {
            if !item.header.isEmpty {
                let header = UILabel()
                header.attributedText = NSAttributedString(
                    string: item.header.uppercased(),
                    attributes: Theme.Ramp.attributes(.sectionLabel, color: Theme.Color.accent))
                stack.addArrangedSubview(header)
                stack.setCustomSpacing(Theme.Spacing.xs, after: header)
            }
            let question = UILabel()
            question.text = item.question
            question.font = Theme.Ramp.font(.cardTitle)
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
            if item.custom || item.options.isEmpty {
                stack.addArrangedSubview(answerField(questionIndex: questionIndex, item: item))
            }
            if questionIndex < request.questions.count - 1 {
                stack.setCustomSpacing(Theme.Spacing.xl, after: stack.arrangedSubviews.last!)
            }
        }

        let footer = UIStackView()
        footer.axis = .horizontal
        footer.spacing = Theme.Spacing.m
        skipButton.setTitle(String(localized: "Skip"), for: .normal)
        skipButton.titleLabel?.font = Theme.Ramp.font(.control)
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
        if let editing, !submitted { answerFields[editing]?.becomeFirstResponder() }
    }

    private func optionRow(
        option: QuestionRequest.Option, selected: Bool,
        questionIndex: Int, optionIndex: Int, multiple: Bool
    ) -> UIView {
        let button = UIButton(type: .custom)
        button.contentHorizontalAlignment = .leading
        button.addAction(
            UIAction { [weak self] _ in
                self?.optionTapped(questionIndex: questionIndex, optionIndex: optionIndex, multiple: multiple)
            }, for: .touchUpInside)
        optionButtons["\(questionIndex):\(optionIndex)"] = button
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: TouchSlop.hit).isActive = true
        style(button, as: option, selected: selected, multiple: multiple)
        return button
    }

    /// An option wears its state rather than being rebuilt into it: a card with a half-typed
    /// answer in it is redrawn every time a box is ticked, and redrawing a field is how a keyboard
    /// gets closed under somebody's thumb.
    private func style(
        _ button: UIButton, as option: QuestionRequest.Option, selected: Bool, multiple: Bool
    ) {
        var config = UIButton.Configuration.plain()
        config.baseForegroundColor = Theme.Color.label
        config.background.backgroundColor =
            selected
            ? Theme.Color.accent.withAlphaComponent(0.18)
            : Theme.Color.secondaryBackground
        config.background.cornerRadius = Theme.Radius.control
        config.contentInsets = NSDirectionalEdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12)
        var titleAttr = AttributedString(option.label)
        titleAttr.font = Theme.Ramp.font(.cardTitle)
        config.attributedTitle = titleAttr
        if !option.description.isEmpty {
            var subAttr = AttributedString(option.description)
            subAttr.font = Theme.Ramp.font(.panelDetail)
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
        button.configuration = config
        button.tintColor = selected ? Theme.Color.accent : Theme.Color.tertiaryLabel
        button.accessibilityTraits = selected ? [.button, .selected] : .button
    }

    /// The answer nobody listed. Every ask takes one — the reply travels back as an ordinary
    /// message — so the card always offers a line to type it on rather than hiding it behind a
    /// sheet: an option you have to go looking for is an option that reads as absent, and the
    /// answer the agent needs is often the one it did not think to offer.
    ///
    /// The field is kept across rebuilds so that ticking a box beside it neither empties it nor
    /// closes the keyboard, and what is typed is reported like any other selection — which is
    /// what puts it in the draft store, keystroke by keystroke, so a half-written answer outlives
    /// the app being closed on the question it answers.
    private func answerField(questionIndex: Int, item: QuestionRequest.Item) -> UIView {
        let field = answerFields[questionIndex] ?? makeAnswerField(questionIndex: questionIndex, item: item)
        answerFields[questionIndex] = field
        if !field.isFirstResponder { field.text = selection.custom[questionIndex] ?? "" }
        field.isEnabled = !submitted
        return field
    }

    private func makeAnswerField(questionIndex: Int, item: QuestionRequest.Item) -> AnswerField {
        let field = AnswerField()
        let fastPath = isSingleTapFastPath
        field.placeholder = String(localized: "Type your answer")
        field.accessibilityLabel = item.question
        field.font = Theme.Ramp.font(.answer)
        field.adjustsFontForContentSizeCategory = true
        field.textColor = Theme.Color.label
        field.backgroundColor = Theme.Color.secondaryBackground
        field.layer.cornerRadius = Theme.Radius.control
        field.layer.cornerCurve = .continuous
        field.clearButtonMode = .whileEditing
        field.returnKeyType = fastPath ? .send : .done
        field.enablesReturnKeyAutomatically = true
        field.heightAnchor.constraint(greaterThanOrEqualToConstant: 44).isActive = true
        field.addAction(
            UIAction { [weak self] _ in
                self?.answerTyped(questionIndex: questionIndex, multiple: item.multiple)
            }, for: .editingChanged)
        field.addAction(
            UIAction { [weak self] _ in self?.onEditingBegan?() }, for: .editingDidBegin)
        field.addAction(
            UIAction { [weak self] _ in self?.answerEntered(questionIndex: questionIndex) },
            for: .primaryActionTriggered)
        return field
    }

    /// A typed answer and a ticked option are the same answer to a question that takes one, so
    /// typing takes the ticks off. On a question that takes several, both stand.
    private func answerTyped(questionIndex: Int, multiple: Bool) {
        guard let request, !submitted else { return }
        let text =
            answerFields[questionIndex]?.text?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        selection.custom[questionIndex] = text.isEmpty ? nil : text
        if !multiple, !text.isEmpty, selection.picked[questionIndex]?.isEmpty == false {
            selection.picked[questionIndex] = []
            restyle(questionIndex)
        }
        onSelectionChanged?(selection)
        submitButton.isEnabled = selection.answers(for: request) != nil
    }

    /// Return sends where a tap on an option would have: one question, one answer, nothing else
    /// to fill in. Anywhere else it just puts the keyboard away, because the ask is not finished.
    private func answerEntered(questionIndex: Int) {
        guard let request, !submitted,
            let text = answerFields[questionIndex]?.text?
                .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return }
        selection.custom[questionIndex] = text
        guard isSingleTapFastPath else {
            onSelectionChanged?(selection)
            answerFields[questionIndex]?.resignFirstResponder()
            return
        }
        selection.picked[questionIndex] = []
        onSelectionChanged?(selection)
        guard let answers = selection.answers(for: request) else { return }
        Theme.Haptics.send()
        markSubmitted()
        rebuild()
        onSubmit?(answers)
    }

    private func restyle(_ questionIndex: Int) {
        guard let item = request?.questions[safe: questionIndex] else { return }
        for (optionIndex, option) in item.options.enumerated() {
            guard let button = optionButtons["\(questionIndex):\(optionIndex)"] else { continue }
            style(
                button, as: option,
                selected: selection.picked[questionIndex]?.contains(optionIndex) ?? false,
                multiple: item.multiple)
        }
    }

    /// Answering resolves the pending question server-side exactly once, so
    /// the card stops accepting taps until it is configured with a new request.
    private func markSubmitted() {
        submitted = true
        stack.isUserInteractionEnabled = false
        endEditing(true)
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
        if isSingleTapFastPath { selection.custom[questionIndex] = nil }
        onSelectionChanged?(selection)
        if isSingleTapFastPath, let answers = selection.answers(for: request) {
            markSubmitted()
            rebuild()
            onSubmit?(answers)
            return
        }
        restyle(questionIndex)
        submitButton.isEnabled = selection.answers(for: request) != nil
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

/// The line an answer of your own is written on: the same ground and the same corner as the
/// options above it, inset far enough that the text starts where their labels do.
private final class AnswerField: UITextField {
    private static let padding = UIEdgeInsets(top: 10, left: 12, bottom: 10, right: 12)
    private static let clearWidth: CGFloat = 28

    override func textRect(forBounds bounds: CGRect) -> CGRect { inset(bounds) }
    override func placeholderRect(forBounds bounds: CGRect) -> CGRect { inset(bounds) }
    override func editingRect(forBounds bounds: CGRect) -> CGRect {
        var rect = inset(bounds)
        if clearButtonMode != .never { rect.size.width -= Self.clearWidth }
        return rect
    }

    override func clearButtonRect(forBounds bounds: CGRect) -> CGRect {
        super.clearButtonRect(forBounds: bounds).offsetBy(dx: -Self.padding.right + 4, dy: 0)
    }

    private func inset(_ bounds: CGRect) -> CGRect { bounds.inset(by: Self.padding) }
}
