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
        menu.addItem(item(Localized.text("Software…"), #selector(software), ""))
        if MacProStore.shared.sellsPro {
            menu.addItem(item(ProOffer.title + "…", #selector(pro), ""))
        }
        menu.addItem(.separator())
        menu.addItem(item(Localized.text("Settings…"), #selector(settings), ","))
        menu.addItem(.separator())
        let services = NSMenu(title: Localized.text("Services"))
        menu.addItem(submenu(Localized.text("Services"), services))
        NSApp.servicesMenu = services
        menu.addItem(.separator())
        menu.addItem(
            withTitle: Localized.text("Hide Tailscode"), action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h")
        system(
            menu, Localized.text("Hide Others"),
            #selector(NSApplication.hideOtherApplications(_:)), "h", [.command, .option])
        system(menu, Localized.text("Show All"), #selector(NSApplication.unhideAllApplications(_:)))
        menu.addItem(.separator())
        menu.addItem(
            withTitle: Localized.text("Quit Tailscode"),
            action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        return holder(menu)
    }

    private func makeFileMenu() -> NSMenuItem {
        let menu = NSMenu(title: Localized.text("File"))
        menu.addItem(item(Localized.text("New Chat"), #selector(newChat), "n"))
        menu.addItem(item(Localized.text("Quick Ask…"), #selector(quickAsk), ""))
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
        system(
            menu, Localized.text("Paste and Match Style"),
            #selector(NSTextView.pasteAsPlainText(_:)), "V", [.command, .option])
        system(menu, Localized.text("Delete"), #selector(NSText.delete(_:)))
        menu.addItem(
            withTitle: Localized.text("Select All"), action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a")
        menu.addItem(.separator())
        let finding = NSMenu(title: Localized.text("Find"))
        finding.addItem(item(Localized.text("Find in Conversation"), #selector(find), "f"))
        finding.addItem(item(Localized.text("Find Next"), #selector(findNext), "g"))
        finding.addItem(item(Localized.text("Find Previous"), #selector(findPrevious), "G"))
        menu.addItem(submenu(Localized.text("Find"), finding))
        menu.addItem(.separator())
        menu.addItem(submenu(Localized.text("Spelling and Grammar"), spellingMenu()))
        menu.addItem(submenu(Localized.text("Substitutions"), substitutionsMenu()))
        menu.addItem(submenu(Localized.text("Transformations"), transformationsMenu()))
        menu.addItem(submenu(Localized.text("Speech"), speechMenu()))
        return holder(menu)
    }

    /// The text services every Mac text field answers — a prompt, a rename, a path — routed to
    /// whichever field is typing, as AppKit's own menus route them. The app's own defaults turn
    /// the rewrites off (see `AppDelegate.typeWhatIsTyped`), and this is where a person turns one
    /// back on for themselves.
    private func spellingMenu() -> NSMenu {
        let menu = NSMenu(title: Localized.text("Spelling and Grammar"))
        system(
            menu, Localized.text("Show Spelling and Grammar"),
            #selector(NSText.showGuessPanel(_:)), ":")
        system(
            menu, Localized.text("Check Document Now"), #selector(NSText.checkSpelling(_:)), ";")
        menu.addItem(.separator())
        system(
            menu, Localized.text("Check Spelling While Typing"),
            #selector(NSTextView.toggleContinuousSpellChecking(_:)))
        system(
            menu, Localized.text("Check Grammar With Spelling"),
            #selector(NSTextView.toggleGrammarChecking(_:)))
        system(
            menu, Localized.text("Correct Spelling Automatically"),
            #selector(NSTextView.toggleAutomaticSpellingCorrection(_:)))
        return menu
    }

    private func substitutionsMenu() -> NSMenu {
        let menu = NSMenu(title: Localized.text("Substitutions"))
        system(
            menu, Localized.text("Show Substitutions"),
            #selector(NSTextView.orderFrontSubstitutionsPanel(_:)))
        menu.addItem(.separator())
        system(
            menu, Localized.text("Smart Copy/Paste"),
            #selector(NSTextView.toggleSmartInsertDelete(_:)))
        system(
            menu, Localized.text("Smart Quotes"),
            #selector(NSTextView.toggleAutomaticQuoteSubstitution(_:)))
        system(
            menu, Localized.text("Smart Dashes"),
            #selector(NSTextView.toggleAutomaticDashSubstitution(_:)))
        system(
            menu, Localized.text("Smart Links"),
            #selector(NSTextView.toggleAutomaticLinkDetection(_:)))
        system(
            menu, Localized.text("Data Detectors"),
            #selector(NSTextView.toggleAutomaticDataDetection(_:)))
        system(
            menu, Localized.text("Text Replacement"),
            #selector(NSTextView.toggleAutomaticTextReplacement(_:)))
        return menu
    }

    private func transformationsMenu() -> NSMenu {
        let menu = NSMenu(title: Localized.text("Transformations"))
        system(menu, Localized.text("Make Upper Case"), #selector(NSResponder.uppercaseWord(_:)))
        system(menu, Localized.text("Make Lower Case"), #selector(NSResponder.lowercaseWord(_:)))
        system(menu, Localized.text("Capitalize"), #selector(NSResponder.capitalizeWord(_:)))
        return menu
    }

    private func speechMenu() -> NSMenu {
        let menu = NSMenu(title: Localized.text("Speech"))
        system(menu, Localized.text("Start Speaking"), #selector(NSTextView.startSpeaking(_:)))
        system(menu, Localized.text("Stop Speaking"), #selector(NSTextView.stopSpeaking(_:)))
        return menu
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
        menu.addItem(
            item(
                Localized.text("Mark / Unmark"), #selector(toggleMarked), "m",
                [.command, .shift]))
        menu.addItem(
            item(Localized.text("Select All Chats"), #selector(markAll), "a", [.command, .shift]))
        menu.addItem(.separator())
        menu.addItem(tagged(.delete, Localized.text("Delete…"), #selector(deleteChat), "\u{08}"))
        return holder(menu)
    }

    private func makeViewMenu() -> NSMenuItem {
        let menu = NSMenu(title: Localized.text("View"))
        menu.addItem(
            item(Localized.text("Toggle Sidebar"), #selector(toggleSidebar), "s", [.command, .control]))
        #if !TAILSCODE_MAS
            menu.addItem(
                item(
                    Localized.text("Terminal"), #selector(toggleTerminal), "t",
                    [.command, .option]))
        #endif
        menu.addItem(
            item(Localized.text("Archived Chats"), #selector(toggleArchiveView), "e", [.command, .shift]))
        menu.addItem(videoForgeItem())
        menu.addItem(delegateItem())
        menu.addItem(.separator())
        menu.addItem(item(Localized.text("Split Right"), #selector(splitRight), "d", [.command, .shift]))
        menu.addItem(
            item(
                Localized.text("Split Down"), #selector(splitDown), "d",
                [.command, .shift, .option]))
        menu.addItem(item(Localized.text("Close Split"), #selector(closeSplit), "w", [.command, .shift]))
        menu.addItem(
            item(Localized.text("Zoom Split"), #selector(zoomSplit), "\r", [.command, .shift]))
        menu.addItem(
            item(
                Localized.text("Focus Split Left"), #selector(focusSplitLeft), "\u{F702}",
                [.command, .option]))
        menu.addItem(
            item(
                Localized.text("Focus Split Right"), #selector(focusSplitRight), "\u{F703}",
                [.command, .option]))
        menu.addItem(
            item(
                Localized.text("Focus Split Above"), #selector(focusSplitUp), "\u{F700}",
                [.command, .option]))
        menu.addItem(
            item(
                Localized.text("Focus Split Below"), #selector(focusSplitDown), "\u{F701}",
                [.command, .option]))
        menu.addItem(item(Localized.text("Swap Split"), #selector(exchangeSplit), ""))
        menu.addItem(item(Localized.text("Even Out Splits"), #selector(equalizeSplits), ""))
        menu.addItem(.separator())
        menu.addItem(item(Localized.text("Zoom In"), #selector(zoomIn), "+"))
        let unshifted = item(Localized.text("Zoom In"), #selector(zoomIn), "=")
        unshifted.isHidden = true
        unshifted.allowsKeyEquivalentWhenHidden = true
        menu.addItem(unshifted)
        menu.addItem(item(Localized.text("Zoom Out"), #selector(zoomOut), "-"))
        menu.addItem(item(Localized.text("Actual Size"), #selector(zoomReset), "0"))
        menu.addItem(.separator())
        menu.addItem(item(Localized.text("The month in numbers"), #selector(monthInNumbers), ""))
        menu.addItem(.separator())
        menu.addItem(item(Localized.text("Shortcuts Cheatsheet"), #selector(cheatsheet), "/"))
        menu.addItem(.separator())
        system(
            menu, Localized.text("Enter Full Screen"), #selector(NSWindow.toggleFullScreen(_:)),
            "f", [.command, .control])
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
        menu.addItem(item(Localized.text("Tailscode Support"), #selector(support), ""))
        menu.addItem(item(Localized.text("Keyboard Shortcuts"), #selector(cheatsheet), ""))
        menu.addItem(.separator())
        menu.addItem(item(Localized.text("Report an Issue…"), #selector(reportIssue), ""))
        menu.addItem(item(Localized.text("Privacy Policy"), #selector(privacy), ""))
        NSApp.helpMenu = menu
        return holder(menu)
    }

    /// Where a person goes for help, the same pages the phone's settings link to.
    private enum Link {
        static let support = URL(string: "https://midgarcorp.cc/tailscode/support")!
        static let privacy = URL(string: "https://midgarcorp.cc/tailscode/privacy")!
        static let issue = URL(string: "https://github.com/guitaripod/Tailscode/issues/new")!
    }

    /// The forge's keyboard route, which stays alongside the toolbar control rather than being the
    /// only way in. Named by `ForgeEntryPoint` rather than by this menu, and explained by the one
    /// sentence that cannot go stale: the menu bar is built once at launch, so the tooltip that
    /// changes when a renderer is set up belongs on the control that redraws itself, not here.
    /// The dispatcher's keyboard route, beside the forge's: a packet is a task you start and watch,
    /// so it opens in its own window over the work rather than in a pane.
    private func delegateItem() -> NSMenuItem {
        let entry = item(DelegateEntryPoint.menuTitle, #selector(openDelegate), "d", [.command, .option])
        entry.toolTip = DelegateEntryPoint.subtitle
        return entry
    }

    private func videoForgeItem() -> NSMenuItem {
        let entry = item(ForgeEntryPoint.menuTitle, #selector(videoForge), "v", [.command, .option])
        entry.toolTip = ForgeSurface.subtitle
        return entry
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
        case delete
    }

    private func holder(_ menu: NSMenu) -> NSMenuItem {
        let holder = NSMenuItem()
        holder.submenu = menu
        return holder
    }

    private func submenu(_ title: String, _ menu: NSMenu) -> NSMenuItem {
        let holder = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        holder.submenu = menu
        return holder
    }

    /// An item AppKit answers through the responder chain — the text field that is typing, the
    /// window that is key, the application — rather than this menu.
    private func system(
        _ menu: NSMenu, _ title: String, _ action: Selector, _ key: String = "",
        _ modifiers: NSEvent.ModifierFlags = [.command]
    ) {
        let entry = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if !key.isEmpty { entry.keyEquivalentModifierMask = modifiers }
        menu.addItem(entry)
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

    /// A verb about the conversations acts in the window that holds them, so a window that was
    /// closed is brought back first: the menu bar stays when the window goes.
    private func run(_ action: KeyAction) {
        if hub.window?.isVisible != true { hub.showWindow(nil) }
        _ = hub.perform(action)
    }

    @objc private func quickAsk() { hub.summonQuickAsk() }
    @objc private func findNext() { hub.transcript.stepFind(by: 1) }
    @objc private func findPrevious() { hub.transcript.stepFind(by: -1) }
    @objc private func support() { NSWorkspace.shared.open(Link.support) }
    @objc private func reportIssue() { NSWorkspace.shared.open(Link.issue) }
    @objc private func privacy() { NSWorkspace.shared.open(Link.privacy) }
    @objc private func settings() { hub.presentPreferences() }
    @objc private func pro() { hub.presentPro() }
    @objc private func software() { hub.presentUpdates() }
    @objc private func newChat() { run(.newChat) }
    @objc private func find() { run(.findInConversation) }
    @objc private func send() { run(.send) }
    @objc private func stop() { hub.transcript.stopTurn() }
    @objc private func toggleSaved() { run(.toggleSaved) }
    @objc private func toggleArchived() { run(.archiveSelected) }
    @objc private func toggleUnread() { run(.toggleUnreadSelected) }
    @objc private func rename() { run(.renameSelected) }
    @objc private func fork() { run(.forkSelected) }
    @objc private func copySessionID() { run(.copySessionID) }
    @objc private func copyProjectPath() { run(.copyProjectPath) }
    @objc private func deleteChat() { run(.deleteSelected) }
    @objc private func toggleMarked() { run(.toggleMarked) }
    @objc private func markAll() { run(.toggleMarkAll) }
    @objc private func toggleSidebar() { run(.toggleSidebar) }
    #if !TAILSCODE_MAS
        @objc private func toggleTerminal() { run(.toggleTerminal) }
    #endif
    @objc private func toggleArchiveView() { run(.toggleArchiveView) }
    @objc private func videoForge() { hub.presentForge() }

    @objc private func openDelegate() { hub.presentDelegate() }
    @objc private func zoomIn() { run(.zoomIn) }
    @objc private func zoomOut() { run(.zoomOut) }
    @objc private func zoomReset() { run(.zoomReset) }
    @objc private func cheatsheet() { run(.toggleHelp) }
    @objc private func monthInNumbers() { hub.presentAnalytics() }
    @objc private func nextChat() { run(.selectNext) }
    @objc private func previousChat() { run(.selectPrevious) }
    @objc fileprivate func splitRight() { run(.splitPane(.horizontal)) }
    @objc fileprivate func splitDown() { run(.splitPane(.vertical)) }
    @objc fileprivate func closeSplit() { run(.closeSplit) }
    @objc fileprivate func zoomSplit() { run(.zoomSplit) }
    @objc fileprivate func focusSplitLeft() { run(.focusSplit(.left)) }
    @objc fileprivate func focusSplitRight() { run(.focusSplit(.right)) }
    @objc fileprivate func focusSplitUp() { run(.focusSplit(.up)) }
    @objc fileprivate func focusSplitDown() { run(.focusSplit(.down)) }
    @objc fileprivate func exchangeSplit() { run(.exchangeSplit) }
    @objc fileprivate func equalizeSplits() { run(.equalizeSplits) }
}

extension MainMenu: NSMenuItemValidation {
    /// The chat verbs answer for the chat that is open: absent one, they dim; Save and Mark
    /// Unread also flip their titles to describe the state they would leave behind, and Rename
    /// and Fork answer for what the server can actually do. Held marks outrank the open chat for
    /// the one verb a set changes the meaning of: Delete says how many it would take and stays
    /// reachable without an open chat, so the number is read before the menu is chosen, never
    /// after.
    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        let treeVerbs: Set<Selector> = [
            #selector(closeSplit), #selector(zoomSplit), #selector(focusSplitLeft),
            #selector(focusSplitRight), #selector(focusSplitUp), #selector(focusSplitDown),
            #selector(exchangeSplit), #selector(equalizeSplits),
        ]
        if let action = menuItem.action, treeVerbs.contains(action) {
            return hub.splitPanes.paneCount > 1
        }
        if menuItem.action == #selector(findNext) || menuItem.action == #selector(findPrevious) {
            return hub.window?.isVisible == true && hub.transcript.canStepFind
        }
        let marked = hub.sidebar.markedCount
        let chatVerbs: Set<Selector> = [
            #selector(send), #selector(stop), #selector(toggleSaved), #selector(toggleArchived),
            #selector(toggleUnread), #selector(rename), #selector(fork),
            #selector(copySessionID), #selector(copyProjectPath), #selector(deleteChat),
            #selector(toggleMarked), #selector(find),
        ]
        guard let action = menuItem.action, chatVerbs.contains(action) else { return true }
        if action == #selector(deleteChat), marked > 0 {
            menuItem.title = BulkChatCopy.button(.delete, count: marked) + "…"
            return true
        }
        guard let entry = hub.currentEntry else {
            restTitle(menuItem)
            return false
        }
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
        case .delete:
            menuItem.title = Localized.text("Delete…")
        case nil:
            break
        }
        return true
    }

    /// The words the flipping verbs wear when there is nothing for them to describe. A dimmed item
    /// still reads, and "Unsave · Unarchive · Mark as Read" over a closed conversation describes a
    /// chat that is no longer anywhere.
    private func restTitle(_ menuItem: NSMenuItem) {
        switch Tag(rawValue: menuItem.tag) {
        case .save: menuItem.title = Localized.text("Save")
        case .archive: menuItem.title = Localized.text("Archive")
        case .unread: menuItem.title = Localized.text("Mark as Unread")
        case .delete: menuItem.title = Localized.text("Delete…")
        default: break
        }
    }
}
