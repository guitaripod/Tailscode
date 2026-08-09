import TailscodeCore
import CodingAgentKit
import CodingAgentKitApple
import UIKit

/// Every conversation across every server in one list, grouped into the shared sections —
/// PINNED, LIVE NOW, SAVED, RECENT — with filter chips narrowing what is grouped, so finding a
/// chat is scroll-or-search instead of expand-and-hunt.
@MainActor
final class SessionListViewController: UIViewController {
    private enum ChatFilter: Equatable {
        case all, live, profile(String)
    }

    private let viewModel: SessionListViewModel
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<SessionSection, SessionEntry>!
    private let refreshControl = UIRefreshControl()
    private let searchController = UISearchController(searchResultsController: nil)
    private let chipBar = UIScrollView()
    private let chipStack = UIStackView()
    private let unreachableLabel = UILabel()
    private let selectionBar = Theme.Glass.view()
    private let selectionStack = UIStackView()
    private var bulkButtons: [BulkChatAction: UIButton] = [:]
    private var filter: ChatFilter
    private let scope: ProjectScope?
    private var hasAppeared = false
    private var hasLoadedOnce = false
    private var searchQuery = ""
    var keyCursor: Int?

    /// The rows the list is drawing, flattened across every section in the order the eye reads
    /// them. The keyboard cursor, select-all and the pruning of a held selection all address this
    /// one list, because an `IndexPath` into a sectioned snapshot is not a position a person has.
    private var visibleEntries: [SessionEntry] = []

    /// Each visible row's derived state, keyed the way every store here is keyed, so a cell reads
    /// what `SessionRowModel` already decided instead of re-deciding it per configure.
    private var rowModels: [String: SessionRowModel] = [:]
    /// What the whole listing already says, so no row repeats it: one server's name written on
    /// every row of a one-server fleet is the word a reader's eye lands on and learns nothing from.
    private var vocabulary: ChatListVocabulary = .full

    private var selection = ChatSelection()
    private var isSelecting = false

