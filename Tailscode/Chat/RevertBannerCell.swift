import TailscodeCore
import UIKit

/// The face of a conversation wound back to one of your own messages. A card at the end of the
/// transcript, in the same family as the interrupted-turn card, standing where the set-aside
/// messages used to be: how many went, which files came back, and one press to bring it all back
/// until the next message makes it final.
final class RevertBannerCell: UICollectionViewCell {
    static let reuseID = "RevertBannerCell"
    private static let fileLimit = 6

    private let card = UIView()
    private let icon = UIImageView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let filesStack = UIStackView()
    private let restoreButton = UIButton(type: .system)
    private var onRestore: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func build() {
        card.backgroundColor = Theme.Color.secondaryBackground
        card.layer.cornerRadius = Theme.Radius.card
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.layer.borderColor = RevertBanner.tone.color.withAlphaComponent(0.35).cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(card)

        icon.image = UIImage(
            systemName: RevertBanner.symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        icon.tintColor = RevertBanner.tone.color
        icon.contentMode = .scaleAspectFit
        icon.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.font = Theme.Ramp.font(.cardTitle)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = Theme.Color.label
        titleLabel.numberOfLines = 0

        let header = UIStackView(arrangedSubviews: [icon, titleLabel])
        header.axis = .horizontal
        header.alignment = .firstBaseline
        header.spacing = Theme.Spacing.s

        detailLabel.font = Theme.Ramp.font(.panelDetail)
        detailLabel.adjustsFontForContentSizeCategory = true
        detailLabel.textColor = Theme.Color.secondaryLabel
        detailLabel.numberOfLines = 0

        filesStack.axis = .vertical
        filesStack.alignment = .leading
        filesStack.spacing = Theme.Spacing.xs

        var restoreConfig = Theme.Glass.buttonConfiguration()
        restoreConfig.cornerStyle = .capsule
        restoreConfig.buttonSize = .small
        restoreButton.configuration = restoreConfig
        restoreButton.addAction(UIAction { [weak self] _ in self?.onRestore?() }, for: .touchUpInside)

        let stack = UIStackView(arrangedSubviews: [
            header, detailLabel, filesStack, restoreButton,
        ])
        stack.axis = .vertical
        stack.alignment = .leading
        stack.spacing = Theme.Spacing.xs
        stack.setCustomSpacing(Theme.Spacing.s, after: filesStack)
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Spacing.xs),
            card.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor, constant: -Theme.Spacing.xs),
            card.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: Theme.Spacing.l),
            card.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.l),

            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: Theme.Spacing.m),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -Theme.Spacing.m),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Theme.Spacing.m),
            stack.trailingAnchor.constraint(
                equalTo: card.trailingAnchor, constant: -Theme.Spacing.m),
        ])
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        onRestore = nil
        for view in filesStack.arrangedSubviews { view.removeFromSuperview() }
    }

    func configure(_ banner: RevertBanner, restoring: Bool, onRestore: @escaping () -> Void) {
        self.onRestore = onRestore
        titleLabel.text = banner.title
        detailLabel.text = banner.detail
        for view in filesStack.arrangedSubviews { view.removeFromSuperview() }
        let (shown, more) = banner.files(upTo: Self.fileLimit)
        for file in shown { filesStack.addArrangedSubview(Self.fileRow(file)) }
        if let more { filesStack.addArrangedSubview(Self.moreRow(more)) }
        filesStack.isHidden = shown.isEmpty && more == nil
        restoreButton.configuration?.title =
            restoring ? RevertReading.restoringTitle : banner.restoreTitle
        restoreButton.isEnabled = !restoring
        isAccessibilityElement = true
        accessibilityLabel = banner.spoken
        accessibilityTraits = .staticText
        accessibilityCustomActions = restoring ? [] : [restoreAction(banner.restoreTitle)]
    }

    /// Restore as a VoiceOver action: the card reads as one element, which hides the button
    /// inside it, so its one press is handed to the rotor instead.
    private func restoreAction(_ title: String) -> UIAccessibilityCustomAction {
        UIAccessibilityCustomAction(name: title) { [weak self] _ in
            self?.onRestore?()
            return true
        }
    }

    private static func fileRow(_ file: RevertBanner.FileLine) -> UIView {
        let path = UILabel()
        path.font = Theme.Ramp.font(.rowDetail)
        path.adjustsFontForContentSizeCategory = true
        path.textColor = Theme.Color.label
        path.numberOfLines = 1
        path.lineBreakMode = .byTruncatingMiddle
        path.text = file.path

        let meta = UILabel()
        meta.font = Theme.Ramp.font(.rowNote)
        meta.adjustsFontForContentSizeCategory = true
        meta.textColor = Theme.Color.secondaryLabel
        meta.numberOfLines = 1
        meta.text = file.counts.map { "\(file.change) · \($0)" } ?? file.change

        let row = UIStackView(arrangedSubviews: [path, meta])
        row.axis = .vertical
        row.alignment = .leading
        row.spacing = 1
        return row
    }

    private static func moreRow(_ text: String) -> UIView {
        let label = UILabel()
        label.font = Theme.Ramp.font(.rowNote)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = Theme.Color.tertiaryLabel
        label.text = text
        return label
    }
}
