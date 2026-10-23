import TailscodeCore
import UIKit

extension SessionListViewController {
    /// The verbs a held selection can be given, on a bar of their own at the bottom of the list.
    /// Every label is `BulkChatCopy.button`, so this client says "Delete 4" exactly the way the
    /// desktops say it and never phrases a count of its own. The bar is out of the layout
    /// entirely while nothing is being selected — an idle strip must never cost the list a row.
    func configureSelectionBar() {
        selectionBar.isHidden = true
        selectionBar.alpha = 0
        selectionBar.translatesAutoresizingMaskIntoConstraints = false
        selectionStack.axis = .horizontal
        selectionStack.distribution = .fillEqually
        selectionStack.alignment = .fill
        selectionStack.spacing = Theme.Spacing.xs
        selectionStack.translatesAutoresizingMaskIntoConstraints = false
        for action in [BulkChatAction.delete, .archive, .save, .markRead] {
            let button = bulkButton(action)
            bulkButtons[action] = button
            selectionStack.addArrangedSubview(button)
        }
        selectionBar.contentView.addSubview(selectionStack)
        view.addSubview(selectionBar)
        NSLayoutConstraint.activate([
            selectionBar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            selectionBar.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            selectionStack.topAnchor.constraint(
                equalTo: selectionBar.contentView.topAnchor, constant: Theme.Spacing.s),
            selectionStack.leadingAnchor.constraint(
                equalTo: selectionBar.contentView.leadingAnchor, constant: Theme.Spacing.s),
            selectionStack.trailingAnchor.constraint(
                equalTo: selectionBar.contentView.trailingAnchor, constant: -Theme.Spacing.s),
            selectionStack.bottomAnchor.constraint(
                equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -Theme.Spacing.s),
        ])
    }

