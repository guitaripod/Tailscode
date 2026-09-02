import Foundation

/// The looks a share card can wear, authored for a poster rather than for a window.
///
/// The app's themes are tuned for hours of reading — quiet canvases, accents that never shout.
/// A card is looked at for three seconds in somebody else's feed, so it may be louder: a canvas
/// that falls through a gradient, one accent that carries, ink that stays readable at a glance.
/// Every style is *authored* here and *published* through ``published``, which walks any slot
/// that cannot be read on its own canvas in lightness until it can — a style that cannot be made
/// readable fails the build rather than shipping as a picture nobody can read.
///
/// The first style is not a palette but a pointer: the card wears whatever the app is wearing,
/// which is what it did before there was a choice.
public struct CardStyle: Sendable, Equatable, Identifiable {
    public let id: String
    public let name: String
    /// One line on what it is for, for a menu that has room for it.
    public let tagline: String
    /// Nil for the style that follows the app's own theme.
    public let authored: AnalyticsShare.Palette?

    public static let appID = "app"

    public static let app = CardStyle(
        id: appID, name: Localized.text("Match the app"),
        tagline: Localized.text("Whatever theme the app is wearing"), authored: nil)

    public static let midnight = CardStyle(
        id: "midnight", name: Localized.text("Midnight"),
        tagline: Localized.text("Deep navy, mint ink"),
        authored: .init(
            canvas: "#0b0f1a", canvasEnd: "#151c30", text: "#eef2ff", textDim: "#9ea8cc",
            accent: "#7cf5c8", info: "#8ab4ff", warn: "#ffcf6b", special: "#c9a2ff"))

    public static let aurora = CardStyle(
        id: "aurora", name: Localized.text("Aurora"),
        tagline: Localized.text("Teal falling into violet"),
        authored: .init(
            canvas: "#06191f", canvasEnd: "#171242", text: "#e9fbff", textDim: "#93bcc8",
            accent: "#4ff0b0", info: "#57c7ff", warn: "#ffd166", special: "#b98bff"))

    public static let ember = CardStyle(
        id: "ember", name: Localized.text("Ember"),
        tagline: Localized.text("Charcoal and tangerine"),
        authored: .init(
            canvas: "#170a0d", canvasEnd: "#2f1410", text: "#fff1ea", textDim: "#c9a196",
            accent: "#ff7a45", info: "#ffb86b", warn: "#ffd76a", special: "#ff8fa3"))

    public static let neon = CardStyle(
        id: "neon", name: Localized.text("Neon"),
        tagline: Localized.text("Black, hot pink, cyan"),
        authored: .init(
            canvas: "#050508", canvasEnd: "#160b26", text: "#f7f7ff", textDim: "#a49bc2",
            accent: "#ff3ea5", info: "#2ee6ff", warn: "#ffe14d", special: "#a66bff"))

    public static let ocean = CardStyle(
        id: "ocean", name: Localized.text("Ocean"),
        tagline: Localized.text("Deep water, aqua light"),
        authored: .init(
            canvas: "#04182a", canvasEnd: "#0b3457", text: "#e6f6ff", textDim: "#95b9d3",
            accent: "#37e0d0", info: "#62b6ff", warn: "#ffd36e", special: "#9ec1ff"))

    public static let gold = CardStyle(
        id: "gold", name: Localized.text("Gold"),
        tagline: Localized.text("Dark bronze and gold leaf"),
        authored: .init(
            canvas: "#15100a", canvasEnd: "#2e2210", text: "#fff8e6", textDim: "#c6b893",
            accent: "#f5c542", info: "#7dd3fc", warn: "#fb923c", special: "#d8b4fe"))

    public static let ink = CardStyle(
        id: "ink", name: Localized.text("Ink"),
        tagline: Localized.text("Black and white, nothing else"),
        authored: .init(
            canvas: "#000000", canvasEnd: "#141414", text: "#ffffff", textDim: "#a3a3a3",
            accent: "#ffffff", info: "#8c8c8c", warn: "#d4d4d4", special: "#bfbfbf"))

    public static let paper = CardStyle(
        id: "paper", name: Localized.text("Paper"),
        tagline: Localized.text("Warm cream, terracotta ink"),
        authored: .init(
            canvas: "#fbf7ef", canvasEnd: "#efe6d4", text: "#1c1a17", textDim: "#6b655a",
            accent: "#c2410c", info: "#1d4ed8", warn: "#b45309", special: "#6d28d9"))

    public static let frost = CardStyle(
        id: "frost", name: Localized.text("Frost"),
        tagline: Localized.text("Ice white, cobalt ink"),
        authored: .init(
            canvas: "#f5f9ff", canvasEnd: "#dfe9f9", text: "#0f172a", textDim: "#52617f",
            accent: "#1d4ed8", info: "#0e7490", warn: "#b45309", special: "#7c3aed"))

    public static let all: [CardStyle] = [
        app, midnight, aurora, ember, neon, ocean, gold, ink, paper, frost,
    ]

    public static func named(_ id: String?) -> CardStyle {
        all.first { $0.id == id } ?? app
    }

    /// The style's colours as the card will actually paint them: every slot readable on both
    /// ends of the canvas it sits on. The app style has no palette of its own and answers with
    /// the app's, or the share default where the app wears System's invisible colours.
    public func palette(dark: Bool) -> AnalyticsShare.Palette {
        guard let authored else {
            return ThemeSelection.usesSystemPalette
                ? .shareDefault : .current(dark: dark)
        }
        return Self.published(authored)
    }

    /// Whether the style paints a light canvas, which is what a swatch and a menu need to know
    /// to draw it against their own ground.
    public var isLight: Bool {
        guard let authored else { return false }
        return (Contrast.luminance(authored.canvas) ?? 0) > 0.4
    }

    public static func published(_ palette: AnalyticsShare.Palette) -> AnalyticsShare.Palette {
        func readable(_ hex: String, ratio: Double) -> String {
            var out = hex
            for ground in [palette.canvas, palette.canvasEnd] {
                out = Contrast.adjusted(out, on: ground, ratio: ratio) ?? out
            }
            return out
        }
        return AnalyticsShare.Palette(
            canvas: palette.canvas, canvasEnd: palette.canvasEnd,
            raised: palette.raised, rule: palette.rule,
            text: readable(palette.text, ratio: 4.5),
            textDim: readable(palette.textDim, ratio: 4.5),
            accent: readable(palette.accent, ratio: 3), info: readable(palette.info, ratio: 3),
            warn: readable(palette.warn, ratio: 3), special: readable(palette.special, ratio: 3),
            onAccent: palette.onAccent)
    }
}

/// Which style the card wears, remembered by id so a style dropped from the catalog falls back
/// rather than repainting somebody's card as the wrong one.
public enum CardStyleSelection {
    public static let storageKey = "tailscode.shareCardStyle"

    public static var current: CardStyle {
        CardStyle.named(UserDefaults.standard.string(forKey: storageKey))
    }

    public static func set(_ style: CardStyle) {
        UserDefaults.standard.set(style.id, forKey: storageKey)
    }
}
