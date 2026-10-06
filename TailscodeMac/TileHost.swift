import AppKit
import CodingAgentKit
import TailscodeCore

/// The tiling tree on the Mac, drawn as one frame-placed canvas.
///
/// `SplitLayout` decides the arrangement and Core's placement turns it into rectangles for a
/// container of a given size; this lays every pane's shell at its rectangle, a divider over every
/// seam, and the overflow strip under the panes the window cannot show. Nothing is nested and
/// nothing is re-parented: a split adds one shell, a close removes one, and every other verb —
/// exchange, rotate, promote, arrange, zoom, a window too small for every pane — is a change of
/// frames and of `isHidden`. The ratio a divider holds is written only when a person drags or
/// nudges it, never read back from what a layout happened to produce.
///
/// Each pane also has a density. The focused pane is the whole conversation; the governor's one-
/// second decision says which other chats stay whole and which become glance tiles, a pane too
/// small to be read whole is a glance whatever the governor says, and a pane out of sight —
/// zoomed away, overflowed, the window occluded — owns no stream and no clock. A pane demoted to
/// a glance lets go of its row views twenty seconds later; coming back rebuilds the tail.
@MainActor
final class TileHost: NSViewController, PaneTiling {
    private(set) var layout = SplitLayout()
    private(set) var panes: [PaneID: TranscriptViewController] = [:]
    private(set) var shells: [PaneID: TileShellView] = [:]
    private var dividers: [SplitID: TileDividerView] = [:]
    private(set) var canvas = TileCanvasView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    private let strip = OverflowStripView(frame: .zero)
    private let dropHighlight = PaneDropHighlightView(frame: .zero)
    private(set) var placement: PanePlacement?

    var makePane: (() -> TranscriptViewController)?
    /// Who every pane this host builds answers to, when no `makePane` was handed over.
    weak var paneHost: PaneHost?
    var onPaneOpened: ((TranscriptViewController, String?) -> Void)?
    var onChatDropped: ((TranscriptViewController, PaneDragPayload, PaneDropZone) -> Bool)?
    var chatTitleForDrop: ((PaneDragPayload) -> String?)?
    var onFocusChanged: (() -> Void)?
    var onLayoutChanged: (() -> Void)?
    var heldSessions: (() -> [PaneID: SplitPaneSession])?
    var onRefused: ((String) -> Void)?
    var onResume: ((PaneID) -> Void)?
    /// What the chat list last heard about a conversation: its title and its activity face. A
    /// paused pane and a chip in the strip are drawn from this, never from a stream.
    var listFace: ((SplitPaneSession) -> (title: String, activity: ActivityKind?)?)?

    private var pinned: Set<PaneID> = []
    private var userParked: Set<PaneID> = []
    private var held: [PaneID: SplitPaneSession] = [:]
    private var occluded = false
    private var decision: GovernorDecision?
    private var sizeAllowsFull: [PaneID: Bool] = [:]
    private var feeds: [PaneID: GlanceFeed] = [:]
    private var releases: [PaneID: Timer] = [:]
    private var promotionHold: [PaneID: TimeInterval] = [:]
    private var readings: [PaneID: (reading: GlanceReading, at: Date)] = [:]
    private var reliefToken: MemoryReliefToken?
    private var dropZone: (pane: PaneID, zone: PaneDropZone)?
    private var reconcileScheduled = false
    private var lastHidden: [PaneID] = []
    private var liveResizing = false
    private var deferredPeers: [PaneID] = []

    /// How long a demoted pane keeps its rows before letting them go, and how long a glance's
    /// last words are kept for the paused face.
    var demotedKeep: TimeInterval = 20
    static let readingKeep: TimeInterval = 600

