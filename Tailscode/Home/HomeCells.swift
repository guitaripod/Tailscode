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
            hasher.combine(card.reading)
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

/// Every server that did not answer, as one card. A card per machine made a fleet's bad morning
/// into a screenful of the same sentence; the machines are named once, with the side that is the
/// likelier cause and the one fix to try first.
struct ServerAlertCard: Hashable {
    let reading: ReachReading

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
    var onAction: ((ReachReading.Action) -> Void)?
    var onHelp: (() -> Void)?

    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let leadLabel = UILabel()
    private let primaryButton = UIButton(type: .system)
    private let helpButton = UIButton(type: .system)
    private let buttons = UIStackView()
    private var primary: ReachReading.Action = .retry

    override init(frame: CGRect) {
        super.init(frame: frame)
        surface.backgroundColor = UIColor { traits in
            Theme.Color.groupedSurface.resolvedColor(with: traits)
                .mixed(with: Theme.Color.danger.resolvedColor(with: traits), fraction: 0.1)
        }
        surface.layer.borderWidth = 1
        surface.layer.borderColor = Theme.Color.danger.withAlphaComponent(0.4).cgColor
        iconView.tintColor = Theme.Color.danger
        iconView.contentMode = .scaleAspectFit
        iconView.setContentHuggingPriority(.required, for: .horizontal)
        iconView.setContentCompressionResistancePriority(.required, for: .horizontal)

        titleLabel.font = Theme.Ramp.font(.panelLabel)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = Theme.Color.label
        titleLabel.numberOfLines = 0

        leadLabel.font = Theme.Ramp.font(.panelFootnote)
        leadLabel.adjustsFontForContentSizeCategory = true
        leadLabel.textColor = Theme.Color.secondaryLabel
        leadLabel.numberOfLines = 0

        primaryButton.configuration = Self.capsule(prominent: true)
        primaryButton.addAction(
            UIAction { [weak self] _ in
                guard let self else { return }
                Theme.Haptics.tap()
                self.onAction?(self.primary)
            }, for: .touchUpInside)
        var help = Self.capsule(prominent: false)
        help.title = String(localized: "What to try")
        helpButton.configuration = help
        helpButton.addAction(
            UIAction { [weak self] _ in
                Theme.Haptics.tap()
                self?.onHelp?()
            }, for: .touchUpInside)

        buttons.addArrangedSubview(primaryButton)
        buttons.addArrangedSubview(helpButton)
        buttons.spacing = Theme.Spacing.s
        buttons.alignment = .leading
        stackButtons()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (cell: ServerAlertCell, _) in cell.stackButtons()
        }

        let header = UIStackView(arrangedSubviews: [iconView, titleLabel])
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = Theme.Spacing.s

        let column = UIStackView(arrangedSubviews: [header, leadLabel, buttons])
        column.axis = .vertical
        column.alignment = .fill
        column.spacing = Theme.Spacing.s
        column.setCustomSpacing(Theme.Spacing.m, after: leadLabel)
        column.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Spacing.m),
            column.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Theme.Spacing.m),
            column.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Spacing.m),
            column.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.m),
        ])
        isAccessibilityElement = false
        accessibilityElements = [titleLabel, leadLabel, primaryButton, helpButton]
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(_ card: ServerAlertCard) {
        let reading = card.reading
        primary = reading.primary
        iconView.image = UIImage(
            systemName: reading.symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold))
        titleLabel.text = reading.title
        leadLabel.text = reading.lead
        primaryButton.configuration?.title = ReachDoors.title(for: reading.primary)
        primaryButton.configuration?.image = UIImage(
            systemName: ReachDoors.symbol(for: reading.primary),
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
        helpButton.accessibilityHint = String(localized: "Shows every fix, in the order to try them.")
    }

    /// Side by side the two buttons share a line; at accessibility sizes they take a line each,
    /// because a label wrapped a letter at a time is no button at all.
    private func stackButtons() {
        let accessible = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        buttons.axis = accessible ? .vertical : .horizontal
    }

    private static func capsule(prominent: Bool) -> UIButton.Configuration {
        var config = prominent ? UIButton.Configuration.filled() : UIButton.Configuration.plain()
        config.baseBackgroundColor = Theme.Color.danger
        config.baseForegroundColor = prominent ? Theme.Color.onAccent : Theme.Color.danger
        config.cornerStyle = .capsule
        config.imagePadding = Theme.Spacing.xs
        if !prominent {
            config.background.strokeColor = Theme.Color.danger.withAlphaComponent(0.4)
            config.background.strokeWidth = 1
        }
        config.contentInsets = NSDirectionalEdgeInsets(
            top: 6, leading: Theme.Spacing.m, bottom: 6, trailing: Theme.Spacing.m)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            var out = $0
            out.font = Theme.Ramp.font(.chip)
            return out
        }
        return config
    }

    override var isHighlighted: Bool {
        get { false }
        set {}
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
