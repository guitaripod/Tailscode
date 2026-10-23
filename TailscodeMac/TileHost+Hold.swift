import AppKit
import CodingAgentKit
import TailscodeCore

extension TileHost {
    /// What every pane holds, as the density rules read it; a pane that became a chat since the
    /// last reconcile — a restore's staggered wake, a chooser answered — is settled again.
    func currentKinds() -> [PaneID: PaneKind] {
        var kinds: [PaneID: PaneKind] = [:]
        for (id, pane) in panes { kinds[id] = pane.paneKind(held: held[id] != nil) }
        return kinds
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
    func liveResize(_ live: Bool) {
        liveResizing = live
        if live {
            hold(layout.paneIDs.filter { $0 != layout.focusedPane })
        } else {
            releaseDeferred()
        }
    }

    /// A divider drag: every whole pane takes its frame live under the pointer, and every
    /// transcript holds its rows' width until the drag ends — re-measuring a few hundred rows of
    /// text is twenty to fifty milliseconds a pane on the Mac, which no drag step can afford —
    /// then the focused pane catches up first and the rest one per frame.
    func holdRows(_ holding: Bool) {
        guard holding != dragHolding else { return }
        dragHolding = holding
        if holding {
            hold(layout.paneIDs)
        } else {
            let focused = layout.focusedPane
            deferredPeers = deferredPeers.filter { $0 == focused } + deferredPeers.filter { $0 != focused }
            releaseDeferred()
        }
    }

    private func hold(_ ids: [PaneID]) {
        let fresh = ids.filter { id in
            shells[id]?.face == .full && !(shells[id]?.isHidden ?? true)
                && !deferredPeers.contains(id)
        }
        deferredPeers += fresh
        for id in fresh { panes[id]?.setLiveResize(true) }
    }

    private func releaseDeferred() {
        guard !liveResizing, !dragHolding, !deferredPeers.isEmpty else { return }
        let id = deferredPeers.removeFirst()
        panes[id]?.setLiveResize(false)
        guard !deferredPeers.isEmpty else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { [weak self] in
            MainThread.call { self?.releaseDeferred() }
        }
    }

    /// The bench's way of starting and ending a live resize without a pointer on a window edge.
    func simulateLiveResize(_ live: Bool) {
        liveResize(live)
        if !live {
            while !deferredPeers.isEmpty { releaseDeferred() }
        }
    }

    /// The bench's way of holding rows for a drag and letting them all catch up at once.
    func simulateDividerDrag(_ dragging: Bool) {
        holdRows(dragging)
        if !dragging {
            while !deferredPeers.isEmpty { releaseDeferred() }
        }
    }

    /// The focused pane's accent hairline, the identity strips, and what each pane says about
    /// itself: its pin and which other pane shows the same chat.
    func applyFocusStyling() {
        let several = layout.paneCount > 1
        let visible = min(placement?.frames.count ?? layout.paneCount, layout.paneCount) > 1
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
            pane.setIdentityVisible(visible)
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
    func speakPanes() {
        let order = layout.paneIDs
        for (index, id) in order.enumerated() {
            guard let shell = shells[id] else { continue }
            let face = describe(id)
            var parts = [Localized.text("Pane %@ of %@", "\(index + 1)", "\(order.count)"), face.title]
            if let activity = face.activity { parts.append(activity.spoken) }
            shell.setAccessibilityLabel(parts.joined(separator: ", "))
        }
    }

    /// The panes as the governor ranks them. A chat a restore is still resolving counts as a chat
    /// (`waiting`), and only a pane the person paused or a safe restore holds counts as parked.
    func seatbeltPanes(held waiting: [PaneID: SplitPaneSession]) -> SeatbeltPanes {
        var seen = SeatbeltPanes()
        let placement = self.placement
        for id in layout.paneIDs {
            guard let pane = panes[id] else { continue }
            let rect = placement?.frames[id]
            let paused = userParked.contains(id) || held[id] != nil
            let placed = rect != nil && !paused
            let reading = attention(id)
            seen.facts.append(
                PaneFacts(
                    id: id, kind: pane.paneKind(held: waiting[id] != nil || held[id] != nil),
                    focused: id == layout.focusedPane, placed: placed,
                    width: rect?.width ?? 0, height: rect?.height ?? 0,
                    attention: reading, pinned: pinned.contains(id)))
            if rect == nil {
                seen.hidden += 1
            } else if paused || (pane.currentEntry == nil && waiting[id] != nil) {
                seen.parked += 1
            } else if shells[id]?.face == .glance {
                seen.glance += 1
            } else {
                seen.live += 1
                if reading == .running {
                    seen.streaming += 1
                    if id == layout.focusedPane { seen.focusedStreaming = true }
                }
            }
        }
        seen.occluded = occluded
        return seen
    }
}
