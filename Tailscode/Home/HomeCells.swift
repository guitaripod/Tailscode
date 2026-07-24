import CodingAgentKit
import UIKit

enum HomeSection: Hashable {
    case alerts, live, projects, recent, usage
}

enum HomeItem: Hashable {
    case alert(ServerAlertCard)
    case live(LiveCard)
    case project(ProjectCard)
    case recent(RecentCard)
    case usage(QuotaCard)
    case placeholder(Int)
}

struct LiveCard: Hashable {
    enum Presence {
        case working, needsInput, syncing
    }

    let entry: SessionEntry
    let title: String
    let detail: String
    let presence: Presence

    init(entry: SessionEntry, presence: Presence) {
        self.entry = entry
        self.presence = presence
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
struct ServerAlertCard: Hashable {
    let profileID: String
    let name: String

    static func == (lhs: ServerAlertCard, rhs: ServerAlertCard) -> Bool {
        lhs.profileID == rhs.profileID
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(profileID)
    }
}

struct ProjectCard: Hashable {
    let profileID: String
    let profileName: String
    let backend: AgentType
    let directory: String
    let chatCount: Int

    var name: String { (directory as NSString).lastPathComponent }

    static func == (lhs: ProjectCard, rhs: ProjectCard) -> Bool {
        lhs.profileID == rhs.profileID && lhs.directory == rhs.directory
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(profileID)
        hasher.combine(directory)
    }
}

struct RecentCard: Hashable {
    let entry: SessionEntry
    let title: String
    let detail: String
    let unread: Bool

    init(entry: SessionEntry, unread: Bool) {
        self.entry = entry
        self.unread = unread
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
    private let stateLabel = UILabel()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        dot.layer.cornerRadius = 4
        dot.translatesAutoresizingMaskIntoConstraints = false

        stateLabel.font = .systemFont(ofSize: 10, weight: .heavy)
        stateLabel.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .preferredFont(forTextStyle: .subheadline).withTraits(.traitBold)
        titleLabel.textColor = Theme.Color.label
        titleLabel.numberOfLines = 2
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.font = .preferredFont(forTextStyle: .caption2)
        detailLabel.textColor = Theme.Color.secondaryLabel
        detailLabel.numberOfLines = 1
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        [dot, stateLabel, titleLabel, detailLabel].forEach(contentView.addSubview)
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Spacing.m),
            dot.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Spacing.m + 2),
            dot.widthAnchor.constraint(equalToConstant: 8),
            dot.heightAnchor.constraint(equalToConstant: 8),
            stateLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: Theme.Spacing.xs),
            stateLabel.centerYAnchor.constraint(equalTo: dot.centerYAnchor),

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
        let (color, state): (UIColor, String) =
            switch card.presence {
            case .needsInput: (Theme.Color.warning, "NEEDS YOU")
            case .working: (Theme.Color.success, "LIVE")
            case .syncing: (Theme.Color.tertiaryLabel, "SYNCING")
            }
        dot.backgroundColor = color
        stateLabel.textColor = color
        stateLabel.text = state
        accessibilityLabel = "\(state): \(card.title), \(card.detail)"
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

/// A project is a directory you've chatted in; tapping one aims the docked
/// composer at it, so the rail is a set of zero-cost launch pads rather than
/// a row of server mutations.
final class ProjectCell: GlassCardCell {
    private let iconBackground = UIView()
    private let iconView = UIImageView()
    private let nameLabel = UILabel()
    private let detailLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        iconBackground.layer.cornerRadius = 8
        iconBackground.layer.cornerCurve = .continuous
        iconBackground.translatesAutoresizingMaskIntoConstraints = false

        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false

        nameLabel.font = .preferredFont(forTextStyle: .subheadline).withTraits(.traitBold)
        nameLabel.textColor = Theme.Color.label
        nameLabel.numberOfLines = 1
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.font = .preferredFont(forTextStyle: .caption2)
        detailLabel.textColor = Theme.Color.tertiaryLabel
        detailLabel.numberOfLines = 1
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        iconBackground.addSubview(iconView)
        [iconBackground, nameLabel, detailLabel].forEach(contentView.addSubview)
        NSLayoutConstraint.activate([
            iconBackground.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Spacing.m),
            iconBackground.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Spacing.m),
            iconBackground.widthAnchor.constraint(equalToConstant: 28),
            iconBackground.heightAnchor.constraint(equalToConstant: 28),
            iconView.centerXAnchor.constraint(equalTo: iconBackground.centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: iconBackground.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 15),
            iconView.heightAnchor.constraint(equalToConstant: 15),

