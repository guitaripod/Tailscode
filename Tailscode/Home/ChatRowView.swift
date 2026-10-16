import CodingAgentKit
import TailscodeCore
import UIKit

/// Everything one chat row says, decided once from Core's reading of the conversation.
///
/// Home's bands, the chat list beside a conversation and a bookmark all draw the same row, because
/// a chat is one thing whatever place it is shown in: its state is the glyph, what happened is the
/// news line, and who and where is always the last line. Nothing here is a second opinion about
/// the conversation — it is `SessionRowModel` and `ChatRowNews` spelled for UIKit.
struct ChatRowFacts: Equatable {
    struct Piece: Equatable {
        let text: String
        let isQuiet: Bool
    }

    var icon: ActivityIcon
    var title: String
    var unread: Bool
    var news: ChatRowNews?
    var chip: ModelChip?
    var pieces: [Piece]
    var age: String
    var pinned: Bool
    var dimmed: Bool
    var spoken: String

    @MainActor
    init(
        row: SessionRowModel, vocabulary: ChatListVocabulary, ask: ApprovalAsk? = nil,
        missed: MissedActivity.Reason? = nil
    ) {
        let facets = row.facets(vocabulary)
        let news = ChatRowNews.reading(for: row, ask: ask, missed: missed)
        self.icon = row.state.icon
        self.title = SessionListViewController.displayTitle(row.title)
        self.unread = row.unread
        self.news = news
        self.chip = ModelBadge.chip(for: row.entry)
        self.pieces = Self.pieces(of: facets)
        self.age = facets.age
        self.pinned = row.pinned
        self.dimmed = row.state == .offline
        self.spoken = Self.spoken(
            title: title, state: row.state.activity?.spoken, news: news?.spoken,
            unread: row.unread, pinned: row.pinned, updatedAt: row.entry.session.updatedAt)
    }

    init(saved chat: SavedChat, unread: Bool) {
        self.icon = .idle
        self.title = chat.displayTitle
        self.unread = unread
        self.news = unread ? ChatRowNews(lead: String(localized: "Finished")) : nil
        self.chip = nil
        var pieces: [Piece] = []
        if let project = chat.projectName { pieces.append(Piece(text: project, isQuiet: false)) }
        pieces.append(Piece(text: chat.profileName, isQuiet: true))
        self.pieces = pieces
        self.age = SessionRowModel.age(of: chat.updatedAt)
        self.pinned = false
        self.dimmed = false
        self.spoken = Self.spoken(
            title: chat.displayTitle, state: nil, news: news?.spoken, unread: unread,
            pinned: false, updatedAt: chat.updatedAt)
    }

    var signature: Int {
        var hasher = Hasher()
        hasher.combine(icon.symbol)
        hasher.combine(String(describing: icon.tone))
        hasher.combine(title)
        hasher.combine(unread)
        hasher.combine(news?.lead)
        hasher.combine(news?.object)
        hasher.combine(chip)
        for piece in pieces {
            hasher.combine(piece.text)
            hasher.combine(piece.isQuiet)
        }
        hasher.combine(age)
        hasher.combine(pinned)
        hasher.combine(dimmed)
        return hasher.finalize()
    }

    private static func pieces(of facets: SessionRowFacets) -> [Piece] {
        var pieces: [Piece] = []
        if let project = facets.project { pieces.append(Piece(text: project, isQuiet: false)) }
        if let origin = facets.origin { pieces.append(Piece(text: origin, isQuiet: true)) }
        return pieces
    }

    private static func spoken(
        title: String, state: String?, news: String?, unread: Bool, pinned: Bool, updatedAt: Date
    ) -> String {
        var parts = [title]
        if let state { parts.append(state) }
        if let news { parts.append(news) }
        if unread { parts.append(String(localized: "Unread")) }
        if pinned { parts.append(String(localized: "Pinned")) }
        parts.append(
            RelativeDateTimeFormatter().localizedString(for: updatedAt, relativeTo: Date()))
        return parts.joined(separator: ", ")
    }
}

struct ChatRowConfiguration: UIContentConfiguration, Equatable {
    var facts: ChatRowFacts

    func makeContentView() -> any UIView & UIContentView {
        ChatRowContentView(configuration: self)
    }

    func updated(for state: any UIConfigurationState) -> ChatRowConfiguration { self }
}

/// The row: a tinted tile holding the state's own mark, the title with its unread dot, a line of
/// news only when there is some, and who and where beneath it. The tile is the one place the
/// activity vocabulary moves — working breathes, a question knocks, everything settled holds
/// still — so a column of rows reads as a column of states before a word of it is read.
@MainActor
final class ChatRowContentView: UIView, UIContentView {
    var configuration: any UIContentConfiguration {
        didSet { apply() }
    }

