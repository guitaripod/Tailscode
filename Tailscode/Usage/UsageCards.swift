import CodingAgentKit
import TailscodeCore
import UIKit

struct GaugeVM {
    let name: String
    let fraction: Double
    let percentText: String
    let amountText: String
    let caption: String
    let isBalance: Bool
    let pace: PaceRow?

    /// Whether the row has a pace to speak of: a window with a clock and enough of it gone to read.
    var isPaced: Bool { pace.map { $0.kind == .window && $0.tick != nil && $0.note == nil } ?? false }
}

func rampColor(for fraction: Double, accent: UIColor) -> UIColor {
    switch QuotaSurface.Pressure(fraction: fraction) {
    case .usedUp, .nearlyOut: return Theme.Color.danger
    case .gettingTight: return Theme.Color.warning
    case .roomToSpare: return accent
    }
}

/// The page's few shared shapes, so a card, a chip and a row are drawn the same way wherever the
/// screen needs one.
@MainActor
enum UsageStyle {
    static func card(_ views: [UIView], spacing: CGFloat, vertical: CGFloat = Theme.Spacing.l)
        -> UIView
    {
        let container = UIView()
        container.backgroundColor = Theme.Color.groupedSurface
        container.layer.cornerRadius = Theme.Radius.card
        container.layer.cornerCurve = .continuous

        let stack = UIStackView(arrangedSubviews: views)
        stack.axis = .vertical
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: vertical),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -vertical),
            stack.leadingAnchor.constraint(
                equalTo: container.leadingAnchor, constant: Theme.Spacing.l),
            stack.trailingAnchor.constraint(
                equalTo: container.trailingAnchor, constant: -Theme.Spacing.l),
        ])
        return container
    }

    static func pill(_ text: String, color: UIColor) -> UIView {
        let label = UILabel()
        label.text = text
        label.font = Theme.Ramp.font(.metricLabel)
        label.textColor = color
        label.translatesAutoresizingMaskIntoConstraints = false
        let background = UIView()
        background.backgroundColor = color.withAlphaComponent(0.16)
        background.layer.cornerRadius = 9
        background.layer.cornerCurve = .continuous
        background.setContentHuggingPriority(.required, for: .horizontal)
        background.setContentCompressionResistancePriority(.required, for: .horizontal)
        background.addSubview(label)
        NSLayoutConstraint.activate([
            background.heightAnchor.constraint(equalToConstant: 20),
            label.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            label.leadingAnchor.constraint(
                equalTo: background.leadingAnchor, constant: Theme.Spacing.s),
            label.trailingAnchor.constraint(
                equalTo: background.trailingAnchor, constant: -Theme.Spacing.s),
        ])
        return background
    }

    static func dot(_ color: UIColor, size: CGFloat = 9) -> UIView {
        let dot = UIView()
        dot.backgroundColor = color
        dot.layer.cornerRadius = size / 2
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: size),
            dot.heightAnchor.constraint(equalToConstant: size),
        ])
        return dot
    }

    static func moreButton(menu: UIMenu) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "ellipsis")
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
            pointSize: 16, weight: .semibold)
        configuration.baseForegroundColor = Theme.Color.secondaryLabel
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: 6, leading: 8, bottom: 6, trailing: 0)
        let button = UIButton(configuration: configuration)
        button.showsMenuAsPrimaryAction = true
        button.menu = menu
        button.accessibilityLabel = String(localized: "Card options")
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    /// A bar that is a window's fullness: never a missing bar, so a window with almost nothing
    /// spent still shows a sliver.
    static func bar(fraction: Double, color: UIColor) -> UIView {
        let track = UIView()
        track.backgroundColor = Theme.Color.separator
        track.layer.cornerRadius = 3
        track.translatesAutoresizingMaskIntoConstraints = false
        let fill = UIView()
        fill.backgroundColor = color
        fill.layer.cornerRadius = 3
        fill.translatesAutoresizingMaskIntoConstraints = false
        track.addSubview(fill)
        NSLayoutConstraint.activate([
            track.heightAnchor.constraint(equalToConstant: 6),
            fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            fill.topAnchor.constraint(equalTo: track.topAnchor),
            fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
            fill.widthAnchor.constraint(
                equalTo: track.widthAnchor, multiplier: max(0.02, min(1, fraction))),
        ])
        return track
    }
}

/// The navigation title and, under it, how fresh the figures are — so the screen needs no large
/// title and no line of its own to say "Updated just now".
@MainActor
final class UsageTitleView: UIStackView {
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()

