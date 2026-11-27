import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

extension MainWindow {
    /// The side buttons of a mouse, heard anywhere in the window. They are Back and Forward for the
    /// chats the focused pane has shown, wherever the pointer is — over the transcript, the list,
    /// the terminal or the prompt box — and a press is claimed so what is under the pointer never
    /// also acts on it.
    func installPointerButtons(on window: UnsafeMutablePointer<GtkWidget>) {
        Gtk.onPointerButtons(window) { [weak self] button in
            guard let direction = ChatTrail.Direction(gdkButton: button) else { return }
            _ = self?.stepTrail(direction)
        }
    }

    /// One step along the focused pane's trail, taken at once and drawn once: the place moves now,
    /// and the pane opens the chat it ended on after every queued press has been counted and before
    /// the next frame, so the fastest back-and-forth a hand can make costs one chat build per
    /// frame at the most and none for a chat it walked past. Nothing happens, and nothing is said,
    /// when there is nowhere to go.
    @discardableResult
    func stepTrail(_ direction: ChatTrail.Direction) -> Bool {
        if SheetStack.shared?.conversationChordsEnabled == false { return false }
        let pane = activePane
        let moved = pane.trail.step(direction) { reachable($0, from: pane) }
        guard moved != nil else { return false }
        queueTrailSettle(of: pane)
        return true
    }

    /// Whether a step may land on `target` in `pane`: the chat is still listed, and no other pane
    /// of a split is already showing it — one conversation in two panes would be two views of one
    /// stream.
    private func reachable(_ target: ChatTarget, from pane: ChatPane) -> Bool {
        guard listedEntry(for: target) != nil else { return false }
        guard let holder = splitHost.pane(showing: target.sessionID) else { return true }
        return holder === pane
    }

    private func listedEntry(for target: ChatTarget) -> SessionEntry? {
        entries.first {
            $0.session.id == target.sessionID && $0.profileID == target.contextID
        }
    }

    private func queueTrailSettle(of pane: ChatPane) {
        guard !pane.trailSettleQueued else { return }
        pane.trailSettleQueued = true
        Gtk.beforePaint { [weak self, weak pane] in
            guard let self, let pane else { return }
            self.settleTrail(of: pane)
        }
    }

    private func settleTrail(of pane: ChatPane) {
        pane.trailSettleQueued = false
        guard let target = pane.trail.settle(), let entry = listedEntry(for: target) else { return }
        Trace.mark("trail \(target.sessionID.prefix(8))")
        keepBackgroundWorkOut()
        pane.open(entry)
        followInSidebar(target)
        warmTrailNeighbours(of: pane)
    }

    /// A hop is drawn by itself: the rows above the first screen and the list's own redraw wait for
    /// the hand to stop. The list is drawn once, at the end, with the chat it ended on marked.
    private func keepBackgroundWorkOut() {
        FillTurns.hold(for: ChatTrail.quiet)
        let now = Self.sidebarClock
        sidebarHoldUntil = now + ChatTrail.quiet
        sidebarCoalescer.flush(at: now)
    }

    /// The list's mark moves with the chat, at once and in place: two rows change a style class, the
    /// keyboard cursor is re-derived and a row that is out of view is brought just inside it. The
    /// draw that settles everything else a hop changes (a chat now read, an order) waits for the hand.
    private func followInSidebar(_ target: ChatTarget) {
        markFocusedRow(target.sessionID)
        syncCursorToSelection()
        revealCursorRow()
    }

    /// The chats either side of the place are the next press's destination, so a chat the window no
    /// longer holds the rows of is made ready now, while the hand is still on the button.
    private func warmTrailNeighbours(of pane: ChatPane) {
        for direction in [ChatTrail.Direction.back, .forward] {
            guard
                let target = pane.trail.neighbour(direction, reaching: { reachable($0, from: pane) }),
                rememberedRows(for: target.sessionID) == nil,
                let entry = listedEntry(for: target)
            else { continue }
            live.warmer.warm(entry)
        }
    }

    /// A chat that no longer exists leaves every pane's trail, so Back never lands on it.
    func forgetInTrails(sessionIDs: Set<String>) {
        splitHost.eachPane { pane in
            for target in pane.trail.visited where sessionIDs.contains(target.sessionID) {
                pane.trail.forget(target)
            }
        }
    }
}
