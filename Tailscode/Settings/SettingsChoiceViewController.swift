import UIKit

/// One choice among a few, made the way the iPhone's own Settings makes it: a page of the options
/// with a tick beside the one in force, each taking effect the moment it is tapped, and the words
/// that explain them under the list.
@MainActor
final class SettingsChoiceViewController: UIViewController, UICollectionViewDelegate {
    struct Option: Sendable {
        let title: String
        let detail: String?
    }

    private let options: [Option]
    private let footer: String?
    private let onPick: (Int) -> Void
    private var selected: Int
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, Int>!

    init(
        title: String, options: [Option], selected: Int, footer: String? = nil,
        onPick: @escaping (Int) -> Void
    ) {
        self.options = options
        self.selected = selected
        self.footer = footer
        self.onPick = onPick
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.groupedBackground
        navigationItem.largeTitleDisplayMode = .never
        var config = UICollectionLayoutListConfiguration.themed(.insetGrouped)
        config.footerMode = footer == nil ? .none : .supplementary
        collectionView = UICollectionView(
            frame: view.bounds,
            collectionViewLayout: UICollectionViewCompositionalLayout.readableList(using: config))
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        view.addSubview(collectionView)

        let cell = UICollectionView.CellRegistration<SurfaceListCell, Int> { [weak self] cell, _, index in
            self?.configure(cell, index)
        }
        let footerRegistration = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] view, _, _ in
            var content = UIListContentConfiguration.footer()
            content.text = self?.footer
            view.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
            collectionView, indexPath, index in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: index)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(
                using: footerRegistration, for: indexPath)
        }
        var snapshot = NSDiffableDataSourceSnapshot<Int, Int>()
        snapshot.appendSections([0])
        snapshot.appendItems(Array(options.indices))
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func configure(_ cell: SurfaceListCell, _ index: Int) {
        let option = options[index]
        var content = option.detail == nil ? UIListContentConfiguration.cell() : .subtitleCell()
        content.text = option.title
        content.secondaryText = option.detail
        content.secondaryTextProperties.color = Theme.Color.secondaryLabel
        content.textToSecondaryTextVerticalPadding = 3
        cell.contentConfiguration = content
        cell.accessories =
            index == selected ? [.checkmark(options: .init(tintColor: Theme.Color.accent))] : []
        cell.accessibilityTraits = index == selected ? [.button, .selected] : [.button]
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let index = dataSource.itemIdentifier(for: indexPath), index != selected else { return }
        let previous = selected
        selected = index
        Theme.Haptics.selection()
        onPick(index)
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems([previous, index])
        dataSource.apply(snapshot, animatingDifferences: false)
    }
}
