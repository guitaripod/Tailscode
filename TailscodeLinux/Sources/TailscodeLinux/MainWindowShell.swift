import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension MainWindow {
    /// The update centre, held the same way the server screen is: a second ask raises the window
    /// already open rather than stacking a second copy of a screen following a live update.
    func presentUpdates() {
        UpdatePanel.present(parent: sidebarPane)
    }

    func presentClock() {
        MeridianSheet.present(parent: sidebarPane)
    }

    /// The mark, drawn from what this device already knew. It says one thing and holds still unless
    /// something is actually being installed — an update that exists is a settled fact, and
    /// stillness is what tells a reader the app is not busy on their behalf. There is no dismiss
    /// gesture here and no other one anywhere: setting an offer aside happens inside the update
    /// centre, against that exact offer.
    ///
    /// The glyph is the rollup's own icon; the word and the tone the glyph turns are the chip's —
    /// a chip that says "Update" holds still even while another machine updates in the background,
    /// because a spinning arrow beside that word would read as the download it is not.
    func renderUpdates() {
        let rollup = UpdateLedger.rollup()
        guard let chip = rollup.chip else {
            ActivityPulse.stop(updateGlyph)
            gtk_widget_set_visible(updateBox, 0)
            return
        }
        let icon = ActivityIcon(
            symbol: rollup.icon.symbol, glyph: rollup.icon.glyph, cycle: rollup.icon.cycle,
            tone: chip.tone, motion: chip.motion)
        gtk_label_set_text(op(updateGlyph), icon.glyph)
        Gtk.setTone(updateGlyph, icon.glyphCSS, from: Self.updateTones)
        ActivityPulse.apply(icon, to: updateGlyph)
        gtk_label_set_text(op(updateHeadline), chip.title)
        gtk_widget_set_tooltip_text(updateBox, rollup.accessibilityLine())
        gtk_widget_set_visible(updateBox, 1)
    }

    static let updateTones = ActivityTone.allCases.map(\.glyphCSS)

    /// Every answer any machine gives, and every change to what this device is asking or
    /// following right now, redraws the mark — and is written through to the settings file,
    /// because `UserDefaults` on Linux is keyed to the running executable and a mark that lived
    /// only there would evaporate on exactly the install it exists to talk about.
    func observeUpdates() {
        for name in [UpdateLedger.didChange, UpdateDriver.didChange] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: nil) {
                [weak self] _ in
                Gtk.onMain { [weak self] in
                    SettingsFile.capture()
                    self?.renderUpdates()
                }
            }
        }
    }

    /// The app standing aside for the build that replaces it. `g_application_quit` does not fire
    /// `close-request`, so everything typed into a composer is written down here or it is lost —
    /// and this is the only thing in the update that closes a window, which is why it happens at
    /// the restart rather than at the press.
    func quitForUpdate() {
        quitCleanly()
    }

    /// The process was asked to stop — by an update, by the installer or systemd sending
    /// `SIGTERM`, or by a session ending — and leaves the way a person closing the window does:
    /// drafts written down and the launch recorded as a clean exit. Cut down instead, the next
    /// launch reads an ordinary stop as a crash, and two in a row floor the governor at *loaded*
    /// for ten minutes, which turns the written-not-pasted reveal into text that lands in lumps.
    func quitCleanly() {
        guard !Gtk.isQuitting else { return }
        stashDrafts()
        DraftStore.flush()
        SettingsFile.flush()
        SessionListCache.flushEnqueuedSave()
        Seatbelts.shared.exitClean()
        Gtk.markQuitting()
        tearDown()
        g_application_quit(ptr(app))
    }

    /// The main window is being destroyed. The application holds nothing open of its own, so the
    /// last window going is the process ending: the loop is told to run nothing more for Swift.
    /// With another window still up the process lives on, and only this window's work stops.
    func windowDestroyed() {
        tearDown()
        guard !otherWindowsStanding() else { return }
        Gtk.markQuitting()
    }

    func otherWindowsStanding() -> Bool {
        let own = window.map { UnsafeMutableRawPointer($0) }
        var node = gtk_application_get_windows(ptr(UnsafeMutableRawPointer(app)))
        while let current = node {
            if let data = current.pointee.data, data != own { return true }
            node = current.pointee.next
        }
        return false
    }

    /// Ends everything the window started that would otherwise keep running into widgets that are
    /// going: the polling tasks, the list streams, the quota and update and clock clocks, the
    /// governor's tick, every pane's clock and the first-fill backfill. Safe to repeat, and safe
    /// after the widgets are gone, because it touches none.
    func tearDown() {
        guard !tornDown else { return }
        tornDown = true
        refreshTask?.cancel()
        refreshTask = nil
        usageTask?.cancel()
        usageTask = nil
        searchTask?.cancel()
        searchTask = nil
        watchCheck?.cancel()
        watchCheck = nil
        for task in listStreamTasks.values { task.cancel() }
        listStreamTasks.removeAll()
        Seatbelts.shared.stop()
        UpdateWatch.stop()
        ClockWatch.shared.stop()
        if let tile = splitHost as? TileHost {
            tile.onDensityChanged = nil
            tile.eachPane { $0.quiesce() }
        }
        FillTurns.cancelAll()
    }

    /// The chord summons one entry and nothing else; the words land in the focused pane as a new
    /// conversation with no project directory. The pane's queued first message goes out the
    /// moment the mint's own open() has built the conversation, and a mint that fails takes the
    /// words back so the next chat this pane opens cannot inherit them.
    /// A question that arrived from somewhere else on the desktop. The window comes forward first
    /// because the composer is inside it: a summon that opened a text field behind another app's
    /// window would take the keystrokes that followed with it.
    func summonQuickAsk() {
        raise()
        if QuickAskWindow.open != nil { return }
        presentQuickAsk()
    }

    func presentQuickAsk() {
        let pane = activePane
        let fallback = pane.entry?.profileID
        Task { [weak self] in
            let profiles = await ServerDirectory.shared.profiles()
            var gathered: [String: [String]] = [:]
            var grammar: [String: Bool] = [:]
            for profile in profiles {
                let backend = await ServerDirectory.shared.backend(for: profile)
                gathered[profile.id] = backend?.reasoningEffortOptions ?? []
                grammar[profile.id] = backend?.resolvesCommandsFromPromptText == true
            }
            let efforts = gathered
            let promptTextGrammar = grammar
            Gtk.onMain { [weak self] in
                guard let self else { return }
                guard !profiles.isEmpty else {
                    self.presentServers()
                    return
                }
                QuickAskWindow.present(
                    servers: profiles, agentEfforts: efforts,
                    promptTextGrammar: promptTextGrammar, preferredServer: fallback,
                    recents: self.entries,
                    parent: self.window,
                    onAsk: { [weak self] profileID, send, attachments, done in
                        Gtk.onMain { [weak self] in
                            self?.createChat(
                                onProfileID: profileID, directory: nil, into: pane,
                                firstMessage: send, attachments: attachments, quickAsk: true,
                                done: done)
                        }
                    },
                    onResume: { [weak self] entry in
                        Gtk.onMain { [weak self] in
                            guard let self else { return }
                            pane.open(entry)
                            self.renderSidebar()
                        }
                    })
            }
        }
    }

    /// Every pane closes: the chat list collapses into the split view, the file tree and the
    /// terminal give their space back to the conversation. The choice survives relaunch.
    enum ClosablePane: String, CaseIterable {
        case sidebar
        case files
        case terminal

        var key: String { "tailscode.pane.\(rawValue)" }

        var isShown: Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }

        init(_ pane: SettingsContext.Pane) {
            switch pane {
            case .sidebar: self = .sidebar
            case .terminal: self = .terminal
            }
        }
    }

    func paneShown(_ pane: ClosablePane) -> Bool { pane.isShown }

    /// A terminal someone just opened is a terminal they want to type into; focus follows the
    /// reveal, on idle so the widget is on screen by the time focus lands.
    func togglePane(_ pane: ClosablePane) {
        SettingsFile.set(!paneShown(pane), forKey: pane.key)
        applyPane(pane)
        if pane == .terminal, paneShown(.terminal) {
            Gtk.onMain { [weak self] in self?.focus(.terminal) }
        }
    }

    func applyPane(_ pane: ClosablePane) {
        let shown = paneShown(pane)
        switch pane {
        case .files:
            return
        case .sidebar:
            guard let sidebarPane else { return }
            gtk_widget_set_visible(sidebarPane, shown ? 1 : 0)
        case .terminal:
            gtk_widget_set_visible(terminal.widget, shown ? 1 : 0)
        }
    }

    func applyPanePreferences() {
        for pane in ClosablePane.allCases { applyPane(pane) }
        applyLayoutPreferences()
    }

    /// Everything the settings window can change that is not a colour: the window's own pane
    /// sizes here, and each conversation pane restyling itself.
    func applyLayoutPreferences() {
        if let splitWidget {
            gtk_paned_set_position(op(splitWidget), Preferences.divider(.sidebar) ?? 300)
        }
        if let terminalPaned {
            gtk_paned_set_position(op(terminalPaned), Preferences.divider(.terminal) ?? 600)
        }
        terminal.setFontScale(Preferences.terminalScale)
        terminal.applyPalette(MatrixTheme.palette)
        orb.applyTheme()
        ClockWatch.shared.themeChanged()
        videoRing?.retheme()
        splitHost.eachPane { $0.applyLayoutPreferences() }
        splitHost.applyRatios()
    }

    /// The desktop's dark preference flipped: reload the stylesheet for the other palette and let
    /// every pane re-derive its rows, whose prose markup carries the palette's colors baked in.
    func retheme() {
        MatrixTheme.install()
        terminal.applyPalette(MatrixTheme.palette)
        splitHost.eachPane { $0.retheme() }
        studioSheet?.rethemed()
    }

    /// The width the chat list may never fall under, and the reason the sidebar is allowed to be
    /// squeezed below what it naturally wants at all: a list whose rows carry a pill that comes and
    /// goes has a natural width that comes and goes with it, and a divider GTK is free to push out
    /// to that width moves the whole tiling tree every time a chat starts or stops answering. So
    /// the divider is exactly where it was put, and the floor is held here rather than by the rows.
    static let sidebarFloor: Int32 = 190

    func holdSidebarFloor() {
        fitSidebarTitle()
        fitUsageStrip()
        Gtk.after(60) { [weak self] in self?.fitSidebarTitle() }
        guard let splitWidget else { return }
        let position = gtk_paned_get_position(op(splitWidget))
        guard position < Self.sidebarFloor, gtk_widget_get_width(splitWidget) > 400 else { return }
        gtk_paned_set_position(op(splitWidget), Self.sidebarFloor)
    }

    /// The dividers are read back rather than watched: a size saved a few seconds after the drag
    /// is indistinguishable from one saved during it. A position saved on a wide window would
    /// leave nothing for the other pane on a narrow one, so every divider is pulled back inside
    /// the window it is actually in before it is saved.
    func clampDividers() {
        for paned in [splitWidget].compactMap({ $0 }) {
            let width = gtk_widget_get_width(paned)
            guard width > 400 else { continue }
            let position = gtk_paned_get_position(op(paned))
            let ceiling = width - 200
            if position > ceiling { gtk_paned_set_position(op(paned), ceiling) }
        }
        if let terminalPaned {
            let height = gtk_widget_get_height(terminalPaned)
            guard height > 300 else { return }
            let position = gtk_paned_get_position(op(terminalPaned))
            if position > height - 120 { gtk_paned_set_position(op(terminalPaned), height - 120) }
        }
    }

    /// The window's own shape, read back on the same slow tick as the dividers.
    func rememberWindow() {
        guard let window else { return }
        let maximized = gtk_window_is_maximized(ptr(window)) != 0
        Preferences.setWindowMaximized(maximized)
        guard !maximized else { return }
        Preferences.setWindowSize(
            width: gtk_widget_get_width(window), height: gtk_widget_get_height(window))
    }

    func rememberDividers() {
        clampDividers()
        fitSidebarTitle()
        fitUsageStrip()
        rememberWindow()
        Preferences.setLastSession(activePane.sessionID)
        if let splitWidget, gtk_widget_get_visible(sidebarPane ?? splitWidget) != 0 {
            Preferences.setDivider(.sidebar, position: gtk_paned_get_position(op(splitWidget)))
        }
        if let terminalPaned, gtk_widget_get_visible(terminal.widget) != 0 {
            Preferences.setDivider(.terminal, position: gtk_paned_get_position(op(terminalPaned)))
        }
        splitHost.captureRatios()
        splitHost.persist()
    }

    func presentSettings(page: SettingsPage? = nil) {
        SettingsWindow.present(
            parent: window, page: page,
            onLayoutChanged: { [weak self] in
                Gtk.onMain { [weak self] in self?.applyLayoutPreferences() }
            },
            onShortcutsChanged: { [weak self] in
                Gtk.onMain { [weak self] in self?.reloadShortcuts(announce: false) }
            },
            onShowCheatsheet: { [weak self] in
                Gtk.onMain { [weak self] in
                    guard let self else { return }
                    self.activePane.setHelp(true)
                    if let window = self.window { gtk_window_present(ptr(window)) }
                }
            },
            onOrbChanged: { [weak self] in
                Gtk.onMain { [weak self] in self?.orb.applyEnabled() }
            },
            onUsageKeysChanged: { [weak self] in
                Task { [weak self] in
                    _ = await self?.refreshUsage()
                }
            },
            onOpenServers: { [weak self] in
                Gtk.onMain { [weak self] in self?.presentServers() }
            },
            onOpenUpdates: { [weak self] in
                Gtk.onMain { [weak self] in self?.presentUpdates() }
            },
            isPaneShown: { pane in ClosablePane(pane).isShown },
            setPaneShown: { [weak self] pane, shown in
                Gtk.onMain { [weak self] in
                    guard let self, self.paneShown(ClosablePane(pane)) != shown else { return }
                    self.togglePane(ClosablePane(pane))
                }
            })
    }
}
