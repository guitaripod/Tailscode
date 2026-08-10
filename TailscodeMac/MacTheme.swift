import AppKit
import CodingAgentKit
import TailscodeCore

/// The desktop half of the design tokens. Values are the same numbers the iOS `Theme` uses; only
/// the types differ. Chrome is material and quiet, the transcript is flat and opaque — the two
/// never borrow each other's surfaces.
enum MacTheme {
    /// The colours, named by what they mean rather than what they are — the same vocabulary the
    /// desktop's `Palette` is written in. Each is computed rather than stored, because a theme is
    /// a second axis AppKit has no trait for: the token has to be asked again after a change, and
    /// `ThemePalette` is what remembers the answer in between.
    enum Color {
        static var label: NSColor { ThemePalette.color(\.text, system: .labelColor) }
        static var secondaryLabel: NSColor {
            ThemePalette.color(\.textDim, system: .secondaryLabelColor)
        }
        /// The third register has no slot of its own: it is the dim one walked a third of the way
        /// back into the canvas. It sits below the contrast floor by construction, so it carries
        /// ornament — a chevron, a rule, a count beside a fact — and never a fact alone.
        static var tertiaryLabel: NSColor {
            ThemePalette.blended(\.textDim, toward: \.canvas, 0.35, system: .tertiaryLabelColor)
        }
        static var separator: NSColor { ThemePalette.color(\.rule, system: .separatorColor) }
        static var canvas: NSColor { ThemePalette.color(\.canvas, system: .textBackgroundColor) }
        /// Every raised content surface: cards, code blocks, gauge tracks, chips.
        static var canvasRaised: NSColor {
            ThemePalette.color(\.canvasRaised, system: .quaternarySystemFill)
        }
        static var codeBackground: NSColor {
            ThemePalette.color(\.codeBg, system: .quaternarySystemFill)
        }
        static var subagentBackground: NSColor {
            ThemePalette.color(\.subagentBg, system: .quinarySystemFill)
        }
        static var accent: NSColor { ThemePalette.color(\.accent, system: .controlAccentColor) }
        /// Affirmation. A palette spends one colour on motion and affirmation together, so under a
        /// theme a finished step and a running one are the same hue and are told apart by their
        /// glyph — which is the contract the desktop has always kept.
        static var success: NSColor { ThemePalette.color(\.accent, system: .systemGreen) }
        static var warning: NSColor { ThemePalette.color(\.warn, system: .systemOrange) }
        static var danger: NSColor { ThemePalette.color(\.danger, system: .systemRed) }
        /// Identity of what the agent touched — subagents, tools, files, modes.
        static var info: NSColor { ThemePalette.color(\.info, system: .systemIndigo) }
        /// Standing marks on a conversation — the goal, a compaction seam, a saved chat.
        static var mark: NSColor { ThemePalette.color(\.special, system: .systemPurple) }
        /// Ink on a signal fill. Never white: on a light palette the canvas is the ink, and the
        /// pairing is one of the seventeen rules `Palette.contrastContract` proves.
        static var onAccent: NSColor { ThemePalette.color(\.onAccent, system: .white) }
        static var findHit: NSColor {
            ThemePalette.color(\.findHit, system: NSColor.systemYellow.withAlphaComponent(0.35))
        }
        /// One colour per syntax role, on the same mapping the other two clients draw from — a
        /// keyword is the standing mark, a name is an identity, a diff reuses addition and
        /// subtraction. "System" has no palette to derive from and falls back to the platform's
        /// own colours rather than to a stock syntax theme.
        static func syntax(_ role: SyntaxRole) -> NSColor {
            ThemePalette.syntax(role, system: systemSyntax(role))
        }

        /// The same role over one of a diff's washed lines, corrected against that wash rather
        /// than the plain code background.
        static func syntax(_ role: SyntaxRole, on kind: DiffLineKind) -> NSColor {
            ThemePalette.syntax(role, on: kind, system: systemSyntax(role))
        }

