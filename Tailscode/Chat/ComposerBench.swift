#if DEBUG
    import MidgarCore
    import TailscodeCore
    import UIKit

    /// Times the prompt box under a finger that never stops: each key's own work, from the key to
    /// the box laid out again, and every frame the screen missed while the keys were landing.
    @MainActor
    final class ComposerBench: NSObject {
        private var link: CADisplayLink?
        private var last: CFTimeInterval = 0
        private var hitches = 0
        private var hitchTime: Double = 0
        private var worstFrame: Double = 0
        private var samples: [Double] = []

        override init() {
            super.init()
            let link = CADisplayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            self.link = link
        }

        @objc private func tick(_ link: CADisplayLink) {
            defer { last = link.timestamp }
            guard last > 0 else { return }
            let expected = link.targetTimestamp - link.timestamp
            let delta = link.timestamp - last
            worstFrame = max(worstFrame, delta * 1000)
            guard delta > expected * 1.5 else { return }
            hitches += 1
            hitchTime += (delta - expected) * 1000
        }

        /// Runs one step and keeps how long it took, layout included.
        func time(_ step: () -> Void, in view: UIView) {
            let start = CACurrentMediaTime()
            step()
            view.layoutIfNeeded()
            samples.append((CACurrentMediaTime() - start) * 1000)
        }

        /// Ends the run and writes one line the log can be searched for.
        func finish(_ name: String, extra: String = "") {
            link?.invalidate()
            link = nil
            let sorted = samples.sorted()
            guard !sorted.isEmpty else { return }
            let at = { (share: Double) in sorted[min(sorted.count - 1, Int(Double(sorted.count) * share))] }
            let line = String(
                format: "COMPOSE_BENCH name=%@ steps=%d p50=%.2f p95=%.2f max=%.2f hitches=%d hitchms=%.0f worstframe=%.1f %@",
                name, sorted.count, at(0.5), at(0.95), sorted[sorted.count - 1], hitches, hitchTime, worstFrame,
                extra)
            MidgarLog.info(line, category: .performance)
        }
    }
#endif
