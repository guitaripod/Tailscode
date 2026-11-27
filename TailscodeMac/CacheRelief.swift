import AppKit
import MidgarCore
import TailscodeCore

/// The Mac's own caches in the one registry the governor relieves, and the same relief when
/// nobody is looking.
///
/// Decoded pictures, the heads' rest pictures, rendered prose and clip posters are conveniences
/// kept so a scroll back costs nothing; each can be made again from what is on disk or on screen.
/// They are given back when the governor reaches strained (half) or critical (all), and all of
/// them once no window of the app has been visible for `awayAfter`: an app left behind another
/// for the afternoon holds only what it would have to ask a server for again.
@MainActor
enum CacheRelief {
    /// How long no window may be visible before the caches are given back.
    static let awayAfter: TimeInterval = 300

    private static var tokens: [MemoryReliefToken] = []
    private static var observers: [NSObjectProtocol] = []
    private static var away: Timer?
    private(set) static var awayReliefs = 0

    static func install() {
        guard tokens.isEmpty else { return }
        KitRelief.install()
        register("decoded pictures") { ImageStore.shared.relieve($0) }
        register("head pictures") { BrainPictures.relieve($0) }
        register("rendered prose") { _ in MacMarkdown.invalidate() }
        register("clip posters") { depth in
            if depth == .all { MacClipPosters.relieve() }
        }
        register("freed pages") { depth in
            if depth == .all { malloc_zone_pressure_relief(nil, 0) }
        }
    }

    /// Follows whether anybody can see the app, for the relief an absence earns. Not installed by
    /// a harness, whose windows are never on a screen.
    static func watchAbsence() {
        guard observers.isEmpty else { return }
        let center = NotificationCenter.default
        for name in [
            NSApplication.didHideNotification, NSApplication.didUnhideNotification,
            NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification, NSWindow.willCloseNotification,
        ] {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { _ in
                    MainThread.call { noteVisibility(isSeen: isSeen()) }
                })
        }
    }

    /// Whether any window of the app is on a screen where somebody could see it.
    private static func isSeen() -> Bool {
        guard let app = NSApp, !app.isHidden else { return false }
        return app.windows.contains {
            $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible)
        }
    }

    /// Starts the wait when the app goes out of sight and ends it when it comes back.
    static func noteVisibility(isSeen: Bool, after delay: TimeInterval = awayAfter) {
        if isSeen {
            away?.invalidate()
            away = nil
            return
        }
        guard away == nil else { return }
        away = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { _ in
            MainThread.call { relieveAway() }
        }
    }

    private static func relieveAway() {
        away = nil
        awayReliefs += 1
        let relieved = MemoryRelief.shared.relieve(.all)
        MidgarLog.info(
            "away: nobody has seen a window for \(Int(awayAfter)) s, \(relieved.count) caches given back",
            category: .performance)
    }

    private static func register(_ name: String, _ evict: @escaping @MainActor @Sendable (ReliefDepth) -> Void) {
        tokens.append(
            MemoryRelief.shared.register(name: name) { depth in
                if Thread.isMainThread {
                    MainThread.call { evict(depth) }
                } else {
                    DispatchQueue.main.async { MainThread.call { evict(depth) } }
                }
            })
    }
}