        /// The field an added or removed diff line sits on — the same accent and danger its +N/−N
        /// labels wear, washed nearly into the code background.
        static func diffBackground(_ kind: DiffLineKind) -> NSColor {
            switch kind {
            case .added:
                return ThemePalette.diffBackground(
                    .added, system: NSColor.systemGreen.withAlphaComponent(0.16))
            case .removed:
                return ThemePalette.diffBackground(
                    .removed, system: NSColor.systemRed.withAlphaComponent(0.16))
            case .context, .hunk, .meta, .note: return .clear
            }
        }

        private static func systemSyntax(_ role: SyntaxRole) -> NSColor {
            switch role {
            case .plain: return .labelColor
            case .keyword, .attribute: return .systemPink
            case .type, .function: return .systemTeal
            case .string: return .systemOrange
            case .number: return .systemPurple
            case .comment: return .secondaryLabelColor
            case .added: return .systemGreen
            case .removed: return .systemRed
            }
        }
        static var claude: NSColor {
            ThemePalette.color(
                \.brandClaude,
                system: NSColor(
                    name: nil,
                    dynamicProvider: { appearance in
                        appearance.isDark
                            ? NSColor(red: 0.90, green: 0.55, blue: 0.42, alpha: 1)
                            : NSColor(red: 0.80, green: 0.42, blue: 0.29, alpha: 1)
                    }))
        }
        static var opencode: NSColor {
            ThemePalette.color(\.brandOpencode, system: .systemTeal)
        }

        /// A model family's hue and an effort's heat, from the shared catalog: the theme's canvas
        /// corrects them when a theme is on, and the platform's own light and dark grounds do when
        /// it is not. A family the catalog does not recognise keeps the secondary register.
        static func modelFamily(_ family: ModelTint.Family?) -> NSColor {
            modelIdentity(family: family, name: nil)
        }

        /// The family's authored hue, or — for a model outside the catalog — the stable hue its
        /// own name hashes to, so an opencode fleet of qwens and glms is a spread of colours
        /// rather than a column of grey. No name at all keeps the secondary register.
        static func modelIdentity(_ chip: ModelChip) -> NSColor {
            modelIdentity(family: chip.family, name: chip.name)
        }

        private static func modelIdentity(family: ModelTint.Family?, name: String?) -> NSColor {
            NSColor(name: nil) { appearance in
                let dark = appearance.isDark
                guard family != nil || name != nil else { return .secondaryLabelColor }
                let canvas =
                    ThemePalette.palette(themeID: ThemeSelection.themeID, dark: dark)?.canvas
                    ?? systemCanvas(dark: dark)
                let hex = ModelTint.identityHex(
                    family: family, name: name ?? "", onCanvas: canvas, isDark: dark)
                return NSColor(hex: hex) ?? .secondaryLabelColor
            }
        }

        static func modelEffort(_ effort: String) -> NSColor? {
            guard ModelTint.authoredEffortHex(effort) != nil else { return nil }
            return NSColor(name: nil) { appearance in
                let dark = appearance.isDark
                let canvas =
                    ThemePalette.palette(themeID: ThemeSelection.themeID, dark: dark)?.canvas
                    ?? systemCanvas(dark: dark)
                guard let hex = ModelTint.effortHex(effort, onCanvas: canvas) else {
                    return .secondaryLabelColor
                }
                return NSColor(hex: hex) ?? .secondaryLabelColor
            }
        }

        static func modelRainbowLetter(_ index: Int, of count: Int) -> NSColor {
            NSColor(name: nil) { appearance in
                let dark = appearance.isDark
                let canvas =
                    ThemePalette.palette(themeID: ThemeSelection.themeID, dark: dark)?.canvas
                    ?? systemCanvas(dark: dark)
                let letters = ModelTint.rainbow(letters: count, onCanvas: canvas)
                guard letters.indices.contains(index) else { return .labelColor }
                return NSColor(hex: letters[index]) ?? .labelColor
            }
        }

        private static func systemCanvas(dark: Bool) -> String {
            dark ? "#1e1e1e" : "#ffffff"
        }

