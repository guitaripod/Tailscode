import CodingAgentKit
import CodingAgentKitApple
import UIKit

@MainActor
final class ServerDetailViewController: UIViewController {
    private let profile: ConnectionProfile
    var onRemoved: (() -> Void)?

    private enum Section: Int, CaseIterable { case info, status, actions }
    private enum Item: Hashable {
        case value(label: String, value: String)
        case status(String)
        case test
        case remove
    }

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var statusText = "Checking…"
    private var sessionCount: Int?
    private var serverVersion: String?
    private var modelCount: Int?
    private var latestVersion: String?

    init(profile: ConnectionProfile) {
        self.profile = profile
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = profile.name
        view.backgroundColor = Theme.Color.groupedBackground
        configure()
        applySnapshot()
        Task { await refresh() }
    }

    private func configure() {
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .supplementary
        let layout = UICollectionViewCompositionalLayout.list(using: config)
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        view.addSubview(collectionView)

        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { cell, _, item in
            var content = cell.defaultContentConfiguration()
            cell.accessories = []
            switch item {
            case .value(let label, let value):
                content.text = label
                content.secondaryText = value
                content.prefersSideBySideTextAndSecondaryText = true
                content.secondaryTextProperties.color = Theme.Color.secondaryLabel
                if label == "Update available" {
                    content.secondaryTextProperties.color = Theme.Color.warning
                }
            case .status(let text):
                content.text = "Status"
                content.secondaryText = text
                content.prefersSideBySideTextAndSecondaryText = true
            case .test:
                content.text = "Test connection"
                content.textProperties.color = Theme.Color.accent
                content.image = UIImage(systemName: "antenna.radiowaves.left.and.right")
                content.imageProperties.tintColor = Theme.Color.accent
            case .remove:
                content.text = "Remove connection"
                content.textProperties.color = Theme.Color.danger
                content.image = UIImage(systemName: "trash")
                content.imageProperties.tintColor = Theme.Color.danger
            }
            cell.contentConfiguration = content
        }

        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { view, _, indexPath in
            var content = UIListContentConfiguration.header()
            content.text = ["Server", "Health", ""][indexPath.section]
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

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections(Section.allCases)
        var info: [Item] = [
            .value(label: "Backend", value: profile.backend.displayName),
            .value(label: "Host", value: profile.baseURL.host ?? "—"),
            .value(label: "Port", value: profile.baseURL.port.map(String.init) ?? "—"),
        ]
        if let serverVersion {
            info.append(.value(label: "Version", value: serverVersion))
        }
        if let modelCount {
            info.append(.value(label: "Models", value: String(modelCount)))
        }
        if let sessionCount {
            info.append(.value(label: "Sessions", value: String(sessionCount)))
        }
        snapshot.appendItems(info, toSection: .info)
        var statusItems: [Item] = [.status(statusText)]
        if let latestVersion, let serverVersion, serverVersion != latestVersion {
            statusItems.append(.value(label: "Update available", value: latestVersion))
        }
        statusItems.append(.test)
        snapshot.appendItems(statusItems, toSection: .status)
        snapshot.appendItems([.remove], toSection: .actions)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func refresh() async {
        statusText = "Checking…"
        sessionCount = nil
        serverVersion = nil
        modelCount = nil
        applySnapshot()
        let policy = ConnectionPolicy(requestTimeout: .seconds(8), resourceTimeout: .seconds(12))
        guard let backend = ConnectionController.shared.makeBackend(for: profile, policy: policy) else {
            statusText = "No credentials"
            applySnapshot()
            return
        }
        do {
            let health = try await backend.health()
            statusText = health.healthy ? "Healthy" : "Unhealthy"
            serverVersion = health.version
            sessionCount = (try? await backend.listSessions())?.count
            if profile.backend == .openCode {
                modelCount = try? await backend.availableModels().count
                latestVersion = await fetchLatestOpencodeRelease()
            }
        } catch {
            statusText = "Unreachable"
        }
        applySnapshot()
    }

    /// GitHub's latest opencode release tag, so the user can see at a glance
    /// whether the server process is behind and might be missing new models.
    private func fetchLatestOpencodeRelease() async -> String? {
        guard let url = URL(string: "https://api.github.com/repos/anomalyco/opencode/releases/latest")
        else { return nil }
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 6
        guard
            let (data, _) = try? await URLSession.shared.data(for: request),
            let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let tag = json["tag_name"] as? String
        else { return nil }
        return tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
    }

    private func confirmRemove() {
        let isDemo = profile.id.hasPrefix(DemoWorld.profilePrefix)
        let alert = UIAlertController(
            title: isDemo ? "Leave the demo?" : "Remove \(profile.name)?",
            message: isDemo
                ? "This removes both sample servers."
                : "This deletes the saved server and its password from the Keychain.",
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "Cancel", style: .cancel))
        alert.addAction(UIAlertAction(title: "Remove", style: .destructive) { [weak self] _ in
            guard let self else { return }
            try? ConnectionController.shared.delete(profile.id)
            Theme.Haptics.warning()
            onRemoved?()
            navigationController?.popViewController(animated: true)
        })
        present(alert, animated: true)
    }
}

extension ServerDetailViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .test:
            Theme.Haptics.tap()
            Task { await refresh() }
        case .remove:
            confirmRemove()
        default:
            break
        }
    }
}
