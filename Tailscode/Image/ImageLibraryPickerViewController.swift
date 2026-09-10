import TailscodeCore
import UIKit

/// The machine's gallery as a picker: the same tiles, one tap to choose. Opened from the reference
/// chip's "From the Library", where the whole shelf is worth having in front of you rather than a
/// row of thumbnails under a keyboard.
@MainActor
final class ImageLibraryPickerViewController: UIViewController {
    private let library: ImageLibrary
    private let onPick: (ImageGenLibraryItem) -> Void
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, String>!

    init(library: ImageLibrary, onPick: @escaping (ImageGenLibraryItem) -> Void) {
        self.library = library
        self.onPick = onPick
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = ImageGenLibraryWords.heading(machine: library.machine)
        view.backgroundColor = Theme.Color.groupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .cancel,
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        let layout = UICollectionViewCompositionalLayout { _, environment in
            ImageStudioLayout.grid(environment: environment)
        }
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        let tile = UICollectionView.CellRegistration<ImageTileCell, String> { [weak self] cell, _, id in
            guard let self, let item = self.library.item(named: id) else { return }
            cell.apply(item, library: self.library, onStage: false)
        }
        dataSource = UICollectionViewDiffableDataSource<Int, String>(collectionView: collectionView) {
            view, indexPath, id in
            view.dequeueConfiguredReusableCell(using: tile, for: indexPath, item: id)
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(apply), name: ImageLibrary.didChange, object: nil)
        apply()
    }

    @objc private func apply() {
        var snapshot = NSDiffableDataSourceSnapshot<Int, String>()
        snapshot.appendSections([0])
        snapshot.appendItems(library.items.map(\.id))
        dataSource.apply(snapshot, animatingDifferences: true)
    }
}

extension ImageLibraryPickerViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard let id = dataSource.itemIdentifier(for: indexPath), let item = library.item(named: id)
        else { return }
        Theme.Haptics.selection()
        dismiss(animated: true) { [onPick] in onPick(item) }
    }
}

/// The one grid every shelf of tiles is laid out on: three across on a phone, more as the width
/// allows, square, two points apart, inside the readable column on a wide window.
@MainActor
enum ImageStudioLayout {
    static let gap: CGFloat = 2

    static func columns(for width: CGFloat) -> Int {
        max(3, min(6, Int(width / 128)))
    }

    static func grid(environment: NSCollectionLayoutEnvironment, header: Bool = false)
        -> NSCollectionLayoutSection
    {
        let columns = columns(for: environment.container.effectiveContentSize.width)
        let item = NSCollectionLayoutItem(
            layoutSize: NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1 / CGFloat(columns)),
                heightDimension: .fractionalHeight(1)))
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1),
                heightDimension: .fractionalWidth(1 / CGFloat(columns))),
            repeatingSubitem: item, count: columns)
        group.interItemSpacing = .fixed(gap)
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = gap
        section.contentInsets = NSDirectionalEdgeInsets(
            top: 0, leading: Theme.Spacing.m, bottom: Theme.Spacing.l, trailing: Theme.Spacing.m)
        if environment.traitCollection.horizontalSizeClass == .regular {
            section.contentInsetsReference = .readableContent
        }
        if header {
            let size = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1), heightDimension: .estimated(64))
            section.boundarySupplementaryItems = [
                NSCollectionLayoutBoundarySupplementaryItem(
                    layoutSize: size, elementKind: UICollectionView.elementKindSectionHeader,
                    alignment: .top)
            ]
        }
        return section
    }

    /// A stack of full-width rows sized by their content — the stage, the caption, the verbs.
    static func rows(environment: NSCollectionLayoutEnvironment, header: Bool = false)
        -> NSCollectionLayoutSection
    {
        let size = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1), heightDimension: .estimated(80))
        let item = NSCollectionLayoutItem(layoutSize: size)
        let group = NSCollectionLayoutGroup.vertical(layoutSize: size, subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        if environment.traitCollection.horizontalSizeClass == .regular {
            section.contentInsetsReference = .readableContent
        }
        if header {
            let headerSize = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1), heightDimension: .estimated(64))
            section.boundarySupplementaryItems = [
                NSCollectionLayoutBoundarySupplementaryItem(
                    layoutSize: headerSize, elementKind: UICollectionView.elementKindSectionHeader,
                    alignment: .top)
            ]
        }
        return section
    }
}
