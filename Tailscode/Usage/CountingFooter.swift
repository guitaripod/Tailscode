import TailscodeCore
import UIKit

/// One footer for the page's explanations. Where the numbers came from and what each provider's
/// caps are is the same kind of sentence on every card, so it is asked for once and answered for
/// every provider on the board.
@MainActor
final class CountingFooter: UIView {
    private let disclosure = DisclosureRow(title: String(localized: "How this is counted"))
    private let body = UIStackView()
    private var expanded = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        disclosure.addTarget(self, action: #selector(toggle), for: .touchUpInside)
        body.axis = .vertical
        body.spacing = Theme.Spacing.l
        body.isHidden = true
        body.alpha = 0

        let stack = UIStackView(arrangedSubviews: [disclosure, body])
        stack.axis = .vertical
        stack.spacing = Theme.Spacing.m
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.xs),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Spacing.xs),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func render(_ holdings: [QuotaHolding]) {
        body.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for holding in holdings { body.addArrangedSubview(section(for: holding)) }
    }

    private func section(for holding: QuotaHolding) -> UIView {
        let name = UILabel()
        name.text = holding.quota.providerName
        name.font = Theme.Ramp.font(.control)
        name.textColor = Theme.Color.label

        let note = UILabel()
        note.font = Theme.Ramp.font(.panelFootnote)
        note.textColor = Theme.Color.secondaryLabel
        note.numberOfLines = 0
        note.text = Self.provenanceNote(holding)

        var views: [UIView] = [name, note]
        for detail in holding.quota.details {
            views.append(detailRow(detail.key, detail.value))
        }
        let stack = UIStackView(arrangedSubviews: views)
        stack.axis = .vertical
        stack.spacing = Theme.Spacing.xs
        stack.setCustomSpacing(Theme.Spacing.s, after: note)
        return stack
    }

    /// Where the numbers came from, in a sentence: the provider's own source, the machines that
    /// answered when more than one did, and what a live reading is.
    private static func provenanceNote(_ holding: QuotaHolding) -> String {
        let source = QuotaRollup.provenance(holding)
        guard holding.quota.live else {
            return String(
                localized:
                    "Last saved figures from \(source) — refreshed from the server while this screen is up."
            )
        }
        return String(
            localized:
                "Live from \(source). Percentages are the account's actual consumption, not an estimate."
        )
    }

    private func detailRow(_ title: String, _ value: String) -> UIView {
        let label = UILabel()
        label.text = title
        label.font = Theme.Ramp.font(.panelFootnote)
        label.textColor = Theme.Color.label
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let valueLabel = UILabel()
        valueLabel.text = value
        valueLabel.font = Theme.Ramp.font(.metricDetail)
        valueLabel.textColor = Theme.Color.secondaryLabel
        valueLabel.textAlignment = .right
        valueLabel.numberOfLines = 0
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)

        let row = UIStackView(arrangedSubviews: [label, valueLabel])
        row.axis = .horizontal
        row.alignment = .firstBaseline
        row.spacing = Theme.Spacing.s
        return row
    }

    @objc private func toggle() {
        expanded.toggle()
        disclosure.setExpanded(expanded)
        Theme.Haptics.selection()
        UIView.animate(withDuration: 0.25) {
            self.body.isHidden = !self.expanded
            self.body.alpha = self.expanded ? 1 : 0
        }
    }
}

@MainActor
final class DisclosureRow: UIControl {
    private let titleLabel = UILabel()
    private let chevron = UIImageView(image: UIImage(systemName: "chevron.right"))

    init(title: String) {
        super.init(frame: .zero)
        titleLabel.text = title
        titleLabel.font = Theme.Ramp.font(.panelLabel)
        titleLabel.textColor = Theme.Color.secondaryLabel

        chevron.tintColor = Theme.Color.secondaryLabel
        chevron.preferredSymbolConfiguration = UIImage.SymbolConfiguration(
            pointSize: 12, weight: .semibold)
        chevron.contentMode = .scaleAspectFit

        let row = UIStackView(arrangedSubviews: [titleLabel, UIView(), chevron])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Theme.Spacing.s
        row.isUserInteractionEnabled = false
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = titleLabel.text
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.6 : 1 }
    }

    func setExpanded(_ expanded: Bool) {
        UIView.animate(withDuration: 0.2) {
            self.chevron.transform =
                expanded ? CGAffineTransform(rotationAngle: .pi / 2) : .identity
        }
    }
}
