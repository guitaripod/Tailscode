import AppKit

/// Whether anybody can see a view, asked once for every clock in the window that draws for the
/// eye alone.
///
/// A display link that only checks for a window keeps stepping behind another app, under a window
/// that covers it, on a minimised window and in a hidden app, and every frame it draws there is
/// drawn for nobody. A view may run its clock when its window is on screen (the compositor reports
/// the window's occlusion), is not minimised, and the app is the one in front. The gate owns the
/// notifications that change that answer, so a view hands over one closure and starts or stops its
/// clock when it is called, instead of every view carrying its own copy of the observers.
///
/// A harness has no screen: a window it makes is never ordered front and the app never becomes
/// active, so under `--selftest` and `--bench` the gate is open for any view in a window, and the
/// check that proves the gate itself turns that off for its own duration.
@MainActor
final class DisplayGate {
    nonisolated(unsafe) static var assumesVisible =
        CommandLine.arguments.contains("--selftest") || CommandLine.arguments.contains("--bench")

    private weak var view: NSView?
    private let onChange: () -> Void
    private var appObservers: [NSObjectProtocol] = []
    private var windowObservers: [NSObjectProtocol] = []

    init(_ view: NSView, onChange: @escaping () -> Void) {
        self.view = view
        self.onChange = onChange
        let center = NotificationCenter.default
        for name in [
            NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
            NSApplication.didHideNotification, NSApplication.didUnhideNotification,
        ] {
            appObservers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainThread.call { self?.onChange() }
                })
        }
    }

    isolated deinit {
        for token in appObservers + windowObservers {
            NotificationCenter.default.removeObserver(token)
        }
    }

    /// Follows the window the view is in now. Called from `viewDidMoveToWindow`.
    func attach() {
        for token in windowObservers { NotificationCenter.default.removeObserver(token) }
        windowObservers = []
        guard let window = view?.window else { return }
        for name in [
            NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification,
        ] {
            windowObservers.append(
                NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] _ in
                    MainThread.call { self?.onChange() }
                })
        }
    }

    var isOpen: Bool { Self.allows(view) }

    /// Whether the wall may be drawn: the window is on screen and not minimised and the app is not
    /// hidden. The app need not be in front, which is what sets the wall apart from the board.
    static func allowsWall(_ view: NSView?) -> Bool {
        guard let window = view?.window else { return false }
        if assumesVisible { return true }
        return window.occlusionState.contains(.visible) && !window.isMiniaturized && !(NSApp?.isHidden ?? false)
    }

    /// Whether a view in a window may be drawn for now: the window is on screen and the app is in
    /// front.
    static func allows(_ view: NSView?) -> Bool {
        guard let window = view?.window else { return false }
        if assumesVisible { return true }
        guard window.occlusionState.contains(.visible), !window.isMiniaturized else { return false }
        return NSApp?.isActive ?? false
    }
}
