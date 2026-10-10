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
    /// Sessions panes hold without showing them yet — parked by a safe restore, waiting their turn
    /// in a staggered one, or waiting for their server — so a layout saved meanwhile keeps them
    /// rather than writing those panes down as empty.
    var heldSessions: (() -> [PaneID: SplitPaneSession])?
    /// A verb refused with a reason — a split with no room for another pane.
    var onRefused: ((String) -> Void)?
    /// Panes the governor parks on top of what zoom and occlusion already hide.
    private var governorParked: Set<PaneID> = []
    private var occluded = false
    /// The layout written a moment after the last change rather than on every focus move and every
    /// divider notification; nil clears the record. Flushed on every exit path.
    private let writer = TrailingWriter<String?>(label: "tailscode.layout-writer") { encoded in
        if let encoded {
            UserDefaults.standard.set(encoded, forKey: SplitSnapshot.defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: SplitSnapshot.defaultsKey)
        }
    }
    /// Layout writes asked for, and divider notifications that moved a ratio — counted for the
    /// selftest that proves a burst of changes is one write and a programmatic resize is none.
    private(set) var persistRequests = 0
    private(set) var ratioCaptures = 0

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

    func id(of pane: TranscriptViewController) -> PaneID? {
        panes.first { $0.value === pane }?.key
    }

    /// Lays a strip across the top of the pane area, above every pane and under the toolbar. The
    /// tree is always rebuilt beneath what is already here, so an overlay stays on top without
    /// ever being moved.
    func installOverlay(_ overlay: NSView) {
        overlay.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(overlay, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
        ])
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
        guard hasRoom(layout.focusedPane, axis: axis) else { return }
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
            hasRoom(id, axis: edge.axis),
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

    /// Whether a pane can halve along `axis` in the room the tree really has, asked of Core's
    /// placement at the container's size; a refusal is said rather than swallowed.
    func canSplit(_ id: PaneID, axis: SplitAxis) -> Bool {
        let size = view.bounds.size
        guard size.width > 0, size.height > 0 else { return true }
        let placement = layout.placement(
            in: SplitSize(width: Double(size.width), height: Double(size.height)),
            scale: Double(view.window?.backingScaleFactor ?? 2))
        return layout.canSplit(id, axis: axis, in: placement)
    }

    private func hasRoom(_ id: PaneID, axis: SplitAxis) -> Bool {
        guard canSplit(id, axis: axis) else {
            onRefused?(Localized.text("No room for another split here"))
            return false
        }
        return true
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

    /// The tree laid out in the area the panes actually have, which is what the resize verbs and a
    /// divider's own range are read from. Every pane is held to the floor this host gives the split
    /// items — the same one AppKit enforces on a pointer drag, so a key and a drag stop at the same
    /// line, and one that never outgrows the room, so no pane is ever left out of the solve.
    private func currentPlacement() -> PanePlacement {
        let size = view.bounds.size
        return layout.placement(
            in: SplitSize(width: Double(size.width), height: Double(size.height)),
            scale: Double(view.window?.backingScaleFactor ?? 2), stripHeight: 0
        ) { [self] id in
            panes[id] == nil
                ? .zero
                : PaneMinimum(
                    width: Double(paneFloor(.horizontal)), height: Double(paneFloor(.vertical)))
        }
    }

    /// The registered pane chords that act on the tree itself — arrange, promote, rotate, move to
    /// an edge, resize, cycle — through Core's one dispatcher, so this desktop and the Linux one
    /// cannot mean different things by the same key. A chord with nothing to do (one pane has
    /// nothing to rotate) is still the tree's, and is spent rather than handed on.
    @discardableResult
    func perform(_ action: KeyAction) -> Bool {
        guard let effect = layout.perform(action, placement: currentPlacement()) else {
            return true
        }
        applyEffect(effect)
        return true
    }

    /// Rebuilds the tree as the arrangement a menu item named.
    func arrange(_ arrangement: SplitArrangement) {
        guard let effect = layout.choose(arrangement) else { return }
        applyEffect(effect)
    }

    /// Redoes only as much of the window as the verb undid and writes the tree down. A verb that
    /// only moves panes about leaves the keyboard where it is, so the chord can be pressed again.
    private func applyEffect(_ effect: SplitVerbEffect) {
        switch effect {
        case .restructured:
            rebuild()
        case .resized:
            settleRatios()
        case .refocused:
            applyZoom()
            applyFocusStyling()
        }
        onFocusChanged?()
        persist()
    }

    /// A key on a focused divider, or VoiceOver stepping an adjustable one: the same clamped move
    /// the pointer makes.
    private func moveDivider(_ split: SplitID, by key: DividerKey) -> Bool {
        guard layout.move(split, by: key, in: currentPlacement()) else { return true }
        settleRatios()
        schedulePersist()
        return true
    }

    /// What a divider tells assistive technology: which two panes it divides, and its position
    /// between the extremes it can travel, in Core's words.
    private func dividerReading(_ split: SplitID) -> DividerAccessibilityReading? {
        let placement = currentPlacement()
        guard let divider = placement.divider(split), let sides = layout.sides(of: split) else {
            return nil
        }
        func names(_ ids: [PaneID]) -> [String] {
            ids.map { id in
                let name = panes[id]?.paneName ?? ""
                return name.isEmpty ? Localized.text("Pane") : name
            }
        }
        var standing = divider
        if let first = (splitViews[split])?.arrangedSubviews.first {
            let held = Double(splitViews[split]?.isVertical == true ? first.frame.width : first.frame.height)
            standing.position = min(max(held, divider.lowest), divider.highest)
        }
        return DividerAccessibilityReading(
            label: DividerReading.label(first: names(sides.first), second: names(sides.second)),
            value: DividerReading.value(standing), position: standing.position,
            minimum: divider.lowest, maximum: divider.highest)
    }

    /// Every pane its fair share, from the menu verb or a double click on any divider.
    func equalize() {
        layout.equalize()
        settleRatios()
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
            if let address = snapshot.draw(for: id) {
                pane.showDraw(ImageGenEndpoint(address: address))
                continue
            }
            #if !TAILSCODE_MAS
                if let target = snapshot.page(for: id) {
                    pane.showWeb(target)
                    continue
                }
            #endif
            #if !TAILSCODE_MAS
                if let target = snapshot.video(for: id) {
                    pane.showVideo(target)
                    continue
                }
            #endif
            if let session = snapshot.session(for: id) { bindings[id] = session }
        }
        rebuild()
        return bindings
    }

    private func installDropTarget(on pane: TranscriptViewController) {
        pane.view.registerForDraggedTypes([.tailscodeChat, .tailscodePane])
        pane.paneMovePayload = { [weak self, weak pane] in
            guard let self, let pane, let id = self.id(of: pane) else { return nil }
            return PaneMovePayload(pane: id)
        }
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
        if let moving = panePayload(from: sender) {
            guard moving.pane != id, layout.contains(moving.pane) else {
                clearDropHighlight()
                return false
            }
            showDropHighlight(zone, on: pane, caption: zone.moveVerb)
            dropZone = (id, zone)
            return true
        }
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
        if let moving = panePayload(from: sender) {
            return receivePaneDrop(moving, on: pane, zone: zoneUnderPointer(sender, over: pane))
        }
        guard let payload = payload(from: sender) else { return false }
        return onChatDropped?(pane, payload, zoneUnderPointer(sender, over: pane)) ?? false
    }

    /// A pane let go over another. A pane dropped on itself or carrying a pane the tree no longer
    /// holds changes nothing, and the pane that moved is the one that takes the focus.
    @discardableResult
    func receivePaneDrop(
        _ moving: PaneMovePayload, on pane: TranscriptViewController, zone: PaneDropZone
    ) -> Bool {
        guard let id = self.id(of: pane), layout.contains(moving.pane),
            let intent = PaneDropTarget.move(moving.pane, onto: id, zone: zone),
            layout.apply(intent)
        else { return false }
        layout.focus(moving.pane)
        rebuild()
        onFocusChanged?()
        persist()
        return true
    }

    private func panePayload(from sender: NSDraggingInfo) -> PaneMovePayload? {
        guard let text = sender.draggingPasteboard.string(forType: .tailscodePane) else {
            return nil
        }
        return PaneMovePayload.decode(text)
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
        var draws: [String: String] = [:]
        let held = heldSessions?() ?? [:]
        for (id, pane) in panes {
            if let endpoint = pane.drawEndpoint {
                draws[id.raw] = endpoint.address
                continue
            }
            if let target = pane.webTarget {
                pages[id.raw] = target.address
                continue
            }
            #if !TAILSCODE_MAS
                if let target = pane.videoTarget {
                    videos[id.raw] = target.address
                    continue
                }
            #endif
            guard let entry = pane.currentEntry else {
                if let session = held[id] { sessions[id.raw] = session }
                continue
            }
            sessions[id.raw] = SplitPaneSession(
                profileID: entry.profileID, sessionID: entry.session.id)
        }
        return SplitSnapshot(
            layout: layout, sessions: sessions, videos: videos, pages: pages, draws: draws)
    }

    /// The same key and shape the Linux desktop persists, so both restore the same arrangement.
    /// A lone pane clears the record: the plain window needs no layout file.
    func persist() {
        schedulePersist()
        onLayoutChanged?()
    }

    private func schedulePersist() {
        persistRequests += 1
        let current = snapshot()
        if paneCount > 1 || !current.videos.isEmpty || !current.pages.isEmpty
            || !current.draws.isEmpty,
            let encoded = current.encoded
        {
            writer.schedule(encoded)
        } else {
            writer.schedule(nil)
        }
    }

    /// Writes the waiting layout now; every exit path calls it.
    func flushPersistence() {
        writer.flush()
    }

    /// Rebuilds the controller skeleton around the surviving panes. Panes detach first so no
    /// `NSSplitViewItem` still claims them when they join the new tree, and the ratios are asserted
    /// twice on purpose: once here, so a tree that already has an extent is never painted at
    /// `NSSplitView`'s own even distribution and then jumped to the real arrangement a frame later,
    /// and once on the next turn for the tree that had no extent yet.
    private func rebuild() {
        suppressCapture = true
        for pane in panes.values {
            pane.removeFromParent()
            pane.view.removeFromSuperview()
        }
        if let treeRoot {
            treeRoot.removeFromParent()
            treeRoot.view.removeFromSuperview()
        }
        for splitView in splitViews.values {
            NotificationCenter.default.removeObserver(
                self, name: NSSplitView.didResizeSubviewsNotification, object: splitView)
        }
        splitViews = [:]
        splitItems = [:]
        splitLeaves = [:]
        let built = build(layout.root)
        addChild(built)
        built.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(built.view, positioned: .below, relativeTo: nil)
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
        settleRatios()
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
            splitView.onDividerKey = { [weak self] key in self?.moveDivider(id, by: key) ?? false }
            splitView.accessibilityReading = { [weak self] in self?.dividerReading(id) }
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
        let count = CGFloat(max(1, layout.paneCount))
        return min(ideal, (extent - (count - 1) * CGFloat(PaneSizing.gutter)) / count)
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
    /// Whether every divider was already where the tree puts it, so nothing was left to correct.
    @discardableResult
    func applyRatios() -> Bool {
        let held = suppressCapture
        suppressCapture = true
        defer { suppressCapture = held }
        view.layoutSubtreeIfNeeded()
        var settled = true
        applyRatios(layout.root, placement: currentPlacement(), settled: &settled)
        return settled
    }

    private func applyRatios(_ node: SplitNode, placement: PanePlacement, settled: inout Bool) {
        guard case .split(let id, _, let ratio, let first, let second) = node else { return }
        if let splitView = splitViews[id] {
            let extent = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
            if extent > 50 {
                let position =
                    placement.divider(id)?.position
                    ?? Double((extent - splitView.dividerThickness) * ratio)
                let before = splitView.arrangedSubviews.first.map {
                    splitView.isVertical ? $0.frame.width : $0.frame.height
                }
                splitView.setPosition(CGFloat(position), ofDividerAt: 0)
                splitView.layoutSubtreeIfNeeded()
                let after = splitView.arrangedSubviews.first.map {
                    splitView.isVertical ? $0.frame.width : $0.frame.height
                }
                if before.map({ abs(Double($0) - position) > 1 }) ?? true
                    || after.map({ abs(Double($0) - position) > 1 }) ?? true
                {
                    settled = false
                }
            }
        }
        applyRatios(first, placement: placement, settled: &settled)
        applyRatios(second, placement: placement, settled: &settled)
    }

    /// AppKit redistributes a nested split's thickness as the one above it moves, so a position
    /// written once can be undone by the layout it causes. Writing the tree's positions again
    /// until a pass finds every divider already there is what leaves it there; the passes are a
    /// few frames apart and give up after a handful, because a floor that cannot be honoured is
    /// a clamp, not a race.
    func settleRatios() {
        suppressCapture = true
        if applyRatios() {
            suppressCapture = false
            return
        }
        settle(attempt: 1)
    }

    private func settle(attempt: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(30)) { [weak self] in
            guard let self else { return }
            if self.applyRatios() || attempt >= 8 {
                self.suppressCapture = false
            } else {
                self.settle(attempt: attempt + 1)
            }
        }
    }

    /// A divider drag settles into the model as a ratio, exactly the way the window's own
    /// dividers persist — mid-collapse widths that are nobody's intent are ignored, and so is every
    /// resize the person did not make with a divider: a window resize, a zoom, a rebuild. Only a
    /// ratio that actually moved is written, and the write trails the drag.
    @objc private func splitResized(_ notification: Notification) {
        guard !suppressCapture, Self.isDividerDrag(notification),
            let splitView = notification.object as? NSSplitView,
            let id = splitViews.first(where: { $0.value === splitView })?.key,
            let firstView = splitView.arrangedSubviews.first
        else { return }
        let extent = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        let position = splitView.isVertical ? firstView.frame.width : firstView.frame.height
        guard extent > 150, position > 40, position < extent - 40 else { return }
        let share = position / (extent - splitView.dividerThickness)
        guard abs((layout.ratio(of: id) ?? -1) - share) > 0.001 else { return }
        let placement = currentPlacement()
        if let divider = placement.divider(id) {
            let coordinate = Double(share)
                * (divider.parent.extent(along: divider.axis) - PaneSizing.gutter)
            layout.drag(id, to: coordinate, in: placement)
            if coordinate < divider.lowest - 1 || coordinate > divider.highest + 1 {
                settleRatios()
            }
        } else {
            layout.setRatio(Double(share), of: id)
        }
        ratioCaptures += 1
        schedulePersist()
    }

    /// `NSSplitView` names the divider in the notification only when a divider is being dragged,
    /// and a drag is a mouse gesture; a resize from anywhere else carries neither.
    private static func isDividerDrag(_ notification: Notification) -> Bool {
        guard notification.userInfo?["NSSplitViewDividerIndex"] != nil else { return false }
        switch NSApp?.currentEvent?.type {
        case .leftMouseDragged, .leftMouseDown, .leftMouseUp: return true
        default: return false
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
        applyParking()
    }

    /// A pane nobody can see owns no stream and no clock: zoomed away, the window not visible, or
    /// parked by the governor. Showing it again takes its chat back.
    func applyParking() {
        let zoomed = layout.zoomedPane
        for (id, pane) in panes {
            let hidden = zoomed != nil && zoomed != id
            pane.setParked(occluded || hidden || governorParked.contains(id))
        }
    }

    /// Whether the window is visible at all, from its occlusion state.
    func setOccluded(_ occluded: Bool) {
        guard occluded != self.occluded else { return }
        self.occluded = occluded
        if !occluded { governorParked = [] }
        applyParking()
    }

    /// The governor's parked panes, from the seatbelts' one-second decision.
    func applyGovernor(_ densities: [PaneID: PaneDensity]) {
        let parked = Set(densities.filter { $0.value == .parked }.keys)
        guard parked != governorParked else { return }
        governorParked = parked
        applyParking()
    }

    /// A hairline accent on the focused pane, only once a second pane exists to be told apart
    /// from — a lone pane stays exactly the window it always was. The border is a `CGColor` and so
    /// keeps the accent it was born with, which is why the window asks for this again whenever the
    /// palette changes, beside the pane colours it repaints in the same moment.
    func applyFocusStyling() {
        let showAccent = layout.paneCount > 1
        for (id, pane) in panes {
            pane.setFocusedPane(id == layout.focusedPane)
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

/// What a divider says about itself to assistive technology: the two panes it divides, and where
/// it stands between the extremes it can travel — Core's words, read live from the tree.
struct DividerAccessibilityReading {
    let label: String
    let value: String
    let position: Double
    let minimum: Double
    let maximum: Double
}

/// A split view whose divider answers a double click by evening the whole arrangement out. The
/// second click is intercepted before `NSSplitView` starts tracking a drag, and only when it
/// lands in the gap between the two subviews — a double click anywhere in a conversation is none
/// of this view's business.
///
/// Every split here has exactly one divider, so the view itself is the divider's keyboard focus: a
/// press on the gap takes it, and while it holds it the arrow keys move the divider by the
/// keyboard step, shift by the large one, and Home and End take it to its extremes. It is also
/// the divider's accessibility element — an adjustable splitter with a label, a position between
/// its extremes, and increment and decrement that step by the same nudge.
final class DividerSplitView: NSSplitView {
    var onDividerDoubleClick: (() -> Void)?
    var onDividerKey: ((DividerKey) -> Bool)?
    var accessibilityReading: (() -> DividerAccessibilityReading?)?
    private lazy var splitterElement = DividerAccessibilityElement(owner: self)

    override var acceptsFirstResponder: Bool { onDividerKey != nil }

    override func becomeFirstResponder() -> Bool {
        needsDisplay = true
        return super.becomeFirstResponder()
    }

    override func resignFirstResponder() -> Bool {
        needsDisplay = true
        return super.resignFirstResponder()
    }

    override func drawDivider(in rect: NSRect) {
        guard window?.firstResponder === self else { return super.drawDivider(in: rect) }
        MacTheme.Color.accent.setFill()
        rect.fill()
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if hitsDivider(point) {
            window?.makeFirstResponder(self)
            if event.clickCount == 2 {
                onDividerDoubleClick?()
                return
            }
        }
        super.mouseDown(with: event)
    }

    override func keyDown(with event: NSEvent) {
        guard let key = Self.dividerKey(for: event), onDividerKey?(key) == true else {
            return super.keyDown(with: event)
        }
    }

    /// The divider key an event spells, or nil: an arrow steps, shift makes it large, Home and End
    /// go to the extremes, and anything with command, control or option is somebody else's chord.
    static func dividerKey(for event: NSEvent) -> DividerKey? {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        guard flags.isDisjoint(with: [.command, .control, .option]) else { return nil }
        let large = flags.contains(.shift)
        switch event.keyCode {
        case 123, 126: return .back(large: large)
        case 124, 125: return .forward(large: large)
        case 115: return .lowest
        case 119: return .highest
        default: return nil
        }
    }

    override func accessibilityChildren() -> [Any]? {
        guard accessibilityReading != nil else { return super.accessibilityChildren() }
        var children = (super.accessibilityChildren() ?? []).filter {
            ($0 as? NSAccessibilityProtocol)?.accessibilityRole() != .splitter
        }
        children.append(splitterElement)
        return children
    }

    /// Where the gap between the two subviews is, in this view's coordinates.
    var dividerRect: NSRect {
        guard arrangedSubviews.count == 2 else { return .zero }
        let ordered =
            isVertical
            ? arrangedSubviews.sorted { $0.frame.minX < $1.frame.minX }
            : arrangedSubviews.sorted { $0.frame.minY < $1.frame.minY }
        let low = isVertical ? ordered[0].frame.maxX : ordered[0].frame.maxY
        let high = isVertical ? ordered[1].frame.minX : ordered[1].frame.minY
        let thickness = max(high - low, dividerThickness)
        return isVertical
            ? NSRect(x: low, y: 0, width: thickness, height: bounds.height)
            : NSRect(x: 0, y: low, width: bounds.width, height: thickness)
    }

    fileprivate func step(_ key: DividerKey) -> Bool {
        onDividerKey?(key) ?? false
    }

    fileprivate func hitsDivider(_ point: NSPoint) -> Bool {
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

/// The divider as VoiceOver meets it: a splitter that says which two panes it divides, reads its
/// position as a value between the extremes it can travel, and steps by the keyboard nudge when
/// incremented or decremented. It stands in for the toolkit's own splitter, which knows neither
/// the clamp nor the names.
final class DividerAccessibilityElement: NSAccessibilityElement {
    private unowned let owner: DividerSplitView

    init(owner: DividerSplitView) {
        self.owner = owner
        super.init()
    }

    private var reading: DividerAccessibilityReading? { owner.accessibilityReading?() }

    override func accessibilityRole() -> NSAccessibility.Role? { .splitter }

    override func accessibilityParent() -> Any? { owner }

    override func accessibilityLabel() -> String? { reading?.label }

    override func accessibilityValue() -> Any? { reading.map { NSNumber(value: $0.position) } }

    override func accessibilityValueDescription() -> String? { reading?.value }

    override func accessibilityMinValue() -> Any? { reading.map { NSNumber(value: $0.minimum) } }

    override func accessibilityMaxValue() -> Any? { reading.map { NSNumber(value: $0.maximum) } }

    override func accessibilityOrientation() -> NSAccessibilityOrientation {
        owner.isVertical ? .vertical : .horizontal
    }

    override func accessibilityFrame() -> NSRect {
        guard let window = owner.window else { return .zero }
        let inWindow = owner.convert(owner.dividerRect, to: nil)
        return window.convertToScreen(inWindow)
    }

    override func isAccessibilityFocused() -> Bool {
        owner.window?.firstResponder === owner
    }

    override func setAccessibilityFocused(_ focused: Bool) {
        if focused { owner.window?.makeFirstResponder(owner) }
    }

    override func accessibilityPerformIncrement() -> Bool {
        owner.step(.forward(large: false))
    }

    override func accessibilityPerformDecrement() -> Bool {
        owner.step(.back(large: false))
    }
}

#if DEBUG
    extension SplitPaneHost {
        /// The tree as the driver reads it: how many panes, what shape, which holds the focus and
        /// in what reading order, by the first characters of each pane's id.
        func driveOrder(_ label: String) -> String {
            let order = layout.paneIDs.map { String($0.raw.prefix(4)) }.joined(separator: ",")
            let focus = layout.paneIDs.firstIndex(of: layout.focusedPane) ?? -1
            return
                "\(label) panes=\(layout.paneCount) shape=\(SplitEven.shape(of: layout)) "
                + "focus=\(focus) zoom=\(layout.zoomedPane != nil) order=\(order)"
        }

        /// Every pane's frame in the tree's own coordinates, top-left origin, in reading order.
        func driveGeometry() -> String {
            view.layoutSubtreeIfNeeded()
            let frames = orderedPanes.enumerated().map { index, pane -> String in
                let rect = pane.view.convert(pane.view.bounds, to: view)
                let top = view.isFlipped ? rect.minY : view.bounds.height - rect.maxY
                return String(
                    format: "%d(%.0f,%.0f %.0fx%.0f)", index, rect.minX, top, rect.width,
                    rect.height)
            }
            return
                "GEOM \(frames.joined(separator: " ")) canvas=\(Int(view.bounds.width))x\(Int(view.bounds.height))"
        }

        /// What VoiceOver would be told about each divider, in reading order, and whether it holds
        /// the keyboard.
        func driveDividers() -> String {
            let lines = layout.splitIDs.enumerated().compactMap { index, id -> String? in
                guard let splitView = splitViews[id] as? DividerSplitView,
                    let element = (splitView.accessibilityChildren() ?? []).compactMap({
                        $0 as? DividerAccessibilityElement
                    }).first
                else { return nil }
                let value = (element.accessibilityValue() as? NSNumber)?.doubleValue ?? -1
                let low = (element.accessibilityMinValue() as? NSNumber)?.doubleValue ?? -1
                let high = (element.accessibilityMaxValue() as? NSNumber)?.doubleValue ?? -1
                let actual =
                    splitView.arrangedSubviews.first.map {
                        splitView.isVertical ? $0.frame.width : $0.frame.height
                    } ?? -1
                return String(
                    format: "%d role=%@ pos=%.0f actual=%.0f range=%.0f...%.0f focused=%d \"%@\" \"%@\"",
                    index, element.accessibilityRole()?.rawValue ?? "-", value, actual, low, high,
                    element.isAccessibilityFocused() ? 1 : 0,
                    element.accessibilityLabel() ?? "-",
                    element.accessibilityValueDescription() ?? "-")
            }
            return "DIVIDERS \(lines.count) " + lines.joined(separator: " | ")
        }

        /// A key on divider `index` without a keyboard: it takes focus and moves as a key would.
        func driveDivider(_ index: Int, key: DividerKey) -> Bool {
            let ids = layout.splitIDs
            guard ids.indices.contains(index), let splitView = splitViews[ids[index]] else {
                return false
            }
            view.window?.makeFirstResponder(splitView)
            return moveDivider(ids[index], by: key)
        }

        /// A strip carried over another pane without a pointer: the highlight is drawn where
        /// letting go would put the pane, captioned with the move it would make.
        func drivePaneHover(target: Int, u: Double, v: Double, source: Int) -> String {
            let panes = orderedPanes
            guard panes.indices.contains(target), panes.indices.contains(source) else {
                return "PDRAG no-target"
            }
            let pane = panes[target]
            let zone = PaneDropTarget.zone(
                x: u * Double(pane.view.bounds.width), y: v * Double(pane.view.bounds.height),
                width: Double(pane.view.bounds.width), height: Double(pane.view.bounds.height))
            guard target != source else {
                clearDropHighlight()
                return "PDRAG - caption=-"
            }
            showDropHighlight(zone, on: pane, caption: zone.moveVerb)
            return "PDRAG \(target) \(zone) caption=\(zone.moveVerb)"
        }

        /// A strip dropped on another pane: `target` and `source` are reading-order indexes and
        /// `u`, `v` where in the target the pointer is, as fractions from its top-left.
        func drivePaneDrop(target: Int, u: Double, v: Double, source: Int) -> String {
            let panes = orderedPanes
            guard panes.indices.contains(target), panes.indices.contains(source),
                let moving = id(of: panes[source])
            else { return "PDROP no-target" }
            let pane = panes[target]
            let zone = PaneDropTarget.zone(
                x: u * Double(pane.view.bounds.width), y: v * Double(pane.view.bounds.height),
                width: Double(pane.view.bounds.width), height: Double(pane.view.bounds.height))
            let took = receivePaneDrop(PaneMovePayload(pane: moving), on: pane, zone: zone)
            return "PDROP took=\(took) zone=\(zone) panes=\(paneCount)"
        }
    }
#endif
