import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// The tiling tree on Linux, drawn as one flat canvas.
///
/// `SplitLayout` decides the arrangement and Core's placement turns it into rectangles for the
/// size the canvas has; the canvas's solver — which is this host's `solve`, called inside its
/// allocation — gives every pane's shell its rectangle, every divider its band over a seam, and the
/// overflow strip the row under the panes the window cannot show. Nothing is nested and nothing is
/// re-parented: a split adds one shell, a close removes one, and every other verb — exchange,
/// rotate, promote, arrange, zoom, a window too small for every pane — is a different answer from
/// the solver, and a pane it does not place is hidden, not moved. The ratio a divider holds is
/// written only when a person drags or nudges it, never read back from what a layout produced.
///
/// Each chat also has a density. The focused chat is whole; the governor's one-second decision says
/// which others stay whole and which become glance tiles, a chat too small to be read whole is a
/// glance whatever the governor says, and a pane out of sight — zoomed away, overflowed — owns no
/// stream and no clock. A pane demoted to a glance lets go of its row widgets twenty seconds
/// later, and coming back refills the tail.
final class TileHost: PaneTiling, @unchecked Sendable {
    let container: UnsafeMutablePointer<GtkWidget> = gtk_overlay_new()!
    private(set) var layout = SplitLayout()
    private(set) var panes: [PaneID: ChatPane] = [:]
    private(set) var shells: [PaneID: TileShell] = [:]
    private var dividers: [SplitID: TileDivider] = [:]
    private(set) var canvas: TileCanvas!
    let strip = OverflowStrip()
    private let dropHighlight = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    private let dropCaption = Gtk.label("", css: "drop-caption", selectable: false)
    private let ghost = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    private(set) var placement: PanePlacement?
    private weak var host: MainWindow?

    private var dropZone: (pane: PaneID, zone: PaneDropZone)?
    private var dropRect: TileRect?
    private var ghostRect: TileRect?
    private var pinned: Set<PaneID> = []
    private var userParked: Set<PaneID> = []
    private var held: [PaneID: SplitPaneSession] = [:]
    private var decision: GovernorDecision?
    private var sizeAllowsFull: [PaneID: Bool] = [:]
    private var feeds: [PaneID: GlanceFeed] = [:]
    private var releaseTokens: [PaneID: Int] = [:]
    private var promotionHold: [PaneID: TimeInterval] = [:]
    private var readings: [PaneID: (reading: GlanceReading, at: Date)] = [:]
    private var reliefToken: MemoryReliefToken?
    private var reconcileScheduled = false
    private var lastHidden: [PaneID] = []
    private var lastRects: [PaneID: TileRect] = [:]
    private var dividersStale = false
    private var reconciledKinds: [PaneID: PaneKind] = [:]
    private var drag: DividerDrag?
    private(set) var persistRequests = 0
    private(set) var ratioWrites = 0
    private(set) var lastDragMilliseconds = 0.0

    /// How long a demoted pane keeps its rows before letting them go, and how long a glance's last
    /// words are kept for the paused face.
    var demotedKeep: TimeInterval = 20
    static let readingKeep: TimeInterval = 600

    /// What the window listens for: the counts the live chip draws changed.
    var onDensityChanged: (() -> Void)?
    var listFace: ((SplitPaneSession) -> (title: String, activity: ActivityKind?)?)?

    private struct DividerDrag {
        let id: SplitID
        let axis: SplitAxis
        let startPosition: Double
        let startPointer: Double
        var ghosting: Bool
        var slowSteps = 0
        var lastTarget: Double
        var moved = false
    }

    /// The step cost past which a divider drag stops moving the panes under the pointer and moves
    /// a line instead, committing once on release.
    static let liveDragLimit = 8.0

    init(host: MainWindow) {
        self.host = host
        gtk_widget_set_hexpand(container, 1)
        gtk_widget_set_vexpand(container, 1)
        canvas = TileCanvas { [weak self] width, height, sink in
            self?.solve(width: width, height: height, sink: sink)
        }
        gtk_overlay_set_child(op(container), canvas.widget)
        buildOverlays()
        let pane = makePane(layout.focusedPane)
        adopt(pane, as: layout.focusedPane)
        Seatbelts.shared.onDecision = { [weak self] decision in self?.applyGovernor(decision) }
        reliefToken = MemoryRelief.shared.register(name: "glance readings") { [weak self] depth in
            Gtk.onMain { [weak self] in self?.relieve(depth) }
        }
        scheduleReconcile()
    }

    deinit {
        reliefToken?.cancel()
    }

