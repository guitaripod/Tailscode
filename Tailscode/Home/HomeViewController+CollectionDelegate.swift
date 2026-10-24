import TailscodeCore
import CodingAgentKit
import UIKit

extension HomeViewController: UICollectionViewDelegate {
    func collectionView(
        _ collectionView: UICollectionView, didHighlightItemAt indexPath: IndexPath
    ) {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .chat(let card): warm(card.entry)
        case .ask(let card): warm(card.entry)
        default: break
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        releaseDeferredSnapshotIfNeeded()
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        switch item {
        case .alert:
            onOpenSettings?()
        case .status:
            presentAgents()
        case .demoNudge, .supporter, .placeholder:
            break
        case .glance:
            pushUsage()
        case .chat(let card):
            openChat(for: card.entry)
        case .ask(let card):
            openChat(for: card.entry)
        case .quota:
            pushUsage()
        case .saved(let card):
            openSaved(card.chat)
        case .more(let card):
            if card.band == .saved { pushSaved() } else { pushChats() }
        }
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first,
            let item = dataSource.itemIdentifier(for: indexPath)
        else { return nil }
        switch item {
        case .saved(let card):
            return savedMenu(for: card.chat)
        case .chat(let card):
            return sessionMenu(for: card.entry, allowDelete: !card.row.state.isInFlight)
        case .ask(let card):
            return sessionMenu(for: card.entry, allowDelete: false)
        case .status, .glance, .quota, .alert, .demoNudge, .supporter, .more, .placeholder:
            return nil
        }
    }

    private func savedMenu(for chat: SavedChat) -> UIContextMenuConfiguration {
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            UIMenu(children: [
                UIAction(
                    title: String(localized: "Open"), image: UIImage(systemName: "bubble.left")
                ) { _ in
                    self?.openSaved(chat)
                },
                UIAction(
                    title: String(localized: "Remove from Saved"),
                    image: UIImage(systemName: "bookmark.slash"),
                    attributes: .destructive
                ) { _ in
                    Theme.Haptics.tap()
                    SavedChatStore.remove(profileID: chat.profileID, sessionID: chat.sessionID)
                },
            ])
        }
    }

    /// Long-press on a session card mirrors the Chats screen's row menu, so
    /// managing a conversation never requires leaving Home.
    private func sessionMenu(
        for entry: SessionEntry, allowDelete: Bool
    ) -> UIContextMenuConfiguration {
        UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            guard let self else { return UIMenu() }
            var actions: [UIMenuElement] = [
                UIAction(
                    title: String(localized: "Open"), image: UIImage(systemName: "bubble.left")
                ) {
                    [weak self] _ in self?.openChat(for: entry)
                }
            ]
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
                actions.append(
                    UIAction(
                        title: String(localized: "Chats in \(ProjectScope(of: entry).name)"),
                        image: UIImage(systemName: "folder")
                    ) { [weak self] _ in self?.openProjectBoard(for: ProjectScope(of: entry)) })
            }
            let isSaved = SavedChatStore.contains(entry)
            actions.append(
                UIAction(
                    title: isSaved
                        ? String(localized: "Remove from Saved") : String(localized: "Save chat"),
                    image: UIImage(systemName: isSaved ? "bookmark.slash" : "bookmark")
                ) { [weak self] _ in
                    Theme.Haptics.tap()
                    SavedChatStore.toggle(entry)
                    self?.applySnapshot()
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
                ) { _ in
                    Theme.Haptics.tap()
                    ArchivedChatStore.toggle(
                        profileID: entry.profileID, sessionID: entry.session.id)
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
                ) { _ in
                    Theme.Haptics.tap()
                    SessionPinStore.toggle(
                        profileID: entry.profileID, sessionID: entry.session.id)
                })
            let isUnread = SessionSeenStore.unreadEvaluator()(
                entry.session.id, entry.session.updatedAt)
            actions.append(
                UIAction(
                    title: isUnread
                        ? String(localized: "Mark as read") : String(localized: "Mark as unread"),
                    image: UIImage(systemName: isUnread ? "envelope.open" : "envelope.badge")
                ) { [weak self] _ in
                    Theme.Haptics.tap()
                    if isUnread {
                        SessionSeenStore.markSeen(entry.session.id)
                    } else {
                        SessionSeenStore.markUnread(
                            entry.session.id, updatedAt: entry.session.updatedAt)
                    }
                    self?.applySnapshot()
                })
            if self.viewModel.supportsRenaming(entry) {
                actions.append(
                    UIAction(
                        title: String(localized: "Rename"), image: UIImage(systemName: "pencil")
                    ) {
                        [weak self] _ in self?.promptRename(entry)
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
                        Task { [weak self] in
                            guard let self, let forked = await self.viewModel.fork(entry)
                            else { return }
                            Theme.Haptics.success()
                            self.openChat(for: forked)
                        }
                    })
            }
            if allowDelete, self.viewModel.supportsMultipleSessions(entry) {
                actions.append(
                    UIAction(
                        title: String(localized: "Delete"), image: UIImage(systemName: "trash"),
                        attributes: .destructive
                    ) { [weak self] _ in self?.confirmDelete(entry) })
            }
            return UIMenu(children: actions)
        }
    }

    private func promptRename(_ entry: SessionEntry) {
        let alert = UIAlertController(
            title: String(localized: "Rename conversation"), message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = entry.session.title
            field.clearButtonMode = .whileEditing
            field.autocapitalizationType = .sentences
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(
            UIAlertAction(title: String(localized: "Rename"), style: .default) {
                [weak self, weak alert] _ in
            let title = alert?.textFields?.first?.text?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty, title != entry.session.title else { return }
            Theme.Haptics.success()
            Task { await self?.viewModel.rename(entry, to: title) }
        })
        present(alert, animated: true)
    }

    private func confirmDelete(_ entry: SessionEntry) {
        let alert = UIAlertController(
            title: String(localized: "Delete conversation?"),
            message: String(
                localized:
                    "\"\(SessionListViewController.displayTitle(entry.session.title))\" will be removed from the server."
            ),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(
            UIAlertAction(title: String(localized: "Delete"), style: .destructive) { [weak self] _ in
            Theme.Haptics.warning()
            Task { await self?.viewModel.delete(entry) }
        })
        present(alert, animated: true)
    }
}
