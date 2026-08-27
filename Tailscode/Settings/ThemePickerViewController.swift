import TailscodeCore
import UIKit
import WidgetKit

/// A theme is picked by looking at it, not by reading its name.
///
/// Every row is drawn in the palette it offers — its own canvas, its own two text registers, its
/// own signals in the order a transcript uses them — so the list is fourteen small screenshots of
/// the app rather than fourteen words. Each row shows the face the app would actually be wearing
/// right now, because a swatch drawn in a theme's night colours is a lie to someone reading in
/// daylight.
///
/// The choice applies the moment it is made, under the picker, which is the only honest way to
/// judge one: the navigation bar this list sits under is Liquid Glass, and glass takes its colour
/// from the content behind it — so the chrome changes as you scroll past the row you are
/// considering, which is exactly the thing being decided.
@MainActor
final class ThemePickerViewController: UIViewController {
    private enum Section: Hashable {
        case appearance
        case themes
    }

    private enum Item: Hashable {
        case appearance(ThemeAppearance)
        case system
        case theme(String)
    }

    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Theme")
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = Theme.Color.groupedBackground
        buildCollectionView()
        buildDataSource()
        apply()
        NotificationCenter.default.addObserver(
            self, selector: #selector(refreshRows), name: ThemeSelection.didChange, object: nil)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeIdentityTrait.self]) {
            (controller: ThemePickerViewController, _) in controller.refreshRows()
        }
    }

    private func buildCollectionView() {
        var layout = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        layout.headerMode = .supplementary
        collectionView = UICollectionView(
            frame: .zero, collectionViewLayout: UICollectionViewCompositionalLayout.readableList(using: layout))
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = Theme.Color.groupedBackground
        collectionView.delegate = self
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func buildDataSource() {
        let appearanceCell = UICollectionView.CellRegistration<
            UICollectionViewListCell, ThemeAppearance
        > { cell, _, appearance in
            var content = cell.defaultContentConfiguration()
            content.text = appearance.title
            content.textProperties.color = Theme.Color.label
            content.image = UIImage(systemName: Self.symbol(for: appearance))
            content.imageProperties.tintColor = Theme.Color.accent
            cell.contentConfiguration = content
            cell.accessories =
                ThemeSelection.appearance == appearance
                ? [.checkmark(options: .init(tintColor: Theme.Color.accent))] : []
            var background = UIBackgroundConfiguration.listGroupedCell()
            background.backgroundColor = Theme.Color.groupedSurface
            cell.backgroundConfiguration = background
        }

        let themeCell = UICollectionView.CellRegistration<ThemeSwatchCell, Item> {
            [weak self] cell, _, item in
            guard let self else { return }
            switch item {
            case .system:
                cell.showSystem(chosen: ThemeSelection.usesSystemPalette)
            case .theme(let id):
                cell.show(
                    AppTheme.named(id), palette: self.previewPalette(for: id),
                    chosen: ThemeSelection.themeID == id)
            case .appearance:
                break
            }
        }

        dataSource = UICollectionViewDiffableDataSource<Section, Item>(
            collectionView: collectionView
        ) { collection, indexPath, item in
            if case .appearance(let appearance) = item {
                return collection.dequeueConfiguredReusableCell(
                    using: appearanceCell, for: indexPath, item: appearance)
            }
            return collection.dequeueConfiguredReusableCell(
                using: themeCell, for: indexPath, item: item)
        }

        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            var content = view.defaultContentConfiguration()
            content.text = self?.dataSource.sectionIdentifier(for: indexPath.section) == .appearance
                ? String(localized: "Light or dark") : String(localized: "Themes")
            content.textProperties.color = Theme.Color.secondaryLabel
            view.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { collection, kind, indexPath in
            collection.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
    }

    private static func symbol(for appearance: ThemeAppearance) -> String {
        switch appearance {
        case .system: return "iphone"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }

    /// The face this theme would wear right now — the pin if there is one, otherwise whatever the
    /// device is doing — so every swatch on screen is a preview and not a brochure.
    private func previewPalette(for id: String) -> Palette {
        let dark =
            ThemeSelection.appearance.pinnedDark ?? (traitCollection.userInterfaceStyle == .dark)
        return ThemeSelection.palette(themeID: id, dark: dark)
    }

    private func apply(animated: Bool = false) {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.appearance, .themes])
        snapshot.appendItems(ThemeAppearance.allCases.map(Item.appearance), toSection: .appearance)
        snapshot.appendItems([.system] + AppTheme.all.map { Item.theme($0.id) }, toSection: .themes)
        dataSource.apply(snapshot, animatingDifferences: animated)
    }

    /// Every row restates itself: the checkmarks moved, and each swatch is drawn in the face the
    /// app is wearing now rather than the one it was wearing when the list was built.
    @objc private func refreshRows() {
        var snapshot = dataSource.snapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
    override init(nibName: String?, bundle: Bundle?) { super.init(nibName: nibName, bundle: bundle) }
    convenience init() { self.init(nibName: nil, bundle: nil) }
}

extension ThemePickerViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        switch item {
        case .appearance(let appearance):
            ThemeSelection.setAppearance(appearance)
        case .system:
            ThemeSelection.setThemeID(ThemeSelection.systemID)
        case .theme(let id):
            ThemeSelection.setThemeID(id)
        }
        Theme.Chrome.apply()
        refreshRows()
        Theme.Haptics.selection()
        WidgetCenter.shared.reloadTimelines(ofKind: UsageWidgetStore.kind)
    }
}

