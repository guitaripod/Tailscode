import CodingAgentKit
import UIKit

enum HomeSection: Hashable {
    case live, servers, recent, usage
}

enum HomeItem: Hashable {
    case live(LiveCard)
    case server(ServerCard)
    case recent(RecentCard)
    case usage(QuotaCard)
}

struct LiveCard: Hashable {
    let entry: SessionEntry
    let title: String
    let detail: String

    init(entry: SessionEntry) {
        self.entry = entry
        let trimmed = entry.session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = AgentSession.isPlaceholderTitle(trimmed) ? "New conversation" : trimmed
        var parts = [entry.profileName]
        if let directory = entry.session.directory {
            parts.append((directory as NSString).lastPathComponent)
        }
        if let badge = ModelBadge.text(for: entry.session) {
            parts.append(badge)
        }
        self.detail = parts.joined(separator: " · ")
    }

    static func == (lhs: LiveCard, rhs: LiveCard) -> Bool {
        lhs.entry == rhs.entry
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(entry)
    }
}

/// Card identity is the stable key; the volatile fields are cell content,
/// refreshed via reconfigure so a data refresh never animates delete+insert.
struct ServerCard: Hashable {
    let profileID: String
    let name: String
    let backend: AgentType
    let host: String
    let reachable: Bool
    let sessionCount: Int
    let liveCount: Int

    static func == (lhs: ServerCard, rhs: ServerCard) -> Bool {
        lhs.profileID == rhs.profileID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(profileID)
    }
}

struct RecentCard: Hashable {
    let entry: SessionEntry
    let title: String
    let detail: String

    init(entry: SessionEntry) {
        self.entry = entry
        let trimmed = entry.session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title = AgentSession.isPlaceholderTitle(trimmed) ? "New conversation" : trimmed
        var parts: [String] = [entry.profileName]
        if let directory = entry.session.directory {
            parts.append((directory as NSString).lastPathComponent)
        }
        if let badge = ModelBadge.text(for: entry.session) {
            parts.append(badge)
        }
        parts.append(entry.session.updatedAt.formatted(.relative(presentation: .named)))
        self.detail = parts.joined(separator: " · ")
    }

    static func == (lhs: RecentCard, rhs: RecentCard) -> Bool {
        lhs.entry == rhs.entry
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(entry)
    }
}

struct QuotaCard: Hashable {
    let quota: UsageQuota

    static func == (lhs: QuotaCard, rhs: QuotaCard) -> Bool {
        lhs.quota.providerName == rhs.quota.providerName
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(quota.providerName)
    }
}

/// Shared chrome for every Home card: a glass surface with continuous
/// corners that all content floats on.
class GlassCardCell: UICollectionViewCell {
    let surface = Theme.Glass.view()

    override init(frame: CGRect) {
        super.init(frame: frame)
        surface.layer.cornerRadius = Theme.Radius.card
        surface.layer.cornerCurve = .continuous
        surface.clipsToBounds = true
        surface.isUserInteractionEnabled = false
        surface.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(surface)
        NSLayoutConstraint.activate([
            surface.topAnchor.constraint(equalTo: contentView.topAnchor),
            surface.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            surface.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            surface.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet {
            UIView.animate(withDuration: 0.15) {
                self.contentView.transform =
                    self.isHighlighted
                    ? CGAffineTransform(scaleX: 0.97, y: 0.97) : .identity
            }
        }
    }
}

final class LiveSessionCell: GlassCardCell {
    private let dot = UIView()
    private let liveLabel = UILabel()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        dot.backgroundColor = Theme.Color.success
        dot.layer.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false

        liveLabel.text = "LIVE"
        liveLabel.font = .systemFont(ofSize: 10, weight: .heavy)
        liveLabel.textColor = Theme.Color.success
        liveLabel.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .preferredFont(forTextStyle: .subheadline).withTraits(.traitBold)
        titleLabel.textColor = Theme.Color.label
        titleLabel.numberOfLines = 2
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.font = .preferredFont(forTextStyle: .caption2)
        detailLabel.textColor = Theme.Color.secondaryLabel
        detailLabel.numberOfLines = 1
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        [dot, liveLabel, titleLabel, detailLabel].forEach(contentView.addSubview)
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Spacing.m),
            dot.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Spacing.m + 2),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            liveLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: Theme.Spacing.xs),
            liveLabel.centerYAnchor.constraint(equalTo: dot.centerYAnchor),

            titleLabel.topAnchor.constraint(equalTo: dot.bottomAnchor, constant: Theme.Spacing.s),
            titleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Spacing.m),
            titleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.m),

            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: titleLabel.trailingAnchor),
            detailLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Theme.Spacing.m),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(_ card: LiveCard) {
        titleLabel.text = card.title
        detailLabel.text = card.detail
        accessibilityLabel = "Live: \(card.title), \(card.detail)"
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        dot.layer.removeAnimation(forKey: "pulse")
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.3
        pulse.duration = 0.9
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        dot.layer.add(pulse, forKey: "pulse")
    }
}

