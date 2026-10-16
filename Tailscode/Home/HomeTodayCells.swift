import CodingAgentKit
import TailscodeCore
import UIKit

struct QuotaCard: Hashable {
    let quota: UsageQuota

    static func == (lhs: QuotaCard, rhs: QuotaCard) -> Bool {
        lhs.quota.providerName == rhs.quota.providerName
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(quota.providerName)
    }
}

final class QuotaCardCell: ContentCardCell {
    private let providerLabel = UILabel()
    private let countdownLabel = UILabel()
    private let gaugeStack = UIStackView()
    private let gaugeRows = (0..<3).map { _ in GaugeRow() }

    override init(frame: CGRect) {
        super.init(frame: frame)
        answersPointer(cornerRadius: Theme.Radius.card)
        providerLabel.font = Theme.Ramp.font(.cardTitle)
        providerLabel.textColor = Theme.Color.label
        providerLabel.translatesAutoresizingMaskIntoConstraints = false

        countdownLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .medium)
        countdownLabel.textColor = Theme.Color.secondaryLabel
        countdownLabel.textAlignment = .right
        countdownLabel.setContentHuggingPriority(.required, for: .horizontal)
        countdownLabel.translatesAutoresizingMaskIntoConstraints = false

        gaugeStack.axis = .vertical
        gaugeStack.spacing = Theme.Spacing.s
        gaugeStack.translatesAutoresizingMaskIntoConstraints = false
        gaugeRows.forEach(gaugeStack.addArrangedSubview)

        [providerLabel, countdownLabel, gaugeStack].forEach(contentView.addSubview)
        NSLayoutConstraint.activate([
            providerLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Spacing.m),
            providerLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Spacing.m),
            providerLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: countdownLabel.leadingAnchor, constant: -Theme.Spacing.s),

            countdownLabel.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.m),
            countdownLabel.centerYAnchor.constraint(equalTo: providerLabel.centerYAnchor),

            gaugeStack.topAnchor.constraint(equalTo: providerLabel.bottomAnchor, constant: Theme.Spacing.s),
            gaugeStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Spacing.m),
            gaugeStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.m),
            gaugeStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Theme.Spacing.m),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(_ card: QuotaCard) {
        providerLabel.text = card.quota.providerName
        if let countdown = Self.countdown(card.quota) {
            countdownLabel.text = String(localized: "resets in \(countdown)")
            countdownLabel.isHidden = false
        } else {
            countdownLabel.isHidden = true
        }
        let gauges = Array(card.quota.gauges.prefix(3))
        for (index, row) in gaugeRows.enumerated() {
            guard index < gauges.count else {
                row.isHidden = true
                continue
            }
            row.isHidden = false
            row.apply(gauges[index])
        }
        accessibilityLabel = card.quota.providerName
        accessibilityValue = card.quota.gauges.prefix(3)
            .map {
                String(
                    localized:
                        "\(UsageGaugeFormat.gaugeLabel($0.label)) \(Int($0.fraction * 100)) percent")
            }
            .joined(separator: ", ")
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    /// How long until the window this card is mostly about resets, when the provider actually said
    /// so. Shared with the card's content signature so a countdown that has not moved a minute
    /// does not redraw the card.
    static func countdown(_ quota: UsageQuota) -> String? {
        guard let session = quota.gauges.first(where: { $0.trustedReset }),
            let resetsAt = session.resetsAt, resetsAt > Date()
        else { return nil }
        let minutes = max(1, Int(resetsAt.timeIntervalSinceNow / 60))
        return minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
    }
}

/// One quota bar, built once and re-pointed at whatever gauge the card now carries. The card is
/// reconfigured whenever anything on the board moves, and rebuilding six views and a constraint
/// solve per bar to change two numbers was the most expensive `configure` on Home. A gauge that
/// carries money but no ceiling is a balance rather than a window — the bar goes away and the
/// value reads as the money itself, because a cap that does not exist must not be drawn as one.
private final class GaugeRow: UIStackView {
    private let label = UILabel()
    private let percent = UILabel()
    private let track = UIView()
    private let fill = UIView()
    private var fillWidth: NSLayoutConstraint?

    init() {
        super.init(frame: .zero)
        label.font = Theme.Ramp.font(.panelFootnote)
        label.textColor = Theme.Color.secondaryLabel
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)

        percent.font = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        percent.setContentHuggingPriority(.required, for: .horizontal)

