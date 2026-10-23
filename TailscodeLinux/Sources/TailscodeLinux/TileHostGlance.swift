import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

extension TileHost {
    /// A demoted pane keeps its rows for twenty seconds, so a glance pressed again comes back as
    /// it was; after that the rows go, and coming back refills the tail.
    func scheduleRelease(_ id: PaneID) {
        guard releaseTokens[id] == nil else { return }
        releaseSerial += 1
        let token = releaseSerial
        releaseTokens[id] = token
        Gtk.after(UInt32(demotedKeep * 1000)) { [weak self] in
            guard let self, self.releaseTokens[id] == token else { return }
            self.releaseTokens[id] = nil
            guard let pane = self.panes[id], pane.isParked else { return }
            pane.releaseRows()
        }
    }

    /// A glance's own hold on the chat, at the level's glance rate, with the newest state the hub
    /// already has drawn at once.
    func startFeed(_ id: PaneID) {
        guard feeds[id] == nil, let pane = panes[id], let entry = pane.entry, let host else { return }
        let interval = decision?.animation.glanceInterval ?? (1.0 / 4)
        let feed = GlanceFeed(entry: entry, live: host.live, interval: interval) { [weak self] state in
            self?.noteState(state, for: id)
        }
        feeds[id] = feed
        if let state = feed.latest ?? pane.lastState { noteState(state, for: id) }
    }

    func noteState(_ state: ConversationState, for id: PaneID) {
        let queued = panes[id]?.queuedCount ?? 0
        readings[id] = (GlanceReading(state: state, queued: queued), Date())
        renderGlance(id)
    }

    func renderGlance(_ id: PaneID) {
        guard let shell = shells[id], shell.face == .glance, let pane = panes[id] else { return }
        let order = layout.paneIDs
        let title = describe(id).title
        if readings[id] == nil, let state = pane.lastState {
            readings[id] = (GlanceReading(state: state, queued: pane.queuedCount), Date())
        }
        let tile = shell.ensureGlance()
        if let rect = placement?.frames[id] { tile.fit(width: rect.width, height: rect.height) }
        tile.render(
            title: title, reading: readings[id]?.reading,
            catalog: pane.entry.map { ModelCatalogStore.cached($0.profileID) } ?? [],
            pinned: pinned.contains(id),
            index: (order.firstIndex(of: id) ?? 0) + 1, of: order.count)
    }

    func renderPaused(_ id: PaneID) {
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
        shell.ensureParked().render(
            title: face.title, activity: face.activity, lastWords: kept?.reading.tail,
            readAt: kept?.at, detail: detail, index: (order.firstIndex(of: id) ?? 0) + 1,
            of: order.count)
    }

    /// The name and the face a pane is known by right now, from whatever it already holds: the
    /// stream it is showing, the last glance it read, or the chat list's listing.
    func describe(_ id: PaneID) -> (title: String, activity: ActivityKind?) {
        guard let pane = panes[id] else { return (Localized.text("No conversation"), nil) }
        if let preview = pane.previewSummary { return (preview, nil) }
        if let page = pane.webSummary { return (page, nil) }
        if let video = pane.videoSummary { return (video, nil) }
        if let entry = pane.entry {
            let title =
                entry.session.hasPlaceholderTitle
                ? Localized.text("New conversation") : entry.session.title
            let activity: ActivityKind?
            if let reading = readings[id], shells[id]?.face != .full {
                activity = reading.reading.activity
            } else if let state = pane.lastState {
                activity = ActivityKind.inFlight(in: state)
            } else {
                activity = listFace?(
                    SplitPaneSession(profileID: entry.profileID, sessionID: entry.session.id))?
                    .activity
            }
            return (title, activity)
        }
        if let session = held[id] ?? host?.heldSession(for: id), let listed = listFace?(session) {
            return listed
        }
        return (Localized.text("No conversation"), nil)
    }

