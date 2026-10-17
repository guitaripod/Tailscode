import CAdw
import Foundation
import TailscodeCore

/// Every colour the brain's own drawing uses, as sRGB numbers a cairo context takes, resolved once
/// from the palette and the model that answered. The zones' colours are the head's own channel
/// tones, so a light theme gets the lifted glow it needs inside the dark dome and a dark one gets
/// the theme's slots as they are.
struct BrainInks {
    typealias RGB = (red: Double, green: Double, blue: Double)

    let zones: [RGB]
    let live: RGB
    let attention: RGB
    let danger: RGB
    let quiet: RGB
    let identity: RGB
    let ink: RGB
    let dim: RGB
    let special: RGB
    let accent: RGB
    let info: RGB
    let domeInk: RGB
    let domeDim: RGB
    let domeSpecial: RGB
    let domeAccent: RGB
    let domeInfo: RGB
    let panel: RGB
    let card: RGB
    let rule: RGB
    let isDark: Bool
    /// What sits on the transcript's canvas wears the theme's corrected palette, which clears its
    /// contrast there; the head is dark in every theme and its lights wear the lifted tones above.
    let correctedZones: [RGB]
    let warn: RGB
    let cDanger: RGB
    let canvas: RGB
    let rule2: RGB
    let hex: Hex

    /// The palette's own hex strings, for the places a colour is written into markup or a rule.
    struct Hex {
        let text: String
        let dim: String
        let accent: String
        let warn: String
        let danger: String
        let info: String
        let special: String
        let canvas: String
        let raised: String
        let rule: String
        let say: String
        let rule2: String
    }

    init(palette: Palette, face: NeuralFace) {
        let tones = NeuralPalette.channelTones(palette: palette, face: face)
        zones = NeuralZone.allCases.map { Self.encode(tones[$0.rawValue]) }
        live = Self.encode(NeuralPalette.glow(.live, palette: palette, face: face))
        attention = Self.encode(NeuralPalette.glow(.attention, palette: palette, face: face))
        danger = Self.encode(NeuralPalette.glow(.danger, palette: palette, face: face))
        quiet = Self.encode(NeuralPalette.glow(.quiet, palette: palette, face: face))
        identity = Self.encode(NeuralPalette.glow(.identity, palette: palette, face: face))
        domeInk = zones[NeuralZone.think.rawValue]
        domeDim = zones[NeuralZone.delegate.rawValue]
        domeSpecial = zones[NeuralZone.shell.rawValue]
        domeAccent = zones[NeuralZone.act.rawValue]
        domeInfo = zones[NeuralZone.sense.rawValue]
        let fallback: RGB = (0.5, 0.5, 0.5)
        ink = Contrast.channels(palette.text) ?? fallback
        dim = Contrast.channels(palette.textDim) ?? fallback
        special = Contrast.channels(palette.special) ?? fallback
        accent = Contrast.channels(palette.accent) ?? fallback
        info = Contrast.channels(palette.info) ?? fallback
        rule = Contrast.channels(palette.rule) ?? fallback
        let canvas = Contrast.channels(palette.canvas) ?? (0.05, 0.05, 0.05)
        isDark = palette.isDark
        panel =
            palette.isDark
            ? (canvas.red * 0.55, canvas.green * 0.55, canvas.blue * 0.55) : (0.045, 0.06, 0.055)
        card = Contrast.channels(palette.canvasRaised) ?? canvas
        self.canvas = canvas
        warn = Contrast.channels(palette.warn) ?? fallback
        cDanger = Contrast.channels(palette.danger) ?? fallback
        let say = Contrast.blend(palette.info, palette.accent, 0.45) ?? palette.accent
        let rule2 = Contrast.blend(palette.canvas, palette.textDim, 0.34) ?? palette.rule
        self.rule2 = Contrast.channels(rule2) ?? fallback
        correctedZones = [
            ink, info, accent, special, dim, Contrast.channels(say) ?? accent,
        ]
        hex = Hex(
            text: palette.text, dim: palette.textDim, accent: palette.accent, warn: palette.warn,
            danger: palette.danger, info: palette.info, special: palette.special,
            canvas: palette.canvas, raised: palette.canvasRaised, rule: palette.rule, say: say,
            rule2: rule2)
    }

    private static func encode(_ linear: NeuralRGB) -> RGB {
        func channel(_ value: Float) -> Double { Double(pow(max(0, value), 1 / 2.2)) }
        return (channel(linear.r), channel(linear.g), channel(linear.b))
    }

    func zone(_ zone: NeuralZone) -> RGB { zones[zone.rawValue] }

    func corrected(_ zone: NeuralZone) -> RGB { correctedZones[zone.rawValue] }

    func correctedHex(_ zone: NeuralZone) -> String {
        switch zone {
        case .think: return hex.text
        case .sense: return hex.info
        case .act: return hex.accent
        case .shell: return hex.special
        case .delegate: return hex.dim
        case .say: return hex.say
        }
    }

    /// A tone as it is worn on the canvas: the accent for a live thing, the warning colour for
    /// one that waits on the person, the danger colour, and the dim ink for a quiet one.
    func correctedHex(_ tone: NeuralTone) -> String {
        switch tone {
        case .live, .identity: return hex.accent
        case .attention: return hex.warn
        case .danger: return hex.danger
        case .quiet: return hex.dim
        }
    }

    func corrected(_ tone: NeuralTone) -> RGB {
        switch tone {
        case .live, .identity: return accent
        case .attention: return warn
        case .danger: return cDanger
        case .quiet: return dim
        }
    }

    func tone(_ tone: NeuralTone) -> RGB {
        switch tone {
        case .live: return live
        case .attention: return attention
        case .danger: return danger
        case .quiet: return quiet
        case .identity: return identity
        }
    }

    func color(of tone: NeuralNodeTone, zone: NeuralZone) -> RGB {
        switch tone {
        case .zone: return self.zone(zone)
        case .live: return live
        case .attention: return attention
        case .danger: return danger
        case .quiet: return quiet
        }
    }

    static func mix(_ one: RGB, _ other: RGB, _ amount: Double) -> RGB {
        (
            one.red + (other.red - one.red) * amount, one.green + (other.green - one.green) * amount,
            one.blue + (other.blue - one.blue) * amount
        )
    }
}