final class ServerCardCell: GlassCardCell {
    var onNewChat: (() -> Void)?

    private let iconBackground = UIView()
    private let iconView = UIImageView()
    private let nameLabel = UILabel()
    private let detailLabel = UILabel()
    private let newChatButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        iconBackground.layer.cornerRadius = 20
        iconBackground.layer.cornerCurve = .continuous
        iconBackground.translatesAutoresizingMaskIntoConstraints = false

        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .preferredFont(forTextStyle: .headline)
        nameLabel.textColor = Theme.Color.label
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.font = .preferredFont(forTextStyle: .caption1)
        detailLabel.textColor = Theme.Color.secondaryLabel
        detailLabel.numberOfLines = 1
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        var config = Theme.Glass.buttonConfiguration(prominent: true)
        config.image = UIImage(
            systemName: "plus",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 14, weight: .bold))
        config.cornerStyle = .capsule
        newChatButton.configuration = config
        newChatButton.accessibilityLabel = "New chat"
        newChatButton.translatesAutoresizingMaskIntoConstraints = false
        newChatButton.addAction(
            UIAction { [weak self] _ in
                Theme.Haptics.tap()
                self?.onNewChat?()
            }, for: .touchUpInside)

        iconBackground.addSubview(iconView)
        [iconBackground, nameLabel, detailLabel, newChatButton].forEach(contentView.addSubview)
        NSLayoutConstraint.activate([
            iconBackground.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Spacing.m),
            iconBackground.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            iconBackground.widthAnchor.constraint(equalToConstant: 40),
            iconBackground.heightAnchor.constraint(equalToConstant: 40),
            iconView.centerXAnchor.constraint(equalTo: iconBackground.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconBackground.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 22),
            iconView.heightAnchor.constraint(equalToConstant: 22),

            nameLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Spacing.m),
            nameLabel.leadingAnchor.constraint(equalTo: iconBackground.trailingAnchor, constant: Theme.Spacing.m),
            nameLabel.trailingAnchor.constraint(lessThanOrEqualTo: newChatButton.leadingAnchor, constant: -Theme.Spacing.s),

            detailLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
            detailLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: newChatButton.leadingAnchor, constant: -Theme.Spacing.s),
            detailLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Theme.Spacing.m),

            newChatButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.m),
            newChatButton.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            newChatButton.widthAnchor.constraint(equalToConstant: 44),
            newChatButton.heightAnchor.constraint(equalToConstant: 44),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(_ card: ServerCard) {
        iconBackground.backgroundColor = card.backend.brandColor.withAlphaComponent(0.15)
        iconView.image = UIImage(systemName: card.backend.symbolName)?
            .withTintColor(card.backend.brandColor, renderingMode: .alwaysOriginal)
        nameLabel.text = card.name
        var parts = [card.backend.displayName]
        if !card.reachable {
            parts.append("unreachable")
        } else {
            parts.append("\(card.sessionCount) chat\(card.sessionCount == 1 ? "" : "s")")
            if card.liveCount > 0 { parts.append("\(card.liveCount) live") }
        }
        let detail = parts.joined(separator: " · ")
        detailLabel.text = detail
        detailLabel.textColor = card.reachable ? Theme.Color.secondaryLabel : Theme.Color.danger
        accessibilityLabel = "\(card.name), \(detail)"
        isAccessibilityElement = false
        accessibilityElements = [newChatButton]
    }
}

final class RecentSessionCell: GlassCardCell {
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let chevron = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .preferredFont(forTextStyle: .subheadline)
        titleLabel.textColor = Theme.Color.label
        titleLabel.numberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.font = .preferredFont(forTextStyle: .caption2)
        detailLabel.textColor = Theme.Color.tertiaryLabel
        detailLabel.numberOfLines = 1
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        chevron.image = UIImage(
            systemName: "chevron.right",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        chevron.tintColor = Theme.Color.tertiaryLabel
        chevron.translatesAutoresizingMaskIntoConstraints = false

        [iconView, titleLabel, detailLabel, chevron].forEach(contentView.addSubview)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Spacing.m),
            iconView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),

            titleLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Spacing.s + 2),
            titleLabel.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: Theme.Spacing.m),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -Theme.Spacing.s),

            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor, constant: -Theme.Spacing.s),
            detailLabel.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -(Theme.Spacing.s + 2)),

            chevron.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.m),
            chevron.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(_ card: RecentCard) {
        iconView.image = UIImage(systemName: card.entry.backendType.symbolName)?
            .withTintColor(card.entry.backendType.brandColor, renderingMode: .alwaysOriginal)
        titleLabel.text = card.title
        detailLabel.text = card.detail
        accessibilityLabel = "\(card.title), \(card.detail)"
        isAccessibilityElement = true
        accessibilityTraits = .button
    }
}