    var subtitle: String? {
        didSet {
            subtitleLabel.text = subtitle
            subtitleLabel.isHidden = subtitle == nil
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        axis = .vertical
        alignment = .center
        spacing = 0
        titleLabel.text = String(localized: "Usage")
        titleLabel.font = Theme.Ramp.font(.panelTitle)
        titleLabel.textColor = Theme.Color.label
        subtitleLabel.font = Theme.Ramp.font(.panelFootnote)
        subtitleLabel.textColor = Theme.Color.secondaryLabel
        subtitleLabel.isHidden = true
        addArrangedSubview(titleLabel)
        addArrangedSubview(subtitleLabel)
    }

    @available(*, unavailable) required init(coder: NSCoder) { fatalError() }
}

/// The board's switches: one chip per provider, lit in its brand's colour while shown and dimmed
/// while hidden — never removed, because a switch that vanishes when it is off cannot be switched
/// back. The arrangement and the lead live in the navigation bar's menu.
@MainActor
final class BoardBar: UIView {
    private let scroller = UIScrollView()
    private let row = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        scroller.showsHorizontalScrollIndicator = false
        scroller.alwaysBounceHorizontal = false
        scroller.translatesAutoresizingMaskIntoConstraints = false
        row.axis = .horizontal
        row.spacing = Theme.Spacing.s
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        scroller.addSubview(row)
        addSubview(scroller)
        NSLayoutConstraint.activate([
            scroller.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroller.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroller.topAnchor.constraint(equalTo: topAnchor),
            scroller.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: scroller.contentLayoutGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: scroller.contentLayoutGuide.trailingAnchor),
            row.topAnchor.constraint(equalTo: scroller.contentLayoutGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: scroller.contentLayoutGuide.bottomAnchor),
            scroller.frameLayoutGuide.heightAnchor.constraint(equalTo: row.heightAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 34),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func render(
        _ choices: [QuotaBoard.Choice],
        change: @escaping ((inout QuotaBoardPreferences) -> Void) -> Void
    ) {
        row.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for choice in choices {
            let accent = Self.accent(for: choice)
            var configuration = UIButton.Configuration.plain()
            configuration.title = choice.name
            configuration.cornerStyle = .capsule
            configuration.buttonSize = .small
            configuration.baseForegroundColor =
                choice.isHidden ? Theme.Color.secondaryLabel : Theme.Color.label
            configuration.background.backgroundColor =
                choice.isHidden
                ? Theme.Color.groupedSurface : accent.withAlphaComponent(0.20)
            configuration.contentInsets = NSDirectionalEdgeInsets(
                top: 6, leading: 12, bottom: 6, trailing: 12)
            if choice.isReported {
                configuration.image = UIImage(systemName: "circle.fill")
                configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
                    pointSize: 7)
                configuration.imageColorTransformer = UIConfigurationColorTransformer { _ in
                    choice.isHidden ? accent.withAlphaComponent(0.45) : accent
                }
            } else {
                configuration.image = UIImage(systemName: "key")
                configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
                    pointSize: 10)
            }
            configuration.imagePadding = 6
            let chip = UIButton(configuration: configuration)
            chip.setContentHuggingPriority(.required, for: .horizontal)
            chip.setContentCompressionResistancePriority(.required, for: .horizontal)
            chip.accessibilityLabel = choice.name
            chip.accessibilityValue =
                choice.isHidden ? String(localized: "Hidden") : String(localized: "Shown")
            chip.accessibilityHint =
                choice.isHidden
                ? String(localized: "Shows this provider on the board")
                : String(localized: "Hides this provider from the board")
            let key = choice.key
            let hidden = choice.isHidden
            chip.addAction(
                UIAction { _ in
                    Theme.Haptics.selection()
                    change { $0.setHidden(key, !hidden) }
                }, for: .touchUpInside)
            row.addArrangedSubview(chip)
        }
    }

    /// The arrangement and the lead, one menu at the trailing edge of the navigation bar.
    static func arrangeItem(
        preferences: QuotaBoardPreferences,
        change: @escaping ((inout QuotaBoardPreferences) -> Void) -> Void
    ) -> UIBarButtonItem {
        let arrangements = QuotaBoardPreferences.Arrangement.allCases.map { option in
            UIAction(
                title: option.title, state: option == preferences.arrangement ? .on : .off
            ) { _ in
                change { $0.arrangement = option }
            }
        }
        let lead = UIAction(
            title: String(localized: "Lead with the tightest window"),
            state: preferences.leadsWithTightest ? .on : .off
        ) { _ in
            change { $0.leadsWithTightest.toggle() }
        }
        let item = UIBarButtonItem(
            image: UIImage(systemName: "line.3.horizontal.decrease"),
            menu: UIMenu(children: [
                UIMenu(
                    title: String(localized: "Arrange"), options: .displayInline,
                    children: arrangements),
                UIMenu(options: .displayInline, children: [lead]),
            ]))
        item.accessibilityLabel = String(localized: "Arrange the board")
        return item
    }

    private static func accent(for choice: QuotaBoard.Choice) -> UIColor {
        UsageAccent.color(for: choice.key)
    }
}

@MainActor
enum UsageAccent {
    static func color(for key: String) -> UIColor {
        switch key {
        case "claude": return Theme.Color.claude
        case "grok": return Theme.Color.grok
        case "opencode": return Theme.Color.opencode
        case "deepseek": return Theme.Color.modelFamily(.deepseek)
        case "ollama-cloud": return Theme.Color.ollamaCloud
        default: return Theme.Color.accent
        }
    }
}

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

