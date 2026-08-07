import TailscodeCore
import UIKit

enum Theme {
    /// The colours, named by what they mean rather than what they are — the same vocabulary the
    /// desktop's `Palette` is written in, so a capability that reads as a warning on one client
    /// cannot read as motion on another.
    ///
    /// Each token is one colour for the life of the process and is asked again on every resolve, so
    /// a theme change repaints what is already on screen through `ThemeIdentityTrait` rather than
    /// through a rebuild. Every token names the system colour it stands in for, because "System" is
    /// one of the choices and is what this app looked like before it had any others.
    enum Color {
        static let background = ThemePalette.color(\.canvas, system: .systemBackground)
        static let secondaryBackground = ThemePalette.color(
            \.canvasRaised, system: .secondarySystemBackground)
        static let groupedBackground = ThemePalette.color(
            \.canvas, system: .systemGroupedBackground)
        static let groupedSurface = ThemePalette.color(
            \.canvasRaised, system: .secondarySystemGroupedBackground)
        static let label = ThemePalette.color(\.text, system: .label)
        static let secondaryLabel = ThemePalette.color(\.textDim, system: .secondaryLabel)
        /// The third register has no slot of its own: it is the dim one walked a third of the way
        /// back into the canvas, which is what keeps two quiet greys distinguishable on a palette
        /// whose canvas is not grey at all.
        static let tertiaryLabel = ThemePalette.blended(
            \.textDim, toward: \.canvas, 0.35, system: .tertiaryLabel)
        static let accent = ThemePalette.color(\.accent, system: systemAccent)
        static let userBubble = ThemePalette.color(\.accent, system: systemAccent)
        static let assistantBubble = ThemePalette.color(\.canvasRaised, system: .systemGray5)
        static let reasoningBackground = ThemePalette.color(
            \.subagentBg, system: .tertiarySystemFill)
        static let codeBackground = ThemePalette.color(\.codeBg, system: .secondarySystemBackground)
        static let separator = ThemePalette.color(\.rule, system: .separator)
        static let success = ThemePalette.color(\.accent, system: .systemGreen)
        static let warning = ThemePalette.color(\.warn, system: .systemOrange)
        static let danger = ThemePalette.color(\.danger, system: .systemRed)
        /// Identity of what the agent touched: tool names, file paths, attachments, subagents.
        static let info = ThemePalette.color(\.info, system: .systemIndigo)
        /// Standing marks on the conversation: the goal, a compaction seam, a saved chat.
        static let special = ThemePalette.color(\.special, system: .systemPurple)
        /// Text set on a signal-filled surface, so a fill that reads against the canvas reads
        /// against its own ink too.
        static let onAccent = ThemePalette.color(\.onAccent, system: .white)
        static let findHit = ThemePalette.color(
            \.findHit, system: UIColor.systemYellow.withAlphaComponent(0.35))
        /// One colour per syntax role, resolved from the theme the app is wearing. The mapping is
        /// the shared one — a keyword is the standing mark, a name is an identity, a diff reuses
        /// addition and subtraction — so a block of code looks like the same block on all three
        /// clients. "System" has no palette to derive from, so it falls back to the platform's own
        /// colours rather than to a stock syntax theme none of Apple's materials were drawn for.
        static func syntax(_ role: SyntaxRole) -> UIColor { syntaxColors[role] ?? label }

        private static let syntaxColors: [SyntaxRole: UIColor] = SyntaxRole.allCases.reduce(
            into: [:]
        ) { table, role in
            table[role] = ThemePalette.syntax(role, system: systemSyntax(role))
        }

