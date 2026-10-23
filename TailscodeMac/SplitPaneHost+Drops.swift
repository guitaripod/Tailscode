import AppKit
import TailscodeCore

extension SplitPaneHost {
    func installDropTarget(on pane: TranscriptViewController) {
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

    func showDropHighlight(
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
}
