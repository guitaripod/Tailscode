import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The drifting points behind the wall, Core's `WallMotes` so the three walls share one field: a
/// count that follows the area, allocated when the size changes and never while it runs. Their
/// speed follows the wall's mood: almost still when calm, a gentle current when busy, drawn toward
/// whatever needs a person when something does, slow and warm in an alarm. Currents gives each
/// a four-point trail that fades behind it.
final class WatchMotes: @unchecked Sendable {
    private var field = WallMotes(width: 1920, height: 1080, seed: 1)

    var count: Int { field.count }

    var positionSum: Double { field.positionSum }

    /// Builds the field again only when the screen's area calls for a different number of motes.
    func fit(width: Double, height: Double) {
        guard width > 1, height > 1,
            WallMotes.count(width: width, height: height) != field.count
        else { return }
        field = WallMotes(width: width, height: height, seed: 1)
    }

    func step(dt: Double, mood: WallMood, target: (x: Double, y: Double)?, slow: Double, aspect: Double) {
        field.step(dt: dt, mood: mood, target: target, slow: slow, aspect: aspect)
    }

    func paint(
        _ cr: OpaquePointer, width: Double, height: Double, unit: Double, ink: PartyInk, t: Double,
        animated: Bool, brightness: Double, trails: Bool = false
    ) {
        fit(width: width, height: height)
        for index in 0..<field.count {
            let twinkle = animated ? 0.5 + 0.5 * sin(field.phase[index] + t * 0.45) : 0.55
            let alpha = (0.05 + 0.13 * twinkle) * brightness
            let px = field.x[index] * width
            let py = field.y[index] * height
            let radius = max(0.8, field.size[index] * unit * 0.8)
            ink.set(cr, alpha: alpha * 0.22)
            cairo_new_path(cr)
            cairo_arc(cr, px, py, radius * 2.2, 0, 2 * .pi)
            cairo_fill(cr)
            ink.set(cr, alpha: alpha)
            cairo_new_path(cr)
            cairo_arc(cr, px, py, radius, 0, 2 * .pi)
            cairo_fill(cr)
        }
        if trails { paintTrails(cr, width: width, height: height, unit: unit, ink: ink, brightness: brightness) }
    }

