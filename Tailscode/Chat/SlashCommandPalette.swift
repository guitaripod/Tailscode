import UIKit

@MainActor
struct SlashCommand {
    let keywords: [String]
    let title: String
    let subtitle: String
    let symbol: String
    /// Server commands are tinted; app actions stay neutral, so the two never read as one list.
    var runsOnServer: Bool = false
    let run: () -> Void
}

/// A titled run of commands. The split exists because `/` addresses two different machines: rows
/// that act on this app, and rows the agent itself will resolve.
@MainActor
struct SlashCommandSection {
    let title: String
    let commands: [SlashCommand]
}

/// A floating command list shown above the composer when the draft begins with `/`.
/// The glass sits behind non-interactive; the rows are siblings on top so touches land
/// (iOS 26 `UIGlassEffect` swallows touches routed through a visual-effect content view).
@MainActor
final class SlashCommandPalette: UIView {
    private let glass = Theme.Glass.view(interactive: false)
    private let scroll = UIScrollView()
    private let stack = UIStackView()
    private var heightCap: NSLayoutConstraint!

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

        scroll.showsVerticalScrollIndicator = false
        scroll.alwaysBounceVertical = false
        scroll.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scroll)

        stack.axis = .vertical
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(stack)

        let content = scroll.contentLayoutGuide
        let frame = scroll.frameLayoutGuide
        let hugContent = hugContentConstraint()
        heightCap = heightAnchor.constraint(lessThanOrEqualToConstant: 320)

        NSLayoutConstraint.activate([
            glass.topAnchor.constraint(equalTo: topAnchor),
            glass.leadingAnchor.constraint(equalTo: leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: trailingAnchor),
            glass.bottomAnchor.constraint(equalTo: bottomAnchor),

            scroll.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),

            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.widthAnchor.constraint(equalTo: frame.widthAnchor),

            hugContent,
            heightCap,
        ])

        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.18
        layer.shadowRadius = 16
        layer.shadowOffset = CGSize(width: 0, height: 6)
    }

    /// Shrinks the palette to its content when the list is short. Its priority must stay below the
    /// rows' compression resistance (750): any higher and it outranks their intrinsic heights, so a
    /// catalog taller than the gap between the navigation bar and the composer gets squashed —
    /// rows collapsing onto each other instead of scrolling.
    private func hugContentConstraint() -> NSLayoutConstraint {
        let constraint = scroll.heightAnchor.constraint(equalTo: stack.heightAnchor)
        constraint.priority = UILayoutPriority(700)
        return constraint
    }

    /// A backstop only: the owner constrains the palette's top to the safe area, which is what
    /// actually keeps a long catalog from growing up behind the navigation bar. This keeps the
    /// list from dominating the screen on a tall device even when there is room for it.
    override func layoutSubviews() {
        super.layoutSubviews()
        if let window {
            let cap = window.bounds.height * 0.55
            if heightCap.constant != cap { heightCap.constant = cap }
        }
    }

    func update(with sections: [SlashCommandSection]) {
        stack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let titled = sections.count > 1
        for section in sections where !section.commands.isEmpty {
            if titled { stack.addArrangedSubview(makeHeader(section.title)) }
            for command in section.commands { stack.addArrangedSubview(makeRow(command)) }
        }
        scroll.setContentOffset(.zero, animated: false)
    }

    private func makeHeader(_ title: String) -> UIView {
        let label = UILabel()
        label.text = title.uppercased()
        label.font = .preferredFont(forTextStyle: .caption2)
        label.adjustsFontForContentSizeCategory = true
        label.textColor = Theme.Color.tertiaryLabel
        let container = UIView()
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -2),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(
                lessThanOrEqualTo: container.trailingAnchor, constant: -14),
        ])
        return container
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
        config.baseForegroundColor =
            command.runsOnServer ? Theme.Color.accent : Theme.Color.secondaryLabel

        let button = UIButton(configuration: config)
        button.contentHorizontalAlignment = .leading
        button.addAction(UIAction { _ in command.run() }, for: .touchUpInside)
        return button
    }
}
