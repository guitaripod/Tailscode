import AppKit
import CodingAgentKit
import CodingAgentKitApple
import MidgarCore
import TailscodeCore

extension MainWindowController {
    /// A restored pane opens its session the moment the cached listing carries it; a session no
    /// listing carries leaves an explanation, and the binding is kept for the next refresh. A pane
    /// somebody filled by hand in the meantime keeps what it holds, and anything that did bind
    /// moves the window's own chrome after it — the title, the files tree, the terminal's
    /// directory all sit at their launch defaults until something tells them a chat is open, which
    /// is why the first `git status` after a restore used to run in the wrong repository.
    ///
    /// What resolves does not open at once: it wakes in `RestorePlan.wakeSchedule`'s order — the
    /// focused pane now, then the most recently focused, 300 ms apart — so a restore or a bulk open
    /// never starts every stream in one frame.
    func resolvePendingBindings() {
        guard !pendingBindings.isEmpty else { return }
        let listed = SessionListCache.load()
        var ready: [PaneID: (SessionEntry, any CodingAgentBackend)] = [:]
        for (paneID, binding) in pendingBindings {
            guard let pane = splitPanes.panes[paneID], pane.currentEntry == nil else {
                pendingBindings[paneID] = nil
                continue
            }
            guard
                let entry = listed.first(where: {
                    $0.profileID == binding.profileID && $0.session.id == binding.sessionID
                }),
                let profile = ServerDirectory.shared.profiles.first(where: {
                    $0.id == binding.profileID
                }),
                let backend = ServerDirectory.shared.backend(for: profile)
            else {
                pane.resetPane(
                    placeholder: Localized.text(
                        "Waiting for this conversation's server to answer."))
                continue
            }
            pendingBindings[paneID] = nil
            wakingBindings[paneID] = binding
            ready[paneID] = (entry, backend)
        }
        guard !ready.isEmpty else { return }
        let layout = splitPanes.layout
        let schedule = RestorePlan.wakeSchedule(
            focused: layout.focusedPane, recent: layout.recentlyFocused
        ).filter { ready[$0.pane] != nil }
        let already = wakingQueueEnd
        for (index, step) in schedule.enumerated() {
            guard let (entry, backend) = ready[step.pane] else { continue }
            let delay = max(already, CACurrentMediaTime()) - CACurrentMediaTime() + step.at
            if index == 0, delay <= 0 {
                wake(step.pane, entry: entry, backend: backend)
                continue
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainThread.call { self?.wake(step.pane, entry: entry, backend: backend) }
            }
        }
        wakingQueueEnd =
            max(already, CACurrentMediaTime()) + (schedule.last?.at ?? 0) + RestorePlan.wakeSpacing
    }

    /// One pane's turn in a staggered wake. A pane closed or filled by hand while it waited keeps
    /// what it has.
    private func wake(
        _ paneID: PaneID, entry: SessionEntry, backend: any CodingAgentBackend
    ) {
        guard wakingBindings.removeValue(forKey: paneID) != nil,
            let pane = splitPanes.panes[paneID], pane.currentEntry == nil
        else { return }
        pane.open(entry, backend: backend)
        MidgarLog.info(
            "restore: woke pane \(paneID.raw.prefix(8)), \(wakingBindings.count) still waiting",
            category: .session
        )
        if pane === transcript { focusedPaneChanged() }
    }

    /// The pane a parked or waking chat belongs to. Asked to open such a chat — the list's own
    /// reopen of the last chat at launch, or a press on its row — the window goes to that pane
    /// instead of collapsing the arrangement around it; going there is what wakes a parked one.
    func heldPane(showing sessionID: String) -> PaneID? {
        parkedBindings.first { $0.value.sessionID == sessionID }?.key
            ?? wakingBindings.first { $0.value.sessionID == sessionID }?.key
    }

    /// Holds for panes a structural change closed go with them, and the banner counts what is left.
    func forgetHeldPanesGone() {
        let present = Set(splitPanes.layout.paneIDs)
        parkedBindings = parkedBindings.filter { present.contains($0.key) }
        wakingBindings = wakingBindings.filter { present.contains($0.key) }
        splitPanes.setHeld(parkedBindings)
        refreshLiveChip(Seatbelts.shared.decision)
        if parkedBindings.isEmpty {
            dismissRestoreBanner()
        } else {
            restoreBanner?.setCount(parkedBindings.count)
        }
    }

