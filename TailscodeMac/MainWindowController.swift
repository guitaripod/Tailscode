import AppKit
import CodingAgentKit
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
    private var toastView: NSView?
    private var toastGeneration = 0
    private var keyMonitor: Any?

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

    /// A two-second floating confirmation — the answer to "did my click do anything". Glass,
    /// because it floats above content; one at a time, because two toasts is a queue nobody reads.
    func toast(_ text: String) {
        guard let host = window?.contentView else { return }
        toastView?.removeFromSuperview()
        let label = NSTextField(labelWithString: text)
        label.font = MacTheme.Font.body()
        label.translatesAutoresizingMaskIntoConstraints = false
        let padded = NSView()
        padded.translatesAutoresizingMaskIntoConstraints = false
        padded.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: padded.leadingAnchor, constant: 14),
            label.trailingAnchor.constraint(equalTo: padded.trailingAnchor, constant: -14),
            label.topAnchor.constraint(equalTo: padded.topAnchor, constant: 8),
            label.bottomAnchor.constraint(equalTo: padded.bottomAnchor, constant: -8),
        ])
        let glass = MacTheme.glass(around: padded, cornerRadius: 18)
        host.addSubview(glass)
        NSLayoutConstraint.activate([
            glass.centerXAnchor.constraint(equalTo: host.centerXAnchor),
            glass.bottomAnchor.constraint(equalTo: host.bottomAnchor, constant: -28),
        ])
        toastView = glass
        glass.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            glass.animator().alphaValue = 1
        }
        toastGeneration += 1
        let generation = toastGeneration
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard let self, self.toastGeneration == generation, let view = self.toastView
            else { return }
            NSAnimationContext.runAnimationGroup(
                { context in
                    context.duration = 0.3
                    view.animator().alphaValue = 0
                }, completionHandler: nil)
            try? await Task.sleep(for: .milliseconds(320))
            guard self.toastGeneration == generation else { return }
            self.toastView?.removeFromSuperview()
            self.toastView = nil
        }
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
        case .cycleForward, .cycleBackward:
            return focus(focused == .chats ? .transcript : .chats)
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
        case .send, .commandPalette, .zoomIn, .zoomOut, .zoomReset:
            return false
        }
        return true
    }

    private func wireChildren() {
        sidebar.onOpen = { [weak self] entry, backend in
            self?.handleOpen(entry, backend: backend)
        }
        sidebar.onNotice = { [weak self] text in self?.setNotice(text) }
        sidebar.onToast = { [weak self] text in self?.toast(text) }
        transcript.onState = { [weak self] state in self?.lastState = state }
        transcript.onToast = { [weak self] text in self?.toast(text) }
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

    /// Anything that takes text — the composer, the filter field's editor, a rename sheet — is
    /// insert; the rest of the window is normal. The terminal context arrives with its pane.
    private func keyContext() -> KeyContext {
        guard let responder = window?.firstResponder else { return .normal }
        return responder is NSText ? .insert : .normal
    }

    @discardableResult
    private func focus(_ pane: Pane) -> Bool {
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
        static let files = NSToolbarItem.Identifier("tailscode.toolbar.files")
        static let terminal = NSToolbarItem.Identifier("tailscode.toolbar.terminal")
        static let usage = NSToolbarItem.Identifier("tailscode.toolbar.usage")
        static let servers = NSToolbarItem.Identifier("tailscode.toolbar.servers")
        static let settings = NSToolbarItem.Identifier("tailscode.toolbar.settings")
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            ToolbarID.sidebar, .sidebarTrackingSeparator, .flexibleSpace, ToolbarID.files,
            ToolbarID.terminal, ToolbarID.usage, ToolbarID.servers, ToolbarID.settings,
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
            return makeToolbarItem(
                itemIdentifier, symbol: "gauge", label: Localized.text("Usage"),
                tip: Localized.text("The quota picture arrives in a later phase"),
                action: #selector(toolbarPlaceholder))
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

    @objc private func toolbarPlaceholder(_ sender: NSToolbarItem) {
        toast(sender.toolTip ?? Localized.text("Coming in a later phase"))
    }
}

extension MainWindowController: NSToolbarItemValidation {
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool { true }
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
