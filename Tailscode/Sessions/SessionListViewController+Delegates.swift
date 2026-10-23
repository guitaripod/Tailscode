import TailscodeCore
import UIKit

extension SessionListViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        if !showsAsColumn || isSelecting { collectionView.deselectItem(at: indexPath, animated: true) }
        guard let entry = dataSource.itemIdentifier(for: indexPath) else { return }
        keyCursor = visibleEntries.firstIndex(of: entry)
        guard !isSelecting else {
            toggleMark(entry)
            return
        }
        openChat(for: entry)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard !isSelecting, let indexPath = indexPaths.first,
            let entry = dataSource.itemIdentifier(for: indexPath)
        else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) {
            [weak self] _ in
            guard let self else { return UIMenu() }
            var actions: [UIMenuElement] = []
            if SceneRouting.supportsMultipleWindows,
                let url = SceneRouting.sessionURL(entry.session.id)
            {
                actions.append(
                    UIAction(
                        title: String(localized: "Open in New Window"),
                        image: UIImage(systemName: "rectangle.badge.plus")
                    ) { _ in
                        Theme.Haptics.tap()
                        SceneRouting.openInNewWindow(url)
                    })
            }
            if let directory = entry.session.directory,
                let profile = self.viewModel.servers.first(where: { $0.id == entry.profileID })
            {
                actions.append(
                    UIAction(
                        title: String(localized: "New chat in same project"),
                        image: UIImage(systemName: "plus.bubble")
                    ) { [weak self] _ in
                        Task {
                            guard let self,
                                let new = await self.viewModel.newSession(
                                    on: profile, directory: directory)
                            else { return }
                            Theme.Haptics.success()
                            self.openChat(for: new)
                        }
                    })
            }
            if self.scope == nil {
                let rowScope = ProjectScope(of: entry)
                actions.append(
                    UIAction(
                        title: String(localized: "Only this project"),
                        subtitle: rowScope.banner(serverName: entry.profileName),
                        image: UIImage(systemName: "folder")
                    ) { [weak self] _ in
                        self?.openProjectBoard(rowScope)
                    })
            }
            let isSaved = SavedChatStore.contains(entry)
            actions.append(
                UIAction(
                    title: isSaved
                        ? String(localized: "Remove from Saved") : String(localized: "Save chat"),
                    image: UIImage(systemName: isSaved ? "bookmark.slash" : "bookmark")
                ) { _ in
                    Theme.Haptics.tap()
                    SavedChatStore.toggle(entry)
                })
            let isArchived = ArchivedChatStore.contains(
                profileID: entry.profileID, sessionID: entry.session.id)
            actions.append(
                UIAction(
                    title: isArchived
                        ? String(localized: "Unarchive") : String(localized: "Archive"),
                    subtitle: isArchived
                        ? String(localized: "Back into the chat list")
                        : String(localized: "Out of the list, kept on the server"),
                    image: UIImage(systemName: isArchived ? "tray.and.arrow.up" : "archivebox")
                ) { [weak self] _ in
                    self?.toggleArchived(entry)
                })
            let isPinned = SessionPinStore.contains(
                profileID: entry.profileID, sessionID: entry.session.id)
            actions.append(
                UIAction(
                    title: isPinned ? String(localized: "Unpin") : String(localized: "Pin"),
                    subtitle: isPinned
                        ? String(localized: "Back into the recency order")
                        : String(localized: "Always at the top of the chat list"),
                    image: UIImage(systemName: isPinned ? "pin.slash" : "pin")
                ) { [weak self] _ in
                    self?.togglePinned(entry)
                })
            let isUnread = SessionSeenStore.unreadEvaluator()(
                entry.session.id, entry.session.updatedAt)
            actions.append(
                UIAction(
                    title: isUnread
                        ? String(localized: "Mark as read") : String(localized: "Mark as unread"),
                    image: UIImage(systemName: isUnread ? "envelope.open" : "envelope.badge")
                ) { [weak self] _ in
                    self?.toggleUnread(entry)
                })
            if self.viewModel.supportsRenaming(entry) {
                actions.append(
                    UIAction(
                        title: String(localized: "Rename"), image: UIImage(systemName: "pencil")
                    ) {
                        [weak self] _ in
                        self?.promptRename(entry)
                    })
            }
            if self.viewModel.supportsForking(entry) {
                actions.append(
                    UIAction(
                        title: String(localized: "Fork"),
                        subtitle: String(
                            localized: "A new session with this history, for a different direction"),
                        image: UIImage(systemName: "arrow.triangle.branch")
                    ) { [weak self] _ in
                        self?.forkAndOpen(entry)
                    })
            }
            actions.append(
                UIAction(
                    title: String(localized: "Copy title"),
                    image: UIImage(systemName: "doc.on.doc")
                ) { _ in
                    UIPasteboard.general.string = entry.session.title
                    Theme.Haptics.success()
                })
            if self.viewModel.supportsMultipleSessions(entry) {
                actions.append(
                    UIAction(
                        title: String(localized: "Delete"), image: UIImage(systemName: "trash"),
                        attributes: .destructive
                    ) { [weak self] _ in
                        self?.confirmDelete(entry) { _ in }
                    })
            }
            return UIMenu(children: actions)
        }
    }
}

extension SessionListViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        searchQuery = searchController.searchBar.text?.trimmingCharacters(in: .whitespaces) ?? ""
        applySnapshot()
    }
}

/// The search bar narrows the rows it already holds while it is typed in, and searches what was
/// actually said when it is submitted. The two are different questions and the second one takes a
/// network, so it gets a screen of its own rather than replacing the list under the keyboard.
extension SessionListViewController: UISearchBarDelegate {
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        let query = searchBar.text?.trimmingCharacters(in: .whitespaces) ?? ""
        guard TranscriptSearch.isSearchable(query) else { return }
        Theme.Haptics.tap()
        searchBar.resignFirstResponder()
        let entries = viewModel.entries
        let sources = viewModel.servers.compactMap { profile in
            viewModel.backend(forProfileID: profile.id).map {
                TranscriptSearch.Source(
                    profileID: profile.id,
                    name: ServerLabel.display(name: profile.name, backend: profile.backend),
                    backend: $0,
                    entries: entries.filter { $0.profileID == profile.id })
            }
        }
        navigationController?.pushViewController(
            TranscriptSearchViewController(query: query, sources: sources) { [weak self] profileID, sessionID in
                self?.openSearchResult(profileID: profileID, sessionID: sessionID)
            }, animated: true)
    }
}

/// A row lifted out of the list and dropped beside the window opens that conversation in a window
/// of its own — the iPad's gesture for "both of these at once", on the same route the context
/// menu's Open in New Window takes.
extension SessionListViewController: UICollectionViewDragDelegate {
    func collectionView(
        _ collectionView: UICollectionView, itemsForBeginning session: UIDragSession,
        at indexPath: IndexPath
    ) -> [UIDragItem] {
        guard !isSelecting, SceneRouting.supportsMultipleWindows,
            let entry = dataSource.itemIdentifier(for: indexPath),
            let url = SceneRouting.sessionURL(entry.session.id)
        else { return [] }
        let provider = NSItemProvider()
        provider.registerObject(SceneRouting.activity(for: url, title: entry.session.title), visibility: .all)
        let item = UIDragItem(itemProvider: provider)
        item.localObject = entry
        return [item]
    }
}
