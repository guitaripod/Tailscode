import CodingAgentKit
import TailscodeCore
import UIKit

extension DelegateRungState {
    /// The ink one rung wears at the size of a dot: lit where the run is or passed, marked where it
    /// failed or was held, and faint where the run never had business.
    var pipColor: UIColor {
        switch self {
        case .current, .passed: return Theme.Color.success
        case .failed: return Theme.Color.danger
        case .held: return Theme.Color.warning
        case .pending: return Theme.Color.tertiaryLabel
        case .belowStart, .beyondCeiling, .skipped: return Theme.Color.tertiaryLabel.withAlphaComponent(0.35)
        }
    }
}

extension ActivityTone {
    /// Ink for words that carry a tone, where quiet means secondary rather than faint.
    var inkColor: UIColor { self == .quiet ? Theme.Color.secondaryLabel : color }
}

/// A word in a capsule, tinted by what it means: where a pass's patch went or how a run stopped.
final class DelegatePill: UIView {
    private let label = UILabel()

    init() {
        super.init(frame: .zero)
        label.font = Theme.Ramp.font(.pill)
        label.adjustsFontForContentSizeCategory = true
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        layer.cornerCurve = .continuous
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
        ])
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }

    func show(_ text: String?, tone: ActivityTone) {
        label.text = text
        isHidden = text == nil
        let ink = tone.inkColor
        label.textColor = ink
        backgroundColor = ink.withAlphaComponent(0.14)
    }
}

/// A run's ladder at the size of a row: one dot per rung, cheapest first.
final class DelegateRungPips: UIStackView {
    init() {
        super.init(frame: .zero)
        axis = .horizontal
        spacing = 3
        alignment = .center
        setContentHuggingPriority(.required, for: .horizontal)
    }

    @available(*, unavailable) required init(coder: NSCoder) { fatalError() }

    func show(_ rungs: [DelegateRungState]) {
        while arrangedSubviews.count > rungs.count { arrangedSubviews.last?.removeFromSuperview() }
        while arrangedSubviews.count < rungs.count {
            let dot = UIView()
            dot.layer.cornerRadius = 3
            dot.translatesAutoresizingMaskIntoConstraints = false
            dot.widthAnchor.constraint(equalToConstant: 6).isActive = true
            dot.heightAnchor.constraint(equalToConstant: 6).isActive = true
            addArrangedSubview(dot)
        }
        for (dot, state) in zip(arrangedSubviews, rungs) { dot.backgroundColor = state.pipColor }
        isHidden = rungs.isEmpty
    }
}

/// One run as a row of the board: what it is doing to the eye, the goal and its pill, where it is,
/// and the ladder in dots beside the repository and the age. Every word is `DelegateRunRow`'s.
final class DelegateRunRowCell: UICollectionViewListCell {
    private let badge = ActivityBadgeView(pointSize: 13)
    private let dot = UIView()
    private let headline = UILabel()
    private let pill = DelegatePill()
    private let detail = UILabel()
    private let pips = DelegateRungPips()
    private let meta = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        headline.font = Theme.Ramp.font(.rowTitle)
        headline.textColor = Theme.Color.label
        headline.numberOfLines = 2
        headline.adjustsFontForContentSizeCategory = true
        detail.font = Theme.Ramp.font(.rowDetail)
        detail.textColor = Theme.Color.secondaryLabel
        detail.numberOfLines = 2
        detail.adjustsFontForContentSizeCategory = true
        meta.font = Theme.Ramp.font(.rowMeta)
        meta.textColor = Theme.Color.tertiaryLabel
        meta.adjustsFontForContentSizeCategory = true
        dot.layer.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false

        let lead = UIView()
        lead.translatesAutoresizingMaskIntoConstraints = false
        badge.translatesAutoresizingMaskIntoConstraints = false
        lead.addSubview(badge)
        lead.addSubview(dot)

        let titleRow = UIStackView(arrangedSubviews: [headline, pill])
        titleRow.axis = .horizontal
        titleRow.alignment = .firstBaseline
        titleRow.spacing = Theme.Spacing.s
        pill.setContentHuggingPriority(.required, for: .horizontal)
        headline.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let metaRow = UIStackView(arrangedSubviews: [pips, meta])
        metaRow.axis = .horizontal
        metaRow.alignment = .center
        metaRow.spacing = Theme.Spacing.s

        let column = UIStackView(arrangedSubviews: [titleRow, detail, metaRow])
        column.axis = .vertical
        column.spacing = 3
        column.setCustomSpacing(Theme.Spacing.xs + 2, after: detail)

