import TailscodeCore
import UIKit

extension ModelPickerViewController {
    private func contextMenu(for row: ModelChooserRow) -> UIContextMenuConfiguration? {
        guard let reading = peekReading(for: row) else { return nil }
        let hue = ModelBadge.chip(
            selection: row.selection, effort: nil, catalog: chooser.sources.flatMap(\.models))
            .map { Theme.Color.modelIdentity($0) } ?? Theme.Color.tertiaryLabel
        return UIContextMenuConfiguration(
            identifier: row.id as NSString,
            previewProvider: { ModelPeekViewController(reading: reading, hue: hue) },
            actionProvider: { [weak self] _ in
                guard let self else { return nil }
                var actions: [UIMenuElement] = [
                    UIAction(
                        title: self.pickTitle(for: row),
                        image: UIImage(systemName: "checkmark.circle")
                    ) { [weak self] _ in
                        self?.commit(row.pick)
                    }
                ]
                if row.pinning.preset != nil {
                    let pinned = row.pinning.isPinned
                    actions.append(
                        UIAction(
                            title: pinned
                                ? String(localized: "Unpin") : String(localized: "Pin this pair"),
                            image: UIImage(systemName: pinned ? "star.slash" : "star")
                        ) { [weak self] _ in self?.togglePin(row) })
                }
                return UIMenu(children: actions)
            })
    }

    /// What the press on a row's menu says it does, by where the picker was opened from.
    private func pickTitle(for row: ModelChooserRow) -> String {
        switch context {
        case .serverDefault: return String(localized: "Use as the default")
        case .composer:
            return row.isElsewhere
                ? String(localized: "Start a new chat there") : String(localized: "Use for this message")
        case .chat:
            return row.isElsewhere
                ? String(localized: "Start a new chat there") : String(localized: "Use for this chat")
        case .branch:
            return String(localized: "Try with this model")
        }
    }

    /// Everything the row wears, in one accessory.
    ///
    /// Two custom accessories on one row are two views UIKit sizes from their own frames and never
    /// compresses, so a row with a wall, a machine, its levels, its doors, a chevron and a tick put
    /// six of them into space for two and drew them on top of each other. One view is one frame:
    /// the tick and the chevron take their places first because they are what a press is aimed at,
    /// and the marks fill what is left, dropped from the least decisive end — what ran out, then
    /// where it runs, then what it can do.
    func marks(_ row: ModelChooserRow, room: CGFloat) -> UICellAccessory {
        let strip = RowMarksView(
            row: row, slots: chooser.policy.capabilitySlots, room: max(60, room), star: star(row)
        ) { [weak self] in
            guard let self, let index = self.chooser.rows.firstIndex(where: { $0.id == row.id })
            else { return }
            self.chooser.focus(index)
            _ = self.chooser.setExpanded(!row.isExpanded, at: index)
            Theme.Haptics.selection()
            self.applySnapshot(keepingScroll: true)
        }
        return .customView(
            configuration: .init(
                customView: strip, placement: .trailing(), isHidden: false,
                reservedLayoutWidth: .actual, maintainsFixedSize: true))
    }

    /// Opening a family, or a row's other providers, adds rows *below* the row that was pressed, so
    /// the honest answer is to move nothing — but the sections' layout is rebuilt to hold them and
    /// the list can land somewhere else entirely, which for a press that asked to see one more row
    /// reads as the catalog throwing itself. A fold keeps the reader where they were; a new
    /// question — a query, a filter, a fresh catalog — is a different list and starts at the top.
    func applySnapshot(keepingScroll: Bool = false) {
        let held = keepingScroll ? collectionView.contentOffset : nil
        applyRows()
        guard let held else { return }
        collectionView.layoutIfNeeded()
        let inset = collectionView.adjustedContentInset
        let ceiling = max(
            -inset.top,
            collectionView.contentSize.height + inset.bottom - collectionView.bounds.height)
        collectionView.setContentOffset(
            CGPoint(x: held.x, y: min(held.y, ceiling)), animated: false)
    }

