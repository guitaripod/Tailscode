import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// An eased scroll of one adjustment on a widget's own frame clock, ~300 ms from where the value
/// is to a target read afresh every frame.
final class FreshCanvasScroll: @unchecked Sendable {
    private static let duration = 0.3
    private let clock: UnsafeMutablePointer<GtkWidget>
    private let adjustment: UnsafeMutablePointer<GtkAdjustment>
    private let target: () -> Double?
    private let onFinish: () -> Void
    private var set: ((Double) -> Void)?
    private var tick: UInt = 0
    private var startedAt = 0.0
    private var from = 0.0

    init(
        clock: UnsafeMutablePointer<GtkWidget>, adjustment: UnsafeMutablePointer<GtkAdjustment>,
        target: @escaping () -> Double?, onFinish: @escaping () -> Void
    ) {
        self.clock = clock
        self.adjustment = adjustment
        self.target = target
        self.onFinish = onFinish
    }

    func start(reduceMotion: Bool, set: @escaping (Double) -> Void) {
        self.set = set
        from = gtk_adjustment_get_value(adjustment)
        if reduceMotion {
            if let value = target() { set(value) }
            onFinish()
            return
        }
        startedAt = CascadePainter.now
        g_object_ref(UnsafeMutableRawPointer(clock))
        let box = Unmanaged.passRetained(self).toOpaque()
        tick = UInt(
            tailscode_add_tick(
                clock,
                { raw in
                    guard let raw else { return }
                    Unmanaged<FreshCanvasScroll>.fromOpaque(raw).takeUnretainedValue().step()
                }, box))
    }

    private func step() {
        guard tick != 0 else { return }
        let progress: Double = min(1.0, (CascadePainter.now - startedAt) / Self.duration)
        let remaining: Double = 1.0 - progress
        let eased: Double = 1.0 - remaining * remaining * remaining
        if let value = target() {
            let delta: Double = value - from
            set?(from + delta * eased)
        }
        if progress >= 1 { finish() }
    }

    func cancel() {
        guard tick != 0 else { return }
        stopTick()
    }

    private func finish() {
        stopTick()
        onFinish()
    }

    private func stopTick() {
        tailscode_remove_tick(clock, guint(tick))
        tick = 0
        g_object_unref(UnsafeMutableRawPointer(clock))
        Unmanaged.passUnretained(self).release()
    }
}

/// Asks a question once a frame, on a widget's own frame clock, until it answers yes. A row
/// appended this frame is allocated on a later one, and a chained 16 ms timeout polling for it
/// lands off the compositor's beat — the rise then starts a frame late or two frames in one.
final class FrameWatch: @unchecked Sendable {
    private let ask: () -> Bool
    private var finished = false

    private init(ask: @escaping () -> Bool) {
        self.ask = ask
    }

    /// Starts asking on `clock`'s frames. `ask` returns true once it is done.
    @discardableResult
    static func run(on clock: UnsafeMutablePointer<GtkWidget>, _ ask: @escaping () -> Bool)
        -> FrameWatch
    {
        let watch = FrameWatch(ask: ask)
        _ = Gtk.releaseInstalled
        _ = tailscode_add_owned_tick(
            clock,
            { raw in
                guard let raw else { return 0 }
                let watch = Unmanaged<FrameWatch>.fromOpaque(raw).takeUnretainedValue()
                guard !watch.finished else { return 0 }
                if watch.ask() {
                    watch.finished = true
                    return 0
                }
                return 1
            }, Unmanaged.passRetained(watch).toOpaque())
        return watch
    }

    func cancel() {
        finished = true
    }
}
