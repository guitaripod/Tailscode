import CodingAgentKit
import CodingAgentKitApple
import UIKit

@MainActor
final class SessionListViewController: UIViewController {
    var onOpenSettings: (() -> Void)?

    private let viewModel: SessionListViewModel
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<ServerSection, SessionEntry>!
    private let refreshControl = UIRefreshControl()
    private let searchController = UISearchController(searchResultsController: nil)
    private var hasAppeared = false
    private var searchQuery = ""
    private var collapsedSections: Set<String> = {
        Set(UserDefaults.standard.stringArray(forKey: "tailscode.collapsedSections") ?? [])
    }()

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
        title = "Chats"
        view.backgroundColor = Theme.Color.groupedBackground
        configureSearch()
        configureNavItems()
        configureCollectionView()
        configureDataSource()
        bind()
        Task { await viewModel.load() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if hasAppeared { Task { await viewModel.load() } }
        hasAppeared = true
    }

    private func configureSearch() {
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = "Search conversations"
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
    }

    private func configureNavItems() {
        let settingsButton = UIBarButtonItem(
            image: UIImage(systemName: "gearshape"), style: .plain, target: self,
            action: #selector(openSettings))
        let infoButton = UIBarButtonItem(
            image: UIImage(systemName: "sparkles"), style: .plain, target: self,
            action: #selector(showDevelopmentInfo))
        navigationItem.leftBarButtonItems = [settingsButton, infoButton]
        updateAddButton()
    }

    @objc private func showDevelopmentInfo() {
        let alert = UIAlertController(
            title: "Develop iOS Apps on iOS",
            message: "You can now develop iOS apps directly on your iPhone!\n\n" +
                     "This app connects to an opencode server running on your Mac. " +
                     "Start a chat on either device and continue on the other — sessions sync automatically.\n\n" +
                     "Your coding agent runs on your Mac, but you can interact with it from anywhere on your Tailnet.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Got it", style: .default))
        present(alert, animated: true)
    }

    private func updateAddButton() {
        let servers = viewModel.servers
        if servers.count > 1 {
            let actions = servers.map { profile in
                UIAction(
                    title: profile.name,
                    subtitle: "\(profile.backend.displayName) · \(profile.baseURL.host ?? "")",
                    image: Self.serverIcon(for: profile.backend)
                ) { [weak self] _ in self?.presentDirectoryPicker(for: profile) }
            }
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                image: UIImage(systemName: "square.and.pencil"),
                menu: UIMenu(title: "New chat on…", children: actions))
        } else {
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .add, target: self, action: #selector(newSessionDefault))
        }
    }

    private func configureCollectionView() {
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .supplementary
        config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            guard let self, let entry = self.dataSource.itemIdentifier(for: indexPath),
                self.viewModel.supportsMultipleSessions(entry)
            else { return nil }
            let delete = UIContextualAction(style: .destructive, title: "Delete") { _, _, done in
                Task { await self.viewModel.delete(entry); done(true) }
            }
            delete.image = UIImage(systemName: "trash")
            return UISwipeActionsConfiguration(actions: [delete])
        }
        let layout = UICollectionViewCompositionalLayout.list(using: config)
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.refreshControl = refreshControl
        refreshControl.addTarget(self, action: #selector(refresh), for: .valueChanged)
        view.addSubview(collectionView)
    }

