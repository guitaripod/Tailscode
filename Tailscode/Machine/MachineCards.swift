import TailscodeCore
import UIKit

/// The page every machine screen is laid out on: a scrolling column of grouped cards on the
/// grouped background, read at a readable width on an iPad.
@MainActor
enum MachinePage {
    static func install(in controller: UIViewController) -> (scroll: UIScrollView, column: UIStackView) {
        controller.view.backgroundColor = Theme.Color.groupedBackground
        let scroll = UIScrollView()
        scroll.alwaysBounceVertical = true
        scroll.keyboardDismissMode = .interactive
        scroll.translatesAutoresizingMaskIntoConstraints = false
        controller.view.addSubview(scroll)
        let column = UIStackView()
        column.axis = .vertical
        column.spacing = Theme.Spacing.m
        column.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(column)
        let guide = controller.view.readableContentGuide
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: controller.view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor),
            column.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: Theme.Spacing.m),
            column.bottomAnchor.constraint(
                equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Theme.Spacing.xl),
            column.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            column.trailingAnchor.constraint(equalTo: guide.trailingAnchor),
        ])
        return (scroll, column)
    }

    static func header(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text.uppercased(with: .current)
        label.font = Theme.Ramp.font(.sectionLabel)
        label.textColor = Theme.Color.secondaryLabel
        label.adjustsFontForContentSizeCategory = true
        return label
    }

    static func footnote(_ text: String) -> UILabel {
        let label = UILabel()
        label.text = text
        label.numberOfLines = 0
        label.font = Theme.Ramp.font(.panelFootnote)
        label.textColor = Theme.Color.secondaryLabel
        label.adjustsFontForContentSizeCategory = true
        return label
    }

    static func clear(_ column: UIStackView) {
        for view in column.arrangedSubviews {
            column.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
    }

    /// A capsule press in a row's trailing edge.
    static func pill(_ title: String, prominent: Bool = false, action: @escaping () -> Void) -> UIButton {
        var config: UIButton.Configuration = prominent ? .filled() : .gray()
        config.title = title
        config.cornerStyle = .capsule
        config.buttonSize = .small
        config.baseForegroundColor = prominent ? Theme.Color.onAccent : Theme.Color.accent
        if prominent { config.baseBackgroundColor = Theme.Color.accent }
        let button = UIButton(configuration: config)
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        button.addAction(UIAction { _ in action() }, for: .touchUpInside)
        return button
    }
}

/// A grouped card: rows one under another with hairlines between them.
final class MachineCardView: UIView {
    private let stack = UIStackView()

    init() {
        super.init(frame: .zero)
        backgroundColor = Theme.Color.groupedSurface
        layer.cornerRadius = Theme.Radius.card
        layer.cornerCurve = .continuous
        clipsToBounds = true
        stack.axis = .vertical
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func add(_ row: UIView) {
        if !stack.arrangedSubviews.isEmpty {
            let rule = UIView()
            rule.backgroundColor = Theme.Color.separator
            rule.translatesAutoresizingMaskIntoConstraints = false
            rule.heightAnchor.constraint(equalToConstant: 1 / max(UIScreen.main.scale, 1)).isActive = true
            let inset = UIView()
            inset.addSubview(rule)
            NSLayoutConstraint.activate([
                rule.topAnchor.constraint(equalTo: inset.topAnchor),
                rule.bottomAnchor.constraint(equalTo: inset.bottomAnchor),
                rule.leadingAnchor.constraint(equalTo: inset.leadingAnchor, constant: Theme.Spacing.m),
                rule.trailingAnchor.constraint(equalTo: inset.trailingAnchor),
            ])
            stack.addArrangedSubview(inset)
        }
        stack.addArrangedSubview(row)
    }

    var isEmpty: Bool { stack.arrangedSubviews.isEmpty }
}

/// One row of a card: a leading mark, a title over a detail, and whatever trails it. Tappable
/// when given an action.
final class MachineRowView: UIView {
    let leading = UIImageView()
    let titleLabel = UILabel()
    let detailLabel = UILabel()
    let trailing = UIStackView()
    private let below = UIStackView()
    private var action: (() -> Void)?

