import Foundation

extension NeuralShare {
    /// The app's own `Palette` for the head and its nodes on a poster of this look.
    ///
    /// The head's glow is made from a `Palette`, while a poster look is the analytics card's
    /// smaller set of slots, so a look is widened to a palette by taking every slot it names and
    /// the failure colour from the app's default theme. The look that follows the app answers with
    /// the app's own palette, which is what the chat's brain is drawn from.
    public static func headPalette(style: CardStyle, dark: Bool) -> Palette {
        let base = AppTheme.fallback.palette(dark: dark).corrected()
        guard style.authored != nil else {
            return ThemeSelection.usesSystemPalette
                ? base : ThemeSelection.palette(dark: dark)
        }
        let share = style.palette(dark: dark)
        let isDark = (Contrast.luminance(share.canvas) ?? 0) <= 0.4
        return Palette(
            name: style.name, isDark: isDark, canvas: share.canvas, canvasRaised: share.raised,
            rule: share.rule, text: share.text, textDim: share.textDim, accent: share.accent,
            accentDim: share.accent, warn: share.warn, danger: base.danger, info: share.info,
            special: share.special, codeBg: share.raised, subagentBg: share.raised,
            findHit: share.warn, ansi: base.ansi
        ).corrected()
    }
}
