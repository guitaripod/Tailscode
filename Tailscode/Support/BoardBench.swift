#if DEBUG
import MidgarCore
import MidgarUI
import TailscodeCore
import UIKit

/// The measurement rig for Home's board: what a full rebuild costs, and what the board costs the
/// display while it moves. It exists for debug launches on a device with no Instruments attached —
/// `MIDGAR_FRAME_WATCH=<seconds>` counts the frames, and this drives the scroll so the rebuilds
/// that land under it are part of the stretch.
///
/// `TAILSCODE_BOARD_SCROLL=<seconds>` scrolls the board down and back up at
/// `TAILSCODE_BOARD_SCROLL_SPEED` points a second (900 by default), after
/// `TAILSCODE_BOARD_SCROLL_DELAY` seconds (one by default) so the first listing has landed.
@MainActor
enum BoardBench {
    private static var passes = 0
    private static var worst: TimeInterval = 0
    private static var spent: TimeInterval = 0
    private static var scroller: Scroller?
    private static weak var home: HomeViewController?

    /// Whether the bench is moving the board itself. A finger on the list is what really holds a
    /// rebuild back, and a programmatic scroll is not one: the board's own gates read this so a
    /// measured run pays what a hand pays instead of rebuilding under the scroll.
    static var isDrivingScroll: Bool { scroller != nil }

    /// A tick's own cost: it re-words the cards on screen and rebuilds no board, so it should be a
    /// fraction of a pass. Anything near a frame is written down.
    static func note(tick: TimeInterval) {
        guard tick >= 0.004 else { return }
        MidgarLog.notice("Board tick \(milliseconds(tick)) ms", category: .performance)
    }

    /// A full board rebuild, in seconds of this thread's own CPU time — not wall clock, which a
    /// loaded phone inflates with everything else the machine is doing. Every pass is counted so
    /// the run can end with a mean, and one long enough to cost a frame is written as it happens,
    /// with what each stage of it cost.
    static func note(pass: TimeInterval, stages: Stages? = nil) {
        passes += 1
        spent += pass
        worst = max(worst, pass)
        guard pass >= 0.008 else { return }
        let detail = stages.map { " [\($0.summary)]" } ?? ""
        MidgarLog.notice("Board pass \(milliseconds(pass)) ms\(detail)", category: .performance)
    }

    /// The CPU time this thread has used, which is what a pass actually costs.
    static func cpuTime() -> TimeInterval {
        var time = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
        return TimeInterval(time.tv_sec) + TimeInterval(time.tv_nsec) / 1_000_000_000
    }

    /// What each stage of one pass cost, marked as the pass goes by, so the next change is aimed
    /// at the stage that is actually expensive rather than at the one that looks expensive.
    @MainActor
    struct Stages {
        private var last = BoardBench.cpuTime()
        private var parts: [String] = []

        mutating func mark(_ name: String) {
            let now = BoardBench.cpuTime()
            parts.append("\(name) \(Int(((now - last) * 1000).rounded()))")
            last = now
        }

        var summary: String { parts.joined(separator: " ") }
    }

