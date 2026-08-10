import CodingAgentKit
import TailscodeCore
import UIKit

/// Every model the server offers, from every provider, as one list.
///
/// A catalog is not a menu. Two hundred rows, each repeating the same provider key under a name,
/// is a thing to scroll past rather than choose from — so the sections are model families, the
/// provider is a fact on the row beside the id, and the same model reached through two gateways is
/// one row that says so and opens onto both. None of that is decided here: `ModelChooser` in the
/// Kit folds, ranks and walks the catalog, and this draws its answer.
@MainActor
final class ModelPickerViewController: UIViewController {
    private let onSelect: (ModelPick) -> Void
    private var chooser: ModelChooser

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<String, String>!
    private let search = UISearchController(searchResultsController: nil)
    private var didScrollToSelected = false
    private var sectionIDs: [String] = []
    private var rowsByID: [String: ModelChooserRow] = [:]

    init(
        sources: [ModelSource], selected: ModelSelection?, quotas: [UsageQuota] = [],
        onSelect: @escaping (ModelPick) -> Void
    ) {
        self.chooser = ModelChooser(sources: sources, selected: selected, quotas: quotas)
        self.onSelect = onSelect
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Model")
        view.backgroundColor = Theme.Color.groupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close, target: self, action: #selector(close))
        configureSearch()
        configureCollectionView()
        applySnapshot()
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        scrollToSelected()
    }

