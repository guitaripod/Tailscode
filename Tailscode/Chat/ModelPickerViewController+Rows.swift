import TailscodeCore
import UIKit

extension ModelPickerViewController {
    func row(for id: String) -> ModelChooserRow? { rowsByID[id] }

    /// One list configuration lays out every section the same way, so a footer asked for once — the
    /// sentence under the last group that explains the grouping — is asked for under all of them,
    /// and a section that answers with nothing takes the collection view down with it. The layout is
    /// built a section at a time instead: a heading where a section has one, the footer only at the
    /// end, and the data source then always has a view to hand back.
    private func listSection(
        at index: Int, environment: NSCollectionLayoutEnvironment
    ) -> NSCollectionLayoutSection {
        var config = UICollectionLayoutListConfiguration.themed(.insetGrouped)
        config.headerMode = sectionTitle(at: index).isEmpty ? .none : .supplementary
        config.footerMode = index == sectionIDs.count - 1 ? .supplementary : .none
        config.leadingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            self?.pinActions(at: indexPath)
        }
        return .list(using: config, layoutEnvironment: environment)
    }

    private func sectionTitle(at index: Int) -> String {
        guard sectionIDs.indices.contains(index) else { return "" }
        let id = sectionIDs[index]
        return chooser.sections.first { $0.id == id }?.title ?? ""
    }

    func configureCollectionView() {
        let layout = UICollectionViewCompositionalLayout { [weak self] index, environment in
            let section =
                self?.listSection(at: index, environment: environment)
                ?? .list(
                    using: UICollectionLayoutListConfiguration.themed(.insetGrouped),
                    layoutEnvironment: environment)
            if environment.traitCollection.horizontalSizeClass == .regular {
                section.contentInsetsReference = .readableContent
            }
            return section
        }
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        view.addSubview(collectionView)

        let cell = UICollectionView.CellRegistration<SurfaceListCell, String> {
            [weak self] cell, _, id in
            guard let self, let row = self.row(for: id) else { return }
            var content = cell.defaultContentConfiguration()
            content.attributedText = Self.title(row)
            content.textProperties.font = Theme.Ramp.font(row.isSelected ? .rowTitleStrong : .rowTitle)
            content.image = Self.face(row)
            content.imageProperties.reservedLayoutSize = CGSize(width: 14, height: 14)
            content.imageToTextPadding = Theme.Spacing.m
            content.secondaryAttributedText = Self.subtitle(row, shown: self.chooser.machine)
            content.secondaryTextProperties.numberOfLines = 0
            content.textProperties.numberOfLines = 0
            if row.wall != nil, !row.isSelected {
                content.textProperties.color = Theme.Color.tertiaryLabel
            }
            cell.accessibilityLabel = Self.spoken(row)
            cell.contentConfiguration = content
            cell.indentationLevel = row.isNested ? 1 : 0
            cell.accessories = [
                self.marks(row, room: self.view.bounds.width * 0.42)
            ]
        }

        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            guard let self,
                let id = self.dataSource.sectionIdentifier(for: indexPath.section),
                let section = self.chooser.sections.first(where: { $0.id == id })
            else { return }
            self.configureHeader(view, section: section)
        }

        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] view, _, _ in
            var content = UIListContentConfiguration.footer()
            content.text = self?.footerText()
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

    /// A heading's face: the chevron says whether it is open. A supplementary view is not an item,
    /// so a diffable snapshot never reconfigures it — a fold that changed the rows under a heading
    /// left the chevron pointing the old way until the heading scrolled off and back. The face is
    /// therefore written from one place, and a fold rewrites every heading on screen through it.
    private func configureHeader(_ view: UICollectionViewListCell, section: ModelChooserSection) {
            var content = UIListContentConfiguration.header()
            content.text = section.title.isEmpty ? nil : section.title.uppercased()
            content.textProperties.font = Theme.Ramp.font(.sectionLabel)
            content.secondaryText = section.title.isEmpty ? nil : section.detail
            content.secondaryTextProperties.font = Theme.Ramp.font(.rowMeta)
            content.prefersSideBySideTextAndSecondaryText = true
            content.secondaryTextProperties.color = Theme.Color.tertiaryLabel
            if section.canCollapse {
                content.image = UIImage(
                    systemName: section.isCollapsed ? "chevron.right" : "chevron.down",
                    withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold))
                content.imageProperties.tintColor = Theme.Color.secondaryLabel
            }
            view.contentConfiguration = content
            view.accessibilityTraits = section.canCollapse ? .button : []
            view.accessibilityHint =
                section.canCollapse
                ? String(localized: "Opens or folds this family") : nil
            view.accessibilityValue =
                section.canCollapse
                ? (section.isCollapsed ? String(localized: "Folded") : String(localized: "Open")) : nil
            view.gestureRecognizers?.forEach(view.removeGestureRecognizer)
            guard section.canCollapse else { return }
            view.addGestureRecognizer(
                SectionTapRecognizer(section: section.id) { [weak self] id in
                    guard let self, self.chooser.toggleSection(id) else { return }
                    Theme.Haptics.selection()
                    self.applySnapshot(keepingScroll: true)
                })
    }

    func refreshVisibleHeaders() {
        for indexPath in collectionView.indexPathsForVisibleSupplementaryElements(
            ofKind: UICollectionView.elementKindSectionHeader)
        {
            guard
                let view = collectionView.supplementaryView(
                    forElementKind: UICollectionView.elementKindSectionHeader, at: indexPath)
                    as? UICollectionViewListCell,
                let id = dataSource.sectionIdentifier(for: indexPath.section),
                let section = chooser.sections.first(where: { $0.id == id })
            else { continue }
            configureHeader(view, section: section)
        }
    }

    /// The name, with the letters the query landed on weighted inside it — the row says why the
    /// ranking put it here.
    static func title(_ row: ModelChooserRow) -> NSAttributedString {
        let text = NSMutableAttributedString(string: row.title)
        guard !row.highlight.isEmpty else { return text }
        let characters = Array(row.title)
        for offset in row.highlight where offset < characters.count {
            let start = String(characters[0..<offset]).utf16.count
            let length = String(characters[offset]).utf16.count
            text.addAttributes(
                [
                    .foregroundColor: Theme.Color.accent,
                    .font: Theme.Ramp.font(.rowTitleStrong),
                ], range: NSRange(location: start, length: length))
        }
        return text
    }

    /// The row's face: the family's dot, who answers, exactly as the pill and the quick menu wear
    /// it; a hollow circle where nobody has been chosen yet.
    static func face(_ row: ModelChooserRow) -> UIImage {
        if let chip = row.chip { return EffortMeterView.dotImage(Theme.Color.modelIdentity(chip)) }
        return UIImage(
            systemName: "circle",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 8, weight: .semibold))?
            .withTintColor(Theme.Color.tertiaryLabel, renderingMode: .alwaysOriginal)
            ?? UIImage()
    }

    /// One line under the name, said the same way on every row: what settles which model it is,
    /// where it runs when that is news, and what a pick would do to the level when it would move it.
    static func subtitle(_ row: ModelChooserRow, shown: String) -> NSAttributedString? {
        let font = Theme.Ramp.font(.rowDetail)
        let text = NSMutableAttributedString()
        func add(_ part: String, _ color: UIColor) {
            if text.length > 0 {
                text.append(
                    NSAttributedString(
                        string: " · ",
                        attributes: [.font: font, .foregroundColor: Theme.Color.tertiaryLabel]))
            }
            text.append(NSAttributedString(string: part, attributes: [.font: font, .foregroundColor: color]))
        }
        if let wall = row.wall { add(QuotaSurface.rowNote(wall), Theme.Color.danger) }
        if !row.detail.isEmpty {
            add(row.detail, row.isAuto ? Theme.Color.secondaryLabel : Theme.Color.tertiaryLabel)
        }
        if let place = row.place, row.profileID != shown || !row.isElsewhere {
            add(place, Theme.Color.info)
        }
        if let hint = row.reading?.hint { add(hint, Theme.Color.secondaryLabel) }
        return text.length > 0 ? text : nil
    }

    /// Under the last group: what the catalog amounts to, and — only when a row has other
    /// providers to open — the one sentence about the chevron.
    private func footerText() -> String? {
        if let reading = chooser.serverReading { return reading }
        if chooser.isNarrowed { return chooser.summary }
        guard chooser.canExpandAny else { return chooser.catalogSummary }
        return chooser.catalogSummary + "\n"
            + String(localized: "The chevron opens the other providers that run it.")
    }

    /// The whole row in words. A narrow screen has room for two marks and drops the rest, which is
    /// the right trade for the eye and the wrong one for a reader who cannot see the row at all —
    /// so everything the row knows is spoken whether or not it fitted.
    private static func spoken(_ row: ModelChooserRow) -> String {
        var parts = [row.title]
        if !row.detail.isEmpty { parts.append(row.detail) }
        if let wall = row.wall { parts.append(QuotaSurface.bannerBody(wall)) }
        parts += row.facts.map(\.label)
        if let word = row.reading?.word { parts.append(word) }
        if let hint = row.reading?.hint { parts.append(hint) }
        if row.pinning.isPinned { parts.append(String(localized: "Pinned")) }
        if row.isSelected { parts.append(String(localized: "Currently chosen")) }
        return parts.joined(separator: ". ")
    }

    /// The pin: one decision about the pair a row would run — the model at the level it would be
    /// worked at — muted until it is made. A swipe, the menu and this star are the same action,
    /// and every listing of the same model wears the same state.
    func star(_ row: ModelChooserRow) -> UIView? {
        guard !row.isAuto, !row.isLiteral, row.pinning.preset != nil else { return nil }
        let pinned = row.pinning.isPinned
        let button = UIButton(type: .system)
        button.setImage(
            UIImage(
                systemName: pinned ? "star.fill" : "star",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .semibold)),
            for: .normal)
        button.tintColor = pinned ? Theme.Color.accent : Theme.Color.tertiaryLabel
        button.frame = CGRect(x: 0, y: 0, width: 30, height: 28)
        button.accessibilityLabel =
            pinned ? String(localized: "Unpin") : String(localized: "Pin pair")
        button.addAction(UIAction { [weak self] _ in self?.togglePin(row) }, for: .touchUpInside)
        return button
    }

    private func pinActions(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let id = dataSource.itemIdentifier(for: indexPath), let row = row(for: id),
            row.pinning.preset != nil
        else { return nil }
        let pinned = row.pinning.isPinned
        let action = UIContextualAction(
            style: .normal,
            title: pinned ? String(localized: "Unpin") : String(localized: "Pin pair")
        ) { [weak self] _, _, done in
            self?.togglePin(row)
            done(true)
        }
        action.backgroundColor = Theme.Color.accent
        action.image = UIImage(systemName: pinned ? "star.slash" : "star.fill")
        return UISwipeActionsConfiguration(actions: [action])
    }

    func togglePin(_ row: ModelChooserRow) {
        guard let preset = row.pinning.preset else { return }
        let pinned = chooser.togglePin(row: row)
        Theme.Haptics.success()
        applySnapshot(keepingScroll: true)
        let said = ModelPresetCycle.said(preset, modelName: row.title)
        ToastView(
            message: pinned ? String(localized: "Pinned: \(said)") : String(localized: "Unpinned: \(said)")
        ).flash(in: view, above: view.safeAreaLayoutGuide.bottomAnchor, duration: 1.8)
    }

    func peekReading(for row: ModelChooserRow) -> ModelPeekReading? {
        guard !row.isAuto, let selection = row.selection,
            let candidate = chooser.candidates.first(where: { $0.carries(selection) })
        else { return nil }
        return ModelPeekReading.of(
            candidate, selected: chooser.selected, effort: dial?.effort,
            agentOptions: dial?.agentOptions ?? [], contextTokens: dial?.contextTokens,
            quotas: quotas)
    }
}
