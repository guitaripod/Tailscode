import AppKit
import TailscodeCore

/// The palette the head is drawn in, from the app's own appearance through Core.
///
/// A named theme is Core's palette as the rest of the window wears it. "System", which is this
/// client's default, has no palette of its own, so one is made from the platform's colours the
/// activity marks already wear (green for work, orange for attention, red for failure), resolved
/// under the appearance being drawn, and run through the same contrast correction a theme gets.
@MainActor
enum MacBrainPalette {
    private static var memo: [String: Palette] = [:]
    private static var observing = false

    static func palette(for appearance: NSAppearance) -> Palette {
        watchTheme()
        let dark = appearance.isDark
        let key = "\(ThemeSelection.themeID)/\(dark)"
        if let held = memo[key] { return held }
        let made =
            ThemePalette.palette(themeID: ThemeSelection.themeID, dark: dark)
            ?? system(dark: dark, appearance: appearance)
        memo[key] = made
        return made
    }

    /// The palette the window is wearing now, for the surfaces that have no view to ask yet.
    static var current: Palette { palette(for: ThemePalette.appearance) }

    static func hex(_ color: NSColor, in appearance: NSAppearance) -> String {
        var found = "#808080"
        appearance.performAsCurrentDrawingAppearance {
            guard let rgb = color.usingColorSpace(.sRGB) else { return }
            func clamp(_ value: CGFloat) -> Double { Double(min(max(value, 0), 1)) }
            found = Contrast.hex(
                red: clamp(rgb.redComponent), green: clamp(rgb.greenComponent),
                blue: clamp(rgb.blueComponent))
        }
        return found
    }

    /// The opacity a system colour carries in this appearance, which `hex` drops: the secondary
    /// label is the label ink at about half strength, and read at full strength it is white.
    private static func alpha(_ color: NSColor, in appearance: NSAppearance) -> Double {
        var found = 1.0
        appearance.performAsCurrentDrawingAppearance {
            found = Double(color.usingColorSpace(.sRGB)?.alphaComponent ?? 1)
        }
        return found
    }

    private static func system(dark: Bool, appearance: NSAppearance) -> Palette {
        let canvas = hex(.textBackgroundColor, in: appearance)
        let text = hex(.labelColor, in: appearance)
        let dim = Contrast.blend(canvas, hex(.secondaryLabelColor, in: appearance), alpha(.secondaryLabelColor, in: appearance)) ?? text
        let green = hex(.systemGreen, in: appearance)
        let raised = Contrast.blend(canvas, text, 0.06) ?? canvas
        let rule = Contrast.blend(canvas, text, 0.13) ?? dim
        return Palette(
            name: ThemeSelection.systemID, isDark: dark, canvas: canvas, canvasRaised: raised,
            rule: rule, text: text, textDim: dim, accent: green, accentDim: green,
            warn: hex(.systemOrange, in: appearance), danger: hex(.systemRed, in: appearance),
            info: hex(.systemIndigo, in: appearance), special: hex(.systemPurple, in: appearance),
            codeBg: raised, subagentBg: raised, findHit: hex(.systemYellow, in: appearance),
            ansi: []
        ).corrected()
    }

    private static func watchTheme() {
        guard !observing else { return }
        observing = true
        NotificationCenter.default.addObserver(
            forName: MacTheme.Chrome.didRepaint, object: nil, queue: .main
        ) { _ in
            MainThread.call { memo = [:] }
        }
    }
}

/// Every colour the row, the glyph, the nodes and the wires draw with, resolved once from a palette.
///
/// The head is a dark object on any canvas, and its light is additive, so what is drawn inside the
/// dome is lifted toward white on a light palette (the nodes and wires use `dome`), while what
/// stands on the page (the glyph, the chips, the scrubber) wears the palette's own corrected
/// colours (`page`).
@MainActor
struct BrainInks: Equatable {
    let palette: Palette
    let isDark: Bool

    /// A zone's own colour on the page.
    func page(_ zone: NeuralZone) -> NSColor { color(zoneHex(zone)) }

    /// A zone's own colour inside the dome.
    func dome(_ zone: NeuralZone) -> NSColor { color(lifted(zoneHex(zone))) }

