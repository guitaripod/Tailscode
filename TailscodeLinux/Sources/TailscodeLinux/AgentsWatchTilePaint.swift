import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// The parts of a tile that are drawn rather than set in type: the glass card with the state's
/// glow and the minute of heartbeat. Pure cairo over numbers.
enum WatchTilePaint {
    struct Face {
        var state: WallState
        var focused: Bool
        var pulse = 0.0
    }

    static func breathPeriod(_ state: WallState) -> Double? {
        switch state {
        case .working: return 5.2
        case .thinking: return 8
        case .needsYou(let urgency): return urgency == .overdue ? 2.6 : 4.2
        case .background(let stuck): return stuck ? nil : 6.5
        case .retrying: return 4
        default: return nil
        }
    }

    static func glow(_ state: WallState, t: Double, animated: Bool) -> Double {
        switch state {
        case .needsYou(let urgency):
            let overdue = urgency == .overdue
            return WatchGlyph.knock(t, period: overdue ? 2.6 : 4.2, second: overdue ? 0.26 : 0.34, animated: animated)
        default:
            guard let period = breathPeriod(state) else { return 0.5 }
            return WatchGlyph.breath(t, period: period, animated: animated)
        }
    }

    static func card(
        _ cr: OpaquePointer, width: Double, height: Double, unit: Double, face: Face,
        palette: WatchPalette, t: Double, animated: Bool, corner: Double = 1
    ) {
        let ink = palette.ink(face.state)
        let radius = 1.6 * unit * corner
        let swell = glow(face.state, t: t, animated: animated)
        agentsRoundedRect(cr, x: 0.5, y: 0.5, width: width - 1, height: height - 1, radius: radius)
        if let glass = cairo_pattern_create_linear(0, 0, 0, height) {
            cairo_pattern_add_color_stop_rgba(glass, 0, palette.text.red, palette.text.green, palette.text.blue, 0.085)
            cairo_pattern_add_color_stop_rgba(glass, 1, palette.text.red, palette.text.green, palette.text.blue, 0.03)
            cairo_set_source(cr, glass)
            cairo_fill_preserve(cr)
            cairo_pattern_destroy(glass)
        }
        cairo_save(cr)
        cairo_clip(cr)
        wash(cr, width: width, height: height, ink: ink, face: face, swell: swell)
        hatch(cr, width: width, height: height, unit: unit, face: face, palette: palette)
        cairo_restore(cr)
        agentsRoundedRect(cr, x: 0.5, y: 0.5, width: width - 1, height: height - 1, radius: radius)
        let (alpha, line) = border(face.state, unit: unit, swell: swell)
        ink.set(cr, alpha: alpha)
        cairo_set_line_width(cr, line)
        cairo_stroke(cr)
        rim(cr, width: width, radius: radius)
        if face.focused { focusRing(cr, width: width, height: height, unit: unit, radius: radius, palette: palette) }
    }

    private static func border(_ state: WallState, unit: Double, swell: Double) -> (Double, Double) {
        switch state {
        case .needsYou(.overdue): return (0.8 + 0.2 * swell, 0.34 * unit)
        case .needsYou: return (0.55 + 0.4 * swell, 0.26 * unit)
        case .retrying: return (0.5, 0.2 * unit)
        case .quiet: return (0.5, 1)
        case .finished(.failed): return (0.85, 0.26 * unit)
        case .finished(.done): return (0.4, 1)
        case .finished, .away: return (0.3, 1)
        default: return (0.34, 1)
        }
    }

    private static func wash(
        _ cr: OpaquePointer, width: Double, height: Double, ink: PartyInk, face: Face, swell: Double
    ) {
        var strength = 0.06 + 0.06 * swell + 0.03 * face.pulse
        switch face.state {
        case .needsYou(.overdue): strength = 0.15 + 0.1 * swell
        case .needsYou: strength = 0.1 + 0.08 * swell
        case .quiet: strength = 0.04
        case .finished(.failed): strength = 0.14
        case .finished, .away: strength = 0.03
        default: break
        }
        guard let glow = cairo_pattern_create_linear(0, 0, 0, height * 0.9) else { return }
        cairo_pattern_add_color_stop_rgba(glow, 0, ink.red, ink.green, ink.blue, strength * 1.6)
        cairo_pattern_add_color_stop_rgba(glow, 1, ink.red, ink.green, ink.blue, 0)
        cairo_set_source(cr, glow)
        cairo_paint(cr)
        cairo_pattern_destroy(glow)
        if face.state.isNeedsYou {
            ink.set(cr, alpha: strength * 0.5)
            cairo_paint(cr)
        }
    }

    private static func hatch(
        _ cr: OpaquePointer, width: Double, height: Double, unit: Double, face: Face,
        palette: WatchPalette
    ) {
        guard case .away = face.state else { return }
        palette.dim.set(cr, alpha: 0.2)
        cairo_set_line_width(cr, max(1, unit * 0.14))
        var stripe = -height
        let step = unit * 1.3
        while stripe < width {
            cairo_move_to(cr, stripe, height)
            cairo_line_to(cr, stripe + height, 0)
            stripe += step
        }
        cairo_stroke(cr)
    }

    private static func rim(_ cr: OpaquePointer, width: Double, radius: Double) {
        cairo_save(cr)
        cairo_rectangle(cr, radius, 0, width - 2 * radius, 2)
        cairo_clip(cr)
        agentsRoundedRect(cr, x: 1.5, y: 1.5, width: width - 3, height: radius * 4, radius: radius)
        cairo_set_source_rgba(cr, 1, 1, 1, 0.1)
        cairo_set_line_width(cr, 1)
        cairo_stroke(cr)
        cairo_restore(cr)
    }

    private static func focusRing(
        _ cr: OpaquePointer, width: Double, height: Double, unit: Double, radius: Double,
        palette: WatchPalette
    ) {
        agentsRoundedRect(cr, x: unit * 0.35, y: unit * 0.35, width: width - unit * 0.7, height: height - unit * 0.7, radius: radius)
        palette.text.set(cr, alpha: 0.85)
        cairo_set_line_width(cr, max(1.5, unit * 0.2))
        cairo_stroke(cr)
    }

    static func beat(
        _ cr: OpaquePointer, width: Double, height: Double, beat: [Int], slide: Double, ink: PartyInk,
        palette: WatchPalette
    ) {
        guard !beat.isEmpty else { return }
        let pitch = width / Double(beat.count)
        let bar = max(1.5, pitch * 0.62)
        let ceiling = Double(AgentBeat.ceiling)
        if beat.allSatisfy({ $0 == 0 }) {
            palette.dim.set(cr, alpha: 0.55)
            cairo_rectangle(cr, 0, height - 2, width, 2)
            cairo_fill(cr)
            return
        }
        cairo_rectangle(cr, 0, 0, width, height)
        cairo_clip(cr)
        for index in beat.indices {
            let x = (Double(index) + slide) * pitch
            let value = beat[index]
            if value == 0 {
                palette.dim.set(cr, alpha: 0.4)
                cairo_rectangle(cr, x, height - 2, bar, 2)
            } else {
                let lift = max(height * 0.22, height * Double(value) / ceiling)
                ink.set(cr, alpha: 0.5 + 0.5 * Double(value) / ceiling)
                agentsRoundedRect(cr, x: x, y: height - lift, width: bar, height: lift, radius: bar / 2)
            }
            cairo_fill(cr)
        }
    }
}
