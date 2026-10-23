import AppKit
import CodingAgentKit
import TailscodeCore

extension TileHost {
    /// The face every pane should wear now: hidden panes park with nothing; a paused or held chat
    /// wears the paused face; a chat too small to read whole is a glance; the focused chat is
    /// whole; the rest take the governor's word, capped at its full budget with pinned panes and
    /// the most recently touched first, so focusing a glance makes it whole at once and the
    /// longest-untouched whole peer is the one that steps down.
    func reconcile() {
        guard let placement else { return }
        reconciledKinds = currentKinds()
        let focusedID = layout.focusedPane
        let now = CACurrentMediaTime()
        var faces: [PaneID: TileShellView.Face] = [:]
        var hidden: Set<PaneID> = []
        var contenders: [PaneID] = []
        var focusedFull = false
        for id in layout.paneIDs {
            guard let pane = panes[id] else { continue }
            guard let rect = placement.frames[id], !occluded else {
                hidden.insert(id)
                continue
            }
            let kind = pane.paneKind(held: held[id] != nil)
            if held[id] != nil || (userParked.contains(id) && kind == .chat) {
                faces[id] = .paused
                continue
            }
            guard kind == .chat else {
                faces[id] = .full
                continue
            }
            let fits = PaneSizing.allowsFull(
                width: rect.width, height: rect.height, wasFull: sizeAllowsFull[id] ?? true)
            sizeAllowsFull[id] = fits
            guard fits else {
                faces[id] = .glance
                continue
            }
            if id == focusedID {
                let holding = (promotionHold[id] ?? 0) > now
                faces[id] = holding ? .glance : .full
                focusedFull = !holding
                continue
            }
            if decision.map({ $0.densities[id] == .glance }) ?? false {
                faces[id] = .glance
            } else {
                contenders.append(id)
            }
        }
        let budget = decision?.fullBudget ?? Int.max
        var remaining = budget == Int.max ? Int.max : max(0, budget - (focusedFull ? 1 : 0))
        let honourPins = !(decision?.level.overridesPreference ?? false)
        let recent = layout.recentlyFocused
        let ranked = contenders.sorted { lhs, rhs in
            if honourPins, pinned.contains(lhs) != pinned.contains(rhs) {
                return pinned.contains(lhs)
            }
            return (recent.firstIndex(of: lhs) ?? .max) < (recent.firstIndex(of: rhs) ?? .max)
        }
        for id in ranked {
            if remaining > 0 {
                faces[id] = .full
                if remaining != .max { remaining -= 1 }
            } else {
                faces[id] = .glance
            }
        }
        for id in layout.paneIDs {
            if hidden.contains(id) {
                park(id)
            } else if let face = faces[id] {
                wear(face, id: id)
            }
        }
        speakPanes()
    }

    /// Out of sight: no stream, no clock, no glance; the rows stay for an instant unzoom.
    private func park(_ id: PaneID) {
        feeds.removeValue(forKey: id)?.cancel()
        shells[id]?.glance.stopClock()
        panes[id]?.setParked(true)
        panes[id]?.setLiveResize(false)
    }

    private func wear(_ face: TileShellView.Face, id: PaneID) {
        guard let pane = panes[id], let shell = shells[id] else { return }
        switch face {
        case .full:
            feeds.removeValue(forKey: id)?.cancel()
            releases.removeValue(forKey: id)?.invalidate()
            shell.show(.full)
            pane.setRowWindow(decision?.rowWindows[id])
            pane.setParked(false)
        case .glance:
            pane.setParked(true)
            let fresh = !shell.hasGlance
            shell.show(.glance)
            if fresh { wireGlance(shell.glance, id: id) }
            startFeed(id)
            renderGlance(id)
            scheduleRelease(id)
        case .paused:
            feeds.removeValue(forKey: id)?.cancel()
            pane.setParked(true)
            let fresh = shell.face != .paused
            shell.show(.paused)
            if fresh { shell.paused.onResume = { [weak self] in self?.resume(id) } }
            renderPaused(id)
            scheduleRelease(id)
        }
    }