        let top = UIStackView(arrangedSubviews: [label, percent])
        top.axis = .horizontal
        top.spacing = Theme.Spacing.s

        track.backgroundColor = Theme.Color.reasoningBackground
        track.layer.cornerRadius = 3
        track.translatesAutoresizingMaskIntoConstraints = false
        track.heightAnchor.constraint(equalToConstant: 6).isActive = true

        fill.layer.cornerRadius = 3
        fill.translatesAutoresizingMaskIntoConstraints = false
        track.addSubview(fill)
        NSLayoutConstraint.activate([
            fill.topAnchor.constraint(equalTo: track.topAnchor),
            fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
            fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
        ])

        axis = .vertical
        spacing = 4
        addArrangedSubview(top)
        addArrangedSubview(track)
    }

    @available(*, unavailable) required init(coder: NSCoder) { fatalError() }

    func apply(_ gauge: UsageQuota.Gauge) {
        label.text = UsageGaugeFormat.gaugeLabel(gauge.label)
        if let money = gauge.usedUSD, gauge.limitUSD == nil {
            let symbol = (gauge.currency ?? "USD").uppercased() == "CNY" ? "¥" : "$"
            percent.text = String(format: "\(symbol)%.2f", money)
            percent.textColor =
                gauge.fraction >= QuotaSurface.exhaustedFloor
                ? Theme.Color.danger : Theme.Color.label
            track.isHidden = true
            return
        }
        track.isHidden = false
        let raw = "\(Int((min(max(gauge.fraction, 0), 1) * 100).rounded()))%"
        percent.text = QuotaSurface.amountLabel(fraction: gauge.fraction, percentText: raw)
        percent.textColor = gauge.fraction > 0.85 ? Theme.Color.danger : Theme.Color.label
        fill.backgroundColor =
            gauge.fraction > 0.85
            ? Theme.Color.danger : (gauge.fraction > 0.6 ? Theme.Color.warning : Theme.Color.accent)
        let width = max(0.02, min(1, gauge.fraction))
        guard fillWidth?.multiplier != CGFloat(width) else { return }
        fillWidth?.isActive = false
        let constraint = fill.widthAnchor.constraint(
            equalTo: track.widthAnchor, multiplier: CGFloat(width))
        constraint.isActive = true
        fillWidth = constraint
    }
}

/// A conversation that stopped to ask, drawn as the whole question rather than a row: beside a
/// chat list that already holds every row, the pane that is left owes the person what a list
/// cannot say — which command, on which machine, for how long it has been waiting.
struct AskCard: Hashable {
    let row: SessionRowModel
    let facts: ChatRowFacts

    var entry: SessionEntry { row.entry }

    static func == (lhs: AskCard, rhs: AskCard) -> Bool {
        lhs.entry.profileID == rhs.entry.profileID && lhs.entry.session.id == rhs.entry.session.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(entry.profileID)
        hasher.combine(entry.session.id)
    }
}

final class AskCardCell: ContentCardCell {
    var onOpen: (() -> Void)?

    private let tile = UIView()
    private let badge = ActivityBadgeView(pointSize: 16)
    private let titleLabel = UILabel()
    private let leadLabel = UILabel()
    private let ageLabel = UILabel()
    private let commandLabel = UILabel()
    private let commandSurface = UIView()
    private let metaLabel = UILabel()
    private let openButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        surface.backgroundColor = UIColor { traits in
            Theme.Color.groupedSurface.resolvedColor(with: traits)
                .mixed(with: Theme.Color.warning.resolvedColor(with: traits), fraction: 0.1)
        }
        surface.layer.borderWidth = 1
        surface.layer.borderColor = Theme.Color.warning.withAlphaComponent(0.42).cgColor

        tile.layer.cornerRadius = Theme.Radius.control
        tile.layer.cornerCurve = .continuous
        tile.translatesAutoresizingMaskIntoConstraints = false
        badge.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(badge)

        titleLabel.font = Theme.Ramp.font(.cardTitle)
        titleLabel.textColor = Theme.Color.label
        titleLabel.numberOfLines = 2

        leadLabel.font = Theme.Ramp.font(.panelDetail)
        leadLabel.textColor = Theme.Color.secondaryLabel
        leadLabel.numberOfLines = 2

