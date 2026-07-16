import CodingAgentKit
import CodingAgentKitApple
import UIKit

/// The app's front door: what's running right now, one-tap new chats per
/// server, the freshest conversations, and the subscription gauges — each
/// section a Liquid Glass card, each answering "what would I reach for
/// from my pocket?"
@MainActor
final class HomeViewController: UIViewController {
    var onOpenSettings: (() -> Void)?

    private let viewModel: SessionListViewModel
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<HomeSection, HomeItem>!
    private let refreshControl = UIRefreshControl()
    private var quotas: [UsageQuota] = []
    private var hasAppeared = false
    private var pendingDeepLink: (sessionID: String, parkedAt: Date)?

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
        title = "Tailscode"
        navigationItem.largeTitleDisplayMode = .always
        view.backgroundColor = Theme.Color.groupedBackground
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "gearshape"), style: .plain, target: self,
            action: #selector(openSettings))
        updateComposeButton()
        configureCollectionView()
        configureDataSource()
        bind()
        Task { await load() }
        #if DEBUG
            if ProcessInfo.processInfo.environment["TAILSCODE_OPEN_CHATS"] != nil {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    self?.pushChats()
                }
            }
        #endif
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if hasAppeared { Task { await load() } }
        hasAppeared = true
    }

    private func bind() {
        viewModel.onChange = { [weak self] in
            self?.updateComposeButton()
            self?.applySnapshot()
        }
        viewModel.onError = { [weak self] message in
            self?.refreshControl.endRefreshing()
            AppLogger.session.error("home load: \(message)")
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(activityDidChange),
            name: SessionActivity.didChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(sceneDidActivate),
            name: UIApplication.didBecomeActiveNotification, object: nil)
    }

    @objc private func activityDidChange() { applySnapshot() }
    @objc private func sceneDidActivate() { Task { await load() } }
    @objc private func openSettings() { onOpenSettings?() }
    @objc private func refresh() { Task { await load() } }

    /// One server: compose starts a chat there. Several: compose offers the
    /// pick, the same menu the Chats screen uses.
    private func updateComposeButton() {
        let servers = viewModel.servers
        let compose = UIImage(systemName: "square.and.pencil")
        if servers.count > 1 {
            let actions = servers.map { profile in
                UIAction(
                    title: profile.name,
                    subtitle: profile.backend.displayName,
                    image: UIImage(systemName: profile.backend.symbolName)?
                        .withTintColor(profile.backend.brandColor, renderingMode: .alwaysOriginal)
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

    private func load() async {
        await viewModel.load()
        await loadQuotas()
        refreshControl.endRefreshing()
        applySnapshot()
    }

    /// A bridge answers for every provider its host machine is signed into,
    /// but not every bridge host has live quota data — take the first Claude
    /// profile whose bridge does.
    private func loadQuotas() async {
        for profile in viewModel.servers where profile.backend == .claudeCode {
            guard let backend = viewModel.backend(forProfileID: profile.id) else { continue }
            var fetched: [UsageQuota] = []
            if let primary = try? await backend.usageQuota() { fetched.append(primary) }
            if let extra = try? await backend.additionalUsageQuotas() {
                fetched.append(contentsOf: extra)
            }
            if !fetched.isEmpty {
                quotas = fetched
                return
            }
        }
        quotas = []
    }

    private func isLive(_ entry: SessionEntry) -> Bool {
        entry.session.isActive == true
            || SessionActivity.shared.status(for: entry.session.id) != .idle
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<HomeSection, HomeItem>()
        let live = viewModel.entries.filter(isLive).prefix(10)
        if !live.isEmpty {
            snapshot.appendSections([.live])
            snapshot.appendItems(live.map { .live(LiveCard(entry: $0)) }, toSection: .live)
        }
        if !viewModel.servers.isEmpty {
            snapshot.appendSections([.servers])
            snapshot.appendItems(
                viewModel.servers.map { profile in
                    let entries = viewModel.entries.filter { $0.profileID == profile.id }
                    return .server(
                        ServerCard(
                            profileID: profile.id,
                            name: profile.name,
                            backend: profile.backend,
                            host: profile.baseURL.host ?? "",
                            reachable: !viewModel.unreachable.contains(profile.id),
                            sessionCount: entries.count,
                            liveCount: entries.count(where: isLive)))
                }, toSection: .servers)
        }
        let liveIDs = Set(live.map(\.session.id))
        let recent = viewModel.entries.filter { !liveIDs.contains($0.session.id) }.prefix(6)
        if !recent.isEmpty {
            snapshot.appendSections([.recent])
            snapshot.appendItems(recent.map { .recent(RecentCard(entry: $0)) }, toSection: .recent)
        }
        if !quotas.isEmpty {
            snapshot.appendSections([.usage])
            snapshot.appendItems(
                quotas.map { .usage(QuotaCard(quota: $0)) }, toSection: .usage)
        }
        let existing = Set(dataSource.snapshot().itemIdentifiers)
        let carried = snapshot.itemIdentifiers.filter { existing.contains($0) }
        if !carried.isEmpty { snapshot.reconfigureItems(carried) }
        dataSource.apply(snapshot, animatingDifferences: hasAppeared)
        updateEmptyState(itemCount: snapshot.numberOfItems)
        consumePendingDeepLink()
    }

    private func updateEmptyState(itemCount: Int) {
        if itemCount > 0 {
            contentUnavailableConfiguration = nil
        } else if viewModel.isEmptyOfServers {
            var config = UIContentUnavailableConfiguration.empty()
            config.image = UIImage(systemName: "server.rack")
            config.text = "No servers connected"
            config.secondaryText = "Add a connection in Settings to start chatting with your agents."
            contentUnavailableConfiguration = config
        } else {
            contentUnavailableConfiguration = nil
        }
    }

    func openSession(withID id: String) {
        if let top = navigationController?.topViewController as? ChatViewController,
            top.sessionID == id
        {
            return
        }
        guard let entry = viewModel.entries.first(where: { $0.session.id == id }) else {
            pendingDeepLink = (id, Date())
            Task { await load() }
            return
        }
        pendingDeepLink = nil
        presentedViewController?.dismiss(animated: false)
        navigationController?.popToRootViewController(animated: false)
        openChat(for: entry)
    }

    private func consumePendingDeepLink() {
        guard let pending = pendingDeepLink else { return }
        pendingDeepLink = nil
        guard Date().timeIntervalSince(pending.parkedAt) < 30 else { return }
        if let entry = viewModel.entries.first(where: { $0.session.id == pending.sessionID }) {
            openChat(for: entry)
        }
    }

    private func openChat(for entry: SessionEntry) {
        guard let backend = viewModel.backend(for: entry) else { return }
        let chatViewModel = ChatViewModel(
            backend: backend, session: entry.session, contextID: entry.profileID,
            serverName: entry.profileName)
        navigationController?.pushViewController(
            ChatViewController(viewModel: chatViewModel), animated: true)
    }

    private func startChat(on profile: ConnectionProfile) {
        Theme.Haptics.tap()
        NewChatFlow.begin(from: self, profile: profile, viewModel: viewModel) { [weak self] entry in
            self?.openChat(for: entry)
        }
    }

    private func pushChats(filterProfileID: String? = nil) {
        navigationController?.pushViewController(
            SessionListViewController(filterProfileID: filterProfileID), animated: true)
    }

    private func pushUsage() {
        navigationController?.pushViewController(UsageViewController(), animated: true)
    }

    private func configureCollectionView() {
        let layout = UICollectionViewCompositionalLayout { [weak self] index, environment in
            guard let self,
                let section = self.dataSource?.snapshot().sectionIdentifiers[safe: index]
            else { return Self.listSection() }
            switch section {
            case .live: return Self.liveSection()
            case .servers, .recent, .usage: return Self.listSection()
            }
        }
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.refreshControl = refreshControl
        refreshControl.addTarget(self, action: #selector(refresh), for: .valueChanged)
        view.addSubview(collectionView)
    }

    private static func liveSection() -> NSCollectionLayoutSection {
        let item = NSCollectionLayoutItem(
            layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .fractionalHeight(1)))
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: .init(widthDimension: .absolute(248), heightDimension: .absolute(104)),
            subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.orthogonalScrollingBehavior = .continuous
        section.interGroupSpacing = Theme.Spacing.m
        section.contentInsets = .init(
            top: Theme.Spacing.s, leading: Theme.Spacing.l,
            bottom: Theme.Spacing.l, trailing: Theme.Spacing.l)
        section.boundarySupplementaryItems = [header()]
        return section
    }

    private static func listSection() -> NSCollectionLayoutSection {
        let item = NSCollectionLayoutItem(
            layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(72)))
        let group = NSCollectionLayoutGroup.vertical(
            layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(72)),
            subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = Theme.Spacing.s
        section.contentInsets = .init(
            top: Theme.Spacing.s, leading: Theme.Spacing.l,
            bottom: Theme.Spacing.l, trailing: Theme.Spacing.l)
        section.boundarySupplementaryItems = [header()]
        return section
    }

    private static func header() -> NSCollectionLayoutBoundarySupplementaryItem {
        NSCollectionLayoutBoundarySupplementaryItem(
            layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(30)),
            elementKind: UICollectionView.elementKindSectionHeader, alignment: .top)
    }

    private func configureDataSource() {
        let liveCell = UICollectionView.CellRegistration<LiveSessionCell, LiveCard> {
            cell, _, card in cell.configure(card)
        }
        let serverCell = UICollectionView.CellRegistration<ServerCardCell, ServerCard> {
            [weak self] cell, _, card in
            cell.configure(card)
            cell.onNewChat = { [weak self] in
                guard let self,
                    let profile = self.viewModel.servers.first(where: { $0.id == card.profileID })
                else { return }
                self.startChat(on: profile)
            }
        }
        let recentCell = UICollectionView.CellRegistration<RecentSessionCell, RecentCard> {
            cell, _, card in cell.configure(card)
        }
        let quotaCell = UICollectionView.CellRegistration<QuotaCardCell, QuotaCard> {
            cell, _, card in cell.configure(card)
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
            collectionView, indexPath, item in
            switch item {
            case .live(let card):
                return collectionView.dequeueConfiguredReusableCell(
                    using: liveCell, for: indexPath, item: card)
            case .server(let card):
                return collectionView.dequeueConfiguredReusableCell(
                    using: serverCell, for: indexPath, item: card)
            case .recent(let card):
                return collectionView.dequeueConfiguredReusableCell(
                    using: recentCell, for: indexPath, item: card)
            case .usage(let card):
                return collectionView.dequeueConfiguredReusableCell(
                    using: quotaCell, for: indexPath, item: card)
            }
        }

        let header = UICollectionView.SupplementaryRegistration<HomeHeaderView>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            guard let self,
                let section = self.dataSource.snapshot().sectionIdentifiers[safe: indexPath.section]
            else { return }
            switch section {
            case .live:
                view.configure(title: "Live now")
            case .servers:
                view.configure(title: "Servers")
            case .recent:
                view.configure(title: "Recent", actionTitle: "See all") { [weak self] in
                    self?.pushChats()
                }
            case .usage:
                view.configure(title: "Usage", actionTitle: "Details") { [weak self] in
                    self?.pushUsage()
                }
            }
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
    }
}

extension HomeViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        switch item {
        case .live(let card):
            openChat(for: card.entry)
        case .recent(let card):
            openChat(for: card.entry)
        case .server(let card):
            pushChats(filterProfileID: card.profileID)
        case .usage:
            pushUsage()
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
        case .server(let card):
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                UIMenu(children: [
                    UIAction(
                        title: "View chats", image: UIImage(systemName: "bubble.left.and.bubble.right")
                    ) { _ in self?.pushChats(filterProfileID: card.profileID) },
                    UIAction(title: "New chat", image: UIImage(systemName: "plus.bubble")) { _ in
                        guard let self,
                            let profile = self.viewModel.servers.first(where: { $0.id == card.profileID })
                        else { return }
                        self.startChat(on: profile)
                    },
                ])
            }
        case .recent(let card):
            return sessionMenu(for: card.entry, allowDelete: true)
        case .live(let card):
            return sessionMenu(for: card.entry, allowDelete: false)
        case .usage:
            return nil
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
                UIAction(title: "Open", image: UIImage(systemName: "bubble.left")) {
                    [weak self] _ in self?.openChat(for: entry)
                }
            ]
            if let directory = entry.session.directory,
                let profile = self.viewModel.servers.first(where: { $0.id == entry.profileID })
            {
                actions.append(
                    UIAction(
                        title: "New chat in same project", image: UIImage(systemName: "plus.bubble")
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
                        [weak self] _ in self?.promptRename(entry)
                    })
            }
            if allowDelete, self.viewModel.supportsMultipleSessions(entry) {
                actions.append(
                    UIAction(
                        title: "Delete", image: UIImage(systemName: "trash"),
                        attributes: .destructive
                    ) { [weak self] _ in self?.confirmDelete(entry) })
            }
            return UIMenu(children: actions)
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

    private func confirmDelete(_ entry: SessionEntry) {
        let alert = UIAlertController(
            title: "Delete conversation?",
            message: "\"\(SessionListViewController.displayTitle(entry.session.title))\" will be removed from the server.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Delete", style: .destructive) { [weak self] _ in
            Theme.Haptics.warning()
            Task { await self?.viewModel.delete(entry) }
        })
        present(alert, animated: true)
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
