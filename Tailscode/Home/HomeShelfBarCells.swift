import CodingAgentKit
import TailscodeCore
import UIKit

/// What Home's shelf bar has open under it, which is the person's and is remembered.
enum HomeShelfPeek: String {
    case none, masters, quota

    private static let key = "tailscode.home.shelfPeek"

    static var current: HomeShelfPeek {
        get { UserDefaults.standard.string(forKey: key).flatMap(HomeShelfPeek.init) ?? .none }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }
}

/// The two things Home keeps behind a button rather than on the page: the masters and the
/// account's quotas. There is only ever one bar, so its identity is nothing at all.
struct HomeShelfBarCard: Hashable {
    let masters: MasterBoard?
    let glance: QuotaGlance?
    let peek: HomeShelfPeek

    static func == (lhs: HomeShelfBarCard, rhs: HomeShelfBarCard) -> Bool { true }
    func hash(into hasher: inout Hasher) {}
}

/// One row of buttons that stand for whole cards. Each says what its card would lead with — a
/// dot per master in the tone its state wears and how many notes wait, a ring per quota line in
/// its tone — so a wall or a failing guard is seen from the button, and a press opens the card
/// under the bar as a preview; a press on the preview is the road to the page behind it, and a
/// press on the button again puts it away.
final class HomeShelfBarCell: UICollectionViewCell {
    var onPick: ((HomeShelfPeek) -> Void)?

    private let mastersButton = ShelfButton()
    private let quotaButton = ShelfButton()

    override init(frame: CGRect) {
        super.init(frame: frame)
        let row = UIStackView(arrangedSubviews: [mastersButton, quotaButton])
        row.axis = .horizontal
        row.distribution = .fillEqually
        row.spacing = Theme.Spacing.s
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: contentView.topAnchor),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        mastersButton.addAction(UIAction { [weak self] _ in self?.onPick?(.masters) }, for: .touchUpInside)
        quotaButton.addAction(UIAction { [weak self] _ in self?.onPick?(.quota) }, for: .touchUpInside)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(_ card: HomeShelfBarCard) {
        UIView.performWithoutAnimation {
            mastersButton.isHidden = card.masters == nil
            quotaButton.isHidden = card.glance == nil
            if let board = card.masters { fillMasters(board, open: card.peek == .masters) }
            if let glance = card.glance {
                fillQuota(glance, open: card.peek == .quota, alone: card.masters == nil)
            }
            contentView.layoutIfNeeded()
        }
    }

    private func fillMasters(_ board: MasterBoard, open: Bool) {
        let title = UILabel()
        title.text = MasterWords.title
        title.font = Theme.Ramp.font(.gauge)
        title.textColor = Theme.Color.label
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        var parts: [UIView] = [title]
        for row in board.rows.prefix(Self.dotLimit) {
            parts.append(ShelfDot(color: MasterStyle.color(row.state().tone)))
        }
        let waiting = board.rows.compactMap { MasterReading.badge($0.master) }.reduce(0, +)
        if waiting > 0 { parts.append(MasterShelf.badge(waiting)) }
        mastersButton.fill(parts, open: open)
        var spoken = [MasterWords.title]
        spoken += board.rows.map { [$0.master.name, $0.state().text].joined(separator: ", ") }
        mastersButton.accessibilityLabel = spoken.joined(separator: ". ")
    }

    private static let dotLimit = 5

    /// With the bar to itself the quota button has room to name each provider; sharing the row
    /// it is the rings alone, which is what a tone needs to be seen.
    private func fillQuota(_ glance: QuotaGlance, open: Bool, alone: Bool) {
        let marked = glance.lines.filter { $0.kind != .notice }
        var parts: [UIView]
        if marked.isEmpty {
            let label = UILabel()
            label.text = glance.lines.first?.text
            label.font = Theme.Ramp.font(.gauge)
            label.textColor = GlanceInk.words(glance.lines.first?.tone ?? .quiet)
            label.lineBreakMode = .byTruncatingTail
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            parts = [label]
        } else if alone {
            parts = marked.map { line in
                let chip = GlanceMarkChip()
                chip.configure(line)
                return chip
            }
        } else {
            parts = marked.map { line in
                let ring = GlanceMarkView(side: 20)
                ring.configure(line)
                return ring
            }
        }
        quotaButton.fill(parts, open: open, spread: !marked.isEmpty)
        quotaButton.accessibilityLabel = glance.lines.map(HomeGlanceCell.spoken).joined(separator: ", ")
        quotaButton.accessibilityHint =
            open ? String(localized: "Folds the quotas") : String(localized: "Shows every quota")
    }
}

/// A capsule that stands for a card and says whether the card is out: the chevron points down
/// while it is, and the surface wears the accent's wash.
final class ShelfButton: UIControl {
    private let content = UIStackView()
    private let chevron = UIImageView()
    private let surface = CapsuleView()

    init() {
        super.init(frame: .zero)
        surface.isUserInteractionEnabled = false
        surface.layer.cornerCurve = .continuous
        surface.translatesAutoresizingMaskIntoConstraints = false
        content.axis = .horizontal
        content.alignment = .center
        content.spacing = Theme.Spacing.s
        content.isUserInteractionEnabled = false
        chevron.tintColor = Theme.Color.tertiaryLabel
        chevron.setContentHuggingPriority(.required, for: .horizontal)
        chevron.setContentCompressionResistancePriority(.required, for: .horizontal)
        let row = UIStackView(arrangedSubviews: [content, chevron])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Theme.Spacing.s
        row.isUserInteractionEnabled = false
        row.isLayoutMarginsRelativeArrangement = true
        row.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: 0, leading: Theme.Spacing.m, bottom: 0, trailing: Theme.Spacing.m)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(surface)
        addSubview(row)
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: topAnchor),
            surface.bottomAnchor.constraint(equalTo: bottomAnchor),
            surface.leadingAnchor.constraint(equalTo: leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        answersPointer(cornerRadius: 22)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.6 : 1 }
    }

    /// `spread` lays the parts across the whole button rather than packing them at its leading
    /// edge, which is how a row of rings reads as one gauge.
    func fill(_ parts: [UIView], open: Bool, spread: Bool = false) {
        content.arrangedSubviews.forEach { $0.removeFromSuperview() }
        content.distribution = spread ? .equalSpacing : .fill
        parts.forEach(content.addArrangedSubview)
        if !spread { content.addArrangedSubview(UIView()) }
        chevron.image = UIImage(
            systemName: open ? "chevron.up" : "chevron.down",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        surface.backgroundColor =
            open ? Theme.Color.accent.withAlphaComponent(0.16) : Theme.Color.groupedSurface
        accessibilityTraits = open ? [.button, .selected] : .button
    }
}

/// A master's state as one dot.
final class ShelfDot: UIView {
    init(color: UIColor) {
        super.init(frame: .zero)
        backgroundColor = color
        layer.cornerRadius = 4
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 8), heightAnchor.constraint(equalToConstant: 8),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}
