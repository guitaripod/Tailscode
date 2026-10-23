import TailscodeCore
import CodingAgentKitApple
import UIKit

extension SessionListViewController {
    /// Relative timestamps ("Just now", "5m ago") are computed at cell
    /// configure time; this keeps them honest while the screen stays visible.
    func startClockRefresh() {
        clockRefreshTask?.cancel()
        clockRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if Task.isCancelled { return }
                self?.reconfigureActivity()
            }
        }
    }

    func configureSearch() {
        searchController.searchResultsUpdater = self
        searchController.obscuresBackgroundDuringPresentation = false
        searchController.searchBar.delegate = self
        searchController.searchBar.placeholder = String(
            localized: "Filter chats — return to search inside")
        searchController.searchBar.returnKeyType = .search
        searchController.searchBar.enablesReturnKeyAutomatically = false
        navigationItem.searchController = searchController
        navigationItem.hidesSearchBarWhenScrolling = false
    }

    /// Rebuilds both bars wholesale on every change, which is why the Select button and the
    /// selecting-mode bars live here: anything hung on `navigationItem` from somewhere else is
    /// wiped the next time the listing moves. Never add a bar item outside this method.
    func updateComposeButton() {
        guard !isSelecting else {
            navigationItem.leftBarButtonItem = selectAllItem()
            navigationItem.rightBarButtonItems = [
                UIBarButtonItem(
                    systemItem: .done,
                    primaryAction: UIAction { [weak self] _ in self?.setSelecting(false) })
            ]
            return
        }
        navigationItem.leftBarButtonItem = nil
        let servers = viewModel.servers
        let compose = UIImage(systemName: "square.and.pencil")
        let composeItem: UIBarButtonItem
        if scope != nil {
            composeItem = UIBarButtonItem(
                image: compose,
                primaryAction: UIAction { [weak self] _ in self?.startChatInScope() })
        } else if servers.count > 1 {
            let actions = servers.map { profile in
                UIAction(
                    title: profile.name,
                    subtitle: profile.backend.displayName,
                    image: Self.serverIcon(for: profile.backend)
                ) { [weak self] _ in self?.startChat(on: profile) }
            }
            composeItem = UIBarButtonItem(
                image: compose, menu: UIMenu(title: String(localized: "New chat on…"), children: actions))
        } else {
            composeItem = UIBarButtonItem(
                image: compose, primaryAction: UIAction { [weak self] _ in
                    guard let self, let profile = self.viewModel.servers.first else { return }
                    self.startChat(on: profile)
                })
        }
        composeItem.accessibilityLabel =
            scope.map { String(localized: "New chat in \($0.name)") }
            ?? String(localized: "New chat")
        var items = [composeItem]
        if !showsAsColumn {
            let saved = UIBarButtonItem(
                image: UIImage(systemName: "bookmark"),
                primaryAction: UIAction { [weak self] _ in self?.pushSaved() })
            saved.accessibilityLabel = String(localized: "Saved chats")
            items.append(saved)
        }
        if !showsAsColumn, archivedCount() > 0 {
            let archived = UIBarButtonItem(
                image: UIImage(systemName: "archivebox"),
                primaryAction: UIAction { [weak self] _ in self?.pushArchived() })
            archived.accessibilityLabel = String(localized: "Archived chats")
            items.append(archived)
        }
        if !viewModel.entries.isEmpty {
            let select = UIBarButtonItem(
                image: UIImage(systemName: "checklist"),
                primaryAction: UIAction { [weak self] _ in self?.setSelecting(true) })
            select.accessibilityLabel = String(localized: "Select chats")
            items.append(select)
        }
        navigationItem.rightBarButtonItems = items
    }

    func selectAllItem() -> UIBarButtonItem {
        let everything = !visibleEntries.isEmpty
            && visibleEntries.allSatisfy { selection.contains($0) }
        let item = UIBarButtonItem(
            title: everything
                ? String(localized: "Deselect All") : String(localized: "Select All"),
            primaryAction: UIAction { [weak self] _ in self?.toggleMarkAll() })
        item.isEnabled = !visibleEntries.isEmpty
        return item
    }

    /// Counts archived rows in the current listing rather than the raw store, mirroring the
    /// desktop footer: keys whose session no longer lists anywhere should not keep a door open.
    private func archivedCount() -> Int {
        let archived = ArchivedChatStore.all()
        return viewModel.entries.count {
            archived.contains(ArchivedChatStore.key($0.profileID, $0.session.id))
        }
    }

    private func pushSaved() {
        Theme.Haptics.tap()
        if let workspace { return workspace.showSaved() }
        navigationController?.pushViewController(SavedChatsViewController(), animated: true)
    }

    func pushArchived() {
        Theme.Haptics.tap()
        if let workspace { return workspace.showArchived() }
        navigationController?.pushViewController(ArchivedChatsViewController(), animated: true)
    }

    func configureChipBar() {
        chipBar.showsHorizontalScrollIndicator = false
        chipBar.translatesAutoresizingMaskIntoConstraints = false
        chipStack.axis = .horizontal
        chipStack.spacing = Theme.Spacing.s
        chipStack.translatesAutoresizingMaskIntoConstraints = false
        chipBar.addSubview(chipStack)
        view.addSubview(chipBar)

        unreachableLabel.font = Theme.Ramp.font(.panelFootnote)
        unreachableLabel.textColor = Theme.Color.danger
        unreachableLabel.numberOfLines = 1
        unreachableLabel.isHidden = true
        unreachableLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(unreachableLabel)

        chipBarTop = chipBar.topAnchor.constraint(
            equalTo: view.safeAreaLayoutGuide.topAnchor, constant: Theme.Spacing.s)
        chipBarHeight = chipBar.heightAnchor.constraint(equalToConstant: 36)
        NSLayoutConstraint.activate([
            chipBarTop,
            chipBar.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor),
            chipBar.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor),
            chipBarHeight,
            chipStack.topAnchor.constraint(equalTo: chipBar.contentLayoutGuide.topAnchor),
            chipStack.bottomAnchor.constraint(equalTo: chipBar.contentLayoutGuide.bottomAnchor),
            chipStack.leadingAnchor.constraint(equalTo: chipBar.contentLayoutGuide.leadingAnchor, constant: Theme.Spacing.l),
            chipStack.trailingAnchor.constraint(equalTo: chipBar.contentLayoutGuide.trailingAnchor, constant: -Theme.Spacing.l),
            chipStack.heightAnchor.constraint(equalTo: chipBar.frameLayoutGuide.heightAnchor),

            unreachableLabel.topAnchor.constraint(equalTo: chipBar.bottomAnchor, constant: Theme.Spacing.xs),
            unreachableLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -Theme.Spacing.l),
        ])
    }

    func rebuildChips() {
        guard mayRender() else { return }
        chipStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        chipStack.addArrangedSubview(
            chip(title: String(localized: "All"), isSelected: filter == .all) { [weak self] in
            self?.setFilter(.all)
            })
        let liveCount = filterableEntries().count(where: isLive)
        if liveCount > 0 || filter == .live {
            chipStack.addArrangedSubview(
                chip(
                    title: String(localized: "Live · \(liveCount)"), isSelected: filter == .live,
                    tint: Theme.Color.success
                ) {
                    [weak self] in self?.setFilter(.live)
                })
        }
        guard scope == nil else { return }
        for profile in viewModel.servers {
            chipStack.addArrangedSubview(
                chip(
                    title: profile.name,
                    isSelected: filter == .profile(profile.id),
                    icon: Self.serverIcon(for: profile.backend)
                ) { [weak self] in self?.setFilter(.profile(profile.id)) })
        }
    }

    func chip(
        title: String, isSelected: Bool, tint: UIColor? = nil, icon: UIImage? = nil,
        action: @escaping () -> Void
    ) -> UIButton {
        var config = isSelected
            ? UIButton.Configuration.filled() : Theme.Glass.buttonConfiguration()
        config.cornerStyle = .capsule
        config.buttonSize = .small
        var attributed = AttributedString(title)
        attributed.font = Theme.Ramp.font(.panelDetail)
            .withTraits(isSelected ? .traitBold : [])
        config.attributedTitle = attributed
        if isSelected {
            config.baseBackgroundColor = tint ?? Theme.Color.accent
            config.baseForegroundColor = .white
        } else if let tint {
            config.baseForegroundColor = tint
        }
        if let icon, !isSelected {
            config.image = icon
            config.imagePadding = Theme.Spacing.xs
            config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 11)
        }
        let button = UIButton(configuration: config)
        button.accessibilityTraits = isSelected ? [.button, .selected] : .button
        button.addAction(
            UIAction { _ in
                Theme.Haptics.selection()
                action()
            }, for: .touchUpInside)
        return button
    }

    private func setFilter(_ newFilter: ChatFilter) {
        show(filter: filter == newFilter ? .all : newFilter)
    }

    /// Narrows the list to exactly this filter. The chips toggle one off again when it is pressed
    /// twice; a filter chosen from somewhere else — the sidebar, a Home card — is taken as said.
    func show(filter newFilter: ChatFilter) {
        guard newFilter != filter else { return }
        filter = newFilter
        guard isViewLoaded else { return }
        updateTitle()
        rebuildChips()
        applySnapshot()
    }

    /// A column names the scope the sidebar gave it; the phone's list is always Chats, because
    /// the chips right under the title already say which of them are showing.
    func updateTitle() {
        if let scope {
            title = scope.name
            return
        }
        guard showsAsColumn else {
            title = String(localized: "Chats")
            return
        }
        switch filter {
        case .all: title = String(localized: "All Chats")
        case .live: title = String(localized: "Live Now")
        case .profile(let id):
            title = viewModel.servers.first { $0.id == id }?.name ?? String(localized: "Chats")
        }
    }

    /// A column's view runs on under the floating sidebar, and a list whose cells did too laid
    /// their trailing marks out against a width the sidebar was covering — a state pill came out
    /// centred in a slot a third its size, over the row's age and past the column's edge. So a
    /// column's rows start where the column can be seen, and only its background runs beneath.
    func applyColumnMode() {
        view.backgroundColor = showsAsColumn ? Theme.Color.background : Theme.Color.groupedBackground
        NSLayoutConstraint.deactivate(showsAsColumn ? listEdges : columnEdges)
        NSLayoutConstraint.activate(showsAsColumn ? columnEdges : listEdges)
        collectionView.setCollectionViewLayout(makeLayout(), animated: false)
        chipBar.isHidden = showsAsColumn && scope == nil
        chipBarHeight.constant = chipBar.isHidden ? 0 : 36
        chipBarTop.constant = chipBar.isHidden ? 0 : Theme.Spacing.s
        updateTitle()
        updateComposeButton()
        refreshVisibleRows()
        clearSelectedRows()
        syncOpenMark(revealing: true)
    }

    /// Marks the row whose conversation is open beside the list, and nothing when none is.
    func markOpen(_ key: String?) {
        guard key != openKey else { return }
        openKey = key
        syncOpenMark(revealing: true)
    }

    /// A chat opened from somewhere other than this list — a Home card, a notification, the
    /// sidebar's pins — is scrolled into view once, when it opens; a listing that moves while it
    /// is open never drags the list back to it.
    ///
    /// The mark is the list's selection, which the keyboard cursor moves too, so it is only put
    /// back when it moved or was lost — a listing refresh must neither drag the cursor back to the
    /// open row nor, on a phone, clear the row the cursor is on.
    func syncOpenMark(revealing: Bool = false) {
        guard isViewLoaded, dataSource != nil, showsAsColumn, !isSelecting else { return }
        let selected = collectionView.indexPathsForSelectedItems ?? []
        guard revealing || selected.isEmpty else { return }
        let wanted = openKey.flatMap { key in
            visibleEntries.first { ChatSelection.key($0) == key }
        }.flatMap { dataSource.indexPath(for: $0) }
        for indexPath in selected where indexPath != wanted {
            collectionView.deselectItem(at: indexPath, animated: false)
        }
        guard let wanted else { return }
        if !selected.contains(wanted) {
            collectionView.selectItem(at: wanted, animated: false, scrollPosition: [])
        }
        if revealing, !collectionView.indexPathsForVisibleItems.contains(wanted) {
            collectionView.scrollToItem(at: wanted, at: .centeredVertically, animated: true)
        }
    }

    /// Clears every row's selection — leaving the column, where it marked the open chat, or
    /// starting to mark rows for a bulk verb, where it would read as one of the marks.
    func clearSelectedRows() {
        for indexPath in collectionView.indexPathsForSelectedItems ?? [] {
            collectionView.deselectItem(at: indexPath, animated: false)
        }
    }

    func beginSearch() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.searchController.isActive = true
            self.searchController.searchBar.searchTextField.becomeFirstResponder()
        }
    }

    /// Opens a chat the listing holds by its pin key — the sidebar's pinned rows.
    func open(key: String) {
        guard let entry = viewModel.entries.first(where: { ChatSelection.key($0) == key }) else {
            return
        }
        SessionSeenStore.markSeen(entry.session.id)
        openChat(for: entry)
    }
}
