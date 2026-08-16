import AppKit
import TailscodeCore

/// The tiling tree made visible on the Mac: `SplitLayout` decides the arrangement, this renders
/// it as nested `NSSplitViewController`s and keeps the two in agreement — divider drags flow
/// back into the model as ratios, structural verbs rebuild the controller skeleton around the
/// surviving panes, and the zoom is collapse, not structure, so unzooming restores the exact
/// arrangement. Each pane is one `TranscriptViewController`, a complete conversation.
@MainActor
final class SplitPaneHost: NSViewController {
    private(set) var layout = SplitLayout()
    private(set) var panes: [PaneID: TranscriptViewController] = [:]
    /// A pane born empty, with the server the split came from — the hub answers it with the
    /// chooser.
    var onPaneOpened: ((TranscriptViewController, String?) -> Void)?
    /// A chat let go over a pane — the hub opens it and resolves the zone.
    var onChatDropped: ((TranscriptViewController, PaneDragPayload, PaneDropZone) -> Bool)?
    /// Title for the drop caption while a chat is carried over a pane.
    var chatTitleForDrop: ((PaneDragPayload) -> String?)?
    private var splitViews: [SplitID: NSSplitView] = [:]
    private var splitItems: [SplitID: (first: NSSplitViewItem, second: NSSplitViewItem)] = [:]
    private var splitLeaves: [SplitID: (first: Set<PaneID>, second: Set<PaneID>)] = [:]
    private var treeRoot: NSViewController?
    private var suppressCapture = false
    private let dropHighlight = PaneDropHighlightView(frame: .zero)
    private var dropZone: (pane: PaneID, zone: PaneDropZone)?