    private func buildOverlays() {
        strip.onPress = { [weak self] id in self?.reveal(id) }
        canvas.add(strip.widget, layer: .overlays)
        Gtk.addClass(dropHighlight, "drop-zone")
        gtk_widget_set_can_target(dropHighlight, 0)
        gtk_label_set_max_width_chars(op(dropCaption), 18)
        gtk_label_set_xalign(op(dropCaption), 0.5)
        gtk_widget_set_halign(dropCaption, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(dropCaption, GTK_ALIGN_CENTER)
        gtk_widget_set_vexpand(dropCaption, 1)
        gtk_box_append(ptr(dropHighlight), dropCaption)
        canvas.add(dropHighlight, layer: .overlays)
        Gtk.addClass(ghost, "tile-ghost")
        gtk_widget_set_can_target(ghost, 0)
        canvas.add(ghost, layer: .overlays)
    }

    private func relieve(_ depth: ReliefDepth) {
        if depth == .all {
            readings = readings.filter { feeds[$0.key] != nil }
        } else {
            let cutoff = Date().addingTimeInterval(-Self.readingKeep / 2)
            readings = readings.filter { $0.value.at > cutoff }
        }
    }

    var activePane: ChatPane { panes[layout.focusedPane] ?? panes.values.first! }
    var paneCount: Int { layout.paneCount }
    var orderedPanes: [ChatPane] { layout.paneIDs.compactMap { panes[$0] } }

    func pane(showing sessionID: String) -> ChatPane? {
        orderedPanes.first { $0.sessionID == sessionID }
    }

    func eachPane(_ body: (ChatPane) -> Void) {
        for pane in orderedPanes { body(pane) }
    }

    private func makePane(_ id: PaneID) -> ChatPane {
        Trace.mark("makePane begin")
        defer { Trace.mark("makePane end") }
        return ChatPane(id: id, host: host!)
    }

    /// A pane joins the canvas: its shell is made and added once, and the conversation goes in it
    /// for good. Every pane is a place a dragged chat or pane can land, so it is never built
    /// without its drop targets — including the ones a restore or a drop itself mints.
    private func adopt(_ pane: ChatPane, as id: PaneID) {
        panes[id] = pane
        let shell = TileShell(id: id, body: pane.root)
        shell.setResume { [weak self] in Gtk.onMain { [weak self] in self?.resume(id) } }
        shells[id] = shell
        pane.outer = shell.widget
        Gtk.acceptChatDrops(
            on: shell.widget,
            motion: { [weak self] payload, x, y in
                self?.dragMoved(over: id, payload: payload, x: x, y: y)
            },
            leave: { [weak self] in self?.clearDropHighlight() },
            drop: { [weak self] payload, x, y in
                self?.receiveDrop(payload, on: id, x: x, y: y) ?? false
            })
        Gtk.acceptPaneDrops(
            on: shell.widget,
            motion: { [weak self] payload, x, y in
                self?.paneDragMoved(over: id, payload: payload, x: x, y: y)
            },
            leave: { [weak self] in self?.clearDropHighlight() },
            drop: { [weak self] payload, x, y in
                self?.receivePaneDrop(payload, on: id, x: x, y: y) ?? false
            })
        canvas.add(shell.widget, layer: .panes)
    }

    /// A pane leaves the canvas: its stream and clocks first, then its glance and timers, then the
    /// shell. The only removal a pane ever sees.
    private func retire(_ id: PaneID) {
        feeds.removeValue(forKey: id)?.cancel()
        releaseTokens[id] = nil
        promotionHold[id] = nil
        readings[id] = nil
        sizeAllowsFull[id] = nil
        lastRects[id] = nil
        pinned.remove(id)
        userParked.remove(id)
        if let pane = panes.removeValue(forKey: id) {
            pane.shutdown()
            pane.outer = nil
        }
        if let shell = shells.removeValue(forKey: id) {
            shell.shutdown()
            canvas.remove(shell.widget)
        }
    }

    func splitActive(axis: SplitAxis) {
        guard let host else { return }
        let source = activePane.entry?.profileID
        guard hasRoom(layout.focusedPane, axis: axis),
            let freshID = layout.split(layout.focusedPane, axis: axis)
        else { return }
        let pane = makePane(freshID)
        adopt(pane, as: freshID)
        relayout()
        host.presentChooser(in: pane, preferring: source)
        pane.focusTranscript()
        host.focusedPaneChanged()
        persist()
    }

    @discardableResult
    func split(_ pane: ChatPane, edge: PaneDropEdge) -> ChatPane? {
        guard hasRoom(pane.id, axis: edge.axis),
            let freshID = layout.split(
                pane.id, axis: edge.axis, placingNewFirst: edge.placesArrivalFirst)
        else { return nil }
        let fresh = makePane(freshID)
        adopt(fresh, as: freshID)
        relayout()
        host?.focusedPaneChanged()
        persist()
        return fresh
    }

    private func hasRoom(_ id: PaneID, axis: SplitAxis) -> Bool {
        guard let placement = currentPlacement() else { return true }
        guard layout.canSplit(id, axis: axis, in: placement) else {
            host?.toast(Localized.text("No room for another split here"))
            return false
        }
        return true
    }

    func collapse(to keep: ChatPane) {
        guard layout.contains(keep.id) else { return }
        for id in layout.paneIDs where id != keep.id {
            guard layout.close(id) != nil else { continue }
            retire(id)
        }
        layout.focus(keep.id)
        relayout()
        host?.focusedPaneChanged()
        persist()
    }

    func closeActive() {
        close(layout.focusedPane)
    }

    private func close(_ id: PaneID) {
        guard layout.close(id) != nil else { return }
        retire(id)
        relayout()
        host?.focusedPaneChanged()
        persist()
    }

    @discardableResult
    func focusNeighbor(_ direction: SplitDirection) -> Bool {
        let wasZoomed = layout.zoomedPane != nil
        let moved = layout.focusNeighbor(direction)
        guard moved || wasZoomed else { return false }
        relayout()
        if moved { activePane.focusTranscript() }
        host?.focusedPaneChanged()
        persist()
        return moved
    }

    func zoomActive() {
        zoom(layout.focusedPane)
    }

    private func zoom(_ id: PaneID) {
        layout.toggleZoom(id)
        relayout()
        host?.focusedPaneChanged()
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

    /// The registered pane chords that act on the tree itself — arrange, promote, rotate, move to
    /// an edge, resize, cycle — through Core's one dispatcher, so this desktop and the Mac cannot
    /// mean different things by the same key. A chord with nothing to do (one pane has nothing to
    /// rotate) is still the tree's, and is spent rather than handed on.
    @discardableResult
    func perform(_ action: KeyAction) -> Bool {
        guard let placement = currentPlacement(),
            let effect = layout.perform(action, placement: placement)
        else { return true }
        if case .resizeSplit = action { ratioWrites += 1 }
        relayout()
        if effect == .refocused { activePane.focusTranscript() }
        host?.focusedPaneChanged()
        persist()
        return true
    }

    /// Rebuilds the tree as the arrangement a menu row named; the focused pane leads, so main and
    /// stack puts it in the main slot.
    func arrange(_ arrangement: SplitArrangement) {
        guard layout.paneCount > 1,
            layout.arrange(arrangement, order: [layout.focusedPane])
        else { return }
        relayout()
        host?.focusedPaneChanged()
        persist()
    }

    var supportsDensity: Bool { true }

    func togglePinActive() { togglePin(layout.focusedPane) }
    func toggleParkActive() { togglePark(layout.focusedPane) }

    var activeIsPinned: Bool { pinned.contains(layout.focusedPane) }
    var activeIsParked: Bool { userParked.contains(layout.focusedPane) }

    /// Keep live: the governor gives this pane a full slot before any other peer while the level
    /// allows preference at all. At strained and above the pin is held but ignored, and the chip
    /// says so.
    func togglePin(_ id: PaneID) {
        guard layout.contains(id) else { return }
        if pinned.remove(id) == nil { pinned.insert(id) }
        if pinned.contains(id) { userParked.remove(id) }
        reconcile()
        applyFocusStyling()
        persist()
    }

    /// Pause: the pane lets go of its stream and its clocks and wears the paused face until Resume.
    /// Only a conversation can be paused; a page or a stream is not a chat.
    func togglePark(_ id: PaneID) {
        guard let pane = panes[id], pane.paneKind(held: held[id] != nil) == .chat else { return }
        if userParked.remove(id) == nil {
            userParked.insert(id)
            pinned.remove(id)
        }
        reconcile()
        applyFocusStyling()
        persist()
    }

    /// Resume is the person's: a pane they paused comes back whole, a pane a safe restore holds is
    /// handed to the window to wake.
    func resume(_ id: PaneID) {
        if userParked.remove(id) != nil {
            reconcile()
            applyFocusStyling()
            return
        }
        host?.resumeRestored(id)
    }

    func openFullPane(_ id: PaneID) { openFull(id) }

    func focusPane(_ id: PaneID) {
        guard let pane = panes[id] else { return }
        focus(pane, grabKeyboard: true)
    }

    func activePinned(_ id: PaneID) -> Bool { pinned.contains(id) }

    func feedExists(_ id: PaneID) -> Bool { feeds[id] != nil }

    var canvasChildCount: Int { canvas.childCount }
    var canvasAllocations: Int { canvas.allocations }
    var canvasLastMilliseconds: Double { canvas.lastAllocateMilliseconds }

    private func openFull(_ id: PaneID) {
        guard let pane = panes[id] else { return }
        promotionHold[id] = nil
        if layout.focusedPane != id {
            focus(pane, grabKeyboard: true)
        } else {
            reconcile()
        }
    }

    func setHeld(_ held: [PaneID: SplitPaneSession]) {
        guard held != self.held else { return }
        self.held = held
        reconcile()
        applyFocusStyling()
    }

    private func currentPlacement() -> PanePlacement? {
        let size = canvas.size
        guard size.width > 0, size.height > 0 else { return placement }
        return solvePlacement(size)
    }

    private func solvePlacement(_ size: SplitSize) -> PanePlacement {
        let panes = self.panes
        let held = self.held
        return layout.placement(in: size) { id in
            PaneSizing.layoutMinimum(kind: panes[id]?.paneKind(held: held[id] != nil) ?? .empty)
        }
    }

    /// The canvas's allocation, asking where everything goes. Nothing here creates or destroys a
    /// widget: whatever the solve finds out of date — a divider with no band, a density the new
    /// geometry changes — is settled on the next idle, outside the allocation.
    private func solve(width: Int32, height: Int32, sink: TileSink) {
        guard width > 0, height > 0 else { return }
        let placement = solvePlacement(SplitSize(width: Double(width), height: Double(height)))
        self.placement = placement
        var rects: [PaneID: TileRect] = [:]
        for (id, frame) in placement.frames {
            guard let shell = shells[id] else { continue }
            let rect = TileRect(frame)
            rects[id] = rect
            sink.place(shell.widget, rect)
        }
        for divider in placement.dividers {
            if let view = dividers[divider.id] {
                sink.place(view.widget, TileRect(divider.hit))
            } else {
                dividersStale = true
            }
        }
        if dividers.count > placement.dividers.count { dividersStale = true }
        if let rect = placement.strip { sink.place(strip.widget, TileRect(rect)) }
        if let rect = dropRect { sink.place(dropHighlight, rect) }
        if let rect = ghostRect { sink.place(ghost, rect) }
        if dividersStale || placement.hidden != lastHidden || rects != lastRects
            || densityGeometryChanged(placement)
        {
            lastHidden = placement.hidden
            lastRects = rects
            scheduleReconcile()
        }
    }

    private func syncDividers(_ placement: PanePlacement) {
        var seen: Set<SplitID> = []
        for divider in placement.dividers {
            seen.insert(divider.id)
            let view = dividers[divider.id] ?? makeDivider(divider)
            view.describe(divider, label: dividerLabel(divider.id))
        }
        for (id, view) in dividers where !seen.contains(id) {
            canvas.remove(view.widget)
            dividers[id] = nil
        }
        dividersStale = false
    }

    private func makeDivider(_ placement: DividerPlacement) -> TileDivider {
        let id = placement.id
        let handlers = TileDivider.Handlers(
            began: { [weak self] x, y in self?.beginDrag(id, x: x, y: y) },
            moved: { [weak self] x, y in self?.moveDrag(x: x, y: y) },
            ended: { [weak self] x, y in self?.endDrag(x: x, y: y) },
            equalize: { [weak self] in Gtk.onMain { [weak self] in self?.equalize() } },
            key: { [weak self] key in self?.moveDivider(id, by: key) ?? false })
        let view = TileDivider(id: id, axis: placement.axis, handlers: handlers)
        canvas.add(view.widget, layer: .dividers)
        dividers[id] = view
        return view
    }

    /// The label a divider gives a screen reader: the two panes that meet at it, by their place in
    /// reading order, in the words both desktops use.
    private func dividerLabel(_ split: SplitID) -> String {
        let order = layout.paneIDs
        guard let sides = layout.sides(of: split),
            let first = sides.first.last.flatMap({ order.firstIndex(of: $0) }),
            let second = sides.second.first.flatMap({ order.firstIndex(of: $0) })
        else { return Localized.text("Divider between pane %@ and pane %@", "1", "2") }
        return Localized.text(
            "Divider between pane %@ and pane %@", "\(first + 1)", "\(second + 1)")
    }

    /// A divider dragged without a pointer: where it stood, where Core's clamp left it, and whether
    /// the drag drew a ghost instead of moving the panes. `ghost` forces the mode; nil lets the
    /// measured relayout decide, as a pointer's drag does.
    func simulateDrag(
        _ index: Int, by delta: Double, ghost: Bool? = nil
    ) -> (from: Double, to: Double, ghosted: Bool)? {
        let ids = layout.splitIDs
        guard ids.indices.contains(index), let divider = currentPlacement()?.divider(ids[index])
        else { return nil }
        let id = ids[index]
        let along = divider.axis == .horizontal
        let origin = divider.parent.x + divider.position
        let originY = divider.parent.y + divider.position
        beginDrag(id, x: origin, y: originY)
        if let ghost, var state = drag {
            state.ghosting = ghost
            drag = state
        }
        moveDrag(x: along ? origin + delta : origin, y: along ? originY : originY + delta)
        let ghosted = drag?.ghosting ?? false
        endDrag(x: along ? origin + delta : origin, y: along ? originY : originY + delta)
        refreshPlacement()
        return (divider.position, placement?.divider(id)?.position ?? divider.position, ghosted)
    }

    private func beginDrag(_ id: SplitID, x: Double, y: Double) {
        guard let divider = placement?.divider(id) else { return }
        let pointer = divider.axis == .horizontal ? x : y
        let ghosting = canvas.lastAllocateMilliseconds >= Self.liveDragLimit
        drag = DividerDrag(
            id: id, axis: divider.axis, startPosition: divider.position, startPointer: pointer,
            ghosting: ghosting, lastTarget: divider.position)
    }

    private func moveDrag(x: Double, y: Double) {
        guard var state = drag, let placement else { return }
        let pointer = state.axis == .horizontal ? x : y
        let target = state.startPosition + (pointer - state.startPointer)
        state.moved = state.moved || abs(target - state.startPosition) > 0.5
        state.lastTarget = target
        if !state.ghosting {
            let cost = canvas.lastAllocateMilliseconds
            state.slowSteps = cost >= Self.liveDragLimit ? state.slowSteps + 1 : 0
            if state.slowSteps >= 2 { state.ghosting = true }
            Seatbelts.shared.noteRelayout(cost)
        }
        drag = state
        if state.ghosting {
            showGhost(state, target: target, placement: placement)
        } else {
            commitDrag(state.id, to: target)
        }
    }

    private func endDrag(x: Double?, y: Double?) {
        guard let state = drag else { return }
        drag = nil
        var target = state.lastTarget
        if let pointer = state.axis == .horizontal ? x : y {
            target = state.startPosition + (pointer - state.startPointer)
        }
        if state.ghosting {
            ghostRect = nil
            if state.moved { commitDrag(state.id, to: target) } else { canvas.invalidate() }
        }
        guard state.moved else { return }
        lastDragMilliseconds = canvas.lastAllocateMilliseconds
        Seatbelts.shared.noteRelayout(lastDragMilliseconds)
        ratioWrites += 1
        persist()
    }

    private func commitDrag(_ id: SplitID, to target: Double) {
        guard let placement, layout.drag(id, to: target, in: placement) else { return }
        canvas.invalidate()
    }

    /// The line a ghost drag moves: where Core's clamp would put the divider for this pointer,
    /// drawn across the parent's extent, without moving a pane.
    private func showGhost(_ state: DividerDrag, target: Double, placement: PanePlacement) {
        guard let divider = placement.divider(state.id) else { return }
        let clamped = min(max(target, divider.lowest), divider.highest)
        let parent = divider.parent
        let rect: TileRect
        switch divider.axis {
        case .horizontal:
            rect = TileRect(
                x: Int32((parent.x + clamped).rounded()) - 1, y: Int32(parent.y.rounded()), width: 3,
                height: Int32(parent.height.rounded()))
        case .vertical:
            rect = TileRect(
                x: Int32(parent.x.rounded()), y: Int32((parent.y + clamped).rounded()) - 1,
                width: Int32(parent.width.rounded()), height: 3)
        }
        guard rect != ghostRect else { return }
        ghostRect = rect
        canvas.invalidate()
    }

    /// A key on a focused divider: the same clamped move the pointer makes, from where the divider
    /// actually stands.
    @discardableResult
    func moveDivider(_ split: SplitID, by key: DividerKey) -> Bool {
        guard let placement = currentPlacement() else { return false }
        guard layout.move(split, by: key, in: placement) else { return true }
        ratioWrites += 1
        relayout()
        persist()
        return true
    }

    /// Ratios are intent, written by a drag or a nudge as it happens, so there is nothing to read
    /// back from the widgets and nothing to capture on a timer.
    func captureRatios() {}

    @discardableResult
    func applyRatios() -> Bool {
        relayout()
        return true
    }

    func dividerSummary(_ index: Int) -> String {
        guard let placement = currentPlacement() else { return "-" }
        let ids = layout.splitIDs
        guard ids.indices.contains(index), let divider = placement.divider(ids[index]),
            let view = dividers[ids[index]]
        else { return "-" }
        let label = dividerLabel(ids[index])
        let bounds = Gtk.bounds(of: view.widget, in: canvas.widget) ?? (0, 0, 0, 0)
        return String(
            format: "%d pos=%.0f w=%.0f h=%.0f at=%.0f,%.0f range=%.0f...%.0f %@ \"%@\"", index,
            divider.position, bounds.width, bounds.height, bounds.x, bounds.y, divider.lowest,
            divider.highest, view.reading(divider, label: label), label)
    }

    func driveDivider(_ index: Int, key: DividerKey) -> Bool {
        let ids = layout.splitIDs
        guard ids.indices.contains(index) else { return false }
        dividers[ids[index]]?.focus()
        return moveDivider(ids[index], by: key)
    }

    func handleCenters(in reference: UnsafeMutablePointer<GtkWidget>) -> [(SplitID, Double, Double)]
    {
        var centers: [(SplitID, Double, Double)] = []
        for (id, view) in dividers {
            guard gtk_widget_get_mapped(view.widget) != 0,
                let box = Gtk.bounds(of: view.widget, in: reference)
            else { continue }
            centers.append((id, box.x + box.width / 2, box.y + box.height / 2))
        }
        return centers
    }

    var canvasSummary: String { "\(Int(canvas.size.width))x\(Int(canvas.size.height))" }

    /// The pane a point in `reference`'s coordinates lands in. A divider's band reaches four points
    /// into each neighbour, and a press there is a press on the divider, which activates no pane;
    /// so is a press on the strip, on a pane the layout has hidden, or on the chrome beside the tree.
    func pane(at x: Double, y: Double, in reference: UnsafeMutablePointer<GtkWidget>) -> ChatPane? {
        for view in dividers.values where Gtk.contains(view.widget, x: x, y: y, in: reference) {
            return nil
        }
        if Gtk.contains(strip.widget, x: x, y: y, in: reference) { return nil }
        return orderedPanes.first { pane in
            shells[pane.id].map { Gtk.contains($0.widget, x: x, y: y, in: reference) } ?? false
        }
    }

    /// Focus by intent. A press on a glance tile holds it a glance for one double-click interval so
    /// the second press of a double click lands on the tile it meant.
    func focus(_ pane: ChatPane, grabKeyboard: Bool) {
        let id = pane.id
        guard layout.focusedPane != id else { return }
        if !grabKeyboard, shells[id]?.face == .glance {
            promotionHold[id] = Self.now + Self.doubleClickInterval
            Gtk.after(UInt32(Self.doubleClickInterval * 1000) + 30) { [weak self] in
                self?.promotionHold[id] = nil
                self?.reconcile()
                self?.applyFocusStyling()
            }
        }
        layout.focus(id)
        reconcile()
        applyFocusStyling()
        if grabKeyboard { pane.focusTranscript() }
        host?.focusedPaneChanged()
        persist()
    }

    static let doubleClickInterval: TimeInterval = 0.4

    private static var now: TimeInterval { Double(g_get_monotonic_time()) / 1_000_000 }

    /// A chip in the strip pressed: out of the zoom onto that pane, or, when the window had no room
    /// for it, swapped in for the placed pane focused longest ago.
    func reveal(_ id: PaneID) {
        guard layout.contains(id), let placement = currentPlacement() else { return }
        if let zoomed = layout.zoomedPane {
            layout.toggleZoom(zoomed)
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
        host?.focusedPaneChanged()
        persist()
    }

    func restore(_ snapshot: SplitSnapshot) -> [PaneID: SplitPaneSession] {
        guard host != nil, snapshot.layout.isValid else { return [:] }
        for id in Array(panes.keys) { retire(id) }
        layout = snapshot.layout
        pinned = Set(layout.paneIDs.filter { snapshot.isPinned($0) })
        var bindings: [PaneID: SplitPaneSession] = [:]
        for id in layout.paneIDs {
            let pane = makePane(id)
            adopt(pane, as: id)
            switch snapshot.content(for: id) {
            case .draw(let address):
                pane.showDraw(ImageGenEndpoint(address: address))
            case .web:
                if let target = snapshot.page(for: id) { pane.showWeb(target) }
            case .video:
                if let target = snapshot.video(for: id) { pane.showVideo(target) }
            case .chat(let session):
                bindings[id] = session
                pane.showPlaceholder(Localized.text("Connecting…"))
            case .empty:
                pane.showPlaceholder(Localized.text("Pick a chat, or n for a new one."))
            }
        }
        relayout()
        return bindings
    }

    func snapshot() -> SplitSnapshot {
        var contents: [String: PaneContent] = [:]
        for (id, pane) in panes {
            if let endpoint = pane.drawEndpoint {
                contents[id.raw] = .draw(endpoint.address)
            } else if let target = pane.webTarget {
                contents[id.raw] = .web(target.address)
            } else if let target = pane.videoTarget {
                contents[id.raw] = .video(target.address)
            } else if let entry = pane.entry {
                contents[id.raw] = .chat(
                    SplitPaneSession(profileID: entry.profileID, sessionID: entry.session.id))
            } else if let session = host?.heldSession(for: id) {
                contents[id.raw] = .chat(session)
            }
        }
        return SplitSnapshot(
            layout: layout, contents: contents,
            pinned: layout.paneIDs.filter { pinned.contains($0) }.map(\.raw))
    }

    /// A lone pane needs no layout written — except when it is a slot, which is the one thing a
    /// single pane can hold that the chat list cannot restore on its own.
    func persist() {
        persistRequests += 1
        let snapshot = snapshot()
        guard let encoded = snapshot.encoded else { return }
        let slots = snapshot.contents.values.contains { $0.kind != .chat && $0 != .empty }
        SettingsFile.set(paneCount > 1 || slots ? encoded : nil, forKey: SplitSnapshot.defaultsKey)
        if currentKinds() != reconciledKinds {
            reconcile()
            applyFocusStyling()
        }
    }

    /// The tree changed: place it now, in this pass, and settle every density.
    private func relayout() {
        refreshPlacement()
        canvas.invalidate()
        reconcile()
        applyFocusStyling()
    }

    private func refreshPlacement() {
        let size = canvas.size
        guard size.width > 0, size.height > 0 else { return }
        let fresh = solvePlacement(size)
        placement = fresh
        syncDividers(fresh)
    }

    /// Density changes found during an allocation are applied after it, so the allocation never
    /// shows or hides a face mid-flight.
    private func scheduleReconcile() {
        guard !reconcileScheduled else { return }
        reconcileScheduled = true
        Gtk.onMain { [weak self] in
            guard let self else { return }
            self.reconcileScheduled = false
            let hadDividers = self.dividersStale
            self.refreshPlacement()
            if hadDividers { self.canvas.invalidate() }
            self.reconcile()
            self.applyFocusStyling()
        }
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

    private func currentKinds() -> [PaneID: PaneKind] {
        var kinds: [PaneID: PaneKind] = [:]
        for (id, pane) in panes { kinds[id] = pane.paneKind(held: held[id] != nil) }
        return kinds
    }

    /// The face every pane should wear now: hidden panes park with nothing; a paused or held chat
    /// wears the paused face; a chat too small to read whole is a glance; the focused chat is
    /// whole; the rest take the governor's word, capped at its full budget with pinned panes and
    /// the most recently touched first, so focusing a glance makes it whole at once and the
    /// longest-untouched whole peer is the one that steps down.
    func reconcile() {
        guard let placement else { return }
        reconciledKinds = currentKinds()
        let focusedID = layout.focusedPane
        let now = Self.now
        var faces: [PaneID: TileShell.Face] = [:]
        var hidden: Set<PaneID> = []
        var contenders: [PaneID] = []
        var focusedFull = false
        let honourPins = !(decision?.level.overridesPreference ?? false)
        for id in layout.paneIDs {
            guard let pane = panes[id] else { continue }
            guard let rect = placement.frames[id] else {
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
            if decision.map({ $0.densities[id] == .glance }) ?? false,
                !(honourPins && pinned.contains(id))
            {
                faces[id] = .glance
            } else {
                contenders.append(id)
            }
        }
        let budget = decision?.fullBudget ?? Int.max
        var remaining = budget == Int.max ? Int.max : max(0, budget - (focusedFull ? 1 : 0))
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
        describeDividers()
        refreshStrip()
        speakPanes()
        onDensityChanged?()
    }

    /// Each divider introduces itself again whenever where it stands, how far it may travel or
    /// which panes it divides has changed — a conversation opening in a pane changes what the
    /// pane needs, and so how far its neighbours' dividers may go.
    private func describeDividers() {
        guard let placement else { return }
        for divider in placement.dividers {
            dividers[divider.id]?.describe(divider, label: dividerLabel(divider.id))
        }
    }

    /// Out of sight: no stream, no clock, no glance; the rows stay for an instant unzoom.
    private func park(_ id: PaneID) {
        feeds.removeValue(forKey: id)?.cancel()
        shells[id]?.glance?.stopClock()
        panes[id]?.park()
        panes[id]?.setRowWindow(nil)
        scheduleRelease(id)
    }

    private func wear(_ face: TileShell.Face, id: PaneID) {
        guard let pane = panes[id], let shell = shells[id] else { return }
        switch face {
        case .full:
            feeds.removeValue(forKey: id)?.cancel()
            releaseTokens[id] = nil
            shell.glance?.stopClock()
            shell.show(.full)
            pane.setRowWindow(id == layout.focusedPane ? nil : decision?.rowWindows[id])
            pane.unpark()
        case .glance:
            pane.park()
            pane.setRowWindow(nil)
            let fresh = !shell.hasGlance
            let tile = shell.ensureGlance()
            shell.show(.glance)
            if fresh { wireGlance(tile, id: id) }
            startFeed(id)
            renderGlance(id)
            scheduleRelease(id)
        case .paused:
            feeds.removeValue(forKey: id)?.cancel()
            shell.glance?.stopClock()
            pane.park()
            shell.show(.paused)
            renderPaused(id)
            scheduleRelease(id)
        }
    }

    private func wireGlance(_ tile: GlanceTile, id: PaneID) {
        let titles: @Sendable (String) -> String = { SplitMenu.definition($0)?.title ?? $0 }
        tile.wire(
            GlanceTile.Actions(
                openFull: { [weak self] in Gtk.onMain { [weak self] in self?.openFull(id) } },
                keepLive: { [weak self] in Gtk.onMain { [weak self] in self?.togglePin(id) } },
                pause: { [weak self] in Gtk.onMain { [weak self] in self?.togglePark(id) } },
                close: { [weak self] in Gtk.onMain { [weak self] in self?.close(id) } },
                zoom: { [weak self] in
                    Gtk.onMain { [weak self] in
                        guard let self else { return }
                        self.promotionHold[id] = nil
                        if self.layout.zoomedPane != id { self.zoom(id) }
                    }
                },
                menu: { [weak self] in
                    [
                        (Localized.text("Open full"), nil, { [weak self] in
                            Gtk.onMain { [weak self] in self?.openFull(id) }
                        }),
                        (Localized.text("Keep live"),
                            self?.pinned.contains(id) == true ? "✓" : nil, { [weak self] in
                                Gtk.onMain { [weak self] in self?.togglePin(id) }
                            }),
                        (Localized.text("Pause this pane"), nil, { [weak self] in
                            Gtk.onMain { [weak self] in self?.togglePark(id) }
                        }),
                        (titles("split.zoom"), nil, { [weak self] in
                            Gtk.onMain { [weak self] in self?.zoom(id) }
                        }),
                        (titles("split.promote"), nil, { [weak self] in
                            Gtk.onMain { [weak self] in
                                guard let self else { return }
                                self.layout.focus(id)
                                _ = self.perform(.promoteSplit)
                            }
                        }),
                        (titles("split.close"), nil, { [weak self] in
                            Gtk.onMain { [weak self] in self?.close(id) }
                        }),
                    ]
                }))
    }

    /// A demoted pane keeps its rows for twenty seconds, so a glance pressed again comes back as
    /// it was; after that the rows go, and coming back refills the tail.
    private func scheduleRelease(_ id: PaneID) {
        guard releaseTokens[id] == nil else { return }
        let token = (releaseTokens.values.max() ?? 0) + 1
        releaseTokens[id] = token
        Gtk.after(UInt32(demotedKeep * 1000)) { [weak self] in
            guard let self, self.releaseTokens[id] == token else { return }
            self.releaseTokens[id] = nil
            guard let pane = self.panes[id], pane.isParked else { return }
            pane.releaseRows()
        }
    }

    /// A glance's own hold on the chat, at the level's glance rate, with the newest state the hub
    /// already has drawn at once.
    private func startFeed(_ id: PaneID) {
        guard feeds[id] == nil, let pane = panes[id], let entry = pane.entry, let host else { return }
        let interval = decision?.animation.glanceInterval ?? (1.0 / 4)
        let feed = GlanceFeed(entry: entry, live: host.live, interval: interval) { [weak self] state in
            self?.noteState(state, for: id)
        }
        feeds[id] = feed
        if let state = feed.latest ?? pane.lastState { noteState(state, for: id) }
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
        if readings[id] == nil, let state = pane.lastState {
            readings[id] = (GlanceReading(state: state, queued: pane.queuedCount), Date())
        }
        let tile = shell.ensureGlance()
        if let rect = placement?.frames[id] { tile.fit(width: rect.width, height: rect.height) }
        tile.render(
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
        shell.ensureParked().render(
            title: face.title, activity: face.activity, lastWords: kept?.reading.tail,
            readAt: kept?.at, detail: detail, index: (order.firstIndex(of: id) ?? 0) + 1,
            of: order.count)
    }

    /// The name and the face a pane is known by right now, from whatever it already holds: the
    /// stream it is showing, the last glance it read, or the chat list's listing.
    private func describe(_ id: PaneID) -> (title: String, activity: ActivityKind?) {
        guard let pane = panes[id] else { return (Localized.text("No conversation"), nil) }
        if let page = pane.webSummary { return (page, nil) }
        if let video = pane.videoSummary { return (video, nil) }
        if let entry = pane.entry {
            let title =
                entry.session.hasPlaceholderTitle
                ? Localized.text("New conversation") : entry.session.title
            let activity: ActivityKind?
            if let reading = readings[id], shells[id]?.face != .full {
                activity = reading.reading.activity
            } else if let state = pane.lastState {
                activity = ActivityKind.inFlight(in: state)
            } else {
                activity = listFace?(
                    SplitPaneSession(profileID: entry.profileID, sessionID: entry.session.id))?
                    .activity
            }
            return (title, activity)
        }
        if let session = held[id] ?? host?.heldSession(for: id), let listed = listFace?(session) {
            return listed
        }
        return (Localized.text("No conversation"), nil)
    }

    private func refreshStrip() {
        guard let placement, placement.stripNeeded else { return }
        let chips = placement.hidden.map { id -> OverflowStrip.Chip in
            let face = describe(id)
            return OverflowStrip.Chip(
                id: id, title: face.title, activity: face.activity,
                needsYou: face.activity == .needsApproval || face.activity == .needsAnswer)
        }
        strip.show(chips, width: placement.strip?.width ?? placement.bounds.width)
    }

    func applyGovernor(_ decision: GovernorDecision) {
        let previous = self.decision
        self.decision = decision
        let kinds = currentKinds()
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
            || kinds != reconciledKinds
        else {
            onDensityChanged?()
            return
        }
        reconcile()
        applyFocusStyling()
    }

    /// The focused pane's accent hairline, the identity strips, and what each pane says about
    /// itself: its pin and which other pane shows the same chat.
    func applyFocusStyling() {
        let several = layout.paneCount > 1
        let order = layout.paneIDs
        var showing: [String: [PaneID]] = [:]
        for id in order {
            guard let entry = panes[id]?.entry else { continue }
            showing[SessionPinStore.key(entry.profileID, entry.session.id), default: []].append(id)
        }
        for id in order {
            guard let pane = panes[id], let shell = shells[id] else { continue }
            let focused = id == layout.focusedPane
            pane.setFocused(focused)
            shell.setFocusRing(focused: focused, shown: several)
            pane.setIdentityVisible(several)
            var other: Int?
            if let entry = pane.entry,
                let twins = showing[SessionPinStore.key(entry.profileID, entry.session.id)],
                let twin = twins.first(where: { $0 != id }), let index = order.firstIndex(of: twin)
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
            shell.setAccessibleLabel(parts.joined(separator: ", "))
        }
    }

    /// The panes as the governor ranks them. A chat a restore is still resolving counts as a chat
    /// (`waiting`), and only a pane the person paused or a safe restore holds counts as parked.
    func seatbeltPanes(waiting: [PaneID: SplitPaneSession]) -> SeatbeltPanes {
        var seen = SeatbeltPanes.empty
        for id in layout.paneIDs {
            guard let pane = panes[id] else { continue }
            let rect = placement?.frames[id]
            let paused = userParked.contains(id) || held[id] != nil
            let placed = rect != nil && !paused
            seen.facts.append(
                PaneFacts(
                    id: id, kind: pane.paneKind(held: waiting[id] != nil || held[id] != nil),
                    focused: id == layout.focusedPane, placed: placed,
                    width: rect?.width ?? 0, height: rect?.height ?? 0,
                    attention: attention(id), pinned: pinned.contains(id)))
            if rect == nil {
                seen.hidden += 1
            } else if paused {
                seen.hidden += 1
            } else if shells[id]?.face == .glance {
                seen.glance += 1
            } else {
                seen.placed += 1
            }
        }
        return seen
    }

    private func attention(_ id: PaneID) -> PaneAttention {
        let activity: ActivityKind?
        if let shell = shells[id], shell.face != .full, let reading = readings[id] {
            activity = reading.reading.activity
        } else if let state = panes[id]?.lastState {
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
            if let shell = shells[id], placement?.isPlaced(id) == true, shell.face == .full {
                live += 1
            }
        }
        return (live, chats)
    }

    var lastDecision: GovernorDecision? { decision }

    private func dragMoved(over id: PaneID, payload: String?, x: Double, y: Double) {
        guard let shell = shells[id] else { return }
        let zone = PaneDropTarget.zone(
            x: x, y: y, width: Double(gtk_widget_get_width(shell.widget)),
            height: Double(gtk_widget_get_height(shell.widget)))
        let title = payload.flatMap(PaneDragPayload.decode).flatMap { host?.chatTitle(for: $0) }
        showDropHighlight(zone, on: id, caption: zone.caption(title))
    }

    private func paneDragMoved(over id: PaneID, payload: String?, x: Double, y: Double) {
        guard let shell = shells[id], let payload, let moving = PaneMovePayload.decode(payload),
            moving.pane != id, layout.contains(moving.pane)
        else { return clearDropHighlight() }
        let zone = PaneDropTarget.zone(
            x: x, y: y, width: Double(gtk_widget_get_width(shell.widget)),
            height: Double(gtk_widget_get_height(shell.widget)))
        showDropHighlight(zone, on: id, caption: zone.moveVerb)
    }

    /// The arrangement a drop would make, drawn over the panes rather than inside one: it has to
    /// be able to cover half a pane exactly, and it must never take the pointer events the drop
    /// target underneath it is still reading.
    private func showDropHighlight(_ zone: PaneDropZone, on id: PaneID, caption: String) {
        guard let frame = placement?.frames[id] else { return }
        let rect = PaneDropTarget.highlight(for: zone, width: frame.width, height: frame.height)
        dropZone = (id, zone)
        gtk_label_set_text(op(dropCaption), caption)
        dropRect = TileRect(
            x: Int32((frame.x + rect.x).rounded()), y: Int32((frame.y + rect.y).rounded()),
            width: Int32(rect.width.rounded()), height: Int32(rect.height.rounded()))
        canvas.invalidate()
    }

    func clearDropHighlight() {
        guard dropZone != nil || dropRect != nil else { return }
        dropZone = nil
        dropRect = nil
        canvas.invalidate()
    }

    func hover(_ pane: ChatPane, payload: PaneDragPayload, x: Double, y: Double) {
        dragMoved(over: pane.id, payload: payload.encoded, x: x, y: y)
    }

    func hover(_ pane: ChatPane, moving dragged: PaneID, x: Double, y: Double) {
        paneDragMoved(over: pane.id, payload: PaneMovePayload(pane: dragged).encoded, x: x, y: y)
    }

    @discardableResult
    func receiveDrop(_ text: String, on id: PaneID, x: Double, y: Double) -> Bool {
        clearDropHighlight()
        guard let pane = panes[id], let shell = shells[id],
            let payload = PaneDragPayload.decode(text)
        else { return false }
        let zone = PaneDropTarget.zone(
            x: x, y: y, width: Double(gtk_widget_get_width(shell.widget)),
            height: Double(gtk_widget_get_height(shell.widget)))
        return host?.pane(pane, received: payload, zone: zone) ?? false
    }

    @discardableResult
    func receivePaneDrop(_ text: String, on id: PaneID, x: Double, y: Double) -> Bool {
        clearDropHighlight()
        guard let shell = shells[id], let moving = PaneMovePayload.decode(text),
            layout.contains(moving.pane)
        else { return false }
        let zone = PaneDropTarget.zone(
            x: x, y: y, width: Double(gtk_widget_get_width(shell.widget)),
            height: Double(gtk_widget_get_height(shell.widget)))
        guard let intent = PaneDropTarget.move(moving.pane, onto: id, zone: zone),
            layout.apply(intent)
        else { return false }
        layout.focus(moving.pane)
        relayout()
        host?.focusedPaneChanged()
        persist()
        return true
    }

    var dropSummary: String {
        guard let dropZone, let index = layout.paneIDs.firstIndex(of: dropZone.pane) else {
            return "-"
        }
        return "\(index) \(dropZone.zone)"
    }

    var dropCaptionText: String {
        guard dropZone != nil, let text = gtk_label_get_text(op(dropCaption)) else { return "-" }
        return String(cString: text)
    }
}

/// A glance tile's hold on a chat: a `.glance` lease on the hub's one conversation and a slot in
/// the window's drain at the shed level's glance rate, so a peer that changes every token is drawn
/// a few times a second at most and a frozen level draws nothing until it is asked.
final class GlanceFeed: @unchecked Sendable {
    let key: LiveKey
    private let live: LiveRuntime
    private let lease: LiveLease
    private var token: DrainToken?
    private let slotID = PaneID()
    private var interval: TimeInterval
    private let onFrame: (ConversationState) -> Void
    private(set) var applied = 0

    init(
        entry: SessionEntry, live: LiveRuntime, interval: TimeInterval,
        onFrame: @escaping (ConversationState) -> Void
    ) {
        key = LiveKey(entry)
        self.live = live
        let drain = live.drain
        lease = live.hub.lease(key, interest: .glance) { drain.wake() }
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
            hasWork: { lease.hasFrame }, apply: { [weak self] in self?.applyNewest() })
    }

    private func applyNewest() {
        guard let frame = lease.take() else { return }
        applied += 1
        onFrame(frame.state)
    }

    func setInterval(_ next: TimeInterval) {
        guard next != interval else { return }
        interval = next
        if let token { live.drain.update(token, to: slot()) }
    }

    /// The newest state the hub holds for the chat, whatever the rate.
    var latest: ConversationState? { live.hub.latest(key)?.state }

    func cancel() {
        token?.cancel()
        token = nil
        lease.cancel()
    }
}
