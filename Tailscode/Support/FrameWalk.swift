#if DEBUG
import MidgarUI
import UIKit

/// Names the screen on show in the frame watch, so a run that launches straight into one screen
/// through the `TAILSCODE_OPEN_*` switches ends with `Frame watch` lines carrying that screen's
/// name instead of one unlabelled stretch. It reports on arrival at a screen and every two seconds
/// while the screen stays up, which is how a dwell becomes a line that covers it. Started only by
/// `TAILSCODE_FRAME_WALK=1`, so a normal debug launch pays nothing.
@MainActor
enum FrameWalk {
    static func startIfRequested(in window: UIWindow) {
        guard ProcessInfo.processInfo.environment["TAILSCODE_FRAME_WALK"] != nil, walk == nil else {
            return
        }
        let walk = Walk(window: window)
        self.walk = walk
        walk.begin()
    }

    private static var walk: Walk?

    @MainActor
    private final class Walk {
        private let window: UIWindow
        private var screen = ""
        private var shownAt = Date()
        private var lastSecond = -1
        private var scrolled = false
        private var timer: Timer?

        init(window: UIWindow) {
            self.window = window
        }

        func begin() {
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.step() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }

        private func step() {
            guard let name = Self.screenName(in: window) else { return }
            guard name == screen else {
                screen = name
                shownAt = Date()
                lastSecond = -1
                scrolled = false
                MidgarFrameWatch.shared.report("\(name) opened")
                return
            }
            let second = Int(Date().timeIntervalSince(shownAt))
            if second >= 8, !scrolled {
                scrolled = true
                Self.scrollOnce(in: window)
            }
            guard second >= 2, second % 2 == 0, second != lastSecond else { return }
            lastSecond = second
            MidgarFrameWatch.shared.report("\(name) \(second)s")
        }

        /// Moves the first scroll view the shown controller owns down by a screenful, so a list's
        /// scroll cost is part of the stretch and not only its still frame.
        private static func scrollOnce(in window: UIWindow) {
            guard let root = window.rootViewController, let scroll = firstScrollView(in: root.view)
            else { return }
            let limit = max(0, scroll.contentSize.height - scroll.bounds.height)
            let target = min(limit, scroll.contentOffset.y + scroll.bounds.height * 0.6)
            guard target > scroll.contentOffset.y else { return }
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: target), animated: true)
        }

        private static func firstScrollView(in view: UIView) -> UIScrollView? {
            if let scroll = view as? UIScrollView { return scroll }
            for child in view.subviews {
                if let scroll = firstScrollView(in: child) { return scroll }
            }
            return nil
        }

        /// The controller a person is looking at: down every presentation, then the column a
        /// split is showing and the top of the stack inside it.
        private static func screenName(in window: UIWindow) -> String? {
            var top = window.rootViewController
            for _ in 0..<8 {
                guard let current = top else { return nil }
                if let presented = current.presentedViewController, presented !== current {
                    top = presented
                } else if let split = current as? UISplitViewController,
                    let column = split.isCollapsed
                        ? split.viewController(for: .compact)
                        : split.viewController(for: .secondary)
                        ?? split.viewController(for: .compact),
                    column !== current
                {
                    top = column
                } else if let nav = current as? UINavigationController,
                    let visible = nav.visibleViewController, visible !== current
                {
                    top = visible
                } else if let tabs = current as? UITabBarController,
                    let selected = tabs.selectedViewController, selected !== current
                {
                    top = selected
                } else {
                    return shortName(of: current)
                }
            }
            return top.map(shortName(of:))
        }

        private static func shortName(of controller: UIViewController) -> String {
            let type = String(describing: type(of: controller))
            return type.hasSuffix("ViewController")
                ? String(type.dropLast("ViewController".count)) : type
        }
    }
}
#endif
