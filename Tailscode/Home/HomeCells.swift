import CodingAgentKit
import TailscodeCore
import UIKit

enum HomeSection: Hashable {
    case status, schedule, agentNews, shelfBar, masters, glance, alerts, demoNudge, proInvitation, asks, usage
    case needsYou, working, pinned, saved, recent

    var band: SessionSection? {
        switch self {
        case .needsYou: return .needsYou
        case .working: return .working
        case .pinned: return .pinned
        case .saved: return .saved
        case .recent: return .recent
        case .status, .schedule, .agentNews, .shelfBar, .masters, .glance, .alerts, .demoNudge, .proInvitation,
            .asks, .usage:
            return nil
        }
    }

    init(_ section: SessionSection) {
        switch section {
        case .needsYou: self = .needsYou
        case .working: self = .working
        case .pinned: self = .pinned
        case .saved: self = .saved
        case .recent: self = .recent
        }
    }
}

enum HomeItem: Hashable {
    case status(HomeStatusCard)
    case schedule(ScheduleLineCard)
    case agentNews(AgentNewsCard)
    case shelfBar(HomeShelfBarCard)
    case masters(MasterShelfCard)
    case glance(QuotaGlanceCard)
    case alert(ServerAlertCard)
    case demoNudge(DemoNudgeCard)
    case proInvitation(ProInvitationCard)
    case chat(ChatRowCard)
    case ask(AskCard)
    case quota(QuotaCard)
    case saved(SavedCard)
    case more(HomeMoreCard)
    case placeholder(Int)
}

extension HomeItem {
    /// Everything the cell for this item would draw, folded to one value.
    ///
    /// Identity answers which card a row *is* — deliberately just the session or the bookmark, so a
    /// refresh reconfigures a row rather than animating it away and back. It says nothing about
    /// whether anything on the row moved, and the board is rebuilt by everything that moves
    /// anywhere: without this, one agent's step reconfigured every visible card, and each of those
    /// re-measures itself. The ages that tick on their own are folded as the words they render as,
    /// so a row redraws exactly when its own reading changes and not once a second before it.
    var contentSignature: Int {
        var hasher = Hasher()
        switch self {
        case .status(let card):
            hasher.combine(card.status.sentence)
            hasher.combine(card.status.detail)
            hasher.combine(String(describing: card.status.tone))
        case .glance(let card):
            hasher.combine(card.glance.lines.count)
            for line in card.glance.lines {
                hasher.combine(line.text)
                hasher.combine(line.trailing)
                hasher.combine(line.fraction)
                hasher.combine(line.tone.rawValue)
                hasher.combine(line.kind.rawValue)
                hasher.combine(line.paceNews)
            }
        case .alert(let card):
            hasher.combine(card.names)
        case .demoNudge:
            break
        case .schedule(let card):
            hasher.combine(card.line)
        case .agentNews(let card):
            hasher.combine(card.title)
            hasher.combine(card.detail)
        case .shelfBar(let card):
            hasher.combine(card.peek)
            hasher.combine(card.masters.map { MasterShelf.signature($0) })
            for line in card.glance?.lines ?? [] {
                hasher.combine(line.short ?? line.text)
                hasher.combine(line.fraction)
                hasher.combine(line.tone.rawValue)
                hasher.combine(line.kind.rawValue)
            }
        case .masters(let card):
            hasher.combine(MasterShelf.signature(card.board))
        case .proInvitation(let card):
            hasher.combine(card.price)
        case .chat(let card):
            hasher.combine(card.facts.signature)
            hasher.combine(card.band)
        case .ask(let card):
            hasher.combine(card.facts.signature)
        case .quota(let card):
            hasher.combine(card.quota)
            hasher.combine(QuotaCardCell.countdown(card.quota))
        case .saved(let card):
            hasher.combine(card.facts.signature)
        case .more(let card):
            hasher.combine(card.foot)
        case .placeholder(let index):
            hasher.combine(index)
        }
        return hasher.finalize()
    }
}

