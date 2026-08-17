import TailscodeCore
import UIKit

/// The sheet `/design` opens instead of sending the word. A design spends a whole turn on somebody
/// else's machine drawing pictures, so it gets a decision screen: what it will do, what it will not
/// touch, how many alternatives to draw, and where they will land.
@MainActor
final class DesignPreflightViewController: UIViewController {
    private var facts: DesignPreflight
    private let onDesign: (DesignBrief) -> Void
    private let requestField = UITextField()
    private let referenceField = UITextField()
    private let notesField = UITextField()
    private let counts = UISegmentedControl(
        items: (DesignBrief.minimumCount...DesignBrief.maximumCount).map { "\($0)" })
    private let waitLabel = UILabel()
    private let scroll = UIScrollView()
    private var count = DesignBrief.defaultCount

    init(request: String, onDesign: @escaping (DesignBrief) -> Void) {
        facts = DesignPreflight.make(
            directory: DesignBrief(request: request).directory, count: DesignBrief.defaultCount)
        self.onDesign = onDesign
        super.init(nibName: nil, bundle: nil)
        requestField.text = request
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.groupedBackground
        title = String(localized: "Design")
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            systemItem: .cancel,
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        build()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        requestField.becomeFirstResponder()
    }

    private func build() {
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.keyboardDismissMode = .interactive
        view.addSubview(scroll)

        counts.selectedSegmentIndex = count - DesignBrief.minimumCount
        counts.addAction(
            UIAction { [weak self] _ in
                guard let self else { return }
                self.count = self.counts.selectedSegmentIndex + DesignBrief.minimumCount
                Theme.Haptics.step()
                self.refreshWait()
            }, for: .valueChanged)

        waitLabel.text = facts.wait
        waitLabel.font = Theme.Ramp.font(.panelFootnote)
        waitLabel.adjustsFontForContentSizeCategory = true
        waitLabel.textColor = Theme.Color.tertiaryLabel
        waitLabel.numberOfLines = 0
        waitLabel.lineBreakMode = .byTruncatingMiddle

        let stack = UIStackView(arrangedSubviews: [
            hero(),
            body(facts.paragraphs[0]),
            body(facts.paragraphs[1]),
            field(
                requestField, caption: facts.requestCaption, placeholder: facts.requestPlaceholder,
                watches: true),
            field(
                referenceField, caption: facts.referenceCaption,
                placeholder: facts.referencePlaceholder),
            field(notesField, caption: facts.notesCaption, placeholder: facts.notesPlaceholder),
            captioned(facts.countCaption, control: counts),
            waitLabel,
        ])
        stack.axis = .vertical
        stack.spacing = Theme.Spacing.m
        stack.setCustomSpacing(Theme.Spacing.xl, after: stack.arrangedSubviews[0])
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        let action = designButton()
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
                systemName: "rectangle.3.group",
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

        let stack = UIStackView(arrangedSubviews: [icon, headline])
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

    private func body(_ text: String) -> UIView {
        let label = UILabel()
        label.text = text
        label.font = Theme.Ramp.font(.panelLabel)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = Theme.Color.secondaryLabel
        label.numberOfLines = 0
        return label
    }

    private func captioned(_ caption: String, control: UIView) -> UIView {
        let label = UILabel()
        label.text = caption.uppercased()
        label.font = Theme.Ramp.font(.metricLabel)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = Theme.Color.tertiaryLabel

        let stack = UIStackView(arrangedSubviews: [label, control])
        stack.axis = .vertical
        stack.spacing = Theme.Spacing.s
        stack.alignment = .fill
        return stack
    }

    private func field(
        _ field: UITextField, caption: String, placeholder: String, watches: Bool = false
    ) -> UIView {
        field.placeholder = placeholder
        field.font = Theme.Ramp.font(.composer)
        field.adjustsFontForContentSizeCategory = true
        field.borderStyle = .none
        field.autocapitalizationType = .sentences
        field.returnKeyType = .done
        field.clearButtonMode = .whileEditing
        field.addAction(
            UIAction { [weak field] _ in field?.resignFirstResponder() },
            for: .editingDidEndOnExit)
        if watches {
            field.addAction(
                UIAction { [weak self] _ in self?.refreshWait() }, for: .editingChanged)
        }

        let holder = UIView()
        holder.backgroundColor = Theme.Color.secondaryBackground
        holder.layer.cornerRadius = Theme.Radius.control
        holder.layer.cornerCurve = .continuous
        field.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(field)
        NSLayoutConstraint.activate([
            field.topAnchor.constraint(equalTo: holder.topAnchor, constant: Theme.Spacing.m),
            field.bottomAnchor.constraint(equalTo: holder.bottomAnchor, constant: -Theme.Spacing.m),
            field.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: Theme.Spacing.m),
            field.trailingAnchor.constraint(
                equalTo: holder.trailingAnchor, constant: -Theme.Spacing.m),
        ])
        return captioned(caption, control: holder)
    }

    /// Where the mocks will land, restated as the request is typed: the folder is derived from the
    /// words, and a person about to spend a turn is owed the address it will land at.
    private func refreshWait() {
        facts = DesignPreflight.make(directory: brief().directory, count: count)
        waitLabel.text = facts.wait
    }

    private func brief() -> DesignBrief {
        DesignBrief(
            request: requestField.text ?? "", count: count, reference: referenceField.text ?? "",
            notes: notesField.text ?? "")
    }

    private func designButton() -> UIView {
        var config = Theme.Glass.buttonConfiguration(prominent: true)
        config.title = facts.confirmTitle
        config.baseBackgroundColor = Theme.Color.accent
        config.contentInsets = NSDirectionalEdgeInsets(
            top: 14, leading: 20, bottom: 14, trailing: 20)
        let button = UIButton(configuration: config)
        button.addAction(
            UIAction { [weak self] _ in
                guard let self else { return }
                let brief = self.brief()
                guard brief.isReady else {
                    self.requestField.becomeFirstResponder()
                    Theme.Haptics.warning()
                    return
                }
                Theme.Haptics.send()
                self.dismiss(animated: true) { [onDesign = self.onDesign] in onDesign(brief) }
            }, for: .touchUpInside)
        return button
    }
}
