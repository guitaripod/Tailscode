import UIKit

enum Theme {
    enum Color {
        static let background = UIColor.systemBackground
        static let secondaryBackground = UIColor.secondarySystemBackground
        static let groupedBackground = UIColor.systemGroupedBackground
        static let label = UIColor.label
        static let secondaryLabel = UIColor.secondaryLabel
        static let tertiaryLabel = UIColor.tertiaryLabel
        static let accent = UIColor(named: "AccentColor") ?? .systemBlue
        static let userBubble = UIColor(named: "AccentColor") ?? .systemBlue
        static let assistantBubble = UIColor.secondarySystemBackground
        static let reasoningBackground = UIColor.tertiarySystemFill
        static let separator = UIColor.separator
        static let success = UIColor.systemGreen
        static let warning = UIColor.systemOrange
        static let danger = UIColor.systemRed
    }

    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    enum Radius {
        static let card: CGFloat = 14
        static let bubble: CGFloat = 18
        static let control: CGFloat = 10
    }

    enum Font {
        static func body() -> UIFont { .preferredFont(forTextStyle: .body) }
        static func headline() -> UIFont { .preferredFont(forTextStyle: .headline) }
        static func subheadline() -> UIFont { .preferredFont(forTextStyle: .subheadline) }
        static func caption() -> UIFont { .preferredFont(forTextStyle: .caption1) }
        static func mono(_ size: CGFloat = 13) -> UIFont {
            .monospacedSystemFont(ofSize: size, weight: .regular)
        }
    }

    @MainActor
    enum Haptics {
        static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
        static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
        static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
        static func error() { UINotificationFeedbackGenerator().notificationOccurred(.error) }
    }

    @MainActor
    enum Glass {
        /// A Liquid Glass visual-effect view (iOS 26+), falling back to an ultra-thin material
        /// blur on earlier systems. Pass `interactive` for controls that react to touch.
        static func view(interactive: Bool = false, tint: UIColor? = nil) -> UIVisualEffectView {
            if #available(iOS 26.0, *) {
                let effect = UIGlassEffect(style: .regular)
                effect.isInteractive = interactive
                if let tint { effect.tintColor = tint }
                return UIVisualEffectView(effect: effect)
            }
            return UIVisualEffectView(effect: UIBlurEffect(style: .systemUltraThinMaterial))
        }

        /// A capsule/rounded glass control button configuration on iOS 26, with a tinted
        /// filled fallback for earlier systems.
        static func buttonConfiguration(prominent: Bool = false) -> UIButton.Configuration {
            if #available(iOS 26.0, *) {
                return prominent ? .prominentGlass() : .glass()
            }
            var config: UIButton.Configuration = prominent ? .filled() : .gray()
            config.cornerStyle = .capsule
            return config
        }
    }
}
