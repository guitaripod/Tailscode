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
        case qwen, deepseek, llama, mistral
        case glm, kimi, minimax, gemma, phi, command
    }

    /// Read from the same table as the catalog's sections (``ModelNeedles``), against the id's
    /// last path segment, because a provider prefix is not a family: `ollama/glm-4.7-air` must
    /// not wear Llama's blue for the crime of being served by ollama. Claude's members are worn
    /// only by a model that is Claude's — see ``family(_:providerID:)``.
    public static func family(_ raw: String) -> Family? {
        ModelNeedles.tint(raw)
    }

    /// The family with the door the model runs through, which settles Claude outright: an
    /// `anthropic` door is Claude whatever its alias, and no other door borrows Claude's words.
    public static func family(_ raw: String, providerID: String?) -> Family? {
        ModelNeedles.tint(raw, providerID: providerID)
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
        case .qwen: return "#7a5af5"
        case .deepseek: return "#4d6bfe"
        case .llama: return "#1877f2"
        case .mistral: return "#f2620f"
        case .glm: return "#c65bd6"
        case .kimi: return "#a3e635"
        case .minimax: return "#f0507e"
        case .gemma: return "#b8c4ff"
        case .phi: return "#e4e44b"
        case .command: return "#ff9ec7"
        }
    }

    /// A model outside the authored families still deserves to be told apart in a list: its name
    /// is hashed onto one of twelve evenly spaced hues, so `hunyuan` is the same colour on every desk
    /// and in every palette without anyone having authored an identity for it. The hash is its
    /// own (djb2) rather than the language's, whose hashing is salted per process — a colour that
    /// changed on every launch would read as a different model.
    public static func hueBucket(_ name: String) -> Int {
        var hash: UInt32 = 5381
        for byte in name.lowercased().utf8 {
            hash = hash &* 33 &+ UInt32(byte)
        }
        return Int(hash % 12)
    }

    public static func bucketHex(_ bucket: Int) -> String {
        let hue = Double((bucket % 12 + 12) % 12) * 30
        return hsl(hue: hue, saturation: 0.58, lightness: 0.60)
    }

    public static func bucketHex(_ bucket: Int, in palette: Palette) -> String {
        published(bucketHex(bucket), on: palette.canvas)
    }

    private static func hsl(hue: Double, saturation: Double, lightness: Double) -> String {
        let c = (1 - abs(2 * lightness - 1)) * saturation
        let x = c * (1 - abs((hue / 60).truncatingRemainder(dividingBy: 2) - 1))
        let m = lightness - c / 2
        let (r, g, b): (Double, Double, Double) =
            switch Int(hue / 60) % 6 {
            case 0: (c, x, 0)
            case 1: (x, c, 0)
            case 2: (0, c, x)
            case 3: (0, x, c)
            case 4: (x, 0, c)
            default: (c, 0, x)
            }
        return Contrast.hex(red: r + m, green: g + m, blue: b + m)
    }

    /// The effort's heat, authored once for every desk: minimal and low are the same cold slate —
    /// both mean "quickly" — and the scale ends at vermilion because max is the hottest a *level*
    /// goes. Ultracode is not on the scale; it has ``rainbow(letters:onCanvas:)``. An effort word
    /// nobody authored a heat for answers nil and keeps the quiet register. The colour follows the
    /// word's tier (`EffortVocabulary`), so a local model's think wears medium's teal and its
    /// nothink the slate under low.
    public static func authoredEffortHex(_ effort: String) -> String? {
        guard let tier = ModelDial.rank(effort) else { return nil }
        switch tier {
        case ...1: return "#8494a6"
        case 2: return "#3aa8a0"
        case 3: return "#d9a13c"
        case 4: return "#ee8434"
        default: return "#f25c3f"
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

    /// The one identity resolver every chip reads: an authored hue for a recognised family, the
    /// name's own bucketed hue for everyone else, so no model is ever left grey merely for being
    /// outside the famous few.
    public static func identityClass(family: Family?, name: String) -> String {
        family.map(cssClass) ?? "model-hue-\(hueBucket(name))"
    }

    public static func identityHex(
        family: Family?, name: String, onCanvas canvas: String, isDark: Bool
    ) -> String {
        published(family.map { authoredHex($0, isDark: isDark) } ?? bucketHex(hueBucket(name)), on: canvas)
    }

    public static func identityHex(family: Family?, name: String, in palette: Palette) -> String {
        identityHex(family: family, name: name, onCanvas: palette.canvas, isDark: palette.isDark)
    }

    public static func effortClass(_ effort: String) -> String? {
        if ModelDial.isPower(effort) { return "effort-ultracode" }
        guard let tier = ModelDial.rank(effort) else { return nil }
        return "effort-" + effortTiers[max(0, min(effortTiers.count - 1, tier - 1))]
    }

    /// The tiers the stylesheet authors classes for, keyed by their canonical names — every word
    /// folds into its tier's class, the floor under low into low's, because they share its slate
    /// and a class per synonym is noise.
    public static let effortTiers = ["low", "medium", "high", "xhigh", "max"]

    private static func published(_ hex: String, on canvas: String) -> String {
        Contrast.adjusted(hex, on: canvas, ratio: Contrast.readable) ?? hex
    }
}