        private static func systemSyntax(_ role: SyntaxRole) -> UIColor {
            switch role {
            case .plain: return .label
            case .keyword, .attribute: return .systemPink
            case .type, .function: return .systemTeal
            case .string: return .systemOrange
            case .number: return .systemPurple
            case .comment: return .secondaryLabel
            case .added: return .systemGreen
            case .removed: return .systemRed
            }
        }
        static let claude = ThemePalette.color(
            \.brandClaude,
            system: UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(red: 0.90, green: 0.55, blue: 0.42, alpha: 1)
                    : UIColor(red: 0.80, green: 0.42, blue: 0.29, alpha: 1)
            })
        static let grok = ThemePalette.color(
            \.brandGrok,
            system: UIColor { traits in
                traits.userInterfaceStyle == .dark
                    ? UIColor(red: 0.91, green: 0.91, blue: 0.92, alpha: 1)
                    : UIColor(red: 0.12, green: 0.12, blue: 0.12, alpha: 1)
            })
        static let opencode = ThemePalette.color(\.brandOpencode, system: .systemTeal)

        /// Ink for text and symbols that sit *on* a pane of glass, which is the one place a theme
        /// must not reach. Glass flips between light and dark on its own, against whatever content
        /// happens to be behind it and regardless of what the app decided it was, and the system
        /// derives its vibrancy from these colours in particular. A palette slot here would neither
        /// flip nor gain vibrancy, and would go unreadable at exactly the moment the glass inverted.
        static let onGlass = UIColor.label
        static let onGlassSecondary = UIColor.secondaryLabel

        private static let systemAccent = UIColor(named: "AccentColor") ?? .systemBlue
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

    /// A theme is not paint over the materials — it is what the materials drink.
    ///
    /// Glass takes its colour from whatever is behind it, so the way a palette reaches the chrome
    /// is by owning the canvas the chrome floats over: pick Gruvbox and the navigation bar goes
    /// warm because the transcript under it did, without one material being replaced. Glass stays
    /// glass, it never sits on glass, and prose never sits on glass — the transcript is flat and
    /// opaque, which is also the only surface a palette's contrast contract was ever measured
    /// against.
    ///
    /// The one thing a theme says to the glass directly is its accent, and only where the system
    /// itself would have used a tint: a prominent control, a control that carries the send. A
    /// wash is not a fill — the tint rides at a fraction, because a saturated pane of glass stops
    /// being glass.
    @MainActor
    enum Glass {
        /// How much of the accent a tinted pane of glass is allowed to carry.
        private static let wash: CGFloat = 0.32

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

        /// Puts a signal into a pane of glass that already exists — a banner that has just learned
        /// it is a warning rather than a notice. A wash, never a fill: the system maps a tint
        /// through the brightness behind the glass, and a solid colour there stops being glass at
        /// all. `nil` takes the signal back off.
        static func tint(_ view: UIVisualEffectView, with signal: UIColor?) {
            guard #available(iOS 26.0, *), let effect = view.effect as? UIGlassEffect else { return }
            effect.tintColor = signal?.withAlphaComponent(wash)
            view.effect = effect
        }