        let row = UIStackView(arrangedSubviews: [lead, column])
        row.axis = .horizontal
        row.alignment = .top
        row.spacing = Theme.Spacing.m
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            lead.widthAnchor.constraint(equalToConstant: 20),
            lead.heightAnchor.constraint(equalToConstant: 20),
            badge.centerXAnchor.constraint(equalTo: lead.centerXAnchor),
            badge.centerYAnchor.constraint(equalTo: lead.centerYAnchor),
            dot.centerXAnchor.constraint(equalTo: lead.centerXAnchor),
            dot.centerYAnchor.constraint(equalTo: lead.centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            row.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
        ])
        accessories = [.disclosureIndicator()]
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(_ row: DelegateRunRow) {
        headline.text = row.headline
        pill.show(row.badge, tone: row.tone)
        detail.text = row.detail
        detail.isHidden = row.detail.isEmpty
        pips.show(row.rungs)
        meta.text = [row.repo, row.age].filter { !$0.isEmpty }.joined(separator: " · ")
        badge.activity = row.activity
        dot.isHidden = row.activity != nil
        dot.backgroundColor = row.tone.color
        accessibilityLabel = row.spoken
    }
}

/// The ladder as the board draws it: one card per rung, joined cheapest to dearest, each with its
/// model, its health when that says something, and what the table says it has done.
final class DelegateBoardLadderView: UIView {
    private let scroll = UIScrollView()
    private let row = UIStackView()

    init() {
        super.init(frame: .zero)
        scroll.showsHorizontalScrollIndicator = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        row.axis = .horizontal
        row.alignment = .fill
        row.spacing = 2
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)
        scroll.addSubview(row)
        let fill = row.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor)
        fill.priority = .defaultHigh
        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: topAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            row.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
            row.widthAnchor.constraint(greaterThanOrEqualTo: scroll.frameLayoutGuide.widthAnchor),
            fill,
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(_ rungs: [DelegateBoardRung]) {
        for view in row.arrangedSubviews { view.removeFromSuperview() }
        var first: UIView?
        for (index, rung) in rungs.enumerated() {
            if index > 0 { row.addArrangedSubview(Self.joint()) }
            let card = Self.card(rung)
            row.addArrangedSubview(card)
            card.widthAnchor.constraint(greaterThanOrEqualToConstant: 84).isActive = true
            if let first { card.widthAnchor.constraint(equalTo: first.widthAnchor).isActive = true }
            first = first ?? card
        }
        accessibilityElements = row.arrangedSubviews.filter { $0.isAccessibilityElement }
    }

    private static func joint() -> UIView {
        let glyph = UIImageView(image: UIImage(systemName: "chevron.compact.right"))
        glyph.tintColor = Theme.Color.tertiaryLabel
        glyph.contentMode = .center
        glyph.preferredSymbolConfiguration = UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold)
        glyph.setContentHuggingPriority(.required, for: .horizontal)
        glyph.widthAnchor.constraint(equalToConstant: 8).isActive = true
        return glyph
    }

    private static func card(_ rung: DelegateBoardRung) -> UIView {
        let card = UIView()
        card.backgroundColor = Theme.Color.groupedBackground
        card.layer.cornerRadius = Theme.Radius.control
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.layer.borderColor = (rung.tone == .danger ? Theme.Color.danger : Theme.Color.separator).cgColor

        let title = line(rung.label.isEmpty ? rung.tier : "\(rung.tier) · \(rung.label)", role: .rowTitleStrong, color: Theme.Color.label)
        title.numberOfLines = 2
        let model = line(rung.model, role: .rowMeta, color: Theme.Color.secondaryLabel)
        model.numberOfLines = 2
        model.lineBreakMode = .byWordWrapping
        var lines: [UIView] = [title, model]
        if let health = rung.health { lines.append(line(health, role: .rowMeta, color: rung.tone.inkColor)) }
        let record = line(rung.record ?? String(localized: "untried"), role: .rowMeta, color: Theme.Color.tertiaryLabel)
        record.numberOfLines = 2
        lines.append(record)
        let column = UIStackView(arrangedSubviews: lines)
        column.axis = .vertical
        column.spacing = 2
        column.setCustomSpacing(Theme.Spacing.xs, after: title)
        column.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: card.topAnchor, constant: Theme.Spacing.s + 2),
            column.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: Theme.Spacing.s),
            column.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -Theme.Spacing.s),
            column.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor, constant: -Theme.Spacing.s - 2),
        ])
        card.isAccessibilityElement = true
        card.accessibilityLabel = [rung.tier, rung.title, rung.fullModel, rung.health, rung.record]
            .compactMap { $0 }.joined(separator: ", ")
        card.registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: UIView, _) in
            view.layer.borderColor = (rung.tone == .danger ? Theme.Color.danger : Theme.Color.separator)
                .resolvedColor(with: view.traitCollection).cgColor
        }
        return card
    }

    private static func line(_ text: String, role: TypeRole, color: UIColor) -> UILabel {
        let label = UILabel()
        label.text = text
        label.font = Theme.Ramp.font(role)
        label.textColor = color
        label.adjustsFontForContentSizeCategory = true
        label.numberOfLines = 1
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }
}

/// A view inside a list cell that draws its own card rather than the list's.
final class DelegateHostCell: UICollectionViewListCell {
    let host = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        host.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            host.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor),
            host.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Places one view edge to edge inside the cell's margins, replacing whatever was there.
    func place(_ view: UIView) {
        guard view.superview !== host else { return }
        for old in host.subviews { old.removeFromSuperview() }
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ])
    }
}
