import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The one frame clock a brain runs on, laid on a widget only while something on that brain moves.
///
/// A settled head draws once and owns no clock at all: stillness rendered thirty times a second is
/// a fan spinning for a picture that is finished. While it runs, the clock asks the display for
/// frames and the owner answers only the ones its tempo owes — the activity grid for the head's
/// own breathing, every frame of the display for a dive or a scrub. Whichever the tempo, the owner
/// reads absolute time, so a skipped frame costs a frame and never the phase.
///
/// The clock holds no reference on the widget it runs on: the widget owns the view that owns the
/// clock, so a reference the other way is a row nothing can ever finalize. A widget torn down takes
/// its frame callbacks with it, which empties the link, and that is how `stop` knows not to reach
/// into a widget that is gone.
final class BrainClock {
    private weak var link: Link?
    private var widget: UnsafeMutablePointer<GtkWidget>?
    private var tick: UInt = 0
    private var lastDrawn = 0.0
    private let step: (Double) -> Void

    private final class Link {
        weak var clock: BrainClock?
        init(_ clock: BrainClock) { self.clock = clock }
    }

    init(step: @escaping (Double) -> Void) {
        self.step = step
    }

    static var now: Double { Double(g_get_monotonic_time()) / 1_000_000 }

    var isRunning: Bool { tick != 0 && link != nil }

    /// The rate the governor lets this window's clocks run at, the activity tempo or less.
    static var activityRate: Double {
        let cap = CascadeBudget.budget.tickCap
        return cap > 0 ? min(ActivityTuning.frameRate, cap) : 0
    }

    /// Lays the clock on `widget`, replacing any earlier one. `tempo` decides which ticks the owner
    /// is called on.
    func run(on widget: UnsafeMutablePointer<GtkWidget>, tempo: NeuralTempo) {
        guard tempo != .stopped else {
            stop()
            return
        }
        if isRunning, self.widget == widget, self.tempo == tempo { return }
        stop()
        self.tempo = tempo
        _ = Gtk.releaseInstalled
        self.widget = widget
        lastDrawn = 0
        let link = Link(self)
        self.link = link
        tick = UInt(
            tailscode_add_owned_tick(
                widget,
                { raw in
                    guard let raw,
                        let clock = Unmanaged<Link>.fromOpaque(raw).takeUnretainedValue().clock
                    else { return 0 }
                    clock.tickOnce()
                    return 1
                }, Unmanaged.passRetained(link).toOpaque()))
    }

    private(set) var tempo: NeuralTempo = .stopped

    func stop() {
        guard let widget else { return }
        if tick != 0, link != nil { tailscode_remove_tick(widget, guint(tick)) }
        tick = 0
        link = nil
        self.widget = nil
        tempo = .stopped
    }

    private func tickOnce() {
        let time = Self.now
        if tempo == .activity {
            guard ActivityTuning.wantsFrame(at: time, lastDrawn: lastDrawn, rate: Self.activityRate)
            else { return }
        }
        lastDrawn = time
        step(time)
    }

    deinit { stop() }
}
