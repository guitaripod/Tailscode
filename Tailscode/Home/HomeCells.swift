import CodingAgentKit
import TailscodeCore
import UIKit

enum HomeSection: Hashable {
    case status, glance, alerts, demoNudge, supporter, asks, usage
    case needsYou, working, pinned, saved, recent

    var band: SessionSection? {
        switch self {
        case .needsYou: return .needsYou
        case .working: return .working
        case .pinned: return .pinned
        case .saved: return .saved
        case .recent: return .recent
        case .status, .glance, .alerts, .demoNudge, .supporter, .asks, .usage: return nil
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
    case glance(QuotaGlanceCard)
    case alert(ServerAlertCard)
    case demoNudge(DemoNudgeCard)
    case supporter(SupporterCard)
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
            }
        case .alert(let card):
            hasher.combine(card.names)
        case .demoNudge:
            break
        case .supporter(let card):
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
            hasher.combine(card.count)
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

/// The one line the quota strip would lead with, and how many lines it holds behind it.
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

/// The foot of a band that holds more than it shows.
struct HomeMoreCard: Hashable {
    let band: SessionSection
    let count: Int

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

/// The one supporter card, keyed by nothing but its own existence: the price is content, so a
/// store answer reconfigures the card rather than replacing it.
struct SupporterCard: Hashable {
    let price: String?

    static func == (lhs: SupporterCard, rhs: SupporterCard) -> Bool { true }
    func hash(into hasher: inout Hasher) {}
}

final class SupporterCell: ContentCardCell {
    var onUnlock: (() -> Void)?
    var onNotNow: (() -> Void)?

    private let iconView = UIImageView()
    private let titleLabel = UILabel()
    private let bodyLabel = UILabel()
    private let unlockButton = PrimaryButton(title: ProOffer.title)
    private let notNowButton = UIButton(type: .system)

    override init(frame: CGRect) {
        super.init(frame: frame)
        iconView.image = UIImage(
            systemName: "heart.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold))
        iconView.tintColor = Theme.Color.accent
        iconView.contentMode = .scaleAspectFit
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.font = Theme.Ramp.font(.cardTitle)
        titleLabel.textColor = Theme.Color.label
        titleLabel.numberOfLines = 0
        titleLabel.text = SupporterInvitation.title

        bodyLabel.font = Theme.Ramp.font(.panelFootnote)
        bodyLabel.textColor = Theme.Color.secondaryLabel
        bodyLabel.numberOfLines = 0
        bodyLabel.text = SupporterInvitation.body

        var notNow = UIButton.Configuration.gray()
        notNow.title = SupporterInvitation.secondaryAction
        notNow.baseForegroundColor = Theme.Color.secondaryLabel
        notNow.cornerStyle = .large
        notNow.buttonSize = .large
        notNowButton.configuration = notNow

        unlockButton.addAction(UIAction { [weak self] _ in self?.onUnlock?() }, for: .touchUpInside)
        notNowButton.addAction(UIAction { [weak self] _ in self?.onNotNow?() }, for: .touchUpInside)

        let header = UIStackView(arrangedSubviews: [iconView, titleLabel])
        header.axis = .horizontal
        header.alignment = .center
        header.spacing = Theme.Spacing.s

        let buttons = UIStackView(arrangedSubviews: [unlockButton, notNowButton])
        buttons.axis = .horizontal
        buttons.spacing = Theme.Spacing.s
        buttons.distribution = .fillProportionally

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
        accessibilityElements = [titleLabel, bodyLabel, unlockButton, notNowButton]
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        get { false }
        set {}
    }

    func configure(_ card: SupporterCard) {
        unlockButton.setTitle(SupporterInvitation.primaryAction(price: card.price))
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

/// The quota strip's first line as one capsule: the window that decides when the next send
/// unlocks, how full it is, and how many other lines stand behind it. It is a button into Usage,
/// not a piece of glass — it sits in the page, and the page is the content layer.
final class HomeGlanceCell: UICollectionViewCell {
    private let ring = MiniRingView()
    private let textLabel = UILabel()
    private let valueLabel = UILabel()
    private let moreLabel = UILabel()
    private let chevron = UIImageView()
    private let capsule = CapsuleView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        capsule.backgroundColor = Theme.Color.groupedSurface
        capsule.layer.cornerCurve = .continuous
        capsule.translatesAutoresizingMaskIntoConstraints = false
        capsule.isUserInteractionEnabled = false

        textLabel.font = Theme.Ramp.font(.gauge)
        textLabel.textColor = Theme.Color.label
        textLabel.lineBreakMode = .byTruncatingTail
        textLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        valueLabel.font = Theme.Ramp.font(.gauge)
        valueLabel.textColor = Theme.Color.label
        valueLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        moreLabel.font = Theme.Ramp.font(.gaugeCaption)
        moreLabel.textColor = Theme.Color.tertiaryLabel
        moreLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        chevron.image = UIImage(
            systemName: "chevron.right",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        chevron.tintColor = Theme.Color.tertiaryLabel
        chevron.setContentHuggingPriority(.required, for: .horizontal)

        ring.translatesAutoresizingMaskIntoConstraints = false
        ring.widthAnchor.constraint(equalToConstant: 20).isActive = true
        ring.heightAnchor.constraint(equalToConstant: 20).isActive = true

        let row = UIStackView(arrangedSubviews: [ring, textLabel, valueLabel, moreLabel, chevron])
        row.axis = .horizontal
        row.alignment = .center
        row.spacing = Theme.Spacing.s
        row.isLayoutMarginsRelativeArrangement = true
        row.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: Theme.Spacing.s, leading: Theme.Spacing.m, bottom: Theme.Spacing.s,
            trailing: Theme.Spacing.m)
        row.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(capsule)
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            capsule.topAnchor.constraint(equalTo: contentView.topAnchor),
            capsule.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            capsule.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            capsule.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            row.topAnchor.constraint(equalTo: contentView.topAnchor),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            row.heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
        ])
        answersPointer(cornerRadius: 22)
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(_ card: QuotaGlanceCard) {
        let lines = card.glance.lines
        guard let lead = lines.first else { return }
        textLabel.text = lead.text
        valueLabel.text = lead.trailing
        valueLabel.isHidden = lead.trailing.isEmpty
        let others = lines.count - 1
        moreLabel.text = others > 0 ? "+\(others)" : nil
        moreLabel.isHidden = others <= 0
        ring.fraction = lead.fraction
        ring.tint = Self.color(for: lead.tone)
        ring.isHidden = lead.fraction == nil
        accessibilityLabel = card.glance.tooltip.isEmpty
            ? lead.text : card.glance.tooltip.components(separatedBy: "\n").first ?? lead.text
        accessibilityValue = lead.trailing
        accessibilityHint = String(localized: "Opens usage")
    }

    private static func color(for tone: QuotaGlance.Tone) -> UIColor {
        switch tone {
        case .ok: return Theme.Color.accent
        case .warn: return Theme.Color.warning
        case .danger: return Theme.Color.danger
        case .balance: return Theme.Color.info
        case .quiet: return Theme.Color.tertiaryLabel
        }
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
        track.path = path.cgPath
        fill.path = path.cgPath
        fill.strokeEnd = CGFloat(min(max(fraction ?? 0, 0), 1))
    }
}

final class HomeHeaderView: UICollectionReusableView {
    private let titleLabel = UILabel()
    private let actionButton = UIButton(type: .system)
    private var onAction: (() -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        titleLabel.font = Theme.Ramp.font(.sectionLabel)
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
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.s),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Spacing.xs),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Spacing.xs),
            actionButton.trailingAnchor.constraint(
                equalTo: trailingAnchor, constant: -Theme.Spacing.s),
            actionButton.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(
        title: String, count: Int? = nil, needsYou: Bool = false, actionTitle: String? = nil,
        onAction: (() -> Void)? = nil
    ) {
        let color = needsYou ? Theme.Color.warning : Theme.Color.secondaryLabel
        let label = NSMutableAttributedString(
            string: title.uppercased(),
            attributes: [
                .font: Theme.Ramp.font(.sectionLabel), .foregroundColor: color,
                .kern: Typography.spec(.sectionLabel).tracking
                    * Theme.Ramp.font(.sectionLabel).pointSize,
            ])
        if let count, count > 0 {
            label.append(
                NSAttributedString(
                    string: "  \(count)",
                    attributes: [
                        .font: Theme.Ramp.font(.sectionLabel),
                        .foregroundColor: color.withAlphaComponent(0.8),
                    ]))
        }
        titleLabel.attributedText = label
        self.onAction = onAction
        if let actionTitle {
            actionButton.setTitle(actionTitle, for: .normal)
            actionButton.isHidden = false
        } else {
            actionButton.isHidden = true
        }
        isAccessibilityElement = false
        titleLabel.accessibilityTraits = .header
    }
}
