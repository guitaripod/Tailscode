import TailscodeCore
import UIKit

/// One agent of the Working and In the background bands: the glyph in its tone and motion, the
/// title and its running time, the line of words for what it is doing, the last minute's pulse, the
/// machine and model, and the agents it has out hanging beneath it as a tree.
@MainActor
final class AgentsRowCell: UICollectionViewCell {
    static let childLimit = 3

    var onOpenChat: (() -> Void)?
    var onToggleChildren: (() -> Void)?

    private let badgeBox = UIView()
    private let badge = ActivityBadgeView(pointSize: 16)
    private let titleLabel = UILabel()
    private let unreadDot = UIView()
    private let elapsedLabel = UILabel()
    private let titleRow = UIStackView()
    private let lineLabel = UILabel()
    private let awayLabel = UILabel()
    private let strip = AgentBeatStripView()
    private let wordLabel = UILabel()
    private let metaLabel = UILabel()
    private let pulseRow = UIStackView()
    private let foldPill = CapsuleView()
    private let foldRow = UIStackView()
    private let foldLabel = UILabel()
    private let childrenStack = UIStackView()
    private let moreButton = UIButton(type: .system)
    private let hairline = UIView()
    private let highlight = UIView()
    private let column = UIStackView()

    private var startedAt: Date?
    private var heardAt: Date?

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (cell: AgentsRowCell, _) in cell.adaptAxes()
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func build() {
        highlight.backgroundColor = Theme.Color.groupedSurface
        highlight.alpha = 0
        highlight.layer.cornerRadius = Theme.Radius.control
        highlight.layer.cornerCurve = .continuous
        highlight.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(highlight)

        badge.translatesAutoresizingMaskIntoConstraints = false
        badgeBox.addSubview(badge)
        badgeBox.setContentHuggingPriority(.required, for: .horizontal)

        titleLabel.font = Theme.Ramp.font(.rowTitleStrong)
        titleLabel.textColor = Theme.Color.label
        titleLabel.numberOfLines = 0
        titleLabel.adjustsFontForContentSizeCategory = true

        unreadDot.backgroundColor = Theme.Color.accent
        unreadDot.layer.cornerRadius = 4
        unreadDot.translatesAutoresizingMaskIntoConstraints = false

        elapsedLabel.font = Theme.Ramp.font(.rowStamp)
        elapsedLabel.textColor = Theme.Color.tertiaryLabel
        elapsedLabel.adjustsFontForContentSizeCategory = true
        elapsedLabel.setContentHuggingPriority(.required, for: .horizontal)
        elapsedLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        titleRow.axis = .horizontal
        titleRow.alignment = .firstBaseline
        titleRow.spacing = Theme.Spacing.s
        [titleLabel, unreadDot, elapsedLabel].forEach(titleRow.addArrangedSubview)

        lineLabel.font = Theme.Ramp.font(.rowDetail)
        lineLabel.textColor = Theme.Color.secondaryLabel
        lineLabel.numberOfLines = 2
        lineLabel.lineBreakMode = .byTruncatingTail
        lineLabel.adjustsFontForContentSizeCategory = true

        awayLabel.font = Theme.Ramp.font(.panelFootnote)
        awayLabel.textColor = Theme.Color.warning
        awayLabel.numberOfLines = 0
        awayLabel.adjustsFontForContentSizeCategory = true

        wordLabel.font = Theme.Ramp.font(.panelFootnote)
        wordLabel.textColor = Theme.Color.tertiaryLabel
        wordLabel.numberOfLines = 0
        wordLabel.adjustsFontForContentSizeCategory = true
        wordLabel.setContentHuggingPriority(.required, for: .horizontal)

        metaLabel.numberOfLines = 0
        metaLabel.adjustsFontForContentSizeCategory = true
        metaLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        strip.setContentHuggingPriority(.required, for: .horizontal)
        strip.setContentCompressionResistancePriority(.required, for: .horizontal)
        pulseRow.axis = .horizontal
        pulseRow.alignment = .center
        pulseRow.spacing = Theme.Spacing.s
        [strip, wordLabel, metaLabel].forEach(pulseRow.addArrangedSubview)

        buildFold()
        childrenStack.axis = .vertical
        childrenStack.spacing = Theme.Spacing.s

        var more = UIButton.Configuration.plain()
        more.baseForegroundColor = Theme.Color.secondaryLabel
        more.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0)
        more.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            var out = $0
            out.font = Theme.Ramp.font(.panelFootnote)
            return out
        }
        moreButton.configuration = more
        moreButton.contentHorizontalAlignment = .leading
        moreButton.addAction(
            UIAction { [weak self] _ in
                Theme.Haptics.selection()
                self?.onToggleChildren?()
            }, for: .touchUpInside)

        column.axis = .vertical
        column.spacing = 3
        column.setCustomSpacing(Theme.Spacing.s, after: lineLabel)
        column.setCustomSpacing(Theme.Spacing.s, after: pulseRow)
        foldRow.axis = .horizontal
        [foldPill, UIView()].forEach(foldRow.addArrangedSubview)
        [titleRow, lineLabel, awayLabel, pulseRow, foldRow, childrenStack, moreButton]
            .forEach(column.addArrangedSubview)
        column.alignment = .fill

        let body = UIStackView(arrangedSubviews: [badgeBox, column])
        body.axis = .horizontal
        body.alignment = .top
        body.spacing = Theme.Spacing.m
        body.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(body)

        hairline.backgroundColor = Theme.Color.separator
        hairline.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(hairline)

        NSLayoutConstraint.activate([
            highlight.topAnchor.constraint(equalTo: contentView.topAnchor),
            highlight.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            highlight.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            highlight.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            badgeBox.widthAnchor.constraint(equalToConstant: 24),
            badge.centerXAnchor.constraint(equalTo: badgeBox.centerXAnchor),
            badge.topAnchor.constraint(equalTo: badgeBox.topAnchor, constant: 2),
            unreadDot.widthAnchor.constraint(equalToConstant: 8),
            unreadDot.heightAnchor.constraint(equalToConstant: 8),
            body.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Spacing.m),
            body.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Theme.Spacing.m),
            body.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Spacing.xs),
            body.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.xs),
            hairline.heightAnchor.constraint(equalToConstant: 0.5),
            hairline.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            hairline.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Spacing.xs),
            hairline.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
        isAccessibilityElement = true
        accessibilityTraits = .button
        adaptAxes()
    }

    private func buildFold() {
        foldPill.backgroundColor = Theme.Color.groupedSurface
        foldLabel.font = Theme.Ramp.font(.panelFootnote)
        foldLabel.textColor = Theme.Color.secondaryLabel
        foldLabel.adjustsFontForContentSizeCategory = true
        let chevron = UIImageView(
            image: UIImage(
                systemName: "chevron.forward",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 9, weight: .semibold)))
        chevron.tintColor = Theme.Color.tertiaryLabel
        let inner = UIStackView(arrangedSubviews: [foldLabel, chevron])
        inner.axis = .horizontal
        inner.alignment = .center
        inner.spacing = Theme.Spacing.xs
        inner.translatesAutoresizingMaskIntoConstraints = false
        foldPill.addSubview(inner)
        NSLayoutConstraint.activate([
            inner.topAnchor.constraint(equalTo: foldPill.topAnchor, constant: 5),
            inner.bottomAnchor.constraint(equalTo: foldPill.bottomAnchor, constant: -5),
            inner.leadingAnchor.constraint(equalTo: foldPill.leadingAnchor, constant: Theme.Spacing.m),
            inner.trailingAnchor.constraint(equalTo: foldPill.trailingAnchor, constant: -Theme.Spacing.m),
        ])
    }

    private func adaptAxes() {
        let large = AgentsLayout.isLarge(traitCollection)
        titleRow.axis = large ? .vertical : .horizontal
        titleRow.alignment = large ? .leading : .firstBaseline
        pulseRow.axis = large ? .vertical : .horizontal
        pulseRow.alignment = large ? .leading : .center
        metaLabel.textAlignment = large ? .natural : AgentsLayout.trailing(self)
    }

    override var isHighlighted: Bool {
        didSet { highlight.alpha = isHighlighted ? 1 : 0 }
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        badge.prepareForReuse()
        onOpenChat = nil
        onToggleChildren = nil
    }

    func configure(
        _ row: AgentRow, background: Bool, showsMachines: Bool, expanded: Bool, heard: Date?, now: Date
    ) {
        startedAt = row.startedAt
        heardAt = heard
        let icon = AgentGlyph.icon(tone: row.tone, motion: row.motion, background: background)
        badge.show(icon, spoken: nil)
        titleLabel.text = row.title
        unreadDot.isHidden = !row.unread
        lineLabel.text = row.line
        lineLabel.isHidden = row.line?.isEmpty ?? true
        awayLabel.isHidden = !row.isAway
        strip.tint = row.tone.color
        strip.beat = row.beat
        strip.isHidden = row.beat == nil
        let word = row.word ?? (row.isWatched ? nil : String(localized: "listed"))
        wordLabel.text = word
        wordLabel.isHidden = word == nil
        applyMeta(row, showsMachines: showsMachines)
        pulseRow.isHidden = strip.isHidden && wordLabel.isHidden && metaLabel.isHidden
        applyChildren(row, expanded: expanded, now: now)
        alpha = row.isAway ? 0.62 : 1
        tick(now: now)
        let said = Self.spoken(row, icon: icon, background: background, showsMachines: showsMachines)
        accessibilityLabel = said + Self.elapsedSpoken(row.startedAt, now: now)
        installActions(row)
    }

    private func applyMeta(_ row: AgentRow, showsMachines: Bool) {
        let pieces: [(text: String, color: UIColor)] =
            showsMachines ? [(row.machine, Theme.Color.secondaryLabel)] : []
        let text = ModelChipText.line(
            chip: row.chip, pieces: pieces, size: Theme.Ramp.font(.panelFootnote).pointSize)
        metaLabel.attributedText = text
        metaLabel.isHidden = text.length == 0
    }

    private func applyChildren(_ row: AgentRow, expanded: Bool, now: Date) {
        let shown = expanded ? row.children : Array(row.children.prefix(Self.childLimit))
        while childrenStack.arrangedSubviews.count > shown.count {
            childrenStack.arrangedSubviews.last?.removeFromSuperview()
        }
        while childrenStack.arrangedSubviews.count < shown.count {
            childrenStack.addArrangedSubview(AgentChildLineView())
        }
        for (view, child) in zip(childrenStack.arrangedSubviews, shown) {
            (view as? AgentChildLineView)?.configure(child, now: now)
        }
        childrenStack.isHidden = shown.isEmpty
        let hidden = row.children.count - Self.childLimit
        moreButton.isHidden = hidden <= 0
        moreButton.configuration?.title =
            expanded ? String(localized: "Show fewer") : String(localized: "Show \(hidden) more")
        let listed = row.listedAgents > row.children.count ? row.listedAgents : 0
        foldRow.isHidden = listed == 0
        foldLabel.text = listed == 0 ? nil : AgentsWords.agents(listed)
    }

    func tick(now: Date) {
        elapsedLabel.text = AgentsWords.elapsed(since: startedAt, now: now)
        elapsedLabel.isHidden = startedAt == nil
        if !awayLabel.isHidden { awayLabel.text = AgentsWords.lastSeen(heardAt, now: now) }
        for case let child as AgentChildLineView in childrenStack.arrangedSubviews { child.tick(now: now) }
    }

    private static func elapsedSpoken(_ start: Date?, now: Date) -> String {
        guard let start else { return "" }
        return ". " + String(localized: "for \(AgentsWords.spokenAge(start, now: now))")
    }

    private static func spoken(
        _ row: AgentRow, icon: ActivityIcon, background: Bool, showsMachines: Bool
    ) -> String {
        var parts = [row.title, AgentGlyph.spoken(tone: row.tone, motion: row.motion, background: background)]
        if let line = row.line, !line.isEmpty { parts.append(line) }
        if let beat = row.beat { parts.append(AgentsWords.beatSpoken(beat)) }
        if let word = row.word { parts.append(word) } else if !row.isWatched {
            parts.append(String(localized: "listed, not watched"))
        }
        if showsMachines { parts.append(row.machine) }
        if let chip = row.chip { parts.append([chip.name, chip.effort].compactMap { $0 }.joined(separator: " ")) }
        if row.unread { parts.append(String(localized: "unread")) }
        if row.isAway { parts.append(String(localized: "not answering")) }
        let listed = row.listedAgents > row.children.count ? row.listedAgents : 0
        if listed > 0 { parts.append(AgentsWords.agents(listed)) }
        for child in row.children {
            var said = child.title + " " + child.line
            if let todos = child.todos { said += ", " + AgentsWords.todosSpoken(todos) }
            parts.append(said)
        }
        return parts.joined(separator: ". ")
    }

    private func installActions(_ row: AgentRow) {
        var actions = [
            UIAccessibilityCustomAction(name: String(localized: "Open chat")) { [weak self] _ in
                self?.onOpenChat?()
                return true
            }
        ]
        if row.children.count > Self.childLimit {
            actions.append(
                UIAccessibilityCustomAction(
                    name: moreButton.configuration?.title ?? String(localized: "Show more")
                ) { [weak self] _ in
                    self?.onToggleChildren?()
                    return true
                })
        }
        accessibilityCustomActions = actions
    }
}
