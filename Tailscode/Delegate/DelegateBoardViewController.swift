import CodingAgentKit
import TailscodeCore
import UIKit

/// One machine's dispatcher as a screen: whether it answers, the ladder it holds, every run it
/// remembers with the live ones folding as they go, and what the numbers say. Every word is
/// `DelegateBoard`'s; this controller draws rows and forwards taps to the desk.
@MainActor
final class DelegateBoardViewController: UIViewController {
    private enum Section: Int, CaseIterable { case status, tiers, runs, stats }
    private enum Item: Hashable {
        case note
        case status
        case password
        case tier(String)
        case run(String)
        case empty
        case stat(String)
        case hint(Int)
    }

    private let host: String
    private let serverName: String
    private let desk = DelegateGate.desk
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var board: DelegateBoard { desk.board(host: host, serverName: serverName) }
    private var reach: DelegateReach { desk.reach[host] ?? .unknown }

    init(host: String, serverName: String) {
        self.host = host
        self.serverName = serverName
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = board.title
        navigationItem.largeTitleDisplayMode = .always
        view.backgroundColor = Theme.Color.groupedBackground
        let plus = UIBarButtonItem(
            image: UIImage(systemName: "plus"),
            primaryAction: UIAction { [weak self] _ in self?.compose() })
        plus.accessibilityLabel = DelegateEntryPoint.newPacketTitle
        let beta = DelegateBetaBadge()
        beta.onTap = { [weak self] in self?.explainBeta() }
        navigationItem.rightBarButtonItems = [plus, UIBarButtonItem(customView: beta)]
        configure()
        NotificationCenter.default.addObserver(
            self, selector: #selector(deskChanged), name: DelegateDesk.didChange, object: nil)
        applySnapshot()
        if board.phase == .idle { desk.probe(host: host, serverName: serverName) }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if board.isReady { Task { await desk.refresh(host: host) } }
    }

    @objc private func deskChanged() {
        applySnapshot()
    }

    private func configure() {
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .supplementary
        let layout = UICollectionViewCompositionalLayout.readableList(using: config)
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.refreshControl = UIRefreshControl()
        collectionView.refreshControl?.addAction(UIAction { [weak self] _ in self?.pulled() }, for: .valueChanged)
        view.addSubview(collectionView)

        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            self?.configure(cell, item)
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.header()
            content.text = self?.sectionTitle(at: indexPath.section)
            view.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: item)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
    }

    private func pulled() {
        if board.isReady {
            Task {
                await desk.refresh(host: host)
                collectionView.refreshControl?.endRefreshing()
            }
        } else {
            desk.probe(host: host, serverName: serverName)
            collectionView.refreshControl?.endRefreshing()
        }
    }

    private func sectionTitle(at index: Int) -> String? {
        switch dataSource.snapshot().sectionIdentifiers[safe: index] {
        case .status: return serverName
        case .tiers: return String(localized: "Ladder")
        case .runs: return String(localized: "Runs")
        case .stats: return String(localized: "Pass rates")
        case .none: return nil
        }
    }