    init(
        title: String, detail: String? = nil, image: UIImage? = nil, tint: UIColor? = nil,
        detailColor: UIColor = Theme.Color.secondaryLabel, action: (() -> Void)? = nil
    ) {
        super.init(frame: .zero)
        self.action = action
        leading.image = image
        leading.tintColor = tint ?? Theme.Color.accent
        leading.contentMode = .scaleAspectFit
        leading.isHidden = image == nil
        leading.translatesAutoresizingMaskIntoConstraints = false
        leading.widthAnchor.constraint(equalToConstant: 30).isActive = true
        leading.heightAnchor.constraint(equalToConstant: 30).isActive = true

        titleLabel.text = title
        titleLabel.font = Theme.Ramp.font(.rowTitle)
        titleLabel.textColor = Theme.Color.label
        titleLabel.numberOfLines = 0
        titleLabel.adjustsFontForContentSizeCategory = true
        detailLabel.text = detail
        detailLabel.font = Theme.Ramp.font(.rowDetail)
        detailLabel.textColor = detailColor
        detailLabel.numberOfLines = 0
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.isHidden = detail?.isEmpty ?? true

        let texts = UIStackView(arrangedSubviews: [titleLabel, detailLabel, below])
        texts.axis = .vertical
        texts.spacing = 2
        texts.setContentHuggingPriority(.defaultLow - 1, for: .horizontal)
        texts.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        below.axis = .vertical
        below.spacing = Theme.Spacing.xs
        below.isHidden = true
        trailing.axis = .horizontal
        trailing.alignment = .center
        trailing.spacing = Theme.Spacing.s
        trailing.setContentHuggingPriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [leading, texts, trailing])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Theme.Spacing.m
        row.isUserInteractionEnabled = true
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Spacing.s + 2),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -(Theme.Spacing.s + 2)),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.m),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Spacing.m),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
        ])
        if action != nil {
            addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
            accessibilityTraits = .button
        }
        isAccessibilityElement = false
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func trail(_ view: UIView) {
        view.setContentHuggingPriority(.required, for: .horizontal)
        view.setContentCompressionResistancePriority(.required, for: .horizontal)
        trailing.addArrangedSubview(view)
    }

    func chevron() {
        let image = UIImageView(
            image: UIImage(
                systemName: "chevron.forward",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)))
        image.tintColor = Theme.Color.tertiaryLabel
        image.contentMode = .center
        image.setContentHuggingPriority(.required, for: .horizontal)
        image.setContentCompressionResistancePriority(.required, for: .horizontal)
        trail(image)
    }

    /// Extra views under the detail: a step's options, a console.
    func attach(_ view: UIView) {
        below.isHidden = false
        below.addArrangedSubview(view)
    }

    @objc private func tapped() {
        Theme.Haptics.tap()
        backgroundColor = Theme.Color.separator.withAlphaComponent(0.35)
        UIView.animate(withDuration: 0.3) { self.backgroundColor = .clear }
        action?()
    }
}

/// A step of an agent's checklist drawn as its mark: done, next, waiting, failed or working.
@MainActor
enum StepMark {
    static func image(_ state: AgentSetupStep.State) -> UIImage? {
        let config = UIImage.SymbolConfiguration(pointSize: 20, weight: .semibold)
        switch state {
        case .done:
            return UIImage(systemName: "checkmark.circle.fill", withConfiguration: config)?
                .withTintColor(Theme.Color.success, renderingMode: .alwaysOriginal)
        case .next:
            return UIImage(systemName: "circle", withConfiguration: config)?
                .withTintColor(Theme.Color.accent, renderingMode: .alwaysOriginal)
        case .waiting:
            return UIImage(systemName: "circle", withConfiguration: config)?
                .withTintColor(Theme.Color.tertiaryLabel, renderingMode: .alwaysOriginal)
        case .failed:
            return UIImage(systemName: "exclamationmark.circle.fill", withConfiguration: config)?
                .withTintColor(Theme.Color.danger, renderingMode: .alwaysOriginal)
        case .working:
            return UIImage(systemName: "ellipsis.circle", withConfiguration: config)?
                .withTintColor(Theme.Color.accent, renderingMode: .alwaysOriginal)
        }
    }
}
