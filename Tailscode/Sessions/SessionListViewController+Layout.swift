import TailscodeCore
import UIKit

extension SessionListViewController {
    func configureCollectionView() {
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: makeLayout())
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.dragDelegate = self
        collectionView.refreshControl = refreshControl
        refreshControl.addTarget(self, action: #selector(refresh), for: .valueChanged)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: unreachableLabel.bottomAnchor, constant: Theme.Spacing.xs),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    /// The two ways the list meets the sides of its view: flush to the edges as the phone has it,
    /// or inside the safe area when it is a column whose view runs on under the floating sidebar.
    /// `applyColumnMode` activates one set and never both.
    func configureEdges() {
        listEdges = [
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            unreachableLabel.leadingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: Theme.Spacing.l),
            selectionBar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
        ]
        columnEdges = [
            collectionView.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            unreachableLabel.leadingAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: Theme.Spacing.l),
            selectionBar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
        ]
    }

    /// The phone's list is inset cards under prominent headings; a column beside a conversation
    /// is a plain run of rows under quiet ones, because at a third of a window the cards' margins
    /// are the title's missing words.
    func makeLayout() -> UICollectionViewCompositionalLayout {
        var config = UICollectionLayoutListConfiguration.themed(showsAsColumn ? .plain : .insetGrouped)
        config.headerMode = .supplementary
        config.itemSeparatorHandler = { _, separators in
            var out = separators
            out.bottomSeparatorInsets = NSDirectionalEdgeInsets(
                top: 0, leading: ChatRowContentView.textInset, bottom: 0, trailing: 0)
            return out
        }
        if showsAsColumn { config.headerTopPadding = Theme.Spacing.s }
        config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            guard let self, !self.isSelecting,
                let entry = self.dataSource.itemIdentifier(for: indexPath)
            else { return nil }
            var actions: [UIContextualAction] = []
            if self.viewModel.supportsMultipleSessions(entry) {
                let delete = UIContextualAction(
                    style: .destructive, title: String(localized: "Delete")
                ) {
                    [weak self] _, _, done in
                    self?.confirmDelete(entry, done: done)
                }
                delete.image = UIImage(systemName: "trash")
                actions.append(delete)
            }
            let isArchived = ArchivedChatStore.contains(
                profileID: entry.profileID, sessionID: entry.session.id)
            let archive = UIContextualAction(
                style: .normal,
                title: isArchived ? String(localized: "Unarchive") : String(localized: "Archive")
            ) { [weak self] _, _, done in
                self?.toggleArchived(entry)
                done(true)
            }
            archive.image = UIImage(systemName: isArchived ? "tray.and.arrow.up" : "archivebox")
            archive.backgroundColor = Theme.Color.secondaryLabel
            actions.append(archive)
            if let row = self.rowModels[ChatSelection.key(entry)], row.state.carriesBackgroundWork,
                self.viewModel.supportsBackgroundStop(entry)
            {
                let stop = UIContextualAction(
                    style: .normal, title: String(localized: "Stop work")
                ) { [weak self] _, _, done in
                    self?.stopBackgroundWork(entry)
                    done(true)
                }
                stop.image = UIImage(systemName: "stop.circle")
                stop.backgroundColor = Theme.Color.warning
                actions.append(stop)
            }
            guard !actions.isEmpty else { return nil }
            let config = UISwipeActionsConfiguration(actions: actions)
            config.performsFirstActionWithFullSwipe = false
            return config
        }
        config.leadingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            guard let self, !self.isSelecting,
                let entry = self.dataSource.itemIdentifier(for: indexPath)
            else { return nil }
            let isSaved = SavedChatStore.contains(entry)
            let save = UIContextualAction(
                style: .normal,
                title: isSaved ? String(localized: "Remove") : String(localized: "Save")
            ) { _, _, done in
                Theme.Haptics.tap()
                SavedChatStore.toggle(entry)
                done(true)
            }
            save.image = UIImage(systemName: isSaved ? "bookmark.slash" : "bookmark")
            save.backgroundColor = Theme.Color.warning
            return UISwipeActionsConfiguration(actions: [save])
        }
        return .readableList(using: config)
    }
}

