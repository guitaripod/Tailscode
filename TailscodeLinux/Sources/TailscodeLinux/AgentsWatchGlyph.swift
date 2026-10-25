import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// What a tile's state looks like as one mark. Colour is never the whole of it: each state has
/// its own shape and its own motion (a breathing orb, a knock, a crawling dash, a ripple, an
/// orbiting dot, a check, a cross, a square, a hatched disc), and each is still, fully lit, when the
/// desk asks for less movement. Pure cairo over numbers, so it allocates nothing per frame.
enum WatchGlyph {
    nonisolated(unsafe) private static let dashes: UnsafeMutablePointer<Double> = {
        let table = UnsafeMutablePointer<Double>.allocate(capacity: 2)
        table[0] = 1
        table[1] = 1
        return table
    }()

    static let amberShare = 0.85

    static func breath(_ t: Double, period: Double, animated: Bool) -> Double {
        animated ? 0.5 + 0.5 * sin(2 * .pi * t / period) : 0.6
    }

    static func knock(_ t: Double, period: Double, second: Double, animated: Bool) -> Double {
        guard animated else { return 0.35 }
        let p = t.truncatingRemainder(dividingBy: period)
        return max(bump(p), 0.8 * bump(p - second))
    }

    private static func bump(_ x: Double) -> Double { exp(-(x * x) / 0.0072) }

    static func paint(
        _ cr: OpaquePointer, size: Double, state: WallState, share: Double?, fade: Double,
        palette: WatchPalette, t: Double, animated: Bool
    ) {
        let centre = size / 2
        let ink = palette.ink(state)
        let ringRadius = size * 0.455
        let ringWidth = size * 0.058
        let coreRadius = size * 0.29
        switch state {
        case .working:
            contextRing(cr, centre, ringRadius, ringWidth, share, ink, palette)
            let swell = breath(t, period: 3.4, animated: animated)
            core(cr, centre, coreRadius * (0.93 + 0.07 * swell), ink, glow: 0.35 + 0.35 * swell)
        case .thinking:
            contextRing(cr, centre, ringRadius, ringWidth, share, ink, palette)
            let swell = breath(t, period: 7.5, animated: animated)
            core(cr, centre, coreRadius * (0.9 + 0.06 * swell), ink, glow: 0.2 + 0.3 * swell)
        case .needsYou(let urgency):
            let overdue = urgency == .overdue
            let period = overdue ? 2.6 : 4.2
            let second = overdue ? 0.26 : 0.34
            let hit = knock(t, period: period, second: second, animated: animated)
            contextRing(cr, centre, ringRadius, ringWidth, share, ink, palette)
            if animated { waves(cr, centre, coreRadius, ringRadius, ink, t, period, second) }
            core(cr, centre, coreRadius * (0.9 + 0.2 * hit), ink, glow: 0.45 + 0.5 * hit)
        case .retrying:
            contextRing(cr, centre, ringRadius * 0.82, ringWidth, share, ink, palette, track: false)
            crawl(cr, centre, ringRadius, ringWidth, ink, t, animated)
            core(cr, centre, coreRadius * 0.45, ink, glow: 0.2)
        case .quiet:
            contextRing(cr, centre, ringRadius, ringWidth, share, ink, palette)
            if animated { ripple(cr, centre, coreRadius, ringRadius, ink, t) }
            flat(cr, centre, coreRadius * 0.92, ink)
        case .background(let stuck):
            hollow(cr, centre, ringRadius * 0.86, ringWidth * 1.25, ink, t, animated, still: stuck)
        case .finished(let outcome):
            finish(cr, centre, size, outcome, ink, palette, fade)
        case .away:
            hatched(cr, centre, size * 0.4, ink)
        }
    }

    private static func disc(_ cr: OpaquePointer, _ x: Double, _ y: Double, _ r: Double) {
        cairo_new_path(cr)
        cairo_arc(cr, x, y, r, 0, 2 * .pi)
    }

