import Foundation

/// The colours a terminal draws in, as the engine takes them: 0xRRGGBB.
///
/// A terminal wears the theme like the rest of the window, and its sixteen named colours stay
/// exactly as the theme published them: what runs inside it chose those names expecting them to
/// mean something.
public struct TerminalColors: Sendable, Equatable {
    public var foreground: UInt32
    public var background: UInt32
    public var cursor: UInt32
    public var ansi: [UInt32]
    public var selectionForeground: UInt32
    public var selectionBackground: UInt32
    public var isDark: Bool

    public init(
        foreground: UInt32, background: UInt32, cursor: UInt32, ansi: [UInt32],
        selectionForeground: UInt32, selectionBackground: UInt32, isDark: Bool
    ) {
        self.foreground = foreground
        self.background = background
        self.cursor = cursor
        self.ansi = ansi
        self.selectionForeground = selectionForeground
        self.selectionBackground = selectionBackground
        self.isDark = isDark
    }

    /// A selection is the theme's accent laid under the text at a strength that leaves every
    /// colour on top of it readable, so the text keeps the terminal's own ink.
    public init(palette: Palette) {
        let foreground = Self.rgb(palette.terminalFg) ?? 0xd0d0d0
        let background = Self.rgb(palette.terminalBg) ?? 0x101010
        let accent = Self.rgb(palette.accent) ?? foreground
        self.init(
            foreground: foreground, background: background, cursor: accent,
            ansi: palette.ansi.prefix(16).map { Self.rgb($0) ?? foreground },
            selectionForeground: foreground,
            selectionBackground: Self.mix(accent, into: background, by: 0.38),
            isDark: palette.isDark)
    }

    /// A terminal for a client wearing the system's own colours, which has no palette to read:
    /// the terminal every desk already knows, light or dark.
    public static func plain(dark: Bool) -> TerminalColors {
        let ansi: [UInt32] =
            dark
            ? [
                0x1c1c1e, 0xff453a, 0x32d74b, 0xffd60a, 0x0a84ff, 0xbf5af2, 0x64d2ff, 0xd1d1d6,
                0x636366, 0xff6961, 0x4cd964, 0xffe55c, 0x409cff, 0xda8fff, 0x8ee5ff, 0xffffff,
            ]
            : [
                0x000000, 0xc41a16, 0x1f7a1f, 0x9a6700, 0x0b4fd1, 0x8a2aa8, 0x0e7f8f, 0x8e8e93,
                0x636366, 0xd70015, 0x248a3d, 0xb25000, 0x0040dd, 0xad44ab, 0x0071a4, 0x1c1c1e,
            ]
        let foreground: UInt32 = dark ? 0xe5e5ea : 0x1c1c1e
        let background: UInt32 = dark ? 0x000000 : 0xffffff
        let accent: UInt32 = dark ? 0x0a84ff : 0x007aff
        return TerminalColors(
            foreground: foreground, background: background, cursor: accent, ansi: ansi,
            selectionForeground: foreground, selectionBackground: mix(accent, into: background, by: 0.38),
            isDark: dark)
    }

    /// `#rrggbb` or `#rgb` as a number.
    public static func rgb(_ hex: String) -> UInt32? {
        var digits = Substring(hex)
        if digits.hasPrefix("#") { digits = digits.dropFirst() }
        if digits.count == 3 { digits = Substring(digits.flatMap { [$0, $0] }) }
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        return value
    }

    public static func mix(_ colour: UInt32, into base: UInt32, by amount: Double) -> UInt32 {
        func channel(_ shift: UInt32) -> UInt32 {
            let over = Double((colour >> shift) & 0xff)
            let under = Double((base >> shift) & 0xff)
            return UInt32((under + (over - under) * min(max(amount, 0), 1)).rounded())
        }
        return channel(16) << 16 | channel(8) << 8 | channel(0)
    }
}
