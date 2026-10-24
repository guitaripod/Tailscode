import Foundation
import MidgarCore
import UIKit
import UIKit.UIGestureRecognizerSubclass

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
/// and a phone left on a desk has nobody to feel one. Touches are noticed by a gesture recognizer
/// on each window that never recognizes anything and never delays or cancels a touch: it writes
/// one timestamp in `touchesBegan` and `touchesMoved` and is otherwise inert, which is the whole
/// per-event cost. Keystrokes arrive in the keyboard's own window, so the text fields' change
/// notifications stamp the same clock. The fast tempo comes back the instant the app becomes
/// active, a touch or keystroke arrives, or a stall is logged, so a slow sample never sits over the
/// moment a person starts to scroll. The tempo changes only how often the question is asked; what
/// counts as late (`threshold`) is the same at both.
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
            watchWindows()
            if UIApplication.shared.applicationState == .active { arm() }
        }
    }

    @objc private func becameActive() {
        MainActor.assumeIsolated { watchWindows() }
        arm()
        noteActivity()
    }

    @objc private func windowAppeared() { MainActor.assumeIsolated { watchWindows() } }

    @objc private func typed() { noteActivity() }

    /// Puts the touch stamp on every window of every scene that does not carry one yet.
    @MainActor private func watchWindows() {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        for window in scenes.flatMap(\.windows) {
            let stamped = window.gestureRecognizers?.contains { $0 is TouchStamp } ?? false
            guard !stamped else { continue }
            window.addGestureRecognizer(TouchStamp { [weak self] in self?.noteActivity() })
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

/// The inert recognizer that tells the monitor a finger is on the screen: it never leaves the
/// possible state, so it neither recognizes anything nor holds another recognizer up, and it
/// neither delays nor cancels a touch.
private final class TouchStamp: UIGestureRecognizer {
    private let stamp: () -> Void

    init(_ stamp: @escaping () -> Void) {
        self.stamp = stamp
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) { stamp() }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) { stamp() }
}