    private let tile = UIView()
    private let badge = ActivityBadgeView(pointSize: 16)
    private let titleLabel = UILabel()
    private let unreadDot = UIView()
    private let newsLabel = UILabel()
    private let metaLabel = UILabel()
    private let pinView = UIImageView()
    private let ageLabel = UILabel()
    private let text = UIStackView()
    private var applied: ChatRowFacts?

    static let tileSize: CGFloat = 30
    static let textInset: CGFloat = Theme.Spacing.m + tileSize + Theme.Spacing.m

    init(configuration: ChatRowConfiguration) {
        self.configuration = configuration
        super.init(frame: .zero)
        build()
        apply()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (view: ChatRowContentView, _) in
            view.applied = nil
            view.apply()
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func build() {
        directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: Theme.Spacing.m, leading: Theme.Spacing.m, bottom: Theme.Spacing.m,
            trailing: Theme.Spacing.m)
        isAccessibilityElement = true
        accessibilityTraits = .button

        tile.layer.cornerRadius = Theme.Radius.control
        tile.layer.cornerCurve = .continuous
        tile.translatesAutoresizingMaskIntoConstraints = false
        badge.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(badge)

        titleLabel.textColor = Theme.Color.label
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        unreadDot.backgroundColor = Theme.Color.accent
        unreadDot.layer.cornerRadius = 4
        unreadDot.translatesAutoresizingMaskIntoConstraints = false
        unreadDot.setContentHuggingPriority(.required, for: .horizontal)

        let titleRow = UIStackView(arrangedSubviews: [titleLabel, unreadDot])
        titleRow.axis = .horizontal
        titleRow.alignment = .center
        titleRow.spacing = Theme.Spacing.s

        newsLabel.lineBreakMode = .byTruncatingTail

        metaLabel.lineBreakMode = .byTruncatingTail
        metaLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        pinView.image = UIImage(
            systemName: "pin.fill",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
        pinView.tintColor = Theme.Color.tertiaryLabel
        pinView.setContentHuggingPriority(.required, for: .horizontal)

        ageLabel.font = Theme.Ramp.font(.rowStamp)
        ageLabel.textColor = Theme.Color.tertiaryLabel
        ageLabel.setContentHuggingPriority(.required, for: .horizontal)
        ageLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        let metaRow = UIStackView(arrangedSubviews: [metaLabel, pinView, ageLabel])
        metaRow.axis = .horizontal
        metaRow.alignment = .firstBaseline
        metaRow.spacing = Theme.Spacing.xs + 2

        [titleRow, newsLabel, metaRow].forEach(text.addArrangedSubview)
        text.axis = .vertical
        text.spacing = 3
        text.translatesAutoresizingMaskIntoConstraints = false

        addSubview(tile)
        addSubview(text)
        NSLayoutConstraint.activate([
            tile.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor),
            tile.topAnchor.constraint(equalTo: layoutMarginsGuide.topAnchor),
            tile.widthAnchor.constraint(equalToConstant: Self.tileSize),
            tile.heightAnchor.constraint(equalToConstant: Self.tileSize),
            badge.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            badge.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
            unreadDot.widthAnchor.constraint(equalToConstant: 8),
            unreadDot.heightAnchor.constraint(equalToConstant: 8),
            text.leadingAnchor.constraint(
                equalTo: tile.trailingAnchor, constant: Theme.Spacing.m),
            text.trailingAnchor.constraint(equalTo: layoutMarginsGuide.trailingAnchor),
            text.topAnchor.constraint(equalTo: layoutMarginsGuide.topAnchor),
            text.bottomAnchor.constraint(equalTo: layoutMarginsGuide.bottomAnchor),
            heightAnchor.constraint(
                greaterThanOrEqualToConstant: Self.tileSize + 2 * Theme.Spacing.m),
        ])
    }

