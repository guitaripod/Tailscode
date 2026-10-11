import Foundation
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
final class MainStallMonitor: @unchecked Sendable {
    static let shared = MainStallMonitor()

    private static let interval: DispatchTimeInterval = .milliseconds(100)
    private static let threshold: CFTimeInterval = 0.12

    private let queue = DispatchQueue(label: "tailscode.stall", qos: .utility)
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?
    private var asking = false
    private var epoch = 0

    func start() {
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(becameActive),
            name: UIApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(
            self, selector: #selector(resigned),
            name: UIApplication.willResignActiveNotification, object: nil)
        DispatchQueue.main.async { [self] in
            if UIApplication.shared.applicationState == .active { arm() }
        }
    }

    @objc private func becameActive() { arm() }

    @objc private func resigned() { disarm() }

    private func arm() {
        lock.lock()
        defer { lock.unlock() }
        guard timer == nil else { return }
        epoch += 1
        asking = false
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
        epoch += 1
    }

    private func ask() {
        lock.lock()
        guard !asking else {
            lock.unlock()
            return
        }
        asking = true
        let asked = epoch
        lock.unlock()
        let sent = CACurrentMediaTime()
        DispatchQueue.main.async { [self] in
            let late = CACurrentMediaTime() - sent
            lock.lock()
            let current = asked == epoch
            if current { asking = false }
            lock.unlock()
            guard current, late > Self.threshold else { return }
            AppLogger.performance.info("stall ms=\(Int(late * 1000))")
        }
    }
}
