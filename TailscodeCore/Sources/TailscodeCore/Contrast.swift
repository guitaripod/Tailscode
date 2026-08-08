import Foundation

/// WCAG contrast, computed from the hex strings a theme is actually written in, so a palette can
/// be asserted rather than eyeballed: a signal colour that no longer reads on its canvas is a bug
/// a screenshot hides and arithmetic does not.
///
/// It also does the other half — making a colour read. A published palette is authored for beauty,
/// not for a 4.5:1 floor, and most of the loved ones put at least one accent below it on at least
/// one of their backgrounds. Rather than hand-tuning every hex until the numbers pass, `adjusted`
/// walks a colour's *lightness* in OKLab until it clears the bar and leaves its hue and chroma
/// alone, so Gruvbox red stays Gruvbox red and simply becomes legible.
public enum Contrast {
    /// Text that carries a fact — a pill's word, a tool name, a count on the band.
    public static let readable: Double = 4.5
    /// Text that is deliberately secondary, and any purely graphical mark.
    public static let secondary: Double = 3.0

    public static func ratio(_ one: String, on other: String) -> Double? {
        guard let a = luminance(one), let b = luminance(other) else { return nil }
        return ratio(a, b)
    }

    private static func ratio(_ one: Double, _ other: Double) -> Double {
        let (high, low) = one > other ? (one, other) : (other, one)
        return (high + 0.05) / (low + 0.05)
    }

    public static func luminance(_ hex: String) -> Double? {
        guard let rgb = RGB(hex) else { return nil }
        return luminance(rgb)
    }

    /// A palette's hex as channels, for the toolkits that want a colour type rather than a string.
    /// Nothing about a slot's meaning survives the trip, so the caller keeps the slot and only the
    /// arithmetic crosses.
    public static func channels(_ hex: String) -> (red: Double, green: Double, blue: Double)? {
        guard let rgb = RGB(hex) else { return nil }
        return (rgb.red, rgb.green, rgb.blue)
    }

    /// Two colours mixed in OKLab rather than in sRGB, because a gradient between them is walked a
    /// character at a time by the stream cascade and sRGB midpoints go grey: green to red passes
    /// through mud, blue to yellow through a dead middle. OKLab keeps the walk the colour the eye
    /// expects at every step.
    public static func blend(_ one: String, _ other: String, _ amount: Double) -> String? {
        guard let start = RGB(one), let end = RGB(other) else { return nil }
        return mix(start, end, amount).hex
    }

    /// The same mix, kept as numbers.
    ///
    /// The stream cascade walks this twenty-six times a frame and then parses the answer straight
    /// back into an integer. Formatting a colour into six hex digits so the caller can undo it is
    /// three thousand strings a second built to be thrown away, on the main thread, inside the
    /// frame callback — the wave is arithmetic and it can stay arithmetic.
    public static func blendChannels(
        _ one: (red: Double, green: Double, blue: Double),
        _ other: (red: Double, green: Double, blue: Double), _ amount: Double
    ) -> (red: Double, green: Double, blue: Double) {
        let blended = mix(
            RGB(red: one.red, green: one.green, blue: one.blue),
            RGB(red: other.red, green: other.green, blue: other.blue), amount)
        return (blended.red, blended.green, blended.blue)
    }

    private static func mix(_ start: RGB, _ end: RGB, _ amount: Double) -> RGB {
        let amount = min(max(amount, 0), 1)
        var lab = OKLab(start)
        let target = OKLab(end)
        lab.lightness += (target.lightness - lab.lightness) * amount
        lab.a += (target.a - lab.a) * amount
        lab.b += (target.b - lab.b) * amount
        return lab.rgb
    }

    /// A hex string from linear-free 0…1 channels — the form the shared rainbow stops are authored
    /// in, for the toolkits that speak hex rather than a colour type.
    public static func hex(red: Double, green: Double, blue: Double) -> String {
        RGB(red: red, green: green, blue: blue).hex
    }

    private static func luminance(_ rgb: RGB) -> Double {
        0.2126 * linear(rgb.red) + 0.7152 * linear(rgb.green) + 0.0722 * linear(rgb.blue)
    }

