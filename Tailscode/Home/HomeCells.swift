import TailscodeCore
import CodingAgentKit
import UIKit

enum HomeSection: Hashable {
    case alerts, missed, live, saved, projects, recent, usage
}

enum HomeItem: Hashable {
    case alert(ServerAlertCard)
    case missed(MissedActivity)
    case live(LiveCard)
    case saved(SavedCard)
    case project(ProjectCard)
    case recent(RecentCard)
    case usage(QuotaCard)
    case placeholder(Int)
    case usagePlaceholder(Int)
}

extension HomeItem {
    /// Everything the cell for this item would draw, folded to one value.
    ///
    /// Identity answers which card a row *is* — deliberately just the session or the bookmark, so a
    /// refresh reconfigures a row rather than animating it away and back. It says nothing about
    /// whether anything on the row moved, and the board is rebuilt by everything that moves
    /// anywhere: without this, one agent's step reconfigured every visible card, and each of those
    /// re-measures itself. The two ages that tick on their own (a missed notice, a quota window)
    /// are folded as the words they render as, so a row redraws exactly when its own reading
    /// changes and not once a second before it.
    var contentSignature: Int {
        var hasher = Hasher()
        switch self {
        case .alert(let card):
            hasher.combine(card.name)
        case .missed(let item):
            hasher.combine(item.title)
            hasher.combine(item.reason)
            hasher.combine(StatusFacts.age(Date().timeIntervalSince(item.at)))
        case .live(let card):
            hasher.combine(card.title)
            hasher.combine(card.detail)
            hasher.combine(card.age)
            hasher.combine(card.presence)
            hasher.combine(card.chip?.name)
            hasher.combine(card.chip?.effort)
        case .saved(let card):
            hasher.combine(card.title)
            hasher.combine(card.detail)
            hasher.combine(card.unread)
        case .project(let card):
            hasher.combine(card.name)
            hasher.combine(card.profileName)
            hasher.combine(card.backend)
            hasher.combine(card.chatCount)
        case .recent(let card):
            hasher.combine(card.title)
            hasher.combine(card.detail)
            hasher.combine(card.unread)
            hasher.combine(card.chip?.name)
            hasher.combine(card.chip?.effort)
        case .usage(let card):
            hasher.combine(card.quota)
            hasher.combine(QuotaCardCell.countdown(card.quota))
        case .placeholder(let index), .usagePlaceholder(let index):
            hasher.combine(index)
        }
        return hasher.finalize()
    }
}

/// One thing that happened while the app was away, as a way back into the chat
/// it happened in. Blocking first, then by when — the same order the desktops
/// put them in, because it is the order they matter in.
final class MissedActivityCell: GlassCardCell {
    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private let chevron = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        iconView.contentMode = .scaleAspectFit
        iconView.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = Theme.Ramp.font(.cardTitle)
        titleLabel.textColor = Theme.Color.label
        titleLabel.numberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.font = Theme.Ramp.font(.panelFootnote)
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
            iconView.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: Theme.Spacing.m),
            iconView.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 22),

            titleLabel.topAnchor.constraint(
                equalTo: contentView.topAnchor, constant: Theme.Spacing.s + 2),
            titleLabel.leadingAnchor.constraint(
                equalTo: iconView.trailingAnchor, constant: Theme.Spacing.m),
            titleLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: chevron.leadingAnchor, constant: -Theme.Spacing.s),

            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: chevron.leadingAnchor, constant: -Theme.Spacing.s),
            detailLabel.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor, constant: -(Theme.Spacing.s + 2)),

            chevron.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.m),
            chevron.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(_ item: MissedActivity) {
        let face = item.reason.face
        iconView.image = UIImage(
            systemName: face.symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold))
        iconView.tintColor = face.tone.color
        titleLabel.text = item.title
        detailLabel.text =
            "\(item.kindLabel) · \(StatusFacts.age(Date().timeIntervalSince(item.at)))"
        accessibilityLabel = "\(item.title). \(item.kindLabel)."
        isAccessibilityElement = true
        accessibilityTraits = .button
    }
}

/// A bookmarked conversation on Home. Reads from the saved snapshot rather than
/// the live listing, so the section survives a server being unreachable — which
/// is most of the reason to bookmark a chat in the first place.
struct SavedCard: Hashable {
    let chat: SavedChat
    let title: String
    let detail: String
    let pieces: [(text: String, color: UIColor)]
    let unread: Bool

    init(chat: SavedChat, unread: Bool) {
        self.chat = chat
        self.unread = unread
        self.title = chat.displayTitle
        var pieces: [(text: String, color: UIColor)] = []
        if let project = chat.projectName {
            pieces.append((project, Theme.Color.secondaryLabel))
        }
        pieces.append((chat.profileName, Theme.Color.tertiaryLabel))
        pieces.append(
            (chat.updatedAt.formatted(.relative(presentation: .named)), Theme.Color.tertiaryLabel))
        self.pieces = pieces
        self.detail = pieces.map(\.text).joined(separator: " · ")
    }