    /// The hub builds each pane so its closures — toasts, band actions, state observation — are
    /// wired the moment the pane exists, before anything can stream into it.
    var makePane: (() -> TranscriptViewController)?
    var onFocusChanged: (() -> Void)?
    var onLayoutChanged: (() -> Void)?

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        dropHighlight.autoresizingMask = []
        root.addSubview(dropHighlight)
        view = root
    }

    /// Creates the first pane once the hub has handed over its factory.
    func bootstrap() {
        guard panes.isEmpty, let makePane else { return }
        let pane = makePane()
        panes[layout.focusedPane] = pane
        installDropTarget(on: pane)
        rebuild()
    }

    var active: TranscriptViewController {
        panes[layout.focusedPane] ?? panes.values.first!
    }

    var paneCount: Int { layout.paneCount }

    var orderedPanes: [TranscriptViewController] {
        layout.paneIDs.compactMap { panes[$0] }
    }

    func pane(showing sessionID: String) -> TranscriptViewController? {
        orderedPanes.first { $0.currentEntry?.session.id == sessionID }
    }

    func eachPane(_ body: (TranscriptViewController) -> Void) {
        for pane in orderedPanes { body(pane) }
    }

    /// Splits the focused pane; the new pane opens focused and asking which server, so the split
    /// itself is the moment the second machine gets chosen — the chat list, or a subsequent open,
    /// can still fill it instead.
    func splitActive(axis: SplitAxis) {
        let source = active.currentEntry?.profileID
        guard let makePane, let freshID = layout.split(layout.focusedPane, axis: axis) else {
            return
        }
        let pane = makePane()
        panes[freshID] = pane
        installDropTarget(on: pane)
        rebuild()
        onPaneOpened?(pane, source)
        onFocusChanged?()
        persist()
    }

    /// Splits `pane` and hands back the fresh pane on the side a drop was aimed at.
    @discardableResult
    func split(_ pane: TranscriptViewController, edge: PaneDropEdge) -> TranscriptViewController? {
        guard let makePane,
            let id = panes.first(where: { $0.value === pane })?.key,
            let freshID = layout.split(id, axis: edge.axis, placingNewFirst: edge.placesArrivalFirst)
        else { return nil }
        let fresh = makePane()
        panes[freshID] = fresh
        installDropTarget(on: fresh)
        rebuild()
        onFocusChanged?()
        persist()
        return fresh
    }

    /// The whole tree collapsed onto one pane: every other pane closes, the kept one inherits
    /// the window and the focus. This is the unsplit gesture — one press, not a close per pane.
    func collapse(to keep: TranscriptViewController) {
        guard let keepID = panes.first(where: { $0.value === keep })?.key,
            layout.contains(keepID)
        else { return }
        for id in layout.paneIDs where id != keepID {
            guard layout.close(id) != nil else { continue }
            if let pane = panes.removeValue(forKey: id) {
                pane.shutdownPane()
                pane.removeFromParent()
                pane.view.removeFromSuperview()
            }
        }
        layout.focus(keepID)
        rebuild()
        onFocusChanged?()
        persist()
    }

    /// Closes the focused pane; its conversation stops streaming and the sibling inherits the
    /// space. The last pane refuses — a window with no conversation surface is not this app.
    func closeActive() {
        let closing = layout.focusedPane
        guard layout.close(closing) != nil else { return }
        if let pane = panes.removeValue(forKey: closing) {
            pane.shutdownPane()
            pane.removeFromParent()
            pane.view.removeFromSuperview()
        }
        rebuild()
        onFocusChanged?()
        persist()
    }

    @discardableResult
    func focusNeighbor(_ direction: SplitDirection) -> Bool {
        let wasZoomed = layout.zoomedPane != nil
        let moved = layout.focusNeighbor(direction)
        if wasZoomed { applyZoom() }
        guard moved || wasZoomed else { return false }
        applyFocusStyling()
        onFocusChanged?()
        persist()
        return moved
    }

    func zoomActive() {
        layout.toggleZoom(layout.focusedPane)
        applyZoom()
        applyFocusStyling()
        persist()
    }

    func exchangeActive() {
        layout.exchange(layout.focusedPane)
        rebuild()
        persist()
    }

    /// Every pane its fair share, from the menu verb or a double click on any divider.
    func equalize() {
        layout.equalize()
        applyRatios()
        persist()
    }

    /// The pane a point in window coordinates lands in. A press on a divider, on a collapsed
    /// pane's ghost, or on the chrome beside the tree belongs to no pane and changes nothing —
    /// which is why this hit tests the pane views themselves rather than the tree's bounds.
    func pane(atWindowPoint point: NSPoint) -> TranscriptViewController? {
        Self.hitTest(orderedPanes, at: point)
    }

    /// The geometry rule on its own, so the selftest can assert it over plain controllers: the
    /// first one whose view is loaded, in a window, on screen, and actually under the point.
    static func hitTest<Controller: NSViewController>(
        _ controllers: [Controller], at point: NSPoint
    ) -> Controller? {
        controllers.first { controller in
            guard controller.isViewLoaded, controller.view.window != nil,
                !controller.view.isHiddenOrHasHiddenAncestor
            else { return false }
            let local = controller.view.convert(point, from: nil)
            return NSMouseInRect(local, controller.view.bounds, controller.view.isFlipped)
        }
    }

    /// Focus by intent: a keyboard move also asks the pane to take the keyboard; a click leaves
    /// AppKit's first responder where the click put it.
    func focus(_ pane: TranscriptViewController, grabKeyboard: Bool) {
        guard let id = panes.first(where: { $0.value === pane })?.key,
            layout.focusedPane != id
        else { return }
        layout.focus(id)
        applyFocusStyling()
        if grabKeyboard { pane.focusComposer() }
        onFocusChanged?()
        persist()
    }

    /// Rebuilds panes from a persisted arrangement and hands back what each pane was showing.
    /// The sessions themselves resolve later, from the cached listing — restore never waits on a
    /// server to draw the window's shape.
    func restore(_ snapshot: SplitSnapshot) -> [PaneID: SplitPaneSession] {
        guard let makePane, snapshot.layout.isValid else { return [:] }
        for pane in panes.values {
            pane.shutdownPane()
            pane.removeFromParent()
            pane.view.removeFromSuperview()
        }
        panes = [:]
        layout = snapshot.layout
        var bindings: [PaneID: SplitPaneSession] = [:]
        for id in layout.paneIDs {
            let pane = makePane()
            panes[id] = pane
            installDropTarget(on: pane)
            if let target = snapshot.page(for: id) {
                pane.showWeb(target)
            } else if let target = snapshot.video(for: id) {
                pane.showVideo(target)
            } else if let session = snapshot.session(for: id) {
                bindings[id] = session
            }
        }
        rebuild()
        return bindings
    }

    private func installDropTarget(on pane: TranscriptViewController) {
        pane.view.registerForDraggedTypes([.tailscodeChat])
        pane.onDragEntered = { [weak self, weak pane] sender in
            guard let self, let pane else { return false }
            return self.dragUpdated(sender, over: pane)
        }
        pane.onDragUpdated = { [weak self, weak pane] sender in
            guard let self, let pane else { return [] }
            return self.dragUpdated(sender, over: pane) ? .copy : []
        }
        pane.onDragExited = { [weak self] in self?.clearDropHighlight() }
        pane.onDragPerform = { [weak self, weak pane] sender in
            guard let self, let pane else { return false }
            return self.receiveDrop(sender, on: pane)
        }
    }

    /// Where the pointer is, asked in the space the shared drop model is written in. Its top edge
    /// is `y: 0`; an unflipped AppKit view's is the bottom, so a drag aimed at the foot of a pane
    /// would otherwise be answered with the arrangement the head of it means.
    private func zoneUnderPointer(
        _ sender: NSDraggingInfo, over pane: TranscriptViewController
    ) -> PaneDropZone {
        let local = pane.view.convert(sender.draggingLocation, from: nil)
        let bounds = pane.view.bounds
        let y = pane.view.isFlipped ? local.y : bounds.height - local.y
        return PaneDropTarget.zone(
            x: Double(local.x), y: Double(y),
            width: Double(bounds.width), height: Double(bounds.height))
    }

    @discardableResult
    private func dragUpdated(_ sender: NSDraggingInfo, over pane: TranscriptViewController) -> Bool {
        guard let id = panes.first(where: { $0.value === pane })?.key else { return false }
        let zone = zoneUnderPointer(sender, over: pane)
        let payload = payload(from: sender)
        let title = payload.flatMap { chatTitleForDrop?($0) }
        showDropHighlight(zone, on: pane, caption: zone.caption(title))
        dropZone = (id, zone)
        return true
    }

    private func showDropHighlight(
        _ zone: PaneDropZone, on pane: TranscriptViewController, caption: String
    ) {
        let paneFrame = pane.view.convert(pane.view.bounds, to: view)
        let rect = PaneDropTarget.highlight(
            for: zone, width: Double(paneFrame.width), height: Double(paneFrame.height))
        let y =
            view.isFlipped
            ? paneFrame.minY + rect.y : paneFrame.maxY - rect.y - rect.height
        let frame = NSRect(
            x: paneFrame.minX + rect.x, y: y, width: rect.width, height: rect.height)
        dropHighlight.show(frame: frame, caption: caption)
        view.addSubview(dropHighlight, positioned: .above, relativeTo: nil)
    }

    func clearDropHighlight() {
        dropZone = nil
        dropHighlight.clear()
    }

    @discardableResult
    private func receiveDrop(_ sender: NSDraggingInfo, on pane: TranscriptViewController) -> Bool {
        clearDropHighlight()
        guard let payload = payload(from: sender) else { return false }
        return onChatDropped?(pane, payload, zoneUnderPointer(sender, over: pane)) ?? false
    }

    private func payload(from sender: NSDraggingInfo) -> PaneDragPayload? {
        let pb = sender.draggingPasteboard
        guard let text = pb.string(forType: .tailscodeChat) else { return nil }
        return PaneDragPayload.decode(text)
    }

    func snapshot() -> SplitSnapshot {
        var sessions: [String: SplitPaneSession] = [:]
        var videos: [String: String] = [:]
        var pages: [String: String] = [:]
        for (id, pane) in panes {
            if let target = pane.webTarget {
                pages[id.raw] = target.address
                continue
            }
            if let target = pane.videoTarget {
                videos[id.raw] = target.address
                continue
            }
            guard let entry = pane.currentEntry else { continue }
            sessions[id.raw] = SplitPaneSession(
                profileID: entry.profileID, sessionID: entry.session.id)
        }
        return SplitSnapshot(layout: layout, sessions: sessions, videos: videos, pages: pages)
    }

    /// The same key and shape the Linux desktop persists, so both restore the same arrangement.
    /// A lone pane clears the record: the plain window needs no layout file.
    func persist() {
        let current = snapshot()
        if paneCount > 1 || !current.videos.isEmpty || !current.pages.isEmpty,
            let encoded = current.encoded
        {
            UserDefaults.standard.set(encoded, forKey: SplitSnapshot.defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: SplitSnapshot.defaultsKey)
        }
        onLayoutChanged?()
    }

    /// Rebuilds the controller skeleton around the surviving panes. Panes detach first so no
    /// `NSSplitViewItem` still claims them when they join the new tree, and the ratios are asserted
    /// twice on purpose: once here, so a tree that already has an extent is never painted at
    /// `NSSplitView`'s own even distribution and then jumped to the real arrangement a frame later,
    /// and once on the next turn for the tree that had no extent yet.
    private func rebuild() {
        for pane in panes.values {
            pane.removeFromParent()
            pane.view.removeFromSuperview()
        }
        if let treeRoot {
            treeRoot.removeFromParent()
            treeRoot.view.removeFromSuperview()
        }
        splitViews = [:]
        splitItems = [:]
        splitLeaves = [:]
        let built = build(layout.root)
        addChild(built)
        built.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(built.view)
        NSLayoutConstraint.activate([
            built.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            built.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            built.view.topAnchor.constraint(equalTo: view.topAnchor),
            built.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        treeRoot = built
        applyZoom()
        applyFocusStyling()
        applyIdentity()
        applyRatios()
        DispatchQueue.main.async { [weak self] in self?.applyRatios() }
    }

    private func build(_ node: SplitNode) -> NSViewController {
        switch node {
        case .pane(let id):
            guard let pane = panes[id] else { return NSViewController() }
            pane.removeFromParent()
            pane.view.removeFromSuperview()
            return pane
        case .split(let id, let axis, _, let first, let second):
            let controller = NSSplitViewController()
            let splitView = DividerSplitView()
            splitView.onDividerDoubleClick = { [weak self] in self?.equalize() }
            controller.splitView = splitView
            controller.splitView.isVertical = axis == .horizontal
            controller.splitView.dividerStyle = .thin
            let firstItem = NSSplitViewItem(viewController: build(first))
            let secondItem = NSSplitViewItem(viewController: build(second))
            for item in [firstItem, secondItem] {
                item.minimumThickness = paneFloor(axis)
                item.canCollapse = false
            }
            controller.addSplitViewItem(firstItem)
            controller.addSplitViewItem(secondItem)
            splitViews[id] = controller.splitView
            splitItems[id] = (firstItem, secondItem)
            splitLeaves[id] = (Set(Self.leaves(of: first)), Set(Self.leaves(of: second)))
            NotificationCenter.default.addObserver(
                self, selector: #selector(splitResized(_:)),
                name: NSSplitView.didResizeSubviewsNotification, object: controller.splitView)
            return controller
        }
    }

    /// The floor a pane is held to, which is the promised extent only while the tree has room to
    /// promise it to every pane at once. A required minimum the surface cannot satisfy is not a
    /// floor: it is a broken constraint, and what comes out of it is an arrangement of uneven panes
    /// that no drag can even out.
    private func paneFloor(_ axis: SplitAxis) -> CGFloat {
        let ideal: CGFloat =
            axis == .horizontal ? CGFloat(PaneDropTarget.minimumPaneExtent) : 160
        let extent = axis == .horizontal ? view.bounds.width : view.bounds.height
        guard extent > 0 else { return ideal }
        return min(ideal, extent / CGFloat(max(1, layout.paneCount)))
    }

    private static func leaves(of node: SplitNode) -> [PaneID] {
        switch node {
        case .pane(let id): return [id]
        case .split(_, _, _, let first, let second):
            return leaves(of: first) + leaves(of: second)
        }
    }

    /// Positions from ratios, asserted after layout so the split has an extent to divide, and
    /// walked outermost-first with a layout pass after each divider — a nested split only learns
    /// its new extent once its parent's position has actually landed, so any other order divides
    /// an extent the tree is about to stop having.
    func applyRatios() {
        suppressCapture = true
        defer { suppressCapture = false }
        view.layoutSubtreeIfNeeded()
        applyRatios(layout.root)
    }

    private func applyRatios(_ node: SplitNode) {
        guard case .split(let id, _, let ratio, let first, let second) = node else { return }
        if let splitView = splitViews[id] {
            let extent = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
            if extent > 50 {
                splitView.setPosition((extent - splitView.dividerThickness) * ratio, ofDividerAt: 0)
                splitView.layoutSubtreeIfNeeded()
            }
        }
        applyRatios(first)
        applyRatios(second)
    }

    /// A divider drag settles into the model as a ratio, exactly the way the window's own
    /// dividers persist — mid-collapse widths that are nobody's intent are ignored.
    @objc private func splitResized(_ notification: Notification) {
        guard !suppressCapture,
            let splitView = notification.object as? NSSplitView,
            let id = splitViews.first(where: { $0.value === splitView })?.key,
            let firstView = splitView.arrangedSubviews.first
        else { return }
        let extent = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        let position = splitView.isVertical ? firstView.frame.width : firstView.frame.height
        guard extent > 150, position > 40, position < extent - 40 else { return }
        layout.setRatio(position / extent, of: id)
        if paneCount > 1, let encoded = snapshot().encoded {
            UserDefaults.standard.set(encoded, forKey: SplitSnapshot.defaultsKey)
        }
    }

    /// The zoom is collapse along the tree: every split hides the side that does not contain the
    /// zoomed pane, so one conversation borrows the whole surface and unzooming shows everything
    /// exactly where it was.
    private func applyZoom() {
        let zoomed = layout.zoomedPane
        for (id, items) in splitItems {
            guard let zoomed, let leaves = splitLeaves[id] else {
                items.first.isCollapsed = false
                items.second.isCollapsed = false
                continue
            }
            items.first.isCollapsed = leaves.second.contains(zoomed)
            items.second.isCollapsed = leaves.first.contains(zoomed)
        }
    }

    /// A hairline accent on the focused pane, only once a second pane exists to be told apart
    /// from — a lone pane stays exactly the window it always was. The border is a `CGColor` and so
    /// keeps the accent it was born with, which is why the window asks for this again whenever the
    /// palette changes, beside the pane colours it repaints in the same moment.
    func applyFocusStyling() {
        let showAccent = layout.paneCount > 1
        for (id, pane) in panes {
            let layer = pane.view.layer
            if showAccent, id == layout.focusedPane {
                layer?.borderColor = MacTheme.Color.accent.withAlphaComponent(0.55).cgColor
                layer?.borderWidth = 1
            } else {
                layer?.borderWidth = 0
            }
        }
    }

    private func applyIdentity() {
        let several = layout.paneCount > 1
        for pane in panes.values { pane.setIdentityVisible(several) }
    }
}

/// A split view whose divider answers a double click by evening the whole arrangement out. The
/// second click is intercepted before `NSSplitView` starts tracking a drag, and only when it
/// lands in the gap between the two subviews — a double click anywhere in a conversation is none
/// of this view's business.
final class DividerSplitView: NSSplitView {
    var onDividerDoubleClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2, hitsDivider(convert(event.locationInWindow, from: nil)) {
            onDividerDoubleClick?()
            return
        }
        super.mouseDown(with: event)
    }

    private func hitsDivider(_ point: NSPoint) -> Bool {
        guard !arrangedSubviews.contains(where: { $0.frame.contains(point) }) else { return false }
        let slop = max(dividerThickness, 4)
        for (left, right) in zip(arrangedSubviews, arrangedSubviews.dropFirst()) {
            let ordered =
                isVertical
                ? (left.frame.minX <= right.frame.minX ? (left, right) : (right, left))
                : (left.frame.minY <= right.frame.minY ? (left, right) : (right, left))
            let low =
                isVertical ? ordered.0.frame.maxX : ordered.0.frame.maxY
            let high =
                isVertical ? ordered.1.frame.minX : ordered.1.frame.minY
            let value = isVertical ? point.x : point.y
            if value >= low - slop, value <= high + slop { return true }
        }
        return false
    }
}
