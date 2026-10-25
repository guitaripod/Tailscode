import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// How far into its swell a mood is at an instant, in `0...1`. The numbers come from the activity
/// vocabulary, so the sidebar's orb breathes and knocks exactly as a row's badge does, and a
/// desk that asked for less movement gets the lit, still end of the same swell.
enum AgentsSwell {
    static func at(_ mood: AgentsMood, time: Double, animated: Bool) -> Double {
        switch mood {
        case .idle: return 0
        case .working:
            guard animated else { return 0.6 }
            return fraction(
                mood.motion.intensity(at: time), floor: ActivityTuning.breathFloor)
        case .needs:
            guard animated else { return 0.8 }
            return fraction(
                mood.motion.intensity(at: time), floor: ActivityTuning.heartbeatFloor)
        }
    }

    private static func fraction(_ intensity: Double, floor: Double) -> Double {
        min(1, max(0, (intensity - floor) / max(0.0001, 1 - floor)))
    }
}

/// The small glass orb the sidebar's agents face wears: a core that swells with the mood, a halo
/// that brightens with it and a ring that holds its shape, drawn from the palette's own tone
/// slots. Idle is a dim, still bead. It lives on its own frame clock only while its mood moves
/// and the desk allows movement, and the clock belongs to its widget, so a sidebar nobody can see
/// is not drawn.
final class AgentsMiniOrb: @unchecked Sendable {
    let canvas: AgentsCanvas
    private let size: Double
    private(set) var mood: AgentsMood = .idle
    private var lastDrawn = 0.0
    private lazy var lap = RepeatingMotion { [weak self] in self?.step() }

    var widget: UnsafeMutablePointer<GtkWidget> { canvas.widget }
    var isTurning: Bool { lap.isTurning }
    var draws: Int { canvas.draws }

    init(size: Int32) {
        self.size = Double(size)
        canvas = AgentsCanvas(width: size, height: size)
        gtk_widget_set_valign(canvas.widget, GTK_ALIGN_CENTER)
        gtk_widget_set_halign(canvas.widget, GTK_ALIGN_CENTER)
        tailscode_set_accessible_hidden(canvas.widget, 1)
        canvas.paint = { [weak self] cr, _, _ in
            guard let self else { return }
            Self.paint(cr, size: self.size, mood: self.mood, time: Self.now, animated: RepeatingMotion.allowed)
        }
        RepeatingMotion.watch(canvas.widget) { [weak self] in self?.relay() }
    }

    static var now: Double { Double(g_get_monotonic_time()) / 1_000_000 }

    func set(mood next: AgentsMood) {
        guard next != mood else { return }
        mood = next
        relay()
    }

    private func relay() {
        _ = lap.lay(on: canvas.widget, meaning: mood.motion)
        canvas.redraw()
    }

    private func step() {
        let time = Self.now
        guard ActivityTuning.wantsFrame(at: time, lastDrawn: lastDrawn) else { return }
        lastDrawn = time
        canvas.redraw()
    }

    static func paint(_ cr: OpaquePointer, size: Double, mood: AgentsMood, time: Double, animated: Bool) {
        let inks = AgentsInks()
        let tone = inks.ink(mood.tone)
        let swell = AgentsSwell.at(mood, time: time, animated: animated)
        let centre = size / 2
        if mood != .idle { halo(cr, centre: centre, radius: size * 0.5, tone: tone, swell: swell) }
        ring(cr, centre: centre, radius: size * 0.4, tone: tone, mood: mood, swell: swell)
        core(
            cr, centre: centre, radius: size * 0.27 * (1 + 0.1 * swell), tone: tone,
            lit: mood == .idle ? 0.6 : 1)
    }

    private static func halo(
        _ cr: OpaquePointer, centre: Double, radius: Double, tone: PartyInk, swell: Double
    ) {
        guard let gradient = cairo_pattern_create_radial(centre, centre, radius * 0.25, centre, centre, radius)
        else { return }
        cairo_pattern_add_color_stop_rgba(gradient, 0, tone.red, tone.green, tone.blue, 0.1 + 0.34 * swell)
        cairo_pattern_add_color_stop_rgba(gradient, 1, tone.red, tone.green, tone.blue, 0)
        cairo_set_source(cr, gradient)
        cairo_arc(cr, centre, centre, radius, 0, 2 * .pi)
        cairo_fill(cr)
        cairo_pattern_destroy(gradient)
    }

    private static func ring(
        _ cr: OpaquePointer, centre: Double, radius: Double, tone: PartyInk, mood: AgentsMood,
        swell: Double
    ) {
        tone.set(cr, alpha: mood == .idle ? 0.28 : 0.3 + 0.4 * swell)
        cairo_set_line_width(cr, 1)
        cairo_arc(cr, centre, centre, radius, 0, 2 * .pi)
        cairo_stroke(cr)
    }

    private static func core(
        _ cr: OpaquePointer, centre: Double, radius: Double, tone: PartyInk, lit: Double
    ) {
        guard
            let gradient = cairo_pattern_create_radial(
                centre - radius * 0.35, centre - radius * 0.4, radius * 0.1, centre, centre, radius)
        else { return }
        let bright = (
            red: tone.red + (1 - tone.red) * 0.62, green: tone.green + (1 - tone.green) * 0.62,
            blue: tone.blue + (1 - tone.blue) * 0.62
        )
        cairo_pattern_add_color_stop_rgba(gradient, 0, bright.red, bright.green, bright.blue, lit)
        cairo_pattern_add_color_stop_rgba(gradient, 0.5, tone.red, tone.green, tone.blue, lit)
        cairo_pattern_add_color_stop_rgba(
            gradient, 1, tone.red * 0.82, tone.green * 0.82, tone.blue * 0.82, lit)
        cairo_set_source(cr, gradient)
        cairo_arc(cr, centre, centre, radius, 0, 2 * .pi)
        cairo_fill(cr)
        cairo_pattern_destroy(gradient)
    }
}