    static func == (lhs: SavedCard, rhs: SavedCard) -> Bool {
        lhs.chat == rhs.chat && lhs.detail == rhs.detail && lhs.unread == rhs.unread
    }

    func hash(into hasher: inout Hasher) { hasher.combine(chat) }
}

struct LiveCard: Hashable {
    enum Presence {
        case working, needsInput, syncing
    }

    let entry: SessionEntry
    let title: String
    let detail: String
    let pieces: [(text: String, color: UIColor)]
    let age: String
    let presence: Presence
    let chip: ModelChip?

    /// `activity` is what the agent is doing this second, known only for turns
    /// this device is streaming; it wears the accent and displaces the static
    /// model/server line because "Running Edit" is the more useful thing to see
    /// on a live card. An idle line leads with the project a step up from the
    /// server, the same read the chat list gives.
    init(entry: SessionEntry, presence: Presence, activity: String?) {
        self.entry = entry
        self.presence = presence
        let trimmed = entry.session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title =
            AgentSession.isPlaceholderTitle(trimmed)
            ? String(localized: "New conversation") : trimmed
        self.age = compactAge(entry.session.updatedAt)
        let project = entry.session.directory.map { ($0 as NSString).lastPathComponent }
        var pieces: [(text: String, color: UIColor)] = []
        if let project { pieces.append((project, Theme.Color.secondaryLabel)) }
        if let doing = activity ?? Self.agentActivity(entry.session) {
            pieces.append((doing, Theme.Color.accent))
        } else {
            pieces.append((entry.profileName, Theme.Color.tertiaryLabel))
        }
        self.pieces = pieces
        self.detail = pieces.map(\.text).joined(separator: " · ")
        self.chip = ModelBadge.chip(for: entry)
    }

    /// What a session that handed its turn to agents is doing, for the card that
    /// would otherwise repeat the model and server while the real work happens
    /// somewhere the transcript doesn't show.
    private static func agentActivity(_ session: AgentSession) -> String? {
        guard let count = session.activeAgents, count > 0 else { return nil }
        if count == 1, let task = session.agentTask, !task.isEmpty {
            return String(localized: "Agent: \(task)")
        }
        return String(localized: "\(count) agents working")
    }

    static func == (lhs: LiveCard, rhs: LiveCard) -> Bool {
        lhs.entry == rhs.entry
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(entry)
    }
}

