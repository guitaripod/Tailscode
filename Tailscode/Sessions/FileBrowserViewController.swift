import TailscodeCore
import CodingAgentKit
import UIKit

final class FileBrowserViewController: UIViewController {
    var onSelect: ((String) -> Void)?

    private enum Section: CaseIterable { case favorites, recents, files }

    private let backend: any FileBrowsingBackend
    private let profileID: String
    private let path: String
    private var hasAppeared = false
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, FileItem>!
    private var isFavorite: Bool { FileBrowserFavorites.isFavorite(path, for: profileID) }

    private enum FileItem: Hashable {
        case favorite(String)
        case recent(String)
        case node(FileNode)
    }

    init(backend: any FileBrowsingBackend, profileID: String, path: String = ".") {
        self.backend = backend
        self.profileID = profileID
        self.path = path
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = path == "." ? String(localized: "Files") : (path as NSString).lastPathComponent
        view.backgroundColor = Theme.Color.groupedBackground
        configureNavBar()
        configureCollectionView()
        configureDataSource()
        Task { await load() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if hasAppeared { Task { await load() } }
        hasAppeared = true
    }

    private func configureNavBar() {
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: String(localized: "Select"), style: .done, target: self,
            action: #selector(selectTapped))
        let favImage = isFavorite ? "star.fill" : "star"
        let favButton = UIBarButtonItem(
            image: UIImage(systemName: favImage), style: .plain, target: self,
            action: #selector(toggleFavorite))
        favButton.tintColor = isFavorite ? Theme.Color.special : nil
        if path != "." {
            navigationItem.rightBarButtonItems = [navigationItem.rightBarButtonItem!, favButton]
        }
        if navigationController?.viewControllers.first === self {
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped))
        }
    }

    private func configureCollectionView() {
        var config = UICollectionLayoutListConfiguration.themed(.insetGrouped)
        config.showsSeparators = false
        config.headerMode = .supplementary
        config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            guard let self, let item = self.dataSource.itemIdentifier(for: indexPath) else {
                return nil
            }
            let stalePath: String
            switch item {
            case .favorite(let path): stalePath = path
            case .recent(let path): stalePath = path
            case .node: return nil
            }
            let remove = UIContextualAction(
                style: .destructive, title: String(localized: "Remove")
            ) {
                [weak self] _, _, done in
                guard let self else { return done(false) }
                if case .favorite = item {
                    FileBrowserFavorites.remove(stalePath, for: self.profileID)
                } else {
                    FileBrowserRecents.remove(stalePath, for: self.profileID)
                }
                Task {
                    await self.load()
                    done(true)
                }
            }
            return UISwipeActionsConfiguration(actions: [remove])
        }
        let layout = UICollectionViewCompositionalLayout.readableList(using: config)
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.refreshControl = UIRefreshControl()
        collectionView.refreshControl?.addTarget(self, action: #selector(refreshTapped), for: .valueChanged)
        view.addSubview(collectionView)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func configureDataSource() {
        let cell = UICollectionView.CellRegistration<SurfaceListCell, FileItem> {
            [weak self] cell, _, item in
            guard self != nil else { return }
            var content = UIListContentConfiguration.subtitleCell()
            switch item {
            case .favorite(let favPath):
                content.text = (favPath as NSString).lastPathComponent
                content.secondaryText = favPath
                content.image = UIImage(systemName: "star.fill")
                content.imageProperties.tintColor = Theme.Color.special
                content.secondaryTextProperties.font = Theme.Ramp.font(.panelFootnote)
                content.secondaryTextProperties.color = Theme.Color.tertiaryLabel
            case .recent(let recentPath):
                content.text = (recentPath as NSString).lastPathComponent
                content.secondaryText = recentPath
                content.image = UIImage(systemName: "clock")
                content.imageProperties.tintColor = Theme.Color.secondaryLabel
                content.secondaryTextProperties.font = Theme.Ramp.font(.panelFootnote)
                content.secondaryTextProperties.color = Theme.Color.tertiaryLabel
            case .node(let node):
                content.text = node.name
                if node.isDirectory {
                    content.image = UIImage(systemName: "folder.fill")
                    content.imageProperties.tintColor = Theme.Color.accent
                    cell.accessories = [.disclosureIndicator()]
                } else {
                    content.image = UIImage(systemName: "doc")
                    content.imageProperties.tintColor = Theme.Color.tertiaryLabel
                    content.textProperties.color = Theme.Color.tertiaryLabel
                    cell.accessories = []
                }
            }
            content.textProperties.font = Theme.Ramp.font(.answer)
            cell.contentConfiguration = content
        }

        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            guard let self else { return }
            let sections = self.dataSource.snapshot().sectionIdentifiers
            guard sections.indices.contains(indexPath.section) else { return }
            let section = sections[indexPath.section]
            var content = UIListContentConfiguration.prominentInsetGroupedHeader()
            switch section {
            case .favorites: content.text = String(localized: "Favorites")
            case .recents: content.text = String(localized: "Recent")
            case .files: content.text = String(localized: "Files")
            }
            view.contentConfiguration = content
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
            collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: item)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
    }