    private func resume(_ id: PaneID) {
        if userParked.remove(id) != nil {
            reconcile()
            applyFocusStyling()
            return
        }
        onResume?(id)
    }

    /// A demoted pane keeps its rows for twenty seconds, so a glance pressed again comes back as it
    /// was; after that the rows go, and coming back rebuilds the tail.
    private func scheduleRelease(_ id: PaneID) {
        guard releases[id] == nil else { return }
        let timer = Timer(timeInterval: demotedKeep, repeats: false) { [weak self] _ in
            MainThread.call {
                guard let self else { return }
                self.releases[id] = nil
                guard let shell = self.shells[id], shell.face != .full else { return }
                self.panes[id]?.releaseRows()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        releases[id] = timer
    }

    /// A glance's own hold on the chat, at the level's glance rate, with the newest state the hub
    /// already has drawn at once.
    private func startFeed(_ id: PaneID) {
        guard feeds[id] == nil, let pane = panes[id], let entry = pane.currentEntry,
            let backend = pane.currentBackend
        else { return }
        let interval = decision?.animation.glanceInterval ?? (1.0 / 4)
        let feed = GlanceFeed(entry: entry, backend: backend, interval: interval) {
            [weak self] state in
            self?.noteState(state, for: id)
        }
        feeds[id] = feed
        if let state = feed.latest ?? pane.currentState { noteState(state, for: id) }
    }

    private func noteState(_ state: ConversationState, for id: PaneID) {
        let queued = panes[id]?.queuedCount ?? 0
        readings[id] = (GlanceReading(state: state, queued: queued), Date())
        renderGlance(id)
    }

    private func renderGlance(_ id: PaneID) {
        guard let shell = shells[id], shell.face == .glance, let pane = panes[id] else { return }
        let order = layout.paneIDs
        let title = describe(id).title
        if readings[id] == nil, let state = pane.currentState {
            readings[id] = (GlanceReading(state: state, queued: pane.queuedCount), Date())
        }
        shell.glance.render(
            title: title, reading: readings[id]?.reading,
            catalog: pane.currentEntry.map { ModelCatalogStore.cached($0.profileID) } ?? [],
            pinned: pinned.contains(id),
            index: (order.firstIndex(of: id) ?? 0) + 1, of: order.count)
    }

    private func renderPaused(_ id: PaneID) {
        guard let shell = shells[id] else { return }
        let order = layout.paneIDs
        let face = describe(id)
        var kept = readings[id]
        if let at = kept?.at, Date().timeIntervalSince(at) > Self.readingKeep {
            readings[id] = nil
            kept = nil
        }
        let detail: String? =
            held[id] != nil
            ? Localized.text("Tailscode didn't close normally last time, so this chat waits.")
            : nil
        shell.paused.render(
            title: face.title, activity: face.activity, lastWords: kept?.reading.tail,
            readAt: kept?.at, detail: detail, index: (order.firstIndex(of: id) ?? 0) + 1,
            of: order.count)
    }

    func applyGovernor(_ decision: GovernorDecision) {
        let previous = self.decision
        self.decision = decision
        let kinds = currentKinds()
        let interval = decision.animation.glanceInterval
        for (id, feed) in feeds {
            feed.setInterval(interval)
            if !interval.isFinite, let state = feed.latest,
                let activity = ActivityKind.inFlight(in: state),
                activity == .needsApproval || activity == .needsAnswer,
                readings[id]?.reading.activity != activity
            {
                noteState(state, for: id)
            }
        }
        refreshStrip()
        guard previous?.densities != decision.densities || previous?.fullBudget != decision.fullBudget
            || previous?.rowWindows != decision.rowWindows || previous?.level != decision.level
            || kinds != reconciledKinds
        else { return }
        reconcile()
        applyFocusStyling()
    }
}
