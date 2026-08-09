import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The pane's other hand: it holds the ultracode aura around the prompt box and turns it.
///
/// Frames come from `gtk_widget_add_tick_callback`, like every other moving thing here, and the
/// phase is read off the monotonic clock rather than counted up frame by frame — a dropped frame
/// then costs a frame and not the rhythm, which is the difference between light travelling around
/// a box and something stuttering around it. A widget with no frame clock is a widget nobody can
/// see, so a pane tiled behind another stops painting on its own.
final class AuraPainter: @unchecked Sendable {
    private let area: UnsafeMutablePointer<GtkWidget>
    private let stops: [Double]
    private var tick: UInt = 0
    private var lastPainted = 0.0
    /// The lap turns in seconds, not frames, so drawing it past thirty a second buys nothing an
    /// eye can keep — and on a fast display an uncapped aura redraws every pane it wraps at the
    /// panel's own rate. Same cap as the orb: a skipped frame costs a frame, never the phase.
    private static let frameInterval = 1.0 / 30.0
    private(set) var isActive = false

    init() {
        area = tailscode_aura_new()
        stops = Ultracode.rainbowStops.flatMap { [$0.red, $0.green, $0.blue] }
        gtk_widget_set_visible(area, 0)
        paint(at: 0)
    }

    /// The drawing area itself, for the overlay that lays it over the prompt box.
    var widget: UnsafeMutablePointer<GtkWidget> { area }

    private static var now: Double { Double(g_get_monotonic_time()) / 1_000_000 }

    /// Reduced motion keeps the aura — the point of it is that a power is on, which is a fact and
    /// not a flourish — and only stops it moving.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        gtk_widget_set_visible(area, active ? 1 : 0)
        guard active else {
            stop()
            return
        }
        guard CascadePainter.motionAllowed else {
            paint(at: 0)
            return
        }
        paint(at: Self.now)
        start()
    }

    private func start() {
        guard tick == 0 else { return }
        g_object_ref(UnsafeMutableRawPointer(area))
        let box = Unmanaged.passUnretained(self).toOpaque()
        tick = UInt(
            tailscode_add_tick(
                area,
                { raw in
                    guard let raw else { return }
                    let painter = Unmanaged<AuraPainter>.fromOpaque(raw).takeUnretainedValue()
                    let time = AuraPainter.now
                    guard time - painter.lastPainted >= AuraPainter.frameInterval else { return }
                    painter.lastPainted = time
                    painter.paint(at: time)
                }, box))
    }

    private func stop() {
        guard tick != 0 else { return }
        tailscode_remove_tick(area, guint(tick))
        tick = 0
        g_object_unref(UnsafeMutableRawPointer(area))
    }

    private func paint(at time: Double) {
        let sample = Ultracode.aura(at: time)
        stops.withUnsafeBufferPointer { buffer in
            tailscode_aura_set(
                area, sample.phase, sample.glow, buffer.baseAddress,
                Int32(Ultracode.rainbowStops.count))
        }
    }

    deinit { stop() }
}