    private func configureDataSource() {
        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, SessionEntry> {
            [weak self] cell, _, entry in
            guard let self else { return }
            var content = UIListContentConfiguration.subtitleCell()
            content.text = Self.displayTitle(entry.session.title)
            content.textProperties.font = Theme.Font.body()
            content.textProperties.numberOfLines = 1

            var parts: [String] = []
            if let dir = entry.session.directory {
                parts.append(dir)
            }
            parts.append(entry.backendType.displayName)
            parts.append(Self.relativeDate(entry.session.updatedAt))
            content.secondaryText = parts.joined(separator: " · ")
            content.secondaryTextProperties.font = .preferredFont(forTextStyle: .caption2)
            content.secondaryTextProperties.color = Theme.Color.tertiaryLabel
            content.secondaryTextProperties.numberOfLines = 2

            content.textToSecondaryTextVerticalPadding = 2
            content.prefersSideBySideTextAndSecondaryText = false

            let serverColor = self.viewModel.profileColor(for: entry.profileID)
                ?? Theme.Color.accent
            content.image = Self.serverIcon(for: entry.backendType)
            content.imageProperties.tintColor = serverColor
            content.imageProperties.maximumSize = CGSize(width: 28, height: 28)
            content.imageToTextPadding = Theme.Spacing.m
            cell.contentConfiguration = content

            var accessories: [UICellAccessory] = []
            if let pill = Self.statusPill(for: entry.session.id) {
                accessories.append(pill)
            }
            accessories.append(.disclosureIndicator())
            cell.accessories = accessories
        }

        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            guard let self else { return }
            let section = self.dataSource.snapshot().sectionIdentifiers[indexPath.section]
            var content = UIListContentConfiguration.prominentInsetGroupedHeader()
            let isCollapsed = self.collapsedSections.contains(section.profileID)
            content.text = section.headerTitle
            content.secondaryTextProperties.font = .preferredFont(forTextStyle: .caption2)
            content.secondaryTextProperties.color = Theme.Color.tertiaryLabel
            content.prefersSideBySideTextAndSecondaryText = false
            view.contentConfiguration = content

            var buttonConfig = UIButton.Configuration.plain()
            buttonConfig.image = UIImage(
                systemName: isCollapsed ? "chevron.right" : "chevron.down",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .semibold))
            buttonConfig.baseForegroundColor = Theme.Color.tertiaryLabel
            let button = UIButton(configuration: buttonConfig)
            let id = section.profileID
            button.addAction(UIAction { [weak self] _ in
                self?.toggleSection(id)
            }, for: .touchUpInside)
            view.accessories = [.customView(configuration: .init(
                customView: button, placement: .trailing(displayed: .always)))]
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
            collectionView, indexPath, entry in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: entry)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
    }

    private func bind() {
        viewModel.onChange = { [weak self] in self?.applySnapshot() }
        viewModel.onError = { [weak self] message in self?.present(error: message) }
        SessionActivity.shared.onChange = { [weak self] in self?.reconfigureActivity() }
    }

    private func reconfigureActivity() {
        guard dataSource != nil else { return }
        var snapshot = dataSource.snapshot()
        guard !snapshot.itemIdentifiers.isEmpty else { return }
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func applySnapshot(reloadProfileID: String? = nil) {
        let sectionData = viewModel.sections(filteredBy: searchQuery)
        var snapshot = NSDiffableDataSourceSnapshot<ServerSection, SessionEntry>()
        for (section, entries) in sectionData {
            snapshot.appendSections([section])
            if !collapsedSections.contains(section.profileID) {
                snapshot.appendItems(entries, toSection: section)
            }
        }
        if let reloadID = reloadProfileID,
           let reloadSection = sectionData.first(where: { $0.section.profileID == reloadID })?.section
        {
            snapshot.reloadSections([reloadSection])
        }
        let existing = dataSource.snapshot().itemIdentifiers
        let existingSet = Set(existing)
        let newSet = Set(snapshot.itemIdentifiers)
        let allEntries = sectionData.flatMap(\.entries)
        let retained = allEntries.filter { existingSet.contains($0) && newSet.contains($0) }
        if !retained.isEmpty { snapshot.reconfigureItems(retained) }
        dataSource.apply(snapshot, animatingDifferences: true)
        refreshControl.endRefreshing()
        updatePrompt()
    }

    private func toggleSection(_ profileID: String) {
        if collapsedSections.contains(profileID) {
            collapsedSections.remove(profileID)
        } else {
            collapsedSections.insert(profileID)
        }
        UserDefaults.standard.set(Array(collapsedSections), forKey: "tailscode.collapsedSections")
        applySnapshot(reloadProfileID: profileID)
    }

    private func updatePrompt() {
        if !viewModel.unreachable.isEmpty {
            navigationItem.prompt = "Unreachable: \(viewModel.unreachable.joined(separator: ", "))"
        } else {
            navigationItem.prompt = nil
        }
    }

    private static func displayTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("New session") { return "New conversation" }
        return trimmed.isEmpty ? "Empty conversation" : trimmed
    }

    private static func relativeDate(_ date: Date) -> String {
        let now = Date()
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            let diff = now.timeIntervalSince(date)
            if diff < 60 { return "Just now" }
            if diff < 3600 { return "\(Int(diff / 60))m ago" }
            let formatter = DateFormatter()
            formatter.dateFormat = "h:mm a"
            return formatter.string(from: date)
        }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) {
            let formatter = DateFormatter()
            formatter.dateFormat = "EEEE"
            return formatter.string(from: date)
        }
        let formatter = DateFormatter()
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }

    private static func serverIcon(for backend: AgentType) -> UIImage? {
        let name = backend == .claudeCode ? "sparkles" : "chevron.left.forwardslash.chevron.right"
        return UIImage(systemName: name)
    }

    private static func statusPill(for sessionID: String) -> UICellAccessory? {
        switch SessionActivity.shared.status(for: sessionID) {
        case .idle:
            return nil
        case .running:
            let spinner = UIActivityIndicatorView(style: .medium)
            spinner.color = Theme.Color.accent
            spinner.startAnimating()
            spinner.sizeToFit()
            return .customView(
                configuration: .init(customView: spinner, placement: .trailing(displayed: .always)))
        case .awaitingApproval:
            let label = UILabel()
            label.text = "APPROVAL"
            label.font = .systemFont(ofSize: 10, weight: .bold)
            label.textColor = Theme.Color.warning
            label.sizeToFit()
            let padH: CGFloat = 8
            let padV: CGFloat = 3
            let container = UIView(
                frame: CGRect(x: 0, y: 0, width: label.bounds.width + padH * 2,
                    height: label.bounds.height + padV * 2))
            label.frame = CGRect(x: padH, y: padV, width: label.bounds.width, height: label.bounds.height)
            container.addSubview(label)
            container.backgroundColor = Theme.Color.warning.withAlphaComponent(0.15)
            container.layer.cornerRadius = 5
            container.layer.cornerCurve = .continuous
            return .customView(
                configuration: .init(customView: container, placement: .trailing(displayed: .always)))
        }
    }

    @objc private func refresh() { Task { await viewModel.load() } }
    @objc private func openSettings() { onOpenSettings?() }

    @objc private func newSessionDefault() {
        guard let profile = viewModel.servers.first else { return }
        presentDirectoryPicker(for: profile)
    }

    private func presentDirectoryPicker(for profile: ConnectionProfile) {
        guard let backend = viewModel.backend(forProfileID: profile.id),
              let fileBackend = backend as? (any FileBrowsingBackend)
        else {
            showTextDirectoryPicker(for: profile)
            return
        }
        let browser = FileBrowserViewController(backend: fileBackend, profileID: profile.id)
        browser.onSelect = { [weak self] path in
            let presenting = browser.presentingViewController
            browser.dismiss(animated: true) {
                Task {
                    guard let self else { return }
                    guard let entry = await self.viewModel.newSession(on: profile, directory: path) else { return }
                    self.openChat(for: entry)
                }
            }
        }
        let nav = UINavigationController(rootViewController: browser)
        present(nav, animated: true)
    }

    private func showTextDirectoryPicker(for profile: ConnectionProfile) {
        let alert = UIAlertController(
            title: "New Chat",
            message: "Enter a directory path on the server",
            preferredStyle: .alert)
        alert.addTextField { textField in
            textField.placeholder = "/path/to/project"
            textField.autocorrectionType = .no
            textField.autocapitalizationType = .none
            textField.keyboardType = .URL
        }
        alert.addAction(UIAlertAction(title: "Create", style: .default) { [weak self] _ in
            let directory = alert.textFields?.first?.text
            let trimmed = directory?.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalDirectory = trimmed?.isEmpty == false ? trimmed : nil
            Task {
                guard let entry = await self?.viewModel.newSession(on: profile, directory: finalDirectory) else { return }
                self?.openChat(for: entry)
            }
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    private func openChat(for entry: SessionEntry) {
        guard let backend = viewModel.backend(for: entry) else { return }
        let chatViewModel = ChatViewModel(
            backend: backend, session: entry.session, contextID: entry.profileID,
            serverName: entry.profileName)
        let chat = ChatViewController(viewModel: chatViewModel)
        navigationController?.pushViewController(chat, animated: true)
    }

    private func present(error message: String) {
        refreshControl.endRefreshing()
        let alert = UIAlertController(title: "Something went wrong", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "OK", style: .default))
        present(alert, animated: true)
    }
}

extension SessionListViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let entry = dataSource.itemIdentifier(for: indexPath) else { return }
        openChat(for: entry)
    }
}

