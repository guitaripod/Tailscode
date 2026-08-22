import TailscodeCore
import UIKit

/// Asking for a video, and watching it be made.
///
/// Everything on this screen is `ForgeBoard`'s: the four sections, their order, every word in every
/// row, what pressing one means and what the button at the bottom says it would do. The controller
/// draws them and does the two things a board cannot — open a text field, and put a finished clip
/// on screen — so the phone, the Mac and the Linux desktop cannot end up describing the same render
/// differently.
///
/// The render itself is `ForgeRunner`'s, not this screen's: a clip is minutes of another machine's
/// card, and a phone goes in a pocket halfway through. Backing out and coming back finds the same
/// render exactly where it was.
@MainActor
final class VideoForgeViewController: UIViewController {
    private enum Item: Hashable {
        case row(String)
        /// The standing fact under the renderer: where a render actually happens. It is the board's
        /// sentence, but it belongs to no row, so it is the one item this screen adds.
        case notice
    }

    private let runner = ForgeRunner.shared
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<String, Item>!
    private let dock = Theme.Glass.view()
    private let call = UIButton(type: .system)
    private let refresher = UIRefreshControl()

    private var index: [String: ForgeRow] = [:]
    private var applied: [Item: Int] = [:]
    /// Which words row is under a finger. A board that restates itself several times a second
    /// while a render runs must not reconfigure the cell somebody is typing into.
    private var editingRowID: String?
    private var stageClip: (asset: ForgeAsset, url: URL)?
    private var stageFailure: String?
    private var locating: Task<Void, Never>?
    private var locatingAsset: ForgeAsset?
    private var muted = true

    private var board: ForgeBoard { runner.board }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = board.heading
        view.backgroundColor = Theme.Color.groupedBackground
        configureCollectionView()
        configureDock()
        configureDataSource()
        NotificationCenter.default.addObserver(
            self, selector: #selector(boardDidChange), name: ForgeRunner.didChange, object: nil)
        apply(animated: false)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        guard !runner.isRendering else { return }
        runner.probe()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        #if DEBUG
            scrollForVerification()
        #endif
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        runner.rememberRecipe()
    }

    private func configureCollectionView() {
        var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        configuration.headerMode = .supplementary
        configuration.backgroundColor = .clear
        configuration.trailingSwipeActionsConfigurationProvider = { [weak self] indexPath in
            self?.swipeActions(at: indexPath)
        }
        collectionView = UICollectionView(
            frame: .zero,
            collectionViewLayout: UICollectionViewCompositionalLayout.list(using: configuration))
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.keyboardDismissMode = .interactive
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        refresher.addAction(
            UIAction { [weak self] _ in
                self?.runner.probe()
                self?.refresher.endRefreshing()
            }, for: .valueChanged)
        collectionView.refreshControl = refresher
        view.addSubview(collectionView)
    }