    /// Each mote's last four positions as a line that thins and fades away from its head, drawn one
    /// stroke per step of the fade for the whole field rather than one per mote.
    private func paintTrails(
        _ cr: OpaquePointer, width: Double, height: Double, unit: Double, ink: PartyInk, brightness: Double
    ) {
        let length = WallMotes.trailLength
        cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
        for step in 0..<length {
            cairo_new_path(cr)
            for index in 0..<field.count {
                let base = index * length
                let fromX = step == 0 ? field.x[index] : field.trailX[base + step - 1]
                let fromY = step == 0 ? field.y[index] : field.trailY[base + step - 1]
                cairo_move_to(cr, fromX * width, fromY * height)
                cairo_line_to(cr, field.trailX[base + step] * width, field.trailY[base + step] * height)
            }
            let fade = 1 - Double(step) / Double(length)
            cairo_set_line_width(cr, max(1, unit * 0.34 * fade))
            ink.set(cr, alpha: 0.16 * fade * brightness)
            cairo_stroke(cr)
        }
        cairo_set_line_cap(cr, CAIRO_LINE_CAP_BUTT)
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

/// The parts of the ground that change only with the size, the palette or the mood, painted once
/// into a surface and copied from there, so repainting the ground for a ripple or a breath of light
/// costs a copy and not a screenful of gradients. The surface is made again only when its key
/// changes.
final class WatchGroundCache {
    struct Key: Equatable {
        var width: Int
        var height: Int
        var unit: Double
        var tint: PartyInk
        var palette: WatchPalette
    }

    private var surface: OpaquePointer?
    private var key: Key?
    private(set) var builds = 0

    deinit {
        if let surface { cairo_surface_destroy(surface) }
    }

    func paint(_ cr: OpaquePointer, key next: Key, build: (OpaquePointer) -> Void) {
        if key != next || surface == nil {
            if let surface { cairo_surface_destroy(surface) }
            surface = cairo_image_surface_create(CAIRO_FORMAT_RGB24, Int32(next.width), Int32(next.height))
            key = next
            builds += 1
            if let surface, let inner = cairo_create(surface) {
                build(inner)
                cairo_destroy(inner)
            }
        }
        guard let surface else { return }
        cairo_save(cr)
        cairo_set_operator(cr, CAIRO_OPERATOR_SOURCE)
        cairo_set_source_surface(cr, surface, 0, 0)
        cairo_paint(cr)
        cairo_restore(cr)
    }
}

/// The aurora painted a sixteenth of the screen's size and stretched over it: the blooms are the
/// softest thing on the wall, and a full-size radial gradient is the slowest thing Cairo draws.
final class WatchAuroraCache {
    static let shrink = 16.0

    private var surface: OpaquePointer?
    private var size = (width: 0, height: 0)

    deinit {
        if let surface { cairo_surface_destroy(surface) }
    }

    func paint(
        _ cr: OpaquePointer, width: Double, height: Double, ink: PartyInk, text: PartyInk, t: Double
    ) {
        let small = (width: max(8, Int(width / Self.shrink)), height: max(8, Int(height / Self.shrink)))
        if surface == nil || size != small {
            if let surface { cairo_surface_destroy(surface) }
            surface = cairo_image_surface_create(CAIRO_FORMAT_ARGB32, Int32(small.width), Int32(small.height))
            size = small
        }
        guard let surface, let inner = cairo_create(surface) else { return }
        cairo_set_operator(inner, CAIRO_OPERATOR_CLEAR)
        cairo_paint(inner)
        cairo_set_operator(inner, CAIRO_OPERATOR_OVER)
        WatchGround.aurora(
            inner, width: Double(small.width), height: Double(small.height), ink: ink, text: text, t: t)
        cairo_destroy(inner)
        cairo_save(cr)
        cairo_scale(cr, width / Double(small.width), height / Double(small.height))
        cairo_set_operator(cr, CAIRO_OPERATOR_ADD)
        cairo_set_source_surface(cr, surface, 0, 0)
        if let pattern = cairo_get_source(cr) { cairo_pattern_set_filter(pattern, CAIRO_FILTER_BILINEAR) }
        cairo_paint(cr)
        cairo_restore(cr)
    }
}

/// What the ground gains from the style and from what happens on the wall, added as light on the
/// ground layer under the glass: the light each tile spills, the slow aurora, and the bands that
/// spread from a tile's edge when it knocks or finishes.
enum WatchGround {
    static let spillReach = 14.0
    static let spillScale = 7.0

    /// How much of a tile's light is left `distance` units from its edge: the exponential falloff the
    /// Metal ground uses, brought to nothing over the last of its reach so no edge shows.
    static func falloff(_ distance: Double) -> Double {
        let near = exp(-distance / spillScale)
        let edge = max(0, min(1, (distance / spillReach - 0.55) / 0.45))
        return near * (1 - edge * edge * (3 - 2 * edge))
    }

    private static let spillStops = [0, 0.08, 0.16, 0.28, 0.42, 0.58, 0.78, 1.0]

    private static func stops(_ pattern: OpaquePointer, ink: PartyInk, strength: Double) {
        for stop in spillStops {
            cairo_pattern_add_color_stop_rgba(
                pattern, stop, ink.red, ink.green, ink.blue, strength * falloff(stop * spillReach))
        }
    }

    /// A tile's light on the ground around its glass: four edge gradients and four rounded corners,
    /// so the light falls off from the rounded rectangle itself and not from a circle. The tile's
    /// own area is left alone.
    static func spill(
        _ cr: OpaquePointer, rect: WatchRect, unit: Double, ink: PartyInk, strength: Double
    ) {
        let radius = 1.6 * unit
        let reach = spillReach * unit
        guard strength > 0.002, rect.width > 2 * radius + 1, rect.height > 2 * radius + 1 else { return }
        cairo_save(cr)
        cairo_set_operator(cr, CAIRO_OPERATOR_ADD)
        cairo_rectangle(cr, rect.x - reach - radius, rect.y - reach - radius, rect.width + 2 * (reach + radius), rect.height + 2 * (reach + radius))
        agentsRoundedRect(cr, x: rect.x, y: rect.y, width: rect.width, height: rect.height, radius: radius)
        cairo_set_fill_rule(cr, CAIRO_FILL_RULE_EVEN_ODD)
        cairo_clip(cr)
        let innerLeft = rect.x + radius
        let innerRight = rect.maxX - radius
        let innerTop = rect.y + radius
        let innerBottom = rect.maxY - radius
        let edges: [(from: (Double, Double), to: (Double, Double), box: (Double, Double, Double, Double))] = [
            ((0, rect.y), (0, rect.y - reach), (innerLeft, rect.y - reach, innerRight - innerLeft, reach)),
            ((0, rect.maxY), (0, rect.maxY + reach), (innerLeft, rect.maxY, innerRight - innerLeft, reach)),
            ((rect.x, 0), (rect.x - reach, 0), (rect.x - reach, innerTop, reach, innerBottom - innerTop)),
            ((rect.maxX, 0), (rect.maxX + reach, 0), (rect.maxX, innerTop, reach, innerBottom - innerTop)),
        ]
        for edge in edges {
            guard let pattern = cairo_pattern_create_linear(edge.from.0, edge.from.1, edge.to.0, edge.to.1) else { continue }
            stops(pattern, ink: ink, strength: strength)
            cairo_set_source(cr, pattern)
            cairo_rectangle(cr, edge.box.0, edge.box.1, edge.box.2, edge.box.3)
            cairo_fill(cr)
            cairo_pattern_destroy(pattern)
        }
        let corners: [(centre: (Double, Double), box: (Double, Double))] = [
            ((innerLeft, innerTop), (innerLeft - radius - reach, innerTop - radius - reach)),
            ((innerRight, innerTop), (innerRight, innerTop - radius - reach)),
            ((innerLeft, innerBottom), (innerLeft - radius - reach, innerBottom)),
            ((innerRight, innerBottom), (innerRight, innerBottom)),
        ]
        for corner in corners {
            guard let pattern = cairo_pattern_create_radial(
                corner.centre.0, corner.centre.1, radius, corner.centre.0, corner.centre.1, radius + reach)
            else { continue }
            stops(pattern, ink: ink, strength: strength)
            cairo_set_source(cr, pattern)
            cairo_rectangle(cr, corner.box.0, corner.box.1, radius + reach, radius + reach)
            cairo_fill(cr)
            cairo_pattern_destroy(pattern)
        }
        cairo_restore(cr)
    }

    /// Three very large, very faint blooms in the mood's colour, drifting on slow loops of their
    /// own: the Aurora field. Nothing here is brighter than four in a hundred.
    static func aurora(
        _ cr: OpaquePointer, width: Double, height: Double, ink: PartyInk, text: PartyInk, t: Double
    ) {
        let reach = 0.55 * max(width, height)
        let blooms: [(x: Double, y: Double, alpha: Double, mix: Double)] = [
            (0.28 + 0.12 * sin(t * 0.031), 0.36 + 0.10 * cos(t * 0.027), 0.040, 0),
            (0.72 + 0.10 * sin(t * 0.023 + 2), 0.64 + 0.12 * sin(t * 0.029 + 1), 0.034, 0.3),
            (0.50 + 0.18 * cos(t * 0.019), 0.22 + 0.10 * sin(t * 0.025 + 4), 0.028, 0.55),
        ]
        cairo_save(cr)
        cairo_set_operator(cr, CAIRO_OPERATOR_ADD)
        for bloom in blooms {
            let colour = ink.mixed(with: text, bloom.mix)
            let cx = bloom.x * width
            let cy = bloom.y * height
            guard let pattern = cairo_pattern_create_radial(cx, cy, 0, cx, cy, reach) else { continue }
            for stop in [0.0, 0.25, 0.5, 0.75, 1.0] {
                let soft = exp(-stop * stop * 3.6) * (1 - stop * stop * stop * stop)
                cairo_pattern_add_color_stop_rgba(pattern, stop, colour.red, colour.green, colour.blue, bloom.alpha * soft)
            }
            cairo_set_source(cr, pattern)
            cairo_paint(cr)
            cairo_pattern_destroy(pattern)
        }
        cairo_restore(cr)
    }

    /// A band of light spreading outward from a tile's edge, soft on both sides; the tile's own area
    /// is left alone. Three strokes of falling width and rising strength make the gaussian.
    static func ripple(
        _ cr: OpaquePointer, rect: WatchRect, corner: Double, grow: Double, width: Double, ink: PartyInk,
        alpha: Double, bounds: (Double, Double)
    ) {
        guard alpha > 0.002, rect.width > 1, rect.height > 1 else { return }
        cairo_save(cr)
        cairo_set_operator(cr, CAIRO_OPERATOR_ADD)
        cairo_rectangle(cr, 0, 0, bounds.0, bounds.1)
        agentsRoundedRect(cr, x: rect.x, y: rect.y, width: rect.width, height: rect.height, radius: corner)
        cairo_set_fill_rule(cr, CAIRO_FILL_RULE_EVEN_ODD)
        cairo_clip(cr)
        for (span, share) in [(4.0, 0.12), (2.0, 0.30), (0.8, 0.55)] {
            agentsRoundedRect(
                cr, x: rect.x - grow, y: rect.y - grow, width: rect.width + 2 * grow,
                height: rect.height + 2 * grow, radius: corner + grow)
            cairo_set_line_width(cr, max(1.5, width * span))
            ink.set(cr, alpha: alpha * share)
            cairo_stroke(cr)
        }
        cairo_restore(cr)
    }
}
