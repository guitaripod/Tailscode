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
    private var lastPainted = 0.0
    private(set) var isActive = false
    private lazy var lap = RepeatingMotion { [weak self] in self?.step() }

    init() {
        area = tailscode_aura_new()
        stops = Ultracode.rainbowStops.flatMap { [$0.red, $0.green, $0.blue] }
        gtk_widget_set_visible(area, 0)
        paint(at: 0)
        RepeatingMotion.watch(area) { [weak self] in self?.relay() }
    }

    /// The drawing area itself, for the overlay that lays it over the prompt box.
    var widget: UnsafeMutablePointer<GtkWidget> { area }

    /// Whether the ring is turning right now, for a harness that has to prove it rather than watch
    /// it — a lit ring and a turning one are the same picture in any one frame.
    var isTurning: Bool { lap.isTurning }

    private static var now: Double { Double(g_get_monotonic_time()) / 1_000_000 }

    /// Reduced motion keeps the aura — the point of it is that a power is on, which is a fact and
    /// not a flourish — and only stops it moving.
    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        gtk_widget_set_visible(area, active ? 1 : 0)
        relay()
    }

    /// Reads the desk's mind again, and lays the lap or takes it off accordingly.
    ///
    /// A tier stays picked for as long as the conversation lasts, so an aura that asked only at the
    /// moment it lit would keep turning for the rest of that conversation under a preference
    /// already changed — and would never start again for a desk that allowed movement back. What a
    /// desk asking for less is left with is the ring itself, lit and still: a power being on is a
    /// fact, and the fact is the edge rather than the travel around it. An aura whose power is off
    /// has no fact to draw, so it stays dark through the change.
    private func relay() {
        guard isActive else {
            lap.lift()
            return
        }
        guard lap.lay(on: area, meaning: .turning) else {
            paint(at: 0)
            return
        }
        paint(at: Self.now)
    }

    /// One frame of the lap, at the tempo everything in this app that moves runs at.
    ///
    /// The lap turns in seconds, not frames, so painting it past that tempo buys nothing an eye can
    /// keep — and on a fast display an uncapped aura redraws every pane it wraps at the panel's own
    /// rate. Which tick the tempo owes is ``ActivityTuning/wantsFrame(at:lastDrawn:)``'s answer and
    /// not a comparison of its own, because the interval falls exactly on a 60Hz and 120Hz tick
    /// boundary, where a bare comparison silently drops to two thirds of the rate.
    private func step() {
        let time = Self.now
        guard ActivityTuning.wantsFrame(at: time, lastDrawn: lastPainted) else { return }
        lastPainted = time
        paint(at: time)
    }

    private func paint(at time: Double) {
        let sample = Ultracode.aura(at: time)
        stops.withUnsafeBufferPointer { buffer in
            tailscode_aura_set(
                area, sample.phase, sample.glow, buffer.baseAddress,
                Int32(Ultracode.rainbowStops.count))
        }
    }
}