    override func systemLayoutSizeFitting(
        _ targetSize: CGSize, withHorizontalFittingPriority horizontalFittingPriority: UILayoutPriority,
        verticalFittingPriority: UILayoutPriority
    ) -> CGSize {
        let margins = directionalLayoutMargins
        let textWidth = max(
            0, targetSize.width - margins.leading - margins.trailing - Self.tileSize
                - Theme.Spacing.m)
        let fitted = text.systemLayoutSizeFitting(
            CGSize(width: textWidth, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
        let height = max(fitted.height + margins.top + margins.bottom, Self.tileSize + margins.top + margins.bottom)
        return CGSize(width: targetSize.width, height: height)
    }

    private func apply() {
        guard let configuration = configuration as? ChatRowConfiguration else { return }
        let facts = configuration.facts
        guard facts != applied else { return }
        applied = facts
        let large = traitCollection.preferredContentSizeCategory.isAccessibilityCategory

        tile.backgroundColor = facts.icon.tone.color.withAlphaComponent(0.14)
        badge.show(facts.icon, spoken: nil)

        titleLabel.font = Theme.Ramp.font(facts.unread ? .rowTitleStrong : .rowTitle)
        titleLabel.numberOfLines = large ? 0 : 1
        titleLabel.text = facts.title
        unreadDot.isHidden = !facts.unread

        if let news = facts.news {
            newsLabel.isHidden = false
            newsLabel.numberOfLines = large ? 0 : 2
            newsLabel.attributedText = Self.newsText(news, tone: facts.icon.tone)
        } else {
            newsLabel.isHidden = true
            newsLabel.attributedText = nil
        }

        metaLabel.numberOfLines = large ? 0 : 1
        metaLabel.attributedText = ModelChipText.line(
            chip: facts.chip,
            pieces: facts.pieces.map {
                ($0.text, $0.isQuiet ? Theme.Color.tertiaryLabel : Theme.Color.secondaryLabel)
            },
            size: Theme.Ramp.font(.panelFootnote).pointSize)
        pinView.isHidden = !facts.pinned
        ageLabel.text = facts.age

        alpha = facts.dimmed ? 0.62 : 1
        accessibilityLabel = facts.spoken
    }

    private static func newsText(_ news: ChatRowNews, tone: ActivityTone) -> NSAttributedString {
        let lead = NSMutableAttributedString(
            string: news.lead,
            attributes: [
                .font: Theme.Ramp.font(.panelDetail),
                .foregroundColor: tone == .attention
                    ? Theme.Color.label : Theme.Color.secondaryLabel,
            ])
        if let object = news.object, !object.isEmpty {
            lead.append(NSAttributedString(string: " "))
            lead.append(
                NSAttributedString(
                    string: object,
                    attributes: [
                        .font: Theme.Ramp.font(.rowDetail),
                        .foregroundColor: Theme.Color.label,
                    ]))
        }
        return lead
    }
}

/// The list cell a chat row sits in. A band that needs the person is washed in the attention
/// tone rather than outlined, because a stroke drawn per cell would box every row in the band and
/// a wash reads as one surface; every other band is the grouped surface, opaque, never glass. A
/// list that owns its own selection colours hands them in through `surfaceTint`, which wins, and a
/// list that paints no surface (`paintsGroupedSurface` off) is transparent, so the screen's own
/// ground — the theme's canvas — is what its rows sit on rather than the platform's white.
@MainActor
final class ChatRowCell: UICollectionViewListCell {
    var wantsAttention = false {
        didSet {
            guard wantsAttention != oldValue else { return }
            setNeedsUpdateConfiguration()
        }
    }

    var paintsGroupedSurface = true {
        didSet {
            guard paintsGroupedSurface != oldValue else { return }
            setNeedsUpdateConfiguration()
        }
    }

    var surfaceTint: ((UICellConfigurationState) -> UIColor?)? {
        didSet { setNeedsUpdateConfiguration() }
    }

    override func updateConfiguration(using state: UICellConfigurationState) {
        var background = UIBackgroundConfiguration.listCell().updated(for: state)
        if let tint = surfaceTint?(state) {
            background.backgroundColor = tint
        } else if state.isHighlighted || state.isSelected {
            if traitCollection.palette != nil {
                background.backgroundColor = Theme.Color.accent.withAlphaComponent(0.14)
            }
        } else if wantsAttention {
            background.backgroundColor = Self.attentionSurface
        } else {
            background.backgroundColor = paintsGroupedSurface ? Theme.Color.groupedSurface : .clear
        }
        backgroundConfiguration = background
    }

    private static let attentionSurface = UIColor { traits in
        let base = Theme.Color.groupedSurface.resolvedColor(with: traits)
        let wash = Theme.Color.warning.resolvedColor(with: traits)
        return base.mixed(with: wash, fraction: 0.1)
    }
}

extension UIColor {
    func mixed(with other: UIColor, fraction: CGFloat) -> UIColor {
        var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
        var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
        guard getRed(&r1, green: &g1, blue: &b1, alpha: &a1),
            other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
        else { return self }
        let t = min(max(fraction, 0), 1)
        return UIColor(
            red: r1 + (r2 - r1) * t, green: g1 + (g2 - g1) * t, blue: b1 + (b2 - b1) * t,
            alpha: a1 + (a2 - a1) * t)
    }
}
