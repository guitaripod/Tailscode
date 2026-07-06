import CodingAgentKit
import UIKit

@MainActor
final class SessionListViewController: UIViewController {
    var onOpenSettings: (() -> Void)?

    private enum Section { case main }

    private let viewModel: SessionListViewModel
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, AgentSession>!
    private let emptyState = EmptyStateView(
        symbol: "bubble.left.and.text.bubble.right",
        title: "No sessions yet",
        message: "Tap + to start a conversation with your agent.")
    private let refreshControl = UIRefreshControl()

    init() {
        let backend =
            ConnectionController.shared.makeBackend()
            ?? UnavailableBackend()
        self.viewModel = SessionListViewModel(backend: backend)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = ConnectionController.shared.activeProfile?.name ?? "Sessions"
        view.backgroundColor = Theme.Color.groupedBackground
        configureNavItems()
        configureCollectionView()
        configureDataSource()
        bind()
        Task { await viewModel.load() }
    }

    private func configureNavItems() {
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            image: UIImage(systemName: "gearshape"), style: .plain, target: self,
            action: #selector(openSettings))
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .add, target: self, action: #selector(newSession))
    }

    private func configureCollectionView() {
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            guard let self, self.viewModel.supportsMultipleSessions,
                let session = self.dataSource.itemIdentifier(for: indexPath)
            else { return nil }
            let delete = UIContextualAction(style: .destructive, title: "Delete") { _, _, done in
                Task { await self.viewModel.delete(session); done(true) }
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
        let registration = UICollectionView.CellRegistration<UICollectionViewListCell, AgentSession> {
            cell, _, session in
            var content = cell.defaultContentConfiguration()
            content.text = session.title
            content.textProperties.numberOfLines = 1
            content.secondaryText = session.updatedAt.formatted(.relative(presentation: .named))
            content.secondaryTextProperties.color = Theme.Color.secondaryLabel
            content.image = UIImage(systemName: "text.bubble")
            content.imageProperties.tintColor = Theme.Color.accent
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
            collectionView, indexPath, session in
            collectionView.dequeueConfiguredReusableCell(
                using: registration, for: indexPath, item: session)
        }
    }

    private func bind() {
        viewModel.onChange = { [weak self] in self?.applySnapshot() }
        viewModel.onError = { [weak self] message in self?.present(error: message) }
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, AgentSession>()
        snapshot.appendSections([.main])
        snapshot.appendItems(viewModel.sessions, toSection: .main)
        dataSource.apply(snapshot, animatingDifferences: true)
        emptyState.isHidden = !viewModel.sessions.isEmpty
        refreshControl.endRefreshing()
    }

    @objc private func refresh() { Task { await viewModel.load() } }
    @objc private func openSettings() { onOpenSettings?() }

    @objc private func newSession() {
        Theme.Haptics.tap()
        Task {
            guard let session = await viewModel.newSession() else { return }
            openChat(for: session)
        }
    }

    private func openChat(for session: AgentSession) {
        let chatViewModel = ChatViewModel(backend: viewModel.backend, session: session)
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
        guard let session = dataSource.itemIdentifier(for: indexPath) else { return }
        openChat(for: session)
    }
}
