import AppKit
import CodingAgentKit
import TailscodeCore

extension TileHost {
    /// The tree changed: lay the canvas out now, in this pass, and settle every density.
    func relayout() {
        canvas.needsLayout = true
        canvas.layoutSubtreeIfNeeded()
        reconcile()
        applyFocusStyling()
    }

    /// The placement for the canvas as it stands, solved if nothing has been laid out yet.
    func currentPlacement() -> PanePlacement? {
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
    func place(in bounds: NSRect) {
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
        if placement.frames.count != lastVisible {
            lastVisible = placement.frames.count
            DispatchQueue.main.async { [weak self] in
                MainThread.call { self?.applyFocusStyling() }
            }
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
        view.onDragBegan = { [weak self] _ in self?.holdRows(true) }
        view.onDrag = { [weak self] id, position in self?.drag(id, to: position) }
        view.onDragEnded = { [weak self] _, moved in
            guard let self else { return }
            self.holdRows(false)
            guard moved else { return }
            self.ratioCaptures += 1
            self.schedulePersist()
        }
        view.onEqualize = { [weak self] in self?.equalize() }
        view.onKey = { [weak self] id, key in self?.moveDivider(id, by: key) ?? false }
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

    /// A key on a focused seam: the same clamped move the pointer makes, written once.
    @discardableResult
    func moveDivider(_ split: SplitID, by key: DividerKey) -> Bool {
        guard let placement = currentPlacement() else { return false }
        guard layout.move(split, by: key, in: placement) else { return true }
        ratioCaptures += 1
        relayout()
        schedulePersist()
        return true
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
    func describe(_ id: PaneID) -> (title: String, activity: ActivityKind?) {
        guard let pane = panes[id] else { return (Localized.text("No conversation"), nil) }
        if let page = pane.webSummary { return (page, nil) }
        if let preview = pane.previewIdentity { return (preview.title, preview.activity) }
        #if !TAILSCODE_MAS
            if let video = pane.videoSummary { return (video, nil) }
        #endif
        if let entry = pane.currentEntry {
            let title =
                entry.session.hasPlaceholderTitle
                ? Localized.text("New conversation") : entry.session.title
            let activity: ActivityKind?
            if placement?.hidden.contains(id) == true {
                activity = hiddenActivity(of: entry)
            } else if let reading = readings[id], shells[id]?.face != .full {
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

    /// A pane out of the placement holds the state it parked with, which stops being true the
    /// moment it parks. A turn it handed to the background watch is read from that watch, and
    /// anything else from the chat list's listing, so its chip keeps telling the truth.
    private func hiddenActivity(of entry: SessionEntry) -> ActivityKind? {
        let key = SessionPinStore.key(entry.profileID, entry.session.id)
        if let presence = TileRuntime.shared.backgroundPresence[key], presence.isInFlight {
            return SessionRowModel(
                entry: entry, unreachable: false, unread: false, saved: false, presence: presence
            ).state.activity
        }
        return listFace?(SplitPaneSession(profileID: entry.profileID, sessionID: entry.session.id))?
            .activity
    }

    /// Redraws the overflow chips from what is known now: the window calls it when a watched
    /// conversation's reading changes, since the strip is otherwise only drawn by a layout pass.
    func refreshStrip() {
        guard let placement, !placement.hidden.isEmpty else { return }
        placeStrip(placement)
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
            MainThread.call {
                guard let self else { return }
                self.reconcileScheduled = false
                self.reconcile()
                self.applyFocusStyling()
            }
        }
    }
}
