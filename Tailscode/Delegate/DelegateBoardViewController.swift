import CodingAgentKit
import TailscodeCore
import UIKit

/// One machine's dispatcher as a screen: New packet first, the ladder it holds as one row of joined
/// rungs with what the table suggests under it, and every run it remembers grouped by what it asks
/// of the reader. Every word is `DelegateBoard`'s; this controller draws rows and forwards taps.
@MainActor
final class DelegateBoardViewController: UIViewController {
    private enum Section: Hashable {
        case top
        case setup
        case ladder
        case runs(DelegateRunSection.Kind)
    }

    private enum Item: Hashable {
        case compose
        case status
        case password
        case setupLead
        case setup(String)
        case ladder
        case hint(Int)
        case run(String)
        case empty
    }

    private let host: String
    private let serverName: String
    private let desk = DelegateGate.desk
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var board: DelegateBoard { desk.board(host: host, serverName: serverName) }
    private var reach: DelegateReach { desk.reach[host] ?? .unknown }
    private var copiedStep: String?
    private var sections: [DelegateRunSection] = []
    private let ladderView = DelegateBoardLadderView()
    private lazy var composeView = makeComposeView()
    private let composeNote = UILabel()

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
        let runCell = UICollectionView.CellRegistration<DelegateRunRowCell, Item> { [weak self] cell, _, item in
            guard case .run(let runID) = item, let row = self?.row(runID) else { return }
            cell.show(row)
        }
        let hostCell = UICollectionView.CellRegistration<DelegateHostCell, Item> { [weak self] cell, _, item in
            guard let self else { return }
            switch item {
            case .compose:
                self.composeNote.text = self.board.note ?? DelegateEntryPoint.subtitle
                cell.place(self.composeView)
                cell.backgroundConfiguration = .clear()
            case .ladder:
                self.ladderView.show(self.board.ladderRungs)
                cell.place(self.ladderView)
            default:
                break
            }
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.header()
            content.text = self?.sectionTitle(at: indexPath.section)
            view.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            switch item {
            case .run: return collectionView.dequeueConfiguredReusableCell(using: runCell, for: indexPath, item: item)
            case .compose, .ladder: return collectionView.dequeueConfiguredReusableCell(using: hostCell, for: indexPath, item: item)
            default: return collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: item)
            }
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
    }

    /// The primary action and the board's one standing sentence, outside any card.
    private func makeComposeView() -> UIView {
        let button = PrimaryButton(title: DelegateEntryPoint.newPacketTitle)
        button.configuration?.image = UIImage(systemName: "plus")
        button.configuration?.imagePadding = Theme.Spacing.s
        button.addAction(UIAction { [weak self] _ in self?.compose() }, for: .touchUpInside)
        composeNote.font = Theme.Ramp.font(.cardBody)
        composeNote.textColor = Theme.Color.secondaryLabel
        composeNote.numberOfLines = 0
        composeNote.adjustsFontForContentSizeCategory = true
        let column = UIStackView(arrangedSubviews: [button, composeNote])
        column.axis = .vertical
        column.spacing = Theme.Spacing.s
        return column
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

    private func row(_ runID: String) -> DelegateRunRow? {
        for section in sections {
            if let row = section.rows.first(where: { $0.runID == runID }) { return row }
        }
        return nil
    }

    private func sectionTitle(at index: Int) -> String? {
        switch dataSource.snapshot().sectionIdentifiers[safe: index] {
        case .top:
            if #available(iOS 26.0, *) { return nil }
            return board.subtitle
        case .setup: return DelegateSetup.title
        case .ladder: return DelegateComposerWords.ladderLabel
        case .runs(let kind): return sections.first { $0.kind == kind }?.title
        case .none: return nil
        }
    }

    private func applySnapshot() {
        let board = board
        if #available(iOS 26.0, *) { navigationItem.subtitle = board.subtitle }
        sections = board.isReady ? board.sections() : []
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.top])
        var top: [Item] = board.isReady ? [.compose] : [.status]
        if reach.asksForPassword || (desk.password(host: host) != nil && !desk.isDemo(host: host)) { top.append(.password) }
        snapshot.appendItems(top, toSection: .top)
        if DelegateSetup.isWanted(board: board, known: desk.isKnown(host: host)) {
            snapshot.appendSections([.setup])
            snapshot.appendItems([.setupLead] + DelegateSetup.steps.map { .setup($0.id) }, toSection: .setup)
        }
        if !board.tiers.isEmpty {
            snapshot.appendSections([.ladder])
            snapshot.appendItems([.ladder] + board.promotions.indices.map { .hint($0) }, toSection: .ladder)
        }
        if board.isReady {
            if sections.isEmpty {
                snapshot.appendSections([.runs(.earlier)])
                snapshot.appendItems([.empty], toSection: .runs(.earlier))
            }
            for section in sections {
                snapshot.appendSections([.runs(section.kind)])
                snapshot.appendItems(section.rows.map { .run($0.runID) }, toSection: .runs(section.kind))
            }
        }
        let existing = Set(dataSource.snapshot().itemIdentifiers)
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter { existing.contains($0) })
        dataSource.apply(snapshot, animatingDifferences: false)
        for header in collectionView.visibleSupplementaryViews(ofKind: UICollectionView.elementKindSectionHeader) {
            guard let header = header as? UICollectionViewListCell,
                let indexPath = collectionView.indexPath(forSupplementaryView: header)
            else { continue }
            var content = UIListContentConfiguration.header()
            content.text = sectionTitle(at: indexPath.section)
            header.contentConfiguration = content
        }
    }

    private func configure(_ cell: UICollectionViewListCell, _ item: Item) {
        var content = cell.defaultContentConfiguration()
        cell.accessories = []
        let board = board
        switch item {
        case .status:
            content.text = board.statusLine
            content.secondaryText = reach.isAnswering || board.statusLine == reach.line ? DelegateEntryPoint.subtitle : reach.line
            content.secondaryTextProperties.color = Theme.Color.secondaryLabel
            content.secondaryTextProperties.numberOfLines = 0
            content.image = UIImage(systemName: DelegateEntryPoint.symbol)
            content.imageProperties.tintColor = (reach == .unknown ? board.statusTone : reach.tone).color
            if board.phase == .checking { cell.accessories = [.working()] }
        case .setupLead:
            content.text = DelegateSetup.lead(serverName: serverName)
            content.textProperties.numberOfLines = 0
            content.textProperties.font = Theme.Ramp.font(.rowNote)
            content.textProperties.color = Theme.Color.secondaryLabel
            content.image = UIImage(systemName: "terminal")
            content.imageProperties.tintColor = Theme.Color.accent
        case .setup(let id):
            guard let step = DelegateSetup.steps.first(where: { $0.id == id }) else { break }
            content.text = step.title
            content.secondaryText = step.command + "\n" + step.detail
            content.secondaryTextProperties.numberOfLines = 0
            content.secondaryTextProperties.font = Theme.Ramp.font(.code)
            content.secondaryTextProperties.color = Theme.Color.secondaryLabel
            let copied = copiedStep == id
            cell.accessories = [
                .label(
                    text: copied ? DelegateSetup.copied : String(localized: "Copy"),
                    options: .init(tintColor: copied ? Theme.Color.success : Theme.Color.accent))
            ]
        case .password:
            content.text = desk.password(host: host) == nil
                ? String(localized: "Enter the dispatcher's password")
                : String(localized: "Change the dispatcher's password")
            content.secondaryText = String(localized: "From serve.env on that machine")
            content.secondaryTextProperties.color = Theme.Color.secondaryLabel
            content.textProperties.color = Theme.Color.accent
            content.image = UIImage(systemName: "key")
            content.imageProperties.tintColor = Theme.Color.accent
        case .hint(let index):
            content.text = board.promotions[safe: index]
            content.textProperties.numberOfLines = 0
            content.textProperties.font = Theme.Ramp.font(.rowNote)
            content.textProperties.color = Theme.Color.secondaryLabel
            content.image = UIImage(systemName: "lightbulb")
            content.imageProperties.tintColor = Theme.Color.special
        case .empty:
            content.text = board.emptyLine
            content.textProperties.color = Theme.Color.secondaryLabel
            content.textProperties.numberOfLines = 0
        case .compose, .ladder, .run:
            break
        }
        cell.contentConfiguration = content
    }

    /// Why the feature wears its mark, in Core's words, sized to them.
    func explainBeta() {
        DelegateBetaViewController.present(from: self)
    }

    func compose() {
        Theme.Haptics.tap()
        DelegateGate.presentComposer(from: self, host: host, serverName: serverName, draft: nil)
    }

    /// One command onto the clipboard, and the row says so for a moment.
    private func copySetupCommand(_ id: String) {
        guard let step = DelegateSetup.steps.first(where: { $0.id == id }) else { return }
        UIPasteboard.general.string = step.command
        Theme.Haptics.tap()
        copiedStep = id
        applySnapshot()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
            guard let self, self.copiedStep == id else { return }
            self.copiedStep = nil
            self.applySnapshot()
        }
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
        case .setup(let id):
            copySetupCommand(id)
        case .compose, .ladder, .hint, .setupLead:
            break
        }
    }
}
