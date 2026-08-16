import TailscodeCore
import UIKit

/// What the answer above it took: one quiet strip of symbol-and-number under a settled turn.
///
/// It is deliberately the dimmest thing in the transcript. A reader who turned this on wants the
/// numbers available while reading, not competing with the words they describe — so the strip is
/// tertiary ink at the transcript's smallest ramp size, holds perfectly still like every settled
/// state, and wraps rather than truncating, because a figure cut in half is worse than a line that
/// runs on. Every figure comes from `ResponseStats` in Core; this decides only how it is laid out.
final class ResponseStatsCell: UICollectionViewCell {
    static let reuseID = "ResponseStatsCell"

    private let strip = UIStackView()
    private var turnTop: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func build() {
        backgroundColor = .clear
        strip.axis = .horizontal
        strip.spacing = Theme.Spacing.m
        strip.alignment = .center
        strip.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(strip)
        turnTop = strip.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 2)
        NSLayoutConstraint.activate([
            turnTop,
            strip.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: Theme.Spacing.m),
            strip.trailingAnchor.constraint(
                lessThanOrEqualTo: contentView.trailingAnchor, constant: -Theme.Spacing.m),
            strip.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
        ])
    }

    var turnInset: CGFloat = 0 {
        didSet { turnTop.constant = 2 + turnInset }
    }

    func configure(_ stats: ResponseStats) {
        strip.arrangedSubviews.forEach {
            strip.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for fact in stats.facts { strip.addArrangedSubview(Self.cell(fact)) }
        isAccessibilityElement = true
        accessibilityLabel = stats.spoken
        accessibilityTraits = .staticText
    }

    /// One figure: its symbol and its number, kept together so a strip that has to compress drops
    /// a whole fact rather than orphaning a number from what it counts.
    private static func cell(_ fact: ResponseStat) -> UIView {
        let icon = UIImageView(
            image: UIImage(
                systemName: fact.symbol,
                withConfiguration: UIImage.SymbolConfiguration(
                    font: Theme.Ramp.font(.responseStat))))
        icon.tintColor = Theme.Color.tertiaryLabel
        icon.contentMode = .center
        icon.setContentHuggingPriority(.required, for: .horizontal)

        let value = UILabel()
        value.text = fact.value
        value.font = Theme.Ramp.font(.responseStat)
        value.adjustsFontForContentSizeCategory = true
        value.textColor = Theme.Color.tertiaryLabel
        value.setContentCompressionResistancePriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [icon, value])
        row.axis = .horizontal
        row.spacing = 3
        row.alignment = .center
        row.isAccessibilityElement = false
        return row
    }
}
