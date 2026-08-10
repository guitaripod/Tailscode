import TailscodeCore
import CodingAgentKit
import CodingAgentKitApple
import UIKit

/// The chats the user chose to keep, drawn from the local store first so the
/// screen is useful before — and without — a network answer. Live data only ever
/// adds to a row: whether it changed, whether it is running, or whether it is no
/// longer reachable.
@MainActor
final class SavedChatsViewController: UIViewController {
    private enum Section { case main }

    /// What the servers had to say about a saved chat. `unknown` is the honest
    /// state before any listing lands, and the reason no row is ever accused of
    /// being missing just because the app has not finished loading.
    private enum Availability {
        case unknown
        case live
        case offline
        case missing
        case serverRemoved

        var isOpenable: Bool { self != .missing && self != .serverRemoved }
    }

    private struct Row: Hashable {
        let chat: SavedChat
        let availability: Availability
        let unread: Bool
        let isRunning: Bool

        static func == (lhs: Row, rhs: Row) -> Bool { lhs.chat == rhs.chat }
        func hash(into hasher: inout Hasher) { hasher.combine(chat) }
    }

    private let viewModel: SessionListViewModel
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Row>!
    private let refreshControl = UIRefreshControl()
    private let searchController = UISearchController(searchResultsController: nil)
    private var saved: [SavedChat] = []
    private var searchQuery = ""
    private var hasLoadedOnce = false
    private var hasAppeared = false

    init() {
        let sources = ConnectionController.shared.allBackends().map {
            SessionListViewModel.Source(profile: $0.profile, backend: $0.backend)
        }
        self.viewModel = SessionListViewModel(sources: sources)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Saved")
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = Theme.Color.groupedBackground
        configureSearch()
        configureCollectionView()
        configureDataSource()
        saved = SavedChatStore.all()
        applySnapshot()
        NotificationCenter.default.addObserver(
            self, selector: #selector(storeDidChange), name: SavedChatStore.didChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(activityDidChange), name: SessionActivity.didChange,
            object: nil)
        viewModel.onChange = { [weak self] in
            self?.hasLoadedOnce = true
            self?.applySnapshot()
        }
        Task { await load() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        saved = SavedChatStore.all()
        applySnapshot()
        if hasAppeared { Task { await load() } }
        hasAppeared = true
    }

    @objc private func storeDidChange() {
        saved = SavedChatStore.all()
        applySnapshot()
    }

    @objc private func activityDidChange() { applySnapshot() }

    @objc private func refresh() { Task { await load() } }

    private func load() async {
        await viewModel.load()
        hasLoadedOnce = true
        SavedChatStore.reconcile(with: viewModel.entries)
        saved = SavedChatStore.all()
        refreshControl.endRefreshing()
        applySnapshot()
    }

    private func configureSearch() {
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = String(localized: "Search saved")
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
        definesPresentationContext = true
    }

    private func configureCollectionView() {
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .none
        config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            guard let self, let row = self.dataSource.itemIdentifier(for: indexPath) else {
                return nil
            }
            let remove = UIContextualAction(
                style: .destructive, title: String(localized: "Remove")
            ) { _, _, done in
                Theme.Haptics.tap()
                SavedChatStore.remove(
                    profileID: row.chat.profileID, sessionID: row.chat.sessionID)
                done(true)
            }
            remove.image = UIImage(systemName: "bookmark.slash")
            remove.backgroundColor = Theme.Color.warning
            return UISwipeActionsConfiguration(actions: [remove])
        }
        let layout = UICollectionViewCompositionalLayout.list(using: config)
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.refreshControl = refreshControl
        refreshControl.addTarget(self, action: #selector(refresh), for: .valueChanged)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func configureDataSource() {
        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, Row> { cell, _, row in
            var content = UIListContentConfiguration.subtitleCell()
            content.text = row.chat.displayTitle
            content.textProperties.font = row.unread
                ? Theme.Ramp.font(.rowTitleStrong) : Theme.Ramp.font(.rowTitle)
            content.textProperties.numberOfLines = 1
            content.secondaryText = Self.detail(for: row)
            content.secondaryTextProperties.font = Theme.Ramp.font(.panelFootnote)
            content.secondaryTextProperties.color = Self.detailColor(for: row)
            content.secondaryTextProperties.numberOfLines = 1
            content.textToSecondaryTextVerticalPadding = 2

            let tint: UIColor =
                row.isRunning
                ? Theme.Color.success
                : (row.availability.isOpenable ? row.chat.backend.brandColor : Theme.Color.tertiaryLabel)
            content.image = UIImage(systemName: row.chat.backend.symbolName)?
                .withTintColor(tint, renderingMode: .alwaysOriginal)
            content.imageProperties.maximumSize = CGSize(width: 20, height: 20)
            content.imageProperties.reservedLayoutSize = CGSize(width: 20, height: 20)
            content.imageToTextPadding = Theme.Spacing.m
            cell.contentConfiguration = content
            cell.contentView.alpha = row.availability.isOpenable ? 1 : 0.55

            var accessories: [UICellAccessory] = []
            if row.isRunning {
                let dot = UIView(frame: CGRect(x: 0, y: 0, width: 8, height: 8))
                dot.backgroundColor = Theme.Color.success
                dot.layer.cornerRadius = 4
                accessories.append(
                    .customView(
                        configuration: .init(customView: dot, placement: .trailing(displayed: .always))))
            } else if row.unread {
                let dot = UIView(frame: CGRect(x: 0, y: 0, width: 8, height: 8))
                dot.backgroundColor = Theme.Color.accent
                dot.layer.cornerRadius = 4
                accessories.append(
                    .customView(
                        configuration: .init(customView: dot, placement: .trailing(displayed: .always))))
            }
            if row.availability.isOpenable { accessories.append(.disclosureIndicator()) }
            cell.accessories = accessories
            cell.accessibilityValue = Self.detail(for: row)
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
            collectionView, indexPath, row in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: row)
        }
    }

