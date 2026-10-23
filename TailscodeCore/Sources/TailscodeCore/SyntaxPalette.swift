import Foundation

/// A role's colour, taken from the palette the app is already wearing rather than from a stock
/// syntax theme. Every slot keeps the meaning it has everywhere else — `special` is the standing
/// mark, so it is what a keyword wears; `info` is identity, so it is what a name wears; `accent`
/// and `danger` are addition and subtraction, so a diff needs no colours of its own — which is why
/// seven themes and their fourteen faces all highlight code without a single hex being authored
/// twice, and why a theme that changes stays coherent inside a code block too.
///
/// Nothing here reaches for `accent` outside a diff: the stream cascade heats freshly written text
/// toward `accent`, and a keyword permanently wearing the colour of "this just arrived" would make
/// the wave unreadable.
public enum SyntaxPalette {
    /// The published colour for a role on this palette's code background, corrected the same way
    /// every other slot is: readable text clears 4.5:1, comments are deliberately quiet and clear
    /// 3:1, and a hue that cannot reach its bar falls back to the text register rather than
    /// shipping as something no one can read.
    public static func hex(_ role: SyntaxRole, in palette: Palette) -> String {
        hex(role, in: palette, on: palette.codeBg)
    }

    /// The ground an added or removed line sits on: the same accent and danger the diff's own
    /// +N/−N labels wear, washed most of the way into the code background rather than worn as
    /// ink. The line's identity survives as a field of colour, which frees the foreground for the
    /// language — a diff stays unmistakably a diff while the code on it reads as code.
    public static func diffLineBackground(_ kind: DiffLineKind, in palette: Palette) -> String? {
        switch kind {
        case .added: return Contrast.blend(palette.accent, palette.codeBg, 0.85)
        case .removed: return Contrast.blend(palette.danger, palette.codeBg, 0.85)
        case .context, .hunk, .meta, .note: return nil
        }
    }

    /// The same derivation against a different ground — a diff line's wash — so ink on a tinted
    /// line is corrected by the same arithmetic as ink on the plain block, rather than trusting
    /// that a colour readable on one canvas survives a canvas that moved toward it.
    public static func hex(_ role: SyntaxRole, in palette: Palette, on background: String) -> String {
        switch role {
        case .plain:
            return corrected(palette.text, on: background)
        case .keyword, .attribute:
            return corrected(palette.special, on: background)
        case .type, .function:
            return corrected(palette.info, on: background)
        case .string:
            return corrected(palette.warn, on: background)
        case .number:
            return corrected(palette.accentDim, on: background)
        case .comment:
            let quiet = Contrast.blend(palette.textDim, background, 0.3) ?? palette.textDim
            return Contrast.adjusted(quiet, on: background, ratio: Contrast.secondary)
                ?? palette.textDim
        case .added:
            return corrected(palette.accent, on: background)
        case .removed:
            return corrected(palette.danger, on: background)
        }
    }

    /// Every role's colour for one palette, for a client that builds its colour table once per
    /// theme rather than per token.
    public static func table(for palette: Palette) -> [SyntaxRole: String] {
        table(for: palette, on: palette.codeBg)
    }

    /// The same table against a chosen ground, for a client colouring the code on a diff's added
    /// or removed wash.
    public static func table(for palette: Palette, on background: String) -> [SyntaxRole: String] {
        var table: [SyntaxRole: String] = [:]
        for role in SyntaxRole.allCases { table[role] = hex(role, in: palette, on: background) }
        return table
    }

    private static func corrected(_ hex: String, on background: String) -> String {
        Contrast.adjusted(hex, on: background, ratio: Contrast.readable) ?? hex
    }
}
