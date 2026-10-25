import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension MainWindow {
    /// Normal mode owns the letters; focusing anything that takes text hands them back, and the
    /// terminal keeps everything but Ctrl+Shift and zoom. The composer key first goes to
    /// whichever pane's composer actually has focus, and that pane becomes the focused one before
    /// the key acts — so typing into a pane and commanding it are never two different panes.
    func installKeymap(on window: UnsafeMutablePointer<GtkWidget>) {
        let root = UInt(bitPattern: window)
        Gtk.onKey(window) { [weak self] keyval, state in
            guard let self, let base = UnsafeMutableRawPointer(bitPattern: root) else {
                return false
            }
            let window: UnsafeMutablePointer<GtkWidget> = ptr(base)
            if let taken = SheetStack.shared?.handleKey(keyval: keyval, state: state) {
                return taken
            }
            if self.agentsEntry?.ownsKey(keyval, state: state, in: window) == true { return false }
            if self.splitHost.orderedPanes.contains(where: {
                $0.brains.handleKey(keyval: keyval, state: state)
            }) {
                return true
            }
            if keyval == Keymap.escape,
                self.splitHost.orderedPanes.contains(where: { $0.rails.escape() })
            {
                return true
            }
            for pane in self.splitHost.orderedPanes where pane.composerHasFocus() {
                self.splitHost.focus(pane, grabKeyboard: false)
                if let handled = pane.handleComposerKey(keyval: keyval, state: state) {
                    return handled
                }
                break
            }
            guard let chord = KeyChord.canonical(keyval: keyval, state: state) else {
                return false
            }
            if self.pendingChords.isEmpty, Gtk.dividerOwnsKey(keyval, state: state, in: window) {
                return false
            }
            let context: KeyContext =
                self.terminal.ownsFocus(in: window)
                ? .terminal : Gtk.focusTakesText(window) ? .insert : .normal
            if self.activePane.chooserShown { self.followTerminal() }
            if context == .normal, self.focused == .transcript, self.pendingChords.isEmpty,
                self.activePane.handleChooserChord(chord)
            {
                return true
            }
            if self.pendingChords.isEmpty, self.activePane.handleWatchChord(chord) {
                return true
            }
            if context == .normal, self.focused == .transcript, self.pendingChords.isEmpty,
                self.activePane.handleVideoChord(chord)
            {
                return true
            }
            if self.focused == .transcript, self.pendingChords.isEmpty,
                self.activePane.handleWebChord(chord)
            {
                return true
            }
            if context == .normal, self.focused == .transcript, self.pendingChords.isEmpty,
                self.activePane.handlePreviewChord(chord)
            {
                return true
            }
            let awaiting =
                context == .normal
                && !(self.activePane.lastState?.pendingPermissions.isEmpty ?? true)
            let resolution = self.shortcuts.resolve(
                chord, context: context, pending: self.pendingChords, awaitingApproval: awaiting)
            switch resolution {
            case .run(let action):
                self.pendingChords = []
                return self.perform(action)
            case .pending(let chords):
                self.pendingChords = chords
                return true
            case .unbound:
                self.pendingChords = []
                return false
            }
        }
        if !shortcuts.issues.isEmpty {
            activePane.setNotice(
                Localized.text(
                    "Keybindings: %@", shortcuts.issues.joined(separator: " · ")))
        }
    }

    /// Re-reads the rebinding file and rebuilds everything derived from it, live: the resolver,
    /// every pane's cheatsheet, and the notice line if the file has something wrong in it.
    func reloadShortcuts(announce: Bool = true) {
        shortcuts = ShortcutSet.load()
        pendingChords = []
        splitHost.eachPane { $0.rebuildHelpOverlay() }
        if shortcuts.issues.isEmpty {
            if announce { toast(Localized.text("Shortcuts reloaded")) }
        } else {
            activePane.setNotice(
                Localized.text(
                    "Keybindings: %@", shortcuts.issues.joined(separator: " · ")))
        }
    }

    /// Ctrl+C over a selection means copy everywhere else on the desktop; only with nothing
    /// selected does the stop binding mean "stop the turn". Conversation verbs land on the
    /// focused pane; the split verbs work the tree itself.
    func perform(_ action: KeyAction) -> Bool {
        switch action {
        case .focus(let pane): focus(pane)
        case .cycleForward: focus(nextPane(after: focused, by: 1))
        case .cycleBackward: focus(nextPane(after: focused, by: -1))
        case .selectNext: move(by: 1)
        case .selectPrevious: move(by: -1)
        case .selectFirst: cursor = 0; openCursor()
        case .selectLast: cursor = max(0, visible.count - 1); openCursor()
        case .openSelected: openCursor()
        case .scrollDown: activePane.scroll(by: 60)
        case .scrollUp: activePane.scroll(by: -60)
        case .halfPageDown: activePane.scroll(byPages: 0.5)
        case .halfPageUp: activePane.scroll(byPages: -0.5)
        case .scrollTop: activePane.scroll(toEnd: false)
        case .scrollBottom: activePane.scroll(toEnd: true)
        case .previousPrompt: activePane.jumpPrompt(by: -1)
        case .nextPrompt: activePane.jumpPrompt(by: 1)
        case .copyLastAnswer: activePane.copyLastAnswer()
        case .insert:
            focus(.transcript)
            activePane.focusComposer()
        case .leaveInsert:
            if clearMarks() { return true }
            let pane = activePane
            if pane.findShown { pane.setFindShown(false) }
            pane.dismissCompletion()
            focused = .transcript
            pane.leaveComposer()
            pane.setHelp(false)
        case .search: gtk_widget_grab_focus(searchEntry)
        case .send: activePane.sendFromComposer()
        case .stop:
            if let window, let focused = tailscode_focused_widget(window),
                let selection = tailscode_label_selection(focused)
            {
                Gtk.copyToClipboard(String(cString: selection))
                g_free(selection)
                toast(Localized.text("Copied"))
            } else {
                activePane.stopTurn()
            }
        case .toggleHelp: activePane.setHelp(!activePane.helpShown)
        case .reload: Task { [weak self] in await self?.refresh() }
        case .allowOnce: activePane.respondToFirstPermission(.once)
        case .allowAlways: activePane.respondToFirstPermission(.always)
        case .deny: activePane.respondToFirstPermission(.reject)
        case .newChat: presentNewChat()
        case .toggleSaved:
            if let entry = activePane.entry { toggleSaved(entry) }
        case .findInConversation: activePane.setFindShown(true)
        case .zoomIn: UIScale.step(0.1)
        case .zoomOut: UIScale.step(-0.1)
        case .zoomReset: UIScale.reset()
        case .toggleSidebar: togglePane(.sidebar)
        case .toggleFiles: return false
        case .toggleTerminal: togglePane(.terminal)
        case .toggleAgents: toggleAgents()
        case .commandPalette: activePane.popupCommandPalette()
        case .effortHotter: activePane.stepEffort(by: 1)
        case .effortColder: activePane.stepEffort(by: -1)
        case .modelDial: activePane.openModelDial()
        case .presetNext: activePane.stepPreset(by: 1)
        case .presetPrevious: activePane.stepPreset(by: -1)
        case .preset(let number): activePane.takePreset(number: number)
        case .archiveSelected:
            if let entry = activePane.entry { toggleArchived(entry) }
        case .toggleArchiveView: setArchiveShown(!showingArchive)
        case .toggleUnreadSelected: toggleUnreadSelected()
        case .renameSelected:
            if let entry = activePane.entry, let backend = activePane.backend,
                backend.capabilities.supportsRenaming
            {
                presentRename(entry: entry, backend: backend)
            }
        case .forkSelected:
            if let entry = activePane.entry, let backend = activePane.backend,
                backend.capabilities.supportsForking
            {
                fork(entry: entry, backend: backend)
            }
        case .deleteSelected: deleteMarkedOrCursor()
        case .toggleMarked: toggleMarkAtCursor()
        case .toggleMarkAll: toggleMarkAll()
        case .copySessionID:
            if let entry = activePane.entry {
                Gtk.copyToClipboard(entry.session.id)
                toast(Localized.text("Copied"))
            }
        case .copyProjectPath:
            if let directory = activePane.entry?.session.directory {
                Gtk.copyToClipboard(directory)
                toast(Localized.text("Copied"))
            }
        case .splitPane(let axis):
            focused = .transcript
            splitHost.splitActive(axis: axis)
        case .splitAtTerminal(let axis):
            splitAtTerminal(axis: axis)
        case .closeSplit:
            splitHost.closeActive()
        case .focusSplit(let direction):
            focused = .transcript
            _ = splitHost.focusNeighbor(direction)
        case .zoomSplit:
            splitHost.zoomActive()
        case .equalizeSplits:
            splitHost.equalize()
        case .exchangeSplit:
            splitHost.exchangeActive()
        case .cycleSplit, .promoteSplit, .rotateSplits, .moveSplitToEdge, .resizeSplit,
            .arrangeSplits:
            focused = .transcript
            splitHost.perform(action)
        case .pinSplit:
            guard splitHost.supportsDensity else { return false }
            splitHost.togglePinActive()
        case .parkSplit:
            guard splitHost.supportsDensity else { return false }
            splitHost.toggleParkActive()
        case .toggleProjectScope:
            toggleProjectScope()
        case .quickAsk:
            presentQuickAsk()
        case .openSettings: presentSettings()
        case .openServers: presentServers()
        case .openUpdates: presentUpdates()
        case .openUsage: presentUsage()
        case .toggleAppearance: toggleAppearance()
        case .toggleCompactTools: toggleCompactTools()
        case .toggleVimComposer: toggleVimComposer()
        case .toggleFullscreen: toggleFullscreen()
        case .openChat(let number): openChat(number: number)
        }
        return true
    }

    /// The headless driver's chord: a registered sequence resolved through the same shortcut set a
    /// key press goes through, so a scripted `ctrl+w a` and a typed one are the same code path.
    func driveChords(_ spec: String) {
        guard let (_, chords) = KeySpec.parse(spec) else {
            FileHandle.standardOutput.write(Data("CHORD unreadable \(spec)\n".utf8))
            return
        }
        for chord in chords {
            switch shortcuts.resolve(
                chord, context: .normal, pending: pendingChords, awaitingApproval: false)
            {
            case .run(let action):
                pendingChords = []
                _ = perform(action)
            case .pending(let held):
                pendingChords = held
            case .unbound:
                pendingChords = []
            }
        }
        reportOrder("CHORD \(spec)")
    }

    /// The viewer sheet as the driver drives it. `open` or `open:<key or number>` raises it over the
    /// active conversation's pictures, `stage` over the Studio's picture; `next`, `prev`, `first`,
    /// `last`, `zoom`, `fit`, `in`, `out`, `actual`, `copy`, `save` and `close` are the viewer's own
    /// commands; `hold0.45` and `release` photograph the middle of its motion; `key:<chord>` sends a
    /// key through the same routing a typed one takes; `keys` names the pictures; and every verb
    /// answers with where the stack stands, so a script can read the order the sheets close in.
    func driveViewer(_ argument: String) {
        let stack = SheetStack.shared
        let viewer = MediaViewer.current
        switch argument {
        case "open":
            activePane.driverOpenGallery()
        case _ where argument.hasPrefix("open:"):
            let name = String(argument.dropFirst(5))
            let keys = activePane.galleryKeys
            let chosen = Int(name).flatMap { keys.indices.contains($0) ? keys[$0] : nil } ?? name
            activePane.driverOpenGallery(key: chosen)
        case "stage":
            StudioSheet.current?.imagePane?.openStage()
        case "keys":
            FileHandle.standardOutput.write(
                Data("VIEWERKEYS \(activePane.galleryKeys.joined(separator: " "))\n".utf8))
        case "next": viewer?.perform(.next)
        case "prev": viewer?.perform(.previous)
        case "first": viewer?.perform(.first)
        case "last": viewer?.perform(.last)
        case "zoom": viewer?.perform(.toggleZoom)
        case "fit": viewer?.perform(.fit)
        case "in": viewer?.perform(.zoomIn)
        case "out": viewer?.perform(.zoomOut)
        case "actual": viewer?.perform(.actualSize)
        case "copy": viewer?.perform(.copy)
        case "save": viewer?.perform(.save)
        case "close": viewer?.perform(.close)
        case "release": viewer?.sheetLayer.release()
        case _ where argument.hasPrefix("hold"):
            if let presence = Double(argument.dropFirst(4)) { viewer?.sheetLayer.hold(at: presence) }
        case _ where argument.hasPrefix("key:"):
            driveKey(String(argument.dropFirst(4)), through: stack)
        default:
            break
        }
        let toplevels = Int(g_list_model_get_n_items(gtk_window_get_toplevels()))
        FileHandle.standardOutput.write(
            Data(
                "VIEWER depth=\(stack?.depth ?? 0) chords=\(stack?.conversationChordsEnabled ?? true) toplevels=\(toplevels) studio=\(StudioSheet.shared?.state ?? .closed) viewer=\(viewer?.summary ?? "-")\n"
                    .utf8))
    }

    /// A key sent through the stack the way the window's own controller sends one, so the order the
    /// sheets answer in is the order a person would find.
    func driveKey(_ spec: String, through stack: SheetStack?) {
        let keyval: UInt32
        var state: UInt32 = 0
        switch spec {
        case "esc": keyval = Keymap.escape
        case "left": keyval = 0xFF51
        case "right": keyval = 0xFF53
        case "home": keyval = 0xFF50
        case "end": keyval = 0xFF57
        case "space": keyval = 0x20
        case "ctrl+w":
            keyval = 0x77
            state = KeyChord.controlMask
        case "ctrl+c":
            keyval = 0x63
            state = KeyChord.controlMask
        case "ctrl+s":
            keyval = 0x73
            state = KeyChord.controlMask
        case "ctrl+1":
            keyval = 0x31
            state = KeyChord.controlMask
        default: keyval = spec.unicodeScalars.first.map { UInt32($0.value) } ?? 0
        }
        let taken = stack?.handleKey(keyval: keyval, state: state)
        FileHandle.standardOutput.write(
            Data("VKEY \(spec) taken=\(taken.map { "\($0)" } ?? "conversation")\n".utf8))
    }

    /// The tree as the driver reads it: how many panes, what shape, which holds the focus and in
    /// what reading order, by the first characters of each pane's id.
    func reportOrder(_ label: String) {
        let layout = splitHost.layout
        let order = layout.paneIDs.map { String($0.raw.prefix(4)) }.joined(separator: ",")
        let focus = layout.paneIDs.firstIndex(of: layout.focusedPane) ?? -1
        FileHandle.standardOutput.write(
            Data(
                "\(label) panes=\(layout.paneCount) shape=\(SplitEven.shape(of: layout)) focus=\(focus) zoom=\(layout.zoomedPane != nil) order=\(order)\n"
                    .utf8))
    }

    /// A divider key without a keyboard: divider `index` takes focus and the key the second
    /// field names (`left`, `right`, `shift+left`, `home`, `end`) moves it.
    func driveDividerKey(_ argument: String) {
        let fields = argument.split(separator: ",").map(String.init)
        let index = Int(fields.first ?? "") ?? 0
        let word = fields.count > 1 ? fields[1] : "right"
        let key: DividerKey
        switch word {
        case "left", "up": key = .back(large: false)
        case "shift+left", "shift+up": key = .back(large: true)
        case "right", "down": key = .forward(large: false)
        case "shift+right", "shift+down": key = .forward(large: true)
        case "home": key = .lowest
        default: key = .highest
        }
        let moved = splitHost.driveDivider(index, key: key)
        FileHandle.standardOutput.write(Data("DIVKEY \(index) \(word) moved=\(moved)\n".utf8))
    }

    /// A pane strip dragged onto another pane: `target,u,v,source` are the target pane's index,
    /// where in it the pointer is as a fraction, and the dragged pane's index.
    func drivePaneDrag(_ argument: String, drop: Bool) {
        let fields = argument.split(separator: ",").map(String.init)
        let target = Int(fields.first ?? "") ?? 0
        let u = Double(fields.count > 1 ? fields[1] : "0.5") ?? 0.5
        let v = Double(fields.count > 2 ? fields[2] : "0.5") ?? 0.5
        let source = Int(fields.count > 3 ? fields[3] : "0") ?? 0
        let panes = splitHost.orderedPanes
        guard panes.indices.contains(target), panes.indices.contains(source) else {
            FileHandle.standardOutput.write(Data("PDROP no-target\n".utf8))
            return
        }
        let pane = panes[target]
        let x = u * Double(gtk_widget_get_width(pane.frame))
        let y = v * Double(gtk_widget_get_height(pane.frame))
        if drop {
            let took = splitHost.receivePaneDrop(
                PaneMovePayload(pane: panes[source].id).encoded, on: pane.id, x: x, y: y)
            FileHandle.standardOutput.write(
                Data("PDROP took=\(took) panes=\(splitHost.paneCount)\n".utf8))
        } else {
            splitHost.hover(pane, moving: panes[source].id, x: x, y: y)
            FileHandle.standardOutput.write(
                Data("PDRAG \(splitHost.dropSummary) caption=\(splitHost.dropCaptionText)\n".utf8))
        }
    }

    /// One key walks in and out of a project: scoped, `p` restores the whole list; unscoped, it
    /// reads the project off the row under the cursor — or the conversation on screen when the
    /// cursor has nothing — and the sidebar becomes that project's own board.
    func toggleProjectScope() {
        guard projectScope == nil else { return setProjectScope(nil) }
        let entry =
            cursor < visible.count ? visible[cursor].lead?.entry : activePane.entry
        guard let entry else { return }
        setProjectScope(ProjectScope(of: entry))
    }

    func setProjectScope(_ scope: ProjectScope?) {
        projectScope = scope
        lastSidebar = nil
        renderSidebar()
        FileHandle.standardOutput.write(
            Data("SCOPE \(scope.map(\.name) ?? "off")\n".utf8))
    }

    /// `x` means every marked chat when any are marked and the row under the cursor when none are
    /// — one key, so a selection never needs a second gesture to be spent. The single-row path
    /// keeps its own confirm, which names the server the chat is being taken from; it must never
    /// silently delete whatever a background pane was holding.
    func deleteMarkedOrCursor() {
        guard marks.isEmpty else {
            perform(bulk: .delete)
            return
        }
        guard cursor < visible.count, let entry = visible[cursor].lead?.entry else { return }
        Task { [weak self] in
            let profiles = await ServerDirectory.shared.profiles()
            guard let profile = profiles.first(where: { $0.id == entry.profileID }),
                let backend = await ServerDirectory.shared.backend(for: profile)
            else { return }
            Gtk.onMain { [weak self] in
                self?.presentDelete(entry: entry, backend: backend)
            }
        }
    }

    func toggleUnreadSelected() {
        guard let entry = activePane.entry else { return }
        let unread = SessionSeenStore.unreadEvaluator()(entry.session.id, entry.session.updatedAt)
        if unread {
            SessionSeenStore.markSeen(entry.session.id)
        } else {
            SessionSeenStore.markUnread(entry.session.id, updatedAt: entry.session.updatedAt)
        }
        renderSidebar()
    }

    func nextPane(after pane: Pane, by delta: Int) -> Pane {
        let all = Pane.allCases
        let index = (all.firstIndex(of: pane) ?? 0) + delta
        return all[(index % all.count + all.count) % all.count]
    }

    func focus(_ pane: Pane) {
        focused = pane
        if pane != .transcript { activePane.dismissCompletion() }
        switch pane {
        case .chats:
            gtk_widget_grab_focus(sidebarList)
            revealCursorRow()
        case .transcript:
            followTerminal()
            activePane.focusTranscript()
        case .files: return
        case .terminal: terminal.takeFocus()
        }
    }

    func move(by delta: Int) {
        guard !visible.isEmpty else { return }
        cursor = max(0, min(visible.count - 1, cursor + delta))
        if cursor >= sidebarLimit { sidebarLimit = cursor + 60 }
        openCursor()
        revealCursorRow()
    }

    func openCursor() {
        guard cursor < visible.count else { return }
        openItem(visible[cursor])
    }
}
