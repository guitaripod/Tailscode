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
        static let codeBackground = UIColor.secondarySystemBackground
        static let separator = UIColor.separator
        static let success = UIColor.systemGreen
        static let warning = UIColor.systemOrange
        static let danger = UIColor.systemRed
        static let claude = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.90, green: 0.55, blue: 0.42, alpha: 1)
                : UIColor(red: 0.80, green: 0.42, blue: 0.29, alpha: 1)
        }
        static let opencode = UIColor.systemTeal
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
        private static let selectionGenerator = UISelectionFeedbackGenerator()

        private static func impact(_ style: UIImpactFeedbackGenerator.FeedbackStyle, _ intensity: CGFloat = 1) {
            guard AppPreferences.hapticsEnabled else { return }
            UIImpactFeedbackGenerator(style: style).impactOccurred(intensity: intensity)
        }

        /// A light tap for general button presses.
        static func tap() { impact(.light) }
        /// A distinct medium thump when the user sends a message.
        static func send() { impact(.medium) }
        /// A soft cushion when the agent finishes responding.
        static func received() { impact(.soft, 0.7) }
        /// A crisp tick as an agent action (tool step) lands during a turn.
        static func step() { impact(.rigid, 0.5) }
        /// The system selection click for pickers and expand/collapse.
        static func selection() {
            guard AppPreferences.hapticsEnabled else { return }
            selectionGenerator.selectionChanged()
        }
        static func success() {
            guard AppPreferences.hapticsEnabled else { return }
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        }
        static func warning() {
            guard AppPreferences.hapticsEnabled else { return }
            UINotificationFeedbackGenerator().notificationOccurred(.warning)
        }
        static func error() {
            guard AppPreferences.hapticsEnabled else { return }
            UINotificationFeedbackGenerator().notificationOccurred(.error)
        }
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

extension UIColor {
    /// Alpha-composites this color over an opaque base for the given traits,
    /// producing an opaque result (translucent chips over cell backgrounds
    /// would otherwise let truncated text bleed through).
    func blended(over base: UIColor, traits: UITraitCollection) -> UIColor {
        var tr: CGFloat = 0, tg: CGFloat = 0, tb: CGFloat = 0, ta: CGFloat = 0
        var br: CGFloat = 0, bg: CGFloat = 0, bb: CGFloat = 0, ba: CGFloat = 0
        resolvedColor(with: traits).getRed(&tr, green: &tg, blue: &tb, alpha: &ta)
        base.resolvedColor(with: traits).getRed(&br, green: &bg, blue: &bb, alpha: &ba)
        return UIColor(
            red: tr * ta + br * (1 - ta),
            green: tg * ta + bg * (1 - ta),
            blue: tb * ta + bb * (1 - ta),
            alpha: 1)
    }
}