/// The sentence at the head of Home and the line under it. There is only ever one, so its
/// identity is nothing at all and everything it says arrives through reconfigure.
struct HomeStatusCard: Hashable {
    let status: HomeStatus

    static func == (lhs: HomeStatusCard, rhs: HomeStatusCard) -> Bool { true }
    func hash(into hasher: inout Hasher) {}
}

/// The quota strip as Home draws it once its button is pressed: every line it holds.
struct QuotaGlanceCard: Hashable {
    let glance: QuotaGlance

    static func == (lhs: QuotaGlanceCard, rhs: QuotaGlanceCard) -> Bool { true }
    func hash(into hasher: inout Hasher) {}
}

/// A conversation in a band. Identity is the pair every store here keys on, so a chat that
/// changes band moves rather than being deleted and inserted, and everything else it says is
/// cell content.
struct ChatRowCard: Hashable {
    let row: SessionRowModel
    let facts: ChatRowFacts
    let band: SessionSection

    var entry: SessionEntry { row.entry }

    static func == (lhs: ChatRowCard, rhs: ChatRowCard) -> Bool {
        lhs.entry.profileID == rhs.entry.profileID && lhs.entry.session.id == rhs.entry.session.id
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(entry.profileID)
        hasher.combine(entry.session.id)
    }
}

/// The foot of a band that holds more than it shows, or that has been opened past its limit.
struct HomeMoreCard: Hashable {
    let band: SessionSection
    let foot: HomeReach.Foot

    static func == (lhs: HomeMoreCard, rhs: HomeMoreCard) -> Bool { lhs.band == rhs.band }
    func hash(into hasher: inout Hasher) { hasher.combine(band) }
}

/// A bookmarked conversation on Home. Reads from the saved snapshot rather than
/// the live listing, so the section survives a server being unreachable — which
/// is most of the reason to bookmark a chat in the first place.
struct SavedCard: Hashable {
    let chat: SavedChat
    let facts: ChatRowFacts

    init(chat: SavedChat, unread: Bool) {
        self.chat = chat
        self.facts = ChatRowFacts(saved: chat, unread: unread)
    }

    static func == (lhs: SavedCard, rhs: SavedCard) -> Bool {
        lhs.chat == rhs.chat && lhs.facts == rhs.facts
    }

    func hash(into hasher: inout Hasher) { hasher.combine(chat) }
}

/// Every server that did not answer, as one line. A card per machine made a fleet's bad morning
/// into a screenful of the same sentence; the machines are named once and the question — try
/// again — is asked once.
struct ServerAlertCard: Hashable {
    let names: [String]

    static func == (lhs: ServerAlertCard, rhs: ServerAlertCard) -> Bool { true }
    func hash(into hasher: inout Hasher) {}
}

/// Shared chrome for every Home card that is not a chat row: an opaque grouped surface with
/// continuous corners that all content sits on. Home's cards are the content layer, so they are
/// never glass — glass is for what floats over them.
class ContentCardCell: UICollectionViewCell {
    let surface = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        surface.backgroundColor = Theme.Color.groupedSurface
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

final class ServerAlertCell: ContentCardCell {
    var onRetry: (() -> Void)?

    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let retryButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        surface.backgroundColor = UIColor { traits in
            Theme.Color.groupedSurface.resolvedColor(with: traits)
                .mixed(with: Theme.Color.danger.resolvedColor(with: traits), fraction: 0.1)
        }
        surface.layer.borderWidth = 1
        surface.layer.borderColor = Theme.Color.danger.withAlphaComponent(0.4).cgColor
        iconView.image = UIImage(
            systemName: "wifi.slash",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        iconView.tintColor = Theme.Color.danger
        iconView.contentMode = .scaleAspectFit
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.font = Theme.Ramp.font(.panelLabel)
        titleLabel.textColor = Theme.Color.label
        titleLabel.numberOfLines = 0

        var config = UIButton.Configuration.plain()
        config.title = String(localized: "Retry")
        config.baseForegroundColor = Theme.Color.danger
        config.cornerStyle = .capsule
        config.background.strokeColor = Theme.Color.danger.withAlphaComponent(0.4)
        config.background.strokeWidth = 1
        config.contentInsets = NSDirectionalEdgeInsets(
            top: 6, leading: Theme.Spacing.m, bottom: 6, trailing: Theme.Spacing.m)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            var out = $0
            out.font = Theme.Ramp.font(.chip)
            return out
        }
        retryButton.configuration = config
        retryButton.setContentHuggingPriority(.required, for: .horizontal)
        retryButton.addAction(
            UIAction { [weak self] _ in
                Theme.Haptics.tap()
                self?.onRetry?()
            }, for: .touchUpInside)

