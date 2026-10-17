import Foundation

/// Theme slots to the head's light. Additive light needs a dark ground, so on a palette whose
/// canvas is light every glow colour is lifted toward white and the head's glow no longer spills
/// past the chassis. All colours here are linear RGB, which is what the shaders and the CPU
/// compositor blend in; the conversion is the mock's `pow(c, 2.2)`. Callers hand in the palette
/// as the app draws it (``Palette/corrected()``).
public enum NeuralPalette {
    /// How far a light palette's glow moves toward white.
    public static let lightLift: Float = 0.45

    /// The linear colour a tone glows in.
    public static func glow(_ tone: NeuralTone, palette: Palette, face: NeuralFace) -> NeuralRGB {
        let hex: String
        switch tone {
        case .live: hex = palette.accent
        case .attention: hex = palette.warn
        case .danger: hex = palette.danger
        case .quiet: hex = palette.textDim
        case .identity: hex = face.hueHex(isDark: palette.isDark)
        }
        return linear(glowify(srgb(hex), light: !palette.isDark))
    }

    /// The thirteen channel colours as `tones()` in the mock: PLAN is the ink, SENSE the info
    /// slot, ACT the accent, SHELL the special slot, DELEGATE the dim ink, SAY half accent and
    /// half info, then links, stars, and the seam, eye, ribs, ear and visor on the accent. An
    /// override (a frame's `toneOverride`, by channel index) replaces a channel's colour with
    /// that tone's glow.
    public static func channelTones(
        palette: Palette, face: NeuralFace, overrides: [NeuralTone?] = []
    ) -> [NeuralRGB] {
        let light = !palette.isDark
        let ink = glowify(srgb(palette.text), light: light)
        let ink2 = glowify(srgb(palette.textDim), light: light)
        let accent = glowify(srgb(palette.accent), light: light)
        let info = glowify(srgb(palette.info), light: light)
        let special = glowify(srgb(palette.special), light: light)
        let base: [NeuralRGB] = [
            ink, info, accent, special, ink2, mix(accent, info, 0.45), mix(accent, info, 0.5),
            mix(ink, info, 0.3), accent, accent, accent, accent, accent,
        ].map(linear)
        var tones = base
        for index in 0..<min(overrides.count, tones.count) {
            if let tone = overrides[index] {
                tones[index] = glow(tone, palette: palette, face: face)
            }
        }
        return tones
    }

    /// Whether the glow may spill outside the chassis: only over a dark page.
    public static func spill(palette: Palette) -> Bool { palette.isDark }

    /// The page the head sits on, in linear light, for the interior's base.
    public static func canvas(palette: Palette) -> NeuralRGB { linear(srgb(palette.canvas)) }

    static func srgb(_ hex: String) -> NeuralRGB {
        guard let channels = Contrast.channels(hex) else { return NeuralRGB(0, 0, 0) }
        return NeuralRGB(Float(channels.red), Float(channels.green), Float(channels.blue))
    }

    static func glowify(_ color: NeuralRGB, light: Bool) -> NeuralRGB {
        light ? mix(color, NeuralRGB(1, 1, 1), lightLift) : color
    }

    static func mix(_ a: NeuralRGB, _ b: NeuralRGB, _ amount: Float) -> NeuralRGB {
        NeuralRGB(
            a.r * (1 - amount) + b.r * amount, a.g * (1 - amount) + b.g * amount,
            a.b * (1 - amount) + b.b * amount)
    }

    static func linear(_ color: NeuralRGB) -> NeuralRGB {
        NeuralRGB(powf(color.r, 2.2), powf(color.g, 2.2), powf(color.b, 2.2))
    }
}