    private func bulkButton(_ action: BulkChatAction) -> UIButton {
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: Self.bulkSymbol(action))
        config.imagePlacement = .top
        config.imagePadding = Theme.Spacing.xs
        config.titleLineBreakMode = .byWordWrapping
        config.contentInsets = NSDirectionalEdgeInsets(top: 6, leading: 4, bottom: 6, trailing: 4)
        config.baseForegroundColor =
            action.isDestructive ? Theme.Color.danger : Theme.Color.accent
        let button = UIButton(configuration: config)
        button.titleLabel?.textAlignment = .center
        button.addAction(
            UIAction { [weak self] _ in self?.performBulk(action) }, for: .touchUpInside)
        return button
    }

    private static func bulkSymbol(_ action: BulkChatAction) -> String {
        switch action {
        case .delete: return "trash"
        case .archive: return "archivebox"
        case .unarchive: return "tray.and.arrow.up"
        case .save: return "bookmark"
        case .unsave: return "bookmark.slash"
        case .markRead: return "envelope.open"
        case .markUnread: return "envelope.badge"
        }
    }

    /// Enters or leaves the editing mode. Leaving always drops the marks: a selection is a gesture
    /// in progress, and one that outlived the bar that could act on it would delete rows nobody
    /// can see are marked.
    func setSelecting(_ selecting: Bool) {
        guard isSelecting != selecting else { return }
        isSelecting = selecting
        if !selecting { selection.clear() }
        Theme.Haptics.tap()
        updateComposeButton()
        updateSelectionBar()
        refreshVisibleRows()
        if selecting { clearSelectedRows() } else { syncOpenMark(revealing: true) }
    }

    func updateSelectionBar() {
        let marked = selection.resolve(in: visibleEntries)
        for (action, button) in bulkButtons {
            let count = targets(for: action, in: marked).count
            var config = button.configuration
            var title = AttributedString(BulkChatCopy.button(action, count: count))
            title.font = Theme.Ramp.font(.panelDetail)
            config?.attributedTitle = title
            button.configuration = config
            button.isEnabled = count > 0
            button.accessibilityLabel = BulkChatCopy.button(action, count: count)
        }
        navigationItem.leftBarButtonItem = isSelecting ? selectAllItem() : nil
        syncSelectionBarVisibility()
    }

    /// Brings the verbs in and out with the mode, and gives the list back the strip they take, so
    /// the last row is never left under the bar. Reduced motion gets the same end state without
    /// the fade — a bar appearing is information, not decoration.
    private func syncSelectionBarVisibility() {
        let shown = isSelecting
        let settled = { [weak self] in
            guard let self else { return }
            self.selectionBar.isHidden = !shown
            if shown { self.view.layoutIfNeeded() }
            let inset = shown ? self.selectionBar.bounds.height : 0
            self.collectionView.contentInset.bottom = inset
            self.collectionView.verticalScrollIndicatorInsets.bottom = inset
        }
        guard selectionBar.isHidden == shown else {
            settled()
            return
        }
        if shown { selectionBar.isHidden = false }
        guard !UIAccessibility.isReduceMotionEnabled else {
            selectionBar.alpha = shown ? 1 : 0
            settled()
            return
        }
        UIView.animate(withDuration: 0.2) { [weak self] in
            self?.selectionBar.alpha = shown ? 1 : 0
        } completion: { _ in settled() }
    }

    /// The marked chats a verb would actually touch: delete only counts the ones whose server can
    /// delete, and every other verb only counts the rows it would change, so a button offering to
    /// save an already-saved selection is disabled rather than a no-op.
    func targets(for action: BulkChatAction, in marked: [SessionEntry]) -> [SessionEntry] {
        switch action {
        case .delete:
            return marked.filter { viewModel.supportsMultipleSessions($0) }
        case .archive:
            return marked.filter {
                !ArchivedChatStore.contains(profileID: $0.profileID, sessionID: $0.session.id)
            }
        case .unarchive:
            return marked.filter {
                ArchivedChatStore.contains(profileID: $0.profileID, sessionID: $0.session.id)
            }
        case .save:
            return marked.filter { !SavedChatStore.contains($0) }
        case .unsave:
            return marked.filter { SavedChatStore.contains($0) }
        case .markRead:
            let unread = SessionSeenStore.unreadEvaluator()
            return marked.filter { unread($0.session.id, $0.session.updatedAt) }
        case .markUnread:
            let unread = SessionSeenStore.unreadEvaluator()
            return marked.filter { !unread($0.session.id, $0.session.updatedAt) }
        }
    }

    /// One verb applied to the whole marked set. Everything but a delete is device-local and
    /// instant, so it happens and the mode ends; a delete is irreversible and asks first.
    private func performBulk(_ action: BulkChatAction) {
        let marked = targets(for: action, in: selection.resolve(in: visibleEntries))
        guard !marked.isEmpty else { return }
        guard !action.isDestructive else {
            confirmBulkDelete(marked)
            return
        }
        apply(action, to: marked)
        Theme.Haptics.success()
        setSelecting(false)
        applySnapshot()
    }

    /// The device-local half of a bulk verb, applied row by row through the same stores a single
    /// row action uses, so a set is never a second code path with its own idea of what archiving
    /// means. Delete is not here: it is the one verb that has to ask the server.
    func apply(_ action: BulkChatAction, to marked: [SessionEntry]) {
        for entry in marked {
            switch action {
            case .delete:
                continue
            case .archive, .unarchive:
                ArchivedChatStore.toggle(profileID: entry.profileID, sessionID: entry.session.id)
            case .save:
                SavedChatStore.save(entry)
            case .unsave:
                SavedChatStore.remove(profileID: entry.profileID, sessionID: entry.session.id)
            case .markRead:
                SessionSeenStore.markSeen(entry.session.id)
            case .markUnread:
                SessionSeenStore.markUnread(entry.session.id, updatedAt: entry.session.updatedAt)
            }
        }
    }

    /// A delete names what goes before it goes, in `BulkChatCopy`'s words, and reports a partial
    /// failure afterwards. A clean run says nothing — the rows are gone, which is the whole report
    /// — but a run that skipped some must never pass for a run that worked.
    func confirmBulkDelete(_ marked: [SessionEntry]) {
        let titles = marked.map { Self.displayTitle($0.session.title) }
        let alert = UIAlertController(
            title: BulkChatCopy.title(.delete, count: marked.count),
            message: BulkChatCopy.message(count: marked.count, titles: titles),
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(
            UIAlertAction(
                title: BulkChatCopy.confirm(.delete, count: marked.count), style: .destructive
            ) { [weak self] _ in
                guard let self else { return }
                Theme.Haptics.warning()
                self.setSelecting(false)
                Task { [weak self] in
                    guard let self else { return }
                    let outcome = await self.viewModel.delete(marked)
                    guard let report = BulkChatCopy.outcome(outcome) else { return }
                    Theme.Haptics.error()
                    let failure = UIAlertController(
                        title: String(localized: "Not everything was deleted"),
                        message: report, preferredStyle: .alert)
                    failure.addAction(
                        UIAlertAction(title: String(localized: "OK"), style: .default))
                    self.present(failure, animated: true)
                }
            })
        present(alert, animated: true)
    }

    func toggleMark(_ entry: SessionEntry) {
        Theme.Haptics.selection()
        selection.toggle(entry)
        updateSelectionBar()
        refreshRow(entry)
    }

    func toggleMarkAll() {
        Theme.Haptics.selection()
        selection.toggleAll(in: visibleEntries)
        updateSelectionBar()
        refreshVisibleRows()
    }

    private func refreshRow(_ entry: SessionEntry) {
        var snapshot = dataSource.snapshot()
        guard snapshot.indexOfItem(entry) != nil else { return }
        snapshot.reconfigureItems([entry])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    func refreshVisibleRows() {
        var snapshot = dataSource.snapshot()
        guard !snapshot.itemIdentifiers.isEmpty else { return }
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }
}
