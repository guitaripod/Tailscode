import TailscodeCore
import UIKit

/// The head's colours in the app's own terms: one palette for the Metal pass and the same colours
/// as `UIColor`s for the nodes, wires and card drawn over it.
///
/// A theme hands over its palette as the app draws it. "System" has no palette of its own, so the
/// default theme's is taken and its inks are replaced by the platform's, resolved against the
/// trait collection the head is shown in; the canvas keeps the default's, because the head is a
/// dark object on any page and only reads the canvas as the ground under its glow.
enum BrainPalette {
    static func palette(for traits: UITraitCollection) -> Palette {
        if let themed = traits.palette { return themed }
        var base = ThemeSelection.palette(
            themeID: nil, dark: traits.userInterfaceStyle == .dark)
        func hex(_ color: UIColor) -> String {
            color.resolvedColor(with: traits).hexString
        }
        base.text = hex(Theme.Color.label)
        base.textDim = hex(Theme.Color.secondaryLabel)
        base.accent = hex(Theme.Color.accent)
        base.warn = hex(Theme.Color.warning)
        base.danger = hex(Theme.Color.danger)
        base.info = hex(Theme.Color.info)
        base.special = hex(Theme.Color.special)
        return base
    }
}

extension UIColor {
    /// `#rrggbb` in sRGB, for handing a platform colour to code that thinks in palettes.
    var hexString: String {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func channel(_ value: CGFloat) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", channel(red), channel(green), channel(blue))
    }

    /// This colour moved `amount` of the way to `other`, in sRGB.
    func mixed(with other: UIColor, _ amount: CGFloat) -> UIColor {
        var a: (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        var b: (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        getRed(&a.0, green: &a.1, blue: &a.2, alpha: &a.3)
        other.getRed(&b.0, green: &b.1, blue: &b.2, alpha: &b.3)
        let t = min(max(amount, 0), 1)
        return UIColor(
            red: a.0 + (b.0 - a.0) * t, green: a.1 + (b.1 - a.1) * t,
            blue: a.2 + (b.2 - a.2) * t, alpha: a.3 + (b.3 - a.3) * t)
    }
}

/// The colours a node field draws with, resolved once per palette and face.
struct BrainInk {
    let palette: Palette
    let face: NeuralFace
    let zones: [UIColor]
    let live: UIColor
    let attention: UIColor
    let danger: UIColor
    let quiet: UIColor
    let identity: UIColor
    let ink: UIColor
    let rule: UIColor
    let special: UIColor
    let dome: UIColor

    /// The dome is dark whatever the page is, so a node's plate is a dark disc and its tone is the
    /// glow on it.
    static let domeColor = UIColor(red: 0.045, green: 0.05, blue: 0.065, alpha: 1)

    init(palette: Palette, face: NeuralFace) {
        self.palette = palette
        self.face = face
        let tones = NeuralPalette.channelTones(palette: palette, face: face)
        zones = NeuralZone.allCases.map { Self.color($0.rawValue < tones.count ? tones[$0.rawValue] : tones[0]) }
        live = Self.color(NeuralPalette.glow(.live, palette: palette, face: face))
        attention = Self.color(NeuralPalette.glow(.attention, palette: palette, face: face))
        danger = Self.color(NeuralPalette.glow(.danger, palette: palette, face: face))
        quiet = Self.color(NeuralPalette.glow(.quiet, palette: palette, face: face))
        identity = Self.color(NeuralPalette.glow(.identity, palette: palette, face: face))
        ink = Self.color(tones[0])
        rule = Self.color(tones[4]).withAlphaComponent(0.34)
        special = Self.color(tones[3])
        dome = Self.domeColor
    }

    func zone(_ zone: NeuralZone) -> UIColor { zones[zone.rawValue] }

    /// What a node of this tone is drawn in.
    func color(for tone: NeuralNodeTone, zone: NeuralZone) -> UIColor {
        switch tone {
        case .zone: return self.zone(zone)
        case .live: return live
        case .attention: return attention
        case .danger: return danger
        case .quiet: return quiet
        }
    }

    func color(for tone: NeuralTone) -> UIColor {
        switch tone {
        case .live: return live
        case .attention: return attention
        case .danger: return danger
        case .quiet: return quiet
        case .identity: return identity
        }
    }

    private static func color(_ linear: NeuralRGB) -> UIColor {
        func encode(_ value: Float) -> CGFloat { CGFloat(powf(min(max(value, 0), 1), 1 / 2.2)) }
        return UIColor(
            red: encode(linear.r), green: encode(linear.g), blue: encode(linear.b), alpha: 1)
    }
}

extension BrainInk: Equatable {
    static func == (lhs: BrainInk, rhs: BrainInk) -> Bool {
        lhs.palette == rhs.palette && lhs.face == rhs.face
    }
}
