import AppKit
import CodingAgentKit
import TailscodeCore

extension TileHost {
    private func zoneUnderPointer(_ sender: NSDraggingInfo, over id: PaneID) -> PaneDropZone? {
        guard let shell = shells[id] else { return nil }
        let local = shell.convert(sender.draggingLocation, from: nil)
        let bounds = shell.bounds
        return PaneDropTarget.zone(
            x: Double(local.x), y: Double(local.y), width: Double(bounds.width),
            height: Double(bounds.height))
    }

    func dragUpdated(_ sender: NSDraggingInfo, over id: PaneID) -> Bool {
        guard let shell = shells[id], let zone = zoneUnderPointer(sender, over: id) else {
            return false
        }
        let caption: String
        if let moving = panePayload(from: sender) {
            guard moving.pane != id, layout.contains(moving.pane) else {
                clearDropHighlight()
                return false
            }
            caption = zone.moveVerb
        } else {
            caption = zone.caption(payload(from: sender).flatMap { chatTitleForDrop?($0) })
        }
        let rect = PaneDropTarget.highlight(
            for: zone, width: Double(shell.frame.width), height: Double(shell.frame.height))
        dropHighlight.show(
            frame: NSRect(
                x: shell.frame.minX + rect.x, y: shell.frame.minY + rect.y, width: rect.width,
                height: rect.height),
            caption: caption)
        dropZone = (id, zone)
        return true
    }

    func clearDropHighlight() {
        dropZone = nil
        dropHighlight.clear()
    }

    func receiveDrop(_ sender: NSDraggingInfo, on id: PaneID) -> Bool {
        clearDropHighlight()
        guard let pane = panes[id], let zone = zoneUnderPointer(sender, over: id) else {
            return false
        }
        if let moving = panePayload(from: sender) {
            return receivePaneDrop(moving, on: id, zone: zone)
        }
        guard let payload = payload(from: sender) else { return false }
        return onChatDropped?(pane, payload, zone) ?? false
    }

    /// A pane let go over another. A pane dropped on itself or carrying a pane the tree no longer
    /// holds changes nothing, and the pane that moved is the one that takes the focus. No pane view
    /// is rebuilt: the canvas only gives every shell its new frame.
    @discardableResult
    func receivePaneDrop(_ moving: PaneMovePayload, on id: PaneID, zone: PaneDropZone) -> Bool {
        guard layout.contains(moving.pane),
            let intent = PaneDropTarget.move(moving.pane, onto: id, zone: zone),
            layout.apply(intent)
        else { return false }
        layout.focus(moving.pane)
        relayout()
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
        guard let text = sender.draggingPasteboard.string(forType: .tailscodeChat) else { return nil }
        return PaneDragPayload.decode(text)
    }
}
