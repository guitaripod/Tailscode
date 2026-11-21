import CodingAgentKit
import TailscodeCore
import UIKit

/// The quota strip as the card the shelf bar opens: a row a line, with the countdowns, the
/// numbers and when a window heading for its wall will hit it. The whole card is the road to
/// Usage — it is the preview, and a press on a preview goes to the page behind it.
final class HomeGlanceCell: UICollectionViewCell {
    private static let cornerRadius: CGFloat = 22
    private static let loneRowHeight: CGFloat = 44
    private static let stackedRowHeight: CGFloat = 30
    private static let stackedInset: CGFloat = 6

    private let card = GlanceCardView(cornerRadius: HomeGlanceCell.cornerRadius)
    private let column = UIStackView()
    private let chevron = UIImageView()
    private let shell = UIStackView()
    private var rows: [GlanceLineRow] = []

    override init(frame: CGRect) {
        super.init(frame: frame)
        card.backgroundColor = Theme.Color.groupedSurface
        card.translatesAutoresizingMaskIntoConstraints = false
        card.isUserInteractionEnabled = false

        column.axis = .vertical
        column.alignment = .fill

        chevron.image = UIImage(
            systemName: "chevron.right",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        chevron.tintColor = Theme.Color.tertiaryLabel
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        chevron.setContentCompressionResistancePriority(.required, for: .horizontal)

        shell.addArrangedSubview(column)
        shell.addArrangedSubview(chevron)
        shell.axis = .horizontal
        shell.alignment = .center
        shell.spacing = Theme.Spacing.s
        shell.isLayoutMarginsRelativeArrangement = true
        shell.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(card)
        contentView.addSubview(shell)
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor),
            card.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            shell.topAnchor.constraint(equalTo: contentView.topAnchor),
            shell.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            shell.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            shell.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            column.topAnchor.constraint(equalTo: shell.layoutMarginsGuide.topAnchor),
            column.bottomAnchor.constraint(equalTo: shell.layoutMarginsGuide.bottomAnchor),
        ])
        answersPointer(cornerRadius: Self.cornerRadius)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(_ card: QuotaGlanceCard) {
        UIView.performWithoutAnimation {
            apply(card)
            contentView.layoutIfNeeded()
        }
    }

    /// Adding, removing and refilling rows inside the snapshot's animation made the stack animate
    /// its arranged views while the cell was reconfigured again, and a row stayed where the
    /// half-finished animation left it: the ring outside the card and the value laid over the
    /// chevron. Applying with animations off settles every frame before the cell is seen.
    private func apply(_ card: QuotaGlanceCard) {
        let lines = card.glance.lines
        guard !lines.isEmpty else { return }
        let stacked = lines.count > 1
        let inset = stacked ? Self.stackedInset : 0
        shell.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: inset, leading: Theme.Spacing.m, bottom: inset, trailing: Theme.Spacing.m)
        seat(lines.count)
        let marked = lines.contains { $0.kind != .notice }
        for (row, line) in zip(rows, lines) {
            row.configure(
                line, minimumHeight: stacked ? Self.stackedRowHeight : Self.loneRowHeight,
                keepsMarkColumn: stacked && marked)
        }
        accessibilityLabel = lines.map(Self.spoken).joined(separator: ", ")
        accessibilityValue = nil
        accessibilityHint = String(localized: "Opens usage")
    }

    /// As many rows as the strip has lines: a row is made once and kept, so a poll that changes a
    /// number refills labels and builds nothing.
    private func seat(_ count: Int) {
        while rows.count < count {
            let row = GlanceLineRow()
            rows.append(row)
            column.addArrangedSubview(row)
        }
        while rows.count > count {
            rows.removeLast().removeFromSuperview()
        }
    }

    static func spoken(_ line: QuotaGlance.Line) -> String {
        [line.text, line.trailing, line.paceNews ?? ""].filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

/// One line of the folded strip: its mark and the provider in one word. The word wears the
/// line's tone only when the line needs attention, so a wall is found by colour before it is read.
final class GlanceMarkChip: UIView {
    private let mark = GlanceMarkView(side: 16)
    private let nameLabel = UILabel()

    init() {
        super.init(frame: .zero)
        nameLabel.font = Theme.Ramp.font(.gaugeCaption)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [mark, nameLabel])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Theme.Spacing.xs
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(_ line: QuotaGlance.Line) {
        mark.configure(line)
        nameLabel.text = line.short ?? line.text
        nameLabel.textColor = GlanceInk.words(line.tone)
    }
}

/// The mark a line wears: a window is a ring that fills, a balance is a dot because money has no
/// ceiling to fill.
final class GlanceMarkView: UIView {
    private let ring = MiniRingView()
    private let dot = UIView()

    init(side: CGFloat) {
        super.init(frame: .zero)
        let dotSide = (side * 0.4).rounded()
        ring.translatesAutoresizingMaskIntoConstraints = false
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.layer.cornerRadius = dotSide / 2
        addSubview(ring)
        addSubview(dot)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: side),
            heightAnchor.constraint(equalToConstant: side),
            ring.topAnchor.constraint(equalTo: topAnchor),
            ring.bottomAnchor.constraint(equalTo: bottomAnchor),
            ring.leadingAnchor.constraint(equalTo: leadingAnchor),
            ring.trailingAnchor.constraint(equalTo: trailingAnchor),
            dot.centerXAnchor.constraint(equalTo: centerXAnchor),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: dotSide),
            dot.heightAnchor.constraint(equalToConstant: dotSide),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(_ line: QuotaGlance.Line) {
        let sentence = line.kind == .notice
        let gauge = !sentence && line.fraction != nil
        let tint = GlanceInk.mark(line.tone)
        ring.isHidden = !gauge
        ring.fraction = line.fraction
        ring.tint = tint
        dot.isHidden = sentence || gauge
        dot.backgroundColor = tint
    }
}

