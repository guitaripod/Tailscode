import TailscodeCore
import UIKit

/// Doors with no reading to draw, as one card instead of one paragraph each: a key nobody has set
/// is a quiet invitation to add one rather than an error, and a key that has been set but not
/// answered for says exactly that. Each row can be hidden the way any card can — from its menu, or
/// from the chip above.
@MainActor
final class MoreProvidersCard: UIView {
    private var container = UIView()

    override init(frame: CGRect) {
        super.init(frame: frame)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func render(
        offers: [QuotaBoard.Offer], accent: (String) -> UIColor, open: @escaping (String) -> Void,
        hide: @escaping (String) -> Void
    ) {
        container.removeFromSuperview()
        guard !offers.isEmpty else { return }

        let title = UILabel()
        title.text = String(localized: "More providers")
        title.font = Theme.Ramp.font(.cardTitle)
        title.textColor = Theme.Color.label

        var views: [UIView] = [title]
        for (index, offer) in offers.enumerated() {
            if index > 0 { views.append(Self.divider()) }
            views.append(row(for: offer, accent: accent(offer.key), open: open, hide: hide))
        }
        container = UsageStyle.card(views, spacing: Theme.Spacing.m, vertical: 14)
        container.translatesAutoresizingMaskIntoConstraints = false
        addSubview(container)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: topAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor),
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    private func row(
        for offer: QuotaBoard.Offer, accent: UIColor, open: @escaping (String) -> Void,
        hide: @escaping (String) -> Void
    ) -> UIView {
        let deepseek = offer.key == "deepseek"
        let hasKey = deepseek ? DeepSeekCredentials.hasToken : OllamaCredentials.hasToken

        let tile = UIView()
        tile.backgroundColor = accent.withAlphaComponent(0.18)
        tile.layer.cornerRadius = 10
        tile.layer.cornerCurve = .continuous
        let initial = UILabel()
        initial.text = String(offer.name.prefix(1))
        initial.font = Theme.Ramp.font(.rowTitleStrong)
        initial.textColor = accent
        initial.translatesAutoresizingMaskIntoConstraints = false
        tile.addSubview(initial)
        tile.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            tile.widthAnchor.constraint(equalToConstant: 36),
            tile.heightAnchor.constraint(equalToConstant: 36),
            initial.centerXAnchor.constraint(equalTo: tile.centerXAnchor),
            initial.centerYAnchor.constraint(equalTo: tile.centerYAnchor),
        ])

        let name = UILabel()
        name.text = offer.name
        name.font = Theme.Ramp.font(.rowTitleStrong)
        name.textColor = Theme.Color.label
        let detail = UILabel()
        detail.numberOfLines = 2
        detail.font = Theme.Ramp.font(.panelFootnote)
        detail.textColor = Theme.Color.secondaryLabel
        detail.text =
            hasKey
            ? String(localized: "Key set — waiting for an answer")
            : (deepseek
                ? String(localized: "Billed per token — no plan caps")
                : String(localized: "Plan-metered — session and weekly windows"))
        let words = UIStackView(arrangedSubviews: [name, detail])
        words.axis = .vertical
        words.spacing = 1

        let action = UILabel()
        action.text = hasKey ? String(localized: "Edit API key") : String(localized: "Add API key")
        action.font = Theme.Ramp.font(.control)
        action.textColor = Theme.Color.accent
        action.textAlignment = .right
        action.numberOfLines = 2
        action.setContentHuggingPriority(.required, for: .horizontal)
        action.setContentCompressionResistancePriority(.required, for: .horizontal)

        words.setContentHuggingPriority(.defaultLow, for: .horizontal)
        words.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let large = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        let line = UIStackView(
            arrangedSubviews: large ? [UIStackView(arrangedSubviews: [tile, words]), action]
                : [tile, words, action])
        if large, let top = line.arrangedSubviews.first as? UIStackView {
            top.axis = .horizontal
            top.alignment = .center
            top.spacing = Theme.Spacing.m
            action.textAlignment = .left
        }
        line.axis = large ? .vertical : .horizontal
        line.alignment = large ? .leading : .center
        line.spacing = Theme.Spacing.m
        line.isLayoutMarginsRelativeArrangement = true
        line.directionalLayoutMargins = NSDirectionalEdgeInsets(
            top: 2, leading: 0, bottom: 2, trailing: 0)

        let control = OfferRow(line)
        control.addAction(
            UIAction { _ in
                Theme.Haptics.tap()
                open(offer.key)
            }, for: .touchUpInside)
        control.menuProvider = {
            UIMenu(children: [
                UIAction(
                    title: String(localized: "Hide"), image: UIImage(systemName: "eye.slash")
                ) { _ in hide(offer.key) }
            ])
        }
        control.accessibilityLabel = "\(offer.name), \(detail.text ?? ""), \(action.text ?? "")"
        return control
    }

    private static func divider() -> UIView {
        let line = UIView()
        line.backgroundColor = Theme.Color.separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: 1 / UIScreen.main.scale).isActive = true
        return line
    }
}

/// A row you press, with a context menu on the long press.
@MainActor
private final class OfferRow: UIControl {
    var menuProvider: (() -> UIMenu)?

    init(_ content: UIView) {
        super.init(frame: .zero)
        content.isUserInteractionEnabled = false
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        isContextMenuInteractionEnabled = true
        isAccessibilityElement = true
        accessibilityTraits = .button
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isHighlighted: Bool {
        didSet { alpha = isHighlighted ? 0.6 : 1 }
    }

    override func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            self?.menuProvider?()
        }
    }
}
