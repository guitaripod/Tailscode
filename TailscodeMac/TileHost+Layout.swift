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
            if shell.frame != frame {
                let resized = shell.frame.size != frame.size
                shell.frame = frame
                if !resized { panes[id]?.sky.needsDisplay = true }
            }
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
        let labels = dividerWords()
        var seen: Set<SplitID> = []
        for divider in placement.dividers {
            seen.insert(divider.id)
            let view = dividers[divider.id] ?? makeDivider(divider)
            view.update(divider, label: labels[divider.id] ?? "")
            if view.isHidden { view.isHidden = false }
        }
        for (id, view) in dividers where !seen.contains(id) {
            view.removeFromSuperview()
            dividers[id] = nil
        }
    }

    /// What each seam tells a screen reader, counted once for the tree it divides: the words name
    /// two pane numbers, so a layout pass over an unchanged tree pays for no walk and no string.
    private func dividerWords() -> [SplitID: String] {
        if layout.root == dividerRoot { return dividerLabels }
        var labels: [SplitID: String] = [:]
        let order = layout.paneIDs
        func walk(_ node: SplitNode) -> (first: PaneID, last: PaneID)? {
            switch node {
            case .pane(let id):
                return (id, id)
            case .split(let id, _, _, let first, let second):
                guard let leading = walk(first), let trailing = walk(second) else { return nil }
                labels[id] = Localized.text(
                    "Divider between pane %@ and pane %@",
                    "\((order.firstIndex(of: leading.last) ?? 0) + 1)",
                    "\((order.firstIndex(of: trailing.first) ?? 1) + 1)")
                return (leading.first, trailing.last)
            }
        }
        _ = walk(layout.root)
        dividerRoot = layout.root
        dividerLabels = labels
        return labels
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
            forgetStripChips()
            return
        }
        let frame = NSRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
        if strip.frame != frame { strip.frame = frame }
        strip.isHidden = false
        if stripPending || placement.hidden != stripHidden {
            stripPending = false
            stripHidden = placement.hidden
            stripRow = placement.hidden.map(chip(for:))
        }
        strip.show(stripRow)
    }

    /// The chip a hidden pane wears, kept until one of the cheap facts it was built from moved: a
    /// chip is read out of the chat list's whole listing, so a layout pass and the governor's
    /// second cost a handful of lookups here instead of a scan of every chat on every machine.
    private func chip(for id: PaneID) -> OverflowStripView.Chip {
        let facts = chipFacts(id)
        if let known = stripChipFacts[id], known == facts, let chip = stripChips[id] { return chip }
        let face = describe(id)
        let chip = OverflowStripView.Chip(
            id: id, title: face.title, activity: face.activity,
            needsYou: face.activity == .needsApproval || face.activity == .needsAnswer)
        stripChips[id] = chip
        stripChipFacts[id] = facts
        return chip
    }

    /// What a chip says that can be read without walking the listing, and the refresh count the
    /// walk it did make belongs to.
    private func chipFacts(_ id: PaneID) -> StripChipFacts {
        let pane = panes[id]
        let entry = pane?.currentEntry
        let identity = entry.map {
            "\($0.profileID)|\($0.session.id)|\($0.session.hasPlaceholderTitle)|\($0.session.title)"
        }
        let key = entry.map { SessionPinStore.key($0.profileID, $0.session.id) }
        let preview = pane?.previewIdentity
        var summary = pane?.webSummary ?? preview?.title
        #if !TAILSCODE_MAS
            summary = summary ?? pane?.videoSummary
        #endif
        return StripChipFacts(
            entry: identity, held: held[id], summary: summary, activity: preview?.activity,
            presence: key.flatMap { TileRuntime.shared.backgroundPresence[$0] },
            listing: stripListing)
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

    /// Redraws the overflow chips from what is known now. A chip whose cheap facts did not move is
    /// kept, so the governor's second and a layout pass cost the strip nothing they did not already
    /// pay for.
    func refreshStrip() {
        guard let placement, !placement.hidden.isEmpty else {
            forgetStripChips()
            return
        }
        placeStrip(placement)
    }

    /// The listing the chips are read out of, or the watches' presence, moved on: every chip is
    /// read again on the next refresh, and one whose facts moved is built again.
    func noteListingChanged() {
        stripListing &+= 1
        stripPending = true
        refreshStrip()
    }

    private func forgetStripChips() {
        guard !stripChips.isEmpty || !stripRow.isEmpty else { return }
        stripChips.removeAll()
        stripChipFacts.removeAll()
        stripRow = []
        stripHidden = []
        stripPending = true
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
