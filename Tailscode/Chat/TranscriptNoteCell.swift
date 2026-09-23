import TailscodeCore
import UIKit

/// A line the server wrote for the reader rather than the model: the model or agent changing
/// hands, a turn picked back up after a restart, work the agent left running reporting back.
///
/// It stands between the turns it separates, never inside one, so it draws as a quiet line across
/// the transcript rather than a bubble: small secondary text beside its symbol, tinted by the tone
/// Core read it with. It holds perfectly still, because a note is a fact about what already
/// happened rather than something still moving.
final class TranscriptNoteCell: UICollectionViewCell {
    static let reuseID = "TranscriptNoteCell"

    private let icon = UIImageView()
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func build() {
        icon.contentMode = .scaleAspectFit
        icon.setContentHuggingPriority(.required, for: .horizontal)

        label.font = Theme.Ramp.font(.note)
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 0

        let row = UIStackView(arrangedSubviews: [icon, label])
        row.axis = .horizontal
        row.alignment = .firstBaseline
        row.spacing = Theme.Spacing.xs
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)

        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),

            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Spacing.xs),
            row.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor, constant: -Theme.Spacing.xs),
            row.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: Theme.Spacing.l),
            row.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.l),
        ])
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        icon.image = nil
        label.text = nil
    }

    func configure(_ line: TranscriptNoteLine) {
        let tint = Self.color(for: line.tone)
        icon.image = UIImage(
            systemName: line.symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .medium))
        icon.tintColor = tint
        label.text = line.text
        label.textColor = tint
        isAccessibilityElement = true
        accessibilityLabel = line.spoken
        accessibilityTraits = .staticText
    }

    private static func color(for tone: ActivityTone) -> UIColor {
        switch tone {
        case .attention: return Theme.Color.warning
        case .live, .danger, .quiet: return Theme.Color.secondaryLabel
        }
    }
}