    func refreshStrip() {
        guard let placement, placement.stripNeeded else { return }
        let chips = placement.hidden.map { id -> OverflowStrip.Chip in
            let face = describe(id)
            return OverflowStrip.Chip(
                id: id, title: face.title, activity: face.activity,
                needsYou: face.activity == .needsApproval || face.activity == .needsAnswer)
        }
        strip.show(chips, width: placement.strip?.width ?? placement.bounds.width)
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
        guard previous?.densities != decision.densities || previous?.fullBudget != decision.fullBudget
            || previous?.rowWindows != decision.rowWindows || previous?.level != decision.level
            || kinds != reconciledKinds
        else {
            onDensityChanged?()
            return
        }
        reconcile()
        applyFocusStyling()
    }

    /// The focused pane's accent hairline, the identity strips, and what each pane says about
    /// itself: its pin and which other pane shows the same chat.
    func applyFocusStyling() {
        let several = layout.paneCount > 1
        let visibleCount = currentPlacement().map { $0.frames.count } ?? layout.paneCount
        let order = layout.paneIDs
        let shown = currentPlacement().map { Set($0.frames.keys) } ?? Set(order)
        ChatPane.markSharedTitles(
            visible: order.filter { shown.contains($0) }.compactMap { panes[$0] },
            others: order.filter { !shown.contains($0) }.compactMap { panes[$0] })
        var showing: [String: [PaneID]] = [:]
        for id in order {
            guard let entry = panes[id]?.entry else { continue }
            showing[SessionPinStore.key(entry.profileID, entry.session.id), default: []].append(id)
        }
        for id in order {
            guard let pane = panes[id], let shell = shells[id] else { continue }
            let focused = id == layout.focusedPane
            pane.setFocused(focused)
            shell.setFocusRing(focused: focused, shown: several)
            pane.setIdentityVisible(visibleCount > 1)
            var other: Int?
            if let entry = pane.entry,
                let twins = showing[SessionPinStore.key(entry.profileID, entry.session.id)],
                let twin = twins.first(where: { $0 != id }), let index = order.firstIndex(of: twin)
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
            shell.setAccessibleLabel(parts.joined(separator: ", "))
        }
    }

    /// The panes as the governor ranks them. A chat a restore is still resolving counts as a chat
    /// (`waiting`), and only a pane the person paused or a safe restore holds counts as parked.
    func seatbeltPanes(waiting: [PaneID: SplitPaneSession]) -> SeatbeltPanes {
        var seen = SeatbeltPanes.empty
        for id in layout.paneIDs {
            guard let pane = panes[id] else { continue }
            let rect = placement?.frames[id]
            let paused = userParked.contains(id) || held[id] != nil
            let placed = rect != nil && !paused
            seen.facts.append(
                PaneFacts(
                    id: id, kind: pane.paneKind(held: waiting[id] != nil || held[id] != nil),
                    focused: id == layout.focusedPane, placed: placed,
                    width: rect?.width ?? 0, height: rect?.height ?? 0,
                    attention: attention(id), pinned: pinned.contains(id)))
            if rect == nil {
                seen.hidden += 1
            } else if paused {
                seen.hidden += 1
            } else if shells[id]?.face == .glance {
                seen.glance += 1
            } else {
                seen.placed += 1
            }
        }
        return seen
    }

    func attention(_ id: PaneID) -> PaneAttention {
        let activity: ActivityKind?
        if let shell = shells[id], shell.face != .full, let reading = readings[id] {
            activity = reading.reading.activity
        } else if let state = panes[id]?.lastState {
            activity = ActivityKind.inFlight(in: state)
        } else {
            activity = nil
        }
        switch activity {
        case .needsApproval, .needsAnswer: return .needsYou
        case .failed: return .failed
        case nil, .offline, .queued: return .quiet
        default: return .running
        }
    }

    /// What the live chip says: how many chats are whole out of how many there are.
    var liveCounts: (live: Int, chats: Int) {
        var live = 0
        var chats = 0
        for id in layout.paneIDs {
            guard let pane = panes[id], pane.paneKind(held: held[id] != nil) == .chat else {
                continue
            }
            chats += 1
            if let shell = shells[id], placement?.isPlaced(id) == true, shell.face == .full {
                live += 1
            }
        }
        return (live, chats)
    }

    var lastDecision: GovernorDecision? { decision }
}
