import TailscodeCore
import UIKit

/// The trait the whole app's colour hangs off.
///
/// A theme is not an appearance — it is a second axis beside light and dark — and UIKit has had a
/// place for exactly that since custom traits arrived: declare it, mark it as affecting colour, and
/// every dynamic colour in the process is invalidated and re-resolved the moment the window's
/// override changes. That is what makes picking a theme repaint the app that is already on screen
/// without a single view being rebuilt, and it is why nothing here posts a "reload everything".
struct ThemeIdentityTrait: UITraitDefinition {
    static let defaultValue = ThemeSelection.systemID
    static let identifier = "com.tailscode.theme"
    static let affectsColorAppearance = true
}

extension UITraitCollection {
    var themeID: String { self[ThemeIdentityTrait.self] }

    /// The palette this trait collection is asking for, or `nil` when the platform's own colours
    /// are in force — which is a real answer, not a missing one.
    var palette: Palette? {
        ThemePalette.palette(themeID: themeID, dark: userInterfaceStyle == .dark)
    }
}

/// The bridge from a theme's hex strings to the colours UIKit draws.
///
/// A token is one `UIColor` for the life of the process whose provider is asked again on every
/// resolve, so the same `Theme.Color.canvas` is Rosé Pine at midnight and Gruvbox in daylight
/// without anything holding a reference having to know. Every token names a system colour to fall
/// back to, because "System" is one of the choices and the app it describes is the one Apple's
/// materials were drawn for.
@MainActor
enum ThemePalette {
    /// `corrected()` walks eleven slots through OKLab, and a resolve happens per colour per view
    /// per trait change. Two palettes per theme is a small enough space to simply keep.
    nonisolated(unsafe) private static var cache: [String: Palette] = [:]
    nonisolated(unsafe) private static let lock = NSLock()

    nonisolated static func palette(themeID: String, dark: Bool) -> Palette? {
        guard themeID != ThemeSelection.systemID else { return nil }
        let key = "\(themeID)/\(dark)"
        lock.lock()
        defer { lock.unlock() }
        if let hit = cache[key] { return hit }
        let made = ThemeSelection.palette(themeID: themeID, dark: dark)
        cache[key] = made
        return made
    }

    /// The palette the app is wearing right now, for code that has to reason about the theme rather
    /// than merely draw in it — the picker's own swatches, the terminal's ANSI table.
    nonisolated static var current: Palette? {
        palette(
            themeID: ThemeSelection.themeID,
            dark: ThemeSelection.appearance.pinnedDark ?? traitDark)
    }

    private nonisolated static var traitDark: Bool {
        UITraitCollection.current.userInterfaceStyle == .dark
    }

    /// A token: the theme's slot when a theme is on, the system's own colour when it is not.
    nonisolated static func color(_ slot: KeyPath<Palette, String> & Sendable, system: UIColor) -> UIColor {
        UIColor { traits in
            guard let palette = traits.palette else { return system.resolvedColor(with: traits) }
            return UIColor(hex: palette[keyPath: slot])
                ?? system.resolvedColor(with: traits)
        }
    }

    /// A token that is a mix of two slots — the third text register, a hairline that has to sit
    /// between the rule and the canvas. Mixed in OKLab, so the step between the two registers is
    /// the one the eye expects rather than the one sRGB arithmetic produces.
    nonisolated static func blended(
        _ slot: KeyPath<Palette, String> & Sendable, toward other: KeyPath<Palette, String> & Sendable, _ amount: Double,
        system: UIColor
    ) -> UIColor {
        UIColor { traits in
            guard let palette = traits.palette,
                let mixed = Contrast.blend(
                    palette[keyPath: slot], palette[keyPath: other], amount),
                let color = UIColor(hex: mixed)
            else { return system.resolvedColor(with: traits) }
            return color
        }
    }

    /// The theme's own colour for a syntax role. Deriving one costs an OKLab walk against the code
    /// background, and a provider is asked again for every glyph run in every visible block, so the
    /// whole table is derived once per palette and kept — the same trade the palette cache makes.
    nonisolated(unsafe) private static var syntaxTables: [String: [SyntaxRole: String]] = [:]

    nonisolated static func syntax(_ role: SyntaxRole, system: UIColor) -> UIColor {
        UIColor { traits in
            guard let palette = traits.palette else { return system.resolvedColor(with: traits) }
            let key = "\(traits.themeID)/\(palette.isDark)"
            lock.lock()
            let table: [SyntaxRole: String]
            if let hit = syntaxTables[key] {
                table = hit
            } else {
                table = SyntaxPalette.table(for: palette)
                syntaxTables[key] = table
            }
            lock.unlock()
            guard let hex = table[role], let color = UIColor(hex: hex) else {
                return system.resolvedColor(with: traits)
            }
            return color
        }
    }

    /// A slot at reduced opacity, for fills that are meant to read as a wash of a signal rather
    /// than the signal itself.
    nonisolated static func color(
        _ slot: KeyPath<Palette, String> & Sendable, alpha: CGFloat, system: UIColor
    ) -> UIColor {
        UIColor { traits in
            guard let palette = traits.palette, let color = UIColor(hex: palette[keyPath: slot])
            else { return system.resolvedColor(with: traits).withAlphaComponent(alpha) }
            return color.withAlphaComponent(alpha)
        }
    }
}

extension UIColor {
    /// A colour from the six-digit hex a palette is written in. sRGB, because that is the space
    /// every published theme's numbers were measured in and `Contrast` scored them in.
    convenience init?(hex: String) {
        guard let channels = Contrast.channels(hex) else { return nil }
        self.init(
            red: CGFloat(channels.red), green: CGFloat(channels.green),
            blue: CGFloat(channels.blue), alpha: 1)
    }
}