    private static func contextRing(
        _ cr: OpaquePointer, _ c: Double, _ radius: Double, _ width: Double, _ share: Double?,
        _ ink: PartyInk, _ palette: WatchPalette, track: Bool = true
    ) {
        guard let share else { return }
        cairo_set_line_width(cr, width)
        if track {
            disc(cr, c, c, radius)
            palette.text.set(cr, alpha: 0.12)
            cairo_stroke(cr)
        }
        let full = max(0, min(1, share))
        guard full > 0.005 else { return }
        let hot = full > amberShare
        let arc = hot ? (ink == palette.needs ? palette.overdue : palette.needs) : ink
        arc.set(cr, alpha: 0.95)
        cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
        cairo_new_path(cr)
        cairo_arc(cr, c, c, radius, -.pi / 2, -.pi / 2 + 2 * .pi * full)
        cairo_stroke(cr)
        cairo_set_line_cap(cr, CAIRO_LINE_CAP_BUTT)
    }

    private static func core(
        _ cr: OpaquePointer, _ c: Double, _ r: Double, _ ink: PartyInk, glow: Double
    ) {
        if let halo = cairo_pattern_create_radial(c, c, r * 0.5, c, c, r * 1.68) {
            cairo_pattern_add_color_stop_rgba(halo, 0, ink.red, ink.green, ink.blue, 0.5 * glow)
            cairo_pattern_add_color_stop_rgba(halo, 1, ink.red, ink.green, ink.blue, 0)
            cairo_set_source(cr, halo)
            disc(cr, c, c, r * 1.68)
            cairo_fill(cr)
            cairo_pattern_destroy(halo)
        }
        let bright = ink.lifted(0.55)
        let deep = ink.sunk(0.3)
        if let body = cairo_pattern_create_radial(c - r * 0.35, c - r * 0.4, r * 0.08, c, c, r) {
            cairo_pattern_add_color_stop_rgba(body, 0, bright.red, bright.green, bright.blue, 1)
            cairo_pattern_add_color_stop_rgba(body, 0.55, ink.red, ink.green, ink.blue, 1)
            cairo_pattern_add_color_stop_rgba(body, 1, deep.red, deep.green, deep.blue, 1)
            cairo_set_source(cr, body)
            disc(cr, c, c, r)
            cairo_fill(cr)
            cairo_pattern_destroy(body)
        }
        cairo_save(cr)
        cairo_translate(cr, c - r * 0.3, c - r * 0.45)
        cairo_scale(cr, 0.5, 0.3)
        cairo_set_source_rgba(cr, 1, 1, 1, 0.5)
        cairo_arc(cr, 0, 0, r * 0.7, 0, 2 * .pi)
        cairo_fill(cr)
        cairo_restore(cr)
    }

    private static func flat(_ cr: OpaquePointer, _ c: Double, _ r: Double, _ ink: PartyInk) {
        disc(cr, c, c, r)
        ink.set(cr, alpha: 0.9)
        cairo_fill(cr)
        disc(cr, c, c, r)
        ink.lifted(0.25).set(cr, alpha: 0.5)
        cairo_set_line_width(cr, max(1, r * 0.08))
        cairo_stroke(cr)
    }

    private static func waves(
        _ cr: OpaquePointer, _ c: Double, _ core: Double, _ outer: Double, _ ink: PartyInk,
        _ t: Double, _ period: Double, _ second: Double
    ) {
        let p = t.truncatingRemainder(dividingBy: period)
        var start = 0.0
        for _ in 0..<2 {
            let q = (p - start) / 1.1
            if q >= 0 && q < 1 {
                let radius = core + (outer * 1.12 - core) * q
                disc(cr, c, c, radius)
                ink.set(cr, alpha: 0.6 * (1 - q) * (1 - q))
                cairo_set_line_width(cr, max(1.2, core * 0.12))
                cairo_stroke(cr)
            }
            start = second
        }
    }

    private static func crawl(
        _ cr: OpaquePointer, _ c: Double, _ radius: Double, _ width: Double, _ ink: PartyInk,
        _ t: Double, _ animated: Bool
    ) {
        dashes[0] = width * 2.1
        dashes[1] = width * 1.5
        cairo_set_dash(cr, dashes, 2, animated ? -t * radius * 0.55 : 0)
        cairo_set_line_width(cr, width * 1.15)
        disc(cr, c, c, radius)
        ink.set(cr, alpha: 0.95)
        cairo_stroke(cr)
        cairo_set_dash(cr, nil, 0, 0)
    }