    /// One button, four meanings, and the board decides which one it is wearing. It rides the
    /// keyboard so a prompt typed to the end is one press from being rendered.
    private func configureDock() {
        dock.translatesAutoresizingMaskIntoConstraints = false
        call.translatesAutoresizingMaskIntoConstraints = false
        call.addAction(
            UIAction { [weak self] _ in self?.callTapped() }, for: .touchUpInside)
        view.addSubview(dock)
        dock.contentView.addSubview(call)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: dock.topAnchor),
            dock.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            dock.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            dock.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            call.topAnchor.constraint(equalTo: dock.contentView.topAnchor, constant: Theme.Spacing.s),
            call.bottomAnchor.constraint(
                equalTo: dock.contentView.bottomAnchor, constant: -Theme.Spacing.s),
            call.leadingAnchor.constraint(
                equalTo: dock.contentView.leadingAnchor, constant: Theme.Spacing.l),
            call.trailingAnchor.constraint(
                equalTo: dock.contentView.trailingAnchor, constant: -Theme.Spacing.l),
        ])
        updateCall()
    }

    private func configureDataSource() {
        let stage = UICollectionView.CellRegistration<ForgeStageCell, Item> {
            [weak self] cell, _, _ in
            guard let self, let row = self.board.rows.first(where: { $0.kind == .job }) else {
                return
            }
            cell.apply(
                ForgeStageReading(
                    row: row, job: self.board.job, size: self.board.recipe.size,
                    clip: self.stageClip?.url, clipFailure: self.stageFailure, muted: self.muted))
            cell.onOpenClip = { [weak self] in self?.openStageClip() }
            cell.onToggleSound = { [weak self] in self?.toggleSound() }
        }
        let value = UICollectionView.CellRegistration<ForgeValueCell, Item> {
            [weak self] cell, _, item in
            guard let self, let row = self.row(for: item), case .field(let field) = row.kind else {
                return
            }
            cell.apply(
                row, field: field, tone: self.tone(of: row), activity: self.activity(of: row))
        }
        let words = UICollectionView.CellRegistration<ForgeWordsCell, Item> {
            [weak self] cell, _, item in
            guard let self, let row = self.row(for: item), case .field(let field) = row.kind else {
                return
            }
            let typed = field == .prompt ? self.board.recipe.prompt : self.board.recipe.negative
            cell.apply(row, field: field, words: typed, hint: self.board.value(of: field))
            cell.onEdit = { [weak self] text in self?.type(text, into: field) }
            cell.onFocus = { [weak self] focused in
                self?.editingRowID = focused ? row.id : nil
            }
        }
        let clip = UICollectionView.CellRegistration<ForgeClipCell, Item> {
            [weak self] cell, _, item in
            guard let self, let row = self.row(for: item), let entry = row.entry else { return }
            cell.apply(row, entry: entry, gone: self.goneWords(for: entry))
        }
        let note = UICollectionView.CellRegistration<ForgeNoteCell, Item> {
            [weak self] cell, _, item in
            guard let self else { return }
            switch item {
            case .notice:
                cell.apply(self.board.notice, tone: .quiet)
            case .row:
                guard let row = self.row(for: item) else { return }
                cell.apply(row.title, tone: self.tone(of: row))
            }
        }
        let expander = UICollectionView.CellRegistration<ForgeExpanderCell, Item> {
            [weak self] cell, _, item in
            guard let self, let row = self.row(for: item), case .expander(let id) = row.kind else {
                return
            }
            cell.apply(row, expanded: self.board.expanded.contains(id))
        }

        dataSource = UICollectionViewDiffableDataSource<String, Item>(
            collectionView: collectionView
        ) { [weak self] view, indexPath, item in
            guard let self, case .row = item, let row = self.row(for: item) else {
                return view.dequeueConfiguredReusableCell(using: note, for: indexPath, item: item)
            }
            switch row.kind {
            case .job:
                return view.dequeueConfiguredReusableCell(using: stage, for: indexPath, item: item)
            case .field(let field):
                guard field == .prompt || field == .negative else {
                    return view.dequeueConfiguredReusableCell(
                        using: value, for: indexPath, item: item)
                }
                return view.dequeueConfiguredReusableCell(using: words, for: indexPath, item: item)
            case .clip:
                return view.dequeueConfiguredReusableCell(using: clip, for: indexPath, item: item)
            case .expander:
                return view.dequeueConfiguredReusableCell(
                    using: expander, for: indexPath, item: item)
            case .note:
                return view.dequeueConfiguredReusableCell(using: note, for: indexPath, item: item)
            }
        }

        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] cell, _, indexPath in
            guard let self, let id = self.dataSource.sectionIdentifier(for: indexPath.section),
                let section = self.board.sections.first(where: { $0.id == id })
            else { return }
            var content = cell.defaultContentConfiguration()
            content.text = section.title
            content.secondaryText = self.headerDetail(of: section)
            content.textProperties.font = Theme.Ramp.font(.rowTitleStrong)
            content.secondaryTextProperties.font = Theme.Ramp.font(.panelFootnote)
            content.secondaryTextProperties.color = Theme.Color.tertiaryLabel
            content.prefersSideBySideTextAndSecondaryText = true
            cell.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { view, _, indexPath in
            view.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
    }

    /// A section's own detail, minus the two the rest of this screen already says. The render's
    /// detail is the button at the bottom, and the settings' is the line under the stage; printing
    /// either twice would make a reader look for a difference that is not there.
    private func headerDetail(of section: ForgeSection) -> String? {
        guard section.id != ForgeBoard.renderID, section.id != ForgeBoard.settingsID else {
            return nil
        }
        return section.detail.isEmpty ? nil : section.detail
    }

    private func row(for item: Item) -> ForgeRow? {
        guard case .row(let id) = item else { return nil }
        return index[id]
    }

    /// What colour a row's words are worn in, taken from the phase of the section it belongs to
    /// rather than from the row: a machine that did not answer failed its whole section, and every
    /// line in it — the address, its sentence, the note under it — says so together.
    private func tone(of row: ForgeRow) -> ActivityTone {
        switch board.sections.first(where: { $0.id == row.sectionID })?.phase {
        case .failed: return .danger
        case .ready: return row.sectionID == ForgeBoard.rendererID ? .live : .quiet
        case .checking, .idle, nil: return .quiet
        }
    }

    /// The one row that can be mid-question. A machine being asked whether it is there is work,
    /// and work in this app has a face that moves rather than a label that sits still.
    private func activity(of row: ForgeRow) -> ActivityKind? {
        guard row.sectionID == ForgeBoard.rendererID, board.isChecking else { return nil }
        return .connecting
    }

    private func goneWords(for entry: ForgeEntry) -> String? {
        guard runner.isMissing(entry), let host = runner.endpoint?.host else { return nil }
        return ForgeFailure.missingFile(host).description
    }

    @objc private func boardDidChange() {
        apply(animated: true)
    }

    private func apply(animated: Bool) {
        index = Dictionary(board.rows.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        syncStageClip()
        var snapshot = NSDiffableDataSourceSnapshot<String, Item>()
        for section in board.sections {
            snapshot.appendSections([section.id])
            var items = section.rows.map { Item.row($0.id) }
            if section.id == ForgeBoard.rendererID { items.append(.notice) }
            snapshot.appendItems(items, toSection: section.id)
        }
        let previous = dataSource.snapshot()
        let existing = Set(previous.itemIdentifiers)
        var content: [Item: Int] = [:]
        var stale: [Item] = []
        for item in snapshot.itemIdentifiers {
            let mark = signature(item)
            content[item] = mark
            guard existing.contains(item), applied[item] != mark else { continue }
            if case .row(let id) = item, id == editingRowID { continue }
            stale.append(item)
        }
        applied = content
        if !stale.isEmpty { snapshot.reconfigureItems(stale) }
        dataSource.apply(
            snapshot,
            animatingDifferences: animated && view.window != nil
                && previous.sectionIdentifiers != snapshot.sectionIdentifiers)
        updateCall()
    }

    /// Everything a row would draw, folded to one number, so a frame off the socket redraws the
    /// rows that moved and nothing else. The elapsed reading is deliberately absent: it ages on the
    /// stage's own clock, and folding it in here would reconfigure the whole card once a second.
    private func signature(_ item: Item) -> Int {
        var hasher = Hasher()
        switch item {
        case .notice:
            hasher.combine(board.notice)
        case .row(let id):
            guard let row = index[id] else { break }
            hasher.combine(row.title)
            hasher.combine(row.detail)
            hasher.combine(row.badge)
            hasher.combine(row.note)
            hasher.combine(row.fraction)
            hasher.combine(row.isActivatable)
            hasher.combine(activity(of: row) != nil)
            if case .job = row.kind {
                hasher.combine(stageClip?.url)
                hasher.combine(stageFailure)
                hasher.combine(muted)
                hasher.combine(board.recipe.size)
            }
            if case .expander(let section) = row.kind {
                hasher.combine(board.expanded.contains(section))
            }
            if let entry = row.entry { hasher.combine(runner.isMissing(entry)) }
        }
        return hasher.finalize()
    }

    private func updateCall() {
        let busy = board.isBusy
        var config = Theme.Glass.buttonConfiguration(prominent: !busy)
        config.title = board.renderCall
        config.cornerStyle = .large
        config.buttonSize = .large
        if busy { config.baseForegroundColor = Theme.Color.danger }
        call.configuration = config
        call.accessibilityLabel = board.renderCall
    }

    private func callTapped() {
        perform(runner.begin())
    }

    private func perform(_ action: ForgeAction?) {
        guard let action else { return }
        switch action {
        case .render(let recipe):
            startRender(recipe)
        case .cancel:
            runner.stop()
        case .play(let asset):
            play(asset, entryID: nil)
        case .edit(let field):
            open(field)
        case .configure:
            openRenderer()
        }
    }

    private func startRender(_ recipe: ForgeRecipe) {
        view.endEditing(true)
        Theme.Haptics.send()
        stageClip = nil
        stageFailure = nil
        locatingAsset = nil
        runner.render(recipe)
    }

    /// A value the board cannot walk by itself. An address opens its own screen; words are already
    /// a box on this one, so the box is scrolled to and given the keyboard.
    private func open(_ field: ForgeField) {
        guard field != .endpoint else {
            openRenderer()
            return
        }
        guard let row = board.rows.first(where: { $0.kind == .field(field) }),
            let path = dataSource.indexPath(for: .row(row.id))
        else { return }
        collectionView.scrollToItem(at: path, at: .centeredVertically, animated: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let cell = self?.collectionView.cellForItem(at: path) as? ForgeWordsCell else {
                return
            }
            cell.focus()
        }
    }

    private func openRenderer() {
        Theme.Haptics.tap()
        let editor = ForgeEndpointViewController()
        let nav = UINavigationController(rootViewController: editor)
        present(nav, animated: true)
    }

    private func type(_ text: String, into field: ForgeField) {
        switch field {
        case .prompt: runner.describe(text)
        case .negative: runner.avoid(text)
        case .endpoint, .size, .seconds, .fps, .model, .seed: return
        }
    }

    private func toggleSound() {
        muted.toggle()
        Theme.Haptics.selection()
        reloadStage()
    }

    private func openStageClip() {
        guard let clip = stageClip else { return }
        Theme.Haptics.tap()
        ClipTheatre.present(clip.url, from: self)
    }

    /// Where to point a player, asked before it is pointed there. A clip whose file has been
    /// cleaned up off the renderer answers 404, and a video player reports that in words about
    /// nothing anybody can act on.
    private func play(_ asset: ForgeAsset, entryID: String?) {
        Theme.Haptics.tap()
        Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await self.runner.locate(asset, entryID: entryID)
                ClipTheatre.present(url, from: self)
            } catch {
                self.flash(ForgeClient.reason(error, host: self.runner.endpoint?.host ?? ""))
                Theme.Haptics.error()
            }
        }
    }

    private func share(_ asset: ForgeAsset, from source: UIView?) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let data = try await self.runner.fetch(asset)
                guard let url = ClipExport.stage(data, as: asset) else { return }
                ClipExport.share(url, from: self, source: source)
            } catch {
                self.flash(ForgeClient.reason(error, host: self.runner.endpoint?.host ?? ""))
                Theme.Haptics.error()
            }
        }
    }

    /// The clip the render in hand produced, confirmed to still be there before the stage points a
    /// player at it. Asked once per asset: the stage reconfigures on every frame off the socket.
    private func syncStageClip() {
        guard let asset = runner.board.job.asset else {
            locating?.cancel()
            locating = nil
            locatingAsset = nil
            stageClip = nil
            stageFailure = nil
            return
        }
        guard stageClip?.asset != asset, locatingAsset != asset else { return }
        locating?.cancel()
        locatingAsset = asset
        stageFailure = nil
        locating = Task { [weak self] in
            guard let self else { return }
            do {
                let url = try await self.runner.locate(asset)
                guard !Task.isCancelled else { return }
                self.stageClip = (asset, url)
            } catch {
                guard !Task.isCancelled else { return }
                self.stageFailure = ForgeClient.reason(
                    error, host: self.runner.endpoint?.host ?? "")
            }
            self.locating = nil
            self.reloadStage()
        }
    }

    private func reloadStage() {
        guard let row = board.rows.first(where: { $0.kind == .job }) else { return }
        let item = Item.row(row.id)
        applied[item] = signature(item)
        var snapshot = dataSource.snapshot()
        guard snapshot.itemIdentifiers.contains(item) else { return }
        snapshot.reconfigureItems([item])
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func flash(_ words: String) {
        ToastView(message: words).flash(in: view, above: dock.topAnchor, duration: 3)
    }

    #if DEBUG
        /// Puts a named section under the top of the screen on launch — and opens the renderer's
        /// own screen when asked — so every part of this surface can be photographed without a
        /// finger driving it.
        private func scrollForVerification() {
            if ProcessInfo.processInfo.environment["TAILSCODE_VIDEO_OPEN"] == "renderer" {
                openRenderer()
            }
            guard let id = ProcessInfo.processInfo.environment["TAILSCODE_VIDEO_SCROLL"],
                let section = dataSource.snapshot().sectionIdentifiers.firstIndex(of: id),
                dataSource.snapshot().numberOfItems(inSection: id) > 0
            else { return }
            collectionView.scrollToItem(
                at: IndexPath(item: 0, section: section), at: .top, animated: false)
        }
    #endif

    private func swipeActions(at indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard let item = dataSource.itemIdentifier(for: indexPath), let row = row(for: item),
            let entry = row.entry
        else { return nil }
        let forget = UIContextualAction(style: .destructive, title: String(localized: "Remove")) {
            [weak self] _, _, done in
            self?.runner.forget(entry)
            Theme.Haptics.warning()
            done(true)
        }
        forget.image = UIImage(systemName: "trash")
        return UISwipeActionsConfiguration(actions: [forget])
    }
}

