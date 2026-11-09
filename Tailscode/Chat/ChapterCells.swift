import TailscodeCore
import UIKit

/// Where a chapter of the conversation began, above the message that opened it: the number and
/// the time in the small label, the title under it in the strong row voice, wrapping as far as it
/// needs. A header to VoiceOver, so the headings rotor walks the chapters; a tap opens them on
/// this one.
final class ChapterHeadingCell: UICollectionViewCell {
    static let reuseID = "ChapterHeadingCell"

    private let kicker = UILabel()
    private let title = UILabel()
    private let press = UIControl()
    private var topConstraint: NSLayoutConstraint!
    private var onPress: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        kicker.numberOfLines = 1
        kicker.adjustsFontForContentSizeCategory = true
        title.numberOfLines = 0
        title.adjustsFontForContentSizeCategory = true
        let column = UIStackView(arrangedSubviews: [kicker, title])
        column.axis = .vertical
        column.spacing = 3
        column.isUserInteractionEnabled = false
        column.translatesAutoresizingMaskIntoConstraints = false
        press.translatesAutoresizingMaskIntoConstraints = false
        press.addAction(UIAction { [weak self] _ in self?.pressed() }, for: .touchUpInside)
        contentView.addSubview(press)
        contentView.addSubview(column)
        topConstraint = column.topAnchor.constraint(equalTo: contentView.topAnchor)
        NSLayoutConstraint.activate([
            topConstraint,
            column.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: Theme.Spacing.l),
            column.trailingAnchor.constraint(
                lessThanOrEqualTo: contentView.trailingAnchor, constant: -Theme.Spacing.l),
            column.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            press.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            press.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            press.topAnchor.constraint(equalTo: column.topAnchor, constant: -6),
            press.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
        ])
        isAccessibilityElement = true
        accessibilityTraits = [.header, .button]
        accessibilityHint = String(localized: "Shows how this chat got here.")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    var gapAbove: CGFloat = 0 {
        didSet { topConstraint.constant = gapAbove }
    }

    func configure(_ heading: ChapterHeading, onPress: @escaping () -> Void) {
        self.onPress = onPress
        kicker.attributedText = NSAttributedString(
            string: StatusMark.chapters + " " + heading.label.uppercased() + "  ·  " + heading.time,
            attributes: Theme.Ramp.attributes(.seamLabel, color: Theme.Color.secondaryLabel))
        title.attributedText = NSAttributedString(
            string: heading.title,
            attributes: Theme.Ramp.attributes(.cardTitle, color: Theme.Color.label))
        accessibilityLabel = heading.spoken
    }

    override func accessibilityActivate() -> Bool {
        pressed()
        return true
    }

    private func pressed() {
        Theme.Haptics.tap()
        onPress?()
    }
}