    private static func ripple(
        _ cr: OpaquePointer, _ c: Double, _ core: Double, _ outer: Double, _ ink: PartyInk, _ t: Double
    ) {
        let phase = t.truncatingRemainder(dividingBy: 60) / 6
        guard phase < 1 else { return }
        disc(cr, c, c, core + (outer * 1.1 - core) * phase)
        ink.lifted(0.2).set(cr, alpha: 0.4 * (1 - phase))
        cairo_set_line_width(cr, max(1, core * 0.1))
        cairo_stroke(cr)
    }

    private static func hollow(
        _ cr: OpaquePointer, _ c: Double, _ radius: Double, _ width: Double, _ ink: PartyInk,
        _ t: Double, _ animated: Bool, still: Bool
    ) {
        disc(cr, c, c, radius)
        ink.set(cr, alpha: still ? 0.95 : 0.7)
        cairo_set_line_width(cr, width)
        cairo_stroke(cr)
        disc(cr, c, c, radius * 0.5)
        ink.set(cr, alpha: 0.16)
        cairo_set_line_width(cr, width * 0.6)
        cairo_stroke(cr)
        let angle = still ? -.pi / 2 : (animated ? t * 2 * .pi / 6.5 - .pi / 2 : 0.8 * .pi)
        let x = c + cos(angle) * radius
        let y = c + sin(angle) * radius
        disc(cr, x, y, width * 1.35)
        ink.lifted(0.35).set(cr)
        cairo_fill(cr)
        disc(cr, x, y, width * 2.4)
        ink.set(cr, alpha: 0.22)
        cairo_fill(cr)
    }

    private static func finish(
        _ cr: OpaquePointer, _ c: Double, _ size: Double, _ outcome: WallOutcome, _ ink: PartyInk,
        _ palette: WatchPalette, _ fade: Double
    ) {
        let cooled = ink.mixed(with: palette.dim, 0.7 * fade)
        let radius = size * 0.36
        let mark = size * 0.15
        cairo_set_line_cap(cr, CAIRO_LINE_CAP_ROUND)
        cairo_set_line_join(cr, CAIRO_LINE_JOIN_ROUND)
        switch outcome {
        case .stopped:
            agentsRoundedRect(cr, x: c - radius * 0.72, y: c - radius * 0.72, width: radius * 1.44, height: radius * 1.44, radius: radius * 0.22)
            cooled.set(cr, alpha: 0.9)
            cairo_fill(cr)
        case .unknown:
            disc(cr, c, c, radius)
            cooled.set(cr, alpha: 0.8)
            cairo_set_line_width(cr, size * 0.06)
            cairo_stroke(cr)
        case .done, .failed:
            disc(cr, c, c, radius)
            cooled.set(cr, alpha: 0.2)
            cairo_fill_preserve(cr)
            cooled.set(cr)
            cairo_set_line_width(cr, size * 0.07)
            cairo_stroke(cr)
            cairo_set_line_width(cr, size * 0.085)
            if outcome == .done {
                cairo_move_to(cr, c - mark * 1.15, c + mark * 0.05)
                cairo_line_to(cr, c - mark * 0.3, c + mark * 0.9)
                cairo_line_to(cr, c + mark * 1.25, c - mark * 0.85)
            } else {
                cairo_move_to(cr, c - mark, c - mark)
                cairo_line_to(cr, c + mark, c + mark)
                cairo_move_to(cr, c + mark, c - mark)
                cairo_line_to(cr, c - mark, c + mark)
            }
            cairo_stroke(cr)
        }
        cairo_set_line_cap(cr, CAIRO_LINE_CAP_BUTT)
    }

    private static func hatched(_ cr: OpaquePointer, _ c: Double, _ r: Double, _ ink: PartyInk) {
        cairo_save(cr)
        disc(cr, c, c, r)
        ink.set(cr, alpha: 0.12)
        cairo_fill_preserve(cr)
        cairo_clip_preserve(cr)
        ink.set(cr, alpha: 0.7)
        cairo_set_line_width(cr, max(1, r * 0.07))
        var stripe = c - r * 2
        while stripe < c + r * 2 {
            cairo_move_to(cr, stripe, c + r)
            cairo_line_to(cr, stripe + r * 2, c - r)
            stripe += r * 0.34
        }
        cairo_stroke(cr)
        cairo_restore(cr)
        disc(cr, c, c, r)
        ink.set(cr, alpha: 0.8)
        cairo_set_line_width(cr, max(1, r * 0.08))
        cairo_stroke(cr)
    }
}
