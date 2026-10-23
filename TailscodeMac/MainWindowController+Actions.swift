import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

extension MainWindowController {
    /// A two-second floating confirmation — the answer to "did my click do anything". Presented
    /// by the hub so every child's toast lands in the same queue.
    func toast(_ text: String) {
        toasts.show(text)
    }

    /// The single key a binding puts an action on right now, overrides included, for a menu item
    /// to show — so a chord rebound in the keybindings file is the chord the menu names. A
    /// sequence has no menu spelling and is left off.
    func boundChord(for action: KeyAction) -> KeyChord? {
        Self.boundChord(for: action, in: shortcuts)
    }

    /// The keys a shortcut is on right now, overrides included, spelled as the cheatsheet spells
    /// them — what a menu item shows for a verb whose binding is a sequence.
    func shortcutKeys(for id: String) -> String? {
        let keys = shortcuts.effective[id] ?? []
        return keys.isEmpty ? nil : keys.joined(separator: " / ")
    }

    /// The menu bar's Delete, which like Save, Archive and Rename answers for the chat that is
    /// open rather than for the list's cursor; marked chats still outrank it, the number having
    /// been read in the menu's title. The `x` key keeps the cursor's meaning.
    func deleteOpenChat() {
        if sidebar.markedCount > 0 {
            sidebar.presentDeleteFromKeyboard()
            return
        }
        guard let currentEntry, let currentBackend else { return }
        sidebar.presentDelete(entry: currentEntry, backend: currentBackend)
    }

    /// Rebuilds the panes as the arrangement a menu item named.
    func arrangeSplits(_ arrangement: SplitArrangement) {
        focused = .transcript
        splitPanes.arrange(arrangement)
    }

    /// Insert is asked first, then the contexts a verb like Keep Live lives in alone. Outside
    /// insert a chord must carry control or option to be shown: a bare key bound for the normal
    /// context would become a menu key equivalent and take that letter from every text field.
    static func boundChord(for action: KeyAction, in shortcuts: ShortcutSet) -> KeyChord? {
        for context in [KeyContext.insert, .normal, .terminal] {
            let map = shortcuts.actions[context] ?? [:]
            let tokens = map.filter { $0.value == action && !$0.key.contains(",") }.keys.sorted()
            for token in tokens {
                guard let colon = token.firstIndex(of: ":"),
                    let keyval = UInt32(token[token.index(after: colon)...])
                else { continue }
                let flags = token[..<colon]
                if context != .insert, !flags.contains("c"), !flags.contains("a") { continue }
                var state: UInt32 = 0
                if flags.contains("c") { state |= KeyChord.controlMask }
                if flags.contains("s") { state |= KeyChord.shiftMask }
                if flags.contains("a") { state |= KeyChord.altMask }
                return KeyChord.canonical(keyval: keyval, state: state)
            }
        }
        return nil
    }

    /// The dial's answers to a control turned in quick steps — a wheel notch, a preset chord — each
    /// replacing the last rather than queueing behind it, so five notches are one sentence that
    /// keeps up and not ten seconds of sentences that lag.
    func dialToast(_ text: String) {
        toasts.show(text, replacing: "dial")
    }

    func setNotice(_ text: String) {
        transcript.setNotice(text)
    }

    /// Re-reads the rebinding file and rebuilds everything derived from it, live: the resolver,
    /// the cheatsheet if it is open, and the notice line if the file has something wrong in it.
    func reloadShortcuts() {
        shortcuts = ShortcutSet.load()
        pendingChords = []
        onShortcutsReloaded?()
        NotificationCenter.default.post(name: Self.shortcutsDidReload, object: nil)
        if let cheatsheet, cheatsheet.isVisible {
            cheatsheet.close()
            presentCheatsheet()
        }
        if shortcuts.issues.isEmpty {
            toast(Localized.text("Shortcuts reloaded"))
        } else {
            setNotice(
                Localized.text("Keybindings: %@", shortcuts.issues.joined(separator: " · ")))
        }
    }

