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
        recents: [ModelSelection] = RecentModelsStore.all(),
        onSelect: @escaping (ModelPick) -> Void
    ) {
        self.chooser = ModelChooser(
            sources: sources, selected: selected, recents: recents, quotas: quotas)
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

    /// The search field, and beside it the standing filters. Typing answers "which model"; it is a
    /// poor way to ask for "only what this chat can switch to without moving" or "only what runs on
    /// my own machine", which a fleet makes people ask constantly — so those are a tap that is
    /// always on screen rather than a word somebody has to know to type.
    private func configureSearch() {
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = String(localized: "Search models, providers, ids")
        if chooser.scopes.count > 1 {
            search.searchBar.delegate = self
            search.searchBar.scopeButtonTitles = chooser.scopes.map(\.title)
            search.searchBar.selectedScopeButtonIndex = 0
            search.searchBar.showsScopeBar = true
            search.scopeBarActivation = .manual
        }
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        navigationItem.preferredSearchBarPlacement = .stacked
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
                content.secondaryTextProperties.numberOfLines = 1
                content.secondaryTextProperties.lineBreakMode = .byTruncatingTail
            }
            content.textProperties.numberOfLines = 1
            content.textProperties.lineBreakMode = .byTruncatingTail
            if row.wall != nil { content.textProperties.color = Theme.Color.tertiaryLabel }
            cell.accessibilityLabel = Self.spoken(row)
            cell.contentConfiguration = content
            cell.indentationLevel = row.isNested ? 1 : 0
            var accessories: [UICellAccessory] = []
            if let wall = row.wall { accessories.append(Self.wallPill(wall)) }
            accessories += row.facts.filter { !$0.isCapability }.map(Self.pill)
            let room = cell.traitCollection.horizontalSizeClass == .compact ? 2 : 4
            accessories = Array(accessories.prefix(room))
            if accessories.count < room,
                let marks = Self.capabilityAccessory(
                    row, slots: self.chooser.policy.capabilitySlots)
            {
                accessories.append(marks)
            }
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
        ) { [weak self] view, _, _ in
            var content = UIListContentConfiguration.footer()
            content.text =
                self?.chooser.isNarrowed == true
                ? self?.chooser.summary
                : String(
                    localized:
                        "One row per model, grouped by family. The chevron opens the other providers that run it."
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

    /// The whole row in words. A narrow screen has room for two marks and drops the rest, which is
    /// the right trade for the eye and the wrong one for a reader who cannot see the row at all —
    /// so everything the row knows is spoken whether or not it fitted.
    private static func spoken(_ row: ModelChooserRow) -> String {
        var parts = [row.title]
        if !row.detail.isEmpty { parts.append(row.detail) }
        if let wall = row.wall { parts.append(QuotaSurface.bannerBody(wall)) }
        parts += row.facts.map(\.label)
        if row.isSelected { parts.append(String(localized: "Currently chosen")) }
        return parts.joined(separator: ". ")
    }

    /// What a model reads, as one fixed set of slots rather than a per-row huddle of symbols: a
    /// slot the model lacks is left empty, so the marks line up down the list and a row that reads
    /// less than its neighbours is visible as a gap instead of found by reading.
    private static func capabilityAccessory(
        _ row: ModelChooserRow, slots: [ModelFact]
    ) -> UICellAccessory? {
        guard !slots.isEmpty else { return nil }
        let worn = Set(row.facts.filter(\.isCapability))
        let stack = UIStackView()
        stack.axis = .horizontal
        stack.spacing = 5
        stack.alignment = .center
        var said: [String] = []
        for slot in slots {
            let box = UIImageView()
            box.contentMode = .center
            box.widthAnchor.constraint(equalToConstant: 15).isActive = true
            guard worn.contains(slot) else {
                stack.addArrangedSubview(box)
                continue
            }
            box.image = UIImage(
                systemName: slot.symbol,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .regular))
            box.tintColor = Theme.Color.tertiaryLabel
            said.append(slot.label)
            stack.addArrangedSubview(box)
        }
        stack.isAccessibilityElement = !said.isEmpty
        stack.accessibilityLabel = said.joined(separator: ", ")
        let width = CGFloat(slots.count) * 15 + CGFloat(slots.count - 1) * stack.spacing
        stack.frame = CGRect(x: 0, y: 0, width: width, height: 18)
        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalToConstant: width),
            stack.heightAnchor.constraint(equalToConstant: 18),
        ])
        return .customView(
            configuration: .init(
                customView: stack, placement: .trailing(), maintainsFixedSize: true))
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
        let pill = PillLabel()
        pill.text = text
        pill.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        pill.textColor = tint
        pill.textAlignment = .center
        pill.accessibilityLabel = accessibility
        pill.minimumWidth = minimum
        pill.backgroundColor = tint.withAlphaComponent(0.12)
        pill.layer.cornerRadius = 5
        pill.layer.cornerCurve = .continuous
        pill.setContentCompressionResistancePriority(.required, for: .horizontal)
        pill.setContentHuggingPriority(.required, for: .horizontal)
        pill.fixSize()
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
        guard let empty = chooser.emptyResult else {
            contentUnavailableConfiguration = nil
            return
        }
        var config = UIContentUnavailableConfiguration.search()
        config.text = empty
        if let escape = chooser.emptyEscape {
            var button = UIButton.Configuration.borderless()
            button.title = String(localized: "Clear the filter")
            config.button = button
            config.buttonProperties.primaryAction = UIAction { [weak self] _ in
                guard let self, self.chooser.setScope(escape) else { return }
                self.search.searchBar.selectedScopeButtonIndex =
                    self.chooser.scopes.firstIndex(of: escape) ?? 0
                self.applySnapshot()
            }
        }
        contentUnavailableConfiguration = config
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

/// A pill that measures itself. An accessory laid out from a hand-set frame has no size for the
/// cell to lay out *around*, so two of them on one row were drawn in the same place — which is how
/// a row ended up wearing "used up" and "3 levels" on top of each other. A label with an honest
/// `intrinsicContentSize` is the whole fix.
private final class PillLabel: UILabel {
    var minimumWidth: CGFloat = 0
    private let inset = UIEdgeInsets(top: 3, left: 6, bottom: 3, right: 6)

    override var intrinsicContentSize: CGSize {
        let size = super.intrinsicContentSize
        return CGSize(
            width: max(minimumWidth, size.width + inset.left + inset.right),
            height: size.height + inset.top + inset.bottom)
    }

    override func drawText(in rect: CGRect) {
        super.drawText(in: rect.inset(by: inset))
    }

    /// An accessory is laid out from whichever of the two a cell asks for, and which one it asks
    /// for is not ours to know — so the size is stated both ways.
    func fixSize() {
        let size = intrinsicContentSize
        frame = CGRect(origin: .zero, size: size)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: size.width),
            heightAnchor.constraint(equalToConstant: size.height),
        ])
    }
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

extension ModelPickerViewController: UISearchBarDelegate {
    func searchBar(_ searchBar: UISearchBar, selectedScopeButtonIndexDidChange index: Int) {
        guard chooser.scopes.indices.contains(index),
            chooser.setScope(chooser.scopes[index])
        else { return }
        Theme.Haptics.selection()
        applySnapshot()
    }
}
