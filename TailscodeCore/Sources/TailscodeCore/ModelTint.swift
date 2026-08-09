import Foundation

/// A model's identity as a colour, so a list is scanned rather than read.
///
/// Two facts follow a conversation everywhere its model is named: which family is answering, and
/// how hard it was asked to think. The family is an identity, so it gets one authored hue — the
/// same hue on every desk — published the way the brand colours are: corrected in OKLab against
/// the canvas it will sit on, hue and chroma kept, lightness moved only where it had to be. The
/// effort is a magnitude, not an identity, so it wears heat instead — cold slate through teal and
/// amber to vermilion — and ultracode, which is a power rather than a level, wears the rainbow it
/// already owns. A model outside the known families keeps the quiet register: an identity is
/// recognised, never invented.
public enum ModelTint {
    public enum Family: String, CaseIterable, Sendable {
        case fable, opus, sonnet, haiku, grok, gpt, gemini
    }

    public static func family(_ raw: String) -> Family? {
        let id = raw.lowercased()
        if id.contains("fable") || id.contains("mythos") { return .fable }
        for family in Family.allCases where id.contains(family.rawValue) {
            return family
        }
        return nil
    }

    /// The authored hue: what the family's colour *is*, before any canvas has a say. Fable wears
    /// Claude's terracotta — the flagship carries the brand — and Grok is xAI's monochrome, silver
    /// in the dark and ink in the light, which is the one hue that has to know the appearance.
    public static func authoredHex(_ family: Family, isDark: Bool) -> String {
        switch family {
        case .fable: return "#d97757"
        case .opus: return "#a78bfa"
        case .sonnet: return "#38bdf8"
        case .haiku: return "#3fc47c"
        case .grok: return isDark ? "#e8e8eb" : "#1f1f1f"
        case .gpt: return "#10a37f"
        case .gemini: return "#4285f4"
        }
    }

    /// The effort's heat, authored once for every desk: minimal and low are the same cold slate —
    /// both mean "quickly" — and the scale ends at vermilion because max is the hottest a *level*
    /// goes. Ultracode is not on the scale; it has ``rainbow(letters:onCanvas:)``. An effort word
    /// nobody authored a heat for answers nil and keeps the quiet register.
    public static func authoredEffortHex(_ effort: String) -> String? {
        switch effort.lowercased() {
        case "minimal", "none", "low": return "#8494a6"
        case "medium": return "#3aa8a0"
        case "high": return "#d9a13c"
        case "xhigh": return "#ee8434"
        case "max": return "#f25c3f"
        default: return nil
        }
    }

    public static func hex(_ family: Family, in palette: Palette) -> String {
        hex(family, onCanvas: palette.canvas, isDark: palette.isDark)
    }

    public static func hex(_ family: Family, onCanvas canvas: String, isDark: Bool) -> String {
        published(authoredHex(family, isDark: isDark), on: canvas)
    }

    public static func effortHex(_ effort: String, in palette: Palette) -> String? {
        effortHex(effort, onCanvas: palette.canvas)
    }

    public static func effortHex(_ effort: String, onCanvas canvas: String) -> String? {
        authoredEffortHex(effort).map { published($0, on: canvas) }
    }

    /// One colour per letter of the ultracode word, sampled evenly around the shared rainbow and
    /// then held to the same contrast floor as any other fact on this canvas — a rainbow that
    /// cannot be read is a decoration, and ultracode is a state.
    public static func rainbow(letters count: Int, onCanvas canvas: String) -> [String] {
        guard count > 0 else { return [] }
        let stops = Ultracode.rainbowStops
        return (0..<count).map { index in
            let position =
                count == 1
                ? 0 : Double(index) / Double(count - 1) * Double(stops.count - 1)
            let lower = min(stops.count - 1, Int(position))
            let upper = min(stops.count - 1, lower + 1)
            let amount = position - Double(lower)
            let red = stops[lower].red + (stops[upper].red - stops[lower].red) * amount
            let green = stops[lower].green + (stops[upper].green - stops[lower].green) * amount
            let blue = stops[lower].blue + (stops[upper].blue - stops[lower].blue) * amount
            return published(Contrast.hex(red: red, green: green, blue: blue), on: canvas)
        }
    }

    /// The style class a text client hangs the colour on, generated per palette by its stylesheet.
    public static func cssClass(_ family: Family) -> String { "model-\(family.rawValue)" }

    public static func effortClass(_ effort: String) -> String? {
        if effort.lowercased() == Ultracode.effortLevel { return "effort-ultracode" }
        switch authoredEffortHex(effort) {
        case nil: return nil
        default: return "effort-\(canonicalEffort(effort))"
        }
    }

    /// The tiers the stylesheet authors classes for, keyed by their canonical names — minimal and
    /// none fold into low, because they share its slate and a class per synonym is noise.
    public static let effortTiers = ["low", "medium", "high", "xhigh", "max"]

    private static func canonicalEffort(_ effort: String) -> String {
        switch effort.lowercased() {
        case "minimal", "none": return "low"
        default: return effort.lowercased()
        }
    }

    private static func published(_ hex: String, on canvas: String) -> String {
        Contrast.adjusted(hex, on: canvas, ratio: Contrast.readable) ?? hex
    }
}