    /// Everything the keyboard can mean, one switch. A verb aimed at a hidden pane declines,
    /// returning false so the keystroke falls through instead of being swallowed by a promise.
    @discardableResult
    func perform(_ action: KeyAction) -> Bool {
        switch action {
        case .focus(let pane):
            return focus(pane)
        case .toggleFiles:
            return false
        case .cycleForward:
            cycle(1)
        case .cycleBackward:
            cycle(-1)
        case .selectNext:
            sidebar.move(by: 1)
        case .selectPrevious:
            sidebar.move(by: -1)
        case .selectFirst:
            sidebar.selectFirst()
        case .selectLast:
            sidebar.selectLast()
        case .openSelected:
            sidebar.openCursor()
        case .search:
            sidebar.focusFilter()
        case .insert:
            focused = .transcript
            transcript.focusComposer()
        case .leaveInsert:
            if sidebar.clearMarks() { return true }
            transcript.setFindShown(false)
            transcript.composer.dismissCompletion()
            window?.makeFirstResponder(nil)
            closeCheatsheet()
        case .toggleSaved:
            guard let currentEntry else { return true }
            sidebar.toggleSaved(currentEntry)
        case .archiveSelected:
            guard let currentEntry else { return true }
            sidebar.toggleArchived(currentEntry)
        case .toggleArchiveView:
            sidebar.setArchiveShown(!sidebar.showingArchive)
        case .toggleUnreadSelected:
            guard let currentEntry else { return true }
            sidebar.toggleUnread(currentEntry)
        case .renameSelected:
            guard let currentEntry, let currentBackend,
                currentBackend.capabilities.supportsRenaming
            else { return true }
            sidebar.presentRename(entry: currentEntry, backend: currentBackend)
        case .forkSelected:
            guard let currentEntry, let currentBackend,
                currentBackend.capabilities.supportsForking
            else { return true }
            sidebar.fork(entry: currentEntry, backend: currentBackend)
        case .toggleMarked:
            sidebar.toggleMarkUnderCursor()
        case .toggleMarkAll:
            sidebar.toggleMarkAllShown()
        case .deleteSelected:
            sidebar.presentDeleteFromKeyboard()
        case .copySessionID:
            guard let currentEntry else { return true }
            copyToPasteboard(currentEntry.session.id)
        case .copyProjectPath:
            guard let directory = currentEntry?.session.directory else { return true }
            copyToPasteboard(directory)
        case .toggleSidebar:
            togglePane(.sidebar)
        case .toggleTerminal:
            #if !TAILSCODE_MAS
                togglePane(.terminal)
            #endif
        case .toggleHelp:
            toggleCheatsheet()
        case .newChat:
            presentNewChat()
        case .reload:
            Task { [weak self] in await self?.sidebar.refresh() }
        case .scrollDown:
            transcript.scrollBy(60)
        case .scrollUp:
            transcript.scrollBy(-60)
        case .halfPageDown:
            transcript.scrollByPages(0.5)
        case .halfPageUp:
            transcript.scrollByPages(-0.5)
        case .scrollTop:
            transcript.scrollToTop()
        case .scrollBottom:
            transcript.scrollToBottom()
        case .previousPrompt:
            transcript.scrollToPrompt(-1)
        case .nextPrompt:
            transcript.scrollToPrompt(1)
        case .copyLastAnswer:
            transcript.copyLastAnswer()
        case .findInConversation:
            transcript.setFindShown(true)
        case .allowOnce:
            transcript.respondToFirstPermission(.once)
        case .allowAlways:
            transcript.respondToFirstPermission(.always)
        case .deny:
            transcript.respondToFirstPermission(.reject)
        case .stop:
            if let text = window?.firstResponder as? NSText, text.selectedRange.length > 0 {
                text.copy(nil)
                toast(Localized.text("Copied"))
            } else {
                transcript.stopTurn()
            }
        case .send:
            transcript.composer.sendNow()
        case .commandPalette:
            transcript.composer.openCommandPalette()
        case .effortHotter:
            transcript.composer.stepEffort(by: 1)
        case .effortColder:
            transcript.composer.stepEffort(by: -1)
        case .modelDial:
            transcript.composer.openModelDial()
        case .presetNext:
            transcript.composer.stepPreset(by: 1)
        case .presetPrevious:
            transcript.composer.stepPreset(by: -1)
        case .preset(let number):
            transcript.composer.applyPreset(number: number)
        case .zoomIn:
            MacTheme.UIScale.step(0.1)
            applyUIScale()
        case .zoomOut:
            MacTheme.UIScale.step(-0.1)
            applyUIScale()
        case .zoomReset:
            MacTheme.UIScale.reset()
            applyUIScale()
        case .splitPane(let axis):
            focused = .transcript
            splitPanes.splitActive(axis: axis)
        case .splitAtTerminal:
            #if TAILSCODE_MAS
                return false
            #else
                toast(TerminalSplit.Refusal.oneCommandAtATime.words)
            #endif
        case .closeSplit:
            splitPanes.closeActive()
        case .focusSplit(let direction):
            focused = .transcript
            splitPanes.focusNeighbor(direction)
        case .zoomSplit:
            splitPanes.zoomActive()
        case .equalizeSplits:
            splitPanes.equalize()
        case .exchangeSplit:
            splitPanes.exchangeActive()
        case .cycleSplit(let forward):
            guard splitPanes.paneCount > 1 else { return false }
            focused = .transcript
            splitPanes.cycleFocus(forward: forward)
        case .promoteSplit:
            guard splitPanes.paneCount > 1 else { return false }
            focused = .transcript
            splitPanes.promoteActive()
        case .rotateSplits(let forward):
            guard splitPanes.paneCount > 1 else { return false }
            focused = .transcript
            splitPanes.rotate(forward: forward)
        case .moveSplitToEdge(let edge):
            guard splitPanes.paneCount > 1 else { return false }
            focused = .transcript
            splitPanes.moveActiveToEdge(edge)
        case .resizeSplit(let direction):
            guard splitPanes.paneCount > 1 else { return false }
            focused = .transcript
            splitPanes.resizeActive(direction, large: false)
        case .arrangeSplits:
            guard splitPanes.paneCount > 1 else { return false }
            focused = .transcript
            splitPanes.arrange(nil)
        case .pinSplit:
            guard splitPanes.supportsDensity, splitPanes.paneCount > 1 else { return false }
            splitPanes.togglePinActive()
            refreshLiveChip(Seatbelts.shared.decision)
        case .parkSplit:
            guard splitPanes.supportsDensity, splitPanes.paneCount > 1 else { return false }
            splitPanes.toggleParkActive()
            refreshLiveChip(Seatbelts.shared.decision)
        case .toggleProjectScope:
            sidebar.toggleProjectScope(fallback: currentEntry)
        case .quickAsk:
            presentQuickAsk()
        }
        return true
    }

