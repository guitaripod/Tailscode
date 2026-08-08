import CodingAgentKit
import TailscodeCore
import UIKit

extension GitTone {
    var color: UIColor {
        switch self {
        case .added: return Theme.Color.success
        case .removed: return Theme.Color.danger
        case .changed: return Theme.Color.info
        case .untracked: return Theme.Color.tertiaryLabel
        case .conflict: return Theme.Color.warning
        case .neutral: return Theme.Color.secondaryLabel
        }
    }
}

/// What the repository behind this conversation is doing — and nothing about doing anything to it.
///
/// The panel is read-only by design: the state a change lands in is the thing that is genuinely
/// hard to know from a transcript, while a commit made from a phone is a commit nobody reviewed on
/// the machine that has to live with it. So it answers the questions a person actually has mid-turn
/// — which branch, how far from the upstream, what the agent has already touched, what a file's
/// change actually is — and offers no button that writes.
final class GitStatusViewController: UIViewController {
    private enum Section: Hashable {
        case header
        case files(GitSection.Kind)
        case commits
        case note
    }

    private enum Item: Hashable {
        case header
        case change(GitRow)
        case commit(GitCommitRow)
        case note(String)
    }

    private let backend: any GitObservingBackend
    private let directory: String?
    private let sessionID: String?
    private var state: GitState?
    private var loadFailure: String?
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Section, Item>!
    private let spinner = UIActivityIndicatorView(style: .medium)
    private let refresher = UIRefreshControl()