/// The colours the quota strip's tones are drawn in.
enum GlanceInk {
    static func mark(_ tone: QuotaGlance.Tone) -> UIColor {
        switch tone {
        case .ok: return Theme.Color.accent
        case .warn: return Theme.Color.warning
        case .danger: return Theme.Color.danger
        case .balance: return Theme.Color.info
        case .quiet: return Theme.Color.tertiaryLabel
        }
    }

    /// Only what needs attention leaves the page's own ink, so a card of quiet windows reads as
    /// text and a wall is the one coloured thing on it.
    static func words(_ tone: QuotaGlance.Tone) -> UIColor {
        switch tone {
        case .ok, .balance: return Theme.Color.label
        case .warn: return Theme.Color.warning
        case .danger: return Theme.Color.danger
        case .quiet: return Theme.Color.secondaryLabel
        }
    }
}

/// One line of the quota strip: the mark its tone wears, its words, and the number the words are
/// about in a column the rows share. A sentence about the reading itself wears no mark and starts
/// where the words start. A window heading for its wall says so on a second line under its words.
final class GlanceLineRow: UIView {
    /// What a row keeps above and below its words, so one that says two things under its name
    /// does not touch its neighbours; a row of one line is shorter than its minimum either way.
    private static let breathing: CGFloat = 4

    private let mark = GlanceMarkView(side: 20)
    private let textLabel = UILabel()
    private let newsLabel = UILabel()
    private let valueLabel = UILabel()
    private let minimum: NSLayoutConstraint

    init() {
        let row = UIStackView()
        minimum = row.heightAnchor.constraint(greaterThanOrEqualToConstant: 44)
        super.init(frame: .zero)

        textLabel.font = Theme.Ramp.font(.gauge)
        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        newsLabel.font = Theme.Ramp.font(.gaugeCaption)
        newsLabel.numberOfLines = 2
        newsLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        valueLabel.font = Theme.Ramp.font(.gauge)
        valueLabel.textAlignment = .right
        valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        valueLabel.setContentHuggingPriority(.required, for: .horizontal)

        let words = UIStackView(arrangedSubviews: [textLabel, newsLabel])
        words.axis = .vertical
        words.spacing = 1

        row.addArrangedSubview(mark)
        row.addArrangedSubview(words)
        row.addArrangedSubview(valueLabel)
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Theme.Spacing.s
        row.isLayoutMarginsRelativeArrangement = true
        row.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: Self.breathing, leading: 0, bottom: Self.breathing, trailing: 0)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            minimum,
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// `keepsMarkColumn` holds the mark's place on a line that wears none, so a sentence among
    /// gauges starts where their words start; a sentence on its own starts at the card's edge.
    func configure(_ line: QuotaGlance.Line, minimumHeight: CGFloat, keepsMarkColumn: Bool) {
        minimum.constant = minimumHeight
        let sentence = line.kind == .notice

        textLabel.text = line.text
        textLabel.textColor = sentence ? GlanceInk.words(line.tone) : Theme.Color.label

        valueLabel.text = line.trailing
        valueLabel.isHidden = line.trailing.isEmpty
        valueLabel.textColor = GlanceInk.words(line.tone)

        let news = line.paceNews
        newsLabel.text = news
        newsLabel.isHidden = news == nil
        newsLabel.textColor = GlanceInk.mark(line.tone)

        mark.configure(line)
        mark.isHidden = sentence && !keepsMarkColumn
    }
}

/// A surface that is a capsule while it is one row tall and a rounded card once it is taller.
final class GlanceCardView: UIView {
    private let cornerRadius: CGFloat

    init(cornerRadius: CGFloat) {
        self.cornerRadius = cornerRadius
        super.init(frame: .zero)
        layer.cornerCurve = .continuous
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = min(bounds.height / 2, cornerRadius)
    }
}

final class CapsuleView: UIView {
    override func layoutSubviews() {
        super.layoutSubviews()
        layer.cornerRadius = bounds.height / 2
    }
}

final class MiniRingView: UIView {
    private let track = CAShapeLayer()
    private let fill = CAShapeLayer()

    var fraction: Double? {
        didSet { setNeedsLayout() }
    }

    var tint: UIColor = Theme.Color.accent {
        didSet { refreshColors() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        track.fillColor = UIColor.clear.cgColor
        track.lineWidth = 3
        fill.fillColor = UIColor.clear.cgColor
        fill.lineWidth = 3
        fill.lineCap = .round
        layer.addSublayer(track)
        layer.addSublayer(fill)
        refreshColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeIdentityTrait.self]) {
            (view: MiniRingView, _: UITraitCollection) in
            view.refreshColors()
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func refreshColors() {
        track.strokeColor = Theme.Color.separator.resolvedColor(with: traitCollection).cgColor
        fill.strokeColor = tint.resolvedColor(with: traitCollection).cgColor
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let radius = (min(bounds.width, bounds.height) - 3) / 2
        let path = UIBezierPath(
            arcCenter: CGPoint(x: bounds.midX, y: bounds.midY), radius: max(radius, 0),
            startAngle: -.pi / 2, endAngle: 1.5 * .pi, clockwise: true)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        track.path = path.cgPath
        fill.path = path.cgPath
        fill.strokeEnd = CGFloat(min(max(fraction ?? 0, 0), 1))
        CATransaction.commit()
    }
}
