import CodingAgentKit
import TailscodeCore
import UIKit

/// One provider's card. Every provider wears the same anatomy — a dot for who, name, plan,
/// provenance, windows as a label with its reset beside it above a bar, and a menu for its place on
/// the board — so the screen reads as one repeated shape. A balance is the one exception the shape
/// allows: money with no ceiling is the number itself rather than a bar against a cap nobody
/// stated. The fine print that used to fold under every card lives in the page's one footer.
@MainActor
final class ProviderCard: UIView {
    var onMenu: (() -> UIMenu)?

    init(holding: QuotaHolding, accent: UIColor, gauges: [GaugeVM]) {
        super.init(frame: .zero)
        build(holding: holding, accent: accent, gauges: gauges)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func build(holding: QuotaHolding, accent: UIColor, gauges: [GaugeVM]) {
        let quota = holding.quota
        let rows = UIStackView()
        rows.axis = .vertical
        rows.spacing = Theme.Spacing.m
        for gauge in gauges {
            rows.addArrangedSubview(
                gauge.isBalance ? balanceRow(gauge) : gaugeRow(gauge, accent: accent))
        }
        if quota.error != nil {
            rows.addArrangedSubview(errorRow(quota, holding: holding))
        }
        let container = UsageStyle.card(
            [header(quota, accent: accent), rows], spacing: Theme.Spacing.m, vertical: 14)
        container.translatesAutoresizingMaskIntoConstraints = false
        addSubview(container)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: topAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor),
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    private func errorRow(_ quota: UsageQuota, holding: QuotaHolding) -> UIView {
        let machines =
            holding.failedMachines.isEmpty ? holding.machines : holding.failedMachines
        let label = UILabel()
        label.text = QuotaSurface.failureLine(quota, machines: machines)
        label.font = Theme.Ramp.font(.panelFootnote)
        label.textColor = quota.live ? Theme.Color.secondaryLabel : Theme.Color.danger
        label.numberOfLines = 0

        let row = UIStackView(arrangedSubviews: [label])
        row.axis = .vertical
        row.spacing = Theme.Spacing.xs
        if quota.errorCode == "key_expired" || quota.errorCode == "no_subscription" {
            let open = UIButton(type: .system)
            open.setTitle(Localized.text("Open Console"), for: .normal)
            open.titleLabel?.font = Theme.Ramp.font(.panelFootnote)
            open.contentHorizontalAlignment = .leading
            open.addAction(
                UIAction { _ in
                    guard let url = URL(string: "https://opencode.ai/console") else { return }
                    UIApplication.shared.open(url)
                }, for: .touchUpInside)
            row.addArrangedSubview(open)
        }
        return row
    }

    private func header(_ quota: UsageQuota, accent: UIColor) -> UIView {
        let title = UILabel()
        title.text = quota.providerName
        title.font = Theme.Ramp.font(.cardTitle)
        title.textColor = Theme.Color.label
        title.setContentHuggingPriority(.required, for: .horizontal)

        let subtitle = UILabel()
        subtitle.text = quota.subtitle
        subtitle.font = Theme.Ramp.font(.panelFootnote)
        subtitle.textColor = Theme.Color.secondaryLabel
        subtitle.numberOfLines = 1
        subtitle.lineBreakMode = .byTruncatingTail
        subtitle.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let menu = UsageStyle.moreButton(
            menu: UIMenu(children: [
                UIDeferredMenuElement.uncached { [weak self] completion in
                    completion([self?.onMenu?() ?? UIMenu()])
                }
            ]))

        let header = UIStackView(arrangedSubviews: [
            UsageStyle.dot(accent), title, subtitle, UIView(),
            UsageStyle.pill(
                QuotaSurface.badge(quota),
                color: quota.live ? accent : Theme.Color.secondaryLabel),
            menu,
        ])
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = Theme.Spacing.s
        header.setCustomSpacing(Theme.Spacing.m, after: title)
        return header
    }

    /// A label with its reset beside it, the value at the far edge and the bar under both: one
    /// idea in two lines, where the reset used to be a second line of fine print of its own.
    private func gaugeRow(_ gauge: GaugeVM, accent: UIColor) -> UIView {
        let color = rampColor(for: gauge.fraction, accent: accent)
        let line = UIStackView(arrangedSubviews: [
            Self.nameLabel(gauge.name, clause: gauge.caption),
            Self.valueLabel(gauge.amountText, fraction: gauge.fraction, pace: gauge.pace),
        ])
        line.axis = .horizontal
        line.alignment = .firstBaseline
        line.spacing = Theme.Spacing.s

        var views: [UIView] = [line]
        if let pace = gauge.pace {
            let bar = PaceBar()
            bar.speaks = false
            bar.configure(pace)
            views.append(bar)
            if let words = PaceWords.line(for: pace, opened: true) { views.append(words) }
        } else {
            views.append(UsageStyle.bar(fraction: gauge.fraction, color: color))
        }
        let row = UIStackView(arrangedSubviews: views)
        row.axis = .vertical
        row.spacing = 7
        row.isAccessibilityElement = true
        row.accessibilityLabel =
            gauge.pace.map { "\(gauge.name), \(gauge.amountText), \(gauge.caption), \($0.news.map { "\($0.lead) \($0.body)" } ?? $0.note ?? "")" }
            ?? "\(gauge.name), \(gauge.amountText), \(gauge.caption)"
        return row
    }

    private func balanceRow(_ gauge: GaugeVM) -> UIView {
        let line = UIStackView(arrangedSubviews: [
            Self.nameLabel(gauge.name, clause: nil),
            Self.valueLabel(gauge.amountText, fraction: gauge.fraction, size: .balance),
        ])
        line.axis = .horizontal
        line.alignment = .firstBaseline
        line.spacing = Theme.Spacing.s

        let caption = UILabel()
        caption.text = gauge.caption
        caption.font = Theme.Ramp.font(.panelFootnote)
        caption.textColor = Theme.Color.secondaryLabel
        caption.numberOfLines = 2

        var views: [UIView] = [line, caption]
        if let note = gauge.pace?.note {
            let runway = UILabel()
            runway.attributedText = PaceWords.note(note)
            runway.numberOfLines = 0
            views.append(runway)
        }
        let row = UIStackView(arrangedSubviews: views)
        row.axis = .vertical
        row.spacing = Theme.Spacing.xs
        row.isAccessibilityElement = true
        row.accessibilityLabel =
            "\(gauge.name), \(gauge.amountText), \(gauge.caption)"
            + (gauge.pace?.note.map { ", " + $0 } ?? "")
        return row
    }

    private static func nameLabel(_ name: String, clause: String?) -> UILabel {
        let label = UILabel()
        let text = NSMutableAttributedString(
            string: name,
            attributes: [
                .font: Theme.Ramp.font(.control), .foregroundColor: Theme.Color.label,
            ])
        if let clause, !clause.isEmpty, clause != "—" {
            text.append(
                NSAttributedString(
                    string: "  \(clause)",
                    attributes: [
                        .font: Theme.Ramp.font(.panelFootnote),
                        .foregroundColor: Theme.Color.secondaryLabel,
                    ]))
        }
        label.attributedText = text
        label.numberOfLines = 2
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    private enum ValueSize { case row, balance }

    /// A window's figure wears the register of where it lands when it has a pace, and of how full
    /// it is when it has only a level.
    private static func valueColor(
        fraction: Double, pressure: QuotaSurface.Pressure, pace: PaceRow?
    ) -> UIColor {
        if let pace, pace.kind == .window, pace.tick != nil, pace.note == nil {
            switch pace.tone {
            case .quiet: return Theme.Color.label
            case .attention: return Theme.Color.warning
            case .danger: return Theme.Color.danger
            }
        }
        return pressure == .roomToSpare
            ? Theme.Color.label : rampColor(for: fraction, accent: Theme.Color.label)
    }

    private static func valueLabel(
        _ text: String, fraction: Double, size: ValueSize = .row, pace: PaceRow? = nil
    ) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = Theme.Ramp.font(size == .balance ? .metricLarge : .metricValue)
        let pressure = QuotaSurface.Pressure(fraction: fraction)
        label.textColor =
            size == .balance
            ? (QuotaSurface.isExhausted(fraction) ? Theme.Color.danger : Theme.Color.label)
            : valueColor(fraction: fraction, pressure: pressure, pace: pace)
        label.textAlignment = .right
        label.setContentHuggingPriority(.required, for: .horizontal)
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        return label
    }
}
