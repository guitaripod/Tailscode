import TailscodeCore
import UIKit

/// The card a table wears while it is being written: its own border, the open-work mark turning,
/// and the count of what has landed. `TableDraft` says why the rows are held — nothing here is
/// measured against anything, so an arrival costs two label sets and no layout at all.
final class TableDraftCell: UICollectionViewCell {
    static let reuseID = "TableDraftCell"

    private let card = UIView()
    private let mark = UIImageView()
    private let title = UILabel()
    private let count = UILabel()
    private var cardTop: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        card.translatesAutoresizingMaskIntoConstraints = false
        card.clipsToBounds = true
        card.layer.cornerRadius = CGFloat(TableStyle.radius)
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.layer.borderColor = Self.borderInk.cgColor

        mark.translatesAutoresizingMaskIntoConstraints = false
        mark.contentMode = .scaleAspectFit
        mark.tintColor = Theme.Color.accent
        mark.image = UIImage(systemName: TableDraft.mark.symbol)
        mark.setContentCompressionResistancePriority(.required, for: .horizontal)

        title.font = Theme.Ramp.font(.tableHeader)
        title.textColor = Theme.Color.secondaryLabel
        count.font = Theme.Ramp.font(.tableCell)
        count.textColor = Theme.Color.tertiaryLabel

        let row = UIStackView(arrangedSubviews: [mark, title, count])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Theme.Spacing.s
        row.isLayoutMarginsRelativeArrangement = true
        let air = CGFloat(TableStyle.rowPadding) + 2
        row.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: air, leading: CGFloat(TableStyle.edge), bottom: air,
            trailing: CGFloat(TableStyle.edge))
        row.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(card)
        card.addSubview(row)
        cardTop = card.topAnchor.constraint(
            equalTo: contentView.topAnchor, constant: Theme.Spacing.xs)
        NSLayoutConstraint.activate([
            cardTop,
            card.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor, constant: -Theme.Spacing.xs),
            card.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: Theme.Spacing.l),
            card.trailingAnchor.constraint(
                lessThanOrEqualTo: contentView.trailingAnchor, constant: -Theme.Spacing.l),
            row.topAnchor.constraint(equalTo: card.topAnchor),
            row.bottomAnchor.constraint(equalTo: card.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            mark.widthAnchor.constraint(equalToConstant: 14),
            mark.heightAnchor.constraint(equalToConstant: 14),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Extra gap above the card when this row opens a new turn.
    var turnInset: CGFloat = 0 {
        didSet { cardTop.constant = Theme.Spacing.xs + turnInset }
    }

    func configure(_ draft: TableDraft, key: String) {
        TableCell.Wash.note(draft: key)
        title.text = draft.title
        count.text = draft.detail
        count.isHidden = draft.detail == nil
        isAccessibilityElement = true
        accessibilityLabel = draft.reading
        turn()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        card.layer.borderColor = Self.borderInk.cgColor
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        mark.layer.removeAnimation(forKey: "sweep")
    }

    private func turn() {
        guard mark.layer.animation(forKey: "sweep") == nil else { return }
        let sweep = CABasicAnimation(keyPath: "transform.rotation.z")
        sweep.fromValue = 0
        sweep.toValue = 2 * Double.pi
        sweep.duration = ActivityTuning.sweepPeriod
        sweep.repeatCount = .infinity
        mark.layer.setRepeatingMotion(sweep, forKey: "sweep", meaning: TableDraft.motion)
    }

    private static var borderInk: UIColor {
        Theme.Color.label.withAlphaComponent(CGFloat(TableStyle.border))
    }
}