/// A live card's heartbeat: how long ago the session last moved, short enough
/// to sit beside the state pill.
private func compactAge(_ date: Date) -> String {
    let seconds = max(0, Int(Date().timeIntervalSince(date)))
    if seconds < 60 { return "\(seconds)s" }
    if seconds < 3600 { return "\(seconds / 60)m" }
    if seconds < 86400 { return "\(seconds / 3600)h" }
    return "\(seconds / 86400)d"
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
    let pieces: [(text: String, color: UIColor)]
    let unread: Bool
    let chip: ModelChip?

    init(entry: SessionEntry, unread: Bool) {
        self.entry = entry
        self.unread = unread
        let trimmed = entry.session.title.trimmingCharacters(in: .whitespacesAndNewlines)
        self.title =
            AgentSession.isPlaceholderTitle(trimmed)
            ? String(localized: "New conversation") : trimmed
        var pieces: [(text: String, color: UIColor)] = []
        if let directory = entry.session.directory {
            pieces.append(((directory as NSString).lastPathComponent, Theme.Color.secondaryLabel))
        }
        pieces.append((entry.profileName, Theme.Color.tertiaryLabel))
        pieces.append(
            (
                entry.session.updatedAt.formatted(.relative(presentation: .named)),
                Theme.Color.tertiaryLabel
            ))
        self.pieces = pieces
        self.detail = pieces.map(\.text).joined(separator: " · ")
        self.chip = ModelBadge.chip(for: entry)
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
    private let dot = ActivityBadgeView(pointSize: 9)
    private let stateLabel = UILabel()
    private let ageLabel = UILabel()
    private let titleLabel = UILabel()
    private let detailLabel = UILabel()
    private var presence: LiveCard.Presence?

    override init(frame: CGRect) {
        super.init(frame: frame)
        dot.translatesAutoresizingMaskIntoConstraints = false

        stateLabel.font = Theme.Ramp.font(.pill)
        stateLabel.translatesAutoresizingMaskIntoConstraints = false

        ageLabel.font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
        ageLabel.textColor = Theme.Color.tertiaryLabel
        ageLabel.textAlignment = .right
        ageLabel.translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = Theme.Ramp.font(.cardTitle)
        titleLabel.textColor = Theme.Color.label
        titleLabel.numberOfLines = 2
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.font = Theme.Ramp.font(.panelFootnote)
        detailLabel.textColor = Theme.Color.secondaryLabel
        detailLabel.numberOfLines = 1
        detailLabel.translatesAutoresizingMaskIntoConstraints = false

        [dot, stateLabel, ageLabel, titleLabel, detailLabel].forEach(contentView.addSubview)
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Spacing.m),
            dot.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Spacing.m + 2),
            dot.widthAnchor.constraint(equalToConstant: 14),
            dot.heightAnchor.constraint(equalToConstant: 14),
            stateLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: Theme.Spacing.xs),
            stateLabel.centerYAnchor.constraint(equalTo: dot.centerYAnchor),
            stateLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: ageLabel.leadingAnchor, constant: -Theme.Spacing.xs),
            ageLabel.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.m),
            ageLabel.centerYAnchor.constraint(equalTo: dot.centerYAnchor),

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
        detailLabel.attributedText = ModelChipText.line(
            chip: card.chip, pieces: card.pieces,
            size: Theme.Ramp.font(.panelFootnote).pointSize)
        ageLabel.text = card.age
        let activity: ActivityKind =
            switch card.presence {
            case .needsInput: .needsApproval
            case .working: .working
            case .syncing: .connecting
            }
        let state: String =
            switch card.presence {
            case .needsInput: String(localized: "NEEDS YOU")
            case .working: String(localized: "LIVE")
            case .syncing: String(localized: "SYNCING")
            }
        dot.activity = activity
        applyPresence(
            color: activity.icon.tone.color, state: state,
            animated: presence != nil && presence != card.presence)
        presence = card.presence
        accessibilityLabel = String(
            localized: "\(state): \(card.title), \(card.detail), \(card.age) ago")
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        presence = nil
        dot.prepareForReuse()
    }

    /// A card that settles from SYNCING to LIVE, or lights up as NEEDS YOU,
    /// dissolves between the two rather than swapping mid-glance.
    private func applyPresence(color: UIColor, state: String, animated: Bool) {
        let apply = { [stateLabel] in
            stateLabel.textColor = color
            stateLabel.text = state
        }
        guard animated else {
            apply()
            return
        }
        UIView.transition(
            with: contentView, duration: 0.25, options: [.transitionCrossDissolve, .allowUserInteraction],
            animations: apply)
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

        nameLabel.font = Theme.Ramp.font(.cardTitle)
        nameLabel.textColor = Theme.Color.label
        nameLabel.numberOfLines = 1
        nameLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.font = Theme.Ramp.font(.panelFootnote)
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
        let detail =
            String(localized: "\(card.chatCount) chats") + " · \(card.profileName)"
        detailLabel.text = detail
        accessibilityLabel = String(localized: "Project \(card.name), \(detail)")
        accessibilityHint = String(localized: "Aims the composer at this project")
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

        titleLabel.font = Theme.Ramp.font(.cardTitle)
        titleLabel.textColor = Theme.Color.label
        titleLabel.numberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.font = Theme.Ramp.font(.panelFootnote)
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
        titleLabel.text = String(localized: "\(card.name) is unreachable")
        detailLabel.text = String(
            localized: "Check the server or Tailscale, then pull to refresh.")
        accessibilityLabel = String(localized: "\(card.name) is unreachable")
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
        unreadBadge.translatesAutoresizingMaskIntoConstraints = false
        paintBadgeRing()
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeIdentityTrait.self]) {
            (view: Self, _) in view.paintBadgeRing()
        }

        titleLabel.textColor = Theme.Color.label
        titleLabel.numberOfLines = 1
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        detailLabel.font = Theme.Ramp.font(.panelFootnote)
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

    /// The dot's ring is the list's own background punched out around it, and a `CGColor` keeps
    /// whichever colour that was when it was read — so it is repainted rather than merely set.
    private func paintBadgeRing() {
        unreadBadge.layer.borderColor =
            Theme.Color.groupedBackground.resolvedColor(with: traitCollection).cgColor
    }

    func configure(_ card: RecentCard) {
        apply(
            symbol: card.entry.backendType.symbolName,
            tint: card.entry.backendType.brandColor,
            title: card.title, detail: card.detail, pieces: card.pieces, unread: card.unread,
            badge: nil, chip: card.chip)
    }

    func configure(_ card: SavedCard) {
        apply(
            symbol: card.chat.backend.symbolName,
            tint: card.chat.backend.brandColor,
            title: card.title, detail: card.detail, pieces: card.pieces, unread: card.unread,
            badge: "bookmark.fill")
    }

    private func apply(
        symbol: String, tint: UIColor, title: String, detail: String,
        pieces: [(text: String, color: UIColor)], unread: Bool,
        badge: String?, chip: ModelChip? = nil
    ) {
        iconView.image = UIImage(systemName: symbol)?
            .withTintColor(tint, renderingMode: .alwaysOriginal)
        unreadBadge.isHidden = !unread
        titleLabel.font = unread
            ? Theme.Ramp.font(.cardTitle)
            : Theme.Ramp.font(.panelLabel)
        titleLabel.text = title
        detailLabel.attributedText = ModelChipText.line(
            chip: chip, pieces: pieces,
            size: Theme.Ramp.font(.panelFootnote).pointSize)
        if let badge, let image = UIImage(
            systemName: badge,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        {
            chevron.image = image
            chevron.tintColor = Theme.Color.warning
        } else {
            chevron.image = UIImage(
                systemName: "chevron.right",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
            chevron.tintColor = Theme.Color.tertiaryLabel
        }
        accessibilityLabel =
            unread ? String(localized: "Unread: \(title), \(detail)") : "\(title), \(detail)"
        isAccessibilityElement = true
        accessibilityTraits = .button
    }
}

/// Skeleton stand-in for a `RecentSessionCell` while the first-ever session
/// fetch is in flight (no cached list yet). Mirrors that cell's geometry so
/// the swap to real rows doesn't shift the layout.
/// A card standing in for one that is still loading: the real card's shape,
/// blocked out and pulsing. Reserving the space up front is what keeps arriving
/// data from shoving the list around.
class ShimmerCardCell: GlassCardCell {
    /// A blocked-out stand-in for one piece of the real card's content.
    func block(cornerRadius: CGFloat) -> UIView {
        let view = UIView()
        view.backgroundColor = Theme.Color.separator
        view.layer.cornerRadius = cornerRadius
        view.layer.cornerCurve = .continuous
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

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

final class RecentPlaceholderCell: ShimmerCardCell {
    private lazy var iconBlock = block(cornerRadius: 10)
    private lazy var titleBar = block(cornerRadius: 7)
    private lazy var detailBar = block(cornerRadius: 5)

    override init(frame: CGRect) {
        super.init(frame: frame)
        [iconBlock, titleBar, detailBar].forEach(contentView.addSubview)
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
        accessibilityLabel = String(localized: "Loading recent chats")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

/// Mirrors ``QuotaCardCell``'s title and three gauge rows so the usage section
/// holds its final height from the first frame — the live quota fetch and the
/// opencode scan land seconds apart, and each used to shove the list.
final class QuotaPlaceholderCell: ShimmerCardCell {
    private lazy var titleBar = block(cornerRadius: 7)

    override init(frame: CGRect) {
        super.init(frame: frame)
        let rows = UIStackView(arrangedSubviews: (0..<3).map { _ in gaugeRow() })
        rows.axis = .vertical
        rows.spacing = Theme.Spacing.s
        rows.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(titleBar)
        contentView.addSubview(rows)

        NSLayoutConstraint.activate([
            titleBar.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Spacing.m + 2),
            titleBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Spacing.m),
            titleBar.widthAnchor.constraint(equalTo: contentView.widthAnchor, multiplier: 0.35),
            titleBar.heightAnchor.constraint(equalToConstant: 14),

            rows.topAnchor.constraint(equalTo: titleBar.bottomAnchor, constant: Theme.Spacing.m),
            rows.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Spacing.m),
            rows.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.m),
            rows.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Theme.Spacing.m),
        ])

        isAccessibilityElement = true
        accessibilityLabel = String(localized: "Loading usage")
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func gaugeRow() -> UIView {
        let label = block(cornerRadius: 4)
        label.heightAnchor.constraint(equalToConstant: 9).isActive = true
        label.widthAnchor.constraint(equalToConstant: 64).isActive = true

        let labelRow = UIStackView(arrangedSubviews: [label, UIView()])
        labelRow.axis = .horizontal

        let track = block(cornerRadius: 3)
        track.heightAnchor.constraint(equalToConstant: 6).isActive = true

        let column = UIStackView(arrangedSubviews: [labelRow, track])
        column.axis = .vertical
        column.spacing = 4
        return column
    }
}

final class QuotaCardCell: GlassCardCell {
    private let providerLabel = UILabel()
    private let countdownLabel = UILabel()
    private let gaugeStack = UIStackView()
    private let gaugeRows = (0..<3).map { _ in GaugeRow() }

    override init(frame: CGRect) {
        super.init(frame: frame)
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

final class HomeHeaderView: UICollectionReusableView {
    private let titleLabel = UILabel()
    private let actionButton = UIButton(type: .system)
    private var onAction: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        titleLabel.font = Theme.Ramp.font(.rowTitleStrong)
        titleLabel.textColor = Theme.Color.secondaryLabel
        titleLabel.translatesAutoresizingMaskIntoConstraints = false

        actionButton.titleLabel?.font = Theme.Ramp.font(.panelDetail)
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
