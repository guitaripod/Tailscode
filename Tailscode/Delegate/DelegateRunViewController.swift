import CodingAgentKit
import TailscodeCore
import UIKit

/// One run as `DelegateRunReading` tells it: the goal and its facts, the one thing that matters
/// now, the ladder, exactly one primary action with the rest beside it, the patch's files and the
/// timeline. The past is read from the daemon's record and the present streams in on the same
/// fold, so reopening a run finds it exactly where it is.
@MainActor
final class DelegateRunViewController: UIViewController {
    private enum Section: Hashable { case head, lead, ladder, primary, actions, files, timeline }
    private enum Item: Hashable {
        case head
        case lead
        case ladder
        case primary
        case action(String)
        case replay
        case file(String)
        case line(Int)
    }

    private let host: String
    private let serverName: String
    private let runID: String
    private let desk = DelegateGate.desk
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var followsBottom = true
    private var askedPatch = false
    private var delivering = false
    private var reading: DelegateRunReading?
    private let headView = DelegateRunHeadView()
    private let leadView = DelegateLeadView()
    private let primaryView = DelegatePrimaryActionView()

    private var board: DelegateBoard { desk.board(host: host, serverName: serverName) }

    init(host: String, serverName: String, runID: String) {
        self.host = host
        self.serverName = serverName
        self.runID = runID
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = DelegateEntryPoint.title
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = Theme.Color.groupedBackground
        primaryView.onPress = { [weak self] in
            guard let self, let primary = self.reading?.primary else { return }
            self.perform(primary.kind, source: self.primaryView)
        }
        configure()
        NotificationCenter.default.addObserver(
            self, selector: #selector(deskChanged), name: DelegateDesk.didChange, object: nil)
        applySnapshot()
        Task { await desk.load(runID: runID, host: host) }
    }

    @objc private func deskChanged() {
        applySnapshot()
    }

    #if DEBUG
        /// `TAILSCODE_DELEGATE_SCROLL=1` lands on the run's last rows, so a simulator can be
        /// photographed with the timeline in view.
        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            guard ProcessInfo.processInfo.environment["TAILSCODE_DELEGATE_SCROLL"] == "1" else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                guard let self else { return }
                let bottom = max(self.collectionView.contentSize.height - self.collectionView.bounds.height + self.collectionView.adjustedContentInset.bottom, 0)
                self.collectionView.setContentOffset(CGPoint(x: 0, y: bottom), animated: false)
            }
        }
    #endif

    private func configure() {
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .supplementary
        config.itemSeparatorHandler = { [weak self] indexPath, separator in
            var separator = separator
            if self?.dataSource.snapshot().sectionIdentifiers[safe: indexPath.section] == .timeline {
                separator.topSeparatorVisibility = .hidden
                separator.bottomSeparatorVisibility = .hidden
            }
            return separator
        }
        let layout = UICollectionViewCompositionalLayout.readableList(using: config)
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        view.addSubview(collectionView)

        let ladderCell = UICollectionView.CellRegistration<LadderCell, Item> { [weak self] cell, _, _ in
            guard let ladder = self?.reading?.ladder else { return }
            cell.show(ladder)
        }
        let hostCell = UICollectionView.CellRegistration<DelegateHostCell, Item> { [weak self] cell, _, item in
            guard let self, let reading = self.reading else { return }
            switch item {
            case .head:
                self.headView.show(reading)
                cell.place(self.headView)
                cell.backgroundConfiguration = .clear()
            case .lead:
                guard let lead = reading.lead else { return }
                self.leadView.show(lead)
                cell.place(self.leadView)
                var background = UIBackgroundConfiguration.listGroupedCell()
                background.backgroundColor = lead.tone == .quiet
                    ? Theme.Color.groupedSurface : lead.tone.color.withAlphaComponent(0.12)
                cell.backgroundConfiguration = background
            case .primary:
                guard let primary = reading.primary else { return }
                self.primaryView.show(primary, busy: self.delivering)
                cell.place(self.primaryView)
                cell.backgroundConfiguration = .clear()
            default:
                break
            }
        }
        let listCell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            self?.configure(cell, item)
        }
        let lineCell = UICollectionView.CellRegistration<DelegateTimelineCell, Item> { [weak self] cell, _, item in
            guard case .line(let seq) = item, let timeline = self?.reading?.timeline,
                let line = timeline.first(where: { $0.seq == seq })
            else { return }
            cell.show(line, first: timeline.first?.seq == seq, last: timeline.last?.seq == seq)
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            var content = UIListContentConfiguration.header()
            content.text = self?.sectionTitle(at: indexPath.section)
            view.contentConfiguration = content
        }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) { collectionView, indexPath, item in
            switch item {
            case .ladder: return collectionView.dequeueConfiguredReusableCell(using: ladderCell, for: indexPath, item: item)
            case .head, .lead, .primary: return collectionView.dequeueConfiguredReusableCell(using: hostCell, for: indexPath, item: item)
            case .line: return collectionView.dequeueConfiguredReusableCell(using: lineCell, for: indexPath, item: item)
            default: return collectionView.dequeueConfiguredReusableCell(using: listCell, for: indexPath, item: item)
            }
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
    }

    private func sectionTitle(at index: Int) -> String? {
        switch dataSource.snapshot().sectionIdentifiers[safe: index] {
        case .files: return reading?.filesTitle
        case .timeline: return DelegateRunReading.timelineTitle
        default: return nil
        }
    }

    private func applySnapshot() {
        let board = board
        guard let reading = board.reading(for: runID) else { return }
        self.reading = reading
        if board.story(for: runID)?.status == .passed, board.patches[runID] == nil, !askedPatch {
            askedPatch = true
            Task { [weak self] in
                guard let self else { return }
                do { try await self.desk.patch(runID: self.runID, host: self.host) } catch {
                    AppLogger.ui.error("delegate patch for \(self.runID) unread: \(error.localizedDescription)")
                }
            }
        }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.head])
        snapshot.appendItems([.head], toSection: .head)
        if reading.lead != nil {
            snapshot.appendSections([.lead])
            snapshot.appendItems([.lead], toSection: .lead)
        }
        snapshot.appendSections([.ladder])
        snapshot.appendItems([.ladder], toSection: .ladder)
        if reading.primary != nil {
            snapshot.appendSections([.primary])
            snapshot.appendItems([.primary], toSection: .primary)
        }
        var actions = reading.secondary.map { Item.action($0.id) }
        if !reading.replayTiers.isEmpty { actions.append(.replay) }
        if !actions.isEmpty {
            snapshot.appendSections([.actions])
            snapshot.appendItems(actions, toSection: .actions)
        }
        if !reading.files.isEmpty {
            snapshot.appendSections([.files])
            snapshot.appendItems(reading.files.map { .file($0.path) }, toSection: .files)
        }
        if !reading.timeline.isEmpty {
            snapshot.appendSections([.timeline])
            snapshot.appendItems(reading.timeline.map { .line($0.seq) }, toSection: .timeline)
        }
        let existing = dataSource.snapshot().itemIdentifiers
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter { existing.contains($0) })
        let grew = snapshot.itemIdentifiers.count > existing.count
        dataSource.apply(snapshot, animatingDifferences: false)
        refreshHeaders()
        if grew, followsBottom, reading.isLive, let last = reading.timeline.last,
            let indexPath = dataSource.indexPath(for: .line(last.seq))
        {
            collectionView.scrollToItem(at: indexPath, at: .bottom, animated: true)
        }
    }

    private func refreshHeaders() {
        for header in collectionView.visibleSupplementaryViews(ofKind: UICollectionView.elementKindSectionHeader) {
            guard let header = header as? UICollectionViewListCell,
                let indexPath = collectionView.indexPath(forSupplementaryView: header)
            else { continue }
            var content = UIListContentConfiguration.header()
            content.text = sectionTitle(at: indexPath.section)
            header.contentConfiguration = content
        }
    }

    private func action(_ id: String) -> DelegateRunAction? {
        reading?.secondary.first { $0.id == id }
    }

    private func configure(_ cell: UICollectionViewListCell, _ item: Item) {
        guard let reading else { return }
        var content = cell.defaultContentConfiguration()
        cell.accessories = []
        switch item {
        case .action(let id):
            guard let action = action(id) else { break }
            let ink = action.role == .destructive ? Theme.Color.danger : Theme.Color.accent
            content.text = action.title
            content.textProperties.color = ink
            content.secondaryText = action.detail
            content.secondaryTextProperties.color = Theme.Color.secondaryLabel
            content.secondaryTextProperties.numberOfLines = 0
            content.image = UIImage(systemName: Self.symbol(action.kind))
            content.imageProperties.tintColor = ink
        case .replay:
            content.text = DelegateRunReading.replayMenuTitle
            content.textProperties.color = Theme.Color.accent
            content.image = UIImage(systemName: "arrow.counterclockwise")
            content.imageProperties.tintColor = Theme.Color.accent
            cell.accessories = [.popUpMenu(replayMenu(reading.replayTiers))]
        case .file(let path):
            guard let file = reading.files.first(where: { $0.path == path }) else { break }
            content.text = file.name
            content.textProperties.font = Theme.Ramp.font(.treeRow)
            content.secondaryText = file.folder.isEmpty ? nil : file.folder
            content.secondaryTextProperties.font = Theme.Ramp.font(.treePath)
            content.secondaryTextProperties.color = Theme.Color.secondaryLabel
            content.image = UIImage(systemName: "doc.text")
            content.imageProperties.tintColor = Theme.Color.secondaryLabel
            var accessories: [UICellAccessory] = []
            if let counts = Self.counts(file) {
                accessories.append(.customView(configuration: .init(customView: counts, placement: .trailing())))
            }
            accessories.append(.disclosureIndicator())
            cell.accessories = accessories
            cell.accessibilityLabel = [file.path, file.counts].compactMap { $0 }.joined(separator: ", ")
        case .head, .lead, .ladder, .primary, .line:
            break
        }
        cell.contentConfiguration = content
    }

    private static func symbol(_ kind: DelegateRunAction.Kind) -> String {
        switch kind {
        case .approve, .apply: return "checkmark.circle"
        case .hold: return "pause.circle"
        case .discard: return "trash"
        case .cancel: return "xmark.circle"
        case .replay: return "arrow.up.forward.circle"
        case .duplicate: return "doc.on.doc"
        }
    }

    /// "+12 −3" in the colours a diff gutter wears, or the one word a binary file gets.
    private static func counts(_ file: DelegateFileRow) -> UILabel? {
        guard let counts = file.counts else { return nil }
        let label = UILabel()
        label.font = Theme.Ramp.font(.rowMeta)
        guard let added = file.added, let removed = file.removed, counts.hasPrefix("+") else {
            label.text = counts
            label.textColor = Theme.Color.secondaryLabel
            return label
        }
        let text = NSMutableAttributedString(string: "+\(added)", attributes: [.foregroundColor: Theme.Color.success])
        if removed > 0 {
            text.append(NSAttributedString(string: " −\(removed)", attributes: [.foregroundColor: Theme.Color.danger]))
        }
        label.attributedText = text
        return label
    }

    private func replayMenu(_ tiers: [String]) -> UIMenu {
        let labels = Dictionary(board.tiers.map { ($0.tier, $0.label) }, uniquingKeysWith: { first, _ in first })
        return UIMenu(title: DelegateRunReading.replayMenuTitle, children: tiers.map { tier in
            let label = labels[tier] ?? ""
            return UIAction(title: tier, subtitle: label.isEmpty ? nil : label) { [weak self] _ in
                self?.replay(tier: tier)
            }
        })
    }

    private func perform(_ kind: DelegateRunAction.Kind, source: UIView) {
        switch kind {
        case .approve: decide(true)
        case .hold: decide(false)
        case .apply: apply(source: source)
        case .discard: confirmDiscard(source: source)
        case .cancel: cancel(source: source)
        case .replay(let tier): replay(tier: tier)
        case .duplicate:
            guard let packet = board.story(for: runID)?.packet else { return }
            Theme.Haptics.tap()
            DelegateGate.presentComposer(from: self, host: host, serverName: serverName, draft: DelegateDraft(packet: packet))
        }
    }

    /// Applying lands files in a tree a chat may be writing to right now; that chat is named before
    /// the press rather than discovered after it.
    private func apply(source: UIView) {
        let repo = reading?.repo ?? ""
        let chats = DelegateChatFootprint.from(SessionListCache.load(), host: host)
        let cautions = DelegateApplyCheck.cautions(repo: repo, chats: chats)
        guard cautions.isEmpty else {
            Theme.Haptics.warning()
            let alert = UIAlertController(
                title: DelegateApplyCheck.confirmTitle, message: cautions.joined(separator: "\n\n"), preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: String(localized: "Cancel"), style: .cancel))
            alert.addAction(UIAlertAction(title: DelegateApplyCheck.confirmAction, style: .default) { [weak self] _ in
                self?.deliver(apply: true)
            })
            present(alert, animated: true)
            return
        }
        deliver(apply: true)
    }

    private func confirmDiscard(source: UIView) {
        let alert = UIAlertController(
            title: String(localized: "Discard this patch?"),
            message: String(localized: "The tree never sees it. The patch stays readable on this run."),
            preferredStyle: .actionSheet)
        alert.popoverPresentationController?.sourceView = source
        alert.popoverPresentationController?.sourceRect = source.bounds
        alert.addAction(UIAlertAction(title: String(localized: "Discard"), style: .destructive) { [weak self] _ in
            self?.deliver(apply: false)
        })
        alert.addAction(UIAlertAction(title: String(localized: "Keep it"), style: .cancel))
        present(alert, animated: true)
    }

    private func deliver(apply: Bool) {
        guard !delivering else { return }
        delivering = true
        apply ? Theme.Haptics.send() : Theme.Haptics.warning()
        applySnapshot()
        Task { [weak self] in
            guard let self else { return }
            do {
                if apply {
                    try await self.desk.apply(runID: self.runID, host: self.host)
                } else {
                    try await self.desk.discard(runID: self.runID, host: self.host)
                }
                AppLogger.ui.info("delegate run \(self.runID) \(apply ? "applied" : "discarded") on \(self.host)")
                Theme.Haptics.success()
            } catch {
                AppLogger.ui.error("delegate run \(self.runID) \(apply ? "apply" : "discard") refused: \(error.localizedDescription)")
                Theme.Haptics.error()
                DelegateRefusalViewController.present(DelegateRefusal(error), from: self)
            }
            self.delivering = false
            self.applySnapshot()
        }
    }

    private func openFile(_ file: DelegateFileRow) {
        Theme.Haptics.tap()
        let runID = runID
        let host = host
        let path = file.path
        let viewer = GitDiffViewController(
            title: file.name, subtitle: file.path,
            load: { try await DelegateRunViewController.filePatch(runID: runID, host: host, path: path) })
        navigationController?.pushViewController(viewer, animated: true)
    }

    private static func filePatch(runID: String, host: String, path: String) async throws -> String? {
        let patch = try await DelegateGate.desk.patch(runID: runID, host: host)
        return DelegatePatch.files(patch).first { $0.path == path }?.patch
    }

    private func replay(tier: String) {
        Theme.Haptics.send()
        Task { [weak self] in
            guard let self else { return }
            do {
                let started = try await self.desk.replay(runID: self.runID, host: self.host, tier: tier, ceiling: nil)
                DelegateGate.showRun(started, host: self.host, serverName: self.serverName, from: self)
            } catch {
                self.fail(String(localized: "The replay did not start"), error)
            }
        }
    }

    private func decide(_ approved: Bool) {
        approved ? Theme.Haptics.send() : Theme.Haptics.warning()
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.desk.approve(runID: self.runID, host: self.host, approved: approved)
            } catch {
                self.fail(String(localized: "The answer did not reach the dispatcher"), error)
            }
        }
    }

    private func cancel(source: UIView) {
        let alert = UIAlertController(
            title: String(localized: "Cancel this run?"),
            message: String(localized: "The attempt out on the machine finishes on its own; nothing after it starts."),
            preferredStyle: .actionSheet)
        alert.popoverPresentationController?.sourceView = source
        alert.popoverPresentationController?.sourceRect = source.bounds
        alert.addAction(UIAlertAction(title: String(localized: "Cancel the run"), style: .destructive) { [weak self] _ in
            guard let self else { return }
            Task { [weak self] in
                guard let self else { return }
                do { try await self.desk.cancel(runID: self.runID, host: self.host) } catch {
                    self.fail(String(localized: "The run did not cancel"), error)
                }
            }
        })
        alert.addAction(UIAlertAction(title: String(localized: "Keep going"), style: .cancel))
        present(alert, animated: true)
    }

    private func fail(_ title: String, _ error: Error) {
        Theme.Haptics.error()
        let alert = UIAlertController(title: title, message: error.localizedDescription, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: String(localized: "OK"), style: .cancel))
        present(alert, animated: true)
    }
}