        let row = UIStackView(arrangedSubviews: [iconView, titleLabel, retryButton])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Theme.Spacing.m
        row.isLayoutMarginsRelativeArrangement = true
        row.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: Theme.Spacing.s, leading: Theme.Spacing.m, bottom: Theme.Spacing.s,
            trailing: Theme.Spacing.s)
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: contentView.topAnchor),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(_ card: ServerAlertCard) {
        let words =
            card.names.count == 1
            ? String(localized: "\(card.names[0]) is unreachable")
            : String(localized: "\(card.names.count) servers are unreachable")
        titleLabel.text = words
        isAccessibilityElement = false
        accessibilityElements = [titleLabel, retryButton]
        retryButton.accessibilityHint = String(
            localized: "Check the server or Tailscale, then try again.")
    }
}

/// The one demo card, keyed by nothing but its own existence.
struct DemoNudgeCard: Hashable {
    static func == (lhs: DemoNudgeCard, rhs: DemoNudgeCard) -> Bool { true }
    func hash(into hasher: inout Hasher) {}
}

final class DemoNudgeCell: ContentCardCell {
    var onSetUp: (() -> Void)?
    var onNotNow: (() -> Void)?

    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let bodyLabel = UILabel()
    private let setUpButton = PrimaryButton(title: DemoNudge.primaryAction)
    private let notNowButton = UIButton(type: .system)
    private let buttons = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        iconView.image = UIImage(
            systemName: "laptopcomputer.and.iphone",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold))
        iconView.tintColor = Theme.Color.accent
        iconView.contentMode = .scaleAspectFit
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.font = Theme.Ramp.font(.cardTitle)
        titleLabel.textColor = Theme.Color.label
        titleLabel.numberOfLines = 0
        titleLabel.text = DemoNudge.title

        bodyLabel.font = Theme.Ramp.font(.panelFootnote)
        bodyLabel.textColor = Theme.Color.secondaryLabel
        bodyLabel.numberOfLines = 0
        bodyLabel.text = DemoNudge.body

        var notNow = UIButton.Configuration.gray()
        notNow.title = DemoNudge.secondaryAction
        notNow.baseForegroundColor = Theme.Color.secondaryLabel
        notNow.cornerStyle = .large
        notNow.buttonSize = .large
        notNowButton.configuration = notNow

        setUpButton.addAction(UIAction { [weak self] _ in self?.onSetUp?() }, for: .touchUpInside)
        notNowButton.addAction(UIAction { [weak self] _ in self?.onNotNow?() }, for: .touchUpInside)

        let header = UIStackView(arrangedSubviews: [iconView, titleLabel])
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = Theme.Spacing.s

        buttons.addArrangedSubview(setUpButton)
        buttons.addArrangedSubview(notNowButton)
        buttons.spacing = Theme.Spacing.s
        stackButtons()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (cell: DemoNudgeCell, _) in cell.stackButtons()
        }

        let column = UIStackView(arrangedSubviews: [header, bodyLabel, buttons])
        column.axis = .vertical
        column.spacing = Theme.Spacing.s
        column.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Spacing.m),
            column.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Spacing.m),
            column.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.m),
            column.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Theme.Spacing.m),
        ])
        isAccessibilityElement = false
        accessibilityElements = [titleLabel, bodyLabel, setUpButton, notNowButton]
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Side by side the two buttons share a line; at accessibility sizes a label would be wrapped a
    /// letter at a time to make that true, so they take a line each instead.
    private func stackButtons() {
        let accessible = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        buttons.axis = accessible ? .vertical : .horizontal
        buttons.distribution = accessible ? .fill : .fillProportionally
    }

    override var isHighlighted: Bool {
        get { false }
        set {}
    }
}