    /// A row's identity is its place in the list, not its face: opening a row's other doors, or
    /// picking one of them, changes what the row wears without changing which row it is, and a
    /// snapshot that finds the same ids draws nothing new. Every row whose reading changed is
    /// reloaded by name rather than reconfigured — a reconfigured cell keeps the height it was
    /// measured at, so a longer subtitle was cut off at the old row's one line — and the headings
    /// on screen are rewritten, so a chevron always points the way the list is actually folded.
    private func applyRows() {
        var snapshot = NSDiffableDataSourceSnapshot<String, String>()
        let before = rowsByID
        rowsByID.removeAll(keepingCapacity: true)
        for section in chooser.sections {
            snapshot.appendSections([section.id])
            snapshot.appendItems(section.rows.map(\.id), toSection: section.id)
            for row in section.rows { rowsByID[row.id] = row }
        }
        let changed = rowsByID.compactMap { id, row -> String? in
            guard let old = before[id], old != row else { return nil }
            return id
        }
        if !changed.isEmpty { snapshot.reloadItems(changed) }
        sectionIDs = chooser.sections.map(\.id)
        dataSource.apply(snapshot, animatingDifferences: false)
        refreshVisibleHeaders()
        syncFoldItem()
        guard let empty = chooser.emptyResult else {
            contentUnavailableConfiguration = nil
            return
        }
        var config = UIContentUnavailableConfiguration.search()
        config.text = empty
        contentUnavailableConfiguration = config
    }

    /// The one press over the whole list: open everything the folding is holding back, or shut it
    /// all again. It names the number, because "show more" over a catalog is a promise of unknown
    /// size and a person deciding whether to scroll is deciding on that number.
    private func syncFoldItem() {
        guard let action = chooser.foldAction else {
            navigationItem.leftBarButtonItem = nil
            return
        }
        navigationItem.leftBarButtonItem = UIBarButtonItem(
            title: action.title, image: nil,
            primaryAction: UIAction { [weak self] _ in
                guard let self, self.chooser.setAllCollapsed(action.collapses) else { return }
                Theme.Haptics.selection()
                self.applySnapshot(keepingScroll: true)
            })
    }

    @objc func close() { dismiss(animated: true) }

    /// A catalog that arrived while the picker is up — a server that came back from a restart —
    /// re-answers the list in place. The query and the tab survive the answer, and a server that
    /// is still down reads as down rather than as a machine with no models.
    func update(sources: [ModelSource]) {
        let query = chooser.query
        let machine = chooser.machine
        let door = chooser.door
        chooser = Self.makeChooser(
            sources: sources, selected: chooser.selected, recents: recents, quotas: quotas,
            dial: dial, context: context)
        chooser.search(query)
        chooser.setMachine(machine)
        chooser.setDoor(door)
        guard isViewLoaded else { return }
        syncMachines()
        applySnapshot()
    }
}

extension ModelPickerViewController: UICollectionViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) { scrollBand() }

    func collectionView(
        _ collectionView: UICollectionView, contextMenuConfigurationForItemAt indexPath: IndexPath,
        point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let id = dataSource.itemIdentifier(for: indexPath), let row = row(for: id) else {
            return nil
        }
        return contextMenu(for: row)
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let id = dataSource.itemIdentifier(for: indexPath), let row = row(for: id) else {
            return
        }
        commit(row.pick)
    }

    /// A pick that only changes this chat is told first and the sheet goes after it. A pick that
    /// leaves the chat waits for the sheet to be gone, so the screen it leaves for is not being
    /// presented over while it moves.
    private func commit(_ pick: ModelPick) {
        guard context == .branch else {
            onSelect(pick)
            dismiss(animated: true)
            return
        }
        let report = onSelect
        dismiss(animated: true) { report(pick) }
    }
}

extension ModelPickerViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        chooser.search(searchController.searchBar.text ?? "")
        applySnapshot()
    }
}
