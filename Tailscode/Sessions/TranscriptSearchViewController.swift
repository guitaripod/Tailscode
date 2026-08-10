import CodingAgentKit
import TailscodeCore
import UIKit

/// What was actually said, everywhere.
///
/// The list above this one matches titles, which is instant and local and misses everything that
/// matters: the answer, the diff, the command that finally worked. Submitting the query asks every
/// connected server at once and lands here, one ranked list rather than a pile per machine.
///
/// It states its own coverage rather than implying it. A result screen is read as an absence, and
/// an absence is read as an answer, so a server that could only be matched on titles, gave up
/// early, or never replied is named under the results instead of quietly contributing nothing.
@MainActor
final class TranscriptSearchViewController: UIViewController {
    private let query: String
    private let sources: [TranscriptSearch.Source]
    private let onOpen: (String, String) -> Void

    private var board: TranscriptSearch.Board?
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, TranscriptSearch.Row>!
    private let spinner = UIActivityIndicatorView(style: .medium)
    private var searchTask: Task<Void, Never>?

    init(
        query: String, sources: [TranscriptSearch.Source],
        onOpen: @escaping (String, String) -> Void
    ) {
        self.query = query
        self.sources = sources
        self.onOpen = onOpen
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    deinit { searchTask?.cancel() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "“\(query)”"
        navigationItem.largeTitleDisplayMode = .never
        view.backgroundColor = Theme.Color.groupedBackground
        configureCollectionView()
        configureDataSource()
        spinner.translatesAutoresizingMaskIntoConstraints = false
        spinner.startAnimating()
        view.addSubview(spinner)
        NSLayoutConstraint.activate([
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        run()
    }

    private func run() {
        let query = query
        let sources = sources
        searchTask = Task { [weak self] in
            let found = await TranscriptSearch.run(query: query, sources: sources)
            guard !Task.isCancelled else { return }
            self?.board = found
            self?.spinner.stopAnimating()
            self?.applySnapshot()
        }
    }

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Int, TranscriptSearch.Row>()
        snapshot.appendSections([0])
        snapshot.appendItems(board?.rows ?? [], toSection: 0)
        dataSource.apply(snapshot, animatingDifferences: false)
        updateEmptyState()
    }

    private func updateEmptyState() {
        guard let board, board.isEmpty else {
            contentUnavailableConfiguration = nil
            return
        }
        var config = UIContentUnavailableConfiguration.empty()
        config.image = UIImage(systemName: "text.magnifyingglass")
        config.text = String(localized: "Nothing said “\(query)”")
        config.secondaryText =
            TranscriptSearch.caveat(for: board)
            ?? String(localized: "Every server was searched, all the way through.")
        contentUnavailableConfiguration = config
    }

    private func configureCollectionView() {
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.footerMode = .supplementary
        let layout = UICollectionViewCompositionalLayout.list(using: config)
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        view.addSubview(collectionView)
    }

    private func configureDataSource() {
        let cell = UICollectionView.CellRegistration<
            TranscriptSearchCell, TranscriptSearch.Row
        > { cell, _, row in cell.configure(row) }
        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
            view, indexPath, row in
            view.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: row)
        }
        let footer = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionFooter
        ) { [weak self] view, _, _ in
            var content = view.defaultContentConfiguration()
            content.text = self?.board.flatMap(TranscriptSearch.caveat)
            content.textProperties.font = Theme.Ramp.font(.panelDetail)
            content.textProperties.color = Theme.Color.secondaryLabel
            view.contentConfiguration = content
        }
        dataSource.supplementaryViewProvider = { view, _, indexPath in
            view.dequeueConfiguredReusableSupplementary(using: footer, for: indexPath)
        }
    }
}

extension TranscriptSearchViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let row = dataSource.itemIdentifier(for: indexPath) else { return }
        Theme.Haptics.tap()
        onOpen(row.profileID, row.sessionID)
    }
}

/// One conversation the words were found in: what it is, where it lives, and the places it said
/// them — each quoted under the register it was in, so an answer, a thought and a shell command
/// are told apart at a glance rather than read for.
final class TranscriptSearchCell: UICollectionViewListCell {
    private let titleLabel = UILabel()
    private let whereLabel = UILabel()
    private let quotes = UIStackView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        titleLabel.font = Theme.Ramp.font(.cardTitle)
        titleLabel.textColor = Theme.Color.label
        titleLabel.numberOfLines = 1

        whereLabel.font = Theme.Ramp.font(.panelFootnote)
        whereLabel.textColor = Theme.Color.secondaryLabel
        whereLabel.numberOfLines = 1

        quotes.axis = .vertical
        quotes.spacing = 2

        let column = UIStackView(arrangedSubviews: [titleLabel, whereLabel, quotes])
        column.axis = .vertical
        column.spacing = 3
        column.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(column)
        NSLayoutConstraint.activate([
            column.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor, constant: Theme.Spacing.m),
            column.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor, constant: -Theme.Spacing.m),
            column.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Theme.Spacing.s),
            column.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor, constant: -Theme.Spacing.s),
        ])
        accessories = [.disclosureIndicator()]
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    func configure(_ row: TranscriptSearch.Row) {
        titleLabel.text = SessionListViewController.displayTitle(row.title)
        whereLabel.text =
            ([row.project, row.profileName].compactMap { $0 }
            + (row.isTitleOnly ? [String(localized: "title only")] : []))
            .joined(separator: " · ")
        quotes.arrangedSubviews.forEach {
            quotes.removeArrangedSubview($0)
            $0.removeFromSuperview()
        }
        for match in row.matches.prefix(3) { quotes.addArrangedSubview(Self.quote(match)) }
        if row.total > row.matches.count {
            let more = UILabel()
            more.font = Theme.Ramp.font(.panelFootnote)
            more.textColor = Theme.Color.tertiaryLabel
            more.text = String(localized: "… \(row.total - row.matches.count) more in this chat")
            quotes.addArrangedSubview(more)
        }
        accessibilityLabel = row.title
    }

    private static func quote(_ match: TranscriptMatch) -> UIView {
        let kind = UILabel()
        kind.font = Theme.Ramp.font(.metricLabel)
        kind.textColor = Theme.Color.accent
        kind.text = TranscriptSearch.label(for: match)
        kind.setContentCompressionResistancePriority(.required, for: .horizontal)

        let text = UILabel()
        text.font = Theme.Ramp.font(.panelFootnote)
        text.textColor = Theme.Color.secondaryLabel
        text.text = match.text
        text.numberOfLines = 2

        let row = UIStackView(arrangedSubviews: [kind, text])
        row.axis = .horizontal
        row.spacing = 6
        row.alignment = .top
        return row
    }
}
