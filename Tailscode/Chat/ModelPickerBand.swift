import TailscodeCore
import UIKit

/// A press on a family heading, carrying which heading it was. A supplementary view is recycled, so
/// the gesture has to know its own section rather than the one the view held last time.
final class SectionTapRecognizer: UITapGestureRecognizer {
    private let section: String
    private let handler: (String) -> Void

    init(section: String, handler: @escaping (String) -> Void) {
        self.section = section
        self.handler = handler
        super.init(target: nil, action: nil)
        addTarget(self, action: #selector(fire))
    }

    @objc private func fire() {
        guard state == .ended else { return }
        handler(section)
    }
}

/// A view that answers with the size it was built for, so a hand-laid strip can be measured like
/// anything else in the row.
final class FixedWidthView: UIView {
    private let size: CGSize

    init(width: CGFloat, height: CGFloat) {
        size = CGSize(width: width, height: height)
        super.init(frame: CGRect(origin: .zero, size: size))
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize { size }
}

/// Holds the band so that, lifted by a scroll, it is cut off at the edge of the bars rather than
/// drawn through them, and lets every touch it does not cover reach the list underneath.
final class ClippingBand: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }
}

/// The stack above the list, which tells its owner when it changes size.
final class BandView: UIStackView {
    var onResize: (() -> Void)?
    private var measured: CGFloat = -1

    override func layoutSubviews() {
        super.layoutSubviews()
        guard abs(bounds.height - measured) > 0.5 else { return }
        measured = bounds.height
        onResize?()
    }
}

/// One capsule per machine, scrolling sideways. The name, a dot for a machine that is not
/// answering, and the count in the quieter register; the selected one wears the accent. The same
/// row of capsules serves the doors under the machines — one press each, the one in force wearing
/// the accent.
final class ChipStripView: UIScrollView {
    struct Chip {
        let title: String
        let count: Int
        let detail: String
        /// A dot before the name, in the colour of what it says; nil for nothing to say.
        let dot: UIColor?

        init(title: String, count: Int, detail: String, dot: UIColor?) {
            self.title = title
            self.count = count
            self.detail = detail
            self.dot = dot
        }

        init(_ machine: ModelMachine) {
            self.init(
                title: machine.title, count: machine.count, detail: machine.detail,
                dot: machine.state.wearsDot
                    ? ChooserBriefingViewController.colour(machine.state.tone) : nil)
        }

        init(_ door: ModelDoor) {
            self.init(
                title: door.title, count: door.count, detail: door.detail,
                dot: door.kind == .local ? Theme.Color.info : nil)
        }
    }

    var onPick: ((Int) -> Void)?
    /// A long press, or the context menu, on a chip: the card that explains it.
    var onInfo: ((Int) -> Void)?
    private let row = UIStackView()

    init() {
        super.init(frame: .zero)
        showsHorizontalScrollIndicator = false
        alwaysBounceHorizontal = false
        contentInset = UIEdgeInsets(
            top: 0, left: Theme.Spacing.l, bottom: 0, right: Theme.Spacing.l)
        row.axis = .horizontal
        row.spacing = Theme.Spacing.s
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: contentLayoutGuide.topAnchor, constant: Theme.Spacing.xs),
            row.bottomAnchor.constraint(
                equalTo: contentLayoutGuide.bottomAnchor, constant: -Theme.Spacing.xs),
            row.leadingAnchor.constraint(equalTo: contentLayoutGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: contentLayoutGuide.trailingAnchor),
            heightAnchor.constraint(equalTo: row.heightAnchor, constant: 2 * Theme.Spacing.xs),
        ])
        isAccessibilityElement = false
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func render(_ chips: [Chip], selected: Int) {
        for view in row.arrangedSubviews { view.removeFromSuperview() }
        for (index, chip) in chips.enumerated() {
            let button = Self.button(chip, selected: index == selected)
            button.addAction(UIAction { [weak self] _ in self?.onPick?(index) }, for: .touchUpInside)
            button.menu = UIMenu(children: [
                UIAction(
                    title: String(localized: "About \(chip.title)"),
                    image: UIImage(systemName: "info.circle")
                ) { [weak self] _ in self?.onInfo?(index) }
            ])
            button.showsMenuAsPrimaryAction = false
            button.accessibilityHint = String(localized: "Hold for what is behind it")
            row.addArrangedSubview(button)
        }
        layoutIfNeeded()
        guard row.arrangedSubviews.indices.contains(selected) else { return }
        scrollRectToVisible(row.arrangedSubviews[selected].frame.insetBy(dx: -Theme.Spacing.l, dy: 0), animated: false)
    }

    private static func button(_ chip: Chip, selected: Bool) -> UIButton {
        var configuration = UIButton.Configuration.filled()
        configuration.cornerStyle = .capsule
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: 6, leading: Theme.Spacing.m, bottom: 6, trailing: Theme.Spacing.m)
        configuration.baseBackgroundColor =
            selected ? Theme.Color.accent : Theme.Color.secondaryBackground
        let ink = selected ? Theme.Color.onAccent : Theme.Color.label
        let quiet = selected ? Theme.Color.onAccent.withAlphaComponent(0.7) : Theme.Color.tertiaryLabel
        let title = NSMutableAttributedString(
            string: chip.title, attributes: Theme.Ramp.attributes(.chip, color: ink))
        title.append(
            NSAttributedString(
                string: "  \(chip.count)", attributes: Theme.Ramp.attributes(.rowMeta, color: quiet)))
        configuration.attributedTitle = AttributedString(title)
        if let dot = chip.dot {
            configuration.image = UIImage(
                systemName: "circle.fill",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 6, weight: .bold))
            configuration.imagePadding = Theme.Spacing.xs
            configuration.imageColorTransformer = UIConfigurationColorTransformer { _ in dot }
        }
        let button = UIButton(configuration: configuration)
        button.accessibilityLabel = "\(chip.title). \(chip.detail)"
        button.accessibilityTraits = selected ? [.button, .selected] : .button
        return button
    }
}