        ageLabel.font = Theme.Ramp.font(.rowStamp)
        ageLabel.textColor = Theme.Color.tertiaryLabel
        ageLabel.setContentHuggingPriority(.required, for: .horizontal)
        ageLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        commandLabel.font = Theme.Ramp.font(.code)
        commandLabel.textColor = Theme.Color.label
        commandLabel.numberOfLines = 3
        commandLabel.lineBreakMode = .byTruncatingTail
        commandLabel.translatesAutoresizingMaskIntoConstraints = false
        commandSurface.backgroundColor = Theme.Color.codeBackground
        commandSurface.layer.cornerRadius = Theme.Radius.control
        commandSurface.layer.cornerCurve = .continuous
        commandSurface.addSubview(commandLabel)
        NSLayoutConstraint.activate([
            commandLabel.topAnchor.constraint(
                equalTo: commandSurface.topAnchor, constant: Theme.Spacing.s + 2),
            commandLabel.bottomAnchor.constraint(
                equalTo: commandSurface.bottomAnchor, constant: -(Theme.Spacing.s + 2)),
            commandLabel.leadingAnchor.constraint(
                equalTo: commandSurface.leadingAnchor, constant: Theme.Spacing.m),
            commandLabel.trailingAnchor.constraint(
                equalTo: commandSurface.trailingAnchor, constant: -Theme.Spacing.m),
        ])

        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        var open = UIButton.Configuration.plain()
        open.title = String(localized: "Open")
        open.image = UIImage(
            systemName: "chevron.right",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        open.imagePlacement = .trailing
        open.imagePadding = Theme.Spacing.xs
        open.baseForegroundColor = Theme.Color.warning
        open.cornerStyle = .capsule
        open.background.strokeColor = Theme.Color.warning.withAlphaComponent(0.42)
        open.background.strokeWidth = 1
        open.contentInsets = NSDirectionalEdgeInsets(
            top: 6, leading: Theme.Spacing.m, bottom: 6, trailing: Theme.Spacing.m)
        open.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            var out = $0
            out.font = Theme.Ramp.font(.chip)
            return out
        }
        openButton.configuration = open
        openButton.setContentHuggingPriority(.required, for: .horizontal)
        openButton.addAction(
            UIAction { [weak self] _ in
                Theme.Haptics.tap()
                self?.onOpen?()
            }, for: .touchUpInside)

        let titles = UIStackView(arrangedSubviews: [titleLabel, leadLabel])
        titles.axis = .vertical
        titles.spacing = 2
        let head = UIStackView(arrangedSubviews: [tile, titles, ageLabel])
        head.axis = .horizontal
        head.alignment = .top
        head.spacing = Theme.Spacing.m
        let foot = UIStackView(arrangedSubviews: [metaLabel, openButton])
        foot.axis = .horizontal
        foot.alignment = .center
        foot.spacing = Theme.Spacing.m

        let column = UIStackView(arrangedSubviews: [head, commandSurface, foot])
        column.axis = .vertical
        column.spacing = Theme.Spacing.m
        column.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(column)
        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: ChatRowContentView.tileSize),
            tile.heightAnchor.constraint(equalToConstant: ChatRowContentView.tileSize),
            badge.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            badge.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            column.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Spacing.m),
            column.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor, constant: -Theme.Spacing.m),
            column.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: Theme.Spacing.l),
            column.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.l),
        ])
        answersPointer(cornerRadius: Theme.Radius.card)
        isAccessibilityElement = false
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(_ card: AskCard) {
        let facts = card.facts
        tile.backgroundColor = facts.icon.tone.color.withAlphaComponent(0.14)
        badge.show(facts.icon, spoken: nil)
        titleLabel.text = facts.title
        ageLabel.text = facts.age
        if let news = facts.news {
            leadLabel.text = news.lead
            commandLabel.text = news.object
            commandSurface.isHidden = news.object == nil
        } else {
            leadLabel.text = nil
            commandSurface.isHidden = true
        }
        metaLabel.attributedText = ModelChipText.line(
            chip: facts.chip,
            pieces: facts.pieces.map {
                ($0.text, $0.isQuiet ? Theme.Color.tertiaryLabel : Theme.Color.secondaryLabel)
            },
            size: Theme.Ramp.font(.panelFootnote).pointSize)
        accessibilityElements = [titleLabel, leadLabel, commandLabel, openButton]
        openButton.accessibilityLabel = String(localized: "Open \(facts.title)")
    }
}
