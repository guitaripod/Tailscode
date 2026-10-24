import TailscodeCore
import CodingAgentKitApple
import UIKit

extension SessionListViewController {
    @objc func handleInsertKeyCommand(_ command: UIKeyCommand) {
        guard let token = command.propertyList as? String,
            let chord = KeyBridge.chord(forToken: token)
        else { return }
        _ = KeyBridge.shared.handle(chord, context: .insert, awaitingApproval: false) {
            [weak self] action in
            self?.performKeyAction(action) ?? false
        }
    }
}

extension SessionListViewController: KeyActionHost {
    var keyContext: KeyContext {
        searchController.searchBar.searchTextField.isFirstResponder ? .insert : .normal
    }

    /// The chat list's answers to the shared registry: J/K walk a visible cursor, Enter opens
    /// it, and every row verb acts on the row under the cursor — the desktops' sidebar keys,
    /// spoken through this screen. False lets a press fall through.
    func performKeyAction(_ action: KeyAction) -> Bool {
        switch action {
        case .selectNext:
            moveCursor(by: 1)
        case .selectPrevious:
            moveCursor(by: -1)
        case .selectFirst:
            moveCursor(to: 0)
        case .selectLast:
            moveCursor(to: max(0, visibleEntries.count - 1))
        case .openSelected:
            guard let entry = cursorEntry() else { return false }
            guard !isSelecting else {
                toggleMark(entry)
                return true
            }
            SessionSeenStore.markSeen(entry.session.id)
            openChat(for: entry)
        case .scrollDown:
            moveCursor(by: 1)
        case .scrollUp:
            moveCursor(by: -1)
        case .halfPageDown:
            moveCursor(by: 8)
        case .halfPageUp:
            moveCursor(by: -8)
        case .search:
            searchController.isActive = true
            searchController.searchBar.searchTextField.becomeFirstResponder()
        case .leaveInsert:
            if !selection.isEmpty {
                selection.clear()
                updateSelectionBar()
                refreshVisibleRows()
                return true
            }
            if isSelecting {
                setSelecting(false)
                return true
            }
            guard searchController.isActive else { return false }
            searchController.isActive = false
            becomeFirstResponder()
        case .newChat:
            guard let profile = preferredServer() else { return false }
            startChat(on: profile)
        case .toggleSaved:
            guard let entry = cursorEntry() else { return false }
            Theme.Haptics.tap()
            SavedChatStore.toggle(entry)
        case .archiveSelected:
            guard let entry = cursorEntry() else { return false }
            toggleArchived(entry)
        case .toggleArchiveView:
            pushArchived()
        case .toggleAgents:
            AgentsPresenter.toggle(from: self)
        case .toggleUnreadSelected:
            guard let entry = cursorEntry() else { return false }
            toggleUnread(entry)
        case .renameSelected:
            guard let entry = cursorEntry(), viewModel.supportsRenaming(entry) else {
                return false
            }
            promptRename(entry)
        case .forkSelected:
            guard let entry = cursorEntry(), viewModel.supportsForking(entry) else {
                return false
            }
            forkAndOpen(entry)
        case .toggleMarked:
            guard let entry = cursorEntry() else { return false }
            if !isSelecting { setSelecting(true) }
            toggleMark(entry)
        case .toggleMarkAll:
            guard !visibleEntries.isEmpty else { return false }
            if !isSelecting { setSelecting(true) }
            toggleMarkAll()
        case .deleteSelected:
            let marked = targets(for: .delete, in: selection.resolve(in: visibleEntries))
            guard marked.isEmpty else {
                confirmBulkDelete(marked)
                return true
            }
            guard let entry = cursorEntry(), viewModel.supportsMultipleSessions(entry) else {
                return false
            }
            confirmDelete(entry) { _ in }
        case .copySessionID:
            guard let entry = cursorEntry() else { return false }
            UIPasteboard.general.string = entry.session.id
            Theme.Haptics.success()
        case .copyProjectPath:
            guard let entry = cursorEntry(), let directory = entry.session.directory else {
                return false
            }
            UIPasteboard.general.string = directory
            Theme.Haptics.success()
        case .reload:
            Task { await viewModel.load() }
        case .toggleProjectScope:
            if scope != nil {
                navigationController?.popViewController(animated: true)
                return true
            }
            guard let entry = cursorEntry() else { return false }
            openProjectBoard(ProjectScope(of: entry))
        case .toggleHelp:
            ShortcutCheatsheetViewController.present(from: self)
        case .toggleSidebar:
            guard let workspace else { return false }
            workspace.toggleColumns()
        default:
            return false
        }
        return true
    }

    /// The cursor is a flat position over every row on screen, not an offset into one section: a
    /// pinned chat or a WORKING heading used to leave the keyboard verbs acting on a row the
    /// person was not looking at. Never addresses a snapshot by a hardcoded section.
    private func cursorEntry() -> SessionEntry? {
        guard let keyCursor, visibleEntries.indices.contains(keyCursor) else { return nil }
        return visibleEntries[keyCursor]
    }

    private func moveCursor(by delta: Int) {
        let count = visibleEntries.count
        guard count > 0 else { return }
        moveCursor(to: max(0, min(count - 1, (keyCursor ?? (delta > 0 ? -1 : count)) + delta)))
    }

    private func moveCursor(to index: Int) {
        guard visibleEntries.indices.contains(index) else { return }
        keyCursor = index
        guard let indexPath = dataSource.indexPath(for: visibleEntries[index]) else { return }
        collectionView.selectItem(
            at: indexPath, animated: true, scrollPosition: .centeredVertically)
    }

    /// The machine a new chat opens on before anyone chooses: the one the last chat was started
    /// on, since one machine is the overwhelmingly common answer and the modal can still switch.
    /// Never asks the server question ahead of the modal that already asks it.
    private func preferredServer() -> ConnectionProfile? {
        let remembered = AppPreferences.lastComposeTarget?.profileID
        return viewModel.servers.first { $0.id == remembered } ?? viewModel.servers.first
    }
}