/// Doors with no reading to draw, as one card instead of one paragraph each: a key nobody has set
/// is a quiet invitation to add one rather than an error, and a key that has been set but not
/// answered for says exactly that. Each row can be hidden the way any card can — from its menu, or
/// from the chip above.
@MainActor
final class MoreProvidersCard: UIView {
    private var container = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func render(
        offers: [QuotaBoard.Offer], accent: (String) -> UIColor, open: @escaping (String) -> Void,
        hide: @escaping (String) -> Void
    ) {
        container.removeFromSuperview()
        guard !offers.isEmpty else { return }

        let title = UILabel()
        title.text = String(localized: "More providers")
        title.font = Theme.Ramp.font(.cardTitle)
        title.textColor = Theme.Color.label

        var views: [UIView] = [title]
        for (index, offer) in offers.enumerated() {
            if index > 0 { views.append(Self.divider()) }
            views.append(row(for: offer, accent: accent(offer.key), open: open, hide: hide))
        }
        container = UsageStyle.card(views, spacing: Theme.Spacing.m, vertical: 14)
        container.translatesAutoresizingMaskIntoConstraints = false
        addSubview(container)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: topAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor),
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    private func row(
        for offer: QuotaBoard.Offer, accent: UIColor, open: @escaping (String) -> Void,
        hide: @escaping (String) -> Void
    ) -> UIView {
        let deepseek = offer.key == "deepseek"
        let hasKey = deepseek ? DeepSeekCredentials.hasToken : OllamaCredentials.hasToken

        let tile = UIView()
        tile.backgroundColor = accent.withAlphaComponent(0.18)
        tile.layer.cornerRadius = 10
        tile.layer.cornerCurve = .continuous
        let initial = UILabel()
        initial.text = String(offer.name.prefix(1))
        initial.font = Theme.Ramp.font(.rowTitleStrong)
        initial.textColor = accent
        initial.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(initial)
        tile.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: 36),
            tile.heightAnchor.constraint(equalToConstant: 36),
            initial.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            initial.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
        ])

        let name = UILabel()
        name.text = offer.name
        name.font = Theme.Ramp.font(.rowTitleStrong)
        name.textColor = Theme.Color.label
        let detail = UILabel()
        detail.numberOfLines = 2
        detail.font = Theme.Ramp.font(.panelFootnote)
        detail.textColor = Theme.Color.secondaryLabel
        detail.text =
            hasKey
            ? String(localized: "Key set — waiting for an answer")
            : (deepseek
                ? String(localized: "Billed per token — no plan caps")
                : String(localized: "Plan-metered — session and weekly windows"))
        let words = UIStackView(arrangedSubviews: [name, detail])
        words.axis = .vertical
        words.spacing = 1

        let action = UILabel()
        action.text = hasKey ? String(localized: "Edit API key") : String(localized: "Add API key")
        action.font = Theme.Ramp.font(.control)
        action.textColor = Theme.Color.accent
        action.textAlignment = .right
        action.numberOfLines = 2
        action.setContentHuggingPriority(.required, for: .horizontal)
        action.setContentCompressionResistancePriority(.required, for: .horizontal)

        words.setContentHuggingPriority(.defaultLow, for: .horizontal)
        words.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let large = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        let line = UIStackView(
            arrangedSubviews: large ? [UIStackView(arrangedSubviews: [tile, words]), action]
                : [tile, words, action])
        if large, let top = line.arrangedSubviews.first as? UIStackView {
            top.axis = .horizontal
            top.alignment = .center
            top.spacing = Theme.Spacing.m
            action.textAlignment = .left
        }
        line.axis = large ? .vertical : .horizontal
        line.alignment = large ? .leading : .center
        line.spacing = Theme.Spacing.m
        line.isLayoutMarginsRelativeArrangement = true
        line.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: 2, leading: 0, bottom: 2, trailing: 0)

        let control = OfferRow(line)
        control.addAction(
            UIAction { _ in
                Theme.Haptics.tap()
                open(offer.key)
            }, for: .touchUpInside)
        control.menuProvider = {
            UIMenu(children: [
                UIAction(
                    title: String(localized: "Hide"), image: UIImage(systemName: "eye.slash")
                ) { _ in hide(offer.key) }
            ])
        }
        control.accessibilityLabel = "\(offer.name), \(detail.text ?? ""), \(action.text ?? "")"
        return control
    }

    private static func divider() -> UIView {
        let line = UIView()
        line.backgroundColor = Theme.Color.separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale).isActive = true
        return line
    }
}

/// A row you press, with a context menu on the long press.
@MainActor
private final class OfferRow: UIControl {
    var menuProvider: (() -> UIMenu)?

    init(_ content: UIView) {
        super.init(frame: .zero)
        content.isUserInteractionEnabled = false
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        isContextMenuInteractionEnabled = true
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.6 : 1 }
    }

    override func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            self?.menuProvider?()
        }
    }
}

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