    /// The same colour, moved away from `background` in lightness only, until it reads at `ratio`.
    /// A colour that already clears the bar is returned untouched — the whole point is to correct
    /// what a palette got wrong and to leave alone what it got right. Returns nil only if the hue
    /// cannot reach the target at any lightness, which is a palette the caller must be told about
    /// rather than one to silently approximate.
    public static func adjusted(_ hex: String, on background: String, ratio target: Double)
        -> String?
    {
        guard let color = RGB(hex), let canvas = RGB(background) else { return nil }
        let canvasLuminance = luminance(canvas)
        guard ratio(luminance(color), canvasLuminance) < target else { return hex }

        var lab = OKLab(color)
        let toward: Double = canvasLuminance > 0.18 ? 0 : 1
        /// What the palette will actually contain — eight bits a channel. Measuring the continuous
        /// value would let the search settle on 4.499:1 and quantise to a failure nobody can see
        /// but the contract can.
        func reads(at lightness: Double) -> String? {
            lab.lightness = lightness
            let hex = lab.rgb.hex
            guard let quantized = RGB(hex),
                ratio(luminance(quantized), canvasLuminance) >= target
            else { return nil }
            return hex
        }

        var low = lab.lightness
        var high = toward
        var best: String?
        for _ in 0..<24 {
            let middle = (low + high) / 2
            if let hex = reads(at: middle) {
                best = hex
                high = middle
            } else {
                low = middle
            }
        }
        return best ?? reads(at: toward)
    }

    private static func linear(_ channel: Double) -> Double {
        channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }

    private static func encode(_ channel: Double) -> Double {
        channel <= 0.0031308 ? channel * 12.92 : 1.055 * pow(channel, 1 / 2.4) - 0.055
    }

    private struct RGB {
        var red: Double
        var green: Double
        var blue: Double

        init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        init?(_ hex: String) {
            var digits = Substring(hex)
            if digits.hasPrefix("#") { digits = digits.dropFirst() }
            guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
            red = Double((value >> 16) & 0xff) / 255
            green = Double((value >> 8) & 0xff) / 255
            blue = Double(value & 0xff) / 255
        }

        var hex: String {
            func byte(_ channel: Double) -> Int { Int((min(max(channel, 0), 1) * 255).rounded()) }
            return String(format: "#%02x%02x%02x", byte(red), byte(green), byte(blue))
        }
    }

    /// OKLab, because lightness has to move without dragging the hue with it. Shifting an sRGB or
    /// HSL value darker visibly swings blues toward purple and yellows toward brown; OKLab is
    /// built so that changing `lightness` alone leaves the colour recognisably itself.
    private struct OKLab {
        var lightness: Double
        var a: Double
        var b: Double

        init(_ rgb: RGB) {
            let red = linear(rgb.red)
            let green = linear(rgb.green)
            let blue = linear(rgb.blue)
            let long = cbrt(0.4122214708 * red + 0.5363325363 * green + 0.0514459929 * blue)
            let medium = cbrt(0.2119034982 * red + 0.6806995451 * green + 0.1073969566 * blue)
            let short = cbrt(0.0883024619 * red + 0.2817188376 * green + 0.6299787005 * blue)
            lightness = 0.2104542553 * long + 0.7936177850 * medium - 0.0040720468 * short
            a = 1.9779984951 * long - 2.4285922050 * medium + 0.4505937099 * short
            b = 0.0259040371 * long + 0.7827717662 * medium - 0.8086757660 * short
        }

        var rgb: RGB {
            let long = pow(lightness + 0.3963377774 * a + 0.2158037573 * b, 3)
            let medium = pow(lightness - 0.1055613458 * a - 0.0638541728 * b, 3)
            let short = pow(lightness - 0.0894841775 * a - 1.2914855480 * b, 3)
            return RGB(
                red: encode(
                    clamp(4.0767416621 * long - 3.3077115913 * medium + 0.2309699292 * short)),
                green: encode(
                    clamp(-1.2684380046 * long + 2.6097574011 * medium - 0.3413193965 * short)),
                blue: encode(
                    clamp(-0.0041960863 * long - 0.7034186147 * medium + 1.7076147010 * short)))
        }

        private func clamp(_ value: Double) -> Double { min(max(value, 0), 1) }
    }
}
