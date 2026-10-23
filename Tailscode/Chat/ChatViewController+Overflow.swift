import TailscodeCore
import CodingAgentKit
import UIKit

extension ChatViewController {
    func updateOverflowBadge(hasPermission: Bool) {
        guard let barItem = navigationItem.rightBarButtonItems?.first else { return }
        let shown = (item: ObjectIdentifier(barItem), hasPermission: hasPermission)
        guard shownOverflowBadge?.item != shown.item
            || shownOverflowBadge?.hasPermission != shown.hasPermission
        else { return }
        shownOverflowBadge = shown
        barItem.image = UIImage(systemName: "ellipsis.circle")
        barItem.tintColor = hasPermission ? Theme.Color.warning : nil
    }

    func overflowBarButton() -> UIBarButtonItem {
        let jump = UIDeferredMenuElement.uncached { [weak self] completion in
            guard let self else { return completion([]) }
            let prompts = self.orderedIDs.compactMap { id -> UIAction? in
                guard let row = self.rowsByID[id], row.role == .user,
                    case .text(let text) = row.content
                else { return nil }
                return UIAction(title: String(text.prefix(50))) { [weak self] _ in
                    self?.scrollTo(id: id)
                }
            }
            guard !prompts.isEmpty else { return completion([]) }
            completion([
                UIMenu(
                    title: String(localized: "Jump to message"),
                    image: UIImage(systemName: "list.bullet"),
                    children: Array(prompts.suffix(20)))
            ])
        }
        let usage = UIDeferredMenuElement.uncached { [weak self] completion in
            Task { @MainActor in
                guard let self, self.viewModel.supportsUsage, let usage = await self.viewModel.usage() else { return completion([]) }
                var parts: [String] = []
                if let tokens = usage.tokens {
                    parts.append(
                        String(localized: "\(tokens.formatted(.number.notation(.compactName))) tokens"))
                }
                if let cost = usage.costUSD {
                    parts.append(String(format: "$%.3f", cost))
                }
                guard !parts.isEmpty else { return completion([]) }
                let item = UIAction(
                    title: String(localized: "Last turn · \(parts.joined(separator: " · "))"),
                    image: UIImage(systemName: "gauge.with.dots.needle.bottom.50percent"),
                    attributes: .disabled
                ) { _ in }
                completion([item])
            }
        }
        let regenerate = UIDeferredMenuElement.uncached { [weak self] completion in
            guard let self, self.viewModel.canRegenerate else { return completion([]) }
            completion([
                UIAction(
                    title: String(localized: "Regenerate"),
                    image: UIImage(systemName: "arrow.clockwise")
                ) {
                    [weak self] _ in
                    Theme.Haptics.tap()
                    self?.viewModel.regenerate()
                }
            ])
        }
        let subagents = UIDeferredMenuElement.uncached { [weak self] completion in
            guard let self, self.viewModel.supportsSubagents else {
                return completion([])
            }
            let agents = self.viewModel.trackedSubagents
            guard !agents.isEmpty else { return completion([]) }
            let live = self.viewModel.subagentPresence.liveCount
            let title =
                live > 0
                ? String(localized: "Agents (\(agents.count) · \(live) live)")
                : String(localized: "Agents (\(agents.count))")
            completion([
                UIAction(
                    title: title,
                    image: UIImage(systemName: "point.3.connected.trianglepath.dotted")
                ) { [weak self] _ in self?.presentSubagents(agents) }
            ])
        }
        let save = UIDeferredMenuElement.uncached { [weak self] completion in
            guard let self else { return completion([]) }
            let isSaved = SavedChatStore.contains(
                profileID: self.viewModel.contextID, sessionID: self.viewModel.session.id)
            completion([
                UIAction(
                    title: isSaved
                        ? String(localized: "Remove from Saved") : String(localized: "Save chat"),
                    image: UIImage(systemName: isSaved ? "bookmark.fill" : "bookmark")
                ) { [weak self] _ in self?.toggleSaved() }
            ])
        }
        let marks = UIDeferredMenuElement.uncached { [weak self] completion in
            guard let self else { return completion([]) }
            let profileID = self.viewModel.contextID
            let sessionID = self.viewModel.session.id
            let pinned = SessionPinStore.contains(profileID: profileID, sessionID: sessionID)
            let archived = ArchivedChatStore.contains(profileID: profileID, sessionID: sessionID)
            completion([
                UIAction(
                    title: pinned ? String(localized: "Unpin") : String(localized: "Pin"),
                    image: UIImage(systemName: pinned ? "pin.slash" : "pin")
                ) { _ in
                    Theme.Haptics.tap()
                    SessionPinStore.toggle(profileID: profileID, sessionID: sessionID)
                },
                UIAction(
                    title: String(localized: "Mark as unread"),
                    image: UIImage(systemName: "envelope.badge")
                ) { [weak self] _ in self?.markUnreadFromHere() },
                UIAction(
                    title: archived
                        ? String(localized: "Unarchive") : String(localized: "Archive"),
                    image: UIImage(systemName: archived ? "tray.and.arrow.up" : "archivebox")
                ) { [weak self] _ in self?.toggleArchivedFromHere() },
            ])
        }
        let commands = UIDeferredMenuElement.uncached { [weak self] completion in
            guard let self, !self.viewModel.composerCommands.isEmpty else { return completion([]) }
            completion([
                UIAction(
                    title: String(localized: "Commands (\(self.viewModel.composerCommands.count))"),
                    image: UIImage(systemName: "square.grid.2x2")
                ) { [weak self] _ in self?.presentCommandCatalog() }
            ])
        }
        var children: [UIMenuElement] = [
            UIAction(
                title: String(localized: "Find in conversation"),
                image: UIImage(systemName: "magnifyingglass")
            ) { [weak self] _ in self?.openFind() }
        ]
        children += [commands, jump, subagents, regenerate, usage, save, marks]
        children.append(
            UIAction(
                title: String(localized: "Share transcript"),
                image: UIImage(systemName: "square.and.arrow.up")
            ) { [weak self] _ in self?.shareTranscript() })
        if viewModel.canRename {
            children.append(
                UIAction(
                    title: String(localized: "Rename"), image: UIImage(systemName: "pencil")
                ) {
                    [weak self] _ in self?.promptRename()
                })
        }
        if viewModel.supportsCompaction {
            children.append(
                UIAction(
                    title: String(localized: "Compact conversation"),
                    image: UIImage(systemName: "arrow.down.right.and.arrow.up.left")
                ) { [weak self] _ in self?.presentCompactPreflight() })
        }
        if viewModel.supportsDelegate {
            children.append(
                UIAction(
                    title: DelegateHandoff.menuTitle,
                    image: UIImage(systemName: DelegateEntryPoint.symbol)
                ) { [weak self] _ in self?.handOff(goal: "") })
        }
        if viewModel.canFork {
            children.append(
                UIAction(
                    title: String(localized: "Fork conversation"),
                    image: UIImage(systemName: "arrow.triangle.branch")
                ) { [weak self] _ in self?.forkConversation() })
        }
        if viewModel.canClear {
            children.append(
                UIAction(
                    title: String(localized: "Clear conversation"),
                    image: UIImage(systemName: "eraser"),
                    attributes: .destructive
                ) { [weak self] _ in self?.confirmClear() })
        }
        return UIBarButtonItem(
            image: UIImage(systemName: "ellipsis.circle"),
            menu: UIMenu(children: children))
    }