    /// A node's tone inside the dome.
    func dome(_ tone: NeuralNodeTone, zone: NeuralZone) -> NSColor {
        switch tone {
        case .zone: return dome(zone)
        case .live: return color(lifted(palette.accent))
        case .attention: return color(lifted(palette.warn))
        case .danger: return color(lifted(palette.danger))
        case .quiet: return color(lifted(palette.textDim))
        }
    }

    /// A tone on the page. `identity` is who answered and how hard, which is the family's own hue.
    func page(_ tone: NeuralTone, face: NeuralFace) -> NSColor {
        switch tone {
        case .live: return color(palette.accent)
        case .attention: return color(palette.warn)
        case .danger: return color(palette.danger)
        case .quiet: return color(palette.textDim)
        case .identity: return color(face.hueHex(isDark: isDark))
        }
    }

    /// The accent inside the dome, lifted on a light page.
    var domeAccent: NSColor { color(lifted(palette.accent)) }

    /// The dome's own dark: what a tag or a plate drawn inside the head sits on.
    var panel: NSColor { color(Self.domeGround) }

    var text: NSColor { color(palette.text) }
    var textDim: NSColor { color(palette.textDim) }
    var rule: NSColor { color(palette.rule) }
    var raised: NSColor { color(palette.canvasRaised) }
    var canvas: NSColor { color(palette.canvas) }

    init(palette: Palette) {
        self.palette = palette
        isDark = palette.isDark
    }

    @MainActor
    static func current(for appearance: NSAppearance) -> BrainInks {
        BrainInks(palette: MacBrainPalette.palette(for: appearance))
    }

    private func zoneHex(_ zone: NeuralZone) -> String {
        switch zone {
        case .think: return palette.text
        case .sense: return palette.info
        case .act: return palette.accent
        case .shell: return palette.special
        case .delegate: return palette.textDim
        case .say: return Contrast.blend(palette.accent, palette.info, 0.45) ?? palette.accent
        }
    }

    private func lifted(_ hex: String) -> String {
        guard !isDark else { return hex }
        let blended = Contrast.blend(hex, "#ffffff", Double(NeuralPalette.lightLift)) ?? hex
        return Contrast.adjusted(blended, on: Self.domeGround, ratio: 4.5) ?? blended
    }

    /// The dome's own dark, which a light page does not change, so ink inside it is held to this.
    private static let domeGround = "#0b100e"

    private func color(_ hex: String) -> NSColor { NSColor(hex: hex) ?? .labelColor }
}

/// The repeating light a node or a glyph dot wears, laid on its layer by the render server.
@MainActor
enum BrainMotion {
    private static let breathKey = "brain.breath"

    /// One lap of the activity's own swell, sampled from the vocabulary's arithmetic and begun at
    /// the most recent whole period of absolute time so every mark breathes as one hand. Nil for a
    /// motion with no swell to draw.
    static func lap(_ motion: ActivityMotion, on layer: CALayer) -> CAKeyframeAnimation? {
        let period: Double
        switch motion {
        case .breath(let value), .heartbeat(let value): period = value.period
        case .still, .sweep: return nil
        }
        let now = CACurrentMediaTime()
        let origin = (now / period).rounded(.down) * period
        let samples = 64
        let lap = CAKeyframeAnimation(keyPath: "opacity")
        lap.values = (0...samples).map {
            NSNumber(value: motion.intensity(at: origin + period * Double($0) / Double(samples)))
        }
        lap.keyTimes = (0...samples).map { NSNumber(value: Double($0) / Double(samples)) }
        lap.calculationMode = .linear
        lap.duration = period
        lap.repeatCount = .infinity
        lap.beginTime = layer.convertTime(origin, from: nil)
        return lap
    }

    /// Lays the swell on a layer, or takes it off for a status that holds still and for a desk
    /// that asked for less movement.
    static func breathe(_ layer: CALayer, _ motion: NeuralMotion) {
        let meaning: ActivityMotion
        switch motion {
        case .breath: meaning = .working
        case .heartbeat: meaning = .attention
        case .sweep, .still:
            layer.removeAnimation(forKey: breathKey)
            layer.opacity = 1
            return
        }
        guard let lap = lap(meaning, on: layer) else { return }
        layer.setRepeatingMotion(lap, forKey: breathKey, meaning: meaning)
    }

    static func isBreathing(_ layer: CALayer) -> Bool { layer.animation(forKey: breathKey) != nil }
}
