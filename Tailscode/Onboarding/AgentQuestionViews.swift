import CodingAgentKit
import TailscodeCore
import UIKit

/// One answer to first run's question, as a press: the agent's mark in its own colour over its
/// name. Three of them sit side by side on the welcome screen, so the first thing a stranger does
/// in the app is say which agent they run, and that press is already the way into its setup.
@MainActor
final class AgentTile: UIControl {
    private let glyph = UIImageView()
    private let titleLabel = UILabel()
    private let stack = UIStackView()
    private let tint: UIColor

    init(choice: FirstRunPlan.AgentChoice) {
        tint = choice.agent.brandColor
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = Theme.Radius.card
        layer.cornerCurve = .continuous
        layer.borderWidth = 1.5

        glyph.image = UIImage(
            systemName: choice.agent.symbolName,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .semibold))
        glyph.tintColor = tint
        glyph.contentMode = .center
        glyph.setContentHuggingPriority(.required, for: .horizontal)
        glyph.setContentCompressionResistancePriority(.required, for: .horizontal)

        titleLabel.text = choice.title
        titleLabel.font = Theme.Ramp.font(.panelLabel)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = Theme.Color.label
        titleLabel.numberOfLines = 2
        titleLabel.adjustsFontSizeToFitWidth = true
        titleLabel.minimumScaleFactor = 0.8
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        stack.addArrangedSubview(glyph)
        stack.addArrangedSubview(titleLabel)
        stack.isUserInteractionEnabled = false
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Spacing.m),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Spacing.m),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.s),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Spacing.s),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 84),
        ])

        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = "\(choice.title). \(choice.detail)"
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeIdentityTrait.self]) {
            (view: AgentTile, _) in view.applyColors()
        }
        applyColors()
        setStacked(true)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.6 : 1 }
    }

    /// Mark over name while the tiles share a row, mark beside name once large text has turned
    /// the row into a column and each tile has the whole width to itself.
    func setStacked(_ stacked: Bool) {
        stack.axis = stacked ? .vertical : .horizontal
        stack.alignment = .center
        stack.spacing = stacked ? Theme.Spacing.s : Theme.Spacing.m
        titleLabel.textAlignment = stacked ? .center : .natural
    }

    private func applyColors() {
        layer.borderColor = tint.withAlphaComponent(0.45).resolvedColor(with: traitCollection).cgColor
        backgroundColor = tint.withAlphaComponent(0.12).blended(
            over: Theme.Color.groupedSurface, traits: traitCollection)
    }
}

/// The question's answers in a row of equal tiles, which becomes a column at accessibility text
/// sizes, where three names side by side would each be a few characters wide.
@MainActor
final class AgentTileRow: UIStackView {
    private let tiles: [AgentTile]

    init(choices: [FirstRunPlan.AgentChoice], onAnswer: @escaping (AgentType) -> Void) {
        tiles = choices.map(AgentTile.init(choice:))
        super.init(frame: .zero)
        distribution = .fillEqually
        for (tile, choice) in zip(tiles, choices) {
            tile.addAction(UIAction { _ in onAnswer(choice.agent) }, for: .touchUpInside)
            addArrangedSubview(tile)
        }
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (row: AgentTileRow, _) in row.apply()
        }
        apply()
    }

    @available(*, unavailable) required init(coder: NSCoder) { fatalError() }

    private func apply() {
        let accessible = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        axis = accessible ? .vertical : .horizontal
        spacing = Theme.Spacing.s
        tiles.forEach { $0.setStacked(!accessible) }
    }
}

/// The agent being installed, once the question has been answered: one row that says which, with
/// the others a press away in a menu. The three full cards asked the question; repeating them
/// above the command would push the command, and the scan that follows it, off the screen.
@MainActor
final class AgentSwitchRow: UIView {
    private let tint: UIColor

    init(choices: [FirstRunPlan.AgentChoice], onPick: @escaping (AgentType) -> Void) {
        let selected = choices.first(where: \.isSelected) ?? choices.first
        tint = selected?.agent.brandColor ?? Theme.Color.accent
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        layer.cornerRadius = Theme.Radius.control
        layer.cornerCurve = .continuous
        layer.borderWidth = 1.5

        let glyph = UIImageView(
            image: UIImage(
                systemName: selected?.agent.symbolName ?? "terminal",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold)))
        glyph.tintColor = tint
        glyph.contentMode = .center
        glyph.translatesAutoresizingMaskIntoConstraints = false

        let text = UIStackView(arrangedSubviews: [
            SetupLink.label(selected?.title ?? "", role: .panelLabel, color: Theme.Color.label),
            SetupLink.label(selected?.detail ?? "", role: .panelFootnote),
        ])
        text.axis = .vertical
        text.spacing = 2
        text.translatesAutoresizingMaskIntoConstraints = false

        var config = UIButton.Configuration.plain()
        config.title = Localized.text("Change")
        config.baseForegroundColor = Theme.Color.accent
        config.contentInsets = NSDirectionalEdgeInsets(top: 11, leading: 8, bottom: 11, trailing: 4)
        config.titleTextAttributesTransformer = UIConfigurationTextAttributesTransformer {
            var out = $0
            out.font = Theme.Ramp.font(.panelDetail)
            return out
        }
        let change = UIButton(configuration: config)
        change.showsMenuAsPrimaryAction = true
        change.menu = UIMenu(
            children: choices.map { choice in
                UIAction(
                    title: choice.title, subtitle: choice.detail,
                    image: UIImage(systemName: choice.agent.symbolName),
                    state: choice.isSelected ? .on : .off
                ) { _ in
                    Theme.Haptics.selection()
                    onPick(choice.agent)
                }
            })
        change.translatesAutoresizingMaskIntoConstraints = false
        change.setContentHuggingPriority(.required, for: .horizontal)
        change.setContentCompressionResistancePriority(.required, for: .horizontal)
        if let selected {
            change.accessibilityLabel = "\(Localized.text("Change")). \(selected.title)"
        }

        addSubview(glyph)
        addSubview(text)
        addSubview(change)
        NSLayoutConstraint.activate([
            glyph.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Theme.Spacing.m),
            glyph.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Spacing.m),
            glyph.widthAnchor.constraint(equalToConstant: 22),
            text.leadingAnchor.constraint(equalTo: glyph.trailingAnchor, constant: Theme.Spacing.s),
            text.topAnchor.constraint(equalTo: topAnchor, constant: Theme.Spacing.m),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Theme.Spacing.m),
            text.trailingAnchor.constraint(equalTo: change.leadingAnchor, constant: -Theme.Spacing.xs),
            change.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Theme.Spacing.s),
            change.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeIdentityTrait.self]) {
            (view: AgentSwitchRow, _) in view.applyColors()
        }
        applyColors()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func applyColors() {
        layer.borderColor = tint.withAlphaComponent(0.9).resolvedColor(with: traitCollection).cgColor
        backgroundColor = tint.withAlphaComponent(0.10).blended(
            over: Theme.Color.groupedSurface, traits: traitCollection)
    }
}