extension SessionListViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        searchQuery = searchController.searchBar.text?.trimmingCharacters(in: .whitespaces) ?? ""
        applySnapshot()
    }
}

final class FileBrowserViewController: UIViewController {
    var onSelect: ((String) -> Void)?

    private enum Section: CaseIterable { case favorites, recents, files }

    private let backend: any FileBrowsingBackend
    private let profileID: String
    private let path: String
    private var nodes: [FileNode] = []
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, FileItem>!
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var isFavorite: Bool { FileBrowserFavorites.isFavorite(path, for: profileID) }

    private enum FileItem: Hashable {
        case favorite(String)
        case recent(String)
        case node(FileNode)

        var node: FileNode? {
            if case .node(let n) = self { return n }
            return nil
        }
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
        title = path == "." ? "Files" : (path as NSString).lastPathComponent
        view.backgroundColor = Theme.Color.groupedBackground
        configureNavBar()
        configureCollectionView()
        configureDataSource()
        Task { await load() }
    }

    private func configureNavBar() {
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: "Select", style: .done, target: self, action: #selector(selectTapped))
        let favImage = isFavorite ? "star.fill" : "star"
        let favButton = UIBarButtonItem(
            image: UIImage(systemName: favImage), style: .plain, target: self,
            action: #selector(toggleFavorite))
        if path != "." {
            navigationItem.rightBarButtonItems = [navigationItem.rightBarButtonItem!, favButton]
        }
        if navigationController?.viewControllers.first === self {
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped))
        }
    }

    private func configureCollectionView() {
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.showsSeparators = false
        config.headerMode = .supplementary
        let layout = UICollectionViewCompositionalLayout.list(using: config)
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
        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, FileItem> {
            [weak self] cell, _, item in
            guard let self else { return }
            var content = UIListContentConfiguration.subtitleCell()
            switch item {
            case .favorite(let favPath):
                content.text = (favPath as NSString).lastPathComponent
                content.secondaryText = favPath
                content.image = UIImage(systemName: "star.fill")
                content.imageProperties.tintColor = Theme.Color.warning
                content.secondaryTextProperties.font = .preferredFont(forTextStyle: .caption2)
                content.secondaryTextProperties.color = Theme.Color.tertiaryLabel
            case .recent(let recentPath):
                content.text = (recentPath as NSString).lastPathComponent
                content.secondaryText = recentPath
                content.image = UIImage(systemName: "clock")
                content.imageProperties.tintColor = Theme.Color.secondaryLabel
                content.secondaryTextProperties.font = .preferredFont(forTextStyle: .caption2)
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
                    cell.accessories = []
                }
            }
            content.textProperties.font = Theme.Font.body()
            cell.contentConfiguration = content
        }

        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { view, _, indexPath in
            let section = Section.allCases[indexPath.section]
            var content = UIListContentConfiguration.prominentInsetGroupedHeader()
            switch section {
            case .favorites: content.text = "Favorites"
            case .recents: content.text = "Recent"
            case .files: content.text = "Files"
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
        spinner.startAnimating()
        FileBrowserRecents.record(path, for: profileID)
        defer {
            spinner.stopAnimating()
            collectionView.refreshControl?.endRefreshing()
        }
        do {
            nodes = try await backend.listFiles(path: path)
                .sorted { a, b in
                    if a.isDirectory != b.isDirectory { return a.isDirectory }
                    return a.name.localizedStandardCompare(b.name) == .orderedAscending
                }
            var snapshot = NSDiffableDataSourceSnapshot<Section, FileItem>()
            let isRoot = path == "."
            if isRoot {
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
            if !isRoot {
                let up = FileNode(path: "..", name: "..", isDirectory: true)
                snapshot.appendItems([.node(up)], toSection: .files)
            }
            snapshot.appendItems(nodes.map { .node($0) }, toSection: .files)
            await dataSource.apply(snapshot, animatingDifferences: false)
        } catch {
            let alert = UIAlertController(
                title: "Error", message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
        }
    }

    @objc private func selectTapped() {
        onSelect?(path)
        dismiss(animated: true)
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
                let nextPath = node.path == ".." ? parentPath(of: path) : node.path
                let vc = FileBrowserViewController(backend: backend, profileID: profileID, path: nextPath)
                vc.onSelect = onSelect
                navigationController?.pushViewController(vc, animated: true)
            }
        }
    }

    private func parentPath(of path: String) -> String {
        var parts = path.split(separator: "/")
        if parts.isEmpty || parts.count == 1 { return "." }
        parts.removeLast()
        return "/" + parts.joined(separator: "/")
    }
}
