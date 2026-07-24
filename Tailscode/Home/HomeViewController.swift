import CodingAgentKit
import CodingAgentKitApple
import UIKit

/// The app's front door, organized around three jobs: triage (what needs you
/// right now — blocked or live agents, unreachable servers), continue (recent
/// conversations, badged when they changed since you last looked), and start
/// (the docked composer plus one-tap project launch pads).
@MainActor
final class HomeViewController: UIViewController {
    var onOpenSettings: (() -> Void)?

    private let viewModel: SessionListViewModel
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<HomeSection, HomeItem>!
    private let refreshControl = UIRefreshControl()
    private let composerBar = HomeComposerBar()
    private var quotas: [UsageQuota] = []
    private var hasAppeared = false
    private var hasLoadedOnce = false
    private var wantsComposerFocus = false
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
        configureComposer()
        bind()
        applySnapshot()
        updateComposer()
        Task { await load() }
        #if DEBUG
            if ProcessInfo.processInfo.environment["TAILSCODE_OPEN_CHATS"] != nil {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    self?.pushChats()
                }
            }
            if ProcessInfo.processInfo.environment["TAILSCODE_OPEN_SETTINGS"] != nil {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    self?.onOpenSettings?()
                }
            }
            if let text = ProcessInfo.processInfo.environment["TAILSCODE_COMPOSE_SEND"] {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(3))
                    self?.composerSend(text)
                }
            }
            if ProcessInfo.processInfo.environment["TAILSCODE_FOCUS_COMPOSER"] != nil {
                Task { [weak self] in
                    try? await Task.sleep(for: .seconds(2))
                    self?.focusComposer()
                }
            }
        #endif
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if hasAppeared { Task { await load() } }
        hasAppeared = true
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if wantsComposerFocus {
            wantsComposerFocus = false
            composerBar.focus()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let overlap = max(
            0, view.bounds.height - composerBar.frame.minY - view.safeAreaInsets.bottom)
        let inset = composerBar.isHidden ? 0 : overlap + Theme.Spacing.s
        if collectionView.contentInset.bottom != inset {
            collectionView.contentInset.bottom = inset
            collectionView.verticalScrollIndicatorInsets.bottom = inset
        }
    }

    func focusComposer() {
        guard viewIfLoaded?.window != nil else {
            wantsComposerFocus = true
            return
        }
        composerBar.focus()
    }

    private func bind() {
        viewModel.onChange = { [weak self] in
            self?.updateComposeButton()
            self?.updateComposer()
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

    @objc private func openSettings() {
        view.endEditing(true)
        onOpenSettings?()
    }
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

    private var lastOpencodeScan: Date?
    private var loadTask: Task<Void, Never>?
    private var enrichmentTask: Task<Void, Never>?

    /// The session fan-out alone decides when the pull-to-refresh spinner stops:
    /// quota and scan work is best-effort enrichment, and an unreachable server
    /// makes each of those calls sit on the 30s request timeout. Blocking the
    /// spinner behind them made a single dead tailnet peer look like a broken
    /// refresh for two minutes.
    /// `viewWillAppear`, scene activation, pull-to-refresh and post-action
    /// reloads can all fire within the same second; against an unreachable
    /// server every one of them parks on the request timeout, so they share a
    /// single in-flight load rather than queueing up behind each other.
    private func load() async {
        if let inFlight = loadTask {
            await inFlight.value
            refreshControl.endRefreshing()
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performLoad()
        }
        loadTask = task
        await task.value
        if loadTask == task { loadTask = nil }
    }

    private func performLoad() async {
        await viewModel.load()
        refreshControl.endRefreshing()
        hasLoadedOnce = true
        updateComposer()
        applySnapshot()
        startEnrichment()
    }

    /// Deliberately not awaited by `performLoad`: quota and scan work is
    /// enrichment layered onto an already-painted list, so it must never hold
    /// the refresh spinner — nor a caller that coalesced onto this load, which
    /// is how pull-to-refresh ended up waiting on an unreachable server twice
    /// over.
    private func startEnrichment() {
        enrichmentTask?.cancel()
        enrichmentTask = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.loadEnrichment()
        }
    }

    private func loadEnrichment() async {
        async let quotas: Void = loadQuotas()
        async let scan: Void = scanOpencodeIfNeeded()
        _ = await (quotas, scan)
        guard !Task.isCancelled else { return }
        applySnapshot()
    }

    private func scanOpencodeIfNeeded() async {
        if let last = lastOpencodeScan, Date().timeIntervalSince(last) < 300 { return }
        let entries = ConnectionController.shared.opencodeBackends()
        guard !entries.isEmpty else { return }
        lastOpencodeScan = Date()
        await UsageScanner.scanOpencode(backends: entries.map { ($0.profile.name, $0.backend) })
    }

    /// A bridge answers for every provider its host machine is signed into,
    /// but not every bridge host has live quota data — take the first Claude
    /// profile whose bridge does.
    /// Delegates to the same deadline-bounded fetcher the widget and the
    /// background refresh use — it already queries every bridge concurrently,
    /// keeps the partial haul when the deadline fires, and resolves the
    /// first-bridge-wins-per-provider ordering. Home previously carried a
    /// third, unbounded copy of that logic. An empty result means nothing
    /// answered in time, which must not blank a good card.
    private func loadQuotas() async {
        let fetched = await LiveQuotaFetcher.fetch(deadline: 10)
        guard !fetched.isEmpty else { return }
        quotas = fetched
        UsageWidgetStore.writeLive(fetched)
    }

    private func isLive(_ entry: SessionEntry) -> Bool {
        entry.session.isActive == true
            || SessionActivity.shared.status(for: entry.session.id) != .idle
    }

    /// A cached `isActive` from the cold-launch snapshot can describe an agent
    /// that died while the app was closed, so unconfirmed liveness renders as
    /// syncing rather than a confident LIVE.
    private func presence(for entry: SessionEntry) -> LiveCard.Presence {
        switch SessionActivity.shared.status(for: entry.session.id) {
        case .awaitingApproval: return .needsInput
        case .running: return .working
        case .idle: return hasLoadedOnce ? .working : .syncing
        }
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<HomeSection, HomeItem>()
        if hasLoadedOnce {
            let down = viewModel.servers.filter { viewModel.unreachable.contains($0.id) }
            if !down.isEmpty {
                snapshot.appendSections([.alerts])
                snapshot.appendItems(
                    down.map { .alert(ServerAlertCard(profileID: $0.id, name: $0.name)) },
                    toSection: .alerts)
            }
        }
        let live = viewModel.entries.filter(isLive)
            .sorted { lhs, rhs in
                let lhsBlocked = presence(for: lhs) == .needsInput
                let rhsBlocked = presence(for: rhs) == .needsInput
                if lhsBlocked != rhsBlocked { return lhsBlocked }
                return lhs.session.updatedAt > rhs.session.updatedAt
            }
            .prefix(10)
        if !live.isEmpty {
            snapshot.appendSections([.live])
            snapshot.appendItems(
                live.map { .live(LiveCard(entry: $0, presence: presence(for: $0))) },
                toSection: .live)
        }
        let projects = projectCards()
        if !projects.isEmpty {
            snapshot.appendSections([.projects])
            snapshot.appendItems(projects.map(HomeItem.project), toSection: .projects)
        }
        let liveIDs = Set(live.map(\.session.id))
        let isUnread = SessionSeenStore.unreadEvaluator()
        let recent = viewModel.entries.filter { !liveIDs.contains($0.session.id) }.prefix(6)
        if !recent.isEmpty {
            snapshot.appendSections([.recent])
            snapshot.appendItems(
                recent.map {
                    .recent(RecentCard(entry: $0, unread: isUnread($0.session.id, $0.session.updatedAt)))
                }, toSection: .recent)
        } else if !hasLoadedOnce, !viewModel.servers.isEmpty {
            snapshot.appendSections([.recent])
            snapshot.appendItems((0..<3).map(HomeItem.placeholder), toSection: .recent)
        }
        if !quotas.isEmpty {
            snapshot.appendSections([.usage])
            snapshot.appendItems(
                quotas.map { .usage(QuotaCard(quota: $0)) }, toSection: .usage)
        }
        let existing = Set(dataSource.snapshot().itemIdentifiers)
        let carried = snapshot.itemIdentifiers.filter { existing.contains($0) }
        if !carried.isEmpty { snapshot.reconfigureItems(carried) }
        dataSource.apply(snapshot, animatingDifferences: false)
        updateEmptyState(itemCount: snapshot.numberOfItems)
        consumePendingDeepLink()
    }

    private func projectCards() -> [ProjectCard] {
        struct Key: Hashable {
            let profileID: String
            let directory: String
        }
        var counts: [Key: Int] = [:]
        var latest: [Key: Date] = [:]
        var meta: [Key: (name: String, backend: AgentType)] = [:]
        for entry in viewModel.entries {
            guard let directory = entry.session.directory else { continue }
            let key = Key(profileID: entry.profileID, directory: directory)
            counts[key, default: 0] += 1
            if entry.session.updatedAt > (latest[key] ?? .distantPast) {
                latest[key] = entry.session.updatedAt
            }
            meta[key] = (entry.profileName, entry.backendType)
        }
        return latest.sorted { $0.value > $1.value }.prefix(6).compactMap { key, _ in
            guard let info = meta[key], let count = counts[key] else { return nil }
            return ProjectCard(
                profileID: key.profileID, profileName: info.name, backend: info.backend,
                directory: key.directory, chatCount: count)
        }
    }

    private func updateEmptyState(itemCount: Int) {
        collectionView.backgroundView = nil
        if itemCount > 0 {
            contentUnavailableConfiguration = nil
        } else if viewModel.isEmptyOfServers {
            var config = UIContentUnavailableConfiguration.empty()
            config.image = UIImage(systemName: "server.rack")
            config.text = "No servers connected"
            config.secondaryText = "Add a connection in Settings to start chatting with your agents."
            contentUnavailableConfiguration = config
        } else if !hasLoadedOnce {
            contentUnavailableConfiguration = UIContentUnavailableConfiguration.loading()
        } else {
            contentUnavailableConfiguration = nil
            collectionView.backgroundView = Self.emptyHintView()
        }
    }

    /// A plain background hint rather than `contentUnavailableConfiguration`,
    /// which would overlay (and block) the docked composer it points at.
    private static func emptyHintView() -> UIView {
        let icon = UIImageView(
            image: UIImage(
                systemName: "bubble.left.and.bubble.right",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 34, weight: .regular)))
        icon.tintColor = Theme.Color.tertiaryLabel
        icon.contentMode = .scaleAspectFit

        let title = UILabel()
        title.text = "No conversations yet"
        title.font = .preferredFont(forTextStyle: .headline)
        title.textColor = Theme.Color.secondaryLabel
        title.textAlignment = .center

        let subtitle = UILabel()
        subtitle.text = "Start one below."
        subtitle.font = .preferredFont(forTextStyle: .subheadline)
        subtitle.textColor = Theme.Color.tertiaryLabel
        subtitle.textAlignment = .center

        let stack = UIStackView(arrangedSubviews: [icon, title, subtitle])
        stack.axis = .vertical
        stack.spacing = Theme.Spacing.s
        stack.alignment = .center
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = UIView()
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: container.centerYAnchor, constant: -40),
        ])
        return container
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
        view.endEditing(true)
        presentedViewController?.dismiss(animated: false)
        navigationController?.popToRootViewController(animated: false)
        openChat(for: entry)
    }

    /// Stays parked until the session actually appears: the cold-launch
    /// snapshot applies before the list loads, and consuming (and dropping)
    /// the link on that early pass loses notification taps.
    private func consumePendingDeepLink() {
        guard let pending = pendingDeepLink else { return }
        guard Date().timeIntervalSince(pending.parkedAt) < 30 else {
            pendingDeepLink = nil
            return
        }
        guard let entry = viewModel.entries.first(where: { $0.session.id == pending.sessionID })
        else { return }
        pendingDeepLink = nil
        openChat(for: entry)
    }

    @discardableResult
    private func openChat(for entry: SessionEntry) -> ChatViewModel? {
        guard let backend = viewModel.backend(for: entry) else { return nil }
        SessionSeenStore.markSeen(entry.session.id)
        let chatViewModel =
            SessionActivity.shared.retainedViewModel(
                for: entry.session.id, contextID: entry.profileID)
            ?? ChatViewModel(
                backend: backend, session: entry.session, contextID: entry.profileID,
                serverName: entry.profileName)
        navigationController?.pushViewController(
            ChatViewController(viewModel: chatViewModel), animated: true)
        return chatViewModel
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

    func pushUsage() {
        navigationController?.pushViewController(UsageViewController(), animated: true)
    }

    private func configureCollectionView() {
        let layout = UICollectionViewCompositionalLayout { [weak self] index, environment in
            guard let self,
                let section = self.dataSource?.snapshot().sectionIdentifiers[safe: index]
            else { return Self.listSection() }
            switch section {
            case .live: return Self.liveSection()
            case .projects: return Self.projectsSection()
            case .alerts: return Self.listSection(withHeader: false)
            case .recent, .usage: return Self.listSection()
            }
        }
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.refreshControl = refreshControl
        collectionView.keyboardDismissMode = .interactive
        let dismissTap = UITapGestureRecognizer(target: self, action: #selector(backgroundTapped))
        dismissTap.cancelsTouchesInView = false
        collectionView.addGestureRecognizer(dismissTap)
        refreshControl.addTarget(self, action: #selector(refresh), for: .valueChanged)
        view.addSubview(collectionView)
    }

    /// Tapping anywhere outside the composer puts the keyboard away; the tap
    /// still reaches whatever it landed on. Project cards are exempt — their
    /// whole point is to re-aim the composer, so the keyboard stays up.
    @objc private func backgroundTapped(_ gesture: UITapGestureRecognizer) {
        guard composerBar.isEditingText else { return }
        if let indexPath = collectionView.indexPathForItem(at: gesture.location(in: collectionView)),
            case .project = dataSource.itemIdentifier(for: indexPath)
        {
            return
        }
        view.endEditing(true)
    }

    private func configureComposer() {
        composerBar.delegate = self
        composerBar.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(composerBar)
        NSLayoutConstraint.activate([
            composerBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            composerBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            composerBar.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
        ])
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

    private static func projectsSection() -> NSCollectionLayoutSection {
        let item = NSCollectionLayoutItem(
            layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .fractionalHeight(1)))
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: .init(widthDimension: .absolute(150), heightDimension: .absolute(88)),
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

    private static func listSection(withHeader: Bool = true) -> NSCollectionLayoutSection {
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
        if withHeader { section.boundarySupplementaryItems = [header()] }
        return section
    }

    private static func header() -> NSCollectionLayoutBoundarySupplementaryItem {
        NSCollectionLayoutBoundarySupplementaryItem(
            layoutSize: .init(widthDimension: .fractionalWidth(1), heightDimension: .estimated(30)),
            elementKind: UICollectionView.elementKindSectionHeader, alignment: .top)
    }

    private func configureDataSource() {
        let alertCell = UICollectionView.CellRegistration<ServerAlertCell, ServerAlertCard> {
            cell, _, card in cell.configure(card)
        }
        let liveCell = UICollectionView.CellRegistration<LiveSessionCell, LiveCard> {
            cell, _, card in cell.configure(card)
        }
        let projectCell = UICollectionView.CellRegistration<ProjectCell, ProjectCard> {
            cell, _, card in cell.configure(card)
        }
        let recentCell = UICollectionView.CellRegistration<RecentSessionCell, RecentCard> {
            cell, _, card in cell.configure(card)
        }
        let quotaCell = UICollectionView.CellRegistration<QuotaCardCell, QuotaCard> {
            cell, _, card in cell.configure(card)
        }
        let placeholderCell = UICollectionView.CellRegistration<RecentPlaceholderCell, Int> {
            _, _, _ in
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
            collectionView, indexPath, item in
            switch item {
            case .alert(let card):
                return collectionView.dequeueConfiguredReusableCell(
                    using: alertCell, for: indexPath, item: card)
            case .live(let card):
                return collectionView.dequeueConfiguredReusableCell(
                    using: liveCell, for: indexPath, item: card)
            case .project(let card):
                return collectionView.dequeueConfiguredReusableCell(
                    using: projectCell, for: indexPath, item: card)
            case .recent(let card):
                return collectionView.dequeueConfiguredReusableCell(
                    using: recentCell, for: indexPath, item: card)
            case .usage(let card):
                return collectionView.dequeueConfiguredReusableCell(
                    using: quotaCell, for: indexPath, item: card)
            case .placeholder(let index):
                return collectionView.dequeueConfiguredReusableCell(
                    using: placeholderCell, for: indexPath, item: index)
            }
        }

        let header = UICollectionView.SupplementaryRegistration<HomeHeaderView>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            guard let self,
                let section = self.dataSource.snapshot().sectionIdentifiers[safe: indexPath.section]
            else { return }
            switch section {
            case .alerts:
                break
            case .live:
                view.configure(title: "Live now")
            case .projects:
                view.configure(title: "Projects")
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

extension HomeViewController: HomeComposerBarDelegate {
    func homeComposer(_ bar: HomeComposerBar, didSend text: String) {
        composerSend(text)
    }

    func homeComposerDidBeginEditing(_ bar: HomeComposerBar) {}

    private var composeTarget: (profileID: String, directory: String?)? {
        if let stored = AppPreferences.lastComposeTarget,
            viewModel.servers.contains(where: { $0.id == stored.profileID })
        {
            return stored
        }
        if let recent = viewModel.entries.first(where: { $0.session.directory != nil }) {
            return (recent.profileID, recent.session.directory)
        }
        guard let first = viewModel.servers.first else { return nil }
        return (first.id, FileBrowserRecents.all(for: first.id).first)
    }

    private func updateComposer() {
        composerBar.isHidden = viewModel.servers.isEmpty
        guard let target = composeTarget,
            let profile = viewModel.servers.first(where: { $0.id == target.profileID })
        else { return }
        let project = target.directory.map { ($0 as NSString).lastPathComponent }
        let title = project.map { "\($0) · \(profile.name)" } ?? profile.name
        let icon = UIImage(
            systemName: profile.backend.symbolName,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))?
            .withTintColor(profile.backend.brandColor, renderingMode: .alwaysOriginal)
        composerBar.setContext(icon: icon, title: title, menu: composeTargetMenu())
        view.setNeedsLayout()
    }

    private func composeTargetMenu() -> UIMenu {
        let current = composeTarget
        let serverMenus: [UIMenuElement] = viewModel.servers.map { profile in
            var children: [UIMenuElement] = []
            children.append(contentsOf: recentDirectories(for: profile).map { directory in
                UIAction(
                    title: (directory as NSString).lastPathComponent,
                    subtitle: directory,
                    image: UIImage(systemName: "folder"),
                    state: current?.profileID == profile.id && current?.directory == directory
                        ? .on : .off
                ) { [weak self] _ in
                    self?.setComposeTarget(profile: profile, directory: directory)
                }
            })
            let backend = viewModel.backend(forProfileID: profile.id)
            if backend is any FileBrowsingBackend,
                backend?.capabilities.supportsFileBrowsing == true
            {
                children.append(
                    UIAction(title: "Browse…", image: UIImage(systemName: "folder.badge.plus")) {
                        [weak self] _ in self?.browseComposeTarget(profile: profile)
                    })
            } else {
                children.append(
                    UIAction(title: "Enter path…", image: UIImage(systemName: "character.cursor.ibeam")) {
                        [weak self] _ in self?.promptComposePath(profile: profile)
                    })
            }
            if viewModel.servers.count == 1 {
                return UIMenu(options: .displayInline, children: children)
            }
            return UIMenu(
                title: profile.name,
                image: UIImage(systemName: profile.backend.symbolName),
                children: children)
        }
        return UIMenu(title: "Start the chat in…", children: serverMenus)
    }

    /// Explicitly chosen recents first, then directories of past sessions.
    private func recentDirectories(for profile: ConnectionProfile) -> [String] {
        let sessionDirs = viewModel.entries
            .filter { $0.profileID == profile.id }
            .compactMap(\.session.directory)
        var seen = Set<String>()
        var result: [String] = []
        for directory in FileBrowserRecents.all(for: profile.id) + sessionDirs
        where seen.insert(directory).inserted {
            result.append(directory)
            if result.count == 6 { break }
        }
        return result
    }

    private func setComposeTarget(profile: ConnectionProfile, directory: String?) {
        AppPreferences.lastComposeTarget = (profile.id, directory)
        if let directory { FileBrowserRecents.record(directory, for: profile.id) }
        Theme.Haptics.selection()
        updateComposer()
    }

    private func browseComposeTarget(profile: ConnectionProfile) {
        guard
            let backend = viewModel.backend(forProfileID: profile.id) as? (any FileBrowsingBackend)
        else { return }
        let browser = FileBrowserViewController(backend: backend, profileID: profile.id)
        browser.onSelect = { [weak self] path in
            guard let self else { return }
            self.presentedViewController?.dismiss(animated: true) {
                self.setComposeTarget(profile: profile, directory: path)
                self.composerBar.focus()
            }
        }
        present(UINavigationController(rootViewController: browser), animated: true)
    }

    private func promptComposePath(profile: ConnectionProfile) {
        let alert = UIAlertController(
            title: "Project directory",
            message: "Enter a directory path on \(profile.name)",
            preferredStyle: .alert)
        alert.addTextField { textField in
            textField.placeholder = "/path/to/project"
            textField.autocorrectionType = .no
            textField.autocapitalizationType = .none
            textField.keyboardType = .URL
        }
        alert.addAction(UIAlertAction(title: "Use", style: .default) { [weak self, weak alert] _ in
            let trimmed = alert?.textFields?.first?.text?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let trimmed, !trimmed.isEmpty else { return }
            self?.setComposeTarget(profile: profile, directory: trimmed)
            self?.composerBar.focus()
        })
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        present(alert, animated: true)
    }

    /// The session is created only now, on commit; the composer keeps the
    /// text until the create succeeds so a dead server loses nothing.
    private func composerSend(_ text: String) {
        guard let target = composeTarget,
            let profile = viewModel.servers.first(where: { $0.id == target.profileID })
        else { return }
        composerBar.setSending(true)
        Task {
            guard let entry = await viewModel.newSession(on: profile, directory: target.directory)
            else {
                composerBar.setSending(false)
                Theme.Haptics.error()
                let alert = UIAlertController(
                    title: "Couldn't start the chat",
                    message: "\(profile.name) didn't respond. Check the connection and try again.",
                    preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: "OK", style: .default))
                present(alert, animated: true)
                return
            }
            if let directory = target.directory {
                FileBrowserRecents.record(directory, for: profile.id)
            }
            AppPreferences.lastComposeTarget = target
            composerBar.setSending(false)
            composerBar.clearText()
            view.endEditing(true)
            Theme.Haptics.success()
            openChat(for: entry)?.send(text)
        }
    }
}

extension HomeViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        switch item {
        case .alert:
            onOpenSettings?()
        case .live(let card):
            openChat(for: card.entry)
        case .project(let card):
            guard let profile = viewModel.servers.first(where: { $0.id == card.profileID })
            else { return }
            setComposeTarget(profile: profile, directory: card.directory)
            composerBar.focus()
        case .recent(let card):
            openChat(for: card.entry)
        case .usage:
            pushUsage()
        case .placeholder:
            break
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
        case .project(let card):
            return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
                UIMenu(children: [
                    UIAction(title: "New chat here", image: UIImage(systemName: "plus.bubble")) { _ in
                        guard let self,
                            let profile = self.viewModel.servers.first(where: { $0.id == card.profileID })
                        else { return }
                        Task {
                            guard let entry = await self.viewModel.newSession(
                                on: profile, directory: card.directory)
                            else { return }
                            Theme.Haptics.success()
                            self.openChat(for: entry)
                        }
                    },
                    UIAction(
                        title: "View chats on \(card.profileName)",
                        image: UIImage(systemName: "bubble.left.and.bubble.right")
                    ) { _ in self?.pushChats(filterProfileID: card.profileID) },
                ])
            }
        case .recent(let card):
            return sessionMenu(for: card.entry, allowDelete: true)
        case .live(let card):
            return sessionMenu(for: card.entry, allowDelete: false)
        case .alert, .usage, .placeholder:
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
