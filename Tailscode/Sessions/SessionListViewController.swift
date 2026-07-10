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
            image: UIImage(systemName: "info.circle"), style: .plain, target: self,
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
            let delete = UIContextualAction(style: .destructive, title: "Delete") {
                [weak self] _, _, done in
                self?.confirmDelete(entry, done: done)
            }
            delete.image = UIImage(systemName: "trash")
            let config = UISwipeActionsConfiguration(actions: [delete])
            config.performsFirstActionWithFullSwipe = false
            return config
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
            let sections = self.dataSource.snapshot().sectionIdentifiers
            guard sections.indices.contains(indexPath.section) else { return }
            let section = sections[indexPath.section]
            var content = UIListContentConfiguration.prominentInsetGroupedHeader()
            let isCollapsed = self.collapsedSections.contains(section.profileID)
            content.text = section.headerTitle
            if self.viewModel.unreachable.contains(section.profileName) {
                content.secondaryText = "Unreachable — pull to retry"
                content.secondaryTextProperties.color = Theme.Color.danger
            } else {
                content.secondaryTextProperties.color = Theme.Color.tertiaryLabel
            }
            content.secondaryTextProperties.font = .preferredFont(forTextStyle: .caption2)
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
            if !searchQuery.isEmpty || !collapsedSections.contains(section.profileID) {
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
        updateEmptyState(itemCount: snapshot.numberOfItems)
        consumePendingDeepLink()
    }

    private func updateEmptyState(itemCount: Int) {
        if itemCount > 0 {
            contentUnavailableConfiguration = nil
        } else if !searchQuery.isEmpty {
            contentUnavailableConfiguration = UIContentUnavailableConfiguration.search()
        } else if viewModel.isEmptyOfServers {
            var config = UIContentUnavailableConfiguration.empty()
            config.image = UIImage(systemName: "server.rack")
            config.text = "No servers connected"
            config.secondaryText = "Add a connection in Settings to start chatting with your agents."
            contentUnavailableConfiguration = config
        } else if viewModel.entries.isEmpty {
            var config = UIContentUnavailableConfiguration.empty()
            config.image = UIImage(systemName: "bubble.left.and.bubble.right")
            config.text = "No conversations yet"
            config.secondaryText = "Tap + to start a chat on your server."
            contentUnavailableConfiguration = config
        } else {
            contentUnavailableConfiguration = nil
        }
    }

    private var pendingDeepLinkSessionID: String?

    /// Opens the chat for a session id (Live Activity tap). If sessions
    /// haven't loaded yet, the link is parked and consumed after the next
    /// snapshot.
    func openSession(withID id: String) {
        if let top = navigationController?.topViewController as? ChatViewController,
            top.sessionID == id
        {
            return
        }
        guard let entry = viewModel.entries.first(where: { $0.session.id == id }) else {
            pendingDeepLinkSessionID = id
            return
        }
        pendingDeepLinkSessionID = nil
        presentedViewController?.dismiss(animated: false)
        navigationController?.popToRootViewController(animated: false)
        openChat(for: entry)
    }

    private func consumePendingDeepLink() {
        guard let id = pendingDeepLinkSessionID else { return }
        openSession(withID: id)
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

    private func confirmDelete(_ entry: SessionEntry, done: @escaping (Bool) -> Void) {
        let alert = UIAlertController(
            title: "Delete conversation?",
            message: "\"\(Self.displayTitle(entry.session.title))\" will be removed from the server.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in done(false) })
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            Theme.Haptics.warning()
            Task {
                await self?.viewModel.delete(entry)
                done(true)
            }
        })
        present(alert, animated: true)
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
            return date.formatted(.dateTime.hour().minute())
        }
        if calendar.isDateInYesterday(date) { return "Yesterday" }
        if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    private static func serverIcon(for backend: AgentType) -> UIImage? {
        UIImage(systemName: backend.symbolName)?
            .withTintColor(backend.brandColor, renderingMode: .alwaysOriginal)
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
            guard let self else { return }
            self.presentedViewController?.dismiss(animated: true) {
                Task {
                    guard let entry = await self.viewModel.newSession(on: profile, directory: path)
                    else { return }
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
            var actions: [UIMenuElement] = []
            if let directory = entry.session.directory,
                let profile = self.viewModel.servers.first(where: { $0.id == entry.profileID })
            {
                actions.append(
                    UIAction(
                        title: "New chat in same project",
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
            actions.append(
                UIAction(title: "Copy title", image: UIImage(systemName: "doc.on.doc")) { _ in
                    UIPasteboard.general.string = entry.session.title
                    Theme.Haptics.success()
                })
            if self.viewModel.supportsMultipleSessions(entry) {
                actions.append(
                    UIAction(
                        title: "Delete", image: UIImage(systemName: "trash"),
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

final class FileBrowserViewController: UIViewController {
    var onSelect: ((String) -> Void)?

    private enum Section: CaseIterable { case favorites, recents, files }

    private let backend: any FileBrowsingBackend
    private let profileID: String
    private let path: String
    private var nodes: [FileNode] = []
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, FileItem>!
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
        favButton.tintColor = isFavorite ? .systemYellow : nil
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
            let remove = UIContextualAction(style: .destructive, title: "Remove") {
                [weak self] _, _, done in
                guard let self else { return done(false) }
                if case .favorite = item {
                    FileBrowserFavorites.toggle(stalePath, for: self.profileID)
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
                content.imageProperties.tintColor = .systemYellow
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
                    content.textProperties.color = Theme.Color.tertiaryLabel
                    cell.accessories = []
                }
            }
            content.textProperties.font = Theme.Font.body()
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
        if dataSource.snapshot().numberOfItems == 0 {
            contentUnavailableConfiguration = UIContentUnavailableConfiguration.loading()
        }
        if path != "." { FileBrowserRecents.record(path, for: profileID) }
        defer { collectionView.refreshControl?.endRefreshing() }
        do {
            nodes = try await backend.listFiles(path: path)
                .sorted { a, b in
                    if a.isDirectory != b.isDirectory { return a.isDirectory }
                    return a.name.localizedStandardCompare(b.name) == .orderedAscending
                }
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
                config.text = "Empty folder"
                contentUnavailableConfiguration = config
            } else {
                contentUnavailableConfiguration = nil
            }
        } catch {
            contentUnavailableConfiguration = nil
            let alert = UIAlertController(
                title: "Error", message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "OK", style: .default))
            present(alert, animated: true)
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