extension DelegateRunViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        switch dataSource.itemIdentifier(for: indexPath) {
        case .action, .replay, .file: return true
        default: return false
        }
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        let source = collectionView.cellForItem(at: indexPath) ?? collectionView
        switch item {
        case .action(let id):
            if let action = action(id) { perform(action.kind, source: source) }
        case .file(let path):
            if let file = reading?.files.first(where: { $0.path == path }) { openFile(file) }
        default:
            break
        }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        let bottom = scrollView.contentOffset.y + scrollView.bounds.height
        followsBottom = bottom >= scrollView.contentSize.height - 80
    }
}

/// One line of the run's timeline, set tight like a log: tone-coloured, a worker's progress indented
/// and quiet, and a failed attempt's own output under its line.
final class DelegateTimelineCell: UICollectionViewListCell {
    private let text = UILabel()
    private let detail = UILabel()
    private let detailBlock = UIView()
    private var indent: NSLayoutConstraint!
    private var top: NSLayoutConstraint!
    private var bottom: NSLayoutConstraint!

    override init(frame: CGRect) {
        super.init(frame: frame)
        text.numberOfLines = 0
        text.adjustsFontForContentSizeCategory = true
        detail.numberOfLines = 0
        detail.font = Theme.Ramp.font(.toolOutput)
        detail.textColor = Theme.Color.secondaryLabel
        detail.adjustsFontForContentSizeCategory = true
        detail.translatesAutoresizingMaskIntoConstraints = false
        let bar = UIView()
        bar.backgroundColor = Theme.Color.separator
        bar.translatesAutoresizingMaskIntoConstraints = false
        detailBlock.addSubview(bar)
        detailBlock.addSubview(detail)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: detailBlock.topAnchor),
            bar.bottomAnchor.constraint(equalTo: detailBlock.bottomAnchor),
            bar.leadingAnchor.constraint(equalTo: detailBlock.leadingAnchor, constant: 2),
            bar.widthAnchor.constraint(equalToConstant: 2),
            detail.topAnchor.constraint(equalTo: detailBlock.topAnchor),
            detail.bottomAnchor.constraint(equalTo: detailBlock.bottomAnchor),
            detail.leadingAnchor.constraint(equalTo: bar.trailingAnchor, constant: Theme.Spacing.s),
            detail.trailingAnchor.constraint(equalTo: detailBlock.trailingAnchor),
        ])
        let column = UIStackView(arrangedSubviews: [text, detailBlock])
        column.axis = .vertical
        column.spacing = Theme.Spacing.xs
        column.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(column)
        indent = column.leadingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.leadingAnchor)
        top = column.topAnchor.constraint(equalTo: contentView.topAnchor)
        bottom = column.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        NSLayoutConstraint.activate([
            top, bottom, indent,
            column.trailingAnchor.constraint(equalTo: contentView.layoutMarginsGuide.trailingAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// - Parameters:
    ///   - first: the line opens the timeline, so it keeps the card's own top margin.
    ///   - last: the line closes the timeline, so it keeps the card's own bottom margin.
    func show(_ line: DelegateStoryLine, first: Bool, last: Bool) {
        text.text = line.text
        text.font = Theme.Ramp.font(line.isProgress ? .rowMeta : .rowDetail)
        text.textColor = line.isProgress ? Theme.Color.tertiaryLabel : line.tone.inkColor
        detail.text = line.detail
        detailBlock.isHidden = line.detail == nil
        indent.constant = line.isProgress ? Theme.Spacing.l : 0
        top.constant = first ? Theme.Spacing.m : Theme.Spacing.xs + 1
        bottom.constant = -(last ? Theme.Spacing.m : Theme.Spacing.xs + 1)
        accessibilityLabel = [line.text, line.detail].compactMap { $0 }.joined(separator: ". ")
    }
}

/// The goal as the run's heading, its pill beside it, and the facts in one line under it.
final class DelegateRunHeadView: UIView {
    private let headline = UILabel()
    private let pill = DelegatePill()
    private let facts = UILabel()

    init() {
        super.init(frame: .zero)
        headline.font = Theme.Ramp.font(.headline)
        headline.textColor = Theme.Color.label
        headline.numberOfLines = 0
        headline.adjustsFontForContentSizeCategory = true
        headline.accessibilityTraits = .header
        facts.font = Theme.Ramp.font(.rowMeta)
        facts.textColor = Theme.Color.secondaryLabel
        facts.numberOfLines = 0
        facts.adjustsFontForContentSizeCategory = true
        let pillRow = UIStackView(arrangedSubviews: [pill, UIView()])
        pillRow.axis = .horizontal
        let column = UIStackView(arrangedSubviews: [pillRow, headline, facts])
        column.axis = .vertical
        column.spacing = Theme.Spacing.xs
        column.setCustomSpacing(Theme.Spacing.s, after: pillRow)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(_ reading: DelegateRunReading) {
        headline.text = reading.headline
        pill.show(reading.badge, tone: reading.tone)
        pill.superview?.isHidden = reading.badge == nil
        facts.text = reading.facts
        facts.isHidden = reading.facts.isEmpty
    }
}

/// The one thing that matters about the run right now, with a bar in the colour of what it means.
final class DelegateLeadView: UIView {
    private let bar = UIView()
    private let title = UILabel()
    private let caption = UILabel()
    private let body = UILabel()

    init() {
        super.init(frame: .zero)
        bar.layer.cornerRadius = 1.5
        bar.translatesAutoresizingMaskIntoConstraints = false
        title.font = Theme.Ramp.font(.cardTitle)
        title.numberOfLines = 0
        title.adjustsFontForContentSizeCategory = true
        caption.font = Theme.Ramp.font(.rowMeta)
        caption.textColor = Theme.Color.secondaryLabel
        caption.numberOfLines = 0
        caption.adjustsFontForContentSizeCategory = true
        body.numberOfLines = 0
        body.adjustsFontForContentSizeCategory = true
        let column = UIStackView(arrangedSubviews: [title, caption, body])
        column.axis = .vertical
        column.spacing = Theme.Spacing.xs
        column.setCustomSpacing(Theme.Spacing.s, after: caption)
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)
        addSubview(column)
        NSLayoutConstraint.activate([
            bar.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            bar.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
            bar.leadingAnchor.constraint(equalTo: leadingAnchor),
            bar.widthAnchor.constraint(equalToConstant: 3),
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.leadingAnchor.constraint(equalTo: bar.trailingAnchor, constant: Theme.Spacing.m),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(_ lead: DelegateRunReading.Lead) {
        bar.backgroundColor = lead.tone.color
        title.text = lead.title
        title.textColor = lead.tone == .quiet ? Theme.Color.label : lead.tone.color
        caption.text = lead.caption
        caption.isHidden = lead.caption == nil
        body.text = lead.body
        body.isHidden = lead.body == nil
        body.font = Theme.Ramp.font(lead.bodyIsOutput ? .toolOutput : .cardBody)
        body.textColor = lead.bodyIsOutput ? Theme.Color.label : Theme.Color.secondaryLabel
    }
}

/// The run's one primary action as the prominent button, with what it does under it.
final class DelegatePrimaryActionView: UIView {
    var onPress: (() -> Void)?
    private let button = PrimaryButton(title: "")
    private let detail = UILabel()

    init() {
        super.init(frame: .zero)
        detail.font = Theme.Ramp.font(.rowNote)
        detail.textColor = Theme.Color.secondaryLabel
        detail.textAlignment = .center
        detail.numberOfLines = 0
        detail.adjustsFontForContentSizeCategory = true
        button.addAction(UIAction { [weak self] _ in self?.onPress?() }, for: .touchUpInside)
        let column = UIStackView(arrangedSubviews: [button, detail])
        column.axis = .vertical
        column.spacing = Theme.Spacing.s
        column.translatesAutoresizingMaskIntoConstraints = false
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(_ action: DelegateRunAction, busy: Bool) {
        button.setTitle(action.title)
        button.setLoading(busy)
        detail.text = action.detail
        detail.isHidden = action.detail == nil
    }
}

/// The ladder as a row of the run, read-only, each rung wearing its state and its word for this run.
final class LadderCell: UICollectionViewListCell {
    private let ladder = TierLadderControl()

    override init(frame: CGRect) {
        super.init(frame: frame)
        ladder.mode = .display
        ladder.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(ladder)
        NSLayoutConstraint.activate([
            ladder.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Spacing.m),
            ladder.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Theme.Spacing.m),
            ladder.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Spacing.l),
            ladder.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.l),
        ])
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(_ ladder: DelegateLadder) {
        self.ladder.rungs = ladder.rungs.map { rung in
            var worded = rung
            worded.note = ladder.word(for: rung)
            return worded
        }
        accessibilityLabel = ladder.spoken
    }
}

/// What a refused apply or discard said, as a sheet sized to its words: git's own reason is set as
/// output, because it is the message.
@MainActor
final class DelegateRefusalViewController: UIViewController {
    private let refusal: DelegateRefusal
    private let column = UIStackView()

    static func present(_ refusal: DelegateRefusal, from presenter: UIViewController) {
        let card = DelegateRefusalViewController(refusal: refusal)
        if let sheet = card.sheetPresentationController {
            sheet.prefersGrabberVisible = true
            sheet.detents = [.medium(), .large()]
        }
        presenter.present(card, animated: true)
    }

    init(refusal: DelegateRefusal) {
        self.refusal = refusal
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.groupedBackground
        let scroll = UIScrollView()
        scroll.alwaysBounceVertical = true
        scroll.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scroll)
        column.axis = .vertical
        column.spacing = Theme.Spacing.m
        column.translatesAutoresizingMaskIntoConstraints = false
        scroll.addSubview(column)

        let title = UILabel()
        title.text = refusal.title
        title.font = Theme.Ramp.font(.panelTitle)
        title.textColor = Theme.Color.danger
        title.numberOfLines = 0
        title.adjustsFontForContentSizeCategory = true
        let body = UILabel()
        body.text = refusal.body
        body.font = Theme.Ramp.font(refusal.bodyIsOutput ? .toolOutput : .cardBody)
        body.textColor = refusal.bodyIsOutput ? Theme.Color.label : Theme.Color.secondaryLabel
        body.numberOfLines = 0
        body.adjustsFontForContentSizeCategory = true
        var config = UIButton.Configuration.filled()
        config.title = String(localized: "OK")
        config.baseBackgroundColor = Theme.Color.accent
        config.cornerStyle = .large
        config.contentInsets = NSDirectionalEdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16)
        let done = UIButton(configuration: config, primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        for view in [title, body, done] { column.addArrangedSubview(view) }
        column.setCustomSpacing(Theme.Spacing.l, after: body)

        NSLayoutConstraint.activate([
            scroll.topAnchor.constraint(equalTo: view.topAnchor),
            scroll.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            scroll.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            column.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor, constant: Theme.Spacing.xl),
            column.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor, constant: -Theme.Spacing.l),
            column.leadingAnchor.constraint(equalTo: scroll.frameLayoutGuide.leadingAnchor, constant: Theme.Spacing.l),
            column.trailingAnchor.constraint(equalTo: scroll.frameLayoutGuide.trailingAnchor, constant: -Theme.Spacing.l),
        ])
    }
}
