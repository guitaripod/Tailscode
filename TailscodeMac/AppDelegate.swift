import AppKit
import TailscodeCore

/// Lifecycle only: activation, reconnect-on-active, and the one window controller that is the
/// app. Everything the window does lives in `MainWindowController`; the menu bar lives in
/// `MainMenu`.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var main: MainWindowController?
    private var menu: MainMenu?

    func applicationDidFinishLaunching(_ notification: Notification) {
        Self.typeWhatIsTyped()
        NSApp.setActivationPolicy(.regular)
        Self.forgetTheKeysForPanesThisCopyLacks()
        #if TAILSCODE_MAS
            Self.keepShortcutsWhereTheContainerCanReachThem()
        #endif
        SessionSeenStore.bootstrapIfNeeded()
        DraftStore.warm()
        ThemeSelection.fallbackID = ThemeSelection.systemID
        NSApp.appearance = MacTheme.Chrome.appearance
        let controller = MainWindowController()
        controller.showWindow(nil)
        main = controller
        let menu = MainMenu(hub: controller)
        menu.install()
        self.menu = menu
        MacGameCenter.shared.start()
        MacProStore.shared.start()
        MacSummon.shared.start { [weak controller] in controller?.summonQuickAsk() }
        MacNotifier.shared.activate()
        MacNotifier.shared.onOpen = { [weak controller] sessionID in
            controller?.openSession(withID: sessionID)
        }
        FirstRunWindow.presentIfNeeded { [weak controller] in
            Task { [weak controller] in await controller?.sidebar.refresh() }
        }
        NSApp.activate(ignoringOtherApps: true)
        openRequestedSession()
        openRequestedSurface()
        MacShot.schedule()
    }

    #if TAILSCODE_MAS
        /// The rebinding file, moved to where a sandboxed copy can both write it and be shown it.
        /// `~/.config/tailscode` is outside this app's container, so the store build keeps the same
        /// file in the Application Support folder the container does hold — set before anything
        /// loads a shortcut, which is the one moment the override is read.
        private static func keepShortcutsWhereTheContainerCanReachThem() {
            ShortcutSet.configDirectoryOverride = FileManager.default.urls(
                for: .applicationSupportDirectory, in: .userDomainMask
            ).first
        }

    #endif

    /// The keys for panes this client does not contain. The registry is Core's and a package never
    /// sees an app target's compilation conditions, so the sheet would otherwise document panes
    /// that cannot be opened — and bind chords to nothing at all. The file tree is gone from both
    /// Mac builds; the terminal only from the sandboxed one.
    private static func forgetTheKeysForPanesThisCopyLacks() {
        var gone: Set<String> = ["focus.files", "pane.files"]
        #if TAILSCODE_MAS
            gone.formUnion(["focus.terminal", "pane.terminal"])
        #endif
        ShortcutSet.unavailable = gone
    }

    /// `TAILSCODE_OPEN_SESSION=<id>` — the same headless hook the iOS harness has: land the
    /// window on one named chat once the listing exists, so a `--shot` can look at a
    /// conversation instead of the picker.
    private func openRequestedSession() {
        guard let id = ProcessInfo.processInfo.environment["TAILSCODE_OPEN_SESSION"] else {
            return
        }
        Task { [weak main] in
            try? await Task.sleep(for: .seconds(2))
            main?.openSession(withID: id)
            #if DEBUG
                guard let text = ProcessInfo.processInfo.environment["TAILSCODE_DRIVE_SEND"],
                    !text.isEmpty
                else { return }
                try? await Task.sleep(for: .seconds(5))
                main?.transcript.driveSend(text)
            #endif
        }
    }

    /// `--open <surface>` — the same hook one step further in: land on a named window once the
    /// listing behind it exists, so `--shot` and `--tree` can look at a sheet or a panel rather
    /// than only at the window a launch already draws.
    private func openRequestedSurface() {
        guard let surface = MacShot.surface else { return }
        Task { [weak main] in
            try? await Task.sleep(for: .seconds(2))
            main?.openSurface(named: surface)
        }
    }

    /// A Mac that slept holds sockets that look alive and deliver nothing; coming back to the
    /// app is the moment to re-dial the stream and re-list the chats.
    func applicationDidBecomeActive(_ notification: Notification) {
        main?.handleDidBecomeActive()
        MacReviewPrompt.shared.returnedToFinishedWork()
    }

    /// Switching away is the ordinary way this app stops being asked, and the one people do
    /// dozens of times a day: whatever is half-typed goes to disk here rather than waiting for
    /// the store's quiet moment to come around.
    func applicationWillResignActive(_ notification: Notification) {
        stashDrafts()
    }

    /// The last chance there is. Quitting must never be what eats a prompt, so every open pane's
    /// composer is written before the process goes.
    func applicationWillTerminate(_ notification: Notification) {
        stashDrafts()
        main?.prepareToQuit()
    }

    /// Everything typed into this app is read by a machine — a prompt, a path, a shell command, an
    /// address — and a curly quote, an em dash or an autocorrected word is a different command.
    /// AppKit hands every text view the person's system-wide choices for those rewrites, so this
    /// app's own defaults say no to them once; a choice made later in Edit ▸ Substitutions is the
    /// app's own and is left alone.
    private static func typeWhatIsTyped() {
        let domain = Bundle.main.bundleIdentifier ?? "com.guitaripod.tailscode"
        let held = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
        for key in [
            "NSAutomaticQuoteSubstitutionEnabled", "NSAutomaticDashSubstitutionEnabled",
            "NSAutomaticTextReplacementEnabled", "NSAutomaticSpellingCorrectionEnabled",
        ] where held[key] == nil {
            UserDefaults.standard.set(false, forKey: key)
        }
    }

    private func stashDrafts() {
        main?.stashComposerDrafts()
        DraftStore.flush()
    }

    /// Closing the window puts the conversations away rather than ending them. A turn still running
    /// finishes and says so in a notification, the quick-ask chord keeps working from any app, and
    /// the Dock icon brings the same window back with every pane where it was — the way a chat
    /// app on the Mac behaves. Quitting is ⌘Q.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// The Dock icon is the way back to a window that was closed: there is no File ▸ New Window to
    /// rebuild the hub from.
    func applicationShouldHandleReopen(
        _ sender: NSApplication, hasVisibleWindows: Bool
    ) -> Bool {
        main?.showWindow(nil)
        return true
    }

    /// What the Dock icon offers besides the windows it already lists: a new chat and a question,
    /// each reachable while every window is closed.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let menu = NSMenu()
        let chat = NSMenuItem(
            title: Localized.text("New Chat"), action: #selector(dockNewChat), keyEquivalent: "")
        chat.target = self
        menu.addItem(chat)
        let ask = NSMenuItem(
            title: Localized.text("Quick Ask…"), action: #selector(dockQuickAsk), keyEquivalent: "")
        ask.target = self
        menu.addItem(ask)
        return menu
    }

    @objc private func dockNewChat() {
        main?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
        _ = main?.perform(.newChat)
    }

    @objc private func dockQuickAsk() {
        main?.summonQuickAsk()
    }
}