    /// The second line answers "can I open this, and did anything happen in it".
    /// A row that cannot be opened says why instead of pretending to be normal.
    private static func detail(for row: Row) -> String {
        switch row.availability {
        case .missing:
            return String(localized: "No longer on \(row.chat.profileName)")
        case .serverRemoved:
            return String(localized: "Server removed — saved copy only")
        case .offline:
            return String(
                localized:
                    "\(row.chat.profileName) unreachable · saved \(row.chat.savedAt.formatted(.relative(presentation: .named)))"
            )
        case .live, .unknown:
            var parts = [row.chat.profileName]
            if let project = row.chat.projectName { parts.append(project) }
            parts.append(row.chat.updatedAt.formatted(.relative(presentation: .named)))
            return parts.joined(separator: " · ")
        }
    }

    private static func detailColor(for row: Row) -> UIColor {
        switch row.availability {
        case .missing, .serverRemoved: return Theme.Color.warning
        case .offline, .live, .unknown: return Theme.Color.tertiaryLabel
        }
    }

    private func availability(for chat: SavedChat) -> Availability {
        guard viewModel.servers.contains(where: { $0.id == chat.profileID }) else {
            return .serverRemoved
        }
        if viewModel.entries.contains(where: {
            $0.profileID == chat.profileID && $0.session.id == chat.sessionID
        }) {
            return .live
        }
        if viewModel.unreachable.contains(chat.profileID) { return .offline }
        return hasLoadedOnce ? .missing : .unknown
    }

    /// Rows that can still be opened lead; a chat whose conversation is gone is kept for tidying
    /// up, not for reaching, so it never heads the list.
    private func rows() -> [Row] {
        let isUnread = SessionSeenStore.unreadEvaluator()
        let matching = saved.filter { chat in
            guard !searchQuery.isEmpty else { return true }
            return chat.title.localizedCaseInsensitiveContains(searchQuery)
                || chat.profileName.localizedCaseInsensitiveContains(searchQuery)
                || (chat.directory?.localizedCaseInsensitiveContains(searchQuery) ?? false)
        }
        return matching.map { chat in
            let state = availability(for: chat)
            return Row(
                chat: chat,
                availability: state,
                unread: state.isOpenable && isUnread(chat.sessionID, chat.updatedAt),
                isRunning: state.isOpenable && isRunning(chat))
        }
        .sorted { lhs, rhs in
            if lhs.availability.isOpenable != rhs.availability.isOpenable {
                return lhs.availability.isOpenable
            }
            return lhs.chat.savedAt > rhs.chat.savedAt
        }
    }

    private func isRunning(_ chat: SavedChat) -> Bool {
        if SessionActivity.shared.status(for: chat.sessionID) != .idle { return true }
        return viewModel.entries.first {
            $0.profileID == chat.profileID && $0.session.id == chat.sessionID
        }?.session.isActive == true
    }