    private func applySnapshot() {
        let board = board
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.status])
        var status: [Item] = board.note == nil ? [.status] : [.note, .status]
        if case .wantsPassword = reach { status.append(.password) }
        if case .refused = reach { status.append(.password) }
        if desk.password(host: host) == nil, !board.isReady { status.append(.password) }
        snapshot.appendItems(status.reduce(into: [Item]()) { if !$0.contains($1) { $0.append($1) } }, toSection: .status)
        if !board.tiers.isEmpty {
            snapshot.appendSections([.tiers])
            snapshot.appendItems(board.tierLines.map { .tier($0.tier) }, toSection: .tiers)
        }
        if board.isReady {
            snapshot.appendSections([.runs])
            let runs = board.runStories.map { Item.run($0.runID) }
            snapshot.appendItems(runs.isEmpty ? [.empty] : runs, toSection: .runs)
        }
        if !board.stats.isEmpty {
            snapshot.appendSections([.stats])
            snapshot.appendItems(board.statRows.map { .stat($0.id) }, toSection: .stats)
            snapshot.appendItems(board.promotions.indices.map { .hint($0) }, toSection: .stats)
        }
        let reconfigure = snapshot.itemIdentifiers.filter { dataSource.snapshot().itemIdentifiers.contains($0) }
        snapshot.reconfigureItems(reconfigure)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func configure(_ cell: UICollectionViewListCell, _ item: Item) {
        var content = cell.defaultContentConfiguration()
        cell.accessories = []
        let board = board
        switch item {
        case .note:
            content.text = board.note
            content.textProperties.numberOfLines = 0
            content.textProperties.font = Theme.Ramp.font(.rowNote)
            content.textProperties.color = Theme.Color.secondaryLabel
            content.image = UIImage(systemName: "play.circle")
            content.imageProperties.tintColor = Theme.Color.special
        case .status:
            content.text = board.statusLine
            content.secondaryText = reach.isAnswering || board.statusLine == reach.line ? DelegateEntryPoint.subtitle : reach.line
            content.secondaryTextProperties.color = Theme.Color.secondaryLabel
            content.image = UIImage(systemName: DelegateEntryPoint.symbol)
            content.imageProperties.tintColor = (reach == .unknown ? board.statusTone : reach.tone).color
            if board.phase == .checking { cell.accessories = [.working()] }
        case .password:
            content.text = desk.password(host: host) == nil
                ? String(localized: "Enter the dispatcher's password")
                : String(localized: "Change the dispatcher's password")
            content.secondaryText = String(localized: "From serve.env on that machine")
            content.secondaryTextProperties.color = Theme.Color.secondaryLabel
            content.textProperties.color = Theme.Color.accent
            content.image = UIImage(systemName: "key")
            content.imageProperties.tintColor = Theme.Color.accent
        case .tier(let tier):
            guard let line = board.tierLines.first(where: { $0.tier == tier }) else { break }
            content.text = line.label.isEmpty ? line.tier : "\(line.tier) · \(line.label)"
            content.secondaryText = line.model
            content.secondaryTextProperties.font = Theme.Ramp.font(.code)
            content.secondaryTextProperties.color = Theme.Color.secondaryLabel
            cell.accessories = [.label(text: line.detail, options: .init(tintColor: line.tone.color))]
        case .run(let runID):
            guard let story = board.story(for: runID) else { break }
            content.text = story.headline
            content.textProperties.numberOfLines = 2
            content.secondaryText = story.subtitle
            content.secondaryTextProperties.numberOfLines = 2
            content.secondaryTextProperties.color = story.tone == .quiet ? Theme.Color.secondaryLabel : story.tone.color
            var accessories: [UICellAccessory] = []
            if let badge = story.badge {
                accessories.append(.label(text: badge, options: .init(tintColor: story.tone.color)))
            }
            if let activity = story.activity {
                let badge = ActivityBadgeView()
                badge.show(activity.icon, spoken: nil)
                accessories.append(.customView(configuration: .init(customView: badge, placement: .trailing())))
            }
            accessories.append(.disclosureIndicator())
            cell.accessories = accessories
            cell.accessibilityLabel = "\(story.headline). \(story.subtitle)"
        case .empty:
            content.text = board.emptyLine
            content.textProperties.color = Theme.Color.secondaryLabel
            content.textProperties.numberOfLines = 0
        case .stat(let id):
            guard let row = board.statRows.first(where: { $0.id == id }) else { break }
            content.text = "\(row.taskClass) · \(row.tier)"
            content.secondaryText = row.line
            content.secondaryTextProperties.color = Theme.Color.secondaryLabel
            cell.accessories = [.label(text: row.rateText, options: .init(tintColor: row.rate >= 0.9 ? Theme.Color.success : (row.rate <= 0.3 ? Theme.Color.danger : Theme.Color.secondaryLabel)))]
        case .hint(let index):
            content.text = board.promotions[safe: index]
            content.textProperties.numberOfLines = 0
            content.textProperties.font = Theme.Ramp.font(.rowNote)
            content.image = UIImage(systemName: "lightbulb")
            content.imageProperties.tintColor = Theme.Color.special
        }
        cell.contentConfiguration = content
    }

    /// Why the feature wears its mark, in Core's words, sized to them.
    func explainBeta() {
        DelegateBetaViewController.present(from: self)
    }

    private func compose() {
        Theme.Haptics.tap()
        let composer = DelegateComposerViewController(host: host, serverName: serverName)
        composer.onStarted = { [weak self] runID in
            guard let self else { return }
            self.navigationController?.pushViewController(
                DelegateRunViewController(host: self.host, serverName: self.serverName, runID: runID), animated: true)
        }
        let nav = UINavigationController(rootViewController: composer)
        nav.navigationBar.prefersLargeTitles = false
        present(nav, animated: true)
    }

    private func askPassword() {
        let alert = UIAlertController(
            title: String(localized: "Dispatcher password"),
            message: String(localized: "The DELEGATE_PASSWORD line in ~/.config/delegate/serve.env on \(serverName)."),
            preferredStyle: .alert)
        alert.addTextField { field in
            field.isSecureTextEntry = true
            field.placeholder = String(localized: "Password")
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(
            UIAlertAction(title: String(localized: "Save"), style: .default) { [weak self, weak alert] _ in
                guard let self, let text = alert?.textFields?.first?.text, !text.isEmpty else { return }
                self.desk.remember(password: text, host: self.host, serverName: self.serverName)
            })
        present(alert, animated: true)
    }
}

extension DelegateBoardViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        switch item {
        case .password:
            askPassword()
        case .status:
            if !board.isReady { desk.probe(host: host, serverName: serverName) }
        case .run(let runID):
            Theme.Haptics.tap()
            navigationController?.pushViewController(
                DelegateRunViewController(host: host, serverName: serverName, runID: runID), animated: true)
        case .empty:
            compose()
        case .tier, .stat, .hint, .note:
            break
        }
    }
}
