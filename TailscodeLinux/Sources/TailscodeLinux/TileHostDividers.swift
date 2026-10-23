import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

extension TileHost {
    /// The canvas's allocation, asking where everything goes. Nothing here creates or destroys a
    /// widget: whatever the solve finds out of date — a divider with no band, a density the new
    /// geometry changes — is settled on the next idle, outside the allocation.
    func solve(width: Int32, height: Int32, sink: TileSink) {
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

    func syncDividers(_ placement: PanePlacement) {
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

    func makeDivider(_ placement: DividerPlacement) -> TileDivider {
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
    func dividerLabel(_ split: SplitID) -> String {
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

    func beginDrag(_ id: SplitID, x: Double, y: Double) {
        guard let divider = placement?.divider(id) else { return }
        let pointer = divider.axis == .horizontal ? x : y
        let ghosting = forcedGhost ?? (canvas.lastAllocateMilliseconds >= Self.liveDragLimit)
        drag = DividerDrag(
            id: id, axis: divider.axis, startPosition: divider.position, startPointer: pointer,
            ghosting: ghosting, lastTarget: divider.position)
    }

    func moveDrag(x: Double, y: Double) {
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

    func endDrag(x: Double?, y: Double?) {
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

    func commitDrag(_ id: SplitID, to target: Double) {
        guard let placement, layout.drag(id, to: target, in: placement) else { return }
        canvas.invalidate()
    }

    /// The line a ghost drag moves: where Core's clamp would put the divider for this pointer,
    /// drawn across the parent's extent, without moving a pane.
    func showGhost(_ state: DividerDrag, target: Double, placement: PanePlacement) {
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

    static var now: TimeInterval { Double(g_get_monotonic_time()) / 1_000_000 }

    func dragMoved(over id: PaneID, payload: String?, x: Double, y: Double) {
        guard let shell = shells[id] else { return }
        let zone = PaneDropTarget.zone(
            x: x, y: y, width: Double(gtk_widget_get_width(shell.widget)),
            height: Double(gtk_widget_get_height(shell.widget)))
        let title = payload.flatMap(PaneDragPayload.decode).flatMap { host?.chatTitle(for: $0) }
        showDropHighlight(zone, on: id, caption: zone.caption(title))
    }

    func paneDragMoved(over id: PaneID, payload: String?, x: Double, y: Double) {
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
    func showDropHighlight(_ zone: PaneDropZone, on id: PaneID, caption: String) {
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