        /// A capsule/rounded glass control button configuration on iOS 26, with a tinted
        /// filled fallback for earlier systems.
        ///
        /// A plain glass button is left entirely alone: it already reads the window's tint, which
        /// is the theme's accent. Only the prominent one is given a colour, and only its fill —
        /// the system maps a tint through the brightness behind the glass and picks the ink to
        /// match, so a foreground chosen here against a flat swatch would be a guess about a
        /// surface that does not exist yet.
        static func buttonConfiguration(prominent: Bool = false) -> UIButton.Configuration {
            if #available(iOS 26.0, *) {
                guard prominent else { return .glass() }
                var config: UIButton.Configuration = .prominentGlass()
                config.baseBackgroundColor = Theme.Color.accent
                return config
            }
            var config: UIButton.Configuration = prominent ? .filled() : .gray()
            config.cornerStyle = .capsule
            if prominent {
                config.baseBackgroundColor = Theme.Color.accent
                config.baseForegroundColor = Theme.Color.onAccent
            } else {
                config.baseForegroundColor = Theme.Color.accent
            }
            return config
        }
    }

    /// Where the theme is actually installed, which is nowhere near the chrome.
    ///
    /// Liquid Glass is a material, not a colour: it samples the content beneath it and derives its
    /// own light-or-dark state, its tone range and its vibrancy from what it finds. So the whole
    /// mechanism by which a theme reaches a navigation bar is that the transcript under the bar
    /// went warm — Apple's own instruction for an app with a colour identity is to put the colour
    /// in the content layer and let the glass pick it up. Painting a bar's background is the one
    /// thing that breaks it: a `UIBarAppearance` background cancels the material and the scroll
    /// edge effect with it, so no bar is touched here and no palette slot maps to one.
    ///
    /// Three facts are all a theme sets, and all of them are app-wide: the identity trait, which
    /// invalidates every dynamic colour in the process; the tint, which is the accent every control
    /// inherits down the window; and the interface style, because a palette with a dark canvas has
    /// to be a dark app or the glass floats in the wrong register over it.
    @MainActor
    enum Chrome {
        /// A navigation bar's *background* is the material and must never be painted; its title is
        /// content, and content is the palette's. Only the two text attributes are set, on every
        /// appearance the bar can be in, so the same words are the same ink whether the bar is
        /// floating over a scrolled transcript or flush against the top of one.
        private static func titledAppearance(
            _ configure: (UINavigationBarAppearance) -> Void
        ) -> UINavigationBarAppearance {
            let appearance = UINavigationBarAppearance()
            configure(appearance)
            appearance.titleTextAttributes = [.foregroundColor: Color.label]
            appearance.largeTitleTextAttributes = [.foregroundColor: Color.label]
            return appearance
        }

        /// Called once at launch and again whenever the choice changes. Nothing is broadcast and
        /// nothing is reloaded: the trait override is the broadcast, and every dynamic colour in
        /// the process — including the ones already inside an attributed string a cell is holding —
        /// is re-resolved off the back of it. What it does not reach is a `CGColor`, which is why
        /// the views that freeze one register for this trait alongside the appearance.
        static func apply() {
            let bar = UINavigationBar.appearance()
            bar.standardAppearance = titledAppearance { $0.configureWithDefaultBackground() }
            bar.compactAppearance = bar.standardAppearance
            bar.scrollEdgeAppearance = titledAppearance { $0.configureWithTransparentBackground() }
            bar.compactScrollEdgeAppearance = bar.scrollEdgeAppearance
            for window in windows {
                adopt(window)
                restyleBars(window)
            }
        }

        /// A bar built before the theme changed holds its own copy of the proxy it was made from,
        /// so the proxy alone repaints nothing already on screen.
        private static func restyleBars(_ view: UIView) {
            if let bar = view as? UINavigationBar {
                let proxy = UINavigationBar.appearance()
                bar.standardAppearance = proxy.standardAppearance
                bar.compactAppearance = proxy.compactAppearance
                bar.scrollEdgeAppearance = proxy.scrollEdgeAppearance
                bar.compactScrollEdgeAppearance = proxy.compactScrollEdgeAppearance
            }
            view.subviews.forEach(restyleBars)
        }

        static func adopt(_ window: UIWindow) {
            window.traitOverrides[ThemeIdentityTrait.self] = ThemeSelection.themeID
            window.overrideUserInterfaceStyle = style
            window.tintColor = Color.accent
        }

        /// Which of the theme's two faces to wear. A pinned appearance overrides the system's;
        /// nothing pinned means the theme follows the device between its own light and dark, which
        /// is the whole reason each theme carries both — and why the palette and the window can
        /// never disagree about which one is in force.
        static var style: UIUserInterfaceStyle {
            switch ThemeSelection.appearance.pinnedDark {
            case .some(true): return .dark
            case .some(false): return .light
            case .none: return .unspecified
            }
        }

        static var windows: [UIWindow] {
            UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap(\.windows)
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
