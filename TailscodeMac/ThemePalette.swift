import AppKit
import TailscodeCore

/// The bridge from a theme's hex strings to the colours AppKit draws.
///
/// A token is one `NSColor` built with a dynamic provider, so it answers light and dark from the
/// *same* theme without anything holding it having to know which is in force. What AppKit has no
/// answer for is the second axis: there is no trait for "which theme", so a change of identity is
/// not something the toolkit can invalidate on its own. It is invalidated here, and the window then
/// restyles itself the same way it does for a change of type scale — the caches are dropped and the
/// rows are rebuilt, which is the only mechanism on this platform that reaches everything.
///
/// Every token names the system colour it stands in for. "System" is one of the choices, it is this
/// client's default, and under it nothing below ever runs: the app is exactly the AppKit app it was.
enum ThemePalette {
    private struct Key: Hashable {
        let slot: AnyKeyPath
        let theme: String
    }

    nonisolated(unsafe) private static var colours: [Key: NSColor] = [:]
    nonisolated(unsafe) private static var palettes: [String: Palette] = [:]
    nonisolated(unsafe) private static let lock = NSLock()

    static func palette(themeID: String, dark: Bool) -> Palette? {
        guard themeID != ThemeSelection.systemID else { return nil }
        let key = "\(themeID)/\(dark)"
        lock.lock()
        defer { lock.unlock() }
        if let hit = palettes[key] { return hit }
        let made = ThemeSelection.palette(themeID: themeID, dark: dark)
        palettes[key] = made
        return made
    }

    /// The palette in force, resolved under the window's own appearance — or whatever is being
    /// drawn in when there is no application to ask, which is how `--selftest` reaches it.
    static var current: Palette? {
        palette(themeID: ThemeSelection.themeID, dark: appearance.isDark)
    }

    static var appearance: NSAppearance {
        NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()
    }

    static func color(_ slot: KeyPath<Palette, String> & Sendable, system: NSColor) -> NSColor {
        let key = Key(slot: slot, theme: ThemeSelection.themeID)
        lock.lock()
        if let hit = colours[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        let id = ThemeSelection.themeID
        let made = NSColor(name: nil) { appearance in
            guard let palette = palette(themeID: id, dark: appearance.isDark),
                let colour = NSColor(hex: palette[keyPath: slot])
            else { return system }
            return colour
        }
        lock.lock()
        colours[key] = made
        lock.unlock()
        return made
    }

    /// A slot walked partway into another, for the register AppKit has and a palette does not.
    static func blended(
        _ slot: KeyPath<Palette, String> & Sendable, toward other: KeyPath<Palette, String> & Sendable,
        _ amount: Double, system: NSColor
    ) -> NSColor {
        let id = ThemeSelection.themeID
        return NSColor(name: nil) { appearance in
            guard let palette = palette(themeID: id, dark: appearance.isDark),
                let mixed = Contrast.blend(
                    palette[keyPath: slot], palette[keyPath: other], amount),
                let colour = NSColor(hex: mixed)
            else { return system }
            return colour
        }
    }

    /// Every token is rebuilt against the theme that is now current. The colours already handed
    /// out keep answering for the theme they were made under, which is exactly why the window has
    /// to rebuild what it drew with them.
    static func invalidate() {
        lock.lock()
        colours.removeAll(keepingCapacity: true)
        lock.unlock()
    }
}

extension NSColor {
    /// A colour from the six-digit hex a palette is written in. sRGB, because that is the space
    /// every published theme's numbers were measured in and `Contrast` scored them in.
    convenience init?(hex: String) {
        guard let channels = Contrast.channels(hex) else { return nil }
        self.init(
            srgbRed: CGFloat(channels.red), green: CGFloat(channels.green),
            blue: CGFloat(channels.blue), alpha: 1)
    }
}
