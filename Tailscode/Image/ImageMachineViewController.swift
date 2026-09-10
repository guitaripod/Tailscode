import TailscodeCore
import UIKit

/// Everything the picture machine has said about itself, on one sheet.
///
/// Where it is, what it runs, when it was last asked, what it is doing now, and — file by file —
/// which of the six model files it holds, because "two files missing" is a count and a person
/// needs the names to go and fix it. Two things happen here: asking again, and pointing the app at
/// another machine, which is the renderer's own setup because one ComfyUI holds both sets of
/// models. Every word is `ImageGenMachineWords`'; the controller draws rows.
@MainActor
final class ImageMachineViewController: UIViewController {
    private enum Section: Hashable {
        case summary
        case facts
        case models
        case actions
    }

    private enum Item: Hashable {
        case summary
        case fact(String)
        case model(String)
        case check
        case change
        case note
    }

    private let studio = ImageStudio.shared
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!

    override func viewDidLoad() {
        super.viewDidLoad()
        title = studio.endpoint.shortName
        view.backgroundColor = Theme.Color.groupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: ImageGenSurface.dismissTitle,
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        configuration.headerMode = .supplementary
        configuration.backgroundColor = .clear
        collectionView = UICollectionView(
            frame: .zero,
            collectionViewLayout: UICollectionViewCompositionalLayout.readableList(
                using: configuration))
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
        configureDataSource()
        NotificationCenter.default.addObserver(
            self, selector: #selector(changed), name: ImageStudio.didChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(changed), name: ImageGenStore.didChange, object: nil)
        apply(animated: false)
        studio.checkMachine(force: studio.sighting == nil)
    }

    private var sighting: ImageGenSighting? { studio.sighting }

    private func configureDataSource() {
        let summary = UICollectionView.CellRegistration<UICollectionViewListCell, Item> {
            [weak self] cell, _, _ in
            guard let self else { return }
            var content = UIListContentConfiguration.subtitleCell()
            content.text = ImageGenMachineWords.summary(self.sighting)
            content.secondaryText = self.studio.door.inherited ? ImageGenMachineWords.inherited : nil
            content.textProperties.font = Theme.Ramp.font(.rowTitleStrong)
            content.secondaryTextProperties.font = Theme.Ramp.font(.rowDetail)
            content.secondaryTextProperties.color = Theme.Color.secondaryLabel
            content.textToSecondaryTextVerticalPadding = 4
            let tone = self.studio.door.tone
            content.image = UIImage(
                systemName: tone == nil
                    ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 20, weight: .regular))
            content.imageProperties.tintColor = tone == nil
                ? Theme.Color.success : tone == .attention ? Theme.Color.warning : Theme.Color.tertiaryLabel
            if self.sighting == nil { content.imageProperties.tintColor = Theme.Color.tertiaryLabel }
            cell.contentConfiguration = content
            cell.backgroundConfiguration = Self.surface()
        }
        let fact = UICollectionView.CellRegistration<UICollectionViewListCell, Item> {
            [weak self] cell, _, item in
            guard let self, case .fact(let key) = item else { return }
            var content = UIListContentConfiguration.valueCell()
            let (label, value) = self.fact(key)
            content.text = label
            content.secondaryText = value
            content.textProperties.font = Theme.Ramp.font(.rowTitle)
            content.secondaryTextProperties.font = Theme.Ramp.font(.rowDetail)
            content.secondaryTextProperties.color = Theme.Color.secondaryLabel
            cell.contentConfiguration = content
            cell.backgroundConfiguration = Self.surface()
            cell.accessibilityLabel = "\(label), \(value)"
        }
        let model = UICollectionView.CellRegistration<UICollectionViewListCell, Item> {
            [weak self] cell, _, item in
            guard let self, case .model(let path) = item,
                let file = ImageGenModelFile.named(path)
            else { return }
            var content = UIListContentConfiguration.subtitleCell()
            content.text = file.role
            content.secondaryText = file.name
            content.textProperties.font = Theme.Ramp.font(.rowTitle)
            content.secondaryTextProperties.font = Theme.Ramp.font(.rowMeta)
            content.secondaryTextProperties.color = Theme.Color.tertiaryLabel
            content.secondaryTextProperties.lineBreakMode = .byTruncatingMiddle
            cell.contentConfiguration = content
            cell.backgroundConfiguration = Self.surface()
            let held = self.sighting?.holds(file)
            let mark = UIImageView(
                image: UIImage(
                    systemName: held == true
                        ? "checkmark.circle.fill" : held == false ? "xmark.circle.fill" : "questionmark.circle",
                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 17, weight: .regular)))
            mark.tintColor = held == true
                ? Theme.Color.success : held == false ? Theme.Color.danger : Theme.Color.tertiaryLabel
            cell.accessories = [.customView(configuration: .init(customView: mark, placement: .trailing()))]
            let state = held == true
                ? ImageGenMachineWords.present
                : held == false ? ImageGenMachineWords.missing : ImageGenMachineWords.unknown
            cell.accessibilityLabel = "\(file.role), \(file.name), \(state)"
        }
        let action = UICollectionView.CellRegistration<UICollectionViewListCell, Item> {
            [weak self] cell, _, item in
            guard let self else { return }
            var content = UIListContentConfiguration.cell()
            switch item {
            case .check:
                content.text = self.studio.checking
                    ? ImageGenMachineWords.checking : ImageGenMachineWords.checkAgain
                content.image = UIImage(systemName: "arrow.clockwise")
            case .change:
                content.text = ImageGenMachineWords.change
                content.image = UIImage(systemName: "desktopcomputer")
            default:
                break
            }
            content.textProperties.font = Theme.Ramp.font(.rowTitle)
            content.textProperties.color = self.studio.checking && item == .check
                ? Theme.Color.tertiaryLabel : Theme.Color.accent
            content.imageProperties.tintColor = content.textProperties.color
            cell.contentConfiguration = content
            cell.backgroundConfiguration = Self.surface()
            cell.accessibilityTraits = .button
        }
        let note = UICollectionView.CellRegistration<ForgeNoteCell, Item> { cell, _, _ in
            cell.apply(ImageGenSurface.subtitle, tone: .quiet)
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            guard let self, let section = self.dataSource.sectionIdentifier(for: indexPath.section)
            else { return }
            var content = UIListContentConfiguration.header()
            switch section {
            case .summary: content.text = nil
            case .facts: content.text = ImageGenMachineWords.title
            case .models: content.text = ImageGenMachineWords.modelsTitle
            case .actions: content.text = nil
            }
            view.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource<Section, Item>(collectionView: collectionView) {
            view, indexPath, item in
            switch item {
            case .summary: return view.dequeueConfiguredReusableCell(using: summary, for: indexPath, item: item)
            case .fact: return view.dequeueConfiguredReusableCell(using: fact, for: indexPath, item: item)
            case .model: return view.dequeueConfiguredReusableCell(using: model, for: indexPath, item: item)
            case .check, .change:
                return view.dequeueConfiguredReusableCell(using: action, for: indexPath, item: item)
            case .note: return view.dequeueConfiguredReusableCell(using: note, for: indexPath, item: item)
            }
        }
        dataSource.supplementaryViewProvider = { view, kind, indexPath in
            view.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
    }

    private static func surface() -> UIBackgroundConfiguration {
        var background = UIBackgroundConfiguration.listCell()
        background.backgroundColor = Theme.Color.groupedSurface
        return background
    }

    private func fact(_ key: String) -> (String, String) {
        switch key {
        case "address":
            return (ImageGenMachineWords.addressLabel, studio.endpoint.displayHost)
        case "version":
            return (ImageGenMachineWords.versionLabel, sighting?.version ?? ImageGenMachineWords.unknown)
        case "checked":
            guard let at = sighting?.at else {
                return (ImageGenMachineWords.checkedLabel, ImageGenMachineWords.neverChecked)
            }
            return (ImageGenMachineWords.checkedLabel, ImageGenLibraryWords.ago(at))
        case "queue":
            guard let running = sighting?.running else {
                return (ImageGenMachineWords.queueLabel, ImageGenMachineWords.unknown)
            }
            return (ImageGenMachineWords.queueLabel, ImageGenMachineWords.queue(running: running))
        default:
            return ("", "")
        }
    }

    @objc private func changed() {
        title = studio.endpoint.shortName
        apply(animated: true)
    }

    private func apply(animated: Bool) {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.summary, .facts, .models, .actions])
        snapshot.appendItems([.summary], toSection: .summary)
        snapshot.appendItems(
            ["address", "version", "checked", "queue"].map(Item.fact), toSection: .facts)
        snapshot.appendItems(ImageGenModelFile.all.map { .model($0.path) }, toSection: .models)
        snapshot.appendItems([.check, .change, .note], toSection: .actions)
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: animated)
    }
}

extension ImageMachineViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .check:
            guard !studio.checking else { return }
            Theme.Haptics.tap()
            studio.checkMachine(force: true)
        case .change:
            Theme.Haptics.tap()
            let nav = UINavigationController(rootViewController: ForgeSetupViewController())
            nav.navigationBar.prefersLargeTitles = true
            present(nav, animated: true)
        default:
            break
        }
    }

    func collectionView(_ collectionView: UICollectionView, shouldHighlightItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .check, .change: return true
        default: return false
        }
    }
}