    /// Every session a pane holds without showing it yet, for the saved layout.
    var heldSessions: [PaneID: SplitPaneSession] {
        pendingBindings.merging(wakingBindings) { held, _ in held }
            .merging(parkedBindings) { held, _ in held }
    }

    /// The safe restore's paused face: each parked pane says it is paused and how to wake it, and
    /// the banner counts them.
    private func park(_ bindings: [PaneID: SplitPaneSession]) {
        parkedBindings = bindings
        for paneID in bindings.keys {
            splitPanes.panes[paneID]?.resetPane(
                placeholder: Localized.text("Paused. Select this pane to resume it."))
        }
        let banner = RestoreBannerView()
        banner.setCount(bindings.count)
        banner.onResumeAll = { [weak self] in self?.resumeAllParked() }
        banner.onResumeOneByOne = { [weak self] in self?.resumeParkedOneByOne() }
        banner.onDismiss = { [weak self] in self?.dismissRestoreBanner() }
        splitPanes.installOverlay(banner)
        restoreBanner = banner
        splitPanes.setHeld(parkedBindings)
    }

    func resumeAllParked() {
        pendingBindings.merge(parkedBindings) { held, _ in held }
        parkedBindings = [:]
        splitPanes.setHeld([:])
        dismissRestoreBanner()
        resolvePendingBindings()
    }

    /// The banner goes and the focused chat wakes; every other one wakes when its pane is gone to.
    func resumeParkedOneByOne() {
        dismissRestoreBanner()
        wakeParked(splitPanes.layout.focusedPane)
    }

    private func dismissRestoreBanner() {
        restoreBanner?.removeFromSuperview()
        restoreBanner = nil
    }

    /// Going to a parked pane — a press in it, a keyboard move onto it — is asking to see it.
    func wakeParked(_ paneID: PaneID) {
        guard let binding = parkedBindings.removeValue(forKey: paneID) else { return }
        pendingBindings[paneID] = binding
        splitPanes.setHeld(parkedBindings)
        if parkedBindings.isEmpty {
            dismissRestoreBanner()
        } else {
            restoreBanner?.setCount(parkedBindings.count)
        }
        resolvePendingBindings()
    }

    /// What the seatbelts sample each second: the panes as the governor ranks them, and the
    /// counts the flight recorder keeps.
    func seatbeltPanes() -> SeatbeltPanes {
        var seen = splitPanes.seatbeltPanes(held: heldSessions)
        seen.occluded = !(window?.occlusionState.contains(.visible) ?? false)
        return seen
    }

    /// The live chip's numbers and its place in the toolbar: shown once two chats can be counted,
    /// and only by a host that gives panes densities at all.
    func refreshLiveChip(_ decision: GovernorDecision?) {
        guard let tiles = splitPanes as? TileHost else {
            liveChipItem?.isHidden = true
            return
        }
        let counts = tiles.liveCounts
        liveChip.update(decision: decision, live: counts.live, chats: counts.chats)
        liveChipItem?.isHidden = !liveChip.isShown
    }

    /// What the chat list last heard about a conversation, for a paused pane and an overflow chip.
    func listFace(_ session: SplitPaneSession) -> (title: String, activity: ActivityKind?)? {
        guard
            let entry = sidebar.allEntries.first(where: {
                $0.profileID == session.profileID && $0.session.id == session.sessionID
            })
        else { return nil }
        let row = SessionRowModel(entry: entry, unreachable: false, unread: false, saved: false)
        return (row.title, row.state.activity)
    }

    /// The arrangement comes back before anything can stream into it, and how its chats come back
    /// is the safe restore's decision: staggered after a clean exit, parked behind the banner after
    /// an unclean one with three or more chats. The launch is recorded either way, so the ledger
    /// always describes the launch that is running.
    func restoreSplitLayout() {
        var bindings: [PaneID: SplitPaneSession] = [:]
        if let raw = UserDefaults.standard.string(forKey: SplitSnapshot.defaultsKey),
            let snapshot = SplitSnapshot.decode(raw)
        {
            bindings = splitPanes.restore(snapshot)
        }
        let plan = Seatbelts.shared.beginLaunch(chatPanes: bindings.count)
        guard case .parked = plan.mode else {
            pendingBindings = bindings
            return
        }
        park(bindings)
    }

    /// The focused pane changed — by keyboard, click, band, or a structural verb. The window
    /// title, the file tree, the terminal and the remembered last-session all follow the eye.
    func focusedPaneChanged() {
        let pane = transcript
        guard let entry = pane.currentEntry else {
            window?.title = "Tailscode"
            window?.subtitle = ""
            return
        }
        UserDefaults.standard.set(entry.session.id, forKey: "tailscode.lastSession")
        showTitle(of: entry)
        retargetTerminal(to: entry.session.directory)
    }

