import CodingAgentKit
import CodingAgentKitApple
import UIKit

/// Every conversation across every server in one flat, recency-sorted list —
/// filter chips stand in for the old collapsible per-server sections, so
/// finding a chat is scroll-or-search instead of expand-and-hunt.
@MainActor
final class SessionListViewController: UIViewController {
    private enum Section { case main }

    private enum ChatFilter: Equatable {
        case all, live, profile(String)
    }

    private let viewModel: SessionListViewModel
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, SessionEntry>!
    private let refreshControl = UIRefreshControl()
    private let searchController = UISearchController(searchResultsController: nil)
    private let chipBar = UIScrollView()
    private let chipStack = UIStackView()
    private let unreachableLabel = UILabel()
    private var filter: ChatFilter
    private var hasAppeared = false
    private var searchQuery = ""

    init(filterProfileID: String? = nil) {
        let sources = ConnectionController.shared.allBackends().map {
            SessionListViewModel.Source(profile: $0.profile, backend: $0.backend)
        }
        self.viewModel = SessionListViewModel(sources: sources)
        self.filter = filterProfileID.map { .profile($0) } ?? .all
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Chats"
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = Theme.Color.groupedBackground
        configureSearch()
        configureChipBar()
        configureCollectionView()
        configureDataSource()
        bind()
        Task { await viewModel.load() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if hasAppeared { Task { await viewModel.load() } }
        hasAppeared = true
        startClockRefresh()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        clockRefreshTask?.cancel()
        clockRefreshTask = nil
    }

    private var clockRefreshTask: Task<Void, Never>?

    /// Relative timestamps ("Just now", "5m ago") are computed at cell
    /// configure time; this keeps them honest while the screen stays visible.
    private func startClockRefresh() {
        clockRefreshTask?.cancel()
        clockRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if Task.isCancelled { return }
                self?.reconfigureActivity()
            }
        }
    }

    private func configureSearch() {
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.placeholder = "Search chats, projects, servers"
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
    }

    private func updateComposeButton() {
        let servers = viewModel.servers
        let compose = UIImage(systemName: "square.and.pencil")
        if servers.count > 1 {
            let actions = servers.map { profile in
                UIAction(
                    title: profile.name,
                    subtitle: profile.backend.displayName,
                    image: Self.serverIcon(for: profile.backend)
                ) { [weak self] _ in self?.startChat(on: profile) }
            }
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                image: compose, menu: UIMenu(title: "New chat on…", children: actions))
        } else {
            navigationItem.rightBarButtonItem = UIBarButtonItem(
                image: compose, primaryAction: UIAction { [weak self] _ in
                    guard let self, let profile = self.viewModel.servers.first else { return }
                    self.startChat(on: profile)
                })
        }
        navigationItem.rightBarButtonItem?.accessibilityLabel = "New chat"
    }

    private func configureChipBar() {
        chipBar.showsHorizontalScrollIndicator = false
        chipBar.translatesAutoresizingMaskIntoConstraints = false
        chipStack.axis = .horizontal
        chipStack.spacing = Theme.Spacing.s
        chipStack.translatesAutoresizingMaskIntoConstraints = false
        chipBar.addSubview(chipStack)
        view.addSubview(chipBar)

        unreachableLabel.font = .preferredFont(forTextStyle: .caption2)
        unreachableLabel.textColor = Theme.Color.danger
        unreachableLabel.numberOfLines = 1
        unreachableLabel.isHidden = true
        unreachableLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(unreachableLabel)

        NSLayoutConstraint.activate([
            chipBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: Theme.Spacing.s),
            chipBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            chipBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            chipBar.heightAnchor.constraint(equalToConstant: 36),
            chipStack.topAnchor.constraint(equalTo: chipBar.contentLayoutGuide.topAnchor),
            chipStack.bottomAnchor.constraint(equalTo: chipBar.contentLayoutGuide.bottomAnchor),
            chipStack.leadingAnchor.constraint(equalTo: chipBar.contentLayoutGuide.leadingAnchor, constant: Theme.Spacing.l),
            chipStack.trailingAnchor.constraint(equalTo: chipBar.contentLayoutGuide.trailingAnchor, constant: -Theme.Spacing.l),
            chipStack.heightAnchor.constraint(equalTo: chipBar.frameLayoutGuide.heightAnchor),

            unreachableLabel.topAnchor.constraint(equalTo: chipBar.bottomAnchor, constant: Theme.Spacing.xs),
            unreachableLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Theme.Spacing.l),
            unreachableLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -Theme.Spacing.l),
        ])
    }

    private func rebuildChips() {
        chipStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        chipStack.addArrangedSubview(chip(title: "All", isSelected: filter == .all) { [weak self] in
            self?.setFilter(.all)
        })
        let liveCount = viewModel.entries.count(where: isLive)
        if liveCount > 0 || filter == .live {
            chipStack.addArrangedSubview(
                chip(title: "Live · \(liveCount)", isSelected: filter == .live, tint: Theme.Color.success) {
                    [weak self] in self?.setFilter(.live)
                })
        }
        for profile in viewModel.servers {
            chipStack.addArrangedSubview(
                chip(
                    title: profile.name,
                    isSelected: filter == .profile(profile.id),
                    icon: Self.serverIcon(for: profile.backend)
                ) { [weak self] in self?.setFilter(.profile(profile.id)) })
        }
    }

    private func chip(
        title: String, isSelected: Bool, tint: UIColor? = nil, icon: UIImage? = nil,
        action: @escaping () -> Void
    ) -> UIButton {
        var config = isSelected
            ? UIButton.Configuration.filled() : Theme.Glass.buttonConfiguration()
        config.cornerStyle = .capsule
        config.buttonSize = .small
        var attributed = AttributedString(title)
        attributed.font = UIFont.preferredFont(forTextStyle: .footnote)
            .withTraits(isSelected ? .traitBold : [])
        config.attributedTitle = attributed
        if isSelected {
            config.baseBackgroundColor = tint ?? Theme.Color.accent
            config.baseForegroundColor = .white
        } else if let tint {
            config.baseForegroundColor = tint
        }
        if let icon, !isSelected {
            config.image = icon
            config.imagePadding = Theme.Spacing.xs
            config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 11)
        }
        let button = UIButton(configuration: config)
        button.accessibilityTraits = isSelected ? [.button, .selected] : .button
        button.addAction(
            UIAction { _ in
                Theme.Haptics.selection()
                action()
            }, for: .touchUpInside)
        return button
    }

    private func setFilter(_ newFilter: ChatFilter) {
        filter = filter == newFilter ? .all : newFilter
        rebuildChips()
        applySnapshot()
    }

    private func configureCollectionView() {
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .none
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
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.refreshControl = refreshControl
        refreshControl.addTarget(self, action: #selector(refresh), for: .valueChanged)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: unreachableLabel.bottomAnchor, constant: Theme.Spacing.xs),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func configureDataSource() {
        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, SessionEntry> {
            [weak self] cell, _, entry in
            guard self != nil else { return }
            var content = UIListContentConfiguration.subtitleCell()
            content.text = Self.displayTitle(entry.session.title)
            content.textProperties.font = Theme.Font.body()
            content.textProperties.numberOfLines = 1

            var parts: [String] = [entry.profileName]
            if let dir = entry.session.directory {
                parts.append((dir as NSString).lastPathComponent)
            }
            parts.append(Self.relativeDate(entry.session.updatedAt))
            content.secondaryText = parts.joined(separator: " · ")
            content.secondaryTextProperties.font = .preferredFont(forTextStyle: .caption2)
            content.secondaryTextProperties.color = Theme.Color.tertiaryLabel
            content.secondaryTextProperties.numberOfLines = 1

            content.textToSecondaryTextVerticalPadding = 2
            content.prefersSideBySideTextAndSecondaryText = false

            let isLive = entry.session.isActive == true
                || SessionActivity.shared.status(for: entry.session.id) != .idle
            content.image = UIImage(systemName: entry.backendType.symbolName)?
                .withTintColor(
                    isLive ? Theme.Color.success : entry.backendType.brandColor,
                    renderingMode: .alwaysOriginal)
            content.imageProperties.maximumSize = CGSize(width: 20, height: 20)
            content.imageProperties.reservedLayoutSize = CGSize(width: 20, height: 20)
            content.imageToTextPadding = Theme.Spacing.m
            cell.contentConfiguration = content

            var accessories: [UICellAccessory] = []
            if let pill = Self.statusPill(for: entry.session.id) {
                accessories.append(pill)
            } else if isLive {
                let dot = UIView(frame: CGRect(x: 0, y: 0, width: 8, height: 8))
                dot.backgroundColor = Theme.Color.success
                dot.layer.cornerRadius = 4
                accessories.append(.customView(
                    configuration: .init(customView: dot, placement: .trailing(displayed: .always))))
            }
            accessories.append(.disclosureIndicator())
            cell.accessories = accessories

            switch SessionActivity.shared.status(for: entry.session.id) {
            case .running:
                cell.accessibilityValue = "Agent running"
            case .awaitingApproval:
                cell.accessibilityValue = "Awaiting approval"
            case .idle:
                cell.accessibilityValue = isLive ? "Live" : nil
            }
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
            collectionView, indexPath, entry in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: entry)
        }
    }

    private func bind() {
        viewModel.onChange = { [weak self] in
            self?.updateComposeButton()
            self?.rebuildChips()
            self?.updateUnreachableNotice()
            self?.applySnapshot()
        }
        viewModel.onError = { [weak self] message in self?.present(error: message) }
        NotificationCenter.default.addObserver(
            self, selector: #selector(activityDidChange),
            name: SessionActivity.didChange, object: nil)
    }

    @objc private func activityDidChange() {
        reconfigureActivity()
        rebuildChips()
    }

    private func reconfigureActivity() {
        guard dataSource != nil else { return }
        var snapshot = dataSource.snapshot()
        guard !snapshot.sectionIdentifiers.isEmpty else { return }
        snapshot.reloadSections(snapshot.sectionIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func updateUnreachableNotice() {
        let names = viewModel.unreachable.compactMap { id in
            viewModel.servers.first(where: { $0.id == id })?.name
        }
        if names.isEmpty {
            unreachableLabel.isHidden = true
            unreachableLabel.text = nil
        } else {
            unreachableLabel.text =
                "\(names.joined(separator: ", ")) unreachable — pull to retry"
            unreachableLabel.isHidden = false
        }
    }

    private func isLive(_ entry: SessionEntry) -> Bool {
        entry.session.isActive == true
            || SessionActivity.shared.status(for: entry.session.id) != .idle
    }

    private func filteredEntries() -> [SessionEntry] {
        var list = viewModel.entries
        switch filter {
        case .all:
            break
        case .live:
            list = list.filter(isLive)
        case .profile(let id):
            list = list.filter { $0.profileID == id }
        }
        guard !searchQuery.isEmpty else { return list }
        return list.filter {
            $0.session.title.localizedCaseInsensitiveContains(searchQuery)
                || ($0.session.directory?.localizedCaseInsensitiveContains(searchQuery) ?? false)
                || $0.profileName.localizedCaseInsensitiveContains(searchQuery)
        }
    }

    private func applySnapshot() {
        let entries = filteredEntries()
        var snapshot = NSDiffableDataSourceSnapshot<Section, SessionEntry>()
        snapshot.appendSections([.main])
        snapshot.appendItems(entries, toSection: .main)
        let existing = Set(dataSource.snapshot().itemIdentifiers)
        let retained = entries.filter { existing.contains($0) }
        if !retained.isEmpty { snapshot.reconfigureItems(retained) }
        dataSource.apply(snapshot, animatingDifferences: hasAppeared)
        refreshControl.endRefreshing()
        updateEmptyState(itemCount: snapshot.numberOfItems)
    }

    private func updateEmptyState(itemCount: Int) {
        if itemCount > 0 {
            contentUnavailableConfiguration = nil
        } else if !searchQuery.isEmpty {
            contentUnavailableConfiguration = UIContentUnavailableConfiguration.search()
        } else if case .live = filter {
            var config = UIContentUnavailableConfiguration.empty()
            config.image = UIImage(systemName: "moon.zzz")
            config.text = "Nothing running"
            config.secondaryText = "Live sessions show up here the moment an agent starts working."
            contentUnavailableConfiguration = config
        } else if viewModel.isEmptyOfServers {
            var config = UIContentUnavailableConfiguration.empty()
            config.image = UIImage(systemName: "server.rack")
            config.text = "No servers connected"
            config.secondaryText = "Add a connection in Settings to start chatting with your agents."
            contentUnavailableConfiguration = config
        } else if viewModel.entries.isEmpty, !viewModel.unreachable.isEmpty {
            var config = UIContentUnavailableConfiguration.empty()
            config.image = UIImage(systemName: "wifi.exclamationmark")
            config.text = "Server unreachable"
            config.secondaryText = "Pull down to retry the connection."
            contentUnavailableConfiguration = config
        } else {
            var config = UIContentUnavailableConfiguration.empty()
            config.image = UIImage(systemName: "bubble.left.and.bubble.right")
            config.text = "No conversations here yet"
            config.secondaryText = "Start one with the compose button."
            contentUnavailableConfiguration = config
        }
    }

    private func promptRename(_ entry: SessionEntry) {
        let alert = UIAlertController(
            title: "Rename conversation", message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = entry.session.title
            field.clearButtonMode = .whileEditing
            field.autocapitalizationType = .sentences
        }
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Rename", style: .default) { [weak self, weak alert] _ in
            let title = alert?.textFields?.first?.text?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty, title != entry.session.title else { return }
            Theme.Haptics.success()
            Task { await self?.viewModel.rename(entry, to: title) }
        })
        present(alert, animated: true)
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

    static func displayTitle(_ title: String) -> String {
        guard AgentSession.isPlaceholderTitle(title) else {
            return title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Empty conversation" : "New conversation"
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
            label.font = UIFontMetrics(forTextStyle: .caption2)
                .scaledFont(for: .systemFont(ofSize: 10, weight: .bold))
            label.adjustsFontForContentSizeCategory = true
            label.textColor = Theme.Color.warning
            label.sizeToFit()
            let padH: CGFloat = 7
            let padV: CGFloat = 3
            let margin: CGFloat = 8
            let pill = UIView(
                frame: CGRect(x: margin, y: 0, width: label.bounds.width + padH * 2,
                    height: label.bounds.height + padV * 2))
            label.frame.origin = CGPoint(x: padH, y: padV)
            pill.addSubview(label)
            pill.backgroundColor = UIColor { traits in
                Theme.Color.warning.withAlphaComponent(0.15)
                    .blended(over: Theme.Color.secondaryBackground, traits: traits)
            }
            pill.layer.cornerRadius = pill.bounds.height / 2
            pill.layer.cornerCurve = .continuous
            let wrapper = UIView(
                frame: CGRect(
                    x: 0, y: 0, width: pill.bounds.width + margin + 6, height: pill.bounds.height))
            wrapper.addSubview(pill)
            return .customView(
                configuration: .init(
                    customView: wrapper, placement: .trailing(displayed: .always),
                    maintainsFixedSize: true))
        }
    }

    @objc private func refresh() { Task { await viewModel.load() } }

    private func startChat(on profile: ConnectionProfile) {
        Theme.Haptics.tap()
        NewChatFlow.begin(from: self, profile: profile, viewModel: viewModel) { [weak self] entry in
            self?.openChat(for: entry)
        }
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
            if self.viewModel.supportsRenaming(entry) {
                actions.append(
                    UIAction(title: "Rename", image: UIImage(systemName: "pencil")) {
                        [weak self] _ in
                        self?.promptRename(entry)
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
        title = path == "." ? "Files" : (path as NSString).lastPathComponent
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
            guard self != nil else { return }
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
        defer { collectionView.refreshControl?.endRefreshing() }
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
                config.text = "Empty folder"
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
                config.text = "Couldn't load files"
                config.secondaryText = SessionListViewModel.readable(error)
                var buttonConfig = UIButton.Configuration.borderedProminent()
                buttonConfig.title = "Retry"
                config.button = buttonConfig
                config.buttonProperties.primaryAction = UIAction { [weak self] _ in
                    Task { await self?.load() }
                }
                contentUnavailableConfiguration = config
            } else {
                contentUnavailableConfiguration = nil
                let alert = UIAlertController(
                    title: "Error", message: error.localizedDescription, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
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