    private func load() async {
        if dataSource.snapshot().numberOfItems == 0 { collectionView.showsWork(true) }
        defer {
            collectionView.refreshControl?.endRefreshing()
            collectionView.showsWork(false)
        }
        do {
            let nodes = try await backend.listFiles(path: path)
                .sorted { a, b in
                    if a.isDirectory != b.isDirectory { return a.isDirectory }
                    return a.name.localizedStandardCompare(b.name) == .orderedAscending
                }
            if path != "." { FileBrowserRecents.record(path, for: profileID) }
            var snapshot = NSDiffableDataSourceSnapshot<Section, FileItem>()
            if path == "." {
                let favs = FileBrowserFavorites.all(for: profileID)
                if !favs.isEmpty {
                    snapshot.appendSections([.favorites])
                    snapshot.appendItems(favs.map { .favorite($0) }, toSection: .favorites)
                }
                let recents = FileBrowserRecents.all(for: profileID)
                if !recents.isEmpty {
                    snapshot.appendSections([.recents])
                    snapshot.appendItems(recents.map { .recent($0) }, toSection: .recents)
                }
            }
            snapshot.appendSections([.files])
            snapshot.appendItems(nodes.map { .node($0) }, toSection: .files)
            let empty = snapshot.numberOfItems == 0
            await dataSource.apply(snapshot, animatingDifferences: false)
            if empty {
                var config = UIContentUnavailableConfiguration.empty()
                config.image = UIImage(systemName: "folder")
                config.text = String(localized: "Empty folder")
                contentUnavailableConfiguration = config
            } else {
                contentUnavailableConfiguration = nil
            }
        } catch {
            AppLogger.ui.error(
                "file browser load failed for \(path): \(SessionListViewModel.readable(error))")
            if dataSource.snapshot().numberOfItems == 0 {
                var config = UIContentUnavailableConfiguration.empty()
                config.image = UIImage(systemName: "exclamationmark.triangle")
                config.text = String(localized: "Couldn't load files")
                config.secondaryText = SessionListViewModel.readable(error)
                var buttonConfig = UIButton.Configuration.borderedProminent()
                buttonConfig.title = String(localized: "Retry")
                config.button = buttonConfig
                config.buttonProperties.primaryAction = UIAction { [weak self] _ in
                    Task { await self?.load() }
                }
                contentUnavailableConfiguration = config
            } else {
                contentUnavailableConfiguration = nil
                let alert = UIAlertController(
                    title: String(localized: "Error"), message: error.localizedDescription,
                    preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
                present(alert, animated: true)
            }
        }
    }

    @objc private func selectTapped() {
        onSelect?(path)
    }

    @objc private func toggleFavorite() {
        FileBrowserFavorites.toggle(path, for: profileID)
        configureNavBar()
    }

    @objc private func cancelTapped() {
        dismiss(animated: true)
    }

    @objc private func refreshTapped() {
        Task { await load() }
    }
}

extension FileBrowserViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        switch item {
        case .favorite(let favPath), .recent(let favPath):
            let vc = FileBrowserViewController(backend: backend, profileID: profileID, path: favPath)
            vc.onSelect = onSelect
            navigationController?.pushViewController(vc, animated: true)
        case .node(let node):
            if node.isDirectory {
                let vc = FileBrowserViewController(
                    backend: backend, profileID: profileID, path: node.path)
                vc.onSelect = onSelect
                navigationController?.pushViewController(vc, animated: true)
            }
        }
    }
}
