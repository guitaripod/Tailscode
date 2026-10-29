import AppKit
import TailscodeCore

/// The peek a tile opens when the window's inspector is hidden: the same peek the inspector holds, in a
/// popover beside the tile, so the wall does not move to make room for it. It goes away by itself
/// after twenty seconds without a press, a key or a scroll in it, and never while a nudge is half
/// written.
@MainActor
final class WatchPeekPopover: NSObject, NSPopoverDelegate {
    static let returnsAfter: TimeInterval = 20

    let peek: AgentPeekViewController
    private let popover = NSPopover()
    private var lastTouch = Date()
    private var monitor: Any?
    private(set) var key: String?
    var onClose: (() -> Void)?

    init(context: AgentsContext) {
        peek = AgentPeekViewController(context: context)
        super.init()
        popover.contentViewController = peek
        popover.contentSize = NSSize(width: 380, height: 600)
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
    }

    var isShown: Bool { popover.isShown }

    func show(_ subject: AgentsSubject, beside rect: CGRect, of view: NSView, now: Date) {
        key = subject.key
        lastTouch = now
        peek.show(subject)
        if !popover.isShown {
            popover.show(relativeTo: rect, of: view, preferredEdge: .maxX)
            watchForTouches()
        }
    }

    func close() {
        guard popover.isShown else { return }
        popover.close()
    }

    /// Closes the popover when nobody has touched it for as long as a peek lasts; true when it did.
    @discardableResult
    func expire(at now: Date) -> Bool {
        guard popover.isShown, now.timeIntervalSince(lastTouch) >= Self.returnsAfter,
            peek.nudgeText.isEmpty
        else { return false }
        popover.close()
        return true
    }

    private func watchForTouches() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .keyDown, .scrollWheel]) {
            [weak self] event in
            MainThread.call {
                guard let self, event.window === self.peek.view.window else { return event }
                self.lastTouch = Date()
                return event
            }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        MainThread.call {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            key = nil
            onClose?()
        }
    }
}