    /// Every fact on the band answers to the same verbs a person would reach for — on the pane
    /// whose band was clicked, which the click also focuses.
    func perform(bandAction action: StatusFacts.Action, on pane: TranscriptViewController) {
        splitPanes.focus(pane, grabKeyboard: false)
        switch action {
        case .stop:
            pane.stopTurn()
        case .compact:
            pane.presentCompactPreflight()
        case .goal:
            pane.presentGoalSheet()
        case .scrollToPending:
            pane.scrollToBottom()
        case .scrollToAgents:
            pane.scrollToNewestAgent()
        case .agent(let id):
            pane.scrollToAgent(id)
        case .spend:
            presentSpend(for: pane)
        case .range:
            presentRange(for: pane)
        case .git:
            presentGit(for: pane)
        case .reconnect:
            pane.reconnect()
        }
    }

    /// The account behind the price, in a popover off the band itself — the number is where the
    /// question was asked, so the answer belongs there rather than in a window of its own.
    func presentSpend(for pane: TranscriptViewController) {
        guard let spend = pane.spend else { return }
        spendPopover?.close()
        let panel = SpendPanelViewController(
            spend: spend, title: pane.currentEntry?.session.title ?? Localized.text("This conversation"))
        let popover = NSPopover()
        popover.behavior = .transient
        popover.ground(panel)
        let anchor = pane.bandAnchor
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        spendPopover = popover
    }