    private func applySnapshot() {
        guard dataSource != nil else { return }
        let rows = rows()
        var snapshot = NSDiffableDataSourceSnapshot<Section, Row>()
        snapshot.appendSections([.main])
        snapshot.appendItems(rows, toSection: .main)
        let existing = Set(dataSource.snapshot().itemIdentifiers)
        let carried = rows.filter { existing.contains($0) }
        if !carried.isEmpty { snapshot.reconfigureItems(carried) }
        dataSource.apply(snapshot, animatingDifferences: hasAppeared)
        updateEmptyState(itemCount: rows.count)
    }

    private func updateEmptyState(itemCount: Int) {
        if itemCount > 0 {
            contentUnavailableConfiguration = nil
        } else if !searchQuery.isEmpty {
            contentUnavailableConfiguration = UIContentUnavailableConfiguration.search()
        } else {
            var config = UIContentUnavailableConfiguration.empty()
            config.image = UIImage(systemName: "bookmark")
            config.text = String(localized: "Nothing saved")
            config.secondaryText = String(
                localized:
                    "Swipe a conversation in Chats, or use the ⋯ menu inside one, to keep it here — saved chats stay listed even when their server is offline."
            )
            contentUnavailableConfiguration = config
        }
    }

    private func open(_ row: Row) {
        guard row.availability.isOpenable else {
            confirmRemoveUnavailable(row)
            return
        }
        guard let backend = viewModel.backend(forProfileID: row.chat.profileID) else { return }
        let entry = viewModel.entries.first {
            $0.profileID == row.chat.profileID && $0.session.id == row.chat.sessionID
        }
        let session =
            entry?.session
            ?? AgentSession(
                id: row.chat.sessionID, agentType: row.chat.backend, title: row.chat.title,
                directory: row.chat.directory, createdAt: row.chat.updatedAt,
                updatedAt: row.chat.updatedAt)
        SessionSeenStore.markSeen(session.id)
        let chatViewModel =
            SessionActivity.shared.retainedViewModel(
                for: session.id, contextID: row.chat.profileID)
            ?? ChatViewModel(
                backend: backend, session: session, contextID: row.chat.profileID,
                serverName: row.chat.profileName)
        navigationController?.pushViewController(
            ChatViewController(viewModel: chatViewModel), animated: true)
    }

    /// A saved chat whose conversation is gone can only be tidied away, so say so
    /// plainly rather than opening a screen that would fail to load.
    private func confirmRemoveUnavailable(_ row: Row) {
        let reason =
            row.availability == .serverRemoved
            ? String(localized: "Its server is no longer connected.")
            : String(localized: "It is no longer on \(row.chat.profileName).")
        let alert = UIAlertController(
            title: String(localized: "Can't open this chat"), message: reason,
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Keep"), style: .cancel))
        alert.addAction(
            UIAlertAction(title: String(localized: "Remove from Saved"), style: .destructive) { _ in
                Theme.Haptics.tap()
                SavedChatStore.remove(
                    profileID: row.chat.profileID, sessionID: row.chat.sessionID)
            })
        present(alert, animated: true)
    }
}

extension SavedChatsViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let row = dataSource.itemIdentifier(for: indexPath) else { return }
        open(row)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first,
            let row = dataSource.itemIdentifier(for: indexPath)
        else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
            var actions: [UIMenuElement] = []
            if row.availability.isOpenable {
                actions.append(
                    UIAction(
                        title: String(localized: "Open"),
                        image: UIImage(systemName: "bubble.left")
                    ) { _ in
                        self?.open(row)
                    })
            }
            actions.append(
                UIAction(
                    title: String(localized: "Copy title"),
                    image: UIImage(systemName: "doc.on.doc")
                ) { _ in
                    UIPasteboard.general.string = row.chat.displayTitle
                    Theme.Haptics.success()
                })
            actions.append(
                UIAction(
                    title: String(localized: "Remove from Saved"),
                    image: UIImage(systemName: "bookmark.slash"),
                    attributes: .destructive
                ) { _ in
                    Theme.Haptics.tap()
                    SavedChatStore.remove(
                        profileID: row.chat.profileID, sessionID: row.chat.sessionID)
                })
            return UIMenu(children: actions)
        }
    }
}

extension SavedChatsViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        searchQuery = searchController.searchBar.text?.trimmingCharacters(in: .whitespaces) ?? ""
        applySnapshot()
    }
}