    private let writer = TrailingWriter<String?>(label: "tailscode.layout-writer") { encoded in
        if let encoded {
            UserDefaults.standard.set(encoded, forKey: SplitSnapshot.defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: SplitSnapshot.defaultsKey)
        }
    }
    private(set) var persistRequests = 0
    private(set) var ratioCaptures = 0
    /// Main-thread milliseconds the last canvas layout took, and the last divider step from the
    /// pointer to rectangles settled, for the bench and the recorder.
    private(set) var lastLayoutCost: TimeInterval = 0
    private(set) var lastDragCost: TimeInterval = 0

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        canvas.onLayout = { [weak self] bounds in self?.place(in: bounds) }
        canvas.onLiveResize = { [weak self] live in self?.liveResize(live) }
        canvas.onAppearance = { [weak self] in self?.applyFocusStyling() }
        canvas.readingOrder = { [weak self] in
            guard let self else { return [] }
            return self.layout.paneIDs.compactMap { self.shells[$0] }.filter { !$0.isHidden }
        }
        strip.isHidden = true
        strip.translatesAutoresizingMaskIntoConstraints = true
        strip.autoresizingMask = []
        strip.onPress = { [weak self] id in self?.reveal(id) }
        canvas.addOverlay(strip)
        dropHighlight.autoresizingMask = []
        canvas.addOverlay(dropHighlight)
        view = canvas
        reliefToken = MemoryRelief.shared.register(name: "glance readings") { [weak self] depth in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.relieve(depth) }
            }
        }
    }

    /// Paused faces keep a glance's last words for ten minutes; under memory pressure they go
    /// sooner — half the age at strained, all but the live glances' at critical.
    private func relieve(_ depth: ReliefDepth) {
        if depth == .all {
            readings = readings.filter { feeds[$0.key] != nil }
        } else {
            let cutoff = Date().addingTimeInterval(-Self.readingKeep / 2)
            readings = readings.filter { $0.value.at > cutoff }
        }
    }

    func bootstrap() {
        guard panes.isEmpty else { return }
        adopt(buildPane(), as: layout.focusedPane)
        relayout()
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

    func pane(showing sessionID: String) -> TranscriptViewController? {
        orderedPanes.first { $0.currentEntry?.session.id == sessionID }
    }

    func eachPane(_ body: (TranscriptViewController) -> Void) {
        for pane in orderedPanes { body(pane) }
    }

    /// A strip hung across the top of the canvas, under the toolbar, inset from the panes' edges
    /// and above every pane.
    func installOverlay(_ overlay: NSView) {
        overlay.translatesAutoresizingMaskIntoConstraints = false
        canvas.addOverlay(overlay)
        let wide = overlay.widthAnchor.constraint(equalToConstant: 720)
        wide.priority = .defaultLow
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(
                equalTo: canvas.safeAreaLayoutGuide.topAnchor, constant: MacTheme.Spacing.s),
            overlay.centerXAnchor.constraint(equalTo: canvas.centerXAnchor),
            overlay.leadingAnchor.constraint(
                greaterThanOrEqualTo: canvas.leadingAnchor, constant: MacTheme.Spacing.l),
            overlay.widthAnchor.constraint(lessThanOrEqualToConstant: 720),
            wide,
        ])
    }

    private func buildPane() -> TranscriptViewController {
        if let makePane { return makePane() }
        let pane = TranscriptViewController()
        if let paneHost { pane.connect(to: paneHost) }
        return pane
    }

    /// A pane joins the canvas: its shell is made and added once, and the conversation goes in it
    /// for good.
    private func adopt(_ pane: TranscriptViewController, as id: PaneID) {
        panes[id] = pane
        let shell = TileShellView(paneID: id)
        shells[id] = shell
        shell.install(body: pane.view)
        addChild(pane)
        wireShell(shell, id: id)
        canvas.addPane(shell)
    }

    /// A pane leaves the canvas: its stream and clocks first, then its glance and timers, then the
    /// shell. The only removal a pane ever sees.
    private func retire(_ id: PaneID) {
        feeds.removeValue(forKey: id)?.cancel()
        releases.removeValue(forKey: id)?.invalidate()
        promotionHold[id] = nil
        readings[id] = nil
        sizeAllowsFull[id] = nil
        pinned.remove(id)
        userParked.remove(id)
        if let pane = panes.removeValue(forKey: id) {
            pane.shutdownPane()
            pane.removeFromParent()
        }
        if let shell = shells.removeValue(forKey: id) {
            shell.glance.stopClock()
            canvas.removePane(shell)
        }
    }

    private func wireShell(_ shell: TileShellView, id: PaneID) {
        shell.onDragEntered = { [weak self] sender in
            self?.dragUpdated(sender, over: id) ?? false
        }
        shell.onDragExited = { [weak self] in self?.clearDropHighlight() }
        shell.onDragPerform = { [weak self] sender in
            self?.receiveDrop(sender, on: id) ?? false
        }
    }

    private func wireGlance(_ glance: GlanceTileView, id: PaneID) {
        glance.onPress = { [weak self] in self?.promoteDensity(id) }
        glance.onDoubleClick = { [weak self] in
            guard let self else { return }
            self.promotionHold[id] = nil
            if self.layout.zoomedPane != id { self.zoom(id) }
        }
        glance.onOpenFull = { [weak self] in self?.promoteDensity(id, now: true) }
        glance.onKeepLive = { [weak self] in self?.togglePin(id) }
        glance.onPause = { [weak self] in self?.togglePark(id) }
        glance.onClose = { [weak self] in self?.close(id) }
        glance.paneMenuItems = { [weak self] in self?.paneMenu(for: id) ?? [] }
    }

    private func paneMenu(for id: PaneID) -> [NSMenuItem] {
        [
            ClosureMenuItem(title: Localized.text("Zoom Split")) { [weak self] in self?.zoom(id) },
            ClosureMenuItem(title: Localized.text("Promote to main")) { [weak self] in
                guard let self else { return }
                self.layout.focus(id)
                self.promoteActive()
            },
        ]
    }

    func splitActive(axis: SplitAxis) {
        let source = active.currentEntry?.profileID
        guard hasRoom(layout.focusedPane, axis: axis),
            let freshID = layout.split(layout.focusedPane, axis: axis)
        else { return }
        let pane = buildPane()
        adopt(pane, as: freshID)
        relayout()
        onPaneOpened?(pane, source)
        onFocusChanged?()
        persist()
    }

    @discardableResult
    func split(_ pane: TranscriptViewController, edge: PaneDropEdge) -> TranscriptViewController? {
        guard let id = id(of: pane), hasRoom(id, axis: edge.axis),
            let freshID = layout.split(id, axis: edge.axis, placingNewFirst: edge.placesArrivalFirst)
        else { return nil }
        let fresh = buildPane()
        adopt(fresh, as: freshID)
        relayout()
        onFocusChanged?()
        persist()
        return fresh
    }

    /// Whether a pane can halve along `axis` in the room it really has; a refusal is said rather
    /// than swallowed.
    func canSplit(_ id: PaneID, axis: SplitAxis) -> Bool {
        guard let placement = currentPlacement() else { return true }
        return layout.canSplit(id, axis: axis, in: placement)
    }

    private func hasRoom(_ id: PaneID, axis: SplitAxis) -> Bool {
        guard canSplit(id, axis: axis) else {
            onRefused?(Localized.text("No room for another split here"))
            return false
        }
        return true
    }

    func collapse(to keep: TranscriptViewController) {
        guard let keepID = id(of: keep), layout.contains(keepID) else { return }
        for id in layout.paneIDs where id != keepID {
            guard layout.close(id) != nil else { continue }
            retire(id)
        }
        layout.focus(keepID)
        relayout()
        onFocusChanged?()
        persist()
    }

    func closeActive() {
        close(layout.focusedPane)
    }

    private func close(_ id: PaneID) {
        guard layout.close(id) != nil else { return }
        retire(id)
        relayout()
        onFocusChanged?()
        persist()
    }

    @discardableResult
    func focusNeighbor(_ direction: SplitDirection) -> Bool {
        let wasZoomed = layout.zoomedPane != nil
        let moved = layout.focusNeighbor(direction)
        guard moved || wasZoomed else { return false }
        relayout()
        onFocusChanged?()
        persist()
        return moved
    }

    func zoomActive() {
        zoom(layout.focusedPane)
    }

    private func zoom(_ id: PaneID) {
        layout.toggleZoom(id)
        relayout()
        onFocusChanged?()
        persist()
    }

    func exchangeActive() {
        layout.exchange(layout.focusedPane)
        relayout()
        persist()
    }

    func equalize() {
        layout.equalize()
        relayout()
        persist()
    }

    @discardableResult
    func cycleFocus(forward: Bool) -> Bool {
        guard layout.cycleFocus(forward: forward, skipping: currentPlacement()) != nil else {
            return false
        }
        relayout()
        onFocusChanged?()
        persist()
        return true
    }

    func promoteActive() {
        guard layout.promote(layout.focusedPane) else { return }
        relayout()
        onFocusChanged?()
        persist()
    }

    func rotate(forward: Bool) {
        guard layout.rotate(forward: forward) else { return }
        relayout()
        persist()
    }

    func moveActiveToEdge(_ edge: SplitDirection) {
        guard layout.moveToEdge(layout.focusedPane, edge: edge) else { return }
        relayout()
        persist()
    }

    /// Rebuilds the tree as `arrangement`, or the next one in the cycle after the shape the tree
    /// already reads as; the focused pane leads, so main and stack puts it in the main slot.
    func arrange(_ arrangement: SplitArrangement?) {
        guard layout.paneCount > 1 else { return }
        let next = arrangement ?? SplitEven.shape(of: layout).nextInCycle
        guard layout.arrange(next, order: [layout.focusedPane]) else { return }
        relayout()
        persist()
    }

    func resizeActive(_ direction: SplitDirection, large: Bool) {
        guard let placement = currentPlacement() else { return }
        let step = large ? PaneSizing.keyboardStepLarge : PaneSizing.keyboardStep
        guard layout.resize(layout.focusedPane, direction, step: step, in: placement) else { return }
        ratioCaptures += 1
        relayout()
        schedulePersist()
    }

    var activeIsPinned: Bool { pinned.contains(layout.focusedPane) }
    var activeIsParked: Bool { userParked.contains(layout.focusedPane) }
    var supportsDensity: Bool { true }

    func togglePinActive() { togglePin(layout.focusedPane) }
    func toggleParkActive() { togglePark(layout.focusedPane) }

    /// Keep live: the governor gives this pane a full slot before any other peer while the level
    /// allows preference at all. At strained and above the pin is held but ignored, and the chip
    /// says so.
    private func togglePin(_ id: PaneID) {
        guard layout.contains(id) else { return }
        if pinned.remove(id) == nil { pinned.insert(id) }
        if pinned.contains(id) { userParked.remove(id) }
        reconcile()
        applyFocusStyling()
        persist()
    }

    /// Pause: the pane lets go of its stream and its clocks and wears the paused face until
    /// Resume. Only a conversation can be paused; a page or a stream is not a chat.
    private func togglePark(_ id: PaneID) {
        guard let pane = panes[id], pane.paneKind(held: held[id] != nil) == .chat else { return }
        if userParked.remove(id) == nil {
            userParked.insert(id)
            pinned.remove(id)
        }
        reconcile()
        applyFocusStyling()
    }

    /// The person pressed a glance, or asked for the whole conversation: it is focused, and
    /// becomes full once a double click has had its chance to mean zoom instead.
    private func promoteDensity(_ id: PaneID, now: Bool = false) {
        guard let pane = panes[id] else { return }
        if now { promotionHold[id] = nil }
        if layout.focusedPane != id {
            focus(pane, grabKeyboard: false)
        } else {
            reconcile()
        }
    }

    /// The pane a point lands in. A divider's band reaches four points into each neighbour, and a
    /// press there is a press on the divider, which activates no pane; so is a press on the strip.
    func pane(atWindowPoint point: NSPoint) -> TranscriptViewController? {
        for divider in dividers.values where !divider.isHiddenOrHasHiddenAncestor {
            if divider.bounds.contains(divider.convert(point, from: nil)) { return nil }
        }
        if !strip.isHidden, strip.bounds.contains(strip.convert(point, from: nil)) { return nil }
        for id in layout.paneIDs {
            guard let shell = shells[id], shell.window != nil,
                !shell.isHiddenOrHasHiddenAncestor
            else { continue }
            let local = shell.convert(point, from: nil)
            if NSMouseInRect(local, shell.bounds, shell.isFlipped) { return panes[id] }
        }
        return nil
    }

    /// Focus by intent. A press on a glance tile holds it a glance for one double-click interval
    /// so the second click of a double click lands on the tile it meant.
    func focus(_ pane: TranscriptViewController, grabKeyboard: Bool) {
        guard let id = id(of: pane), layout.focusedPane != id else { return }
        if let shell = shells[id], shell.face == .glance, let event = NSApp.currentEvent,
            event.type == .leftMouseDown, event.window != nil,
            shell.bounds.contains(shell.convert(event.locationInWindow, from: nil))
        {
            promotionHold[id] = CACurrentMediaTime() + NSEvent.doubleClickInterval
            DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval + 0.02) {
                [weak self] in
                MainActor.assumeIsolated {
                    self?.promotionHold[id] = nil
                    self?.reconcile()
                }
            }
        }
        layout.focus(id)
        reconcile()
        applyFocusStyling()
        if grabKeyboard { pane.focusComposer() }
        onFocusChanged?()
        persist()
    }

    /// A chip in the strip pressed: out of the zoom onto that pane, or, when the window had no room
    /// for it, swapped in for the placed pane focused longest ago.
    func reveal(_ id: PaneID) {
        guard layout.contains(id), let placement = currentPlacement() else { return }
        if layout.zoomedPane != nil {
            layout.toggleZoom(layout.zoomedPane!)
            layout.focus(id)
        } else if !placement.isPlaced(id),
            let stale = layout.recentlyFocused.reversed().first(where: { placement.isPlaced($0) })
        {
            layout.swap(id, stale)
            layout.focus(id)
        } else {
            layout.focus(id)
        }
        relayout()
        onFocusChanged?()
        persist()
    }

    func restore(_ snapshot: SplitSnapshot) -> [PaneID: SplitPaneSession] {
        guard snapshot.layout.isValid else { return [:] }
        for id in Array(panes.keys) { retire(id) }
        layout = snapshot.layout
        pinned = Set(snapshot.layout.paneIDs.filter { snapshot.isPinned($0) })
        var bindings: [PaneID: SplitPaneSession] = [:]
        for id in layout.paneIDs {
            let pane = buildPane()
            adopt(pane, as: id)
            switch snapshot.content(for: id) {
            case .chat(let session):
                bindings[id] = session
            case .web(let address):
                #if TAILSCODE_MAS
                    recordDropped("web")
                #else
                    if let target = WebTarget.classify(address) { pane.showWeb(target) }
                #endif
            case .video(let address):
                #if TAILSCODE_MAS
                    recordDropped("video")
                #else
                    if let target = VideoTarget.classify(address) { pane.showVideo(target) }
                #endif
            case .draw:
                recordDropped("draw")
            case .empty:
                break
            }
        }
        relayout()
        return bindings
    }

    /// A restored pane this copy cannot show comes back empty, and the recorder says which kind —
    /// never what it held.
    private func recordDropped(_ kind: String) {
        Seatbelts.shared.writer?.write(
            FlightRecord(t: FlightRecord.epochMilliseconds(), ev: "restore \(kind)->empty"))
        AppLogger.lifecycle.info("restore: a \(kind) pane this copy cannot show came back empty")
    }

    func snapshot() -> SplitSnapshot {
        var contents: [String: PaneContent] = [:]
        let waiting = heldSessions?() ?? [:]
        for (id, pane) in panes {
            if let target = pane.webTarget {
                contents[id.raw] = .web(target.address)
                continue
            }
            #if !TAILSCODE_MAS
                if let target = pane.videoTarget {
                    contents[id.raw] = .video(target.address)
                    continue
                }
            #endif
            if let entry = pane.currentEntry {
                contents[id.raw] = .chat(
                    SplitPaneSession(profileID: entry.profileID, sessionID: entry.session.id))
            } else if let session = waiting[id] ?? held[id] {
                contents[id.raw] = .chat(session)
            }
        }
        return SplitSnapshot(
            layout: layout, contents: contents,
            pinned: layout.paneIDs.filter { pinned.contains($0) }.map(\.raw))
    }

    func persist() {
        schedulePersist()
        onLayoutChanged?()
    }

    private func schedulePersist() {
        persistRequests += 1
        let current = snapshot()
        let slots = current.contents.values.contains { $0.kind != .chat }
        if paneCount > 1 || slots, let encoded = current.encoded {
            writer.schedule(encoded)
        } else {
            writer.schedule(nil)
        }
    }

    func flushPersistence() {
        writer.flush()
    }

    /// The tree changed: lay the canvas out now, in this pass, and settle every density.
    private func relayout() {
        canvas.needsLayout = true
        canvas.layoutSubtreeIfNeeded()
        reconcile()
        applyFocusStyling()
    }

    /// The placement for the canvas as it stands, solved if nothing has been laid out yet.
    private func currentPlacement() -> PanePlacement? {
        let size = canvas.bounds.size
        guard size.width > 0, size.height > 0 else { return nil }
        return solve(size)
    }

    private func solve(_ size: NSSize) -> PanePlacement {
        let held = self.held
        let panes = self.panes
        return layout.placement(
            in: SplitSize(width: Double(size.width), height: Double(size.height)),
            scale: Double(view.window?.backingScaleFactor ?? 2)
        ) { id in
            let kind = panes[id]?.paneKind(held: held[id] != nil) ?? .empty
            return PaneSizing.layoutMinimum(kind: kind)
        }
    }

    /// Every shell at its rectangle, every divider over its seam, the strip when something is
    /// hidden. A frame is set only when it changed, and a pane out of the placement is hidden,
    /// never moved out of the tree.
    private func place(in bounds: NSRect) {
        let started = CACurrentMediaTime()
        defer { lastLayoutCost = CACurrentMediaTime() - started }
        guard bounds.width > 0, bounds.height > 0 else { return }
        let placement = solve(bounds.size)
        self.placement = placement
        for id in layout.paneIDs {
            guard let shell = shells[id] else { continue }
            guard let rect = placement.frames[id] else {
                if !shell.isHidden { shell.isHidden = true }
                continue
            }
            let frame = NSRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
            if shell.frame != frame { shell.frame = frame }
            if shell.isHidden { shell.isHidden = false }
        }
        placeDividers(placement)
        placeStrip(placement)
        if placement.hidden != lastHidden || densityGeometryChanged(placement) {
            lastHidden = placement.hidden
            scheduleReconcile()
        }
    }

    private func placeDividers(_ placement: PanePlacement) {
        var seen: Set<SplitID> = []
        let order = layout.paneIDs
        for divider in placement.dividers {
            seen.insert(divider.id)
            let view = dividers[divider.id] ?? makeDivider(divider)
            let (first, second) = adjacentPanes(divider.id)
            let label = Localized.text(
                "Divider between pane %@ and pane %@",
                "\((first.flatMap { order.firstIndex(of: $0) } ?? 0) + 1)",
                "\((second.flatMap { order.firstIndex(of: $0) } ?? 1) + 1)")
            view.update(divider, label: label)
            if view.isHidden { view.isHidden = false }
        }
        for (id, view) in dividers where !seen.contains(id) {
            view.removeFromSuperview()
            dividers[id] = nil
        }
    }

    private func makeDivider(_ placement: DividerPlacement) -> TileDividerView {
        let view = TileDividerView(placement: placement)
        view.onDrag = { [weak self] id, position in self?.drag(id, to: position) }
        view.onDragEnded = { [weak self] _, moved in
            guard let self, moved else { return }
            self.ratioCaptures += 1
            self.schedulePersist()
        }
        view.onEqualize = { [weak self] in self?.equalize() }
        view.onStep = { [weak self] id, delta in
            guard let self, let divider = self.placement?.divider(id) else { return }
            self.drag(id, to: divider.position + delta)
            self.ratioCaptures += 1
            self.schedulePersist()
        }
        canvas.addDivider(view)
        dividers[placement.id] = view
        return view
    }

    /// The pane that ends at a seam and the pane that starts after it, in reading order.
    private func adjacentPanes(_ split: SplitID) -> (PaneID?, PaneID?) {
        func find(_ node: SplitNode) -> (PaneID?, PaneID?)? {
            guard case .split(let id, _, _, let first, let second) = node else { return nil }
            if id == split { return (Self.leaves(first).last, Self.leaves(second).first) }
            return find(first) ?? find(second)
        }
        return find(layout.root) ?? (nil, nil)
    }

    private static func leaves(_ node: SplitNode) -> [PaneID] {
        switch node {
        case .pane(let id): return [id]
        case .split(_, _, _, let first, let second): return leaves(first) + leaves(second)
        }
    }

    /// A divider step from the pointer: Core clamps it, the canvas lays out live.
    func drag(_ split: SplitID, to position: Double) {
        guard let placement else { return }
        let started = CACurrentMediaTime()
        guard layout.drag(split, to: position, in: placement) else { return }
        canvas.needsLayout = true
        canvas.layoutSubtreeIfNeeded()
        lastDragCost = CACurrentMediaTime() - started
    }

    private func placeStrip(_ placement: PanePlacement) {
        guard let rect = placement.strip else {
            if !strip.isHidden { strip.isHidden = true }
            return
        }
        let frame = NSRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
        if strip.frame != frame { strip.frame = frame }
        strip.isHidden = false
        strip.show(placement.hidden.map(chip(for:)))
    }

    private func chip(for id: PaneID) -> OverflowStripView.Chip {
        let face = describe(id)
        return OverflowStripView.Chip(
            id: id, title: face.title, activity: face.activity,
            needsYou: face.activity == .needsApproval || face.activity == .needsAnswer)
    }

    /// The name and the face a pane is known by right now, from whatever it already holds: the
    /// stream it is showing, the last glance it read, or the chat list's listing.
    private func describe(_ id: PaneID) -> (title: String, activity: ActivityKind?) {
        guard let pane = panes[id] else { return (Localized.text("No conversation"), nil) }
        if let page = pane.webSummary { return (page, nil) }
        #if !TAILSCODE_MAS
            if let video = pane.videoSummary { return (video, nil) }
        #endif
        if let entry = pane.currentEntry {
            let title =
                entry.session.hasPlaceholderTitle
                ? Localized.text("New conversation") : entry.session.title
            let activity: ActivityKind?
            if let reading = readings[id], shells[id]?.face != .full {
                activity = reading.reading.activity
            } else if let state = pane.currentState {
                activity = ActivityKind.inFlight(in: state)
            } else {
                activity = listFace?(
                    SplitPaneSession(profileID: entry.profileID, sessionID: entry.session.id))?
                    .activity
            }
            return (title, activity)
        }
        if let session = held[id] ?? heldSessions?()[id], let listed = listFace?(session) {
            return listed
        }
        return (Localized.text("No conversation"), nil)
    }

    private func densityGeometryChanged(_ placement: PanePlacement) -> Bool {
        for (id, rect) in placement.frames {
            guard let pane = panes[id], pane.paneKind(held: held[id] != nil) == .chat else {
                continue
            }
            let was = sizeAllowsFull[id] ?? true
            if PaneSizing.allowsFull(width: rect.width, height: rect.height, wasFull: was) != was {
                return true
            }
        }
        return false
    }

    /// Density changes found during a layout pass are applied after it, so the pass never shows or
    /// hides views mid-flight.
    private func scheduleReconcile() {
        guard !reconcileScheduled else { return }
        reconcileScheduled = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.reconcileScheduled = false
                self.reconcile()
                self.applyFocusStyling()
            }
        }
    }

    /// The face every pane should wear now: hidden panes park with nothing; a paused or held chat
    /// wears the paused face; a chat too small to read whole is a glance; the focused chat is
    /// whole; the rest take the governor's word, capped at its full budget with pinned panes and
    /// the most recently touched first, so focusing a glance makes it whole at once and the
    /// longest-untouched whole peer is the one that steps down.
    func reconcile() {
        guard let placement else { return }
        let focusedID = layout.focusedPane
        let now = CACurrentMediaTime()
        var faces: [PaneID: TileShellView.Face] = [:]
        var hidden: Set<PaneID> = []
        var contenders: [PaneID] = []
        var focusedFull = false
        for id in layout.paneIDs {
            guard let pane = panes[id] else { continue }
            guard let rect = placement.frames[id], !occluded else {
                hidden.insert(id)
                continue
            }
            let kind = pane.paneKind(held: held[id] != nil)
            if held[id] != nil || (userParked.contains(id) && kind == .chat) {
                faces[id] = .paused
                continue
            }
            guard kind == .chat else {
                faces[id] = .full
                continue
            }
            let fits = PaneSizing.allowsFull(
                width: rect.width, height: rect.height, wasFull: sizeAllowsFull[id] ?? true)
            sizeAllowsFull[id] = fits
            guard fits else {
                faces[id] = .glance
                continue
            }
            if id == focusedID {
                let holding = (promotionHold[id] ?? 0) > now
                faces[id] = holding ? .glance : .full
                focusedFull = !holding
                continue
            }
            if decision.map({ $0.densities[id] == .glance }) ?? false {
                faces[id] = .glance
            } else {
                contenders.append(id)
            }
        }
        let budget = decision?.fullBudget ?? Int.max
        var remaining = budget == Int.max ? Int.max : max(0, budget - (focusedFull ? 1 : 0))
        let honourPins = !(decision?.level.overridesPreference ?? false)
        let recent = layout.recentlyFocused
        let ranked = contenders.sorted { lhs, rhs in
            if honourPins, pinned.contains(lhs) != pinned.contains(rhs) {
                return pinned.contains(lhs)
            }
            return (recent.firstIndex(of: lhs) ?? .max) < (recent.firstIndex(of: rhs) ?? .max)
        }
        for id in ranked {
            if remaining > 0 {
                faces[id] = .full
                if remaining != .max { remaining -= 1 }
            } else {
                faces[id] = .glance
            }
        }
        for id in layout.paneIDs {
            if hidden.contains(id) {
                park(id)
            } else if let face = faces[id] {
                wear(face, id: id)
            }
        }
        speakPanes()
    }

    /// Out of sight: no stream, no clock, no glance; the rows stay for an instant unzoom.
    private func park(_ id: PaneID) {
        feeds.removeValue(forKey: id)?.cancel()
        shells[id]?.glance.stopClock()
        panes[id]?.setParked(true)
        panes[id]?.setLiveResize(false)
    }

    private func wear(_ face: TileShellView.Face, id: PaneID) {
        guard let pane = panes[id], let shell = shells[id] else { return }
        switch face {
        case .full:
            feeds.removeValue(forKey: id)?.cancel()
            releases.removeValue(forKey: id)?.invalidate()
            shell.show(.full)
            pane.setRowWindow(decision?.rowWindows[id])
            pane.setParked(false)
        case .glance:
            pane.setParked(true)
            let fresh = !shell.hasGlance
            shell.show(.glance)
            if fresh { wireGlance(shell.glance, id: id) }
            startFeed(id)
            renderGlance(id)
            scheduleRelease(id)
        case .paused:
            feeds.removeValue(forKey: id)?.cancel()
            pane.setParked(true)
            let fresh = shell.face != .paused
            shell.show(.paused)
            if fresh { shell.paused.onResume = { [weak self] in self?.resume(id) } }
            renderPaused(id)
            scheduleRelease(id)
        }
    }

    private func resume(_ id: PaneID) {
        if userParked.remove(id) != nil {
            reconcile()
            applyFocusStyling()
            return
        }
        onResume?(id)
    }

    /// A demoted pane keeps its rows for twenty seconds, so a glance pressed again comes back as it
    /// was; after that the rows go, and coming back rebuilds the tail.
    private func scheduleRelease(_ id: PaneID) {
        guard releases[id] == nil else { return }
        let timer = Timer(timeInterval: demotedKeep, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.releases[id] = nil
                guard let shell = self.shells[id], shell.face != .full else { return }
                self.panes[id]?.releaseRows()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        releases[id] = timer
    }

    /// A glance's own hold on the chat, at the level's glance rate, with the newest state the hub
    /// already has drawn at once.
    private func startFeed(_ id: PaneID) {
        guard feeds[id] == nil, let pane = panes[id], let entry = pane.currentEntry,
            let backend = pane.currentBackend
        else { return }
        let interval = decision?.animation.glanceInterval ?? (1.0 / 4)
        let feed = GlanceFeed(entry: entry, backend: backend, interval: interval) {
            [weak self] state in
            self?.noteState(state, for: id)
        }
        feeds[id] = feed
        if let state = feed.latest ?? pane.currentState { noteState(state, for: id) }
    }

    private func noteState(_ state: ConversationState, for id: PaneID) {
        let queued = panes[id]?.queuedCount ?? 0
        readings[id] = (GlanceReading(state: state, queued: queued), Date())
        renderGlance(id)
    }

    private func renderGlance(_ id: PaneID) {
        guard let shell = shells[id], shell.face == .glance, let pane = panes[id] else { return }
        let order = layout.paneIDs
        let title = describe(id).title
        if readings[id] == nil, let state = pane.currentState {
            readings[id] = (GlanceReading(state: state, queued: pane.queuedCount), Date())
        }
        shell.glance.render(
            title: title, reading: readings[id]?.reading, pinned: pinned.contains(id),
            index: (order.firstIndex(of: id) ?? 0) + 1, of: order.count)
    }

    private func renderPaused(_ id: PaneID) {
        guard let shell = shells[id] else { return }
        let order = layout.paneIDs
        let face = describe(id)
        var kept = readings[id]
        if let at = kept?.at, Date().timeIntervalSince(at) > Self.readingKeep {
            readings[id] = nil
            kept = nil
        }
        let detail: String? =
            held[id] != nil
            ? Localized.text("Tailscode didn't close normally last time, so this chat waits.")
            : nil
        shell.paused.render(
            title: face.title, activity: face.activity, lastWords: kept?.reading.tail,
            readAt: kept?.at, detail: detail, index: (order.firstIndex(of: id) ?? 0) + 1,
            of: order.count)
    }

    func applyGovernor(_ decision: GovernorDecision) {
        let previous = self.decision
        self.decision = decision
        let interval = decision.animation.glanceInterval
        for (id, feed) in feeds {
            feed.setInterval(interval)
            if !interval.isFinite, let state = feed.latest,
                let activity = ActivityKind.inFlight(in: state),
                activity == .needsApproval || activity == .needsAnswer,
                readings[id]?.reading.activity != activity
            {
                noteState(state, for: id)
            }
        }
        guard previous?.densities != decision.densities || previous?.fullBudget != decision.fullBudget
            || previous?.rowWindows != decision.rowWindows || previous?.level != decision.level
        else { return }
        reconcile()
        applyFocusStyling()
    }

    func setOccluded(_ occluded: Bool) {
        guard occluded != self.occluded else { return }
        self.occluded = occluded
        if !occluded, var decision {
            decision.densities = decision.densities.filter { $0.value != .parked }
            self.decision = decision
        }
        reconcile()
    }

    func setHeld(_ held: [PaneID: SplitPaneSession]) {
        guard held != self.held else { return }
        self.held = held
        reconcile()
        applyFocusStyling()
    }

    /// The window's live resize: every pane takes its new frame at once, but only the focused pane
    /// re-measures its rows on each step; the others hold their rows' width until the resize ends
    /// and then catch up one pane per frame. Glance and paused faces are cheap and never wait.
    private func liveResize(_ live: Bool) {
        liveResizing = live
        if live {
            deferredPeers = layout.paneIDs.filter { id in
                id != layout.focusedPane && shells[id]?.face == .full
                    && !(shells[id]?.isHidden ?? true)
            }
            for id in deferredPeers { panes[id]?.setLiveResize(true) }
        } else {
            releaseDeferred()
        }
    }

    private func releaseDeferred() {
        guard !liveResizing, !deferredPeers.isEmpty else { return }
        let id = deferredPeers.removeFirst()
        panes[id]?.setLiveResize(false)
        guard !deferredPeers.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { [weak self] in
            MainActor.assumeIsolated { self?.releaseDeferred() }
        }
    }

    /// The bench's way of starting and ending a live resize without a pointer on a window edge.
    func simulateLiveResize(_ live: Bool) {
        liveResize(live)
        if !live {
            while !deferredPeers.isEmpty { releaseDeferred() }
        }
    }

    /// The focused pane's accent hairline, the identity strips, and what each pane says about
    /// itself: its pin and which other pane shows the same chat.
    func applyFocusStyling() {
        let several = layout.paneCount > 1
        let order = layout.paneIDs
        var showing: [String: [PaneID]] = [:]
        for id in order {
            guard let entry = panes[id]?.currentEntry else { continue }
            showing[SessionPinStore.key(entry.profileID, entry.session.id), default: []].append(id)
        }
        for id in order {
            guard let pane = panes[id], let shell = shells[id] else { continue }
            let focused = id == layout.focusedPane
            pane.setFocusedPane(focused)
            shell.setFocusRing(focused: focused, shown: several)
            pane.setIdentityVisible(several)
            var other: Int?
            if let entry = pane.currentEntry,
                let twins = showing[SessionPinStore.key(entry.profileID, entry.session.id)],
                let twin = twins.first(where: { $0 != id }),
                let index = order.firstIndex(of: twin)
            {
                other = index + 1
            }
            pane.setIdentityExtras(pinned: pinned.contains(id), alsoOpenIn: other)
        }
        speakPanes()
    }

    /// "Pane 2 of 5, <title>, <activity>" on every shell, in reading order.
    private func speakPanes() {
        let order = layout.paneIDs
        for (index, id) in order.enumerated() {
            guard let shell = shells[id] else { continue }
            let face = describe(id)
            var parts = [Localized.text("Pane %@ of %@", "\(index + 1)", "\(order.count)"), face.title]
            if let activity = face.activity { parts.append(activity.spoken) }
            shell.setAccessibilityLabel(parts.joined(separator: ", "))
        }
    }

    func seatbeltPanes(held: [PaneID: SplitPaneSession]) -> SeatbeltPanes {
        var seen = SeatbeltPanes()
        let placement = self.placement
        for id in layout.paneIDs {
            guard let pane = panes[id] else { continue }
            let rect = placement?.frames[id]
            let paused = userParked.contains(id) || held[id] != nil
            let placed = rect != nil && !paused
            seen.facts.append(
                PaneFacts(
                    id: id, kind: pane.paneKind(held: held[id] != nil),
                    focused: id == layout.focusedPane, placed: placed,
                    width: rect?.width ?? 0, height: rect?.height ?? 0,
                    attention: attention(id), pinned: pinned.contains(id)))
            if rect == nil {
                seen.hidden += 1
            } else if paused {
                seen.parked += 1
            } else if shells[id]?.face == .glance {
                seen.glance += 1
            } else {
                seen.live += 1
            }
        }
        seen.occluded = occluded
        return seen
    }

    private func attention(_ id: PaneID) -> PaneAttention {
        let activity: ActivityKind?
        if let shell = shells[id], shell.face != .full, let reading = readings[id] {
            activity = reading.reading.activity
        } else if let state = panes[id]?.currentState {
            activity = ActivityKind.inFlight(in: state)
        } else {
            activity = nil
        }
        switch activity {
        case .needsApproval, .needsAnswer: return .needsYou
        case .failed: return .failed
        case nil, .offline, .queued: return .quiet
        default: return .running
        }
    }

    /// What the live chip says: how many chats are whole out of how many there are.
    var liveCounts: (live: Int, chats: Int) {
        var live = 0
        var chats = 0
        for id in layout.paneIDs {
            guard let pane = panes[id], pane.paneKind(held: held[id] != nil) == .chat else {
                continue
            }
            chats += 1
            if let shell = shells[id], !shell.isHidden, shell.face == .full { live += 1 }
        }
        return (live, chats)
    }

    private func zoneUnderPointer(_ sender: NSDraggingInfo, over id: PaneID) -> PaneDropZone? {
        guard let shell = shells[id] else { return nil }
        let local = shell.convert(sender.draggingLocation, from: nil)
        let bounds = shell.bounds
        return PaneDropTarget.zone(
            x: Double(local.x), y: Double(local.y), width: Double(bounds.width),
            height: Double(bounds.height))
    }

    private func dragUpdated(_ sender: NSDraggingInfo, over id: PaneID) -> Bool {
        guard let shell = shells[id], let zone = zoneUnderPointer(sender, over: id) else {
            return false
        }
        let title = payload(from: sender).flatMap { chatTitleForDrop?($0) }
        let rect = PaneDropTarget.highlight(
            for: zone, width: Double(shell.frame.width), height: Double(shell.frame.height))
        dropHighlight.show(
            frame: NSRect(
                x: shell.frame.minX + rect.x, y: shell.frame.minY + rect.y, width: rect.width,
                height: rect.height),
            caption: zone.caption(title))
        dropZone = (id, zone)
        return true
    }

    func clearDropHighlight() {
        dropZone = nil
        dropHighlight.clear()
    }

    private func receiveDrop(_ sender: NSDraggingInfo, on id: PaneID) -> Bool {
        clearDropHighlight()
        guard let pane = panes[id], let payload = payload(from: sender),
            let zone = zoneUnderPointer(sender, over: id)
        else { return false }
        return onChatDropped?(pane, payload, zone) ?? false
    }

    private func payload(from sender: NSDraggingInfo) -> PaneDragPayload? {
        guard let text = sender.draggingPasteboard.string(forType: .tailscodeChat) else { return nil }
        return PaneDragPayload.decode(text)
    }

    /// Checks and the bench read these.
    var dividerViews: [SplitID: TileDividerView] { dividers }
    var stripView: OverflowStripView { strip }
    func face(of id: PaneID) -> TileShellView.Face? { shells[id]?.face }
    func feedCount() -> Int { feeds.count }
}