    static func startIfAsked(in controller: HomeViewController) {
        guard scroller == nil,
            let seconds = ProcessInfo.processInfo.environment["TAILSCODE_BOARD_SCROLL"]
                .flatMap(Double.init), seconds > 0
        else { return }
        let env = ProcessInfo.processInfo.environment
        let speed = env["TAILSCODE_BOARD_SCROLL_SPEED"].flatMap(Double.init) ?? 900
        let delay = env["TAILSCODE_BOARD_SCROLL_DELAY"].flatMap(Double.init) ?? 1
        passes = 0
        worst = 0
        spent = 0
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(delay))
            guard controller.viewIfLoaded?.window != nil, scroller == nil else { return }
            if !MidgarFrameWatch.shared.isRunning { MidgarFrameWatch.shared.start() }
            MidgarFrameWatch.shared.report("before the board scroll")
            home = controller
            let run = Scroller(view: controller.collectionView, seconds: seconds, speed: speed)
            scroller = run
            run.begin()
        }
    }

    private static func finish(_ run: Scroller) {
        scroller = nil
        let mean = passes == 0 ? 0 : spent / Double(passes)
        MidgarLog.notice(
            "Board scroll \(Int(run.seconds))s: \(passes) pass(es), worst \(milliseconds(worst)) ms, mean \(milliseconds(mean)) ms",
            category: .performance)
        MidgarFrameWatch.shared.report("board scroll \(Int(run.seconds))s")
        home?.releaseDeferredSnapshotIfNeeded()
    }

    private static func milliseconds(_ time: TimeInterval) -> Int {
        Int((time * 1000).rounded())
    }

    /// Times each part of walking the fleet for the board, so a slow pass is aimed at the part
    /// that is slow. `TAILSCODE_BOARD_PROBE=1` runs it once on the board's own data, after the
    /// first listing has landed.
    static func probeIfAsked(controller: HomeViewController) {
        guard ProcessInfo.processInfo.environment["TAILSCODE_BOARD_PROBE"] != nil else { return }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            runProbe(controller)
        }
    }

    private static func runProbe(_ controller: HomeViewController) {
        let entries = controller.viewModel.entries
        let archived = ArchivedChatStore.keys()
        let pins = Set(SessionPinStore.all())
        let isUnread = SessionSeenStore.unreadEvaluator()
        let unreachable = controller.viewModel.unreachable
        func time(_ name: String, _ work: () -> Void) {
            let began = cpuTime()
            for _ in 0..<3 { work() }
            let spent = (cpuTime() - began) / 3
            MidgarLog.notice(
                "Board probe \(name): \(String(format: "%.2f", spent * 1000)) ms for \(entries.count) entries",
                category: .performance)
        }
        let activity = SessionActivity.shared
        MidgarLog.notice(
            "Board probe statuses: \(activity.statuses.count), retained: \(activity.statuses.filter { $0.value != .idle }.count)",
            category: .performance)
        time("statuses") { _ = activity.statuses.count }
        time("presenceMap") { _ = activity.presenceSummary() }
        time("presence") { _ = entries.map { activity.presence(for: $0.session.id) } }
        time("archiveKeyed") {
            _ = entries.filter {
                !archived.contains(
                    ArchivedChatStore.ChatKey(profileID: $0.profileID, sessionID: $0.session.id))
            }
        }
        time("archiveJoined") {
            _ = entries.filter {
                !Set(ArchivedChatStore.all()).contains(
                    ArchivedChatStore.key($0.profileID, $0.session.id))
            }
        }
        time("unread") { _ = entries.filter { isUnread($0.session.id, $0.session.updatedAt) } }
        time("pins") {
            _ = entries.filter { pins.contains(SessionPinStore.key($0.profileID, $0.session.id)) }
        }
        time("reach") { _ = entries.filter { unreachable.contains($0.profileID) } }
        time("seed") {
            _ = entries.map {
                HomeRowSeed(
                    entry: $0, unreachable: false, unread: false, saved: false, pinned: false,
                    presence: .unobserved)
            }
        }
        time("full") {
            _ = entries
                .filter {
                    !archived.contains(
                        ArchivedChatStore.ChatKey(profileID: $0.profileID, sessionID: $0.session.id))
                }
                .map {
                    HomeRowSeed(
                        entry: $0, unreachable: unreachable.contains($0.profileID),
                        unread: isUnread($0.session.id, $0.session.updatedAt), saved: false,
                        pinned: pins.contains(SessionPinStore.key($0.profileID, $0.session.id)),
                        presence: .unobserved)
                }
        }
    }

    /// Moves the board a display frame at a time, as a finger would: every frame places the list at
    /// the next offset, so the cells the scroll brings in are made and measured inside the frame
    /// they arrive. It turns at the ends rather than stopping, so a run measures the whole board and
    /// not its first screenful.
    @MainActor
    private final class Scroller {
        let seconds: Double
        private let view: UIScrollView
        private let speed: CGFloat
        private var link: CADisplayLink?
        private var last: CFTimeInterval = 0
        private var elapsed: Double = 0
        private var headingDown = true

        init(view: UIScrollView, seconds: Double, speed: Double) {
            self.view = view
            self.seconds = seconds
            self.speed = CGFloat(speed)
        }

        func begin() {
            let link = CADisplayLink(target: self, selector: #selector(step))
            link.add(to: .main, forMode: .common)
            self.link = link
        }

        @objc private func step(_ link: CADisplayLink) {
            let wait = last == 0 ? 0 : link.timestamp - last
            last = link.timestamp
            elapsed += wait
            guard elapsed < seconds else { return stop() }
            let inset = view.adjustedContentInset
            let floor = -inset.top
            let ceiling = max(floor, view.contentSize.height + inset.bottom - view.bounds.height)
            var y = view.contentOffset.y + speed * CGFloat(wait) * (headingDown ? 1 : -1)
            if y >= ceiling {
                y = ceiling
                headingDown = false
            } else if y <= floor {
                y = floor
                headingDown = true
            }
            view.setContentOffset(CGPoint(x: view.contentOffset.x, y: y), animated: false)
        }

        private func stop() {
            link?.invalidate()
            link = nil
            BoardBench.finish(self)
        }
    }
}
#endif
