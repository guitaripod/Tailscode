import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// Whether the one-time shimmer has been seen, kept in the settings file so it is once ever and
/// not once per launch. A check and the harness hand it a memory of their own.
struct AgentsShimmerMemory: Sendable {
    let seen: @Sendable () -> Bool
    let remember: @Sendable () -> Void

    static let key = "tailscode.agents.entryShimmered"

    static let settings = AgentsShimmerMemory(
        seen: { UserDefaults.standard.bool(forKey: key) },
        remember: { SettingsFile.set(true, forKey: key) })
}

/// What lies over the Agents row without taking a click: a soft amber light along the inside of
/// its border that breathes while something waits on the person, and the one sweep of light that
/// tells a first-time reader the row is alive. Both are painted inside the row's own rounded
/// rectangle and clipped to it, so nothing bleeds past the card.
final class AgentsEntryGlow: @unchecked Sendable {
    static let radius = 10.0
    static let sweepDuration = 1.15

    let canvas = AgentsCanvas(width: 1, height: 1)
    private(set) var mood: AgentsMood = .idle
    private(set) var sweepStart: Double?
    private(set) var sweeps = 0
    private var lastDrawn = 0.0
    private lazy var lap = RepeatingMotion { [weak self] in self?.step() }
    var onFrame: ((Double) -> Void)?
    var onStill: (() -> Void)?

    var widget: UnsafeMutablePointer<GtkWidget> { canvas.widget }
    var isTurning: Bool { lap.isTurning }
    var isSweeping: Bool { sweepStart != nil }

    init() {
        gtk_widget_set_can_target(canvas.widget, 0)
        gtk_widget_set_focusable(canvas.widget, 0)
        gtk_widget_set_hexpand(canvas.widget, 1)
        gtk_widget_set_vexpand(canvas.widget, 1)
        tailscode_set_accessible_hidden(canvas.widget, 1)
        canvas.paint = { [weak self] cr, width, height in self?.paint(cr, width: width, height: height) }
        RepeatingMotion.watch(canvas.widget) { [weak self] in self?.relay() }
    }

    func set(mood next: AgentsMood) {
        guard next != mood else { return }
        mood = next
        relay()
    }

    func startSweep() {
        sweepStart = AgentsMiniOrb.now
        sweeps += 1
        relay()
    }

    private func relay() {
        let moving = mood.motion.isAnimated || sweepStart != nil
        if moving, RepeatingMotion.allowed {
            _ = lap.lay(on: canvas.widget, meaning: .working)
        } else {
            lap.lift()
            sweepStart = nil
            onStill?()
        }
        canvas.redraw()
    }

    private func step() {
        let time = AgentsMiniOrb.now
        guard ActivityTuning.wantsFrame(at: time, lastDrawn: lastDrawn) else { return }
        lastDrawn = time
        if let start = sweepStart, time - start > Self.sweepDuration {
            sweepStart = nil
            if !mood.motion.isAnimated { lap.lift() }
        }
        onFrame?(time)
        canvas.redraw()
    }

    private func paint(_ cr: OpaquePointer, width: Double, height: Double) {
        let inks = AgentsInks()
        let time = AgentsMiniOrb.now
        cairo_save(cr)
        agentsRoundedRect(cr, x: 0, y: 0, width: width, height: height, radius: Self.radius)
        cairo_clip(cr)
        if mood == .needs { border(cr, width: width, height: height, ink: inks.attention, time: time) }
        if let start = sweepStart {
            let light = (inks.canvas.red + inks.canvas.green + inks.canvas.blue) > 1.5
            sweep(
                cr, width: width, height: height, strength: light ? 0.6 : 0.24,
                progress: (time - start) / Self.sweepDuration)
        }
        cairo_restore(cr)
    }

    private func border(_ cr: OpaquePointer, width: Double, height: Double, ink: PartyInk, time: Double) {
        let swell = AgentsSwell.at(.needs, time: time, animated: RepeatingMotion.allowed)
        let layers = 6
        for layer in 0..<layers {
            let inset = 0.5 + Double(layer) * 1.1
            let fade = 1 - Double(layer) / Double(layers)
            agentsRoundedRect(
                cr, x: inset, y: inset, width: width - inset * 2, height: height - inset * 2,
                radius: max(1, Self.radius - inset))
            ink.set(cr, alpha: (0.08 + 0.34 * swell) * fade)
            cairo_set_line_width(cr, 1.3)
            cairo_stroke(cr)
        }
    }

    private func sweep(
        _ cr: OpaquePointer, width: Double, height: Double, strength: Double, progress: Double
    ) {
        let eased = 1 - pow(1 - min(1, max(0, progress)), 2)
        let band = width * 0.4
        let x = -band + (width + band * 2) * eased
        guard let gradient = cairo_pattern_create_linear(x - band / 2, 0, x + band / 2, height * 0.4)
        else { return }
        cairo_pattern_add_color_stop_rgba(gradient, 0, 1, 1, 1, 0)
        cairo_pattern_add_color_stop_rgba(gradient, 0.5, 1, 1, 1, strength)
        cairo_pattern_add_color_stop_rgba(gradient, 1, 1, 1, 1, 0)
        cairo_set_source(cr, gradient)
        cairo_rectangle(cr, 0, 0, width, height)
        cairo_fill(cr)
        cairo_pattern_destroy(gradient)
    }
}