/// A glance tile's hold on a chat: a `.glance` lease on the hub's one conversation and a slot in
/// the frame's drain at the shed level's glance rate, so a peer that changes every token is drawn
/// a few times a second at most and a frozen level draws nothing until it is asked.
@MainActor
final class GlanceFeed {
    let key: LiveKey
    private let lease: LiveLease
    private var token: DrainToken?
    private let slotID = PaneID()
    private var interval: TimeInterval
    private let onFrame: (ConversationState) -> Void
    private(set) var applied = 0

    init(
        entry: SessionEntry, backend: any CodingAgentBackend, interval: TimeInterval,
        onFrame: @escaping (ConversationState) -> Void
    ) {
        key = TileRuntime.key(entry)
        let runtime = TileRuntime.shared
        let drain = runtime.drain
        lease = runtime.lease(entry, backend: backend, interest: .glance) { drain.wake() }.0
        self.interval = interval
        self.onFrame = onFrame
        token = drain.register(slot())
    }

    /// A frozen level has no rate at all; the drain is given an hour rather than infinity, and the
    /// one-second governor pass wakes a frozen tile itself when its turn starts waiting on someone.
    private static func drainInterval(_ interval: TimeInterval) -> TimeInterval {
        interval.isFinite ? interval : 3600
    }

    private func slot() -> DrainSlot {
        let lease = self.lease
        return DrainSlot(
            pane: slotID, priority: .glance, minInterval: Self.drainInterval(interval),
            hasWork: { lease.hasFrame },
            apply: { [weak self] in MainActor.assumeIsolated { self?.applyNewest() } })
    }

    private func applyNewest() {
        guard let frame = lease.take() else { return }
        applied += 1
        onFrame(frame.state)
    }

    func setInterval(_ next: TimeInterval) {
        guard next != interval else { return }
        interval = next
        if let token { TileRuntime.shared.drain.update(token, to: slot()) }
    }

    /// The newest state the hub holds for the chat, whatever the rate.
    var latest: ConversationState? { TileRuntime.shared.hub.latest(key)?.state }

    func cancel() {
        token?.cancel()
        token = nil
        lease.cancel()
    }
}
