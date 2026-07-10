import CodingAgentKit
import UIKit

@MainActor
final class ModelPickerViewController: UIViewController {
    private struct ProviderGroup: Hashable {
        let id: String
        let name: String
    }

    private let allModels: [ModelInfo]
    private let selected: ModelSelection?
    private let onSelect: (ModelSelection) -> Void

    private struct Row: Hashable {
        let model: ModelInfo
        let recent: Bool
    }

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<ProviderGroup, Row>!
    private let search = UISearchController(searchResultsController: nil)
    private var query = ""

    init(models: [ModelInfo], selected: ModelSelection?, onSelect: @escaping (ModelSelection) -> Void) {
        self.allModels = models
        self.selected = selected
        self.onSelect = onSelect
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "Model"
        view.backgroundColor = Theme.Color.groupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close, target: self, action: #selector(close))
        configureSearch()
        configureCollectionView()
        applySnapshot()
    }

    private func configureSearch() {
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = "Search \(allModels.count) models"
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
    }

    private func configureCollectionView() {
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .supplementary
        let layout = UICollectionViewCompositionalLayout.list(using: config)
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        view.addSubview(collectionView)

        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, Row> {
            [weak self] cell, _, row in
            let model = row.model
            var content = cell.defaultContentConfiguration()
            content.text = model.name
            content.secondaryText = model.id
            content.secondaryTextProperties.color = Theme.Color.tertiaryLabel
            content.secondaryTextProperties.font = Theme.Font.mono(11)
            cell.contentConfiguration = content
            let isSelected =
                self?.selected?.modelID == model.id && self?.selected?.providerID == model.providerID
            cell.accessories = isSelected ? [.checkmark()] : []
        }

        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            guard let self else { return }
            var content = UIListContentConfiguration.groupedHeader()
            let group = self.dataSource.snapshot().sectionIdentifiers[indexPath.section]
            let count = self.dataSource.snapshot().numberOfItems(inSection: group)
            content.text = "\(group.name.uppercased())  ·  \(count)"
            view.contentConfiguration = content
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
            collectionView, indexPath, row in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: row)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
    }

    private func applySnapshot() {
        let filtered = query.isEmpty
            ? allModels
            : allModels.filter {
                $0.name.localizedCaseInsensitiveContains(query)
                    || $0.id.localizedCaseInsensitiveContains(query)
                    || $0.providerID.localizedCaseInsensitiveContains(query)
            }
        var snapshot = NSDiffableDataSourceSnapshot<ProviderGroup, Row>()
        if query.isEmpty {
            let recents = RecentModelsStore.all().compactMap { selection in
                allModels.first {
                    $0.id == selection.modelID && $0.providerID == selection.providerID
                }
            }
            if !recents.isEmpty {
                let group = ProviderGroup(id: "·recent", name: "Recent")
                snapshot.appendSections([group])
                snapshot.appendItems(recents.map { Row(model: $0, recent: true) }, toSection: group)
            }
        }
        var seen: [String: ProviderGroup] = [:]
        for model in filtered {
            let group = seen[model.providerID]
                ?? ProviderGroup(id: model.providerID, name: model.providerID)
            if seen[model.providerID] == nil {
                seen[model.providerID] = group
                snapshot.appendSections([group])
            }
            snapshot.appendItems([Row(model: model, recent: false)], toSection: group)
        }
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    @objc private func close() { dismiss(animated: true) }
}

extension ModelPickerViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let row = dataSource.itemIdentifier(for: indexPath) else { return }
        Theme.Haptics.success()
        onSelect(row.model.selection)
        dismiss(animated: true)
    }
}

extension ModelPickerViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        query = searchController.searchBar.text?.trimmingCharacters(in: .whitespaces) ?? ""
        applySnapshot()
    }
}
