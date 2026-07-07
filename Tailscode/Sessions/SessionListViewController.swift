import CodingAgentKit
import CodingAgentKitApple
import UIKit

@MainActor
final class SessionListViewController: UIViewController {
    var onOpenSettings: (() -> Void)?

    private enum Section { case main }

    private let viewModel: SessionListViewModel
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, SessionEntry>!
    private let emptyState = EmptyStateView(
        symbol: "bubble.left.and.text.bubble.right",
        title: "No sessions yet",
        message: "Tap + to start a conversation on one of your servers.")
    private let refreshControl = UIRefreshControl()
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
        title = "Chats"
        view.backgroundColor = Theme.Color.groupedBackground
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

    private func configureNavItems() {
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "gearshape"), style: .plain, target: self,
            action: #selector(openSettings))
        updateAddButton()
    }

    private func updateAddButton() {
        let servers = viewModel.servers
        if servers.count > 1 {
            let actions = servers.map { profile in
                UIAction(
                    title: profile.name,
                    subtitle: "\(profile.backend.displayName) · \(profile.baseURL.host ?? "")",
                    image: Self.icon(for: profile.backend)
                ) { [weak self] _ in self?.startSession(on: profile) }
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

        emptyState.translatesAutoresizingMaskIntoConstraints = false
        emptyState.isHidden = true
        view.addSubview(emptyState)
        NSLayoutConstraint.activate([
            emptyState.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            emptyState.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            emptyState.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            emptyState.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func configureDataSource() {
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, SessionEntry> {
            cell, _, entry in
            var content = cell.defaultContentConfiguration()
            content.text = Self.displayTitle(entry.session.title)
            content.textProperties.numberOfLines = 1
            content.secondaryText =
                "\(entry.profileName) · \(entry.backendType.displayName) · "
                + entry.session.updatedAt.formatted(.relative(presentation: .named))
            content.secondaryTextProperties.color = Theme.Color.secondaryLabel
            content.secondaryTextProperties.numberOfLines = 1
            content.image = Self.icon(for: entry.backendType)
            content.imageProperties.tintColor = Self.color(forHost: entry.host)
            content.imageProperties.maximumSize = CGSize(width: 22, height: 22)
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
            collectionView, indexPath, entry in
            collectionView.dequeueConfiguredReusableCell(
                using: registration, for: indexPath, item: entry)
        }
    }

    private func bind() {
        viewModel.onChange = { [weak self] in self?.applySnapshot() }
        viewModel.onError = { [weak self] message in self?.present(error: message) }
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, SessionEntry>()
        snapshot.appendSections([.main])
        snapshot.appendItems(viewModel.entries, toSection: .main)
        dataSource.apply(snapshot, animatingDifferences: true)
        emptyState.isHidden = !viewModel.entries.isEmpty
        refreshControl.endRefreshing()
        updateUnreachableFooter()
    }

    private func updateUnreachableFooter() {
        guard !viewModel.unreachable.isEmpty else {
            navigationItem.prompt = nil
            return
        }
        navigationItem.prompt = "Unreachable: \(viewModel.unreachable.joined(separator: ", "))"
    }

    private static func displayTitle(_ title: String) -> String {
        title.hasPrefix("New session") ? "New session" : title
    }

    private static func icon(for backend: AgentType) -> UIImage? {
        let name = backend == .claudeCode ? "sparkles" : "chevron.left.forwardslash.chevron.right"
        return UIImage(systemName: name)
    }

    private static func color(forHost host: String) -> UIColor {
        let palette: [UIColor] = [
            .systemBlue, .systemPurple, .systemTeal, .systemIndigo, .systemPink,
            .systemOrange, .systemGreen,
        ]
        var hash = 5381
        for byte in host.utf8 { hash = ((hash << 5) &+ hash) &+ Int(byte) }
        return palette[abs(hash) % palette.count]
    }

    @objc private func refresh() { Task { await viewModel.load() } }
    @objc private func openSettings() { onOpenSettings?() }

    @objc private func newSessionDefault() {
        guard let profile = viewModel.servers.first else { return }
        startSession(on: profile)
    }

    private func startSession(on profile: ConnectionProfile) {
        Theme.Haptics.tap()
        Task {
            guard let entry = await viewModel.newSession(on: profile) else { return }
            openChat(for: entry)
        }
    }

    private func openChat(for entry: SessionEntry) {
        guard let backend = viewModel.backend(for: entry) else { return }
        let chatViewModel = ChatViewModel(backend: backend, session: entry.session)
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
