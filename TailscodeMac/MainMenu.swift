import AppKit
import CodingAgentKit
import TailscodeCore

/// The whole menu bar; every ⌘ equivalent lives here, one action per item. The key monitor
/// returns nil for ⌘ events on purpose, so these are the only owners of the command layer — and
/// validation reads the hub's state on every open, so a verb that cannot land right now says so
/// by dimming instead of failing quietly.
@MainActor
final class MainMenu: NSObject {
    private unowned let hub: MainWindowController

    init(hub: MainWindowController) {
        self.hub = hub
    }

    func install() {
        let main = NSMenu()
        main.addItem(makeAppMenu())
        main.addItem(makeFileMenu())
        main.addItem(makeEditMenu())
        main.addItem(makeChatMenu())
        main.addItem(makeViewMenu())
        main.addItem(makeGoMenu())
        main.addItem(makeWindowMenu())
        main.addItem(makeHelpMenu())
        NSApp.mainMenu = main
    }

    private func makeAppMenu() -> NSMenuItem {
        let menu = NSMenu()
        menu.addItem(
            withTitle: Localized.text("About Tailscode"),
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(item(Localized.text("Settings…"), #selector(settings), ","))
        menu.addItem(.separator())
        menu.addItem(
            withTitle: Localized.text("Hide Tailscode"), action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h")
        menu.addItem(
            withTitle: Localized.text("Quit Tailscode"),
            action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return holder(menu)
    }

    private func makeFileMenu() -> NSMenuItem {
        let menu = NSMenu(title: Localized.text("File"))
        menu.addItem(item(Localized.text("New Chat"), #selector(newChat), "n"))
        menu.addItem(.separator())
        menu.addItem(
            withTitle: Localized.text("Close"), action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w")
        return holder(menu)
    }

    private func makeEditMenu() -> NSMenuItem {
        let menu = NSMenu(title: Localized.text("Edit"))
        menu.addItem(withTitle: Localized.text("Undo"), action: Selector(("undo:")), keyEquivalent: "z")
        menu.addItem(withTitle: Localized.text("Redo"), action: Selector(("redo:")), keyEquivalent: "Z")
        menu.addItem(.separator())
        menu.addItem(withTitle: Localized.text("Cut"), action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        menu.addItem(withTitle: Localized.text("Copy"), action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        menu.addItem(withTitle: Localized.text("Paste"), action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        menu.addItem(
            withTitle: Localized.text("Select All"), action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a")
        menu.addItem(.separator())
        menu.addItem(item(Localized.text("Find in Conversation"), #selector(find), "f"))
        return holder(menu)
    }

    private func makeChatMenu() -> NSMenuItem {
        let menu = NSMenu(title: Localized.text("Chat"))
        menu.addItem(item(Localized.text("Send"), #selector(send), "\r"))
        menu.addItem(item(Localized.text("Stop Turn"), #selector(stop), "."))
        menu.addItem(.separator())
        menu.addItem(tagged(.save, Localized.text("Save"), #selector(toggleSaved), "d"))
        menu.addItem(tagged(.archive, Localized.text("Archive"), #selector(toggleArchived), "e"))
        menu.addItem(
            tagged(
                .unread, Localized.text("Mark as Unread"), #selector(toggleUnread), "u",
                [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(tagged(.rename, Localized.text("Rename…"), #selector(rename), "r"))
        menu.addItem(tagged(.fork, Localized.text("Fork"), #selector(fork), "N"))
        menu.addItem(.separator())
        menu.addItem(item(Localized.text("Copy Session ID"), #selector(copySessionID), ""))
        menu.addItem(tagged(.copyPath, Localized.text("Copy Project Path"), #selector(copyProjectPath), ""))
        menu.addItem(.separator())
        menu.addItem(item(Localized.text("Delete…"), #selector(deleteChat), "\u{08}"))
        return holder(menu)
    }

    private func makeViewMenu() -> NSMenuItem {
        let menu = NSMenu(title: Localized.text("View"))
        menu.addItem(
            item(Localized.text("Toggle Sidebar"), #selector(toggleSidebar), "s", [.command, .control]))
        menu.addItem(item(Localized.text("Files"), #selector(toggleFiles), "f", [.command, .option]))
        menu.addItem(item(Localized.text("Terminal"), #selector(toggleTerminal), "t", [.command, .option]))
        menu.addItem(
            item(Localized.text("Archived Chats"), #selector(toggleArchiveView), "e", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(item(Localized.text("Zoom In"), #selector(zoomIn), "+"))
        menu.addItem(item(Localized.text("Zoom Out"), #selector(zoomOut), "-"))
        menu.addItem(item(Localized.text("Actual Size"), #selector(zoomReset), "0"))
        menu.addItem(.separator())
        menu.addItem(item(Localized.text("Shortcuts Cheatsheet"), #selector(cheatsheet), "/"))
        return holder(menu)
    }

    private func makeGoMenu() -> NSMenuItem {
        let menu = NSMenu(title: Localized.text("Go"))
        menu.addItem(item(Localized.text("Next Chat"), #selector(nextChat), "]"))
        menu.addItem(item(Localized.text("Previous Chat"), #selector(previousChat), "["))
        return holder(menu)
    }

    private func makeWindowMenu() -> NSMenuItem {
        let menu = NSMenu(title: Localized.text("Window"))
        menu.addItem(
            withTitle: Localized.text("Minimize"),
            action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        menu.addItem(
            withTitle: Localized.text("Zoom"), action: #selector(NSWindow.performZoom(_:)),
            keyEquivalent: "")
        menu.addItem(.separator())
        menu.addItem(
            withTitle: Localized.text("Bring All to Front"),
            action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        NSApp.windowsMenu = menu
        return holder(menu)
    }

    private func makeHelpMenu() -> NSMenuItem {
        let menu = NSMenu(title: Localized.text("Help"))
        menu.addItem(item(Localized.text("Keyboard Shortcuts"), #selector(cheatsheet), ""))
        NSApp.helpMenu = menu
        return holder(menu)
    }

    /// Which items need their words or their reach re-derived from the open chat when the menu
    /// drops down.
    private enum Tag: Int {
        case save = 1
        case archive
        case unread
        case rename
        case fork
        case copyPath
    }

    private func holder(_ menu: NSMenu) -> NSMenuItem {
        let holder = NSMenuItem()
        holder.submenu = menu
        return holder
    }

    private func item(
        _ title: String, _ action: Selector, _ key: String,
        _ modifiers: NSEvent.ModifierFlags = [.command]
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.keyEquivalentModifierMask = modifiers
        item.target = self
        return item
    }

    private func tagged(
        _ tag: Tag, _ title: String, _ action: Selector, _ key: String,
        _ modifiers: NSEvent.ModifierFlags = [.command]
    ) -> NSMenuItem {
        let entry = item(title, action, key, modifiers)
        entry.tag = tag.rawValue
        return entry
    }

    @objc private func settings() { hub.presentPreferences() }
    @objc private func newChat() { hub.perform(.newChat) }
    @objc private func find() { hub.perform(.findInConversation) }
    @objc private func send() { hub.perform(.send) }
    @objc private func stop() { hub.transcript.stopTurn() }
    @objc private func toggleSaved() { hub.perform(.toggleSaved) }
    @objc private func toggleArchived() { hub.perform(.archiveSelected) }
    @objc private func toggleUnread() { hub.perform(.toggleUnreadSelected) }
    @objc private func rename() { hub.perform(.renameSelected) }
    @objc private func fork() { hub.perform(.forkSelected) }
    @objc private func copySessionID() { hub.perform(.copySessionID) }
    @objc private func copyProjectPath() { hub.perform(.copyProjectPath) }
    @objc private func deleteChat() { hub.perform(.deleteSelected) }
    @objc private func toggleSidebar() { hub.perform(.toggleSidebar) }
    @objc private func toggleFiles() { hub.perform(.toggleFiles) }
    @objc private func toggleTerminal() { hub.perform(.toggleTerminal) }
    @objc private func toggleArchiveView() { hub.perform(.toggleArchiveView) }
    @objc private func zoomIn() { hub.perform(.zoomIn) }
    @objc private func zoomOut() { hub.perform(.zoomOut) }
    @objc private func zoomReset() { hub.perform(.zoomReset) }
    @objc private func cheatsheet() { hub.perform(.toggleHelp) }
    @objc private func nextChat() { hub.perform(.selectNext) }
    @objc private func previousChat() { hub.perform(.selectPrevious) }
}

extension MainMenu: NSMenuItemValidation {
    /// The chat verbs answer for the chat that is open: absent one, they dim; Save and Mark
    /// Unread also flip their titles to describe the state they would leave behind, and Rename
    /// and Fork answer for what the server can actually do.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let chatVerbs: Set<Selector> = [
            #selector(send), #selector(stop), #selector(toggleSaved), #selector(toggleArchived),
            #selector(toggleUnread), #selector(rename), #selector(fork),
            #selector(copySessionID), #selector(copyProjectPath), #selector(deleteChat),
            #selector(find),
        ]
        guard let action = menuItem.action, chatVerbs.contains(action) else { return true }
        guard let entry = hub.currentEntry else { return false }
        switch Tag(rawValue: menuItem.tag) {
        case .save:
            menuItem.title =
                SavedChatStore.contains(entry)
                ? Localized.text("Unsave") : Localized.text("Save")
        case .archive:
            let archived = ArchivedChatStore.contains(
                profileID: entry.profileID, sessionID: entry.session.id)
            menuItem.title =
                archived ? Localized.text("Unarchive") : Localized.text("Archive")
        case .unread:
            let unread = SessionSeenStore.unreadEvaluator()(
                entry.session.id, entry.session.updatedAt)
            menuItem.title =
                unread ? Localized.text("Mark as Read") : Localized.text("Mark as Unread")
        case .rename:
            return hub.currentBackend?.capabilities.supportsRenaming == true
        case .fork:
            return hub.currentBackend?.capabilities.supportsForking == true
        case .copyPath:
            return entry.session.directory != nil
        case nil:
            break
        }
        return true
    }
}