    /// A chat set aside as unread from inside it stays unread: leaving it, or the next line
    /// arriving in it, must not read it again. Left alone, the screen the reader is looking at
    /// would undo the press the moment it drew the next frame.
    private func markUnreadFromHere() {
        setAsideUnread = true
        SessionSeenStore.markUnread(
            viewModel.session.id, updatedAt: viewModel.sessionSnapshot.updatedAt)
        Theme.Haptics.tap()
        presentToast(String(localized: "Marked as unread"))
    }

    func toggleArchivedFromHere() {
        let archived = ArchivedChatStore.toggle(
            profileID: viewModel.contextID, sessionID: viewModel.session.id)
        Theme.Haptics.tap()
        presentToast(
            archived
                ? String(localized: "Archived — hidden from the list, kept on the server")
                : String(localized: "Back in the chat list"))
    }

    /// Saving from inside a conversation is the moment it usually matters, and
    /// the only entry point where the chat's own title is what gets kept.
    func toggleSaved() {
        let entry = SessionEntry(
            profileID: viewModel.contextID,
            profileName: viewModel.serverName.isEmpty
                ? viewModel.backend.agentType.displayName : viewModel.serverName,
            host: viewModel.serverName,
            backendType: viewModel.backend.agentType,
            session: viewModel.sessionSnapshot)
        if SavedChatStore.toggle(entry) {
            Theme.Haptics.success()
            presentToast(String(localized: "Saved — find it under Saved in Chats."))
        } else {
            Theme.Haptics.tap()
            presentToast(String(localized: "Removed from Saved."))
        }
    }
}