    init(backend: any GitObservingBackend, directory: String?, sessionID: String?) {
        self.backend = backend
        self.directory = directory
        self.sessionID = sessionID
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.groupedBackground
        title = String(localized: "Repository")
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done,
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })

        var configuration = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        configuration.headerMode = .supplementary
        configuration.backgroundColor = .clear
        collectionView = UICollectionView(
            frame: .zero,
            collectionViewLayout: UICollectionViewCompositionalLayout.list(using: configuration))
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.refreshControl = refresher
        refresher.addAction(UIAction { [weak self] _ in self?.load(showSpinner: false) }, for: .valueChanged)
        view.addSubview(collectionView)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.hidesWhenStopped = true
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])

        configureDataSource()
        load(showSpinner: true)
    }

    private func configureDataSource() {
        let header = UICollectionView.CellRegistration<GitHeaderCell, Item> {
            [weak self] cell, _, _ in
            guard let state = self?.state else { return }
            cell.apply(state)
        }
        let change = UICollectionView.CellRegistration<UICollectionViewListCell, GitRow> {
            cell, _, row in
            var content = cell.defaultContentConfiguration()
            content.text = row.name
            content.secondaryText = row.folder.isEmpty ? nil : row.folder
            if let original = row.original {
                content.secondaryText = String(localized: "was \(original)")
            }
            content.image = UIImage(
                systemName: row.kind.symbol,
                withConfiguration: UIImage.SymbolConfiguration(textStyle: .footnote))
            content.imageProperties.tintColor = row.tone.color
            content.textProperties.font = .preferredFont(forTextStyle: .subheadline)
            content.secondaryTextProperties.font = .preferredFont(forTextStyle: .caption2)
            content.secondaryTextProperties.color = Theme.Color.tertiaryLabel
            content.secondaryTextProperties.lineBreakMode = .byTruncatingHead
            cell.contentConfiguration = content
            cell.backgroundConfiguration = Self.rowBackground()
            cell.accessibilityLabel = row.spoken
            var accessories: [UICellAccessory] = [
                .disclosureIndicator(displayed: .always, options: .init(tintColor: Theme.Color.tertiaryLabel))
            ]
            if let counts = Self.counts(row) {
                let label = UILabel()
                label.attributedText = counts
                label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
                accessories.insert(
                    .customView(
                        configuration: .init(
                            customView: label, placement: .trailing(displayed: .always))),
                    at: 0)
            }
            cell.accessories = accessories
        }
        let commit = UICollectionView.CellRegistration<UICollectionViewListCell, GitCommitRow> {
            cell, _, row in
            var content = cell.defaultContentConfiguration()
            content.text = row.subject
            content.textProperties.numberOfLines = 2
            content.textProperties.font = .preferredFont(forTextStyle: .subheadline)
            var detail = [row.short, row.author, row.age]
            if !row.refs.isEmpty { detail.insert(row.refs.joined(separator: " · "), at: 1) }
            content.secondaryText = detail.joined(separator: " · ")
            content.secondaryTextProperties.font = .preferredFont(forTextStyle: .caption2)
            content.secondaryTextProperties.color = Theme.Color.tertiaryLabel
            content.image = UIImage(
                systemName: row.isHead ? "circle.circle.fill" : "circle",
                withConfiguration: UIImage.SymbolConfiguration(textStyle: .caption1))
            content.imageProperties.tintColor =
                row.isHead ? Theme.Color.accent : Theme.Color.tertiaryLabel
            cell.contentConfiguration = content
            cell.backgroundConfiguration = Self.rowBackground()
            cell.accessories = [.disclosureIndicator()]
        }
        let note = UICollectionView.CellRegistration<UICollectionViewListCell, String> {
            cell, _, text in
            var content = cell.defaultContentConfiguration()
            content.text = text
            content.textProperties.font = .preferredFont(forTextStyle: .footnote)
            content.textProperties.color = Theme.Color.secondaryLabel
            content.textProperties.numberOfLines = 0
            cell.contentConfiguration = content
            cell.backgroundConfiguration = Self.rowBackground()
        }

        dataSource = UICollectionViewDiffableDataSource<Section, Item>(
            collectionView: collectionView
        ) { view, indexPath, item in
            switch item {
            case .header:
                return view.dequeueConfiguredReusableCell(
                    using: header, for: indexPath, item: item)
            case .change(let row):
                return view.dequeueConfiguredReusableCell(using: change, for: indexPath, item: row)
            case .commit(let row):
                return view.dequeueConfiguredReusableCell(using: commit, for: indexPath, item: row)
            case .note(let text):
                return view.dequeueConfiguredReusableCell(using: note, for: indexPath, item: text)
            }
        }

        let sectionHeader = UICollectionView.SupplementaryRegistration<
            UICollectionViewListCell
        >(elementKind: UICollectionView.elementKindSectionHeader) { [weak self] cell, _, indexPath in
            guard let self, let section = self.dataSource.sectionIdentifier(for: indexPath.section)
            else { return }
            var content = cell.defaultContentConfiguration()
            switch section {
            case .files(let kind):
                content.text = kind.title
                let rows =
                    self.state?.sections.first { $0.kind == kind }?.rows.count ?? 0
                content.secondaryText = String(localized: "\(rows)")
                content.textProperties.color = kind.tone.color
            case .commits:
                content.text = String(localized: "RECENT COMMITS")
            case .header, .note:
                content.text = nil
            }
            content.textProperties.font = .preferredFont(forTextStyle: .caption1).withTraits(
                .traitBold)
            content.secondaryTextProperties.font = .preferredFont(forTextStyle: .caption2)
            content.secondaryTextProperties.color = Theme.Color.tertiaryLabel
            content.prefersSideBySideTextAndSecondaryText = true
            cell.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { view, kind, indexPath in
            view.dequeueConfiguredReusableSupplementary(using: sectionHeader, for: indexPath)
        }
    }

    private static func rowBackground() -> UIBackgroundConfiguration {
        var background = UIBackgroundConfiguration.listGroupedCell()
        background.backgroundColor = Theme.Color.groupedSurface
        return background
    }

    /// Two numbers that mean opposite things, so they are never one colour. Nothing is drawn for a
    /// file with no lines to count — a `+0` is a number a reader has to stop and dismiss.
    private static func counts(_ row: GitRow) -> NSAttributedString? {
        guard row.hasCounts || !row.detail.isEmpty else { return nil }
        guard row.hasCounts else {
            return NSAttributedString(
                string: row.detail, attributes: [.foregroundColor: Theme.Color.tertiaryLabel])
        }
        let text = NSMutableAttributedString()
        if row.insertions > 0 {
            text.append(
                NSAttributedString(
                    string: "+\(GitState.number(row.insertions))",
                    attributes: [.foregroundColor: Theme.Color.success]))
        }
        if row.deletions > 0 {
            if text.length > 0 { text.append(NSAttributedString(string: " ")) }
            text.append(
                NSAttributedString(
                    string: "−\(GitState.number(row.deletions))",
                    attributes: [.foregroundColor: Theme.Color.danger]))
        }
        return text
    }

    private func load(showSpinner: Bool) {
        if showSpinner { spinner.startAnimating() }
        Task { [weak self] in
            guard let self else { return }
            do {
                let snapshot = try await self.backend.gitSnapshot(
                    directory: self.directory, sessionID: self.sessionID)
                self.state = snapshot.map { GitState(snapshot: $0) }
                self.loadFailure = snapshot == nil
                    ? String(localized: "This server does not report repository state.") : nil
            } catch {
                self.loadFailure = String(localized: "Could not read the repository.")
            }
            self.spinner.stopAnimating()
            self.refresher.endRefreshing()
            self.apply()
        }
    }

    private func apply() {
        var snapshot = NSDiffableDataSourceSnapshot<Section, Item>()
        if state != nil {
            snapshot.appendSections([.header])
            snapshot.appendItems([.header], toSection: .header)
        }
        if let state {
            for section in state.sections {
                snapshot.appendSections([.files(section.kind)])
                snapshot.appendItems(section.rows.map(Item.change), toSection: .files(section.kind))
            }
            var notes: [Item] = []
            if state.truncated, state.hiddenCount > 0 {
                notes.append(
                    .note(
                        String(
                            localized:
                                "\(state.hiddenCount) more changed paths are not listed.")))
            }
            if state.isClean, state.isRepository {
                notes.append(.note(String(localized: "Nothing has been touched since the last commit.")))
            }
            if !state.isRepository {
                notes.append(
                    .note(String(localized: "This conversation is not working inside a git repository.")))
            }
            if !notes.isEmpty {
                snapshot.appendSections([.note])
                snapshot.appendItems(notes, toSection: .note)
            }
            if !state.commits.isEmpty {
                snapshot.appendSections([.commits])
                snapshot.appendItems(state.commits.map(Item.commit), toSection: .commits)
            }
        } else if let loadFailure {
            snapshot.appendSections([.note])
            snapshot.appendItems([.note(loadFailure)], toSection: .note)
        }
        dataSource.apply(snapshot, animatingDifferences: false)
    }

    private func openDiff(_ row: GitRow) {
        Theme.Haptics.tap()
        let viewer = GitDiffViewController(
            title: row.name, subtitle: row.path,
            load: { [backend, directory, sessionID] in
                try await backend.gitPatch(
                    directory: directory, sessionID: sessionID, path: row.path, staged: row.staged)?
                    .patch
            })
        navigationController?.pushViewController(viewer, animated: true)
    }

    private func openCommit(_ row: GitCommitRow) {
        Theme.Haptics.tap()
        let viewer = GitDiffViewController(
            title: row.subject, subtitle: "\(row.short) · \(row.author) · \(row.age)",
            load: { [backend, directory, sessionID] in
                try await backend.gitCommit(
                    directory: directory, sessionID: sessionID, hash: row.hash)?.patch
            })
        navigationController?.pushViewController(viewer, animated: true)
    }
}