    init(filterProfileID: String? = nil, scope: ProjectScope? = nil) {
        let sources = ConnectionController.shared.allBackends().map {
            SessionListViewModel.Source(profile: $0.profile, backend: $0.backend)
        }
        self.viewModel = SessionListViewModel(sources: sources)
        self.filter = filterProfileID.map { .profile($0) } ?? .all
        self.scope = scope
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = scope?.name ?? String(localized: "Chats")
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = Theme.Color.groupedBackground
        configureSearch()
        configureChipBar()
        configureCollectionView()
        configureSelectionBar()
        configureDataSource()
        bind()
        contentUnavailableConfiguration = UIContentUnavailableConfiguration.loading()
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidBecomeActive),
            name: UIApplication.didBecomeActiveNotification, object: nil)
        Task {
            await viewModel.load()
            hasLoadedOnce = true
            applySnapshot()
        }
    }

    /// Coming back to the app with this list on screen must not show the world as it was when
    /// the app was put away — `viewWillAppear` never fires for that path, only this does.
    @objc private func appDidBecomeActive() {
        guard hasAppeared, viewIfLoaded?.window != nil else { return }
        Task { await viewModel.load() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if hasAppeared { Task { await viewModel.load() } }
        hasAppeared = true
        startClockRefresh()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        guard keyContext == .insert else { return nil }
        return KeyBridge.shared.insertKeyCommands(action: #selector(handleInsertKeyCommand(_:)))
    }

    @objc private func handleInsertKeyCommand(_ command: UIKeyCommand) {
        guard let token = command.propertyList as? String,
            let chord = KeyBridge.chord(forToken: token)
        else { return }
        _ = KeyBridge.shared.handle(chord, context: .insert, awaitingApproval: false) {
            [weak self] action in
            self?.performKeyAction(action) ?? false
        }
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if keyContext == .normal, handleKeyPresses(presses) { return }
        super.pressesBegan(presses, with: event)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        clockRefreshTask?.cancel()
        clockRefreshTask = nil
    }

    private var clockRefreshTask: Task<Void, Never>?

    /// Relative timestamps ("Just now", "5m ago") are computed at cell
    /// configure time; this keeps them honest while the screen stays visible.
    private func startClockRefresh() {
        clockRefreshTask?.cancel()
        clockRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if Task.isCancelled { return }
                self?.reconfigureActivity()
            }
        }
    }

    private func configureSearch() {
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
    private func updateComposeButton() {
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
        let saved = UIBarButtonItem(
            image: UIImage(systemName: "bookmark"),
            primaryAction: UIAction { [weak self] _ in self?.pushSaved() })
        saved.accessibilityLabel = String(localized: "Saved chats")
        var items = [composeItem, saved]
        if archivedCount() > 0 {
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

    private func selectAllItem() -> UIBarButtonItem {
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
        navigationController?.pushViewController(SavedChatsViewController(), animated: true)
    }

    private func pushArchived() {
        Theme.Haptics.tap()
        navigationController?.pushViewController(ArchivedChatsViewController(), animated: true)
    }

    private func configureChipBar() {
        chipBar.showsHorizontalScrollIndicator = false
        chipBar.translatesAutoresizingMaskIntoConstraints = false
        chipStack.axis = .horizontal
        chipStack.spacing = Theme.Spacing.s
        chipStack.translatesAutoresizingMaskIntoConstraints = false
        chipBar.addSubview(chipStack)
        view.addSubview(chipBar)

        unreachableLabel.font = .preferredFont(forTextStyle: .caption2)
        unreachableLabel.textColor = Theme.Color.danger
        unreachableLabel.numberOfLines = 1
        unreachableLabel.isHidden = true
        unreachableLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(unreachableLabel)

        NSLayoutConstraint.activate([
            chipBar.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: Theme.Spacing.s),
            chipBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            chipBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            chipBar.heightAnchor.constraint(equalToConstant: 36),
            chipStack.topAnchor.constraint(equalTo: chipBar.contentLayoutGuide.topAnchor),
            chipStack.bottomAnchor.constraint(equalTo: chipBar.contentLayoutGuide.bottomAnchor),
            chipStack.leadingAnchor.constraint(equalTo: chipBar.contentLayoutGuide.leadingAnchor, constant: Theme.Spacing.l),
            chipStack.trailingAnchor.constraint(equalTo: chipBar.contentLayoutGuide.trailingAnchor, constant: -Theme.Spacing.l),
            chipStack.heightAnchor.constraint(equalTo: chipBar.frameLayoutGuide.heightAnchor),

            unreachableLabel.topAnchor.constraint(equalTo: chipBar.bottomAnchor, constant: Theme.Spacing.xs),
            unreachableLabel.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: Theme.Spacing.l),
            unreachableLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.trailingAnchor, constant: -Theme.Spacing.l),
        ])
    }

    private func rebuildChips() {
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

    private func chip(
        title: String, isSelected: Bool, tint: UIColor? = nil, icon: UIImage? = nil,
        action: @escaping () -> Void
    ) -> UIButton {
        var config = isSelected
            ? UIButton.Configuration.filled() : Theme.Glass.buttonConfiguration()
        config.cornerStyle = .capsule
        config.buttonSize = .small
        var attributed = AttributedString(title)
        attributed.font = UIFont.preferredFont(forTextStyle: .footnote)
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
        filter = filter == newFilter ? .all : newFilter
        rebuildChips()
        applySnapshot()
    }

    private func configureCollectionView() {
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .supplementary
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
        let layout = UICollectionViewCompositionalLayout.list(using: config)
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.refreshControl = refreshControl
        refreshControl.addTarget(self, action: #selector(refresh), for: .valueChanged)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: unreachableLabel.bottomAnchor, constant: Theme.Spacing.xs),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    /// The verbs a held selection can be given, on a bar of their own at the bottom of the list.
    /// Every label is `BulkChatCopy.button`, so this client says "Delete 4" exactly the way the
    /// desktops say it and never phrases a count of its own. The bar is out of the layout
    /// entirely while nothing is being selected — an idle strip must never cost the list a row.
    private func configureSelectionBar() {
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
            selectionBar.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            selectionBar.trailingAnchor.constraint(equalTo: view.trailingAnchor),
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
    private func setSelecting(_ selecting: Bool) {
        guard isSelecting != selecting else { return }
        isSelecting = selecting
        if !selecting { selection.clear() }
        Theme.Haptics.tap()
        updateComposeButton()
        updateSelectionBar()
        refreshVisibleRows()
    }

    private func updateSelectionBar() {
        let marked = selection.resolve(in: visibleEntries)
        for (action, button) in bulkButtons {
            let count = targets(for: action, in: marked).count
            var config = button.configuration
            var title = AttributedString(BulkChatCopy.button(action, count: count))
            title.font = UIFont.preferredFont(forTextStyle: .caption1)
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
    private func targets(for action: BulkChatAction, in marked: [SessionEntry]) -> [SessionEntry] {
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
    private func apply(_ action: BulkChatAction, to marked: [SessionEntry]) {
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
    private func confirmBulkDelete(_ marked: [SessionEntry]) {
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

    private func toggleMark(_ entry: SessionEntry) {
        Theme.Haptics.selection()
        selection.toggle(entry)
        updateSelectionBar()
        refreshRow(entry)
    }

    private func toggleMarkAll() {
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

    private func refreshVisibleRows() {
        var snapshot = dataSource.snapshot()
        guard !snapshot.itemIdentifiers.isEmpty else { return }
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func configureDataSource() {
        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, SessionEntry> {
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
            var content = UIListContentConfiguration.prominentInsetGroupedHeader()
            content.text = sections[indexPath.section].title
            view.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
    }

    /// One row, drawn from what `SessionRowModel` already decided. The pill, the tint and the
    /// snippet all read the row's `state` rather than re-asking the listing, which is what keeps a
    /// conversation this device is streaming looking live in the list and in the section it sits
    /// in. Never re-derives liveness inside a cell.
    private func configure(_ cell: UICollectionViewListCell, with row: SessionRowModel) {
        let entry = row.entry
        var content = UIListContentConfiguration.subtitleCell()
        content.text = Self.displayTitle(entry.session.title)
        content.textProperties.font = Theme.Font.body()
        content.textProperties.numberOfLines = 1

        let facets = row.facets(vocabulary)
        let rest =
            row.snippet ?? [facets.project, facets.origin].compactMap { $0 }
            .joined(separator: " · ")
        content.secondaryAttributedText = ModelChipText.detailLine(
            chip: ModelBadge.chip(for: entry.session), rest: rest,
            size: UIFont.preferredFont(forTextStyle: .caption2).pointSize,
            restColor: row.snippet == nil ? Theme.Color.tertiaryLabel : Theme.Color.accent)
        content.secondaryTextProperties.numberOfLines = 1
        content.textToSecondaryTextVerticalPadding = 2
        content.prefersSideBySideTextAndSecondaryText = false

        content.image = UIImage(systemName: entry.backendType.symbolName)?
            .withTintColor(
                Self.tint(for: row.state) ?? entry.backendType.brandColor,
                renderingMode: .alwaysOriginal)
        content.imageProperties.maximumSize = CGSize(width: 20, height: 20)
        content.imageProperties.reservedLayoutSize = CGSize(width: 20, height: 20)
        content.imageToTextPadding = Theme.Spacing.m
        cell.contentConfiguration = content

        var background = UIBackgroundConfiguration.listCell()
        if isSelecting, selection.contains(entry) {
            background.backgroundColor = Theme.Color.accent.withAlphaComponent(0.18)
        }
        cell.backgroundConfiguration = background

        var accessories: [UICellAccessory] = [Self.ageAccessory(facets.age)]
        if isSelecting {
            accessories.append(Self.markAccessory(marked: selection.contains(entry)))
        }
        if row.pinned {
            let pin = UIImageView(image: UIImage(systemName: "pin.fill"))
            pin.tintColor = Theme.Color.accent
            pin.contentMode = .scaleAspectFit
            pin.frame = CGRect(x: 0, y: 0, width: 13, height: 13)
            accessories.append(.customView(
                configuration: .init(
                    customView: pin, placement: .trailing(displayed: .always),
                    maintainsFixedSize: true)))
        }
        if let pill = Self.statusPill(for: row.state) {
            accessories.append(pill)
        } else if row.unread {
            accessories.append(Self.dot(Theme.Color.accent))
        }
        if !isSelecting { accessories.append(.disclosureIndicator()) }
        cell.accessories = accessories
        cell.accessibilityValue = Self.spoken(row, marked: isSelecting && selection.contains(entry))
    }

    /// What a row says out loud: the mark first while selecting, because in an editing mode
    /// whether this chat is going with the next verb outranks what it is doing. Never leaves a
    /// marked row indistinguishable from an unmarked one to VoiceOver.
    private static func spoken(_ row: SessionRowModel, marked: Bool) -> String? {
        var parts: [String] = []
        if marked { parts.append(String(localized: "Selected")) }
        switch row.state {
        case .awaitingApproval: parts.append(String(localized: "Awaiting approval"))
        case .live: parts.append(String(localized: "Agent running"))
        case .failed: parts.append(String(localized: "Last turn failed"))
        case .offline: parts.append(String(localized: "Server unreachable"))
        case .idle: break
        }
        if row.unread { parts.append(String(localized: "Unread")) }
        parts.append(relativeDate(row.entry.session.updatedAt))
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
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

    /// How long ago the chat moved, in a fixed column at the trailing edge rather than at the end
    /// of the second line: staleness is compared down a list, and a number that starts at a
    /// different x on every row cannot be compared at a glance. Monospaced digits so the column
    /// holds even as the figures change under it.
    private static func ageAccessory(_ age: String) -> UICellAccessory {
        let label = UILabel()
        label.text = age
        label.font = UIFontMetrics(forTextStyle: .caption2)
            .scaledFont(for: .monospacedDigitSystemFont(ofSize: 11, weight: .regular))
        label.adjustsFontForContentSizeCategory = true
        label.textColor = Theme.Color.tertiaryLabel
        label.textAlignment = .right
        label.sizeToFit()
        label.frame = CGRect(x: 0, y: 0, width: max(26, label.frame.width), height: 16)
        label.isAccessibilityElement = false
        return .customView(
            configuration: .init(
                customView: label, placement: .trailing(displayed: .always),
                maintainsFixedSize: true))
    }

    private static func dot(_ color: UIColor) -> UICellAccessory {
        let dot = UIView(frame: CGRect(x: 0, y: 0, width: 8, height: 8))
        dot.backgroundColor = color
        dot.layer.cornerRadius = 4
        return .customView(
            configuration: .init(customView: dot, placement: .trailing(displayed: .always)))
    }

    /// The leading server mark takes the state's own tone, so a row that needs you reads amber
    /// from its first pixel to its last. Idle keeps the backend's brand — nothing is happening, so
    /// the only thing worth saying is which agent this is.
    private static func tint(for state: SessionRowState) -> UIColor? {
        state.activity?.icon.tone.color
    }

    private func bind() {
        viewModel.onChange = { [weak self] in
            self?.updateComposeButton()
            self?.rebuildChips()
            self?.updateUnreachableNotice()
            self?.applySnapshot()
        }
        viewModel.onError = { [weak self] message in self?.present(error: message) }
        NotificationCenter.default.addObserver(
            self, selector: #selector(activityDidChange),
            name: SessionActivity.didChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(archiveDidChange),
            name: ArchivedChatStore.didChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(pinDidChange),
            name: SessionPinStore.didChange, object: nil)
    }

    @objc private func pinDidChange() {
        applySnapshot()
    }

    @objc private func archiveDidChange() {
        updateComposeButton()
        applySnapshot()
    }

    @objc private func activityDidChange() {
        reconfigureActivity()
        rebuildChips()
    }

    /// A turn starting or stopping moves the row between sections, not just its pill, so the whole
    /// snapshot is rebuilt rather than the visible cells reloaded — a chat that just went live must
    /// arrive in LIVE NOW, never wear a spinner down in RECENT.
    private func reconfigureActivity() {
        guard dataSource != nil else { return }
        applySnapshot()
    }

    private func updateUnreachableNotice() {
        let names = viewModel.unreachable.compactMap { id in
            viewModel.servers.first(where: { $0.id == id })?.name
        }
        if names.isEmpty {
            unreachableLabel.isHidden = true
            unreachableLabel.text = nil
        } else {
            unreachableLabel.text = String(
                localized: "\(names.joined(separator: ", ")) unreachable — pull to retry")
            unreachableLabel.isHidden = false
        }
    }

    /// Whether the row would land in LIVE NOW, asked the same way `groupIntoSections` asks it, so
    /// the Live chip's count and the section's contents can never disagree. Never re-reads
    /// liveness off the listing alone once this device is watching the turn itself.
    private func isLive(_ entry: SessionEntry) -> Bool {
        switch presence(for: entry) {
        case .running, .awaitingApproval: return true
        case .failed, .unobserved: return entry.session.isWorking
        }
    }

    /// What the chips choose among: the listing with the board's scope already applied, so a
    /// scoped Live count never advertises a turn the board is not showing.
    private func filterableEntries() -> [SessionEntry] {
        guard let scope else { return viewModel.entries }
        return viewModel.entries.filter(scope.matches)
    }

    private func filteredEntries() -> [SessionEntry] {
        let archived = ArchivedChatStore.all()
        var list = viewModel.entries.filter {
            !archived.contains(ArchivedChatStore.key($0.profileID, $0.session.id)) || isLive($0)
        }
        if let scope { list = list.filter(scope.matches) }
        switch filter {
        case .all:
            break
        case .live:
            list = list.filter(isLive)
        case .profile(let id):
            list = list.filter { $0.profileID == id }
        }
        guard !searchQuery.isEmpty else { return list }
        return list.filter {
            $0.session.title.localizedCaseInsensitiveContains(searchQuery)
                || ($0.session.agentTask?.localizedCaseInsensitiveContains(searchQuery) ?? false)
                || ($0.session.directory?.localizedCaseInsensitiveContains(searchQuery) ?? false)
                || $0.profileName.localizedCaseInsensitiveContains(searchQuery)
        }
    }

    /// What this device is watching first-hand, so a row is live the moment a turn starts here
    /// rather than when the server's next sweep agrees, and a turn stopped for an approval says so.
    private func presence(for entry: SessionEntry) -> SessionPresence {
        switch SessionActivity.shared.status(for: entry.session.id) {
        case .running: return .running(SessionActivity.shared.liveDetail(for: entry.session.id))
        case .awaitingApproval: return .awaitingApproval
        case .idle: return .unobserved
        }
    }

    private func rowModel(for entry: SessionEntry, saved: Set<String>, unreachable: Set<String>)
        -> SessionRowModel
    {
        SessionRowModel(
            entry: entry,
            unreachable: unreachable.contains(entry.profileID),
            unread: SessionSeenStore.unreadEvaluator()(entry.session.id, entry.session.updatedAt),
            saved: saved.contains(SessionPinStore.key(entry.profileID, entry.session.id)),
            pinned: SessionPinStore.contains(
                profileID: entry.profileID, sessionID: entry.session.id),
            presence: presence(for: entry))
    }

    /// The listing as the shared `groupIntoSections` groups it — PINNED, LIVE NOW, SAVED, RECENT,
    /// with empty sections dropped so no heading ever sits over nothing. Every row carries the
    /// presence this device knows first-hand, which is what puts the conversation being streamed
    /// right now in LIVE NOW instead of waiting for the server's next sweep to agree.
    private func sectionedRows(for entries: [SessionEntry]) -> [(SessionSection, [SessionRowModel])]
    {
        let saved = Set(SavedChatStore.all().map { SessionPinStore.key($0.profileID, $0.sessionID) })
        let unreachable = Set(viewModel.unreachable)
        return groupIntoSections(
            entries.map { rowModel(for: $0, saved: saved, unreachable: unreachable) })
    }

    /// The flattened order the sections draw becomes `visibleEntries` — the one list the keyboard
    /// cursor, select-all and the held selection all address, because an `IndexPath` into a
    /// sectioned snapshot is not a position a person has.
    private func applySnapshot() {
        let entries = filteredEntries()
        let sections = sectionedRows(for: entries)
        let rows = sections.flatMap(\.1)

        rowModels = Dictionary(
            rows.map { (SessionPinStore.key($0.entry.profileID, $0.entry.session.id), $0) },
            uniquingKeysWith: { first, _ in first })
        vocabulary = ChatListVocabulary(rows: rows)
        visibleEntries = rows.map(\.entry)
        selection.prune(to: visibleEntries)

        var snapshot = NSDiffableDataSourceSnapshot<SessionSection, SessionEntry>()
        for (section, members) in sections {
            snapshot.appendSections([section])
            snapshot.appendItems(members.map(\.entry), toSection: section)
        }
        let existing = Set(dataSource.snapshot().itemIdentifiers)
        let retained = visibleEntries.filter { existing.contains($0) }
        if !retained.isEmpty { snapshot.reconfigureItems(retained) }
        dataSource.apply(snapshot, animatingDifferences: hasAppeared)
        refreshControl.endRefreshing()
        clampKeyCursor()
        updateSelectionBar()
        updateEmptyState(itemCount: snapshot.numberOfItems)
    }

    /// A cursor that outlived the row it pointed at must land somewhere real, not address a row a
    /// re-sort put somewhere else.
    private func clampKeyCursor() {
        guard let keyCursor else { return }
        guard !visibleEntries.isEmpty else {
            self.keyCursor = nil
            return
        }
        self.keyCursor = min(keyCursor, visibleEntries.count - 1)
    }

    private func updateEmptyState(itemCount: Int) {
        if itemCount > 0 {
            contentUnavailableConfiguration = nil
        } else if !hasLoadedOnce, searchQuery.isEmpty {
            contentUnavailableConfiguration = UIContentUnavailableConfiguration.loading()
        } else if !searchQuery.isEmpty {
            contentUnavailableConfiguration = UIContentUnavailableConfiguration.search()
        } else if case .live = filter {
            var config = UIContentUnavailableConfiguration.empty()
            config.image = UIImage(systemName: "moon.zzz")
            config.text = String(localized: "Nothing running")
            config.secondaryText = String(
                localized: "Live sessions show up here the moment an agent starts working.")
            contentUnavailableConfiguration = config
        } else if viewModel.isEmptyOfServers {
            var config = UIContentUnavailableConfiguration.empty()
            config.image = UIImage(systemName: "server.rack")
            config.text = String(localized: "No servers connected")
            config.secondaryText = String(
                localized: "Add a connection in Settings to start chatting with your agents.")
            contentUnavailableConfiguration = config
        } else if viewModel.entries.isEmpty, !viewModel.unreachable.isEmpty {
            var config = UIContentUnavailableConfiguration.empty()
            config.image = UIImage(systemName: "wifi.exclamationmark")
            config.text = String(localized: "Server unreachable")
            config.secondaryText = String(localized: "Pull down to retry the connection.")
            contentUnavailableConfiguration = config
        } else {
            var config = UIContentUnavailableConfiguration.empty()
            config.image = UIImage(systemName: "bubble.left.and.bubble.right")
            config.text = String(localized: "No conversations here yet")
            config.secondaryText = String(localized: "Start one with the compose button.")
            contentUnavailableConfiguration = config
        }
    }

    private func toggleArchived(_ entry: SessionEntry) {
        Theme.Haptics.tap()
        ArchivedChatStore.toggle(profileID: entry.profileID, sessionID: entry.session.id)
    }

    private func togglePinned(_ entry: SessionEntry) {
        Theme.Haptics.tap()
        SessionPinStore.toggle(profileID: entry.profileID, sessionID: entry.session.id)
    }

    private func toggleUnread(_ entry: SessionEntry) {
        Theme.Haptics.tap()
        let unread = SessionSeenStore.unreadEvaluator()(
            entry.session.id, entry.session.updatedAt)
        if unread {
            SessionSeenStore.markSeen(entry.session.id)
        } else {
            SessionSeenStore.markUnread(entry.session.id, updatedAt: entry.session.updatedAt)
        }
        reconfigureActivity()
    }

    private func forkAndOpen(_ entry: SessionEntry) {
        Task { [weak self] in
            guard let self, let forked = await self.viewModel.fork(entry) else { return }
            Theme.Haptics.success()
            self.openChat(for: forked)
        }
    }

    private func promptRename(_ entry: SessionEntry) {
        let alert = UIAlertController(
            title: String(localized: "Rename conversation"), message: nil, preferredStyle: .alert)
        alert.addTextField { field in
            field.text = entry.session.title
            field.clearButtonMode = .whileEditing
            field.autocapitalizationType = .sentences
        }
        alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
        alert.addAction(
            UIAlertAction(title: String(localized: "Rename"), style: .default) {
                [weak self, weak alert] _ in
            let title = alert?.textFields?.first?.text?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !title.isEmpty, title != entry.session.title else { return }
            Theme.Haptics.success()
            Task { await self?.viewModel.rename(entry, to: title) }
        })
        present(alert, animated: true)
    }

    private func confirmDelete(_ entry: SessionEntry, done: @escaping (Bool) -> Void) {
        let alert = UIAlertController(
            title: String(localized: "Delete conversation?"),
            message: String(
                localized:
                    "\"\(Self.displayTitle(entry.session.title))\" will be removed from the server."
            ),
            preferredStyle: .alert)
        alert.addAction(
            UIAlertAction(title: String(localized: "Cancel"), style: .cancel) { _ in done(false) })
        alert.addAction(
            UIAlertAction(title: String(localized: "Delete"), style: .destructive) { [weak self] _ in
            Theme.Haptics.warning()
            Task {
                await self?.viewModel.delete(entry)
                done(true)
            }
        })
        present(alert, animated: true)
    }

    static func displayTitle(_ title: String) -> String {
        guard AgentSession.isPlaceholderTitle(title) else {
            return title.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? String(localized: "Empty conversation") : String(localized: "New conversation")
    }

    private static func relativeDate(_ date: Date) -> String {
        let now = Date()
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            let diff = now.timeIntervalSince(date)
            if diff < 60 { return String(localized: "Just now") }
            if diff < 3600 { return String(localized: "\(Int(diff / 60))m ago") }
            return date.formatted(.dateTime.hour().minute())
        }
        if calendar.isDateInYesterday(date) { return String(localized: "Yesterday") }
        if calendar.isDate(date, equalTo: now, toGranularity: .weekOfYear) {
            return date.formatted(.dateTime.weekday(.wide))
        }
        return date.formatted(.dateTime.month(.abbreviated).day())
    }

    private static func serverIcon(for backend: AgentType) -> UIImage? {
        UIImage(systemName: backend.symbolName)?
            .withTintColor(backend.brandColor, renderingMode: .alwaysOriginal)
    }

    /// The row's own word for what it is doing, taken from `SessionRowState.pill` so the phone
    /// says NEEDS YOU where the desktops say NEEDS YOU, wearing the same symbol and the same
    /// motion the desks give it: a running turn breathes, a turn stopped for you knocks twice, a
    /// failure holds still. Idle is silence, never a pill reading "idle".
    ///
    /// A running turn is the badge alone. It is the state a list has most of, and a row of capsules
    /// reading LIVE down the whole screen is a wall of words where a moving dot is a glance.
    private static func statusPill(for state: SessionRowState) -> UICellAccessory? {
        guard let activity = state.activity else { return nil }
        let badge = ActivityBadgeView(pointSize: 11)
        badge.activity = activity
        guard let pill = state.pill, state != .live else {
            badge.frame = CGRect(x: 0, y: 0, width: 22, height: 22)
            return .customView(
                configuration: .init(
                    customView: badge, placement: .trailing(displayed: .always),
                    maintainsFixedSize: true))
        }
        let color = activity.icon.tone.color
        let label = UILabel()
        label.text = pill.text
        label.font = UIFontMetrics(forTextStyle: .caption2)
            .scaledFont(for: .systemFont(ofSize: 10, weight: .bold))
        label.adjustsFontForContentSizeCategory = true
        label.textColor = color
        label.sizeToFit()
        let padH: CGFloat = 7
        let padV: CGFloat = 3
        let margin: CGFloat = 8
        let glyphWidth: CGFloat = 15
        let capsule = UIView(
            frame: CGRect(
                x: margin, y: 0, width: label.bounds.width + glyphWidth + padH * 2,
                height: label.bounds.height + padV * 2))
        badge.frame = CGRect(
            x: padH - 1, y: 0, width: glyphWidth, height: capsule.bounds.height)
        label.frame.origin = CGPoint(x: padH + glyphWidth, y: padV)
        capsule.addSubview(badge)
        capsule.addSubview(label)
        capsule.backgroundColor = UIColor { traits in
            color.withAlphaComponent(0.15)
                .blended(over: Theme.Color.secondaryBackground, traits: traits)
        }
        capsule.layer.cornerRadius = capsule.bounds.height / 2
        capsule.layer.cornerCurve = .continuous
        capsule.isAccessibilityElement = true
        capsule.accessibilityLabel = activity.spoken
        badge.isAccessibilityElement = false
        let wrapper = UIView(
            frame: CGRect(
                x: 0, y: 0, width: capsule.bounds.width + margin + 6,
                height: capsule.bounds.height))
        wrapper.addSubview(capsule)
        return .customView(
            configuration: .init(
                customView: wrapper, placement: .trailing(displayed: .always),
                maintainsFixedSize: true))
    }

    @objc private func refresh() { Task { await viewModel.load() } }

    private func startChat(on profile: ConnectionProfile) {
        Theme.Haptics.tap()
        NewChatFlow.begin(from: self, profile: profile, viewModel: viewModel) { [weak self] entry in
            self?.openChat(for: entry)
        }
    }

    /// The board's own compose skips both questions — the scope already answered them. The mint
    /// happens straight away, exactly as choosing this server and this folder in the sheet would.
    private func startChatInScope() {
        guard let scope,
            let profile = viewModel.servers.first(where: { $0.id == scope.profileID })
        else { return }
        Theme.Haptics.tap()
        Task {
            guard let entry = await viewModel.newSession(on: profile, directory: scope.directory)
            else {
                Theme.Haptics.error()
                return
            }
            Theme.Haptics.success()
            openChat(for: entry)
        }
    }

    /// A container opens a container: the board is this same listing, scoped. Leaving it is a
    /// plain pop, so the whole list is exactly where it was.
    private func openProjectBoard(_ scope: ProjectScope) {
        Theme.Haptics.tap()
        navigationController?.pushViewController(
            SessionListViewController(scope: scope), animated: true)
    }

    /// A result opens the conversation it names, on the server it happened on. The listing may not
    /// carry it — a chat this device has not listed lately — so one the list cannot resolve says so
    /// instead of doing nothing.
    private func openSearchResult(profileID: String, sessionID: String) {
        guard let entry = viewModel.entries.first(where: {
            $0.profileID == profileID && $0.session.id == sessionID
        }) else {
            Theme.Haptics.warning()
            let alert = UIAlertController(
                title: String(localized: "Not in the listing"),
                message: String(
                    localized: "That chat is not in this server's listing right now."),
                preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
            present(alert, animated: true)
            return
        }
        navigationController?.popViewController(animated: false)
        SessionSeenStore.markSeen(entry.session.id)
        openChat(for: entry)
    }

    private func openChat(for entry: SessionEntry) {
        guard let backend = viewModel.backend(for: entry) else { return }
        let chatViewModel =
            SessionActivity.shared.retainedViewModel(
                for: entry.session.id, contextID: entry.profileID)
            ?? ChatViewModel(
                backend: backend, session: entry.session, contextID: entry.profileID,
                serverName: entry.profileName)
        let chat = ChatViewController(viewModel: chatViewModel)
        navigationController?.pushViewController(chat, animated: true)
    }

    #if DEBUG
        var tourScrollView: UIScrollView { collectionView }

        func tourSelect(_ count: Int) {
            setSelecting(true)
            for entry in visibleEntries.prefix(count) { selection.insert(entry) }
            updateSelectionBar()
            refreshVisibleRows()
        }

        func tourNewChat() {
            guard let profile = viewModel.servers.first else { return }
            startChat(on: profile)
        }

        func tourOpen(_ sessionID: String) {
            guard let entry = viewModel.entries.first(where: { $0.session.id == sessionID })
            else { return }
            SessionSeenStore.markSeen(sessionID)
            openChat(for: entry)
        }
    #endif

    private func present(error message: String) {
        refreshControl.endRefreshing()
        let alert = UIAlertController(
            title: String(localized: "Something went wrong"), message: message,
            preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
        present(alert, animated: true)
    }
}

extension SessionListViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let entry = dataSource.itemIdentifier(for: indexPath) else { return }
        keyCursor = visibleEntries.firstIndex(of: entry)
        guard !isSelecting else {
            toggleMark(entry)
            return
        }
        openChat(for: entry)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard !isSelecting, let indexPath = indexPaths.first,
            let entry = dataSource.itemIdentifier(for: indexPath)
        else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) {
            [weak self] _ in
            guard let self else { return UIMenu() }
            var actions: [UIMenuElement] = []
            if let directory = entry.session.directory,
                let profile = self.viewModel.servers.first(where: { $0.id == entry.profileID })
            {
                actions.append(
                    UIAction(
                        title: String(localized: "New chat in same project"),
                        image: UIImage(systemName: "plus.bubble")
                    ) { [weak self] _ in
                        Task {
                            guard let self,
                                let new = await self.viewModel.newSession(
                                    on: profile, directory: directory)
                            else { return }
                            Theme.Haptics.success()
                            self.openChat(for: new)
                        }
                    })
            }
            if self.scope == nil {
                let rowScope = ProjectScope(of: entry)
                actions.append(
                    UIAction(
                        title: String(localized: "Only this project"),
                        subtitle: rowScope.banner(serverName: entry.profileName),
                        image: UIImage(systemName: "folder")
                    ) { [weak self] _ in
                        self?.openProjectBoard(rowScope)
                    })
            }
            let isSaved = SavedChatStore.contains(entry)
            actions.append(
                UIAction(
                    title: isSaved
                        ? String(localized: "Remove from Saved") : String(localized: "Save chat"),
                    image: UIImage(systemName: isSaved ? "bookmark.slash" : "bookmark")
                ) { _ in
                    Theme.Haptics.tap()
                    SavedChatStore.toggle(entry)
                })
            let isArchived = ArchivedChatStore.contains(
                profileID: entry.profileID, sessionID: entry.session.id)
            actions.append(
                UIAction(
                    title: isArchived
                        ? String(localized: "Unarchive") : String(localized: "Archive"),
                    subtitle: isArchived
                        ? String(localized: "Back into the chat list")
                        : String(localized: "Out of the list, kept on the server"),
                    image: UIImage(systemName: isArchived ? "tray.and.arrow.up" : "archivebox")
                ) { [weak self] _ in
                    self?.toggleArchived(entry)
                })
            let isPinned = SessionPinStore.contains(
                profileID: entry.profileID, sessionID: entry.session.id)
            actions.append(
                UIAction(
                    title: isPinned ? String(localized: "Unpin") : String(localized: "Pin"),
                    subtitle: isPinned
                        ? String(localized: "Back into the recency order")
                        : String(localized: "Always at the top of the chat list"),
                    image: UIImage(systemName: isPinned ? "pin.slash" : "pin")
                ) { [weak self] _ in
                    self?.togglePinned(entry)
                })
            let isUnread = SessionSeenStore.unreadEvaluator()(
                entry.session.id, entry.session.updatedAt)
            actions.append(
                UIAction(
                    title: isUnread
                        ? String(localized: "Mark as read") : String(localized: "Mark as unread"),
                    image: UIImage(systemName: isUnread ? "envelope.open" : "envelope.badge")
                ) { [weak self] _ in
                    self?.toggleUnread(entry)
                })
            if self.viewModel.supportsRenaming(entry) {
                actions.append(
                    UIAction(
                        title: String(localized: "Rename"), image: UIImage(systemName: "pencil")
                    ) {
                        [weak self] _ in
                        self?.promptRename(entry)
                    })
            }
            if self.viewModel.supportsForking(entry) {
                actions.append(
                    UIAction(
                        title: String(localized: "Fork"),
                        subtitle: String(
                            localized: "A new session with this history, for a different direction"),
                        image: UIImage(systemName: "arrow.triangle.branch")
                    ) { [weak self] _ in
                        self?.forkAndOpen(entry)
                    })
            }
            actions.append(
                UIAction(
                    title: String(localized: "Copy title"),
                    image: UIImage(systemName: "doc.on.doc")
                ) { _ in
                    UIPasteboard.general.string = entry.session.title
                    Theme.Haptics.success()
                })
            if self.viewModel.supportsMultipleSessions(entry) {
                actions.append(
                    UIAction(
                        title: String(localized: "Delete"), image: UIImage(systemName: "trash"),
                        attributes: .destructive
                    ) { [weak self] _ in
                        self?.confirmDelete(entry) { _ in }
                    })
            }
            return UIMenu(children: actions)
        }
    }
}

extension SessionListViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        searchQuery = searchController.searchBar.text?.trimmingCharacters(in: .whitespaces) ?? ""
        applySnapshot()
    }
}

/// The search bar narrows the rows it already holds while it is typed in, and searches what was
/// actually said when it is submitted. The two are different questions and the second one takes a
/// network, so it gets a screen of its own rather than replacing the list under the keyboard.
extension SessionListViewController: UISearchBarDelegate {
    func searchBarSearchButtonClicked(_ searchBar: UISearchBar) {
        let query = searchBar.text?.trimmingCharacters(in: .whitespaces) ?? ""
        guard TranscriptSearch.isSearchable(query) else { return }
        Theme.Haptics.tap()
        searchBar.resignFirstResponder()
        let entries = viewModel.entries
        let sources = viewModel.servers.compactMap { profile in
            viewModel.backend(forProfileID: profile.id).map {
                TranscriptSearch.Source(
                    profileID: profile.id,
                    name: ServerLabel.display(name: profile.name, backend: profile.backend),
                    backend: $0,
                    entries: entries.filter { $0.profileID == profile.id })
            }
        }
        navigationController?.pushViewController(
            TranscriptSearchViewController(query: query, sources: sources) { [weak self] profileID, sessionID in
                self?.openSearchResult(profileID: profileID, sessionID: sessionID)
            }, animated: true)
    }
}

final class FileBrowserViewController: UIViewController {
    var onSelect: ((String) -> Void)?

    private enum Section: CaseIterable { case favorites, recents, files }

    private let backend: any FileBrowsingBackend
    private let profileID: String
    private let path: String
    private var hasAppeared = false
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, FileItem>!
    private var isFavorite: Bool { FileBrowserFavorites.isFavorite(path, for: profileID) }

    private enum FileItem: Hashable {
        case favorite(String)
        case recent(String)
        case node(FileNode)
    }

    init(backend: any FileBrowsingBackend, profileID: String, path: String = ".") {
        self.backend = backend
        self.profileID = profileID
        self.path = path
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = path == "." ? String(localized: "Files") : (path as NSString).lastPathComponent
        view.backgroundColor = Theme.Color.groupedBackground
        configureNavBar()
        configureCollectionView()
        configureDataSource()
        Task { await load() }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if hasAppeared { Task { await load() } }
        hasAppeared = true
    }

    private func configureNavBar() {
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: String(localized: "Select"), style: .done, target: self,
            action: #selector(selectTapped))
        let favImage = isFavorite ? "star.fill" : "star"
        let favButton = UIBarButtonItem(
            image: UIImage(systemName: favImage), style: .plain, target: self,
            action: #selector(toggleFavorite))
        favButton.tintColor = isFavorite ? Theme.Color.special : nil
        if path != "." {
            navigationItem.rightBarButtonItems = [navigationItem.rightBarButtonItem!, favButton]
        }
        if navigationController?.viewControllers.first === self {
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                barButtonSystemItem: .cancel, target: self, action: #selector(cancelTapped))
        }
    }

    private func configureCollectionView() {
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.showsSeparators = false
        config.headerMode = .supplementary
        config.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            guard let self, let item = self.dataSource.itemIdentifier(for: indexPath) else {
                return nil
            }
            let stalePath: String
            switch item {
            case .favorite(let path): stalePath = path
            case .recent(let path): stalePath = path
            case .node: return nil
            }
            let remove = UIContextualAction(
                style: .destructive, title: String(localized: "Remove")
            ) {
                [weak self] _, _, done in
                guard let self else { return done(false) }
                if case .favorite = item {
                    FileBrowserFavorites.remove(stalePath, for: self.profileID)
                } else {
                    FileBrowserRecents.remove(stalePath, for: self.profileID)
                }
                Task {
                    await self.load()
                    done(true)
                }
            }
            return UISwipeActionsConfiguration(actions: [remove])
        }
        let layout = UICollectionViewCompositionalLayout.list(using: config)
        collectionView = UICollectionView(frame: .zero, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.refreshControl = UIRefreshControl()
        collectionView.refreshControl?.addTarget(self, action: #selector(refreshTapped), for: .valueChanged)
        view.addSubview(collectionView)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    private func configureDataSource() {
        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, FileItem> {
            [weak self] cell, _, item in
            guard self != nil else { return }
            var content = UIListContentConfiguration.subtitleCell()
            switch item {
            case .favorite(let favPath):
                content.text = (favPath as NSString).lastPathComponent
                content.secondaryText = favPath
                content.image = UIImage(systemName: "star.fill")
                content.imageProperties.tintColor = Theme.Color.special
                content.secondaryTextProperties.font = .preferredFont(forTextStyle: .caption2)
                content.secondaryTextProperties.color = Theme.Color.tertiaryLabel
            case .recent(let recentPath):
                content.text = (recentPath as NSString).lastPathComponent
                content.secondaryText = recentPath
                content.image = UIImage(systemName: "clock")
                content.imageProperties.tintColor = Theme.Color.secondaryLabel
                content.secondaryTextProperties.font = .preferredFont(forTextStyle: .caption2)
                content.secondaryTextProperties.color = Theme.Color.tertiaryLabel
            case .node(let node):
                content.text = node.name
                if node.isDirectory {
                    content.image = UIImage(systemName: "folder.fill")
                    content.imageProperties.tintColor = Theme.Color.accent
                    cell.accessories = [.disclosureIndicator()]
                } else {
                    content.image = UIImage(systemName: "doc")
                    content.imageProperties.tintColor = Theme.Color.tertiaryLabel
                    content.textProperties.color = Theme.Color.tertiaryLabel
                    cell.accessories = []
                }
            }
            content.textProperties.font = Theme.Font.body()
            cell.contentConfiguration = content
        }

        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            guard let self else { return }
            let sections = self.dataSource.snapshot().sectionIdentifiers
            guard sections.indices.contains(indexPath.section) else { return }
            let section = sections[indexPath.section]
            var content = UIListContentConfiguration.prominentInsetGroupedHeader()
            switch section {
            case .favorites: content.text = String(localized: "Favorites")
            case .recents: content.text = String(localized: "Recent")
            case .files: content.text = String(localized: "Files")
            }
            view.contentConfiguration = content
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
            collectionView, indexPath, item in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: item)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
    }

    private func load() async {
        if dataSource.snapshot().numberOfItems == 0 {
            contentUnavailableConfiguration = UIContentUnavailableConfiguration.loading()
        }
        defer { collectionView.refreshControl?.endRefreshing() }
        do {
            let nodes = try await backend.listFiles(path: path)
                .sorted { a, b in
                    if a.isDirectory != b.isDirectory { return a.isDirectory }
                    return a.name.localizedStandardCompare(b.name) == .orderedAscending
                }
            if path != "." { FileBrowserRecents.record(path, for: profileID) }
            var snapshot = NSDiffableDataSourceSnapshot<Section, FileItem>()
            if path == "." {
                let favs = FileBrowserFavorites.all(for: profileID)
                if !favs.isEmpty {
                    snapshot.appendSections([.favorites])
                    snapshot.appendItems(favs.map { .favorite($0) }, toSection: .favorites)
                }
                let recents = FileBrowserRecents.all(for: profileID)
                if !recents.isEmpty {
                    snapshot.appendSections([.recents])
                    snapshot.appendItems(recents.map { .recent($0) }, toSection: .recents)
                }
            }
            snapshot.appendSections([.files])
            snapshot.appendItems(nodes.map { .node($0) }, toSection: .files)
            let empty = snapshot.numberOfItems == 0
            await dataSource.apply(snapshot, animatingDifferences: false)
            if empty {
                var config = UIContentUnavailableConfiguration.empty()
                config.image = UIImage(systemName: "folder")
                config.text = String(localized: "Empty folder")
                contentUnavailableConfiguration = config
            } else {
                contentUnavailableConfiguration = nil
            }
        } catch {
            AppLogger.ui.error(
                "file browser load failed for \(path): \(SessionListViewModel.readable(error))")
            if dataSource.snapshot().numberOfItems == 0 {
                var config = UIContentUnavailableConfiguration.empty()
                config.image = UIImage(systemName: "exclamationmark.triangle")
                config.text = String(localized: "Couldn't load files")
                config.secondaryText = SessionListViewModel.readable(error)
                var buttonConfig = UIButton.Configuration.borderedProminent()
                buttonConfig.title = String(localized: "Retry")
                config.button = buttonConfig
                config.buttonProperties.primaryAction = UIAction { [weak self] _ in
                    Task { await self?.load() }
                }
                contentUnavailableConfiguration = config
            } else {
                contentUnavailableConfiguration = nil
                let alert = UIAlertController(
                    title: String(localized: "Error"), message: error.localizedDescription,
                    preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .default))
                present(alert, animated: true)
            }
        }
    }

    @objc private func selectTapped() {
        onSelect?(path)
    }

    @objc private func toggleFavorite() {
        FileBrowserFavorites.toggle(path, for: profileID)
        configureNavBar()
    }

    @objc private func cancelTapped() {
        dismiss(animated: true)
    }

    @objc private func refreshTapped() {
        Task { await load() }
    }
}

extension FileBrowserViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        switch item {
        case .favorite(let favPath), .recent(let favPath):
            let vc = FileBrowserViewController(backend: backend, profileID: profileID, path: favPath)
            vc.onSelect = onSelect
            navigationController?.pushViewController(vc, animated: true)
        case .node(let node):
            if node.isDirectory {
                let vc = FileBrowserViewController(
                    backend: backend, profileID: profileID, path: node.path)
                vc.onSelect = onSelect
                navigationController?.pushViewController(vc, animated: true)
            }
        }
    }
}

extension SessionListViewController: KeyActionHost {
    var keyContext: KeyContext {
        searchController.searchBar.searchTextField.isFirstResponder ? .insert : .normal
    }

    /// The chat list's answers to the shared registry: J/K walk a visible cursor, Enter opens
    /// it, and every row verb acts on the row under the cursor — the desktops' sidebar keys,
    /// spoken through this screen. False lets a press fall through.
    func performKeyAction(_ action: KeyAction) -> Bool {
        switch action {
        case .selectNext:
            moveCursor(by: 1)
        case .selectPrevious:
            moveCursor(by: -1)
        case .selectFirst:
            moveCursor(to: 0)
        case .selectLast:
            moveCursor(to: max(0, visibleEntries.count - 1))
        case .openSelected:
            guard let entry = cursorEntry() else { return false }
            guard !isSelecting else {
                toggleMark(entry)
                return true
            }
            SessionSeenStore.markSeen(entry.session.id)
            openChat(for: entry)
        case .scrollDown:
            moveCursor(by: 1)
        case .scrollUp:
            moveCursor(by: -1)
        case .halfPageDown:
            moveCursor(by: 8)
        case .halfPageUp:
            moveCursor(by: -8)
        case .search:
            searchController.isActive = true
            searchController.searchBar.searchTextField.becomeFirstResponder()
        case .leaveInsert:
            if !selection.isEmpty {
                selection.clear()
                updateSelectionBar()
                refreshVisibleRows()
                return true
            }
            if isSelecting {
                setSelecting(false)
                return true
            }
            guard searchController.isActive else { return false }
            searchController.isActive = false
            becomeFirstResponder()
        case .newChat:
            guard let profile = preferredServer() else { return false }
            startChat(on: profile)
        case .toggleSaved:
            guard let entry = cursorEntry() else { return false }
            Theme.Haptics.tap()
            SavedChatStore.toggle(entry)
        case .archiveSelected:
            guard let entry = cursorEntry() else { return false }
            toggleArchived(entry)
        case .toggleArchiveView:
            pushArchived()
        case .toggleUnreadSelected:
            guard let entry = cursorEntry() else { return false }
            toggleUnread(entry)
        case .renameSelected:
            guard let entry = cursorEntry(), viewModel.supportsRenaming(entry) else {
                return false
            }
            promptRename(entry)
        case .forkSelected:
            guard let entry = cursorEntry(), viewModel.supportsForking(entry) else {
                return false
            }
            forkAndOpen(entry)
        case .toggleMarked:
            guard let entry = cursorEntry() else { return false }
            if !isSelecting { setSelecting(true) }
            toggleMark(entry)
        case .toggleMarkAll:
            guard !visibleEntries.isEmpty else { return false }
            if !isSelecting { setSelecting(true) }
            toggleMarkAll()
        case .deleteSelected:
            let marked = targets(for: .delete, in: selection.resolve(in: visibleEntries))
            guard marked.isEmpty else {
                confirmBulkDelete(marked)
                return true
            }
            guard let entry = cursorEntry(), viewModel.supportsMultipleSessions(entry) else {
                return false
            }
            confirmDelete(entry) { _ in }
        case .copySessionID:
            guard let entry = cursorEntry() else { return false }
            UIPasteboard.general.string = entry.session.id
            Theme.Haptics.success()
        case .copyProjectPath:
            guard let entry = cursorEntry(), let directory = entry.session.directory else {
                return false
            }
            UIPasteboard.general.string = directory
            Theme.Haptics.success()
        case .reload:
            Task { await viewModel.load() }
        case .toggleProjectScope:
            if scope != nil {
                navigationController?.popViewController(animated: true)
                return true
            }
            guard let entry = cursorEntry() else { return false }
            openProjectBoard(ProjectScope(of: entry))
        case .toggleHelp:
            ShortcutCheatsheetViewController.present(from: self)
        default:
            return false
        }
        return true
    }

    /// The cursor is a flat position over every row on screen, not an offset into one section: a
    /// pinned chat or a LIVE NOW heading used to leave the keyboard verbs acting on a row the
    /// person was not looking at. Never addresses a snapshot by a hardcoded section.
    private func cursorEntry() -> SessionEntry? {
        guard let keyCursor, visibleEntries.indices.contains(keyCursor) else { return nil }
        return visibleEntries[keyCursor]
    }

    private func moveCursor(by delta: Int) {
        let count = visibleEntries.count
        guard count > 0 else { return }
        moveCursor(to: max(0, min(count - 1, (keyCursor ?? (delta > 0 ? -1 : count)) + delta)))
    }

    private func moveCursor(to index: Int) {
        guard visibleEntries.indices.contains(index) else { return }
        keyCursor = index
        guard let indexPath = dataSource.indexPath(for: visibleEntries[index]) else { return }
        collectionView.selectItem(
            at: indexPath, animated: true, scrollPosition: .centeredVertically)
    }

    /// The machine a new chat opens on before anyone chooses: the one the last chat was started
    /// on, since one machine is the overwhelmingly common answer and the modal can still switch.
    /// Never asks the server question ahead of the modal that already asks it.
    private func preferredServer() -> ConnectionProfile? {
        let remembered = AppPreferences.lastComposeTarget?.profileID
        return viewModel.servers.first { $0.id == remembered } ?? viewModel.servers.first
    }
}
