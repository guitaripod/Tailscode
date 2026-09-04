import CodingAgentKit
import TailscodeCore
import UIKit

/// One run: its ladder, its story as the daemon tells it, every attempt, and the two answers a
/// gated rung waits for. The past is read from the daemon's record and the present streams in on
/// the same fold, so reopening a run finds it exactly where it is.
@MainActor
final class DelegateRunViewController: UIViewController {
    private enum Section: Int, CaseIterable { case ladder, approval, story, attempts, actions }
    private enum Item: Hashable {
        case ladder
        case approval
        case line(Int)
        case attempt(Int)
        case cancel
        case replay
        case applied
    }

    private let host: String
    private let serverName: String
    private let runID: String
    private let desk = DelegateGate.desk
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private var followsBottom = true
    private var story: DelegateRunStory? { desk.board(host: host, serverName: serverName).story(for: runID) }

    init(host: String, serverName: String, runID: String) {
        self.host = host
        self.serverName = serverName
        self.runID = runID
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = story?.headline ?? DelegateEntryPoint.title
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = Theme.Color.groupedBackground
        configure()
        NotificationCenter.default.addObserver(
            self, selector: #selector(deskChanged), name: DelegateDesk.didChange, object: nil)
        applySnapshot()
        Task { await desk.load(runID: runID, host: host) }
    }

    @objc private func deskChanged() {
        title = story?.headline ?? title
        applySnapshot()
    }

    private func configure() {
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .supplementary
        let layout = UICollectionViewCompositionalLayout.readableList(using: config)
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        view.addSubview(collectionView)

        let ladderCell = UICollectionView.CellRegistration<LadderCell, Item> { [weak self] cell, _, _ in
            guard let story = self?.story else { return }
            cell.show(story.ladder)
        }
        let approvalCell = UICollectionView.CellRegistration<DelegateApprovalCell, Item> { [weak self] cell, _, _ in
            guard let self, let pending = self.story?.pendingApproval else { return }
            cell.show(tier: pending.tier, reason: pending.reason) { [weak self] approved in
                self?.decide(approved)
            }
        }
        let listCell = UICollectionView.CellRegistration<UICollectionViewListCell, Item> { [weak self] cell, _, item in
            self?.configure(cell, item)
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
            case .approval: return collectionView.dequeueConfiguredReusableCell(using: approvalCell, for: indexPath, item: item)
            default: return collectionView.dequeueConfiguredReusableCell(using: listCell, for: indexPath, item: item)
            }
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
    }

    private func sectionTitle(at index: Int) -> String? {
        switch dataSource.snapshot().sectionIdentifiers[safe: index] {
        case .ladder: return story.map { DelegateWords.status($0.status) }
        case .approval: return String(localized: "Waiting for you")
        case .story: return String(localized: "Story")
        case .attempts: return String(localized: "Attempts")
        case .actions, .none: return nil
        }
    }

    private func applySnapshot() {
        guard let story else { return }
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        snapshot.appendSections([.ladder])
        snapshot.appendItems([.ladder], toSection: .ladder)
        if story.needsApproval {
            snapshot.appendSections([.approval])
            snapshot.appendItems([.approval], toSection: .approval)
        }
        if !story.lines.isEmpty {
            snapshot.appendSections([.story])
            snapshot.appendItems(story.lines.map { .line($0.seq) }, toSection: .story)
        }
        if !story.attempts.isEmpty {
            snapshot.appendSections([.attempts])
            snapshot.appendItems(story.attempts.indices.map { .attempt($0) }, toSection: .attempts)
        }
        snapshot.appendSections([.actions])
        var actions: [Item] = []
        if !story.appliedFiles.isEmpty { actions.append(.applied) }
        if story.isLive { actions.append(.cancel) }
        if !story.isLive { actions.append(.replay) }
        snapshot.appendItems(actions, toSection: .actions)
        let existing = dataSource.snapshot().itemIdentifiers
        snapshot.reconfigureItems(snapshot.itemIdentifiers.filter { existing.contains($0) })
        let grew = snapshot.itemIdentifiers.count > existing.count
        dataSource.apply(snapshot, animatingDifferences: false)
        if grew, followsBottom, story.isLive, let last = story.lines.last {
            if let indexPath = dataSource.indexPath(for: .line(last.seq)) {
                collectionView.scrollToItem(at: indexPath, at: .bottom, animated: true)
            }
        }
    }

    private func configure(_ cell: UICollectionViewListCell, _ item: Item) {
        guard let story else { return }
        var content = cell.defaultContentConfiguration()
        cell.accessories = []
        switch item {
        case .line(let seq):
            guard let line = story.lines.first(where: { $0.seq == seq }) else { break }
            content.text = line.text
            content.textProperties.numberOfLines = 0
            content.textProperties.font = Theme.Ramp.font(line.isProgress ? .rowMeta : .rowDetail)
            content.textProperties.color = line.isProgress ? Theme.Color.tertiaryLabel : (line.tone == .quiet ? Theme.Color.label : line.tone.color)
            content.directionalLayoutMargins.leading = line.isProgress ? Theme.Spacing.xl : Theme.Spacing.l
        case .attempt(let index):
            guard let attempt = story.attempts[safe: index] else { break }
            content.text = DelegateRunStory.attemptLine(attempt)
            content.textProperties.color = DelegateWords.tone(attempt.status) == .quiet ? Theme.Color.label : DelegateWords.tone(attempt.status).color
            var lines: [String] = []
            if let model = story.currentModel[attempt.tier] { lines.append(model) }
            lines.append(Localized.text("%@ in · %@ out", DelegateWords.tokens(attempt.tokensIn), DelegateWords.tokens(attempt.tokensOut)))
            if !attempt.changedFiles.isEmpty { lines.append(attempt.changedFiles.joined(separator: ", ")) }
            if attempt.status != .pass, !attempt.verifyTail.isEmpty {
                lines.append(attempt.verifyTail.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n").suffix(6).joined(separator: "\n"))
            }
            if !attempt.workerSummary.isEmpty, attempt.status == .pass {
                lines.append(String(attempt.workerSummary.prefix(400)))
            }
            content.secondaryText = lines.joined(separator: "\n")
            content.secondaryTextProperties.numberOfLines = 0
            content.secondaryTextProperties.font = Theme.Ramp.font(.code)
            content.secondaryTextProperties.color = Theme.Color.secondaryLabel
        case .applied:
            content.text = Localized.text("Applied %@ to the working tree, unstaged", DelegateWords.files(story.appliedFiles.count))
            content.secondaryText = story.appliedFiles.joined(separator: "\n")
            content.secondaryTextProperties.numberOfLines = 0
            content.secondaryTextProperties.font = Theme.Ramp.font(.code)
            content.secondaryTextProperties.color = Theme.Color.secondaryLabel
            content.image = UIImage(systemName: "checkmark.circle")
            content.imageProperties.tintColor = Theme.Color.success
        case .cancel:
            content.text = String(localized: "Cancel this run")
            content.textProperties.color = Theme.Color.danger
            content.image = UIImage(systemName: "xmark.circle")
            content.imageProperties.tintColor = Theme.Color.danger
        case .replay:
            content.text = String(localized: "Replay on another tier")
            content.secondaryText = String(localized: "The same packet, started where you choose")
            content.secondaryTextProperties.color = Theme.Color.secondaryLabel
            content.textProperties.color = Theme.Color.accent
            content.image = UIImage(systemName: "arrow.counterclockwise")
            content.imageProperties.tintColor = Theme.Color.accent
            cell.accessories = [.customView(configuration: .init(customView: replayButton(), placement: .trailing()))]
        case .ladder, .approval:
            break
        }
        cell.contentConfiguration = content
    }

    private func replayButton() -> UIButton {
        let button = UIButton(configuration: .plain())
        button.showsMenuAsPrimaryAction = true
        var config = UIButton.Configuration.plain()
        config.image = UIImage(systemName: "chevron.up.chevron.down", withConfiguration: UIImage.SymbolConfiguration(pointSize: 11, weight: .semibold))
        config.baseForegroundColor = Theme.Color.secondaryLabel
        button.configuration = config
        let tiers = desk.board(host: host, serverName: serverName).tierOrder
        button.menu = UIMenu(title: String(localized: "Start at"), children: tiers.map { tier in
            UIAction(title: tier) { [weak self] _ in self?.replay(tier: tier) }
        })
        return button
    }

    private func replay(tier: String) {
        Theme.Haptics.send()
        Task { [weak self] in
            guard let self else { return }
            do {
                let started = try await self.desk.replay(runID: self.runID, host: self.host, tier: tier, ceiling: nil)
                self.navigationController?.pushViewController(
                    DelegateRunViewController(host: self.host, serverName: self.serverName, runID: started), animated: true)
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

    private func cancel() {
        let alert = UIAlertController(
            title: String(localized: "Cancel this run?"),
            message: String(localized: "The attempt out on the machine finishes on its own; nothing after it starts."),
            preferredStyle: .actionSheet)
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
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = dataSource.itemIdentifier(for: indexPath) else { return }
        if case .cancel = item { cancel() }
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        let bottom = scrollView.contentOffset.y + scrollView.bounds.height
        followsBottom = bottom >= scrollView.contentSize.height - 80
    }
}

/// The ladder as a row of the run, read-only, wearing the story's states.
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
        self.ladder.rungs = ladder.rungs
        accessibilityLabel = ladder.spoken
    }
}

/// The two answers a gated rung waits for. Approve climbs; hold ends the run as held.
final class DelegateApprovalCell: UICollectionViewListCell {
    private let title = UILabel()
    private let reason = UILabel()
    private let approve = PrimaryButton(title: String(localized: "Approve"))
    private let hold = SecondaryButton(title: String(localized: "Hold"))
    private var onDecision: ((Bool) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        title.font = Theme.Ramp.font(.rowTitleStrong)
        title.numberOfLines = 0
        reason.font = Theme.Ramp.font(.rowDetail)
        reason.textColor = Theme.Color.secondaryLabel
        reason.numberOfLines = 0
        let buttons = UIStackView(arrangedSubviews: [approve, hold])
        buttons.axis = .horizontal
        buttons.distribution = .fillEqually
        buttons.spacing = Theme.Spacing.s
        let column = UIStackView(arrangedSubviews: [title, reason, buttons])
        column.axis = .vertical
        column.spacing = Theme.Spacing.s
        column.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Spacing.m),
            column.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -Theme.Spacing.m),
            column.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Theme.Spacing.l),
            column.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.l),
        ])
        approve.addAction(UIAction { [weak self] _ in self?.onDecision?(true) }, for: .touchUpInside)
        hold.addAction(UIAction { [weak self] _ in self?.onDecision?(false) }, for: .touchUpInside)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func show(tier: String, reason: String, onDecision: @escaping (Bool) -> Void) {
        title.text = Localized.text("Climb to %@?", tier)
        self.reason.text = reason
        self.onDecision = onDecision
    }
}
