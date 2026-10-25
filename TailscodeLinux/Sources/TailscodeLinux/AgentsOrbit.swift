import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The ring of small lights that circles the sidebar's orb: one for each running session, five at
/// most and a plus mark past that, turning slowly while things work, faster and amber while
/// something waits on the person. With the desk asking for less movement the lights keep their
/// places on the ring and stand still, so the count reads the same in a still frame.
enum AgentsOrbit {
    static let cap = 5

    static func shown(_ running: Int) -> Int { min(cap, max(0, running)) }

    static func overflows(_ running: Int) -> Bool { running > cap }

    /// Seconds for one lap.
    static func period(_ mood: AgentsMood) -> Double {
        switch mood {
        case .idle: return 42
        case .working: return 18
        case .needs: return 6.5
        }
    }

    /// Where light `index` of `count` sits, in radians from the right, the first starting at the top.
    static func angle(index: Int, count: Int, mood: AgentsMood, time: Double, animated: Bool) -> Double {
        let phase = animated ? (time.truncatingRemainder(dividingBy: period(mood))) / period(mood) : 0
        return -.pi / 2 + 2 * .pi * (Double(index) / Double(max(1, count)) + phase)
    }

    /// Paints the track, the lights and the plus mark, and says how many lights it drew.
    @discardableResult
    static func paint(
        _ cr: OpaquePointer, centre: Double, radius: Double, tone: PartyInk, mood: AgentsMood,
        running: Int, time: Double, animated: Bool, swell: Double
    ) -> Int {
        tone.set(cr, alpha: mood == .idle ? 0.26 : 0.2 + 0.32 * swell)
        cairo_set_line_width(cr, 1)
        cairo_arc(cr, centre, centre, radius, 0, 2 * .pi)
        cairo_stroke(cr)
        let count = shown(running)
        for index in 0..<count {
            let theta = angle(index: index, count: count, mood: mood, time: time, animated: animated)
            light(cr, x: centre + radius * cos(theta), y: centre + radius * sin(theta), tone: tone, mood: mood)
        }
        if overflows(running) { plus(cr, x: centre + radius * 0.98, y: centre - radius * 0.98, tone: tone) }
        return count
    }

    private static func light(_ cr: OpaquePointer, x: Double, y: Double, tone: PartyInk, mood: AgentsMood) {
        if let glow = cairo_pattern_create_radial(x, y, 0, x, y, 4.6) {
            cairo_pattern_add_color_stop_rgba(glow, 0, tone.red, tone.green, tone.blue, mood == .idle ? 0.2 : 0.5)
            cairo_pattern_add_color_stop_rgba(glow, 1, tone.red, tone.green, tone.blue, 0)
            cairo_set_source(cr, glow)
            cairo_arc(cr, x, y, 4.6, 0, 2 * .pi)
            cairo_fill(cr)
            cairo_pattern_destroy(glow)
        }
        tone.set(cr, alpha: mood == .idle ? 0.7 : 1)
        cairo_arc(cr, x, y, 2, 0, 2 * .pi)
        cairo_fill(cr)
        cairo_set_source_rgba(cr, 1, 1, 1, 0.75)
        cairo_arc(cr, x - 0.5, y - 0.5, 0.7, 0, 2 * .pi)
        cairo_fill(cr)
    }

    private static func plus(_ cr: OpaquePointer, x: Double, y: Double, tone: PartyInk) {
        tone.set(cr, alpha: 0.95)
        cairo_set_line_width(cr, 1.3)
        cairo_move_to(cr, x - 2.2, y)
        cairo_line_to(cr, x + 2.2, y)
        cairo_move_to(cr, x, y - 2.2)
        cairo_line_to(cr, x, y + 2.2)
        cairo_stroke(cr)
    }
}
