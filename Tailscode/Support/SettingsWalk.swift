#if DEBUG
    import MidgarCore
    import TailscodeCore
    import UIKit

    /// Scrolls Settings from its first row to its last and back at one fixed speed, so a hitch
    /// trace of the screen is the same take every run: `--settingswalk` with `TAILSCODE_OPEN_SETTINGS`
    /// set. The speed is a brisk flick, which is the speed at which a cell that does its work while
    /// it is configured shows up as a dropped frame.
    @MainActor
    final class SettingsWalk {
        private static var running: SettingsWalk?

        private let window: UIWindow
        private var link: CADisplayLink?
        private var lastTimestamp: CFTimeInterval = 0
        private var passesLeft = 3
        private var goingDown = true
        private weak var collectionView: UICollectionView?
        private var frameSeconds: [Double] = []
        private var iterationStart: CFAbsoluteTime = 0
        private var iterationSeconds: [Double] = []
        private var observers: [CFRunLoopObserver] = []
        private var storm: Timer?
        private var budget: Double = 0

        private static let pointsPerSecond: CGFloat = 1600

        static func start(in window: UIWindow) {
            let walk = SettingsWalk(window: window)
            running = walk
            Task { await walk.run() }
        }

        private init(window: UIWindow) {
            self.window = window
        }

        private func run() async {
            guard let settings = await settingsOnScreen() else {
                MidgarLog.error("SETTINGS_WALK_NO_SETTINGS", category: .ui)
                return
            }
            collectionView = settings.collectionView
            try? await Task.sleep(for: .seconds(2))
            MidgarLog.info("SETTINGS_WALK_COSTS \(Self.costs())", category: .ui)
            MidgarLog.info("SETTINGS_WALK_BEGIN", category: .ui)
            watchRunLoop()
            if CommandLine.arguments.contains("--storm") { startStorm() }
            let link = CADisplayLink(target: self, selector: #selector(step(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
        }

        /// What the main thread was busy for, one run loop turn at a time, from the moment it woke to
        /// the moment its commit was done and it went back to sleep. A turn longer than the frame
        /// budget is a frame the screen could not show, whatever the display link said.
        private func watchRunLoop() {
            let woke = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.afterWaiting.rawValue, true, Int.min) {
                _, _ in
                MainActor.assumeIsolated { SettingsWalk.running?.iterationStart = CFAbsoluteTimeGetCurrent() }
            }
            let slept = CFRunLoopObserverCreateWithHandler(nil, CFRunLoopActivity.beforeWaiting.rawValue, true, Int.max) {
                _, _ in
                MainActor.assumeIsolated {
                    guard let walk = SettingsWalk.running, walk.iterationStart > 0 else { return }
                    walk.iterationSeconds.append(CFAbsoluteTimeGetCurrent() - walk.iterationStart)
                }
            }
            for observer in [woke, slept].compactMap({ $0 }) {
                CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
                observers.append(observer)
            }
        }

        /// What a foreground sweep over a fleet does to the screen: servers answering health probes
        /// and the update driver finishing steps, four times a second, through the notifications the
        /// real ones use. Only with `--storm`.
        private func startStorm() {
            storm = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
                NotificationCenter.default.post(name: ServerHealthMonitor.didChange, object: nil)
                NotificationCenter.default.post(name: UpdateMonitor.didChange, object: nil)
            }
        }

        /// What one call costs on the main thread, in microseconds, of the things a Settings row has
        /// asked for while it was being configured.
        private static func costs() -> String {
            let probes: [(String, () -> Void)] = [
                ("ledgerRollup", { _ = UpdateLedger.rollup() }),
                ("profiles", { _ = ConnectionController.shared.profiles }),
                ("tailnetKey", { _ = TailnetCredentials.key }),
                ("ollamaKey", { _ = OllamaCredentials.hasToken }),
                ("deepseekKey", { _ = DeepSeekCredentials.hasToken }),
                ("newSwitch", { _ = UISwitch() }),
                ("symbol", { _ = UIImage(systemName: "gauge.with.dots.needle.67percent") }),
            ]
            return probes.map { name, body in
                let start = CFAbsoluteTimeGetCurrent()
                for _ in 0..<50 { body() }
                return String(format: "%@=%.0fus", name, (CFAbsoluteTimeGetCurrent() - start) / 50 * 1e6)
            }.joined(separator: " ")
        }

        private func settingsOnScreen() async -> SettingsViewController? {
            for _ in 0..<200 {
                var top = window.rootViewController
                while let presented = top?.presentedViewController { top = presented }
                if let settings = (top as? UINavigationController)?.viewControllers.first
                    as? SettingsViewController, settings.isViewLoaded, settings.view.window != nil
                {
                    return settings
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
            return nil
        }

        @objc private func step(_ link: CADisplayLink) {
            guard let collectionView else { return finish() }
            let delta = lastTimestamp == 0 ? 0 : link.timestamp - lastTimestamp
            lastTimestamp = link.timestamp
            budget = link.targetTimestamp - link.timestamp
            if delta > 0 { frameSeconds.append(delta) }
            let top = -collectionView.adjustedContentInset.top
            let bottom =
                collectionView.contentSize.height - collectionView.bounds.height
                + collectionView.adjustedContentInset.bottom
            var offset = collectionView.contentOffset.y
            offset += (goingDown ? 1 : -1) * Self.pointsPerSecond * CGFloat(delta)
            if goingDown, offset >= bottom {
                offset = bottom
                goingDown = false
            } else if !goingDown, offset <= top {
                offset = top
                goingDown = true
                passesLeft -= 1
            }
            collectionView.contentOffset.y = offset
            if passesLeft == 0 { finish() }
        }

        /// A hitch is a frame that arrived more than half a frame late, the same bar the system's
        /// own hitch instrument uses; a dropped frame is each whole frame it was late by.
        private func report() -> String {
            let hitches = frameSeconds.filter { $0 > budget * 1.5 }
            let dropped = hitches.reduce(0) { $0 + max(Int(($1 / budget).rounded()) - 1, 0) }
            let worst = (frameSeconds.max() ?? 0) * 1000
            let busy = hitches.reduce(0, +) * 1000
            let busyTurns = iterationSeconds.filter { $0 > 0.001 }
            let sorted = busyTurns.sorted()
            let p95 = sorted.isEmpty ? 0 : sorted[Int(Double(sorted.count - 1) * 0.95)] * 1000
            let over = { (limit: Double) in busyTurns.filter { $0 > limit }.count }
            return String(
                format:
                    "frames=%d budgetMs=%.1f hitches=%d dropped=%d worstMs=%.1f hitchMs=%.0f | turns=%d busyMs=%.0f p95Ms=%.1f maxMs=%.1f over4ms=%d over8ms=%d over16ms=%d",
                frameSeconds.count, budget * 1000, hitches.count, dropped, worst, busy,
                busyTurns.count, busyTurns.reduce(0, +) * 1000, p95, (sorted.last ?? 0) * 1000,
                over(0.004), over(0.0083), over(0.0167))
        }

        private func finish() {
            link?.invalidate()
            link = nil
            storm?.invalidate()
            storm = nil
            observers.forEach { CFRunLoopRemoveObserver(CFRunLoopGetMain(), $0, .commonModes) }
            MidgarLog.info("SETTINGS_WALK_END \(report())", category: .ui)
            Self.running = nil
        }
    }
#endif
