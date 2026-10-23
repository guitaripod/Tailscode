import TailscodeCore
import UIKit

/// The doorway to the analytics screen, wearing a month of days as its own preview: the
/// sparkline appears once a ledger has been read and the total rides beside the chevron.
@MainActor
final class MonthCard: UIControl {
    private let totalLabel = UILabel()
    private let sparkline = UIStackView()
    private static let sparkHeight: CGFloat = 36

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = Theme.Color.groupedSurface
        layer.cornerRadius = Theme.Radius.card
        layer.cornerCurve = .continuous

        let title = UILabel()
        title.text = String(localized: "The month in numbers")
        title.font = Theme.Ramp.font(.cardTitle)
        title.textColor = Theme.Color.label

        totalLabel.font = Theme.Ramp.font(.metricValue)
        totalLabel.textColor = Theme.Color.secondaryLabel
        totalLabel.textAlignment = .right
        totalLabel.setContentHuggingPriority(.required, for: .horizontal)
        totalLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))
        chevron.tintColor = Theme.Color.secondaryLabel
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: 12, weight: .semibold)
        chevron.contentMode = .scaleAspectFit
        chevron.setContentHuggingPriority(.required, for: .horizontal)

        title.numberOfLines = 0
        let header = UIStackView(arrangedSubviews: [title, UIView(), totalLabel, chevron])
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = Theme.Spacing.s
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (card: MonthCard, _: UITraitCollection) in
            let large = card.traitCollection.preferredContentSizeCategory.isAccessibilityCategory
            header.axis = large ? .vertical : .horizontal
            header.alignment = large ? .leading : .center
        }

        sparkline.axis = .horizontal
        sparkline.distribution = .fillEqually
        sparkline.spacing = 2
        sparkline.isHidden = true

        let stack = UIStackView(arrangedSubviews: [header, sparkline])
        stack.axis = .vertical
        stack.spacing = Theme.Spacing.m
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -14),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.l),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Spacing.l),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = title.text
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.7 : 1 }
    }

    func render(_ analytics: UsageAnalytics?) {
        totalLabel.text = analytics?.headline
        sparkline.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard let analytics else {
            sparkline.isHidden = true
            return
        }
        sparkline.isHidden = false
        for day in analytics.days {
            let holder = UIView()
            let bar = UIView()
            let height = max(2, Self.sparkHeight * day.share)
            if day.share > 0 {
                bar.backgroundColor = day.isToday ? Theme.Color.accent : Theme.Color.info
                if !day.isToday { bar.alpha = 0.7 }
            } else {
                bar.backgroundColor = Theme.Color.separator
            }
            bar.layer.cornerRadius = 1.5
            bar.translatesAutoresizingMaskIntoConstraints = false
            holder.addSubview(bar)
            NSLayoutConstraint.activate([
                holder.heightAnchor.constraint(equalToConstant: Self.sparkHeight),
                bar.leadingAnchor.constraint(equalTo: holder.leadingAnchor),
                bar.trailingAnchor.constraint(equalTo: holder.trailingAnchor),
                bar.bottomAnchor.constraint(equalTo: holder.bottomAnchor),
                bar.heightAnchor.constraint(equalToConstant: height),
            ])
            sparkline.addArrangedSubview(holder)
        }
        accessibilityValue = analytics.headline
    }
}
