import AppKit
import CodingAgentKit
import CodingAgentKitApple
import TailscodeCore

extension SidebarViewController: NSMenuDelegate {
    /// The right-click menu on a chat row, exactly the Linux set. The backend lookup that gates
    /// rename, fork and delete happens on the way, so an unreachable server's row still offers
    /// what works offline.
    func menuNeedsUpdate(_ menu: NSMenu) {
        fillRowMenu(menu, row: tableView.clickedRow)
    }

    /// The menu for one row, whether a right-click opened it or the row's ellipsis did.
    func fillRowMenu(_ menu: NSMenu, row: Int) {
        menu.removeAllItems()
        menuModel = nil
        menuBackend = nil
        guard row >= 0, row < rows.count else { return }
        if case .tab(let model, _) = rows[row] {
            buildTabMenu(menu, for: model)
            return
        }
        guard case .session(let model, _, _) = rows[row] else { return }
        menuModel = model
        let entry = model.entry
        if let profile = ServerDirectory.shared.profiles.first(where: { $0.id == entry.profileID }) {
            menuBackend = ServerDirectory.shared.backend(for: profile)
        }
        if entry.session.id != selectedID {
            menu.addItem(menuItem(Localized.text("Open"), action: #selector(menuOpen)))
        }
        menu.addItem(
            menuItem(
                selection.contains(entry)
                    ? Localized.text("Unmark") : Localized.text("Mark"),
                subtitle: Localized.text("Act on several chats at once"),
                action: #selector(menuToggleMarked)))
        menu.addItem(
            menuItem(
                Localized.text("Open in a new split"),
                subtitle: Localized.text("Beside the conversations already on screen"),
                action: #selector(menuOpenInSplit)))
        let saved = SavedChatStore.contains(entry)
        menu.addItem(
            menuItem(
                saved ? Localized.text("Unsave") : Localized.text("Save"),
                subtitle: Localized.text(
                    "A saved chat lists itself even when its server is unreachable"),
                action: #selector(menuToggleSaved)))
        let archived = ArchivedChatStore.contains(
            profileID: entry.profileID, sessionID: entry.session.id)
        menu.addItem(
            menuItem(
                archived ? Localized.text("Unarchive") : Localized.text("Archive"),
                subtitle: archived
                    ? Localized.text("Back into the chat list")
                    : Localized.text("Out of the list, kept on the server"),
                action: #selector(menuToggleArchived)))
        if model.state.carriesBackgroundWork, menuBackend?.capabilities.supportsBackgroundStop == true {
            menu.addItem(
                menuItem(
                    Localized.text("Stop background work"),
                    subtitle: Localized.text("End the command the agent left running on the machine"),
                    action: #selector(menuStopBackgroundWork)))
        }
        let pinned = SessionPinStore.contains(
            profileID: entry.profileID, sessionID: entry.session.id)
        menu.addItem(
            menuItem(
                pinned ? Localized.text("Unpin") : Localized.text("Pin"),
                subtitle: pinned
                    ? Localized.text("Back into the recency order")
                    : Localized.text("Always at the top of the chat list"),
                action: #selector(menuTogglePinned)))
        menu.addItem(
            menuItem(
                model.unread
                    ? Localized.text("Mark as read") : Localized.text("Mark as unread"),
                action: #selector(menuToggleUnread)))
        if let backend = menuBackend {
            if backend.capabilities.supportsRenaming {
                menu.addItem(menuItem(Localized.text("Rename…"), action: #selector(menuRename)))
            }
            if backend.capabilities.supportsForking {
                menu.addItem(
                    menuItem(
                        Localized.text("Fork"),
                        subtitle: Localized.text(
                            "A new session with this history, for a different direction"),
                        action: #selector(menuFork)))
            }
        }
        menu.addItem(
            menuItem(
                Localized.text("Copy session ID"), subtitle: entry.session.id,
                action: #selector(menuCopyID)))
        if let directory = entry.session.directory {
            menu.addItem(
                menuItem(
                    Localized.text("Copy project path"), subtitle: directory,
                    action: #selector(menuCopyPath)))
        }
        if projectScope == nil {
            menu.addItem(
                menuItem(
                    Localized.text("Only this project"),
                    subtitle: ProjectScope(of: entry).banner(serverName: entry.profileName),
                    action: #selector(menuScopeProject)))
        } else {
            menu.addItem(
                menuItem(
                    Localized.text("Every chat"),
                    subtitle: Localized.text("Leave the project board"),
                    action: #selector(menuScopeClear)))
        }
        if menuBackend != nil {
            menu.addItem(.separator())
            menu.addItem(
                menuItem(
                    Localized.text("Delete…"),
                    subtitle: Localized.text("Remove the session from its server"),
                    destructive: true, action: #selector(menuDelete)))
        }
        guard selection.count > 1 else { return }
        menu.addItem(
            menuItem(
                BulkChatCopy.button(.delete, count: selection.count) + "…",
                subtitle: Localized.text("Every marked chat, on every server they are on"),
                destructive: true, action: #selector(menuDeleteMarked)))
    }

    /// The menu on the split's row: each chat inside it on its own, and the one gesture that
    /// takes the arrangement apart. The members are held on the controller so the items can act
    /// without a target per row.
    private func buildTabMenu(_ menu: NSMenu, for model: SplitTabRow) {
        menuTab = model
        for (index, member) in model.members.enumerated() {
            let item = menuItem(
                Localized.text("Open just %@", member.title),
                subtitle: Localized.text("Unsplit down to this one chat"),
                action: #selector(menuOpenTabMember(_:)))
            item.tag = index
            menu.addItem(item)
        }
        menu.addItem(.separator())
        menu.addItem(
            menuItem(
                Localized.text("Unsplit"),
                subtitle: Localized.text("Back to one pane; the chats keep their own rows"),
                action: #selector(menuUnsplit)))
    }

    @objc private func menuOpenTabMember(_ sender: NSMenuItem) {
        guard let members = menuTab?.members, members.indices.contains(sender.tag) else { return }
        onUnsplit?(members[sender.tag].entry)
    }

    @objc private func menuUnsplit() {
        onUnsplit?(nil)
    }

    private func menuItem(
        _ title: String, subtitle: String? = nil, destructive: Bool = false, action: Selector
    ) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        if let subtitle { item.subtitle = subtitle }
        if destructive {
            item.attributedTitle = NSAttributedString(
                string: title, attributes: [.foregroundColor: MacTheme.Color.danger])
        }
        return item
    }

    @objc private func menuOpen() {
        guard let model = menuModel else { return }
        open(model.entry)
    }

    @objc private func menuOpenInSplit() {
        guard let model = menuModel else { return }
        onOpenInSplit?(model.entry)
    }

    @objc private func menuToggleMarked() {
        guard let model = menuModel else { return }
        selection.toggle(model.entry)
        lastSidebar = nil
        render()
    }

    @objc private func menuDeleteMarked() {
        presentBulkDelete(markedModels)
    }

    @objc private func menuToggleSaved() {
        guard let model = menuModel else { return }
        toggleSaved(model.entry)
    }

    @objc private func menuToggleArchived() {
        guard let model = menuModel else { return }
        toggleArchived(model.entry)
    }

    /// Ends the work the chat's process is carrying between turns. The server says why when it
    /// cannot, and that sentence is the notice.
    @objc private func menuStopBackgroundWork() {
        guard let model = menuModel, let backend = menuBackend else { return }
        stopBackgroundWork(model.entry, on: backend)
    }

    private func stopBackgroundWork(_ entry: SessionEntry, on backend: any CodingAgentBackend) {
        Task { [weak self] in
            do {
                try await backend.stopBackgroundWork(sessionID: entry.session.id)
                self?.onNotice?(Localized.text("Stopped the background work."))
            } catch {
                self?.onNotice?(error.localizedDescription)
            }
        }
    }

    @objc private func menuTogglePinned() {
        guard let model = menuModel else { return }
        togglePinned(model.entry)
    }

    @objc private func menuScopeProject() {
        guard let model = menuModel else { return }
        setProjectScope(ProjectScope(of: model.entry))
    }

    @objc private func menuScopeClear() {
        setProjectScope(nil)
    }

    @objc private func menuToggleUnread() {
        guard let model = menuModel else { return }
        toggleUnread(model.entry)
    }

    @objc private func menuRename() {
        guard let model = menuModel, let backend = menuBackend else { return }
        presentRename(entry: model.entry, backend: backend)
    }

    @objc private func menuFork() {
        guard let model = menuModel, let backend = menuBackend else { return }
        fork(entry: model.entry, backend: backend)
    }

    @objc private func menuCopyID() {
        guard let model = menuModel else { return }
        copyToPasteboard(model.entry.session.id)
    }

    @objc private func menuCopyPath() {
        guard let directory = menuModel?.entry.session.directory else { return }
        copyToPasteboard(directory)
    }

    @objc private func menuDelete() {
        guard let model = menuModel, let backend = menuBackend else { return }
        presentDelete(entry: model.entry, backend: backend)
    }
}
