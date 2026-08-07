import UIKit

enum Theme {
    enum Color {
        static let background = UIColor.systemBackground
        static let secondaryBackground = UIColor.secondarySystemBackground
        static let groupedBackground = UIColor.systemGroupedBackground
        static let groupedSurface = UIColor.secondarySystemGroupedBackground
        static let label = UIColor.label
        static let secondaryLabel = UIColor.secondaryLabel
        static let tertiaryLabel = UIColor.tertiaryLabel
        static let accent = UIColor(named: "AccentColor") ?? .systemBlue
        static let userBubble = UIColor(named: "AccentColor") ?? .systemBlue
        static let assistantBubble = UIColor.systemGray5
        static let reasoningBackground = UIColor.tertiarySystemFill
        static let codeBackground = UIColor.secondarySystemBackground
        static let separator = UIColor.separator
        static let success = UIColor.systemGreen
        static let warning = UIColor.systemOrange
        static let danger = UIColor.systemRed
        static let codeNumber = UIColor.systemTeal
        static let codeKeyword = UIColor.systemPink
        static let claude = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.90, green: 0.55, blue: 0.42, alpha: 1)
                : UIColor(red: 0.80, green: 0.42, blue: 0.29, alpha: 1)
        }
        static let grok = UIColor { traits in
            traits.userInterfaceStyle == .dark
                ? UIColor(red: 0.91, green: 0.91, blue: 0.92, alpha: 1)
                : UIColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1)
        }
        static let opencode = UIColor.systemTeal
    }

    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
        static let xxl: CGFloat = 32
        static let xxxl: CGFloat = 48
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
        static func footnote() -> UIFont { .preferredFont(forTextStyle: .footnote) }
        static func caption() -> UIFont { .preferredFont(forTextStyle: .caption1) }
        static func mono(_ size: CGFloat = 13) -> UIFont {
            .monospacedSystemFont(ofSize: size, weight: .regular)
        }

        /// A display headline that still answers to Dynamic Type: the metrics of a
        /// text style scale a weighted system face, which `.systemFont(ofSize:)`
        /// alone never does. The base size is read at the default content size —
        /// reading the current one and scaling it again doubles the growth.
        static func display(_ style: UIFont.TextStyle = .largeTitle, weight: UIFont.Weight = .bold)
            -> UIFont
        {
            UIFontMetrics(forTextStyle: style).scaledFont(
                for: .systemFont(ofSize: baseSize(of: style), weight: weight))
        }

        /// A text style that answers Dynamic Type up to a ceiling. Type set inside a
        /// fixed diagram has nowhere to grow into: past a point every extra point
        /// costs a word, so the label that names a node stops rather than truncates.
        static func capped(_ style: UIFont.TextStyle, maximum: CGFloat) -> UIFont {
            UIFontMetrics(forTextStyle: style).scaledFont(
                for: .systemFont(ofSize: baseSize(of: style)), maximumPointSize: maximum)
        }

        static func scaledMono(_ style: UIFont.TextStyle = .footnote, weight: UIFont.Weight = .regular)
            -> UIFont
        {
            UIFontMetrics(forTextStyle: style).scaledFont(
                for: .monospacedSystemFont(ofSize: baseSize(of: style), weight: weight))
        }

        private static func baseSize(of style: UIFont.TextStyle) -> CGFloat {
            UIFontDescriptor.preferredFontDescriptor(
                withTextStyle: style,
                compatibleWith: UITraitCollection(preferredContentSizeCategory: .large)
            ).pointSize
        }
    }

    /// Names for the physical cues; the force behind them is `HapticEngine`'s business and the
    /// user's setting, so nothing here mentions an amplitude.
    @MainActor
    enum Haptics {
        /// A soft tap for general button presses.
        static func tap() { HapticEngine.shared.play(.tap) }
        /// The message leaves and the wait begins.
        static func send() { HapticEngine.shared.play(.send) }
        /// The wait is over: the agent finished and it is your turn.
        static func received() { HapticEngine.shared.play(.received) }
        /// A step of the work landed while you wait; repeats are coalesced.
        static func step() { HapticEngine.shared.play(.step) }
        /// The agent stopped mid-wait to ask for something.
        static func needsYou() { HapticEngine.shared.play(.needsYou) }
        /// The selection click for pickers and expand/collapse.
        static func selection() { HapticEngine.shared.play(.selection) }
        static func success() { HapticEngine.shared.play(.success) }
        static func warning() { HapticEngine.shared.play(.warning) }
        static func error() { HapticEngine.shared.play(.error) }
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
