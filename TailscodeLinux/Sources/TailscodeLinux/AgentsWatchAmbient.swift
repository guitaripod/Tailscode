import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// Forty-eight drifting points, allocated once. Their speed follows the wall's mood: almost still
/// when calm, a gentle current when busy, drawn toward whatever needs a person when something
/// does, slow and warm in an alarm. A step moves numbers in place; nothing is allocated.
final class WatchMotes: @unchecked Sendable {
    static let count = 48

    private let x = UnsafeMutablePointer<Double>.allocate(capacity: count)
    private let y = UnsafeMutablePointer<Double>.allocate(capacity: count)
    private let heading = UnsafeMutablePointer<Double>.allocate(capacity: count)
    private let size = UnsafeMutablePointer<Double>.allocate(capacity: count)
    private let phase = UnsafeMutablePointer<Double>.allocate(capacity: count)
    private var seed: UInt64 = 0x9E37_79B9_7F4A_7C15

    init() {
        for index in 0..<Self.count { respawn(index, anywhere: true) }
    }

    deinit {
        x.deallocate()
        y.deallocate()
        heading.deallocate()
        size.deallocate()
        phase.deallocate()
    }

    private func next() -> Double {
        seed ^= seed << 13
        seed ^= seed >> 7
        seed ^= seed << 17
        return Double(seed % 10_000) / 10_000
    }

    private func respawn(_ index: Int, anywhere: Bool) {
        x[index] = anywhere ? next() : (next() < 0.5 ? -0.01 : 1.01)
        y[index] = anywhere ? next() : next()
        heading[index] = next() * 2 * .pi
        size[index] = 0.18 + next() * 0.32
        phase[index] = next() * 2 * .pi
    }

    func speed(_ mood: WallMood) -> Double {
        switch mood {
        case .calm: return 0.003
        case .busy: return 0.022
        case .attention: return 0.03
        case .alarm: return 0.009
        }
    }

    var positionSum: Double {
        var total = 0.0
        for index in 0..<Self.count { total += x[index] + y[index] }
        return total
    }

    func step(dt: Double, mood: WallMood, target: (x: Double, y: Double)?, slow: Double) {
        let pace = speed(mood) * slow * dt
        for index in 0..<Self.count {
            var dx = cos(heading[index])
            var dy = sin(heading[index])
            if mood == .busy {
                dx += 1.4
                dy -= 0.5
            }
            if let target, mood == .attention || mood == .alarm {
                let toX = target.x - x[index]
                let toY = target.y - y[index]
                let distance = max(0.001, (toX * toX + toY * toY).squareRoot())
                if distance < 0.035 {
                    respawn(index, anywhere: false)
                    continue
                }
                dx = dx * 0.35 + toX / distance
                dy = dy * 0.35 + toY / distance
            }
            x[index] += dx * pace
            y[index] += dy * pace
            heading[index] += (next() - 0.5) * 0.4 * dt
            if x[index] < -0.02 { x[index] = 1.02 } else if x[index] > 1.02 { x[index] = -0.02 }
            if y[index] < -0.02 { y[index] = 1.02 } else if y[index] > 1.02 { y[index] = -0.02 }
        }
    }

    func paint(
        _ cr: OpaquePointer, width: Double, height: Double, unit: Double, ink: PartyInk, t: Double,
        animated: Bool, brightness: Double
    ) {
        for index in 0..<Self.count {
            let twinkle = animated ? 0.5 + 0.5 * sin(phase[index] + t * 0.45) : 0.55
            let alpha = (0.05 + 0.13 * twinkle) * brightness
            let px = x[index] * width
            let py = y[index] * height
            let radius = max(0.8, size[index] * unit * 0.8)
            ink.set(cr, alpha: alpha * 0.22)
            cairo_new_path(cr)
            cairo_arc(cr, px, py, radius * 2.2, 0, 2 * .pi)
            cairo_fill(cr)
            ink.set(cr, alpha: alpha)
            cairo_new_path(cr)
            cairo_arc(cr, px, py, radius, 0, 2 * .pi)
            cairo_fill(cr)
        }
    }
}

/// The ground the tiles sit on and the edge that breathes when something has waited too long.
enum WatchAmbient {
    static func ground(
        _ cr: OpaquePointer, width: Double, height: Double, unit: Double, palette: WatchPalette,
        tint: PartyInk
    ) {
        if let base = cairo_pattern_create_linear(0, 0, 0, height) {
            let top = palette.groundDeep
            let bottom = palette.ground
            cairo_pattern_add_color_stop_rgba(base, 0, top.red, top.green, top.blue, 1)
            cairo_pattern_add_color_stop_rgba(base, 1, bottom.red, bottom.green, bottom.blue, 1)
            cairo_set_source(cr, base)
            cairo_paint(cr)
            cairo_pattern_destroy(base)
        }
        if let bloom = cairo_pattern_create_radial(
            width * 0.5, height * 0.42, 0, width * 0.5, height * 0.42, max(width, height) * 0.7)
        {
            cairo_pattern_add_color_stop_rgba(bloom, 0, tint.red, tint.green, tint.blue, 0.085)
            cairo_pattern_add_color_stop_rgba(bloom, 1, tint.red, tint.green, tint.blue, 0)
            cairo_set_source(cr, bloom)
            cairo_paint(cr)
            cairo_pattern_destroy(bloom)
        }
        palette.text.set(cr, alpha: 0.035)
        cairo_set_line_width(cr, 1)
        let step = max(24, unit * 6)
        var line = step / 2
        while line < width {
            cairo_move_to(cr, line.rounded() + 0.5, 0)
            cairo_line_to(cr, line.rounded() + 0.5, height)
            line += step
        }
        line = step / 2
        while line < height {
            cairo_move_to(cr, 0, line.rounded() + 0.5)
            cairo_line_to(cr, width, line.rounded() + 0.5)
            line += step
        }
        cairo_stroke(cr)
    }

    static func vignette(
        _ cr: OpaquePointer, width: Double, height: Double, unit: Double, ink: PartyInk, intensity: Double
    ) {
        let band = min(width, height) * 0.13
        for edge in 0..<4 {
            let horizontal = edge < 2
            let from = edge % 2 == 0 ? 0.0 : (horizontal ? height : width)
            let direction = edge % 2 == 0 ? 1.0 : -1.0
            let pattern =
                horizontal
                ? cairo_pattern_create_linear(0, from, 0, from + direction * band)
                : cairo_pattern_create_linear(from, 0, from + direction * band, 0)
            guard let pattern else { continue }
            cairo_pattern_add_color_stop_rgba(pattern, 0, ink.red, ink.green, ink.blue, intensity)
            cairo_pattern_add_color_stop_rgba(pattern, 1, ink.red, ink.green, ink.blue, 0)
            cairo_set_source(cr, pattern)
            if horizontal {
                cairo_rectangle(cr, 0, edge % 2 == 0 ? 0 : height - band, width, band)
            } else {
                cairo_rectangle(cr, edge % 2 == 0 ? 0 : width - band, 0, band, height)
            }
            cairo_fill(cr)
            cairo_pattern_destroy(pattern)
        }
    }
}
