import AppKit
import CodingAgentKit
import TailscodeCore

extension MainWindowController {
    /// A press of the mouse's side buttons, taken before AppKit dispatches it: Back and Forward for
    /// the chats the focused pane has shown, wherever the pointer is. A press that has nowhere to
    /// go is handed back untouched, so a button something under the pointer wants still reaches it.
    func takesTrailButton(_ event: NSEvent) -> Bool {
        guard event.type == .otherMouseDown, event.window === window,
            let direction = ChatTrail.Direction(cocoaButton: event.buttonNumber)
        else { return false }
        return stepTrail(direction)
    }

    /// One step along the focused pane's trail, taken at once and drawn once: the place moves now
    /// and the pane opens the chat it ended on when the event turn is over, so presses that arrive
    /// together open one chat and build nothing they walked past.
    @discardableResult
    func stepTrail(_ direction: ChatTrail.Direction) -> Bool {
        guard SheetStack.shared.conversationChordsEnabled else { return false }
        let pane = splitPanes.active
        let moved = pane.trail.step(direction) { reachable($0, from: pane) }
        guard moved != nil else { return false }
        queueTrailSettle(of: pane)
        return true
    }

    /// Whether a step may land on `target` in `pane`: the chat is still listed, and no other pane
    /// of a split already shows it.
    private func reachable(_ target: ChatTarget, from pane: TranscriptViewController) -> Bool {
        guard listedEntry(for: target) != nil else { return false }
        guard let holder = splitPanes.pane(showing: target.sessionID) else { return true }
        return holder === pane
    }

    private func listedEntry(for target: ChatTarget) -> SessionEntry? {
        sidebar.allEntries.first {
            $0.session.id == target.sessionID && $0.profileID == target.contextID
        }
    }

    private func queueTrailSettle(of pane: TranscriptViewController) {
        guard !pane.trailSettleQueued else { return }
        pane.trailSettleQueued = true
        DispatchQueue.main.async { [weak self, weak pane] in
            guard let self, let pane else { return }
            self.settleTrail(of: pane)
        }
    }

    private func settleTrail(of pane: TranscriptViewController) {
        pane.trailSettleQueued = false
        guard let target = pane.trail.settle(), let entry = listedEntry(for: target),
            let backend = sidebar.backend(for: entry)
        else { return }
        if splitPanes.paneCount > 1 {
            if pane === splitPanes.active {
                handleOpen(entry, backend: backend)
            } else {
                pane.open(entry, backend: backend)
            }
        } else {
            sidebar.open(entry)
        }
        warmTrailNeighbours(of: pane)
    }

    /// The chats either side of the place are the next press's destination, so each is made ready
    /// while the hand is still on the button.
    private func warmTrailNeighbours(of pane: TranscriptViewController) {
        for direction in [ChatTrail.Direction.back, .forward] {
            guard
                let target = pane.trail.neighbour(direction, reaching: { reachable($0, from: pane) }),
                let entry = listedEntry(for: target), let backend = sidebar.backend(for: entry)
            else { continue }
            ConversationWarmer.shared.warm(entry, backend: backend)
        }
    }

    /// A chat that no longer exists leaves every pane's trail, so Back never lands on it.
    func forgetInTrails(_ entry: SessionEntry) {
        let target = ChatTarget(contextID: entry.profileID, sessionID: entry.session.id)
        splitPanes.eachPane { $0.trail.forget(target) }
    }
}
