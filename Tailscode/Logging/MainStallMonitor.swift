import Foundation
import MidgarCore
import UIKit

/// Says when the main thread was too busy to answer, and for how long.
///
/// A stutter is the main thread not getting back to the display in time, and MetricKit reports
/// only a day's histogram of the long ones. This asks the main queue a question every 100 ms from
/// a queue of its own and writes down how late the answer came whenever it came later than a
/// frame or two would explain, so a hitch that happens on a train is a line in the log with the
/// lines either side of it saying what the app was doing. Only one question is ever out, so a
/// stall is one line rather than a queue of them, and a question asked before the app was
/// suspended is dropped rather than read as a stall the length of the suspension.
///
/// The question is asked every 100 ms while somebody is using the app and every 250 ms once five
/// seconds have gone by with no touch and no typing, because a stutter is something a person feels
/// and a phone left on a desk has nobody to feel one. Touches are noticed at the window's own event
/// stream — the cheapest place that sees every one and puts nothing in the touch path, where a
/// recognizer that watches without recognizing can be left holding a sequence the system took away
/// (the swipe up that leaves the app begins inside it) and the window's pans stop being recognized.
/// Keystrokes arrive in the keyboard's own window, so the text fields' change notifications stamp
/// the same clock. The fast tempo comes back the instant the app becomes active, a touch or
/// keystroke arrives, or a stall is logged, so a slow sample never sits over the moment a person
/// starts to scroll. The tempo changes only how often the question is asked; what counts as late
/// (`threshold`) is the same at both.
final class MainStallMonitor: @unchecked Sendable {
    static let shared = MainStallMonitor()

    private static let interval: DispatchTimeInterval = .milliseconds(100)
    private static let idleInterval: DispatchTimeInterval = .milliseconds(250)
    private static let idleAfter: CFTimeInterval = 5
    private static let threshold: CFTimeInterval = 0.12

    private let queue = DispatchQueue(label: "tailscode.stall", qos: .utility)
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var asking = false
    private var epoch = 0
    private var lastActivity: CFTimeInterval = 0
    private var isIdle = false

    func start() {
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(windowAppeared),
            name: UIWindow.didBecomeKeyNotification, object: nil)
        center.addObserver(
            self, selector: #selector(typed), name: UITextView.textDidChangeNotification,
            object: nil)
        center.addObserver(
            self, selector: #selector(typed), name: UITextField.textDidChangeNotification,
            object: nil)
        center.addObserver(
            self, selector: #selector(becameActive),
            name: UIApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(
            self, selector: #selector(resigned),
            name: UIApplication.willResignActiveNotification, object: nil)
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated { watchWindows() }
            if UIApplication.shared.applicationState == .active { arm() }
        }
    }

    @objc private func becameActive() {
        MainActor.assumeIsolated {
            watchWindows()
            releaseStuckGestures()
        }
        arm()
        noteActivity()
    }

    @objc private func windowAppeared() { MainActor.assumeIsolated { watchWindows() } }

    @objc private func typed() { noteActivity() }

    /// Hands the window the one timestamp this needs, once. The window reports a touch from its own
    /// event stream rather than through a recognizer: a recognizer that is watching but never
    /// recognizes still holds the touch sequence it was given, and a sequence the system ends
    /// without telling the app — the swipe that leaves the app begins here — can leave every pan in
    /// that window unrecognized when the app comes back.
    @MainActor private func watchWindows() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for window in scenes.flatMap(\.windows) {
            guard let window = window as? TouchReportingWindow, window.onTouch == nil else {
                continue
            }
            window.onTouch = { [weak self] in self?.noteActivity() }
        }
    }

    /// A recognizer still holding a sequence after the app has been away is a sequence the system
    /// ended without reaching it — the swipe up that left the app began inside it, a call or a
    /// banner took the finger — and every pan beneath a recognizer like that is refused until
    /// something resets it. A window that answers taps but not scrolls is exactly this, and a menu
    /// opening is the accident that used to clear it. Nothing here is legitimately in flight at
    /// activation, so each one is released, and named in the log the first time it has to be.
    @MainActor private func releaseStuckGestures() {
        for scene in UIApplication.shared.connectedScenes {
            guard let scene = scene as? UIWindowScene else { continue }
            for window in scene.windows {
                var released: [String] = []
                window.releaseStuckGestures(into: &released)
                guard !released.isEmpty else { continue }
                MidgarLog.info(
                    "gestures released on activate: \(released.joined(separator: ", "))",
                    category: .lifecycle
                )
            }
        }
    }

    /// Somebody is using the app: stamp the clock and, if the sampling had slowed down, speed it
    /// up again at once.
    private func noteActivity() {
        lock.lock()
        defer { lock.unlock() }
        lastActivity = CACurrentMediaTime()
        guard isIdle else { return }
        isIdle = false
        timer?.schedule(deadline: .now() + Self.interval, repeating: Self.interval)
    }

    @objc private func resigned() { disarm() }

    private func arm() {
        lock.lock()
        defer { lock.unlock() }
        guard timer == nil else { return }
        epoch += 1
        asking = false
        isIdle = false
        lastActivity = CACurrentMediaTime()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.interval, repeating: Self.interval)
        timer.setEventHandler { [weak self] in self?.ask() }
        timer.resume()
        self.timer = timer
    }

    private func disarm() {
        lock.lock()
        defer { lock.unlock() }
        timer?.cancel()
        timer = nil
        asking = false
        isIdle = false
        epoch += 1
    }

    /// Slows the sampling once nobody has touched the app for `idleAfter`. Called with the lock
    /// held, from the sampling queue, so it costs one comparison per question while somebody is
    /// using the app.
    private func slowIfIdle() {
        guard !isIdle, CACurrentMediaTime() - lastActivity > Self.idleAfter else { return }
        isIdle = true
        timer?.schedule(deadline: .now() + Self.idleInterval, repeating: Self.idleInterval)
    }

    private func ask() {
        lock.lock()
        guard !asking else {
            lock.unlock()
            return
        }
        asking = true
        let asked = epoch
        slowIfIdle()
        lock.unlock()
        let sent = CACurrentMediaTime()
        DispatchQueue.main.async { [self] in
            let late = CACurrentMediaTime() - sent
            lock.lock()
            let current = asked == epoch
            if current { asking = false }
            lock.unlock()
            guard current, late > Self.threshold else { return }
            MidgarLog.info("stall ms=\(Int(late * 1000))", category: .performance)
            noteActivity()
        }
    }
}

/// The window a scene draws in, which says when a touch arrives without standing in its way.
final class TouchReportingWindow: UIWindow {
    var onTouch: (() -> Void)?

    override func sendEvent(_ event: UIEvent) {
        if event.type == .touches { onTouch?() }
        super.sendEvent(event)
    }
}

extension UIView {
    /// Every gesture recognizer below this view that is not waiting for a touch, put back to
    /// waiting and named by its type, state and carrier, so the window that comes back holding one
    /// is a line in the log rather than a report of an app that will not scroll.
    func releaseStuckGestures(into released: inout [String]) {
        for recognizer in gestureRecognizers ?? [] where recognizer.state != .possible {
            released.append(
                "\(type(of: recognizer)) state=\(recognizer.state.rawValue) on=\(type(of: self))")
            recognizer.isEnabled = false
            recognizer.isEnabled = true
        }
        for subview in subviews {
            subview.releaseStuckGestures(into: &released)
        }
    }
}
