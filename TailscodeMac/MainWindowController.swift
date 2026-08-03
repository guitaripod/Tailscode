import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

/// The hub — the Mac's `MainWindow`: it owns the window, the toolbar, the split layout, the
/// shortcut engine and the current-chat state. Child controllers talk to it through closures
/// wired at construction, and every later phase reaches the app through the handles this class
/// exposes rather than through globals.
@MainActor
final class MainWindowController: NSWindowController {
    let sidebar = SidebarViewController()
    let transcript = TranscriptViewController()
    private(set) var currentEntry: SessionEntry?
    private(set) var currentBackend: (any CodingAgentBackend)?

    private let split = NSSplitViewController()
    private var sidebarItem: NSSplitViewItem?
    private var filesItem: NSSplitViewItem?
    private var shortcuts = ShortcutSet.load()
    private var pendingChords: [KeyChord] = []
    private var lastState: ConversationState?
    private var focused: Pane = .chats
    private var cheatsheet: NSPanel?
    private var keyMonitor: Any?
    private var usageTask: Task<Void, Never>?
    private var usagePopover: NSPopover?
    private var lastQuotas: [(String, UsageQuota)] = []
    private lazy var toasts = ToastPresenter { [weak self] in self?.transcript.toastAnchor }

    init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "Tailscode"
        super.init(window: window)
        wireChildren()
        configureSplit()
        configureToolbar()
        window.center()
        window.setFrameAutosaveName("TailscodeMain")
        installKeyMonitor()
        startUsagePolling()
        if !shortcuts.issues.isEmpty {
            setNotice(
                Localized.text("Keybindings: %@", shortcuts.issues.joined(separator: " · ")))
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func open(_ entry: SessionEntry) {
        sidebar.open(entry)
    }

    func handleDidBecomeActive() {
        transcript.reconnect()
        Task { [weak self] in await self?.sidebar.refresh() }
    }

    /// A two-second floating confirmation — the answer to "did my click do anything". Presented
    /// by the hub so every child's toast lands in the same queue.
    func toast(_ text: String) {
        toasts.show(text)
    }

    func setNotice(_ text: String) {
        transcript.setNotice(text)
    }

    /// Re-reads the rebinding file and rebuilds everything derived from it, live: the resolver,
    /// the cheatsheet if it is open, and the notice line if the file has something wrong in it.
    func reloadShortcuts() {
        shortcuts = ShortcutSet.load()
        pendingChords = []
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

    /// Everything the keyboard can mean, one switch: the chat-list verbs are live now, the
    /// conversation verbs land with their panes in later phases — those return false so the
    /// keystroke falls through instead of being swallowed by a promise.
    @discardableResult
    func perform(_ action: KeyAction) -> Bool {
        switch action {
        case .focus(let pane):
            return focus(pane)
        case .cycleForward:
            if focused == .chats { return focus(.transcript) }
            if transcript.composer.editorHasFocus { return focus(.chats) }
            focused = .transcript
            transcript.focusComposer()
        case .cycleBackward:
            if focused == .chats {
                focused = .transcript
                transcript.focusComposer()
                return true
            }
            if transcript.composer.editorHasFocus { return focus(.transcript) }
            return focus(.chats)
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
        case .deleteSelected:
            guard let currentEntry, let currentBackend else { return true }
            sidebar.presentDelete(entry: currentEntry, backend: currentBackend)
        case .copySessionID:
            guard let currentEntry else { return true }
            copyToPasteboard(currentEntry.session.id)
        case .copyProjectPath:
            guard let directory = currentEntry?.session.directory else { return true }
            copyToPasteboard(directory)
        case .toggleSidebar:
            togglePane(.sidebar)
        case .toggleFiles:
            togglePane(.files)
        case .toggleTerminal:
            togglePane(.terminal)
        case .toggleHelp:
            toggleCheatsheet()
        case .newChat:
            NSSound.beep()
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
        case .zoomIn:
            MacTheme.UIScale.step(0.1)
            applyUIScale()
        case .zoomOut:
            MacTheme.UIScale.step(-0.1)
            applyUIScale()
        case .zoomReset:
            MacTheme.UIScale.reset()
            applyUIScale()
        }
        return true
    }

    /// Every fact on the band answers to the same verbs a person would reach for: reading the
    /// status and steering the turn are one gesture.
    func perform(bandAction action: StatusFacts.Action) {
        switch action {
        case .stop:
            transcript.stopTurn()
        case .compact:
            transcript.presentCompactPreflight()
        case .goal:
            transcript.presentGoalSheet()
        case .scrollToPending:
            transcript.scrollToBottom()
        case .scrollToAgents:
            transcript.scrollToNewestAgent()
        case .agent(let id):
            transcript.scrollToAgent(id)
        case .reconnect:
            transcript.reconnect()
        }
    }

    private func applyUIScale() {
        transcript.applyUIScale()
        sidebar.applyUIScale()
    }

    private func wireChildren() {
        sidebar.onOpen = { [weak self] entry, backend in
            self?.handleOpen(entry, backend: backend)
        }
        sidebar.onNotice = { [weak self] text in self?.setNotice(text) }
        sidebar.onToast = { [weak self] text in self?.toast(text) }
        transcript.onState = { [weak self] state in self?.lastState = state }
        transcript.onToast = { [weak self] text in self?.toast(text) }
        transcript.onBandAction = { [weak self] action in self?.perform(bandAction: action) }
    }

    /// Quota is account state, not session state: polled on its own slow cadence — quickly only
    /// while the profile list has not been seeded yet — and rendered in the sidebar footer, the
    /// way the phone keeps it on the Home board.
    private func startUsagePolling() {
        usageTask = Task { [weak self] in
            while !Task.isCancelled {
                let settled = await self?.refreshUsage() ?? true
                try? await Task.sleep(for: .seconds(settled ? 120 : 15))
            }
        }
    }

    private func refreshUsage() async -> Bool {
        let profiles = ServerDirectory.shared.profiles
        guard !profiles.isEmpty else { return false }
        let snapshot = await Self.collectQuotas(profiles: profiles)
        lastQuotas = snapshot
        sidebar.renderUsage(snapshot)
        return true
    }

    /// Every quota every server can speak for: the agent's own, plus whatever other providers
    /// the machine holds accounts for (a bridge also reports Grok). One machine answering for a
    /// provider is enough — a second profile on the same host must not double the card.
    private static func collectQuotas(profiles: [ConnectionProfile]) async
        -> [(String, UsageQuota)]
    {
        var quotas: [(String, UsageQuota)] = []
        var seen = Set<String>()
        for profile in profiles {
            guard let backend = ServerDirectory.shared.backend(for: profile) else { continue }
            var collected: [UsageQuota] = []
            if let quota = (try? await backend.usageQuota()) ?? nil { collected.append(quota) }
            collected += (try? await backend.additionalUsageQuotas()) ?? []
            for quota in collected
            where seen.insert("\(quota.providerName)|\(quota.source)").inserted {
                quotas.append((profile.name, quota))
            }
        }
        return quotas
    }

    private func presentUsagePopover(from anchor: NSView) {
        if let usagePopover, usagePopover.isShown {
            usagePopover.close()
            self.usagePopover = nil
            return
        }
        let panel = UsagePanelViewController(initial: lastQuotas) {
            await Self.collectQuotas(profiles: ServerDirectory.shared.profiles)
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = panel
        popover.show(relativeTo: anchor.bounds, of: anchor, preferredEdge: .maxY)
        usagePopover = popover
    }

    private func handleOpen(_ entry: SessionEntry, backend: any CodingAgentBackend) {
        currentEntry = entry
        currentBackend = backend
        UserDefaults.standard.set(entry.session.id, forKey: "tailscode.lastSession")
        transcript.open(entry, backend: backend)
        window?.title =
            entry.session.hasPlaceholderTitle
            ? Localized.text("New conversation") : entry.session.title
        window?.subtitle = ServerLabel.display(name: entry.profileName, backend: entry.backendType)
    }

    private func configureSplit() {
        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.minimumThickness = 240
        sidebarItem.maximumThickness = 400
        sidebarItem.canCollapse = true
        sidebarItem.isCollapsed = !paneShown(.sidebar)
        split.addSplitViewItem(sidebarItem)
        self.sidebarItem = sidebarItem

        split.addSplitViewItem(NSSplitViewItem(viewController: transcript))

        let files = NSSplitViewItem(inspectorWithViewController: FilesPlaceholderViewController())
        files.minimumThickness = 220
        files.maximumThickness = 400
        files.canCollapse = true
        files.isCollapsed = !paneShown(.files)
        split.addSplitViewItem(files)
        filesItem = files

        window?.contentViewController = split
    }

    private func configureToolbar() {
        guard let window else { return }
        let toolbar = NSToolbar(identifier: "TailscodeToolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified
        window.titleVisibility = .visible
    }

    /// One local monitor is the whole engine: ⌘ chords fall through to the menu bar (the adapter
    /// returns nil for them on purpose), text fields keep their letters, and everything else goes
    /// through the shared registry exactly like Linux `installKeymap`.
    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.window else { return event }
            return self.handle(event)
        }
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        if let verdict = composerKey(event) { return verdict ? nil : event }
        guard let chord = MacKeys.chord(for: event) else { return event }
        let context = keyContext()
        let awaiting =
            context == .normal && !(lastState?.pendingPermissions.isEmpty ?? true)
        switch shortcuts.resolve(
            chord, context: context, pending: pendingChords, awaitingApproval: awaiting)
        {
        case .run(let action):
            pendingChords = []
            return perform(action) ? nil : event
        case .pending(let chords):
            pendingChords = chords
            return nil
        case .unbound:
            pendingChords = []
            return event
        }
    }

    /// The prompt box's own key handling, decided here rather than in the text view so the same
    /// keystroke means the same thing whether a person typed it or a binding sent it — exactly
    /// Linux `handleComposerKey`: completion keys first while the popover shows, then vim, then
    /// Return-to-send. `nil` means "not the composer's business" and the keystroke falls through
    /// to the shared registry; `false` hands it to the text view for ordinary typing.
    private func composerKey(_ event: NSEvent) -> Bool? {
        let composer = transcript.composer
        guard composer.editorHasFocus else { return nil }
        let isReturn = event.keyCode == 36 || event.keyCode == 76
        if event.modifierFlags.contains(.command) {
            if isReturn {
                composer.sendNow()
                return true
            }
            return nil
        }
        let control = event.modifierFlags.contains(.control)
        let shift = event.modifierFlags.contains(.shift)
        let letter = event.charactersIgnoringModifiers

        if composer.completionVisible {
            switch event.keyCode {
            case 48:
                if shift { composer.moveCompletion(by: -1) } else { composer.acceptCompletion() }
                return true
            case 125:
                composer.moveCompletion(by: 1)
                return true
            case 126:
                composer.moveCompletion(by: -1)
                return true
            case 53:
                composer.dismissCompletion()
                return true
            default:
                if control, letter == "n" {
                    composer.moveCompletion(by: 1)
                    return true
                }
                if control, letter == "p" {
                    composer.moveCompletion(by: -1)
                    return true
                }
            }
        }

        if composer.vimEnabled {
            let key = vimKey(for: event)
            if composer.vimMode == .insert, key.isEscape || (control && letter == "[") {
                composer.applyVim(VimKey(isEscape: true))
                return true
            }
            if composer.vimMode != .insert {
                return composerNormalKey(key, event: event)
            }
        }

        if isReturn, !shift, ComposerView.sendOnReturn || control {
            composer.sendNow()
            return true
        }
        if isReturn, shift || !ComposerView.sendOnReturn { return false }
        return nil
    }

    /// The composer's normal mode is the app's normal mode: every key answers to the shortcut
    /// table first — j scrolls, J switches chats, ? opens the cheatsheet — while vim keeps what
    /// makes it vim: the visual modes whole, insert and visual entries, Enter to send, and every
    /// key of a command already in flight, so `3x`, `diw` and `ct)` still land. A key neither
    /// side binds goes back to vim rather than to the text view, so no stray letter types itself
    /// into the draft.
    private func composerNormalKey(_ key: VimKey, event: NSEvent) -> Bool? {
        let composer = transcript.composer
        if key.control, event.charactersIgnoringModifiers == "c",
            composer.copySelectionToPasteboard()
        {
            toast(Localized.text("Copied"))
            return true
        }
        guard let chord = MacKeys.chord(for: event) else { return nil }
        let awaiting = !(lastState?.pendingPermissions.isEmpty ?? true)
        if awaiting, !chord.control, !chord.alt, pendingChords.isEmpty,
            let action = shortcuts.approval[chord.token]
        {
            pendingChords = []
            return perform(action)
        }
        if key.isEnter, chord.control {
            pendingChords = []
            composer.sendNow()
            return true
        }
        let plain = !chord.control && !chord.alt
        let entries: Set<Character> = ["i", "a", "o", "v", "V"]
        let entersVimMode = plain && (key.character.map { entries.contains($0) } ?? false)
        if composer.vimMode != .normal || composer.vimAwaitsMore || entersVimMode
            || (plain && key.isEnter)
        {
            pendingChords = []
            composer.applyVim(key)
            return true
        }
        switch shortcuts.resolve(
            chord, context: .normal, pending: pendingChords, awaitingApproval: false)
        {
        case .run(let action):
            pendingChords = []
            _ = perform(action)
            return true
        case .pending(let chords):
            pendingChords = chords
            return true
        case .unbound:
            pendingChords = []
            composer.applyVim(key)
            return true
        }
    }

    private func vimKey(for event: NSEvent) -> VimKey {
        var character: Character?
        if let raw = event.charactersIgnoringModifiers?.first,
            let scalar = raw.unicodeScalars.first?.value, scalar >= 0x20,
            !(0xF700...0xF8FF).contains(scalar)
        {
            character = raw
        }
        return VimKey(
            character: character,
            isEscape: event.keyCode == 53,
            isEnter: event.keyCode == 36 || event.keyCode == 76,
            isBackspace: event.keyCode == 51,
            control: event.modifierFlags.contains(.control))
    }

    /// Anything that takes text — the composer, the filter field's editor, a rename sheet — is
    /// insert; the rest of the window is normal. The terminal context arrives with its pane.
    private func keyContext() -> KeyContext {
        guard let responder = window?.firstResponder else { return .normal }
        return responder is NSText ? .insert : .normal
    }

    @discardableResult
    private func focus(_ pane: Pane) -> Bool {
        if pane != .transcript { transcript.composer.dismissCompletion() }
        switch pane {
        case .chats:
            focused = .chats
            sidebar.takeFocus()
        case .transcript:
            focused = .transcript
            window?.makeFirstResponder(nil)
        case .files, .terminal:
            return false
        }
        return true
    }

    /// Every pane closes, and the choice survives relaunch under the same `tailscode.pane.*`
    /// keys the other desktops use — a window someone shaped once should open shaped that way.
    private enum ClosablePane: String {
        case sidebar
        case files
        case terminal

        var key: String { "tailscode.pane.\(rawValue)" }
        var defaultShown: Bool { self == .sidebar }
    }

    private func paneShown(_ pane: ClosablePane) -> Bool {
        UserDefaults.standard.object(forKey: pane.key) as? Bool ?? pane.defaultShown
    }

    private func togglePane(_ pane: ClosablePane) {
        let shown = !paneShown(pane)
        UserDefaults.standard.set(shown, forKey: pane.key)
        switch pane {
        case .sidebar:
            sidebarItem?.animator().isCollapsed = !shown
        case .files:
            filesItem?.animator().isCollapsed = !shown
        case .terminal:
            toast(Localized.text("The terminal pane arrives in a later phase"))
        }
    }

    private func toggleCheatsheet() {
        if let cheatsheet, cheatsheet.isVisible {
            cheatsheet.close()
            return
        }
        presentCheatsheet()
    }

    private func closeCheatsheet() {
        guard let cheatsheet, cheatsheet.isVisible else { return }
        cheatsheet.close()
    }

    /// The cheatsheet is generated from the registry, so it always tells the truth — overrides
    /// included. Two columns, because forty rows in one column is a scroll, not a glance.
    private func presentCheatsheet() {
        let panel = CheatsheetPanel(
            contentRect: .zero, styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = Localized.text("Keyboard shortcuts")
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.contentView = makeCheatsheetContent()
        panel.setContentSize(panel.contentView?.fittingSize ?? NSSize(width: 640, height: 480))
        if let frame = window?.frame {
            let size = panel.frame.size
            panel.setFrameOrigin(
                NSPoint(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2))
        }
        panel.makeKeyAndOrderFront(nil)
        cheatsheet = panel
    }

    private func makeCheatsheetContent() -> NSView {
        let sections = shortcuts.helpSections()
        let left = cheatsheetColumn()
        let right = cheatsheetColumn()
        let total = sections.reduce(0) { $0 + $1.rows.count + 2 }
        var used = 0
        for section in sections {
            let target = used < (total + 1) / 2 ? left : right
            used += section.rows.count + 2
            let header = NSTextField(labelWithString: section.title)
            header.font = .systemFont(ofSize: 11, weight: .semibold)
            header.textColor = MacTheme.Color.secondaryLabel
            target.addArrangedSubview(header)
            target.setCustomSpacing(6, after: header)
            for row in section.rows {
                let keys = NSTextField(labelWithString: row.keys)
                keys.font = MacTheme.Font.mono(11)
                keys.lineBreakMode = .byTruncatingTail
                keys.widthAnchor.constraint(equalToConstant: 160).isActive = true
                let what = NSTextField(labelWithString: row.what)
                what.font = MacTheme.Font.caption()
                what.textColor = MacTheme.Color.secondaryLabel
                let line = NSStackView(views: [keys, what])
                line.orientation = .horizontal
                line.spacing = 12
                line.alignment = .firstBaseline
                target.addArrangedSubview(line)
            }
            if let last = target.arrangedSubviews.last {
                target.setCustomSpacing(14, after: last)
            }
        }
        let columns = NSStackView(views: [left, right])
        columns.orientation = .horizontal
        columns.alignment = .top
        columns.spacing = 44
        let footer = NSTextField(
            labelWithString: Localized.text(
                "Rebind any of these: %@", ShortcutSet.configURL.path))
        footer.font = MacTheme.Font.caption()
        footer.textColor = MacTheme.Color.tertiaryLabel
        let content = NSStackView(views: [columns, footer])
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        content.edgeInsets = NSEdgeInsets(top: 20, left: 24, bottom: 20, right: 24)
        return content
    }

    private func cheatsheetColumn() -> NSStackView {
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 3
        return column
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        toast(Localized.text("Copied"))
    }
}

extension MainWindowController: NSToolbarDelegate {
    private enum ToolbarID {
        static let sidebar = NSToolbarItem.Identifier("tailscode.toolbar.sidebar")
        static let actions = NSToolbarItem.Identifier("tailscode.toolbar.actions")
        static let files = NSToolbarItem.Identifier("tailscode.toolbar.files")
        static let terminal = NSToolbarItem.Identifier("tailscode.toolbar.terminal")
        static let usage = NSToolbarItem.Identifier("tailscode.toolbar.usage")
        static let servers = NSToolbarItem.Identifier("tailscode.toolbar.servers")
        static let settings = NSToolbarItem.Identifier("tailscode.toolbar.settings")
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            ToolbarID.sidebar, .sidebarTrackingSeparator, .flexibleSpace, ToolbarID.actions,
            ToolbarID.files, ToolbarID.terminal, ToolbarID.usage, ToolbarID.servers,
            ToolbarID.settings,
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space]
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case ToolbarID.sidebar:
            return makeToolbarItem(
                itemIdentifier, symbol: "sidebar.leading", label: Localized.text("Chats"),
                tip: Localized.text("Show or hide the chat list"),
                action: #selector(toolbarToggleSidebar))
        case ToolbarID.actions:
            let item = NSMenuToolbarItem(itemIdentifier: itemIdentifier)
            item.image = NSImage(
                systemSymbolName: "ellipsis.circle",
                accessibilityDescription: Localized.text("Conversation actions"))
            item.label = Localized.text("Actions")
            item.paletteLabel = Localized.text("Actions")
            item.toolTip = Localized.text("Everything this conversation can do")
            item.isBordered = true
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            return item
        case ToolbarID.files:
            return makeToolbarItem(
                itemIdentifier, symbol: "sidebar.trailing", label: Localized.text("Files"),
                tip: Localized.text("Show or hide the files pane"),
                action: #selector(toolbarToggleFiles))
        case ToolbarID.terminal:
            return makeToolbarItem(
                itemIdentifier, symbol: "terminal", label: Localized.text("Terminal"),
                tip: Localized.text("The terminal pane arrives in a later phase"),
                action: #selector(toolbarToggleTerminal))
        case ToolbarID.usage:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = Localized.text("Usage")
            item.paletteLabel = Localized.text("Usage")
            item.toolTip = Localized.text("Every provider's quota picture")
            let button = NSButton(
                image: NSImage(
                    systemSymbolName: "gauge",
                    accessibilityDescription: Localized.text("Usage"))!,
                target: self, action: #selector(toolbarUsage(_:)))
            button.bezelStyle = .toolbar
            item.view = button
            return item
        case ToolbarID.servers:
            return makeToolbarItem(
                itemIdentifier, symbol: "server.rack", label: Localized.text("Servers"),
                tip: Localized.text("Server management arrives in a later phase"),
                action: #selector(toolbarPlaceholder))
        case ToolbarID.settings:
            return makeToolbarItem(
                itemIdentifier, symbol: "gearshape", label: Localized.text("Settings"),
                tip: Localized.text("Settings arrive in a later phase"),
                action: #selector(toolbarPlaceholder))
        default:
            return nil
        }
    }

    private func makeToolbarItem(
        _ identifier: NSToolbarItem.Identifier, symbol: String, label: String, tip: String,
        action: Selector
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
        item.label = label
        item.paletteLabel = label
        item.toolTip = tip
        item.isBordered = true
        item.target = self
        item.action = action
        return item
    }

    @objc private func toolbarToggleSidebar() {
        perform(.toggleSidebar)
    }

    @objc private func toolbarToggleFiles() {
        perform(.toggleFiles)
    }

    @objc private func toolbarToggleTerminal() {
        perform(.toggleTerminal)
    }

    @objc private func toolbarUsage(_ sender: NSButton) {
        presentUsagePopover(from: sender)
    }

    @objc private func toolbarPlaceholder(_ sender: NSToolbarItem) {
        toast(sender.toolTip ?? Localized.text("Coming in a later phase"))
    }
}

extension MainWindowController: NSToolbarItemValidation {
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool { true }
}

extension MainWindowController: NSMenuDelegate {
    /// The ⋯ menu: everything the open conversation can do, rebuilt on every click so the verbs
    /// and the Save/Unsave title always describe the chat as it is now — capability-gated, and
    /// reusing the sidebar's own flows so a rename here and a rename there are the same rename.
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let entry = currentEntry, let backend = currentBackend else {
            let empty = NSMenuItem(
                title: Localized.text("No conversation open"), action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
            return
        }
        let capabilities = backend.capabilities
        let saved = SavedChatStore.contains(entry)
        menu.addItem(
            actionsItem(
                saved ? Localized.text("Unsave") : Localized.text("Save"),
                subtitle: Localized.text(
                    "A saved chat lists itself even when its server is unreachable")
            ) { [weak self] in
                self?.sidebar.toggleSaved(entry)
            })
        if capabilities.supportsRenaming {
            menu.addItem(
                actionsItem(Localized.text("Rename…")) { [weak self] in
                    self?.sidebar.presentRename(entry: entry, backend: backend)
                })
        }
        if capabilities.supportsForking {
            menu.addItem(
                actionsItem(
                    Localized.text("Fork"),
                    subtitle: Localized.text(
                        "A new session with this history, for a different direction")
                ) { [weak self] in
                    self?.sidebar.fork(entry: entry, backend: backend)
                })
        }
        if capabilities.supportsCompaction {
            menu.addItem(
                actionsItem(
                    Localized.text("Compact…"),
                    subtitle: Localized.text("Irreversible, takes minutes")
                ) { [weak self] in
                    self?.transcript.presentCompactPreflight()
                })
        }
        if capabilities.supportsClearing {
            menu.addItem(
                actionsItem(
                    Localized.text("Clear…"),
                    subtitle: Localized.text("Empty the conversation in place")
                ) { [weak self] in
                    self?.presentClear(entry: entry, backend: backend)
                })
        }
        menu.addItem(.separator())
        menu.addItem(
            actionsItem(
                Localized.text("Delete…"),
                subtitle: Localized.text("Remove the session from its server"), destructive: true
            ) { [weak self] in
                self?.sidebar.presentDelete(entry: entry, backend: backend)
            })
    }

    private func actionsItem(
        _ title: String, subtitle: String? = nil, destructive: Bool = false,
        handler: @escaping @MainActor () -> Void
    ) -> NSMenuItem {
        let item = ClosureMenuItem(title: title, handler: handler)
        if let subtitle { item.subtitle = subtitle }
        if destructive {
            item.attributedTitle = NSAttributedString(
                string: title, attributes: [.foregroundColor: MacTheme.Color.danger])
        }
        return item
    }

    private func presentClear(entry: SessionEntry, backend: any CodingAgentBackend) {
        guard let window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = Localized.text("Clear this conversation?")
        alert.informativeText = Localized.text(
            "Everything in it goes away, on the server, for every device.")
        let confirm = alert.addButton(withTitle: Localized.text("Clear"))
        confirm.hasDestructiveAction = true
        alert.addButton(withTitle: Localized.text("Cancel"))
        let sessionID = entry.session.id
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            Task { [weak self] in
                try? await backend.clearConversation(sessionID)
                await self?.sidebar.refresh()
            }
        }
    }
}

/// Esc dismisses, matching the key that opened it: the cheatsheet is a glance, not a window to
/// manage.
private final class CheatsheetPanel: NSPanel {
    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { close() } else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) {
        close()
    }
}

/// Holds the trailing inspector's place until the file-tree phase: the pane, its glass and its
/// persistence are real today, so that phase only swaps the content.
@MainActor
private final class FilesPlaceholderViewController: NSViewController {
    override func loadView() {
        let label = NSTextField(
            wrappingLabelWithString: Localized.text(
                "The project's files land here in a later phase."))
        label.font = MacTheme.Font.caption()
        label.textColor = MacTheme.Color.tertiaryLabel
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            label.leadingAnchor.constraint(
                equalTo: container.leadingAnchor, constant: MacTheme.Spacing.l),
            label.trailingAnchor.constraint(
                equalTo: container.trailingAnchor, constant: -MacTheme.Spacing.l),
        ])
        view = container
    }
}