extension SessionListViewController {
    func configureDataSource() {
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (list: SessionListViewController, _) in
            list.refreshVisibleHeaders()
        }
        let cell = UICollectionView.CellRegistration<ChatRowCell, SessionEntry> {
            [weak self] cell, _, entry in
            guard let self else { return }
            let row = self.rowModels[ChatSelection.key(entry)]
                ?? SessionRowModel(
                    entry: entry, unreachable: false, unread: false, saved: false,
                    presence: self.presence(for: entry))
            self.configure(cell, with: row)
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
            collectionView, indexPath, entry in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: entry)
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            guard let self else { return }
            let sections = self.dataSource.snapshot().sectionIdentifiers
            guard sections.indices.contains(indexPath.section) else { return }
            self.dress(view, as: sections[indexPath.section])
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
    }

    /// A heading and the one figure worth putting beside it: how many agents are waiting or
    /// working, in the section's own tone, or how many rows under it are new, in the accent.
    func dress(_ view: UICollectionViewListCell, as section: ChatListSection) {
        var content = showsAsColumn
            ? UIListContentConfiguration.header()
            : UIListContentConfiguration.prominentInsetGroupedHeader()
        let heading = headings[section] ?? SectionHeading(section: section, rows: 0, fresh: 0)
        let tint = heading.needsYou ? Theme.Color.warning : content.textProperties.color
        let text = NSMutableAttributedString(
            string: content.textProperties.transform == .uppercase
                ? heading.title.uppercased(with: .current) : heading.title,
            attributes: [.font: content.textProperties.font, .foregroundColor: tint])
        let figure = heading.total.map { ("\($0)", heading.needsYou ? tint : Theme.Color.tertiaryLabel) }
            ?? heading.freshLabel.map { ($0, Theme.Color.accent) }
        if let figure {
            text.append(
                NSAttributedString(
                    string: "  " + figure.0,
                    attributes: [
                        .font: UIFont.systemFont(
                            ofSize: Self.figureSize(beside: content.textProperties.font),
                            weight: .semibold),
                        .foregroundColor: figure.1,
                    ]))
        }
        content.attributedText = text
        view.contentConfiguration = content
        view.accessibilityLabel = heading.spoken
    }

    /// The figure beside a heading: the heading's own size where the heading is already small, and
    /// two thirds of it under the phone's prominent headings, where a figure as large as the name
    /// would read as part of it.
    private static func figureSize(beside font: UIFont) -> CGFloat {
        font.pointSize > 17 ? (font.pointSize * 0.68).rounded() : font.pointSize
    }

    /// A count beside a heading moves when a chat under it is read, which changes no row and so
    /// redraws no header on its own.
    func refreshVisibleHeaders() {
        let kind = UICollectionView.elementKindSectionHeader
        let sections = dataSource.snapshot().sectionIdentifiers
        for path in collectionView.indexPathsForVisibleSupplementaryElements(ofKind: kind) {
            guard sections.indices.contains(path.section),
                let view = collectionView.supplementaryView(forElementKind: kind, at: path)
                    as? UICollectionViewListCell
            else { continue }
            dress(view, as: sections[path.section])
        }
    }

    /// One row, drawn from what `SessionRowModel` already decided and spelled by the same row
    /// Home's bands use. The state, the news and the tint all read the row's `state` rather than
    /// re-asking the listing, which is what keeps a conversation this device is streaming looking
    /// live in the list and in the section it sits in. Never re-derives liveness inside a cell.
    func configure(_ cell: ChatRowCell, with row: SessionRowModel) {
        let entry = row.entry
        cell.paintsGroupedSurface = !showsAsColumn
        cell.wantsAttention = row.state.needsYou && !showsAsColumn
        cell.contentConfiguration = ChatRowConfiguration(
            facts: ChatRowFacts(
                row: row, vocabulary: vocabulary,
                ask: showsFixture
                    ? ChatListFixture.asks[entry.session.id]
                    : SessionActivity.shared.approvalAsk(for: entry.session.id),
                missed: missedReasons[entry.session.id],
                section: rowBoards[ChatSelection.key(entry)]))

        let marked = isSelecting && selection.contains(entry)
        let column = showsAsColumn
        cell.surfaceTint = { state in
            if marked { return Theme.Color.accent.withAlphaComponent(0.18) }
            if column, state.isSelected { return Theme.Color.accent.withAlphaComponent(0.14) }
            return nil
        }

        var accessories: [UICellAccessory] = []
        if isSelecting {
            accessories.append(Self.markAccessory(marked: selection.contains(entry)))
        }
        if !isSelecting, !showsAsColumn { accessories.append(.disclosureIndicator()) }
        cell.accessories = accessories
        cell.accessibilityValue = marked ? String(localized: "Selected") : nil
        cell.answersPointer(cornerRadius: showsAsColumn ? 0 : Theme.Radius.control)
    }

    private static func markAccessory(marked: Bool) -> UICellAccessory {
        let mark = UIImageView(
            image: UIImage(
                systemName: marked ? "checkmark.square.fill" : "square",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 18, weight: .medium)))
        mark.tintColor = marked ? Theme.Color.accent : Theme.Color.tertiaryLabel
        mark.contentMode = .scaleAspectFit
        mark.frame = CGRect(x: 0, y: 0, width: 22, height: 22)
        return .customView(
            configuration: .init(
                customView: mark, placement: .leading(displayed: .always),
                maintainsFixedSize: true))
    }
}
