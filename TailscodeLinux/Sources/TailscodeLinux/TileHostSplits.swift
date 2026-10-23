import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

extension TileHost {
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

    func hasRoom(_ id: PaneID, axis: SplitAxis) -> Bool {
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

    func close(_ id: PaneID) {
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

    func zoom(_ id: PaneID) {
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

    func openFull(_ id: PaneID) {
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

    func currentPlacement() -> PanePlacement? {
        let size = canvas.size
        guard size.width > 0, size.height > 0 else { return placement }
        return solvePlacement(size)
    }

    func solvePlacement(_ size: SplitSize) -> PanePlacement {
        let panes = self.panes
        let held = self.held
        return layout.placement(in: size) { id in
            PaneSizing.layoutMinimum(kind: panes[id]?.paneKind(held: held[id] != nil) ?? .empty)
        }
    }
}
