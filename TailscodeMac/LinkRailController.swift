import AppKit
import TailscodeCore

/// Opens and closes the rails' plates for one transcript. The watch is one tracking area on the
/// scroll view, like the message capsule's, and the rail under the pointer is found by where the
/// rows stand rather than by asking each one; the timing is `RailHover`, pure logic over a clock.
///
/// The plate is a child of the pane's overlay, above the scroll view and never inside it, so the
/// column's layout does not know it exists. It is one layer of glass over canvas content, and it
/// leaves the moment the page moves under it, because a plate that stayed would point at a rail
/// that has gone.
@MainActor
final class LinkRailController: NSResponder {
    var locate: ((NSPoint) -> LinkRailLine?)?
    var lineForKey: ((String) -> LinkRailLine?)?
    var toast: ((String) -> Void)?
    var openAddress: (URL) -> Void = { NSWorkspace.shared.open($0) }
    var clock: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }

    private weak var host: NSView?
    private weak var scrollView: NSScrollView?
    private weak var canvas: NSView?
    private var hover = RailHover()
    private var plate: LinkRailPlateView?
    private weak var anchor: LinkRailLine?
    private var anchorKey: String?
    private var pending: DispatchWorkItem?
    private var escapeMonitor: Any?
    private var keyboardDriven = false
    /// The rail whose plate was just put away by a press or Esc, which the pointer resting on it
    /// must not open again until it has been somewhere else.
    private var closedByPress: String?
    /// Which side the open plate chose, held for as long as it is open so a page growing under it
    /// does not flip it from one side of its rail to the other.
    private(set) var upward = false

    var isOpen: Bool { plate != nil }

    var openKey: String? { hover.open }

    func install(in host: NSView, over scrollView: NSScrollView, canvas: NSView) {
        self.host = host
        self.scrollView = scrollView
        self.canvas = canvas
        scrollView.addTrackingArea(
            NSTrackingArea(
                rect: .zero,
                options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) { refresh() }
    override func mouseEntered(with event: NSEvent) { refresh() }
    override func mouseExited(with event: NSEvent) { refresh() }

    /// Reads where the pointer is and lets the timing decide. Called on every move and whenever
    /// the rows change under a pointer standing still.
    func refresh() {
        guard let host, let window = host.window, let canvas, let scrollView else { return }
        guard NSEvent.pressedMouseButtons == 0 else { return }
        let location = window.mouseLocationOutsideOfEventStream
        let region: RailHover.Region
        if let plate, plate.frame.contains(host.convert(location, from: nil)) {
            region = .plate
        } else if scrollView.contentView.bounds.contains(scrollView.contentView.convert(location, from: nil)),
            let line = locate?(canvas.convert(location, from: nil))
        {
            region = line.key == closedByPress ? .none : .rail(line.key)
            if line.key != closedByPress { closedByPress = nil }
        } else {
            region = .none
            closedByPress = nil
        }
        hover.pointer(on: region, at: clock())
        apply()
    }

    /// The rows changed under whatever was open.
    func rowsChanged() {
        guard isOpen else { return }
        sync()
    }

    /// The pointer is on the plate itself, which tells the controller before any move does.
    func pointerOnPlate(_ inside: Bool) {
        hover.pointer(on: inside ? .plate : .none, at: clock())
        apply()
    }

    private func apply() {
        hover.advance(to: clock())
        sync()
        schedule()
    }

    private func schedule() {
        pending?.cancel()
        pending = nil
        guard let deadline = hover.deadline else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
        pending = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(0.005, deadline - clock() + 0.002), execute: work)
    }

    /// A press on a rail, or a key on it: opens at once, or closes what is open.
    func activate(_ line: LinkRailLine, viaKeyboard: Bool) {
        if hover.open == line.key {
            close()
            return
        }
        hover.openNow(line.key)
        keyboardDriven = viaKeyboard
        sync()
        schedule()
    }

    func escape() {
        guard isOpen else { return }
        close()
    }

    func close() {
        closedByPress = hover.open
        hover.escape()
        sync()
        schedule()
    }

    /// The page moved or the chat changed: whatever was open points at nothing now.
    func dismiss() {
        pending?.cancel()
        pending = nil
        hover.escape()
        sync()
    }

    private func sync() {
        guard let key = hover.open else {
            guard plate != nil else { return }
            tearDown()
            return
        }
        if plate != nil, anchorKey == key, anchor?.superview != nil { return }
        guard let line = lineForKey?(key), line.window != nil else {
            hover.escape()
            tearDown()
            return
        }
        if plate != nil, anchorKey == key {
            anchor = line
            line.setExpanded(true)
            reposition()
            return
        }
        show(for: line)
    }

    /// The rows were rebuilt or the page moved: the plate follows its rail, or goes when the rail
    /// has left what the reader can see.
    func reposition() {
        guard plate != nil else { return }
        guard anchor?.superview != nil else {
            sync()
            return
        }
        guard let plate, let host, let scrollView, let line = anchor, line.window != nil else {
            close()
            return
        }
        let rail = line.convert(line.hitRect, to: host)
        let visible = host.convert(scrollView.contentView.bounds, from: scrollView.contentView)
        guard visible.intersects(rail) else {
            close()
            return
        }
        plate.frame = RailPlacement.frame(
            rail: rail, plateSize: plate.plateSize, bounds: host.bounds, flipped: host.isFlipped,
            upward: upward)
    }

    private func show(for line: LinkRailLine) {
        guard let host, let scrollView else { return }
        tearDown()
        let metrics = ChatLayout.metrics
        let width = min(CGFloat(metrics.railPlateWidth), max(240, host.bounds.width - 32))
        let view = LinkRailPlateView(model: line.model, metrics: metrics, width: width)
        view.onOpen = { [weak self] url in
            self?.openAddress(url)
            self?.close()
        }
        view.onCopy = { [weak self] address in
            RowKit.copyToClipboard(address)
            self?.toast?(Localized.text("Copied"))
            self?.close()
        }
        view.onPointer = { [weak self] inside in self?.pointerOnPlate(inside) }
        view.onEscape = { [weak self] in self?.close() }
        line.model.begin(opened: true)
        let rail = line.convert(line.hitRect, to: host)
        let visible = host.convert(scrollView.contentView.bounds, from: scrollView.contentView)
        let room = RailPlacement.roomBelow(
            rail: rail, visible: visible, bottomInset: scrollView.contentInsets.bottom,
            flipped: host.isFlipped)
        upward = LinkRailPlate.opensUpward(
            roomBelow: Double(room), plateHeight: Double(view.plateSize.height))
        view.frame = RailPlacement.frame(
            rail: rail, plateSize: view.plateSize, bounds: host.bounds, flipped: host.isFlipped,
            upward: upward)
        host.addSubview(view, positioned: .above, relativeTo: scrollView)
        plate = view
        anchor = line
        anchorKey = line.key
        line.setExpanded(true)
        watchEscape()
        if keyboardDriven {
            line.window?.makeFirstResponder(view)
            view.select(0)
        }
    }

    private func tearDown() {
        let wasDriven = keyboardDriven
        let line = anchor
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
        let hadFocus = plate.map { $0.window?.firstResponder === $0 } ?? false
        plate?.removeFromSuperview()
        plate = nil
        anchor = nil
        anchorKey = nil
        keyboardDriven = false
        line?.setExpanded(false)
        if wasDriven || hadFocus, let line, line.window != nil {
            line.window?.makeFirstResponder(line)
        }
    }

    private func watchEscape() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard event.keyCode == 53 else { return event }
            let consumed = MainActor.assumeIsolated { () -> Bool in
                guard let self, self.isOpen else { return false }
                self.close()
                return true
            }
            return consumed ? nil : event
        }
    }

    /// For a harness: whether a plate is up, its frame in the host and the row geometry.
    var plateView: LinkRailPlateView? { plate }
}
