import TailscodeCore
import UIKit

struct GaugeVM {
    let name: String
    let fraction: Double
    let percentText: String
    let amountText: String
    let caption: String
    let isBalance: Bool
    let pace: PaceRow?

    /// Whether the row has a pace to speak of: a window with a clock and enough of it gone to read.
    var isPaced: Bool { pace.map { $0.kind == .window && $0.tick != nil && $0.note == nil } ?? false }
}

func rampColor(for fraction: Double, accent: UIColor) -> UIColor {
    switch QuotaSurface.Pressure(fraction: fraction) {
    case .usedUp, .nearlyOut: return Theme.Color.danger
    case .gettingTight: return Theme.Color.warning
    case .roomToSpare: return accent
    }
}

/// The page's few shared shapes, so a card, a chip and a row are drawn the same way wherever the
/// screen needs one.
@MainActor
enum UsageStyle {
    static func card(_ views: [UIView], spacing: CGFloat, vertical: CGFloat = Theme.Spacing.l)
        -> UIView
    {
        let container = UIView()
        container.backgroundColor = Theme.Color.groupedSurface
        container.layer.cornerRadius = Theme.Radius.card
        container.layer.cornerCurve = .continuous

        let stack = UIStackView(arrangedSubviews: views)
        stack.axis = .vertical
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: vertical),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -vertical),
            stack.leadingAnchor.constraint(
                equalTo: container.leadingAnchor, constant: Theme.Spacing.l),
            stack.trailingAnchor.constraint(
                equalTo: container.trailingAnchor, constant: -Theme.Spacing.l),
        ])
        return container
    }

    static func pill(_ text: String, color: UIColor) -> UIView {
        let label = UILabel()
        label.text = text
        label.font = Theme.Ramp.font(.metricLabel)
        label.textColor = color
        label.translatesAutoresizingMaskIntoConstraints = false
        let background = UIView()
        background.backgroundColor = color.withAlphaComponent(0.16)
        background.layer.cornerRadius = 9
        background.layer.cornerCurve = .continuous
        background.setContentHuggingPriority(.required, for: .horizontal)
        background.setContentCompressionResistancePriority(.required, for: .horizontal)
        background.addSubview(label)
        NSLayoutConstraint.activate([
            background.heightAnchor.constraint(equalToConstant: 20),
            label.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            label.leadingAnchor.constraint(
                equalTo: background.leadingAnchor, constant: Theme.Spacing.s),
            label.trailingAnchor.constraint(
                equalTo: background.trailingAnchor, constant: -Theme.Spacing.s),
        ])
        return background
    }

    static func dot(_ color: UIColor, size: CGFloat = 9) -> UIView {
        let dot = UIView()
        dot.backgroundColor = color
        dot.layer.cornerRadius = size / 2
        dot.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            dot.widthAnchor.constraint(equalToConstant: size),
            dot.heightAnchor.constraint(equalToConstant: size),
        ])
        return dot
    }

    static func moreButton(menu: UIMenu) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "ellipsis")
        configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
            pointSize: 16, weight: .semibold)
        configuration.baseForegroundColor = Theme.Color.secondaryLabel
        configuration.contentInsets = NSDirectionalEdgeInsets(
            top: 6, leading: 8, bottom: 6, trailing: 0)
        let button = UIButton(configuration: configuration)
        button.showsMenuAsPrimaryAction = true
        button.menu = menu
        button.accessibilityLabel = String(localized: "Card options")
        button.setContentHuggingPriority(.required, for: .horizontal)
        return button
    }

    /// A bar that is a window's fullness: never a missing bar, so a window with almost nothing
    /// spent still shows a sliver.
    static func bar(fraction: Double, color: UIColor) -> UIView {
        let track = UIView()
        track.backgroundColor = Theme.Color.separator
        track.layer.cornerRadius = 3
        track.translatesAutoresizingMaskIntoConstraints = false
        let fill = UIView()
        fill.backgroundColor = color
        fill.layer.cornerRadius = 3
        fill.translatesAutoresizingMaskIntoConstraints = false
        track.addSubview(fill)
        NSLayoutConstraint.activate([
            track.heightAnchor.constraint(equalToConstant: 6),
            fill.leadingAnchor.constraint(equalTo: track.leadingAnchor),
            fill.topAnchor.constraint(equalTo: track.topAnchor),
            fill.bottomAnchor.constraint(equalTo: track.bottomAnchor),
            fill.widthAnchor.constraint(
                equalTo: track.widthAnchor, multiplier: max(0.02, min(1, fraction))),
        ])
        return track
    }
}

/// The navigation title and, under it, how fresh the figures are — so the screen needs no large
/// title and no line of its own to say "Updated just now".
@MainActor
final class UsageTitleView: UIStackView {
    private let titleLabel = UILabel()
    private let subtitleLabel = UILabel()

    var subtitle: String? {
        didSet {
            subtitleLabel.text = subtitle
            subtitleLabel.isHidden = subtitle == nil
        }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        axis = .vertical
        alignment = .center
        spacing = 0
        titleLabel.text = String(localized: "Usage")
        titleLabel.font = Theme.Ramp.font(.panelTitle)
        titleLabel.textColor = Theme.Color.label
        subtitleLabel.font = Theme.Ramp.font(.panelFootnote)
        subtitleLabel.textColor = Theme.Color.secondaryLabel
        subtitleLabel.isHidden = true
        addArrangedSubview(titleLabel)
        addArrangedSubview(subtitleLabel)
    }

    @available(*, unavailable) required init(coder: NSCoder) { fatalError() }
}

@MainActor
enum UsageAccent {
    static func color(for key: String) -> UIColor {
        switch key {
        case "claude": return Theme.Color.claude
        case "grok": return Theme.Color.grok
        case "opencode": return Theme.Color.opencode
        case "deepseek": return Theme.Color.modelFamily(.deepseek)
        case "ollama-cloud": return Theme.Color.ollamaCloud
        default: return Theme.Color.accent
        }
    }
}
