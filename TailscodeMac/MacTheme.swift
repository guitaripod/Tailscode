import AppKit
import CodingAgentKit

/// The desktop half of the design tokens. Values are the same numbers the iOS `Theme` uses; only
/// the types differ. Chrome is material and quiet, the transcript is flat and opaque — the two
/// never borrow each other's surfaces.
enum MacTheme {
    enum Color {
        static let label = NSColor.labelColor
        static let secondaryLabel = NSColor.secondaryLabelColor
        static let tertiaryLabel = NSColor.tertiaryLabelColor
        static let separator = NSColor.separatorColor
        static let canvas = NSColor.textBackgroundColor
        static let accent = NSColor.controlAccentColor
        static let success = NSColor.systemGreen
        static let warning = NSColor.systemOrange
        static let danger = NSColor.systemRed
        /// Identity of what the agent touched — subagents, tools, files, modes.
        static let info = NSColor.systemIndigo
        /// Standing marks on a conversation — the goal, a compaction seam, a saved chat.
        static let mark = NSColor.systemPurple
        static let claude = NSColor(
            name: nil,
            dynamicProvider: { appearance in
                appearance.isDark
                    ? NSColor(red: 0.90, green: 0.55, blue: 0.42, alpha: 1)
                    : NSColor(red: 0.80, green: 0.42, blue: 0.29, alpha: 1)
            })
        static let opencode = NSColor.systemTeal

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
