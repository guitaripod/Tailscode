import TailscodeCore
import UIKit

/// The card behind a tab or a door in the model chooser: what the server is, the state it is in,
/// exactly what is behind it, and what each door means. Every word is Core's (`ChooserBriefing`);
/// this draws headings, lines and footnotes as a grouped list and adds nothing.
final class ChooserBriefingViewController: UIViewController {
    private let briefing: ChooserBriefing
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, Int>!

    init(briefing: ChooserBriefing) {
        self.briefing = briefing
        super.init(nibName: nil, bundle: nil)
        title = briefing.title
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    static func present(_ briefing: ChooserBriefing, from presenter: UIViewController) {
        let card = ChooserBriefingViewController(briefing: briefing)
        let navigation = UINavigationController(rootViewController: card)
        if let sheet = navigation.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        presenter.present(navigation, animated: true)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.background
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .close,
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .supplementary
        config.footerMode = .supplementary
        let layout = UICollectionViewCompositionalLayout.list(using: config)
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.allowsSelection = false
        view.addSubview(collectionView)
        configureDataSource()
    }

    private func configureDataSource() {
        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, Int> {
            [weak self] cell, indexPath, _ in
            guard let self else { return }
            let line = self.briefing.sections[indexPath.section].lines[indexPath.item]
            var content = UIListContentConfiguration.valueCell()
            content.text = line.label
            content.secondaryText = line.value
            content.secondaryTextProperties.color = Theme.Color.secondaryLabel
            content.prefersSideBySideTextAndSecondaryText = line.value.count < 40
            if let symbol = line.symbol {
                content.image = UIImage(systemName: symbol)
                content.imageProperties.tintColor = self.lineTint(indexPath)
                content.imageProperties.preferredSymbolConfiguration = .init(
                    pointSize: 15, weight: .regular)
            }
            cell.contentConfiguration = content
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            guard let self else { return }
            var content = UIListContentConfiguration.groupedHeader()
            if indexPath.section == 0 {
                content.text = self.briefing.subtitle
                content.secondaryText = self.briefing.lead
                content.secondaryTextProperties.color = Theme.Color.secondaryLabel
                content.secondaryTextProperties.numberOfLines = 0
                content.text = self.briefing.subtitle.uppercased()
            } else {
                content.text = self.briefing.sections[indexPath.section].heading.uppercased()
            }
            view.contentConfiguration = content
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] view, _, indexPath in
            guard let self else { return }
            var content = UIListContentConfiguration.groupedFooter()
            let section = self.briefing.sections[indexPath.section]
            content.text =
                indexPath.section == 0
                ? [self.briefing.sections[0].heading.uppercased(), section.footnote]
                    .compactMap { $0 }.joined(separator: " · ")
                : section.footnote
            content.textProperties.numberOfLines = 0
            view.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource<Int, Int>(collectionView: collectionView) {
            collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: item)
        }
        dataSource.supplementaryViewProvider = { collectionView, kind, indexPath in
            kind == UICollectionView.elementKindSectionHeader
                ? collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
                : collectionView.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
        var snapshot = NSDiffableDataSourceSnapshot<Int, Int>()
        for (index, section) in briefing.sections.enumerated() {
            snapshot.appendSections([index])
            snapshot.appendItems(section.lines.indices.map { index * 1000 + $0 }, toSection: index)
        }
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    /// The state line wears the state's own tone; everything else is the quiet register.
    private func lineTint(_ indexPath: IndexPath) -> UIColor {
        guard indexPath.section == 0, indexPath.item == 0, let tone = briefing.tone else {
            return Theme.Color.secondaryLabel
        }
        return Self.colour(tone)
    }

    static func colour(_ tone: ModelMachineState.Tone) -> UIColor {
        switch tone {
        case .live: return Theme.Color.success
        case .quiet: return Theme.Color.tertiaryLabel
        case .danger: return Theme.Color.danger
        case .attention: return Theme.Color.warning
        }
    }
}
