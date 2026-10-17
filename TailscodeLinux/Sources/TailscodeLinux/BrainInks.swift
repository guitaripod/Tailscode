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
    }

    private static func encode(_ linear: NeuralRGB) -> RGB {
        func channel(_ value: Float) -> Double { Double(pow(max(0, value), 1 / 2.2)) }
        return (channel(linear.r), channel(linear.g), channel(linear.b))
    }

    func zone(_ zone: NeuralZone) -> RGB { zones[zone.rawValue] }

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
