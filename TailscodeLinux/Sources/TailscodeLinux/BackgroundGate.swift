import CGtkShim
import Foundation
import TailscodeCore

/// Whether the person can see the window, and how hard the governor is shedding, as one answer for
/// the pollers that serve nobody while the window is hidden or the loop is the bottleneck.
///
/// A poller asks ``untilVisible()`` before it works, so a minimised or fully covered window costs
/// no fetches, no processes and no relayouts, and the poll it missed runs once when the window is
/// seen again rather than once per period it slept through. ``sleep(_:)`` stretches the period at
/// strained and critical (``BackgroundCadence``). The clock, the governor and everything that
/// keeps the app honest (the watchdog, the flight recorder) are not gated.
final class BackgroundGate: @unchecked Sendable {
    static let shared = BackgroundGate()

    private let lock = NSLock()
    private var visible = true
    private var level: ShedLevel = .calm
    private var parked: [UInt64: CheckedContinuation<Void, Never>] = [:]
    private var shown: [UInt64: () -> Void] = [:]
    private var counter: UInt64 = 0

    var isVisible: Bool {
        lock.lock()
        defer { lock.unlock() }
        return visible
    }

    var shedLevel: ShedLevel {
        lock.lock()
        defer { lock.unlock() }
        return level
    }

    /// Watches the window's visibility for the life of the process. Main thread, once the window
    /// is realised.
    func watch(window: UnsafeMutablePointer<GtkWidget>) {
        setVisible(tailscode_window_is_visible(window) != 0)
        tailscode_window_watch_visibility(
            window, { visible, _ in BackgroundGate.shared.setVisible(visible != 0) }, nil)
    }

    /// Main thread. Becoming visible resumes everything parked and runs the handlers.
    func setVisible(_ now: Bool) {
        lock.lock()
        let changed = visible != now
        visible = now
        let waiting = now ? Array(parked.values) : []
        if now { parked.removeAll() }
        let handlers = now && changed ? Array(shown.values) : []
        lock.unlock()
        if changed {
            AppLog.write(
                .lifecycle, now ? "window visible: background polls resume" : "window hidden: background polls pause")
        }
        for continuation in waiting { continuation.resume() }
        for handler in handlers { handler() }
    }

    /// Called every governor tick.
    func setLevel(_ now: ShedLevel) {
        lock.lock()
        level = now
        lock.unlock()
    }

    /// Returns at once while the window is visible, and when it becomes visible otherwise. A
    /// cancelled task is released at once.
    func untilVisible() async {
        if isVisible { return }
        let id = nextID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                lock.lock()
                if visible || Task.isCancelled {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                parked[id] = continuation
                lock.unlock()
            }
        } onCancel: {
            lock.lock()
            let continuation = parked.removeValue(forKey: id)
            lock.unlock()
            continuation?.resume()
        }
    }

    /// Sleeps one period of a poller, stretched for the level the governor holds when it starts.
    func sleep(_ base: TimeInterval) async {
        try? await Task.sleep(for: .seconds(BackgroundCadence.period(base, level: shedLevel)))
    }

    /// Runs `work` on the main thread each time the window becomes visible again, for the life of
    /// the process: a redraw that was skipped while hidden is owed the moment it can be seen.
    func onShown(_ work: @escaping () -> Void) {
        lock.lock()
        counter += 1
        shown[counter] = work
        lock.unlock()
    }

    private func nextID() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        counter += 1
        return counter
    }
}
