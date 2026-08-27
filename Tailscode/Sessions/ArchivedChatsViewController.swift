import TailscodeCore
import CodingAgentKit
import UIKit

/// The chats set aside with Archive, joined against the live listing the same way the desktop
/// archive view is: the store keeps only identity, so what a row says here is what the listing
/// says about it right now — never a stale copy.
@MainActor
final class ArchivedChatsViewController: UIViewController {
    private enum Section { case main }

    private let viewModel: SessionListViewModel
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, SessionEntry>!
    private let searchController = UISearchController(searchResultsController: nil)
    private var searchQuery = ""

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
        title = String(localized: "Archived")
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = Theme.Color.groupedBackground
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = String(localized: "Search archived chats")
        navigationItem.searchController = searchController
        configureCollectionView()
        configureDataSource()
        viewModel.onChange = { [weak self] in self?.applySnapshot() }
        NotificationCenter.default.addObserver(
            self, selector: #selector(storeDidChange),
            name: ArchivedChatStore.didChange, object: nil)
        applySnapshot()
        Task { await viewModel.load() }
    }

    @objc private func storeDidChange() { applySnapshot() }

    private func configureCollectionView() {
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .none
        config.footerMode = .supplementary
        config.leadingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            guard let self, let entry = self.dataSource.itemIdentifier(for: indexPath)
            else { return nil }
            let restore = UIContextualAction(
                style: .normal, title: String(localized: "Unarchive")
            ) { [weak self] _, _, done in
                self?.unarchive(entry)
                done(true)
            }
            restore.image = UIImage(systemName: "tray.and.arrow.up")
            restore.backgroundColor = Theme.Color.accent
            return UISwipeActionsConfiguration(actions: [restore])
        }
        config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            guard let self, let entry = self.dataSource.itemIdentifier(for: indexPath),
                self.viewModel.supportsMultipleSessions(entry)
            else { return nil }
            let delete = UIContextualAction(
                style: .destructive, title: String(localized: "Delete")
            ) { [weak self] _, _, done in
                self?.confirmDelete(entry, done: done)
            }
            delete.image = UIImage(systemName: "trash")
            let config = UISwipeActionsConfiguration(actions: [delete])
            config.performsFirstActionWithFullSwipe = false
            return config
        }
        let layout = UICollectionViewCompositionalLayout.readableList(using: config)
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
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
        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, SessionEntry> {
            cell, _, entry in
            var content = UIListContentConfiguration.subtitleCell()
            content.text = SessionListViewController.displayTitle(entry.session.title)
            content.textProperties.font = Theme.Ramp.font(.answer)
            content.textProperties.numberOfLines = 1
            var parts: [String] = [entry.profileName]
            if let dir = entry.session.directory {
                parts.append((dir as NSString).lastPathComponent)
            }
            parts.append(SessionRowModel.age(of: entry.session.updatedAt))
            content.secondaryText = parts.joined(separator: " · ")
            content.secondaryTextProperties.font = Theme.Ramp.font(.panelFootnote)
            content.secondaryTextProperties.color = Theme.Color.tertiaryLabel
            content.secondaryTextProperties.numberOfLines = 1
            content.textToSecondaryTextVerticalPadding = 2
            content.image = UIImage(systemName: entry.backendType.symbolName)?
                .withTintColor(
                    entry.session.isActive == true
                        ? Theme.Color.success : Theme.Color.tertiaryLabel,
                    renderingMode: .alwaysOriginal)
            content.imageProperties.maximumSize = CGSize(width: 20, height: 20)
            content.imageProperties.reservedLayoutSize = CGSize(width: 20, height: 20)
            content.imageToTextPadding = Theme.Spacing.m
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { view, _, _ in
            var content = UIListContentConfiguration.groupedFooter()
            content.text = String(
                localized: """
                Archived chats stay on their server — archiving only hides them from this \
                device's lists. One that goes live again resurfaces by itself.
                """)
            view.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
            collectionView, indexPath, entry in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: entry)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }

    private func rows() -> [SessionEntry] {
        let archived = ArchivedChatStore.all()
        var list = viewModel.entries.filter {
            archived.contains(ArchivedChatStore.key($0.profileID, $0.session.id))
        }
        if !searchQuery.isEmpty {
            list = list.filter {
                $0.session.title.localizedCaseInsensitiveContains(searchQuery)
                    || ($0.session.directory?.localizedCaseInsensitiveContains(searchQuery)
                        ?? false)
                    || $0.profileName.localizedCaseInsensitiveContains(searchQuery)
            }
        }
        return list
    }

    private func applySnapshot() {
        let entries = rows()
        var snapshot = NSDiffableDataSourceSnapshot<Section, SessionEntry>()
        snapshot.appendSections([.main])
        snapshot.appendItems(entries, toSection: .main)
        dataSource.apply(snapshot, animatingDifferences: viewIfLoaded?.window != nil)
        if entries.isEmpty {
            var config = UIContentUnavailableConfiguration.empty()
            config.image = UIImage(systemName: "archivebox")
            config.text = String(localized: "Nothing archived")
            config.secondaryText = String(
                localized: "Archive a chat from its row menu to set it aside without deleting it.")
            contentUnavailableConfiguration = config
        } else {
            contentUnavailableConfiguration = nil
        }
    }

    private func unarchive(_ entry: SessionEntry) {
        Theme.Haptics.tap()
        ArchivedChatStore.toggle(profileID: entry.profileID, sessionID: entry.session.id)
    }

    private func confirmDelete(_ entry: SessionEntry, done: @escaping (Bool) -> Void) {
        let alert = UIAlertController(
            title: String(localized: "Delete conversation?"),
            message: String(
                localized:
                    "\"\(SessionListViewController.displayTitle(entry.session.title))\" will be removed from the server."
            ),
            preferredStyle: .alert)
        alert.addAction(
            UIAlertAction(title: String(localized: "Cancel"), style: .cancel) { _ in done(false) })
        alert.addAction(
            UIAlertAction(title: String(localized: "Delete"), style: .destructive) {
                [weak self] _ in
                Theme.Haptics.warning()
                Task {
                    await self?.viewModel.delete(entry)
                    done(true)
                }
            })
        present(alert, animated: true)
    }

    private func open(_ entry: SessionEntry) {
        guard let backend = viewModel.backend(for: entry) else { return }
        SessionSeenStore.markSeen(entry.session.id)
        let chatViewModel =
            SessionActivity.shared.retainedViewModel(
                for: entry.session.id, contextID: entry.profileID)
            ?? ChatViewModel(
                backend: backend, session: entry.session, contextID: entry.profileID,
                serverName: entry.profileName)
        navigationController?.pushViewController(
            ChatViewController(viewModel: chatViewModel), animated: true)
    }
}

extension ArchivedChatsViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let entry = dataSource.itemIdentifier(for: indexPath) else { return }
        open(entry)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first,
            let entry = dataSource.itemIdentifier(for: indexPath)
        else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) {
            [weak self] _ in
            guard let self else { return UIMenu() }
            var actions: [UIMenuElement] = [
                UIAction(
                    title: String(localized: "Open"),
                    image: UIImage(systemName: "arrow.up.right.square")
                ) { [weak self] _ in
                    self?.open(entry)
                },
                UIAction(
                    title: String(localized: "Unarchive"),
                    subtitle: String(localized: "Back into the chat list"),
                    image: UIImage(systemName: "tray.and.arrow.up")
                ) { [weak self] _ in
                    self?.unarchive(entry)
                },
                UIAction(
                    title: String(localized: "Copy title"),
                    image: UIImage(systemName: "doc.on.doc")
                ) { _ in
                    UIPasteboard.general.string = entry.session.title
                    Theme.Haptics.success()
                },
            ]
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

extension ArchivedChatsViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        searchQuery = searchController.searchBar.text?.trimmingCharacters(in: .whitespaces) ?? ""
        applySnapshot()
    }
}
