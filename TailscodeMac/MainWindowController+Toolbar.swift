import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

extension MainWindowController: NSToolbarDelegate {
    private enum ToolbarID {
        static let sidebar = NSToolbarItem.Identifier("tailscode.toolbar.sidebar")
        static let newChat = NSToolbarItem.Identifier("tailscode.toolbar.newchat")
        static let actions = NSToolbarItem.Identifier("tailscode.toolbar.actions")
        static let terminal = NSToolbarItem.Identifier("tailscode.toolbar.terminal")
        static let video = NSToolbarItem.Identifier("tailscode.toolbar.video")
        static let usage = NSToolbarItem.Identifier("tailscode.toolbar.usage")
        static let servers = NSToolbarItem.Identifier("tailscode.toolbar.servers")
        static let settings = NSToolbarItem.Identifier("tailscode.toolbar.settings")
        static let live = NSToolbarItem.Identifier("tailscode.toolbar.live")
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            ToolbarID.sidebar, ToolbarID.newChat, .sidebarTrackingSeparator, .flexibleSpace,
            ToolbarID.live, ToolbarID.actions,
        ] + terminalToolbarItems
            + [ToolbarID.video, ToolbarID.usage, ToolbarID.servers, ToolbarID.settings]
    }

    private var terminalToolbarItems: [NSToolbarItem.Identifier] {
        #if TAILSCODE_MAS
            return []
        #else
            return [ToolbarID.terminal]
        #endif
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarDefaultItemIdentifiers(toolbar) + [.space]
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case ToolbarID.live:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = Localized.text("Live")
            item.paletteLabel = Localized.text("Live")
            item.view = liveChip.button
            item.isHidden = !liveChip.isShown
            liveChipItem = item
            return item
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
        #if !TAILSCODE_MAS
            case ToolbarID.terminal:
                return makeToolbarItem(
                    itemIdentifier, symbol: "terminal", label: Localized.text("Terminal"),
                    tip: Localized.text("Show or hide the terminal pane"),
                    action: #selector(toolbarToggleTerminal))
        #endif
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
            button.toolTip = Localized.text("Every provider's quota picture")
            item.view = button
            item.menuFormRepresentation = ClosureMenuItem(title: Localized.text("Usage")) {
                [weak self] in
                self?.presentUsageWindow()
            }
            return item
        case ToolbarID.newChat:
            return makeToolbarItem(
                itemIdentifier, symbol: "square.and.pencil", label: Localized.text("New Chat"),
                tip: Localized.text("Start a conversation on one of your servers"),
                action: #selector(toolbarNewChat))
        case ToolbarID.video:
            return makeVideoItem(itemIdentifier)
        case ToolbarID.servers:
            return makeToolbarItem(
                itemIdentifier, symbol: "server.rack", label: Localized.text("Servers"),
                tip: Localized.text("Add, probe, update or remove a server"),
                action: #selector(toolbarServers))
        case ToolbarID.settings:
            let item = NSToolbarItem(itemIdentifier: itemIdentifier)
            item.label = Localized.text("Settings")
            item.paletteLabel = Localized.text("Settings")
            let button = UpdateMarkButton(
                symbol: "gearshape", label: Localized.text("Settings"),
                tip: Localized.text("The prompt box, the transcript and the keyboard"),
                target: self, action: #selector(toolbarSettings))
            button.render()
            item.view = button
            item.menuFormRepresentation = ClosureMenuItem(title: Localized.text("Settings")) {
                [weak self] in self?.presentPreferences()
            }
            updateMark = button
            return item
        default:
            return nil
        }
    }

    /// An item that carries its own view has no target and no action, so AppKit's default overflow
    /// row is built dimmed and does nothing — these two therefore say what they do themselves. A
    /// view that overflowed has been taken out of the window on the way into the ⋯ menu, and a
    /// popover shown from a view with no window is an exception rather than a popover, so the
    /// window's own content stands in as the thing the answer points at.
    private func popoverAnchor(preferring view: NSView?) -> NSView? {
        if let view, view.window != nil { return view }
        return window?.contentView
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


    #if !TAILSCODE_MAS
        @objc private func toolbarToggleTerminal() {
            perform(.toggleTerminal)
        }
    #endif

    @objc private func toolbarUsage(_ sender: NSButton) {
        presentUsageWindow()
    }

    @objc private func toolbarNewChat() {
        presentNewChat()
    }

    /// Video's own control, carrying the weight the window gives its other primary actions: it sits
    /// in the toolbar beside servers and settings rather than only inside a menu, which is where a
    /// preference lives and not where an action does. It promises something different before a
    /// renderer exists than after, and it wears the render's own mark while the other machine is
    /// working — so somebody who closed the sheet can still see it is out.
    private func makeVideoItem(_ identifier: NSToolbarItem.Identifier) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        item.label = ForgeEntryPoint.title
        item.paletteLabel = ForgeEntryPoint.title
        let button = ForgeMarkButton(target: self, action: #selector(toolbarVideo))
        button.render()
        item.view = button
        item.toolTip = button.toolTip
        item.menuFormRepresentation = ClosureMenuItem(title: ForgeEntryPoint.menuTitle) {
            [weak self] in self?.presentForge()
        }
        videoMark = button
        return item
    }

    @objc private func toolbarVideo() {
        presentForge()
    }

    @objc private func toolbarServers() {
        presentServers()
    }

    @objc private func toolbarSettings() {
        presentPreferences()
    }
}

extension MainWindowController: NSToolbarItemValidation {
    func validateToolbarItem(_ item: NSToolbarItem) -> Bool { true }
}