        /// Ink for anything that sits *on* a pane of glass. Glass flips between light and dark on
        /// its own, against whatever content is behind it and regardless of what the app decided it
        /// was, and AppKit derives the material's vibrancy from these colours in particular — a
        /// palette hex here would neither flip nor gain vibrancy.
        static let onGlass = NSColor.labelColor
        static let onGlassSecondary = NSColor.secondaryLabelColor

        static func brand(_ agent: AgentType) -> NSColor {
            agent == .claudeCode ? claude : opencode
        }
    }

    enum Spacing {
        static let xs: CGFloat = 4
        static let s: CGFloat = 8
        static let m: CGFloat = 12
        static let l: CGFloat = 16
        static let xl: CGFloat = 24
    }

    enum Radius {
        static let control: CGFloat = 10
        static let card: CGFloat = 14
    }

    enum Font {
        static func body() -> NSFont { .systemFont(ofSize: 13 * UIScale.factor) }
        static func emphasis() -> NSFont {
            .systemFont(ofSize: 13 * UIScale.factor, weight: .semibold)
        }
        static func caption() -> NSFont { .systemFont(ofSize: 11 * UIScale.factor) }
        static func mono(_ size: CGFloat = 12) -> NSFont {
            .monospacedSystemFont(ofSize: size * UIScale.factor, weight: .regular)
        }
    }

    /// The shared ramp resolved into AppKit, scaled by the window's own type preference.
    ///
    /// A Mac has no Dynamic Type, so `UIScale.factor` is what grows the ramp — the same knob the
    /// desktop already had, now applied to a role's size rather than to a handful of token faces.
    /// Tracking and leading are attributes rather than font properties here too, so a label that
    /// must carry them takes `attributes(_:)` and everything else takes `font(_:)`.
    enum Ramp {
        /// What one unit of the ramp is worth in points, per axis: the Mac's own 13pt body for
        /// prose, a step below for the chrome of a list, and a step below that for monospace, whose
        /// every glyph is an em and so reads larger at the same size.
        private static func base(_ axis: TypeAxis) -> Double {
            switch axis {
            case .prose: return 14
            case .chrome: return 14
            case .mono: return 13.5
            }
        }

        static func font(_ role: TypeRole) -> NSFont {
            let spec = Typography.spec(role)
            let size = CGFloat(spec.size(base: base(spec.axis), scale: Double(UIScale.factor)))
            let weight = weight(spec.weight)
            let face: NSFont =
                switch spec.family {
                case .mono: .monospacedSystemFont(ofSize: size, weight: weight)
                case .prose, .canvas: .systemFont(ofSize: size, weight: weight)
                }
            let faced = spec.italic ? italic(face) : face
            guard spec.figures == .tabular else { return faced }
            return NSFont(
                descriptor: faced.fontDescriptor.addingAttributes([
                    .featureSettings: [[
                        NSFontDescriptor.FeatureKey.typeIdentifier: kNumberSpacingType,
                        NSFontDescriptor.FeatureKey.selectorIdentifier: kMonospacedNumbersSelector,
                    ]]
                ]), size: size) ?? faced
        }

        static func attributes(
            _ role: TypeRole, color: NSColor = MacTheme.Color.label,
            alignment: NSTextAlignment = .natural
        ) -> [NSAttributedString.Key: Any] {
            let spec = Typography.spec(role)
            let font = font(role)
            var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
            if spec.tracking != 0 {
                attributes[.tracking] = spec.tracking(forSize: Double(font.pointSize))
            }
            if spec.lineHeight != 1 || alignment != .natural {
                let paragraph = NSMutableParagraphStyle()
                paragraph.alignment = alignment
                if spec.lineHeight != 1 {
                    paragraph.lineHeightMultiple = CGFloat(spec.lineHeight)
                }
                attributes[.paragraphStyle] = paragraph
            }
            return attributes
        }

        private static func italic(_ font: NSFont) -> NSFont {
            let descriptor = font.fontDescriptor.withSymbolicTraits(.italic)
            return NSFont(descriptor: descriptor, size: font.pointSize) ?? font
        }

