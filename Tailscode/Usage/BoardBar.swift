import TailscodeCore
import UIKit

/// The board's switches: one chip per provider, lit in its brand's colour while shown and dimmed
/// while hidden — never removed, because a switch that vanishes when it is off cannot be switched
/// back. The arrangement and the lead live in the navigation bar's menu.
@MainActor
final class BoardBar: UIView {
    private let scroller = UIScrollView()
    private let row = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        scroller.showsHorizontalScrollIndicator = false
        scroller.alwaysBounceHorizontal = false
        scroller.translatesAutoresizingMaskIntoConstraints = false
        row.axis = .horizontal
        row.spacing = Theme.Spacing.s
        row.alignment = .center
        row.translatesAutoresizingMaskIntoConstraints = false
        scroller.addSubview(row)
        addSubview(scroller)
        NSLayoutConstraint.activate([
            scroller.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroller.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroller.topAnchor.constraint(equalTo: topAnchor),
            scroller.bottomAnchor.constraint(equalTo: bottomAnchor),
            row.leadingAnchor.constraint(equalTo: scroller.contentLayoutGuide.leadingAnchor),
            row.trailingAnchor.constraint(equalTo: scroller.contentLayoutGuide.trailingAnchor),
            row.topAnchor.constraint(equalTo: scroller.contentLayoutGuide.topAnchor),
            row.bottomAnchor.constraint(equalTo: scroller.contentLayoutGuide.bottomAnchor),
            scroller.frameLayoutGuide.heightAnchor.constraint(equalTo: row.heightAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 34),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func render(
        _ choices: [QuotaBoard.Choice],
        change: @escaping ((inout QuotaBoardPreferences) -> Void) -> Void
    ) {
        row.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for choice in choices {
            let accent = Self.accent(for: choice)
            var configuration = UIButton.Configuration.plain()
            configuration.title = choice.name
            configuration.cornerStyle = .capsule
            configuration.buttonSize = .small
            configuration.baseForegroundColor =
                choice.isHidden ? Theme.Color.secondaryLabel : Theme.Color.label
            configuration.background.backgroundColor =
                choice.isHidden
                ? Theme.Color.groupedSurface : accent.withAlphaComponent(0.20)
            configuration.contentInsets = NSDirectionalEdgeInsets(
                top: 6, leading: 12, bottom: 6, trailing: 12)
            if choice.isReported {
                configuration.image = UIImage(systemName: "circle.fill")
                configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
                    pointSize: 7)
                configuration.imageColorTransformer = UIConfigurationColorTransformer { _ in
                    choice.isHidden ? accent.withAlphaComponent(0.45) : accent
                }
            } else {
                configuration.image = UIImage(systemName: "key")
                configuration.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
                    pointSize: 10)
            }
            configuration.imagePadding = 6
            let chip = UIButton(configuration: configuration)
            chip.setContentHuggingPriority(.required, for: .horizontal)
            chip.setContentCompressionResistancePriority(.required, for: .horizontal)
            chip.accessibilityLabel = choice.name
            chip.accessibilityValue =
                choice.isHidden ? String(localized: "Hidden") : String(localized: "Shown")
            chip.accessibilityHint =
                choice.isHidden
                ? String(localized: "Shows this provider on the board")
                : String(localized: "Hides this provider from the board")
            let key = choice.key
            let hidden = choice.isHidden
            chip.addAction(
                UIAction { _ in
                    Theme.Haptics.selection()
                    change { $0.setHidden(key, !hidden) }
                }, for: .touchUpInside)
            row.addArrangedSubview(chip)
        }
    }

    /// The arrangement and the lead, one menu at the trailing edge of the navigation bar.
    static func arrangeItem(
        preferences: QuotaBoardPreferences,
        change: @escaping ((inout QuotaBoardPreferences) -> Void) -> Void
    ) -> UIBarButtonItem {
        let arrangements = QuotaBoardPreferences.Arrangement.allCases.map { option in
            UIAction(
                title: option.title, state: option == preferences.arrangement ? .on : .off
            ) { _ in
                change { $0.arrangement = option }
            }
        }
        let lead = UIAction(
            title: String(localized: "Lead with the tightest window"),
            state: preferences.leadsWithTightest ? .on : .off
        ) { _ in
            change { $0.leadsWithTightest.toggle() }
        }
        let item = UIBarButtonItem(
            image: UIImage(systemName: "line.3.horizontal.decrease"),
            menu: UIMenu(children: [
                UIMenu(
                    title: String(localized: "Arrange"), options: .displayInline,
                    children: arrangements),
                UIMenu(options: .displayInline, children: [lead]),
            ]))
        item.accessibilityLabel = String(localized: "Arrange the board")
        return item
    }

    private static func accent(for choice: QuotaBoard.Choice) -> UIColor {
        UsageAccent.color(for: choice.key)
    }
}