extension GitStatusViewController {
    enum FirstKind {
        case change
        case commit
    }

    /// Opens the first row of a kind without a tap, so a screenshot run can reach the diff and the
    /// commit the same way a finger does.
    func openFirst(_ kind: FirstKind) {
        switch kind {
        case .change:
            guard let row = state?.sections.first?.rows.first else { return }
            openDiff(row)
        case .commit:
            guard let row = state?.commits.first else { return }
            openCommit(row)
        }
    }
}

extension GitStatusViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        switch dataSource.itemIdentifier(for: indexPath) {
        case .change(let row): openDiff(row)
        case .commit(let row): openCommit(row)
        default: break
        }
    }
}

/// The header: the branch first because it is the answer to "where am I", then what it owes the
/// upstream, then one line for the working tree — and, when the repository has stopped mid-merge,
/// a line that says so above all of it.
final class GitHeaderCell: UICollectionViewListCell {
    private let branch = UILabel()
    private let sync = UILabel()
    private let summary = UILabel()
    private let alert = UILabel()
    private let alertBox = UIView()
    private let facts = UIStackView()
    private let column = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        branch.font = .systemFont(ofSize: 26, weight: .bold)
        branch.textColor = Theme.Color.label
        branch.adjustsFontSizeToFitWidth = true
        branch.minimumScaleFactor = 0.6
        branch.lineBreakMode = .byTruncatingMiddle
        sync.font = .preferredFont(forTextStyle: .subheadline)
        summary.font = .preferredFont(forTextStyle: .footnote)
        summary.textColor = Theme.Color.secondaryLabel
        summary.numberOfLines = 0
        alert.font = .preferredFont(forTextStyle: .footnote).withTraits(.traitBold)
        alert.textColor = Theme.Color.warning
        alert.numberOfLines = 0
        alertBox.backgroundColor = Theme.Color.warning.withAlphaComponent(0.14)
        alertBox.layer.cornerRadius = Theme.Radius.control
        alertBox.layer.cornerCurve = .continuous
        alert.translatesAutoresizingMaskIntoConstraints = false
        alertBox.addSubview(alert)
        NSLayoutConstraint.activate([
            alert.topAnchor.constraint(equalTo: alertBox.topAnchor, constant: Theme.Spacing.s),
            alert.bottomAnchor.constraint(
                equalTo: alertBox.bottomAnchor, constant: -Theme.Spacing.s),
            alert.leadingAnchor.constraint(
                equalTo: alertBox.leadingAnchor, constant: Theme.Spacing.m),
            alert.trailingAnchor.constraint(
                equalTo: alertBox.trailingAnchor, constant: -Theme.Spacing.m),
        ])
        facts.axis = .vertical
        facts.spacing = 2
        column.axis = .vertical
        column.spacing = Theme.Spacing.xs
        column.addArrangedSubview(branch)
        column.addArrangedSubview(sync)
        column.addArrangedSubview(summary)
        column.addArrangedSubview(alertBox)
        column.setCustomSpacing(Theme.Spacing.m, after: alertBox)
        column.addArrangedSubview(facts)
        column.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Spacing.m),
            column.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor, constant: -Theme.Spacing.m),
            column.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: Theme.Spacing.m),
            column.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.m),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func apply(_ state: GitState) {
        branch.text = state.title
        sync.text = state.sync
        sync.textColor = state.syncTone.color
        summary.text = state.summary
        alert.text = state.alert
        alertBox.isHidden = state.alert == nil
        facts.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for fact in state.facts {
            let name = UILabel()
            name.text = fact.label
            name.font = .preferredFont(forTextStyle: .caption1)
            name.textColor = Theme.Color.tertiaryLabel
            name.setContentHuggingPriority(.required, for: .horizontal)
            let value = UILabel()
            value.text = fact.value
            value.font = .preferredFont(forTextStyle: .caption1)
            value.textColor = fact.tone == .neutral ? Theme.Color.label : fact.tone.color
            value.textAlignment = .right
            value.lineBreakMode = .byTruncatingHead
            let row = UIStackView(arrangedSubviews: [name, value])
            row.axis = .horizontal
            row.spacing = Theme.Spacing.m
            row.isAccessibilityElement = true
            row.accessibilityLabel = "\(fact.label), \(fact.value)"
            facts.addArrangedSubview(row)
        }
        var background = UIBackgroundConfiguration.listGroupedCell()
        background.backgroundColor = Theme.Color.groupedSurface
        backgroundConfiguration = background
    }
}