/// The one invitation to Pro, keyed by nothing but its own existence: what it gives, the person's turns and the price
/// are content, so a store answer reconfigures the card rather than replacing it.
struct ProInvitationCard: Hashable {
    let gift: ProInvitation.Gift
    let price: String?
    let facts: ProPersonalDetails.Facts

    static func == (lhs: ProInvitationCard, rhs: ProInvitationCard) -> Bool { true }
    func hash(into hasher: inout Hasher) {}
}

final class ProInvitationCell: ContentCardCell {
    var onAccept: (() -> Void)?
    var onNotNow: (() -> Void)?

    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let bodyLabel = UILabel()
    private let acceptButton = PrimaryButton(title: ProOffer.title)
    private let notNowButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        iconView.image = UIImage(
            systemName: "sparkles",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold))
        iconView.tintColor = Theme.Color.accent
        iconView.contentMode = .scaleAspectFit
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.font = Theme.Ramp.font(.cardTitle)
        titleLabel.textColor = Theme.Color.label
        titleLabel.numberOfLines = 0

        bodyLabel.font = Theme.Ramp.font(.panelFootnote)
        bodyLabel.textColor = Theme.Color.secondaryLabel
        bodyLabel.numberOfLines = 0

        var notNow = UIButton.Configuration.gray()
        notNow.title = ProInvitation.secondaryAction
        notNow.baseForegroundColor = Theme.Color.secondaryLabel
        notNow.cornerStyle = .large
        notNow.buttonSize = .large
        notNowButton.configuration = notNow

        acceptButton.addAction(UIAction { [weak self] _ in self?.onAccept?() }, for: .touchUpInside)
        notNowButton.addAction(UIAction { [weak self] _ in self?.onNotNow?() }, for: .touchUpInside)

        let header = UIStackView(arrangedSubviews: [iconView, titleLabel])
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = Theme.Spacing.s

        notNowButton.setContentHuggingPriority(.required, for: .horizontal)
        notNowButton.setContentCompressionResistancePriority(.required, for: .horizontal)
        let buttons = UIStackView(arrangedSubviews: [acceptButton, notNowButton])
        buttons.axis = .horizontal
        buttons.spacing = Theme.Spacing.s
        buttons.distribution = .fill

        let column = UIStackView(arrangedSubviews: [header, bodyLabel, buttons])
        column.axis = .vertical
        column.spacing = Theme.Spacing.s
        column.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Spacing.m),
            column.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Spacing.m),
            column.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.m),
            column.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Theme.Spacing.m),
        ])
        isAccessibilityElement = false
        accessibilityElements = [titleLabel, bodyLabel, acceptButton, notNowButton]
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        get { false }
        set {}
    }

    func configure(_ card: ProInvitationCard) {
        titleLabel.text = ProInvitation.title(card.facts)
        bodyLabel.text = ProInvitation.body(card.gift)
        acceptButton.setTitle(ProInvitation.primaryAction(card.gift, price: card.price))
    }
}


/// Skeleton stand-in for a `RecentSessionCell` while the first-ever session
/// fetch is in flight (no cached list yet). Mirrors that cell's geometry so
/// the swap to real rows doesn't shift the layout.
/// A card standing in for one that is still loading: the real card's shape,
/// blocked out and pulsing. Reserving the space up front is what keeps arriving
/// data from shoving the list around.
class ShimmerCardCell: ContentCardCell {
    override init(frame: CGRect) {
        super.init(frame: frame)
        NotificationCenter.default.addObserver(
            self, selector: #selector(retune),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
    }

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
        pulse()
    }

