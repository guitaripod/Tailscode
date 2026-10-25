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

/// The glass orb the sidebar's agents face wears: a core that swells with the mood under a soft
/// highlight, a halo that brightens with it, and an orbit of small lights, one per running
/// session (``AgentsOrbit``). Idle with nothing running is a dim bead inside a calm still ring. It
/// lives on its own frame clock only while its mood or its orbit moves and the desk allows
/// movement, and the clock belongs to its widget, so a sidebar nobody can see is not drawn.
final class AgentsMiniOrb: @unchecked Sendable {
    let canvas: AgentsCanvas
    private let size: Double
    private(set) var mood: AgentsMood = .idle
    private(set) var running = 0
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
            Self.paint(
                cr, size: self.size, mood: self.mood, time: Self.now, animated: RepeatingMotion.allowed,
                running: self.running)
        }
        RepeatingMotion.watch(canvas.widget) { [weak self] in self?.relay() }
    }

    static var now: Double { Double(g_get_monotonic_time()) / 1_000_000 }

    func set(mood next: AgentsMood, running count: Int = 0) {
        guard next != mood || count != running else { return }
        mood = next
        running = count
        relay()
    }

    /// What the lap stands for: the mood's own movement, or a slow drift of the orbit alone when
    /// only background work runs under a quiet face.
    private var meaning: ActivityMotion {
        mood == .idle && running > 0 ? .working : mood.motion
    }

    private func relay() {
        _ = lap.lay(on: canvas.widget, meaning: meaning)
        canvas.redraw()
    }

    private func step() {
        let time = Self.now
        guard ActivityTuning.wantsFrame(at: time, lastDrawn: lastDrawn) else { return }
        lastDrawn = time
        canvas.redraw()
    }

    @discardableResult
    static func paint(
        _ cr: OpaquePointer, size: Double, mood: AgentsMood, time: Double, animated: Bool,
        running: Int = 0
    ) -> Int {
        let inks = AgentsInks()
        let tone = inks.ink(mood.tone)
        let swell = AgentsSwell.at(mood, time: time, animated: animated)
        let centre = size / 2
        if mood != .idle { halo(cr, centre: centre, radius: size * 0.5, tone: tone, swell: swell) }
        shell(cr, centre: centre, radius: size * 0.3, tone: tone, mood: mood)
        let core = size * 0.22 * (1 + 0.1 * swell)
        glass(cr, centre: centre, radius: core, tone: tone, lit: mood == .idle ? 0.6 : 1)
        return AgentsOrbit.paint(
            cr, centre: centre, radius: size * 0.43, tone: tone, mood: mood, running: running,
            time: time, animated: animated, swell: swell)
    }

    private static func halo(
        _ cr: OpaquePointer, centre: Double, radius: Double, tone: PartyInk, swell: Double
    ) {
        guard let gradient = cairo_pattern_create_radial(centre, centre, radius * 0.25, centre, centre, radius)
        else { return }
        cairo_pattern_add_color_stop_rgba(gradient, 0, tone.red, tone.green, tone.blue, 0.1 + 0.3 * swell)
        cairo_pattern_add_color_stop_rgba(gradient, 1, tone.red, tone.green, tone.blue, 0)
        cairo_set_source(cr, gradient)
        cairo_arc(cr, centre, centre, radius, 0, 2 * .pi)
        cairo_fill(cr)
        cairo_pattern_destroy(gradient)
    }

    private static func shell(
        _ cr: OpaquePointer, centre: Double, radius: Double, tone: PartyInk, mood: AgentsMood
    ) {
        tone.set(cr, alpha: mood == .idle ? 0.18 : 0.3)
        cairo_set_line_width(cr, 1)
        cairo_arc(cr, centre, centre, radius, 0, 2 * .pi)
        cairo_stroke(cr)
    }

    private static func glass(
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
            gradient, 1, tone.red * 0.78, tone.green * 0.78, tone.blue * 0.78, lit)
        cairo_set_source(cr, gradient)
        cairo_arc(cr, centre, centre, radius, 0, 2 * .pi)
        cairo_fill(cr)
        cairo_pattern_destroy(gradient)
        cairo_save(cr)
        cairo_translate(cr, centre - radius * 0.3, centre - radius * 0.45)
        cairo_scale(cr, 0.5, 0.3)
        cairo_set_source_rgba(cr, 1, 1, 1, 0.6 * lit)
        cairo_arc(cr, 0, 0, radius * 0.75, 0, 2 * .pi)
        cairo_fill(cr)
        cairo_restore(cr)
    }
}
