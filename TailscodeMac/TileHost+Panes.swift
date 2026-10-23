import AppKit
import CodingAgentKit
import TailscodeCore

extension TileHost {
    /// A strip hung across the top of the canvas, under the toolbar, inset from the panes' edges
    /// and above every pane.
    func installOverlay(_ overlay: NSView) {
        overlay.translatesAutoresizingMaskIntoConstraints = false
        canvas.addOverlay(overlay)
        let wide = overlay.widthAnchor.constraint(equalToConstant: 720)
        wide.priority = .init(700)
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

    func buildPane() -> TranscriptViewController {
        if let makePane { return makePane() }
        let pane = TranscriptViewController()
        if let paneHost { pane.connect(to: paneHost) }
        return pane
    }

    /// A pane joins the canvas: its shell is made and added once, and the conversation goes in it
    /// for good.
    func adopt(_ pane: TranscriptViewController, as id: PaneID) {
        panes[id] = pane
        let shell = TileShellView(paneID: id)
        shells[id] = shell
        shell.install(body: pane.view)
        addChild(pane)
        pane.paneMovePayload = { PaneMovePayload(pane: id) }
        wireShell(shell, id: id)
        canvas.addPane(shell)
    }

    /// A pane leaves the canvas: its stream and clocks first, then its glance and timers, then the
    /// shell. The only removal a pane ever sees.
    func retire(_ id: PaneID) {
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

    func wireGlance(_ glance: GlanceTileView, id: PaneID) {
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
}