extension VideoForgeViewController: UICollectionViewDelegate {
    /// A row the board would not act on takes no highlight either: a line the board owed the
    /// reader must not flash grey as though something happened.
    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath)
        -> Bool
    {
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return false }
        return row(for: item)?.isActivatable ?? false
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath), let row = row(for: item),
            row.isActivatable
        else { return }
        view.endEditing(true)
        announceTouch(on: row)
        let action = runner.activate(row)
        if case .play(let asset) = action, let entry = row.entry {
            play(asset, entryID: entry.id)
            return
        }
        perform(action)
    }

    /// A row that changes a value under the finger clicks; a row that opens something taps.
    private func announceTouch(on row: ForgeRow) {
        switch row.kind {
        case .expander:
            Theme.Haptics.selection()
        case .field(let field):
            field.isCyclable ? Theme.Haptics.selection() : Theme.Haptics.tap()
        case .job, .clip, .note:
            Theme.Haptics.tap()
        }
    }

    func collectionView(
        _ collectionView: UICollectionView,
        contextMenuConfigurationForItemsAt indexPaths: [IndexPath], point: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let indexPath = indexPaths.first,
            let item = dataSource.itemIdentifier(for: indexPath), let row = row(for: item),
            let entry = row.entry
        else { return nil }
        let source = collectionView.cellForItem(at: indexPath)
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) {
            [weak self] _ in
            guard let self else { return nil }
            var actions: [UIAction] = [
                UIAction(
                    title: String(localized: "Use these settings"),
                    image: UIImage(systemName: "arrow.uturn.backward")
                ) { [weak self] _ in
                    self?.runner.reuse(entry)
                    Theme.Haptics.selection()
                }
            ]
            if let asset = entry.asset {
                actions.insert(
                    UIAction(
                        title: String(localized: "Share"),
                        image: UIImage(systemName: "square.and.arrow.up")
                    ) { [weak self] _ in self?.share(asset, from: source) }, at: 0)
            }
            actions.append(
                UIAction(
                    title: String(localized: "Remove"), image: UIImage(systemName: "trash"),
                    attributes: .destructive
                ) { [weak self] _ in
                    self?.runner.forget(entry)
                    Theme.Haptics.warning()
                })
            return UIMenu(title: entry.title, children: actions)
        }
    }
}