    /// Reads the reader's mind again when they change it mid-wait, because a placeholder stands
    /// for exactly as long as the wait does and one that only asked at the moment it appeared
    /// would go on pulsing under a setting that has already changed. A card that is not on screen
    /// is left alone: it asks for itself the moment it comes back.
    @objc private func retune() {
        guard window != nil else { return }
        pulse()
    }

    /// The stand-in's own breath, so a card that is waiting reads as waiting rather than as one
    /// that arrived empty. Whether it moves at all is the vocabulary's to say.
    private func pulse() {
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.45
        pulse.duration = 0.8
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        contentView.layer.setRepeatingMotion(pulse, forKey: "shimmer")
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

final class HomeStatusCell: UICollectionViewCell {
    private let light = ActivityBadgeView(pointSize: 12)
    private let lead = UIStackView()
    private let sentenceLabel = UILabel()
    private let detailLabel = UILabel()
    private let rangeLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        sentenceLabel.font = Theme.Ramp.font(.statusSentence)
        sentenceLabel.textColor = Theme.Color.label
        sentenceLabel.numberOfLines = 0
        sentenceLabel.adjustsFontForContentSizeCategory = true

        detailLabel.font = Theme.Ramp.font(.statusLine)
        detailLabel.textColor = Theme.Color.secondaryLabel
        detailLabel.numberOfLines = 0
        detailLabel.adjustsFontForContentSizeCategory = true

        rangeLabel.font = Theme.Ramp.font(.statusLine)
        rangeLabel.textColor = Theme.Color.warning
        rangeLabel.numberOfLines = 0
        rangeLabel.adjustsFontForContentSizeCategory = true
        rangeLabel.isHidden = true

        light.setContentHuggingPriority(.required, for: .horizontal)
        light.translatesAutoresizingMaskIntoConstraints = false

        [light, sentenceLabel].forEach(lead.addArrangedSubview)
        lead.axis = .horizontal
        lead.alignment = .center
        lead.spacing = Theme.Spacing.s + 2

        let column = UIStackView(arrangedSubviews: [lead, detailLabel, rangeLabel])
        column.axis = .vertical
        column.spacing = 2
        column.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(column)
        contentView.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: Theme.Spacing.s, leading: Theme.Spacing.xs, bottom: Theme.Spacing.xs,
            trailing: Theme.Spacing.xs)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: contentView.layoutMarginsGuide.topAnchor),
            column.bottomAnchor.constraint(equalTo: contentView.layoutMarginsGuide.bottomAnchor),
            column.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor),
            column.trailingAnchor.constraint(
                equalTo: contentView.layoutMarginsGuide.trailingAnchor),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .header
        applySentenceFont()
        registerForTraitChanges([UITraitVerticalSizeClass.self, UITraitPreferredContentSizeCategory.self]) {
            (cell: HomeStatusCell, _) in
            cell.applySentenceFont()
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// A short window — a phone on its side — gives the sentence a smaller voice, because at that
    /// height the sentence at its full size would be the screen.
    private func applySentenceFont() {
        sentenceLabel.font = Theme.Ramp.font(
            traitCollection.verticalSizeClass == .compact ? .headline : .statusSentence)
        lead.alignment =
            traitCollection.preferredContentSizeCategory.isAccessibilityCategory ? .top : .center
    }

    func configure(_ card: HomeStatusCard) {
        let status = card.status
        sentenceLabel.text = status.sentence
        detailLabel.text = status.detail
        detailLabel.isHidden = status.detail.isEmpty
        rangeLabel.text = status.range
        rangeLabel.isHidden = status.range == nil
        light.show(Self.icon(for: status.tone), spoken: nil)
        accessibilityLabel = status.spoken
    }

    private static func icon(for tone: ActivityTone) -> ActivityIcon {
        let motion: ActivityMotion
        switch tone {
        case .attention: motion = ActivityKind.needsApproval.icon.motion
        case .live: motion = ActivityKind.working.icon.motion
        case .danger, .quiet: motion = .still
        }
        return ActivityIcon(symbol: "circle.fill", glyph: "●", tone: tone, motion: motion)
    }
}

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
