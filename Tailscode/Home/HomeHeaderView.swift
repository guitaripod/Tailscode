import CodingAgentKit
import TailscodeCore
import UIKit

final class HomeHeaderView: UICollectionReusableView {
    /// What a heading says about its band being shut or open, and what a press on it does.
    struct Fold {
        let isShut: Bool
        let toggle: () -> Void
    }

    /// A second, smaller way out of a band, drawn as a symbol beside its action.
    struct Door {
        let symbol: String
        let label: String
        let open: () -> Void
    }

    private let titleLabel = UILabel()
    private let chevron = UIImageView()
    private let foldControl = UIControl()
    private let actionButton = UIButton(type: .system)
    private let doorButton = UIButton(type: .system)
    private var onAction: (() -> Void)?
    private var fold: Fold?
    private var door: Door?
    private var drawnShut: Bool?

    override init(frame: CGRect) {
        super.init(frame: frame)
        titleLabel.font = Theme.Ramp.font(.sectionLabel)
        titleLabel.textColor = Theme.Color.secondaryLabel
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        chevron.image = UIImage(
            systemName: "chevron.down",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
        chevron.tintColor = Theme.Color.tertiaryLabel
        chevron.contentMode = .center
        chevron.translatesAutoresizingMaskIntoConstraints = false

        foldControl.translatesAutoresizingMaskIntoConstraints = false
        foldControl.addAction(
            UIAction { [weak self] _ in
                Theme.Haptics.tap()
                self?.fold?.toggle()
            }, for: .touchUpInside)

        actionButton.titleLabel?.font = Theme.Ramp.font(.panelDetail)
        actionButton.translatesAutoresizingMaskIntoConstraints = false
        actionButton.addAction(
            UIAction { [weak self] _ in
                Theme.Haptics.tap()
                self?.onAction?()
            }, for: .touchUpInside)

        doorButton.translatesAutoresizingMaskIntoConstraints = false
        doorButton.addAction(
            UIAction { [weak self] _ in
                Theme.Haptics.tap()
                self?.door?.open()
            }, for: .touchUpInside)

        let trailing = UIStackView(arrangedSubviews: [actionButton, doorButton])
        trailing.spacing = Theme.Spacing.m
        trailing.alignment = .center
        trailing.translatesAutoresizingMaskIntoConstraints = false

        addSubview(foldControl)
        addSubview(titleLabel)
        addSubview(chevron)
        addSubview(trailing)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.s),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Spacing.xs),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Spacing.xs),
            chevron.leadingAnchor.constraint(
                equalTo: titleLabel.trailingAnchor, constant: Theme.Spacing.xs),
            chevron.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            foldControl.leadingAnchor.constraint(equalTo: leadingAnchor),
            foldControl.trailingAnchor.constraint(
                equalTo: chevron.trailingAnchor, constant: Theme.Spacing.l),
            foldControl.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            foldControl.heightAnchor.constraint(equalToConstant: 44),
            trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Spacing.s),
            trailing.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            trailing.leadingAnchor.constraint(
                greaterThanOrEqualTo: foldControl.trailingAnchor, constant: Theme.Spacing.s),
            doorButton.widthAnchor.constraint(greaterThanOrEqualToConstant: 28),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// A heading is shorter than a finger, so the press that shuts its band and the buttons at its
    /// end are reached a little outside it.
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: 0, dy: -10).contains(point)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard self.point(inside: point, with: event), !isHidden, alpha > 0.01 else { return nil }
        for button in [actionButton, doorButton] where !button.isHidden {
            let reach = button.convert(button.bounds, to: self).insetBy(dx: -10, dy: -14)
            if reach.contains(point) { return button }
        }
        guard fold != nil else { return super.hitTest(point, with: event) }
        return foldControl.frame.insetBy(dx: 0, dy: -4).contains(point) ? foldControl : nil
    }

    func configure(
        title: String, count: Int? = nil, needsYou: Bool = false, fold: Fold? = nil,
        door: Door? = nil, actionTitle: String? = nil, actionLabel: String? = nil,
        onAction: (() -> Void)? = nil
    ) {
        let color = needsYou ? Theme.Color.warning : Theme.Color.secondaryLabel
        let label = NSMutableAttributedString(
            string: title.uppercased(),
            attributes: [
                .font: Theme.Ramp.font(.sectionLabel), .foregroundColor: color,
                .kern: Typography.spec(.sectionLabel).tracking
                    * Theme.Ramp.font(.sectionLabel).pointSize,
            ])
        if let count, count > 0 {
            label.append(
                NSAttributedString(
                    string: "  \(count)",
                    attributes: [
                        .font: Theme.Ramp.font(.sectionLabel),
                        .foregroundColor: color.withAlphaComponent(0.8),
                    ]))
        }
        titleLabel.attributedText = label
        self.onAction = onAction
        if let actionTitle {
            actionButton.setTitle(actionTitle, for: .normal)
            actionButton.accessibilityLabel = actionLabel ?? actionTitle
            actionButton.isHidden = false
        } else {
            actionButton.isHidden = true
        }
        self.door = door
        doorButton.isHidden = door == nil
        if let door {
            doorButton.setImage(
                UIImage(
                    systemName: door.symbol,
                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .medium)),
                for: .normal)
            doorButton.accessibilityLabel = door.label
        }
        apply(fold)
        isAccessibilityElement = false
        titleLabel.isAccessibilityElement = fold == nil
        titleLabel.accessibilityTraits = .header
        foldControl.isAccessibilityElement = fold != nil
        foldControl.accessibilityTraits = [.header, .button]
        foldControl.accessibilityLabel = count.map { $0 > 0 ? "\(title), \($0)" : title } ?? title
        foldControl.accessibilityValue = fold.map {
            $0.isShut ? String(localized: "Collapsed") : String(localized: "Expanded")
        }
    }

    /// The chevron turns to say which way the band is, turning in place when a press changed it
    /// and standing already turned when the heading is drawn for the first time.
    private func apply(_ fold: Fold?) {
        self.fold = fold
        chevron.isHidden = fold == nil
        foldControl.isHidden = fold == nil
        guard let fold else {
            drawnShut = nil
            return
        }
        let turn = fold.isShut ? CGAffineTransform(rotationAngle: -.pi / 2) : .identity
        let animates = drawnShut != nil && drawnShut != fold.isShut && window != nil
            && !UIAccessibility.isReduceMotionEnabled
        drawnShut = fold.isShut
        guard animates else {
            chevron.transform = turn
            return
        }
        UIView.animate(
            withDuration: 0.28, delay: 0, usingSpringWithDamping: 0.82, initialSpringVelocity: 0,
            options: [.allowUserInteraction, .beginFromCurrentState]
        ) { self.chevron.transform = turn }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        drawnShut = nil
    }
}