    private func scrollToSelected() {
        guard !didScrollToSelected, let focused = chooser.focused, focused.isAuto == false else {
            return
        }
        didScrollToSelected = true
        guard let indexPath = dataSource.indexPath(for: focused.id) else { return }
        collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)
    }

    private func configureSearch() {
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = String(localized: "Search models, providers, ids")
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
    }

    private func row(for id: String) -> ModelChooserRow? { rowsByID[id] }

    /// One list configuration lays out every section the same way, so a footer asked for once — the
    /// sentence under the last group that explains the grouping — is asked for under all of them,
    /// and a section that answers with nothing takes the collection view down with it. The layout is
    /// built a section at a time instead: a heading where a section has one, the footer only at the
    /// end, and the data source then always has a view to hand back.
    private func listSection(
        at index: Int, environment: NSCollectionLayoutEnvironment
    ) -> NSCollectionLayoutSection {
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = sectionTitle(at: index).isEmpty ? .none : .supplementary
        config.footerMode = index == sectionIDs.count - 1 ? .supplementary : .none
        return .list(using: config, layoutEnvironment: environment)
    }

    private func sectionTitle(at index: Int) -> String {
        guard sectionIDs.indices.contains(index) else { return "" }
        let id = sectionIDs[index]
        return chooser.sections.first { $0.id == id }?.title ?? ""
    }

    private func configureCollectionView() {
        let layout = UICollectionViewCompositionalLayout { [weak self] index, environment in
            self?.listSection(at: index, environment: environment)
                ?? .list(
                    using: UICollectionLayoutListConfiguration(appearance: .insetGrouped),
                    layoutEnvironment: environment)
        }
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        view.addSubview(collectionView)

        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, String> {
            [weak self] cell, _, id in
            guard let self, let row = self.row(for: id) else { return }
            var content = cell.defaultContentConfiguration()
            content.attributedText = Self.title(row)
            content.textProperties.font = Theme.Ramp.font(.answer)
            if row.isAuto {
                content.secondaryText = row.detail
                content.secondaryTextProperties.color = Theme.Color.secondaryLabel
                content.image = UIImage(systemName: "wand.and.stars")
                content.imageProperties.tintColor = Theme.Color.accent
            } else {
                content.secondaryText = row.detail
                content.secondaryTextProperties.color = Theme.Color.tertiaryLabel
                content.secondaryTextProperties.font = Theme.Ramp.font(.toolOutput)
            }
            if let wall = row.wall {
                content.textProperties.color = Theme.Color.tertiaryLabel
                cell.accessibilityLabel = "\(row.title). \(QuotaSurface.bannerBody(wall))"
            }
            cell.contentConfiguration = content
            cell.indentationLevel = row.isNested ? 1 : 0
            var accessories: [UICellAccessory] = []
            if let wall = row.wall { accessories.append(Self.wallPill(wall)) }
            accessories += row.facts.map(Self.factAccessory)
            if row.canExpand { accessories.append(self.expandAccessory(row)) }
            if row.isSelected { accessories.append(.checkmark()) }
            cell.accessories = accessories
        }

        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            guard let self,
                let id = self.dataSource.sectionIdentifier(for: indexPath.section),
                let section = self.chooser.sections.first(where: { $0.id == id })
            else { return }
            var content = UIListContentConfiguration.header()
            content.text = section.title.isEmpty ? nil : section.title.uppercased()
            content.secondaryText = section.title.isEmpty ? nil : section.detail
            content.prefersSideBySideTextAndSecondaryText = true
            content.secondaryTextProperties.color = Theme.Color.tertiaryLabel
            view.contentConfiguration = content
        }

        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { view, _, _ in
            var content = UIListContentConfiguration.footer()
            content.text = String(
                localized:
                    "Models are grouped by family, not by provider — one row per model, with every provider that runs it behind the chevron. Local models run on your server's own machine."
            )
            view.contentConfiguration = content
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
            collectionView, indexPath, id in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: id)
        }
        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            guard kind == UICollectionView.elementKindSectionHeader else {
                return collectionView.dequeueConfiguredReusableSupplementary(
                    using: footer, for: indexPath)
            }
            return collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
    }

    /// The name, with the letters the query landed on weighted inside it — the row says why the
    /// ranking put it here.
    private static func title(_ row: ModelChooserRow) -> NSAttributedString {
        let text = NSMutableAttributedString(string: row.title)
        guard !row.highlight.isEmpty else { return text }
        let characters = Array(row.title)
        for offset in row.highlight where offset < characters.count {
            let start = String(characters[0..<offset]).utf16.count
            let length = String(characters[offset]).utf16.count
            text.addAttributes(
                [
                    .foregroundColor: Theme.Color.accent,
                    .font: Theme.Ramp.font(.headline),
                ], range: NSRange(location: start, length: length))
        }
        return text
    }

    private static func factAccessory(_ fact: ModelFact) -> UICellAccessory {
        switch fact {
        case .local, .providers, .server:
            return pill(fact)
        default:
            let image = UIImageView(
                image: UIImage(
                    systemName: fact.symbol,
                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 12, weight: .medium)))
            image.tintColor = Theme.Color.tertiaryLabel
            image.accessibilityLabel = fact.label
            return .customView(configuration: .init(customView: image, placement: .trailing()))
        }
    }

    private static func pill(_ fact: ModelFact) -> UICellAccessory {
        let tint: UIColor = {
            if case .local = fact { return Theme.Color.accent }
            if case .server = fact { return Theme.Color.warning }
            return Theme.Color.secondaryLabel
        }()
        return pill(text: fact.tag.uppercased(), tint: tint, label: fact.label, minimum: 46)
    }

    /// What ran out and when it comes back, in the danger register. The row is still there to be
    /// picked — a window resets — so this is a mark rather than a barrier.
    private static func wallPill(_ wall: QuotaExhaustion) -> UICellAccessory {
        pill(
            text: QuotaSurface.rowMark(wall).uppercased(), tint: Theme.Color.danger,
            label: QuotaSurface.bannerBody(wall), minimum: 0)
    }

    private static func pill(
        text: String, tint: UIColor, label accessibility: String, minimum: CGFloat
    ) -> UICellAccessory {
        let label = UILabel()
        label.text = text
        label.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        label.textColor = tint
        label.textAlignment = .center
        label.accessibilityLabel = accessibility
        label.sizeToFit()
        let padH: CGFloat = 6
        let padV: CGFloat = 3
        let width = max(minimum, label.bounds.width + padH * 2)
        let pill = UIView(
            frame: CGRect(x: 0, y: 0, width: width, height: label.bounds.height + padV * 2))
        label.frame = CGRect(x: padH, y: padV, width: width - padH * 2, height: label.bounds.height)
        pill.addSubview(label)
        pill.backgroundColor = tint.withAlphaComponent(0.12)
        pill.layer.cornerRadius = 5
        pill.layer.cornerCurve = .continuous
        return .customView(
            configuration: .init(customView: pill, placement: .trailing(), maintainsFixedSize: true))
    }

    /// The chevron opens the row onto the other providers that run the same model, in place —
    /// picking the row itself still picks the model, through whichever provider leads.
    private func expandAccessory(_ row: ModelChooserRow) -> UICellAccessory {
        let button = UIButton(type: .system)
        let symbol = row.isExpanded ? "chevron.down" : "chevron.right"
        button.setImage(
            UIImage(
                systemName: symbol,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold)),
            for: .normal)
        button.tintColor = Theme.Color.secondaryLabel
        button.accessibilityLabel = String(localized: "The other providers that run it")
        let id = row.id
        let expanded = row.isExpanded
        button.addAction(
            UIAction { [weak self] _ in
                guard let self, let index = self.chooser.rows.firstIndex(where: { $0.id == id })
                else { return }
                self.chooser.focus(index)
                _ = self.chooser.setExpanded(!expanded, at: index)
                Theme.Haptics.selection()
                self.applySnapshot()
            }, for: .touchUpInside)
        return .customView(configuration: .init(customView: button, placement: .trailing()))
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<String, String>()
        rowsByID.removeAll(keepingCapacity: true)
        for section in chooser.sections {
            snapshot.appendSections([section.id])
            snapshot.appendItems(section.rows.map(\.id), toSection: section.id)
            for row in section.rows { rowsByID[row.id] = row }
        }
        sectionIDs = chooser.sections.map(\.id)
        dataSource.apply(snapshot, animatingDifferences: false)
        if let empty = chooser.emptyResult {
            var config = UIContentUnavailableConfiguration.search()
            config.text = empty
            contentUnavailableConfiguration = config
        } else {
            contentUnavailableConfiguration = nil
        }
    }

    @objc private func close() { dismiss(animated: true) }

    #if DEBUG
        func tourSearch(_ text: String) {
            search.isActive = true
            search.searchBar.text = text
            updateSearchResults(for: search)
        }

        func tourSelect(matching modelID: String) {
            guard
                let row = chooser.rows.first(where: { row in
                    if case .candidate(let candidate) = row.kind {
                        return candidate.offers.contains { $0.model.id == modelID }
                    }
                    return false
                })
            else { return }
            onSelect(row.pick)
            dismiss(animated: true)
        }
    #endif
}

extension ModelPickerViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath), let row = row(for: id) else {
            return
        }
        Theme.Haptics.success()
        onSelect(row.pick)
        dismiss(animated: true)
    }
}

extension ModelPickerViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        chooser.search(searchController.searchBar.text ?? "")
        applySnapshot()
    }
}
