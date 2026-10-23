import TailscodeCore
import UIKit

/// The tightest window across every provider, as a summary of the next send: the ring, which
/// window it is, when it ends, and one word for how hard it is pressing. It is not a copy of the
/// bar below it — it is what the bars add up to for the question this screen is usually opened for.
@MainActor
final class HeroCard: UIView {
    private let ring = RingGaugeView()
    private let overline = UILabel()
    private let titleLabel = UILabel()
    private let captionLabel = UILabel()
    private let verdictHost = UIView()
    private let row = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
        reflow()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (card: HeroCard, _: UITraitCollection) in
            card.reflow()
        }
    }

    /// At accessibility sizes the ring and the words cannot share a line, so the ring sits above
    /// them rather than squeezing the words into a column a few letters wide.
    private func reflow() {
        let large = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        row.axis = large ? .vertical : .horizontal
        row.alignment = large ? .leading : .center
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private static func pacedColor(_ tone: ContextFill.Tone, accent: UIColor) -> UIColor {
        switch tone {
        case .quiet: return accent
        case .attention: return Theme.Color.warning
        case .danger: return Theme.Color.danger
        }
    }

    /// The word the pill says: the pace's verdict where there is a pace, the level's where there
    /// is only a level, as Core's row decides it.
    private static func verdict(for gauge: GaugeVM) -> (word: String, tone: ContextFill.Tone)? {
        gauge.pace?.status
    }

    func apply(provider: String, gauge: GaugeVM, accent: UIColor) {
        let paced = Self.verdict(for: gauge)
        let color =
            gauge.pace.flatMap { _ in paced.map { Self.pacedColor($0.tone, accent: accent) } }
            ?? rampColor(for: gauge.fraction, accent: accent)
        ring.configure(fraction: gauge.fraction, color: color, percentText: gauge.percentText)
        titleLabel.text = "\(provider) · \(gauge.name)"
        captionLabel.text = gauge.caption
        verdictHost.subviews.forEach { $0.removeFromSuperview() }
        verdictHost.isHidden = gauge.isBalance
        var verdictText = ""
        if !gauge.isBalance {
            let pressure = QuotaSurface.Pressure(fraction: gauge.fraction)
            verdictText = paced?.word ?? pressure.title
            let quiet = paced.map { $0.tone == .quiet } ?? (pressure == .roomToSpare)
            let pill = UsageStyle.pill(
                verdictText, color: quiet ? Theme.Color.secondaryLabel : color)
            pill.translatesAutoresizingMaskIntoConstraints = false
            verdictHost.addSubview(pill)
            NSLayoutConstraint.activate([
                pill.leadingAnchor.constraint(equalTo: verdictHost.leadingAnchor),
                pill.topAnchor.constraint(equalTo: verdictHost.topAnchor),
                pill.bottomAnchor.constraint(equalTo: verdictHost.bottomAnchor),
                pill.trailingAnchor.constraint(lessThanOrEqualTo: verdictHost.trailingAnchor),
            ])
        }
        accessibilityLabel =
            "\(titleLabel.text ?? ""), \(gauge.amountText), \(gauge.caption), \(verdictText)"
    }

    private func build() {
        backgroundColor = Theme.Color.groupedSurface
        layer.cornerRadius = Theme.Radius.card
        layer.cornerCurve = .continuous
        isAccessibilityElement = true

        ring.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            ring.widthAnchor.constraint(equalToConstant: 88),
            ring.heightAnchor.constraint(equalToConstant: 88),
        ])

        overline.text = String(localized: "Tightest window").uppercased()
        overline.font = Theme.Ramp.font(.metricLabel)
        overline.textColor = Theme.Color.secondaryLabel
        overline.numberOfLines = 1

        titleLabel.font = Theme.Ramp.font(.cardTitle)
        titleLabel.textColor = Theme.Color.label
        titleLabel.numberOfLines = 2
        titleLabel.text = "—"

        captionLabel.font = Theme.Ramp.font(.metricDetail)
        captionLabel.textColor = Theme.Color.secondaryLabel
        captionLabel.numberOfLines = 2
        captionLabel.text = "—"

        let text = UIStackView(arrangedSubviews: [overline, titleLabel, captionLabel, verdictHost])
        text.axis = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.setCustomSpacing(Theme.Spacing.s, after: captionLabel)

        row.addArrangedSubview(ring)
        row.addArrangedSubview(text)
        row.spacing = Theme.Spacing.l
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Spacing.l),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Spacing.l),
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.l),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Spacing.l),
        ])
    }
}