final class QuotaCardCell: GlassCardCell {
    private let providerLabel = UILabel()
    private let gaugeStack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        providerLabel.font = .preferredFont(forTextStyle: .subheadline).withTraits(.traitBold)
        providerLabel.textColor = Theme.Color.label
        providerLabel.translatesAutoresizingMaskIntoConstraints = false

        gaugeStack.axis = .vertical
        gaugeStack.spacing = Theme.Spacing.s
        gaugeStack.translatesAutoresizingMaskIntoConstraints = false

        [providerLabel, gaugeStack].forEach(contentView.addSubview)
        NSLayoutConstraint.activate([
            providerLabel.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Spacing.m),
            providerLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Spacing.m),
            providerLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.m),

            gaugeStack.topAnchor.constraint(equalTo: providerLabel.bottomAnchor, constant: Theme.Spacing.s),
            gaugeStack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Spacing.m),
            gaugeStack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.m),
            gaugeStack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Theme.Spacing.m),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(_ card: QuotaCard) {
        var header = card.quota.providerName
        if let session = card.quota.gauges.first(where: { $0.trustedReset }),
            let resetsAt = session.resetsAt, resetsAt > Date()
        {
            let minutes = max(1, Int(resetsAt.timeIntervalSinceNow / 60))
            let countdown = minutes < 60 ? "\(minutes)m" : "\(minutes / 60)h \(minutes % 60)m"
            header += "  ·  resets in \(countdown)"
        }
        providerLabel.text = header
        gaugeStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for gauge in card.quota.gauges.prefix(3) {
            gaugeStack.addArrangedSubview(Self.gaugeRow(gauge))
        }
        accessibilityLabel = card.quota.providerName
        accessibilityValue = card.quota.gauges.prefix(3)
            .map { "\($0.label) \(Int($0.fraction * 100)) percent" }
            .joined(separator: ", ")
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    private static func gaugeRow(_ gauge: UsageQuota.Gauge) -> UIView {
        let label = UILabel()
        label.font = .preferredFont(forTextStyle: .caption2)
        label.textColor = Theme.Color.secondaryLabel
        label.text = gauge.label
        label.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let percent = UILabel()
        percent.font = UIFont.monospacedDigitSystemFont(ofSize: 12, weight: .semibold)
        percent.textColor = gauge.fraction > 0.85 ? Theme.Color.danger : Theme.Color.label
        percent.text = "\(Int((gauge.fraction * 100).rounded()))%"
        percent.setContentHuggingPriority(.required, for: .horizontal)

        let top = UIStackView(arrangedSubviews: [label, percent])
        top.axis = .horizontal
        top.spacing = Theme.Spacing.s

        let track = UIView()
        track.backgroundColor = Theme.Color.reasoningBackground
        track.layer.cornerRadius = 3
        track.translatesAutoresizingMaskIntoConstraints = false
        track.heightAnchor.constraint(equalToConstant: 6).isActive = true

        let fill = UIView()
        fill.backgroundColor =
            gauge.fraction > 0.85
            ? Theme.Color.danger : (gauge.fraction > 0.6 ? Theme.Color.warning : Theme.Color.accent)
        fill.layer.cornerRadius = 3
        fill.translatesAutoresizingMaskIntoConstraints = false
        track.addSubview(fill)
        NSLayoutConstraint.activate([
            fill.topAnchor.constraint(equalTo: track.topAnchor),
            fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
            fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            fill.widthAnchor.constraint(
                equalTo: track.widthAnchor, multiplier: max(0.02, min(1, gauge.fraction))),
        ])

        let column = UIStackView(arrangedSubviews: [top, track])
        column.axis = .vertical
        column.spacing = 4
        return column
    }
}

final class HomeHeaderView: UICollectionReusableView {
    private let titleLabel = UILabel()
    private let actionButton = UIButton(type: .system)
    private var onAction: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        titleLabel.font = .preferredFont(forTextStyle: .footnote).withTraits(.traitBold)
        titleLabel.textColor = Theme.Color.secondaryLabel
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        actionButton.titleLabel?.font = .preferredFont(forTextStyle: .footnote)
        actionButton.translatesAutoresizingMaskIntoConstraints = false
        actionButton.addAction(
            UIAction { [weak self] _ in
                Theme.Haptics.tap()
                self?.onAction?()
            }, for: .touchUpInside)

        addSubview(titleLabel)
        addSubview(actionButton)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.l),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Spacing.xs),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Spacing.xs),
            actionButton.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Spacing.l),
            actionButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, actionTitle: String? = nil, onAction: (() -> Void)? = nil) {
        titleLabel.text = title.uppercased()
        self.onAction = onAction
        if let actionTitle {
            actionButton.setTitle("\(actionTitle) ›", for: .normal)
            actionButton.isHidden = false
        } else {
            actionButton.isHidden = true
        }
    }
}