            nameLabel.topAnchor.constraint(equalTo: iconBackground.bottomAnchor, constant: Theme.Spacing.s),
            nameLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Spacing.m),
            nameLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.m),

            detailLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 1),
            detailLabel.leadingAnchor.constraint(equalTo: nameLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(equalTo: nameLabel.trailingAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(_ card: ProjectCard) {
        iconBackground.backgroundColor = card.backend.brandColor.withAlphaComponent(0.15)
        iconView.image = UIImage(systemName: "folder.fill")?
            .withTintColor(card.backend.brandColor, renderingMode: .alwaysOriginal)
        nameLabel.text = card.name
        let detail = "\(card.chatCount) chat\(card.chatCount == 1 ? "" : "s") · \(card.profileName)"
        detailLabel.text = detail
        accessibilityLabel = "Project \(card.name), \(detail)"
        accessibilityHint = "Aims the composer at this project"
        isAccessibilityElement = true
        accessibilityTraits = .button
    }
}

final class ServerAlertCell: GlassCardCell {
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let chevron = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        iconView.image = UIImage(
            systemName: "exclamationmark.triangle.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold))
        iconView.tintColor = Theme.Color.danger
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .preferredFont(forTextStyle: .subheadline).withTraits(.traitBold)
        titleLabel.textColor = Theme.Color.label
        titleLabel.numberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.font = .preferredFont(forTextStyle: .caption2)
        detailLabel.textColor = Theme.Color.secondaryLabel
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
            iconView.widthAnchor.constraint(equalToConstant: 22),

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

    func configure(_ card: ServerAlertCard) {
        titleLabel.text = "\(card.name) is unreachable"
        detailLabel.text = "Check the server or Tailscale, then pull to refresh."
        accessibilityLabel = "\(card.name) is unreachable"
        isAccessibilityElement = true
        accessibilityTraits = .button
    }
}

final class RecentSessionCell: GlassCardCell {
    private let iconView = UIImageView()
    private let unreadBadge = UIView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let chevron = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false

        unreadBadge.backgroundColor = Theme.Color.accent
        unreadBadge.layer.cornerRadius = 4.5
        unreadBadge.layer.borderWidth = 1.5
        unreadBadge.layer.borderColor = Theme.Color.groupedBackground.cgColor
        unreadBadge.translatesAutoresizingMaskIntoConstraints = false

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

        [iconView, unreadBadge, titleLabel, detailLabel, chevron].forEach(contentView.addSubview)
        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Spacing.m),
            iconView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),

            unreadBadge.centerXAnchor.constraint(equalTo: iconView.trailingAnchor, constant: -1),
            unreadBadge.centerYAnchor.constraint(equalTo: iconView.topAnchor, constant: 1),
            unreadBadge.widthAnchor.constraint(equalToConstant: 9),
            unreadBadge.heightAnchor.constraint(equalToConstant: 9),

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
        unreadBadge.isHidden = !card.unread
        titleLabel.font = card.unread
            ? .preferredFont(forTextStyle: .subheadline).withTraits(.traitBold)
            : .preferredFont(forTextStyle: .subheadline)
        titleLabel.text = card.title
        detailLabel.text = card.detail
        accessibilityLabel = card.unread
            ? "Unread: \(card.title), \(card.detail)" : "\(card.title), \(card.detail)"
        isAccessibilityElement = true
        accessibilityTraits = .button
    }
}

/// Skeleton stand-in for a `RecentSessionCell` while the first-ever session
/// fetch is in flight (no cached list yet). Mirrors that cell's geometry so
/// the swap to real rows doesn't shift the layout.
final class RecentPlaceholderCell: GlassCardCell {
    private let iconBlock = UIView()
    private let titleBar = UIView()
    private let detailBar = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        for block in [iconBlock, titleBar, detailBar] {
            block.backgroundColor = Theme.Color.separator
            block.layer.cornerCurve = .continuous
            block.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(block)
        }
        iconBlock.layer.cornerRadius = 10
        titleBar.layer.cornerRadius = 7
        detailBar.layer.cornerRadius = 5

        NSLayoutConstraint.activate([
            iconBlock.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Spacing.m),
            iconBlock.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            iconBlock.widthAnchor.constraint(equalToConstant: 20),
            iconBlock.heightAnchor.constraint(equalToConstant: 20),

            titleBar.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Spacing.s + 4),
            titleBar.leadingAnchor.constraint(equalTo: iconBlock.trailingAnchor, constant: Theme.Spacing.m),
            titleBar.widthAnchor.constraint(equalTo: contentView.widthAnchor, multiplier: 0.5),
            titleBar.heightAnchor.constraint(equalToConstant: 14),

            detailBar.topAnchor.constraint(equalTo: titleBar.bottomAnchor, constant: 5),
            detailBar.leadingAnchor.constraint(equalTo: titleBar.leadingAnchor),
            detailBar.widthAnchor.constraint(equalTo: contentView.widthAnchor, multiplier: 0.3),
            detailBar.heightAnchor.constraint(equalToConstant: 10),
            detailBar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -(Theme.Spacing.s + 4)),
        ])

        isAccessibilityElement = true
        accessibilityLabel = "Loading recent chats"
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        contentView.layer.removeAnimation(forKey: "shimmer")
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.45
        pulse.duration = 0.8
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        contentView.layer.add(pulse, forKey: "shimmer")
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