        private static func weight(_ weight: TypeWeight) -> NSFont.Weight {
            switch weight {
            case .regular: return .regular
            case .medium: return .medium
            case .semibold: return .semibold
            case .bold: return .bold
            }
        }
    }

    /// Type scale as a live, keyboard-driven preference, under the same `tailscode.uiScale` key
    /// the Linux desktop persists. AppKit has no global font DPI knob, so the factor multiplies
    /// the token fonts and the markdown renderer instead — views rebuilt after a step come out
    /// at the new size.
    enum UIScale {
        private static let key = "tailscode.uiScale"

        static var factor: CGFloat {
            let stored = UserDefaults.standard.double(forKey: key)
            return stored == 0 ? 1.0 : CGFloat(stored)
        }

        static func step(_ delta: Double) {
            let next = min(2.0, max(0.6, ((Double(factor) + delta) * 10).rounded() / 10))
            UserDefaults.standard.set(next, forKey: key)
        }

        static func reset() {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    /// Where the theme is installed, which is nowhere near the glass.
    ///
    /// Liquid Glass is a material: it samples the content beneath it and derives its own light or
    /// dark register, its tone range and its vibrancy from what it finds. The way a palette reaches
    /// the composer's capsule is that the transcript behind it went warm. Nothing here paints a
    /// material, and no palette slot maps to one.
    ///
    /// The Mac has no `window.tintColor` — `controlAccentColor` is read-only and the user's system
    /// accent replaces an app's — so the accent reaches AppKit's own controls per control, and only
    /// where the app was already colouring one. Under "System" none of that runs and the window is
    /// the plain AppKit window it has always been.
    @MainActor
    enum Chrome {
        /// Posted after the palette has changed and the tokens have been rebuilt. The window
        /// listens and restyles itself the way it does for a change of type scale, because AppKit
        /// has no trait to invalidate and a `CGColor` in a layer will otherwise keep the colour it
        /// was born with.
        static let didRepaint = Notification.Name("tailscode.mac.theme.didRepaint")

        static func apply() {
            ThemePalette.invalidate()
            NSApp?.appearance = appearance
            for window in NSApp?.windows ?? [] { window.appearance = appearance }
            NotificationCenter.default.post(name: didRepaint, object: nil)
        }

        static func adopt(_ window: NSWindow) {
            window.appearance = appearance
        }

        /// Which of the theme's two faces to wear. Nothing pinned is `nil`, which is AppKit's own
        /// way of saying "follow the system" — and the palette face is then read back off the
        /// appearance that results, so the canvas and the glass can never disagree about which one
        /// is in force.
        static var appearance: NSAppearance? {
            switch ThemeSelection.appearance.pinnedDark {
            case .some(true): return NSAppearance(named: .darkAqua)
            case .some(false): return NSAppearance(named: .aqua)
            case .none: return nil
            }
        }
    }

    /// Liquid Glass, used the way the system uses it: floating controls above content — the
    /// composer, the status capsule, the jump button — are glass; the content they float over is
    /// flat and opaque. Glass never sits on glass, and prose never sits on glass.
    static func glass(around content: NSView, cornerRadius: CGFloat = Radius.card) -> NSGlassEffectView {
        let view = NSGlassEffectView()
        view.cornerRadius = cornerRadius
        view.contentView = content
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }

    static func tintedGlass(
        around content: NSView, tint: NSColor, cornerRadius: CGFloat = Radius.card
    ) -> NSGlassEffectView {
        let view = glass(around: content, cornerRadius: cornerRadius)
        view.tintColor = tint.withAlphaComponent(0.35)
        return view
    }

    /// Neighbouring glass shapes that should read as one wet surface — the composer row's field
    /// and buttons — go in a container, which also lets the system merge them when they touch.
    static func glassGroup(spacing: CGFloat = Spacing.s) -> NSGlassEffectContainerView {
        let view = NSGlassEffectContainerView()
        view.spacing = spacing
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }
}

extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}
