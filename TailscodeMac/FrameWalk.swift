#if DEBUG
    import AppKit
    import MidgarCore
    import MidgarUI
    import QuartzCore
    import TailscodeCore

    /// How long the main thread kept the display waiting, in the app's own log, measured on the
    /// window's own display link: a tick that arrives late is a frame the person did not get, and
    /// a wait of three frames at 60 Hz is one they feel. `TAILSCODE_FRAME_WATCH=1` starts it, and
    /// the drive script's `mark=<stage>` verb names the stretch each report covers, so one run
    /// through every surface ends with a line per surface rather than one unlabelled average.
    @MainActor
    final class FrameWalk: NSObject {
        static let shared = FrameWalk()

        private var link: CADisplayLink?
        private var last: CFTimeInterval = 0
        private var tally = MidgarFrameTally()
        private var stage = "launch"
        private var sinceReport: CFTimeInterval = 0

        var isRunning: Bool { link != nil }

        static func startIfRequested(in window: NSWindow?, environment: [String: String] = ProcessInfo.processInfo.environment) {
            guard environment["TAILSCODE_FRAME_WATCH"] != nil, !shared.isRunning else { return }
            shared.start(in: window)
        }

        func start(in window: NSWindow?) {
            guard link == nil, let view = window?.contentView else { return }
            let link = view.displayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
            MidgarLog.notice("Frame watch started", category: .performance)
        }

        /// Begins a named stretch, ending the one before it, so a tour reads as one line per stage.
        func mark(_ name: String) {
            guard link != nil else { return }
            report(stage)
            stage = name
            sinceReport = 0
            MidgarLog.notice("Frame watch stage \(name)", category: .performance)
        }

        func stop() {
            link?.invalidate()
            link = nil
            last = 0
            tally = MidgarFrameTally()
        }

        private func report(_ name: String) {
            MidgarLog.notice("Frame watch, \(name): \(tally.summary)", category: .performance)
            tally = MidgarFrameTally()
        }

        @objc private func tick(_ link: CADisplayLink) {
            defer { last = link.timestamp }
            guard last > 0 else { return }
            let wait = link.timestamp - last
            let frame = max(link.targetTimestamp - link.timestamp, 1.0 / 120.0)
            let felt = tally.note(wait: wait, frame: frame)
            if felt {
                MidgarLog.notice(
                    "Frame wait \(Int((wait * 1000).rounded())) ms in \(stage)", category: .performance)
            }
            sinceReport += wait
            if sinceReport >= 2 {
                sinceReport = 0
                report(stage)
            }
        }
    }

    /// The tour's hands: scrolling a list the way a trackpad does, resizing a window, and walking
    /// the theme, so each surface can be measured on a machine nobody is touching.
    @MainActor
    enum WalkDrive {
        /// Scrolls the app's list or the focused conversation for `seconds`, at the pace a finger
        /// moves it, by animating the clip view's origin: every frame is a real scroll notification,
        /// which is the work a scroll actually costs.
        static func scroll(_ what: String, seconds: Double, main: MainWindowController?) -> String {
            let scrollView: NSScrollView?
            switch what {
            case "sidebar": scrollView = main?.sidebar.tableView.enclosingScrollView
            default: scrollView = main?.transcript.scrollView
            }
            guard let scrollView else { return "SCROLL \(what) no scroll view" }
            let clip = scrollView.contentView
            let limit = max(0, (scrollView.documentView?.frame.height ?? 0) - clip.bounds.height)
            guard limit > 0 else { return "SCROLL \(what) nothing to scroll" }
            let from = clip.bounds.origin.y
            let distance = min(limit - from, what == "sidebar" ? limit : limit * 0.8)
            FSAnimator.animate(seconds: seconds) { progress in
                let y = min(limit, from + distance * progress)
                clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
                scrollView.reflectScrolledClipView(clip)
            }
            return "SCROLL \(what) from \(Int(from)) of \(Int(limit)) over \(Int(seconds))s"
        }

        /// Grows and shrinks the window the way dragging its corner does, one layout per step.
        static func resize(_ main: MainWindowController?, seconds: Double) -> String {
            guard let window = main?.window else { return "RESIZE no window" }
            let start = window.frame
            let wide = start.insetBy(dx: -180, dy: -90)
            FSAnimator.animate(seconds: seconds) { progress in
                let out = progress < 0.5 ? progress * 2 : (1 - progress) * 2
                let frame = NSRect(
                    x: start.minX - 180 * out, y: start.minY - 90 * out,
                    width: start.width + 360 * out, height: start.height + 180 * out)
                window.setFrame(frame, display: true)
                _ = wide
            }
            return "RESIZE from \(Int(start.width))x\(Int(start.height)) over \(Int(seconds))s"
        }

        /// Switches the palette to a theme that paints a place, then back, so a theme change's cost
        /// is measured where it is paid rather than at launch.
        static func theme(_ name: String) -> String {
            switch name {
            case "place", "scenery":
                let theme = AppTheme.outerRim
                ThemeSelection.setTheme(theme)
                return "THEME \(theme.id)"
            case "system":
                ThemeSelection.setThemeID(ThemeSelection.systemID)
                return "THEME system"
            default:
                ThemeSelection.setThemeID(name)
                return "THEME \(name)"
            }
        }

        /// Opens a surface by the same names `--open` takes, so one process can walk several windows.
        static func open(_ name: String, main: MainWindowController?) -> String {
            guard let main else { return "OPEN no window" }
            main.openSurface(named: name)
            return "OPEN \(name)"
        }

        /// Puts away the windows a tour opened, leaving the conversation standing.
        static func closeSecondary() -> String {
            let closing = NSApp.windows.filter {
                $0.isVisible && $0.level == .normal && !($0.windowController is MainWindowController)
            }
            for window in closing { window.close() }
            return "CLOSEWINDOWS \(closing.count)"
        }

        /// Opens the first `count` chats in order, the way clicking down the list does.
        static func cycle(_ count: Int, main: MainWindowController?) -> String {
            guard let main else { return "CYCLE no window" }
            let entries = Array(main.sidebar.entries.prefix(max(1, count)))
            guard !entries.isEmpty else { return "CYCLE no chats" }
            for (index, entry) in entries.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.4) {
                    MainThread.call { main.open(entry) }
                }
            }
            return "CYCLE \(entries.count) chats"
        }

        /// Types into the conversation's composer one character at a time, so the cost is the cost
        /// a key press has rather than the cost of one bulk insertion.
        static func type(_ text: String, main: MainWindowController?) -> String {
            guard let main else { return "TYPE no window" }
            let composer = main.transcript.composer
            let characters = Array(text.isEmpty ? "The reconnect path retries with a capped backoff. " : text)
            for (index, character) in characters.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) / 30) {
                    MainThread.call { composer.insertText(String(character)) }
                }
            }
            return "TYPE \(characters.count) characters"
        }
    }

    /// One animation helper for the tour: a display link that hands out eased progress, so the work
    /// is spread over real frames instead of a burst of setFrame calls from one runloop turn.
    @MainActor
    final class FSAnimator: NSObject {
        private var link: CADisplayLink?
        private var started: CFTimeInterval = 0
        private let seconds: Double
        private let step: (Double) -> Void

        static func animate(seconds: Double, step: @escaping (Double) -> Void) {
            let animator = FSAnimator(seconds: seconds, step: step)
            live.append(animator)
            animator.begin()
        }

        private static var live: [FSAnimator] = []

        private init(seconds: Double, step: @escaping (Double) -> Void) {
            self.seconds = seconds
            self.step = step
        }

        private func begin() {
            guard let view = NSApp.mainWindow?.contentView ?? NSApp.windows.first?.contentView
            else { return }
            let link = view.displayLink(target: self, selector: #selector(tick(_:)))
            link.add(to: .main, forMode: .common)
            self.link = link
            started = link.timestamp
        }

        @objc private func tick(_ link: CADisplayLink) {
            let progress = min(1, (link.timestamp - started) / seconds)
            step(progress)
            guard progress >= 1 else { return }
            link.invalidate()
            self.link = nil
            FSAnimator.live.removeAll { $0 === self }
        }
    }
#endif
