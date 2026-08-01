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
        static func body() -> NSFont { .systemFont(ofSize: 13) }
        static func emphasis() -> NSFont { .systemFont(ofSize: 13, weight: .semibold) }
        static func caption() -> NSFont { .systemFont(ofSize: 11) }
        static func mono(_ size: CGFloat = 12) -> NSFont {
            .monospacedSystemFont(ofSize: size, weight: .regular)
        }
    }

    /// Glass where the system has it, and a correctly-configured visual effect view where it does
    /// not. `blendingMode` and `state` are set explicitly on purpose: the defaults blur the desktop
    /// through the window rather than the content behind the bar, and desaturate the moment the
    /// window stops being key.
    static func chromeBackdrop() -> NSView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .withinWindow
        view.state = .active
        return view
    }
}

extension NSAppearance {
    var isDark: Bool {
        bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }
}