    /// The window wears the focused chat's name and server.
    func showTitle(of entry: SessionEntry) {
        window?.title =
            entry.session.hasPlaceholderTitle
            ? Localized.text("New conversation") : entry.session.title
        window?.subtitle = ServerLabel.display(name: entry.profileName, backend: entry.backendType)
    }

    /// A pane keeps the entry it was opened with, so a chat the server named after it arrived, or
    /// one renamed since, would wear its first title until the focus moved. The listing is what
    /// knows the current one, so every pane on screen is handed it — a rename, or a move of the
    /// model and level it runs on, whoever drove the turn — and what else reads a chat's title
    /// (the window, the overflow strip, the notice raised for it) follows the pane's.
    func refreshTitleFromListing() {
        var renamed = false
        splitPanes.eachPane { pane in
            guard let current = pane.currentEntry,
                let fresh = sidebar.allEntries.first(where: {
                    $0.profileID == current.profileID && $0.session.id == current.session.id
                }),
                pane.adopt(fresh)
            else { return }
            renamed = true
            guard pane === transcript, let adopted = pane.currentEntry else { return }
            showTitle(of: adopted)
        }
        let noticed = TileRuntime.shared.adoptTitles(from: sidebar.allEntries)
        if renamed || noticed { (splitPanes as? TileHost)?.refreshStrip() }
    }

    /// The marked chats opened all at once as one even tiling: the tree replaces what the window
    /// held — the gesture asked for these conversations — and the panes bind through the same
    /// machinery a launch restore uses, so a server that cannot answer right now resolves on the
    /// next refresh instead of failing the whole gesture.
    func openMarkedSplit(_ chosen: [SessionEntry], as arrangement: SplitArrangement) {
        guard let layout = SplitEven.layout(count: chosen.count, as: arrangement) else { return }
        var sessions: [String: SplitPaneSession] = [:]
        for (pane, entry) in zip(layout.paneIDs, chosen) {
            SessionSeenStore.markSeen(entry.session.id)
            sessions[pane.raw] = SplitPaneSession(
                profileID: entry.profileID, sessionID: entry.session.id)
        }
        pendingBindings = splitPanes.restore(SplitSnapshot(layout: layout, sessions: sessions))
        resolvePendingBindings()
        splitPanes.persist()
        focusedPaneChanged()
    }

    /// The row is the window's own arrangement, so pressing it goes to it rather than rebuilding
    /// it: the split is already on screen, and tearing down live streams to reopen the same chats
    /// would cost the reader exactly the panes they asked for.
    func restoreSplitTab(_ tab: SplitTab) {
        transcript.focusComposer()
        focusedPaneChanged()
    }

    /// A member pressed on the split's row: its pane is already on screen, so the press goes to
    /// it — focused, keyboard and all.
    func goToSplitMember(_ entry: SessionEntry) {
        guard let pane = splitPanes.pane(showing: entry.session.id) else {
            guard
                let profile = ServerDirectory.shared.profiles.first(where: {
                    $0.id == entry.profileID
                }), let backend = ServerDirectory.shared.backend(for: profile)
            else { return }
            handleOpen(entry, backend: backend)
            return
        }
        splitPanes.focus(pane, grabKeyboard: true)
        focusedPaneChanged()
    }

    /// The split taken apart in one gesture: every pane but the kept one closes, and the merged
    /// row separates back into the plain rows it stood for. Named a chat, the pane showing it is
    /// the one that inherits the window.
    func unsplit(keeping entry: SessionEntry?) {
        let keep = entry.flatMap { splitPanes.pane(showing: $0.session.id) } ?? splitPanes.active
        splitPanes.collapse(to: keep)
        focusedPaneChanged()
    }

    /// Opening a row into a fresh pane beside the ones already on screen: split, then run the
    /// same open path a sidebar click takes.
    func openInNewSplit(_ entry: SessionEntry) {
        guard
            let profile = ServerDirectory.shared.profiles.first(where: {
                $0.id == entry.profileID
            }), let backend = ServerDirectory.shared.backend(for: profile)
        else {
            setNotice(Localized.text("That server is not configured."))
            return
        }
        splitPanes.splitActive(axis: .horizontal)
        SessionSeenStore.markSeen(entry.session.id)
        handleOpen(entry, backend: backend)
    }
}
