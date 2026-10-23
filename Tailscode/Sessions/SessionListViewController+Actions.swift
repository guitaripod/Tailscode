import TailscodeCore
import CodingAgentKit
import CodingAgentKitApple
import UIKit

extension SessionListViewController {
    func toggleArchived(_ entry: SessionEntry) {
        Theme.Haptics.tap()
        ArchivedChatStore.toggle(profileID: entry.profileID, sessionID: entry.session.id)
    }

    /// Ends the work the chat's process is carrying between turns — the command the agent left
    /// running that is never going to finish. The server says why when it cannot, and that
    /// sentence is what the person sees.
    func stopBackgroundWork(_ entry: SessionEntry) {
        Theme.Haptics.warning()
        Task { [weak self] in await self?.viewModel.stopBackgroundWork(entry) }
    }

    func togglePinned(_ entry: SessionEntry) {
        Theme.Haptics.tap()
        SessionPinStore.toggle(profileID: entry.profileID, sessionID: entry.session.id)
    }

    func toggleUnread(_ entry: SessionEntry) {
        Theme.Haptics.tap()
        let unread = SessionSeenStore.unreadEvaluator()(
            entry.session.id, entry.session.updatedAt)
        if unread {
            SessionSeenStore.markSeen(entry.session.id)
        } else {
            SessionSeenStore.markUnread(entry.session.id, updatedAt: entry.session.updatedAt)
        }
        reconfigureActivity()
    }

    func forkAndOpen(_ entry: SessionEntry) {
        Task { [weak self] in
            guard let self, let forked = await self.viewModel.fork(entry) else { return }
            Theme.Haptics.success()
            self.openChat(for: forked)
        }
    }

    func promptRename(_ entry: SessionEntry) {
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

    func confirmDelete(_ entry: SessionEntry, done: @escaping (Bool) -> Void) {
        let alert = UIAlertController(
            title: String(localized: "Delete conversation?"),
            message: String(
                localized:
                    "\"\(Self.displayTitle(entry.session.title))\" will be removed from the server."
            ),
            preferredStyle: .alert)
        alert.addAction(
            UIAlertAction(title: String(localized: "Cancel"), style: .cancel) { _ in done(false) })
        alert.addAction(
            UIAlertAction(title: String(localized: "Delete"), style: .destructive) { [weak self] _ in
            Theme.Haptics.warning()
            Task {
                await self?.viewModel.delete(entry)
                done(true)
            }
        })
        present(alert, animated: true)
    }

    static func displayTitle(_ title: String) -> String {
        guard AgentSession.isPlaceholderTitle(title) else {
            return title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? String(localized: "Empty conversation") : String(localized: "New conversation")
    }

    private static func relativeDate(_ date: Date) -> String {
        let now = Date()
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            let diff = now.timeIntervalSince(date)
            if diff < 60 { return String(localized: "Just now") }
            if diff < 3600 { return String(localized: "\(Int(diff / 60))m ago") }
            return date.formatted(.dateTime.hour().minute())
        }
        if calendar.isDateInYesterday(date) { return String(localized: "Yesterday") }
        if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    static func serverIcon(for backend: AgentType) -> UIImage? {
        UIImage(systemName: backend.symbolName)?
            .withTintColor(backend.brandColor, renderingMode: .alwaysOriginal)
    }

    @objc func refresh() { Task { await viewModel.load() } }

    func startChat(on profile: ConnectionProfile) {
        Theme.Haptics.tap()
        NewChatFlow.begin(from: self, profile: profile, viewModel: viewModel) { [weak self] entry in
            self?.openChat(for: entry)
        }
    }

    /// The board's own compose skips both questions — the scope already answered them. The mint
    /// happens straight away, exactly as choosing this server and this folder in the sheet would.
    func startChatInScope() {
        guard let scope,
            let profile = viewModel.servers.first(where: { $0.id == scope.profileID })
        else { return }
        Theme.Haptics.tap()
        Task {
            guard let entry = await viewModel.newSession(on: profile, directory: scope.directory)
            else {
                Theme.Haptics.error()
                return
            }
            Theme.Haptics.success()
            openChat(for: entry)
        }
    }

    /// A container opens a container: the board is this same listing, scoped. Leaving it is a
    /// plain pop, so the whole list is exactly where it was.
    func openProjectBoard(_ scope: ProjectScope) {
        Theme.Haptics.tap()
        let board = SessionListViewController(scope: scope)
        board.showsAsColumn = showsAsColumn
        navigationController?.pushViewController(board, animated: true)
    }

    /// A result opens the conversation it names, on the server it happened on. The listing may not
    /// carry it — a chat this device has not listed lately — so one the list cannot resolve says so
    /// instead of doing nothing.
    func openSearchResult(profileID: String, sessionID: String) {
        guard let entry = viewModel.entries.first(where: {
            $0.profileID == profileID && $0.session.id == sessionID
        }) else {
            Theme.Haptics.warning()
            let alert = UIAlertController(
                title: String(localized: "Not in the listing"),
                message: String(
                    localized: "That chat is not in this server's listing right now."),
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
            present(alert, animated: true)
            return
        }
        if !showsAsColumn { navigationController?.popViewController(animated: false) }
        SessionSeenStore.markSeen(entry.session.id)
        openChat(for: entry)
    }

    func openChat(for entry: SessionEntry) {
        guard let backend = viewModel.backend(for: entry) else { return }
        let chatViewModel =
            SessionActivity.shared.retainedViewModel(
                for: entry.session.id, contextID: entry.profileID)
            ?? ChatViewModel(
                backend: backend, session: entry.session, contextID: entry.profileID,
                serverName: entry.profileName)
        showConversation(ChatViewController(viewModel: chatViewModel))
    }

    #if DEBUG
        var tourScrollView: UIScrollView { collectionView }

        func tourSelect(_ count: Int) {
            setSelecting(true)
            for entry in visibleEntries.prefix(count) { selection.insert(entry) }
            updateSelectionBar()
            refreshVisibleRows()
        }

        func tourNewChat() {
            guard let profile = viewModel.servers.first else { return }
            startChat(on: profile)
        }

        func tourOpen(_ sessionID: String) {
            guard let entry = viewModel.entries.first(where: { $0.session.id == sessionID })
            else { return }
            SessionSeenStore.markSeen(sessionID)
            openChat(for: entry)
        }
    #endif

    func present(error message: String) {
        refreshControl.endRefreshing()
        let alert = UIAlertController(
            title: String(localized: "Something went wrong"), message: message,
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        present(alert, animated: true)
    }
}