/// One theme, drawn in itself: the canvas it would set the transcript on, a line of its primary
/// text and a line of its secondary, and its five signals in a row. The card is the swatch — the
/// cell's own background stays the app's, so a theme is seen *against* the app rather than
/// replacing it, which is what a row in a list has to do to stay a row in a list.
@MainActor
final class ThemeSwatchCell: UICollectionViewListCell {
    private let card = UIView()
    private let nameLabel = UILabel()
    private let blurbLabel = UILabel()
    private let signals = UIStackView()
    private let check = UIImageView(image: UIImage(systemName: "checkmark.circle.fill"))

    override init(frame: CGRect) {
        super.init(frame: frame)
        build()
    }

    private func build() {
        card.translatesAutoresizingMaskIntoConstraints = false
        card.layer.cornerRadius = Theme.Radius.card
        card.layer.cornerCurve = .continuous
        card.layer.borderWidth = 1
        card.clipsToBounds = true
        contentView.addSubview(card)

        nameLabel.font = Theme.Ramp.font(.cardTitle)
        nameLabel.numberOfLines = 1
        blurbLabel.font = Theme.Ramp.font(.panelDetail)
        blurbLabel.numberOfLines = 2

        signals.axis = .horizontal
        signals.spacing = Theme.Spacing.xs
        signals.alignment = .center

        check.contentMode = .scaleAspectFit
        check.setContentHuggingPriority(.required, for: .horizontal)

        let heading = UIStackView(arrangedSubviews: [nameLabel, check])
        heading.axis = .horizontal
        heading.spacing = Theme.Spacing.s
        heading.alignment = .firstBaseline

        let stack = UIStackView(arrangedSubviews: [heading, blurbLabel, signals])
        stack.axis = .vertical
        stack.spacing = Theme.Spacing.xs
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        let inset = Theme.Spacing.m
        NSLayoutConstraint.activate([
            card.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Spacing.s),
            card.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor, constant: -Theme.Spacing.s),
            card.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: inset),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -inset),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -inset),
        ])
        var background = UIBackgroundConfiguration.clear()
        background.backgroundColor = .clear
        backgroundConfiguration = background
    }

    func show(_ theme: AppTheme, palette: Palette, chosen: Bool) {
        card.backgroundColor = UIColor(hex: palette.canvas)
        card.layer.borderColor =
            (chosen ? UIColor(hex: palette.accent) : UIColor(hex: palette.rule))?.cgColor
        card.layer.borderWidth = chosen ? 2 : 1
        nameLabel.text = theme.name
        nameLabel.textColor = UIColor(hex: palette.text)
        blurbLabel.text = theme.blurb
        blurbLabel.textColor = UIColor(hex: palette.textDim)
        check.tintColor = UIColor(hex: palette.accent)
        check.isHidden = !chosen
        setSignals(
            [palette.accent, palette.warn, palette.danger, palette.info, palette.special],
            on: palette.canvasRaised)
        accessibilityLabel = "\(theme.name). \(theme.blurb)"
        accessibilityTraits = chosen ? [.button, .selected] : .button
        isAccessibilityElement = true
    }

    /// The system row cannot draw itself in a palette, because its whole claim is that it has
    /// none: it is the app's own tokens, which is what the rest of the list is being compared to.
    func showSystem(chosen: Bool) {
        card.backgroundColor = Theme.Color.groupedSurface
        card.layer.borderColor =
            (chosen ? Theme.Color.accent : Theme.Color.separator).cgColor
        card.layer.borderWidth = chosen ? 2 : 1
        nameLabel.text = String(localized: "System")
        nameLabel.textColor = Theme.Color.label
        blurbLabel.text = String(localized: "iOS's own colours, under Liquid Glass")
        blurbLabel.textColor = Theme.Color.secondaryLabel
        check.tintColor = Theme.Color.accent
        check.isHidden = !chosen
        signals.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for colour in [
            Theme.Color.accent, Theme.Color.warning, Theme.Color.danger, Theme.Color.info,
            Theme.Color.special,
        ] {
            signals.addArrangedSubview(dot(colour, on: Theme.Color.groupedSurface))
        }
        accessibilityLabel = String(localized: "System. iOS's own colours, under Liquid Glass")
        accessibilityTraits = chosen ? [.button, .selected] : .button
        isAccessibilityElement = true
    }

    private func setSignals(_ colours: [String], on surface: String) {
        signals.arrangedSubviews.forEach { $0.removeFromSuperview() }
        let base = UIColor(hex: surface) ?? .clear
        for hex in colours {
            guard let colour = UIColor(hex: hex) else { continue }
            signals.addArrangedSubview(dot(colour, on: base))
        }
    }

    private func dot(_ colour: UIColor, on surface: UIColor) -> UIView {
        let side: CGFloat = 14
        let view = UIView()
        view.backgroundColor = colour
        view.layer.cornerRadius = side / 2
        view.layer.borderWidth = 1
        view.layer.borderColor = surface.cgColor
        view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            view.widthAnchor.constraint(equalToConstant: side),
            view.heightAnchor.constraint(equalToConstant: side),
        ])
        return view
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}
