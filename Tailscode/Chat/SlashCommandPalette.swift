import UIKit

@MainActor
struct SlashCommand {
    let keywords: [String]
    let title: String
    let subtitle: String
    let symbol: String
    let run: () -> Void
}

/// A floating command list shown above the composer when the draft begins with `/`.
/// The glass sits behind non-interactive; the rows are siblings on top so touches land
/// (iOS 26 `UIGlassEffect` swallows touches routed through a visual-effect content view).
@MainActor
final class SlashCommandPalette: UIView {
    private let glass = Theme.Glass.view(interactive: false)
    private let stack = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func build() {
        translatesAutoresizingMaskIntoConstraints = false

        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.layer.cornerRadius = 20
        glass.layer.cornerCurve = .continuous
        glass.clipsToBounds = true
        glass.isUserInteractionEnabled = false
        addSubview(glass)

        stack.axis = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),

            stack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])

        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 16
        layer.shadowOffset = CGSize(width: 0, height: 6)
    }

    func update(with commands: [SlashCommand]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for command in commands { stack.addArrangedSubview(makeRow(command)) }
    }

    private func makeRow(_ command: SlashCommand) -> UIView {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(
            systemName: command.symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .medium))
        config.imagePadding = 12
        config.title = command.title
        config.subtitle = command.subtitle
        config.titleTextAttributesTransformer = .init { incoming in
            var out = incoming
            out.font = Theme.Font.subheadline()
            out.foregroundColor = Theme.Color.label
            return out
        }
        config.subtitleTextAttributesTransformer = .init { incoming in
            var out = incoming
            out.font = .preferredFont(forTextStyle: .caption2)
            out.foregroundColor = Theme.Color.secondaryLabel
            return out
        }
        config.contentInsets = NSDirectionalEdgeInsets(
            top: 9, leading: 14, bottom: 9, trailing: 14)
        config.baseForegroundColor = Theme.Color.accent

        let button = UIButton(configuration: config)
        button.contentHorizontalAlignment = .leading
        button.addAction(UIAction { _ in command.run() }, for: .touchUpInside)
        return button
    }
}
