import TailscodeCore
import UIKit

/// The Style sheet of the Agents Watch wall: every setting of `WallStyle` as a row. A change is
/// saved the moment it is made and the walls redraw underneath the sheet; the rows follow the
/// store, so a style changed anywhere else shows here without the list being rebuilt.
@MainActor
final class WatchStyleViewController: UIViewController {
    var onClose: (() -> Void)?

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<WatchStyleSection, WatchStyleRow>!
    private var style: WallStyle

    init() {
        style = WatchStyleStore.current
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    @discardableResult
    static func present(from presenter: UIViewController) -> WatchStyleViewController {
        let controller = WatchStyleViewController()
        let navigation = UINavigationController(rootViewController: controller)
        if presenter.traitCollection.userInterfaceIdiom == .phone {
            navigation.modalPresentationStyle = .pageSheet
            navigation.sheetPresentationController?.detents = [.medium(), .large()]
            navigation.sheetPresentationController?.prefersGrabberVisible = true
        } else {
            navigation.modalPresentationStyle = .formSheet
        }
        presenter.present(navigation, animated: true)
        return controller
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Style")
        view.backgroundColor = Theme.Color.groupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done,
            primaryAction: UIAction { [weak self] _ in
                self?.dismiss(animated: true)
            })
        configureCollectionView()
        configureDataSource()
        applyInitialSnapshot()
        NotificationCenter.default.addObserver(
            self, selector: #selector(styleDidChange), name: WatchStyleStore.didChange, object: nil)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        guard isBeingDismissed || navigationController?.isBeingDismissed == true else { return }
        onClose?()
    }

    private func configureCollectionView() {
        let layout = UICollectionViewCompositionalLayout.readableList { index in
            var config = UICollectionLayoutListConfiguration.themed(.insetGrouped)
            let titled = WatchStyleSection(rawValue: index)?.title != nil
            config.headerMode = titled ? .supplementary : .none
            return config
        }
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.allowsSelection = false
        view.addSubview(collectionView)
    }

    private func configureDataSource() {
        let segmented = UICollectionView.CellRegistration<WatchStyleSegmentedCell, WatchStyleRow> {
            [weak self] cell, _, row in
            guard let self else { return }
            cell.update(row: row, style: self.style) { [weak self] index in
                self?.choose(row, at: index)
            }
        }
        let menu = UICollectionView.CellRegistration<WatchStyleMenuCell, WatchStyleRow> {
            [weak self] cell, _, row in
            guard let self else { return }
            cell.update(row: row, style: self.style) { [weak self] index in
                self?.choose(row, at: index)
            }
        }
        let toggle = UICollectionView.CellRegistration<WatchStyleToggleCell, WatchStyleRow> {
            [weak self] cell, _, row in
            guard let self else { return }
            cell.update(row: row, style: self.style) { [weak self] isOn in
                self?.set(row, isOn: isOn)
            }
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            guard let self, let section = self.dataSource.sectionIdentifier(for: indexPath.section)
            else { return }
            var content = UIListContentConfiguration.header()
            content.text = section.title
            view.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
            collectionView, indexPath, row in
            switch row.control {
            case .segmented:
                return collectionView.dequeueConfiguredReusableCell(
                    using: segmented, for: indexPath, item: row)
            case .menu:
                return collectionView.dequeueConfiguredReusableCell(
                    using: menu, for: indexPath, item: row)
            case .toggle:
                return collectionView.dequeueConfiguredReusableCell(
                    using: toggle, for: indexPath, item: row)
            }
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
    }

    private func applyInitialSnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<WatchStyleSection, WatchStyleRow>()
        for section in WatchStyleSection.allCases {
            snapshot.appendSections([section])
            snapshot.appendItems(section.rows, toSection: section)
        }
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// Rows are reconfigured in place and their controls are only set when they differ, so the
    /// control a finger is on is never replaced or moved by the change it just made.
    @objc private func styleDidChange() {
        let fresh = WatchStyleStore.current
        guard fresh != style else { return }
        style = fresh
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func choose(_ row: WatchStyleRow, at index: Int) {
        let current = WatchStyleStore.current
        let choices = row.choices(for: current)
        guard choices.indices.contains(index) else { return }
        Theme.Haptics.selection()
        WatchStyleStore.save(choices[index].result(current))
    }

    private func set(_ row: WatchStyleRow, isOn: Bool) {
        guard let flag = row.flag else { return }
        Theme.Haptics.selection()
        WatchStyleStore.save(WatchStyleStore.current.with { $0[keyPath: flag] = isOn })
    }
}
