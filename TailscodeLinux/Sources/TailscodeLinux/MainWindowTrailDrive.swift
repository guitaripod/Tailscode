import CAdw
import CGtkShim
import Foundation
import TailscodeCore

extension MainWindow {
    /// The drive verbs for the chat trail, each answering on stdout: `back` and `forward` take a
    /// step as a press of the side button would, `trail` says where the focused pane stands,
    /// `trailburst=N` presses Back N times inside one event so the coalescing can be counted in the
    /// trace, and `trailbench=N` hops back and forth N times, each hop drawn before the next, and
    /// reports what a press cost until its frame was painted.
    func driveTrail(_ verb: String, _ argument: String) {
        switch verb {
        case "back":
            driveSay("BACK \(stepTrail(.back))")
        case "forward":
            driveSay("FORWARD \(stepTrail(.forward))")
        case "trail":
            driveSay(trailLine())
        case "trailburst":
            let presses = Int(argument) ?? 4
            for _ in 0..<presses { _ = stepTrail(.back) }
            Gtk.after(400) { [weak self] in
                Gtk.onMain { [weak self] in self.map { $0.driveSay("TRAILBURST \($0.trailLine())") } }
            }
        case "trailbench":
            TrailBench(window: self, hops: Int(argument) ?? 40).begin()
        default:
            break
        }
    }

    func driveSay(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    func trailLine() -> String {
        let trail = activePane.trail
        let shown = activePane.sessionID.map { String($0.prefix(8)) } ?? "none"
        let order = trail.visited.map { String($0.sessionID.prefix(8)) }.joined(separator: ",")
        return "TRAIL place=\(trail.place + 1)/\(trail.visited.count) shown=\(shown) [\(order)]"
    }

    /// Hops along the trail the way a hand does at its fastest: the next press comes when the last
    /// one's frame is on the screen. Each sample is the time from the press to the end of the
    /// frame that drew the chat it asked for.
    final class TrailBench: @unchecked Sendable {
        private let window: MainWindow
        private let hops: Int
        private var samples: [Double] = []
        private var work: [Double] = []
        private var direction = ChatTrail.Direction.back

        init(window: MainWindow, hops: Int) {
            self.window = window
            self.hops = hops
        }

        func begin() {
            guard window.activePane.trail.visited.count >= 2 else {
                window.driveSay("TRAILBENCH needs two chats in the trail")
                return
            }
            next()
        }

        private func next() {
            guard samples.count < hops else { return report() }
            let pane = window.activePane
            if direction == .back && !pane.trail.canGoBack { direction = .forward }
            if direction == .forward && !pane.trail.canGoForward { direction = .back }
            let started = ContinuousClock.now
            let busy = Self.threadMilliseconds()
            guard window.stepTrail(direction), let target = pane.trail.current else {
                return report()
            }
            drawn(pane, target.sessionID) { [self] in
                let elapsed = (ContinuousClock.now - started).components
                samples.append(
                    Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
                work.append(Self.threadMilliseconds() - busy)
                next()
            }
        }

        /// The main thread's own CPU time: what a hop costs the processor, apart from the frame
        /// clock's pacing and any wait for the display.
        private static func threadMilliseconds() -> Double {
            var now = timespec()
            clock_gettime(CLOCK_THREAD_CPUTIME_ID, &now)
            return Double(now.tv_sec) * 1000 + Double(now.tv_nsec) / 1e6
        }

        private func drawn(_ pane: ChatPane, _ sessionID: String, then work: @escaping @Sendable () -> Void) {
            Gtk.betweenFrames(of: pane.entryView) { [self] in
                if pane.sessionID == sessionID {
                    work()
                } else {
                    drawn(pane, sessionID, then: work)
                }
            }
        }

        private func report() {
            guard !samples.isEmpty else { return window.driveSay("TRAILBENCH no hops") }
            func line(_ label: String, _ values: [Double]) -> String {
                let sorted = values.sorted()
                func percentile(_ fraction: Double) -> Double {
                    sorted[min(sorted.count - 1, Int(Double(sorted.count) * fraction))]
                }
                return String(
                    format: "%@ p50=%.1fms p95=%.1fms max=%.1fms", label, percentile(0.5),
                    percentile(0.95), sorted.last ?? 0)
            }
            window.driveSay(
                "TRAILBENCH hops=\(samples.count) " + line("shown", samples) + " "
                    + line("cpu", work))
        }
    }
}