    /// The range of the conversation, off the band itself: which tank runs out first and the tanks
    /// behind it, with Compact as the one thing it offers to do — through the pane's ordinary
    /// preflight — and a press on what fills the window taking the transcript to it.
    private func presentRange(for pane: TranscriptViewController) {
        guard let snapshot = pane.rangeSnapshot() else { return }
        contextPopover?.close()
        let canCompact = pane.canCompact
        let panel = RangePanelViewController(
            title: pane.currentEntry?.session.title ?? Localized.text("This conversation"),
            snapshot: snapshot, read: { [weak pane] in pane?.rangeSnapshot() },
            compact: canCompact
                ? { [weak self, weak pane] in
                    self?.contextPopover?.close()
                    pane?.presentCompactPreflight()
                } : nil,
            reveal: { [weak self, weak pane] item in
                self?.contextPopover?.close()
                pane?.scrollToMessage(item.messageID, part: item.id)
            })
        let popover = NSPopover()
        popover.behavior = .transient
        popover.ground(panel)
        let anchor = pane.bandAnchor
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        contextPopover = popover
        rangePanel = panel
        rangePane = pane
    }

    /// The repository behind the branch on the band, in a popover off the band itself. A path or a
    /// commit inside it opens in a window, because a diff outlives the popover that offered it.
    func presentGit(for pane: TranscriptViewController) {
        guard let git = pane.git, let backend = pane.gitBackend, let entry = pane.currentEntry
        else { return }
        gitPopover?.close()
        let directory = entry.session.directory
        let sessionID = entry.session.id
        let panel = GitPanelViewController(
            state: git, title: entry.session.title,
            patch: { row in
                try? await backend.gitPatch(
                    directory: directory, sessionID: sessionID, path: row.path, staged: row.staged)?
                    .patch
            },
            commit: { commit in
                try? await backend.gitCommit(
                    directory: directory, sessionID: sessionID, hash: commit.hash)?.patch
            },
            openDiff: { [weak self] title, subtitle, load in
                self?.gitPopover?.close()
                let window = GitDiffWindowController(title: title, subtitle: subtitle, load: load)
                self?.gitDiffWindows.append(window)
                window.onClose = { [weak self, weak window] in
                    self?.gitDiffWindows.removeAll { $0 === window }
                }
                window.present()
            })
        let popover = NSPopover()
        popover.behavior = .transient
        popover.ground(panel)
        let anchor = pane.bandAnchor
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        gitPopover = popover
    }

    #if DEBUG
        /// The first staged file's diff, opened beside the popover instead of replacing it — the two
        /// facts a picture of the repository wants together, which a press can only show one at a time.
        func presentDemoDiff(for pane: TranscriptViewController) {
            guard let backend = pane.gitBackend, let entry = pane.currentEntry else { return }
            let directory = entry.session.directory
            let sessionID = entry.session.id
            let path = "Sources/Pulse/Socket/Reconnect.swift"
            let window = GitDiffWindowController(
                title: "Reconnect.swift", subtitle: "Sources/Pulse/Socket · staged",
                load: {
                    try? await backend.gitPatch(
                        directory: directory, sessionID: sessionID, path: path, staged: true)?
                        .patch
                })
            gitDiffWindows.append(window)
            window.onClose = { [weak self, weak window] in
                self?.gitDiffWindows.removeAll { $0 === window }
            }
            window.present()
        }
    #endif
}
