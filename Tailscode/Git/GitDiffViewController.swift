import TailscodeCore
import UIKit

/// One file's change, or one commit's, read the way a reviewer reads it: what left in red, what
/// arrived in green, each line still carrying the number it has in the file.
///
/// The numbering is the point. A diff a reader cannot locate in the file is a diff they have to
/// open an editor to act on, and the whole reason to look at this on a phone is to decide whether
/// to tell the agent to keep going.
final class GitDiffViewController: UIViewController {
    private let subtitleText: String
    private let load: @Sendable () async throws -> String?
    private var lines: [GitDiffLine] = []
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Int, GitDiffLine>!
    private let spinner = ActivityBadgeView(pointSize: 16)
    private let emptyLabel = UILabel()

    init(title: String, subtitle: String, load: @escaping @Sendable () async throws -> String?) {
        self.subtitleText = subtitle
        self.load = load
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.background

        var configuration = UICollectionLayoutListConfiguration(appearance: .plain)
        configuration.showsSeparators = false
        configuration.backgroundColor = .clear
        configuration.headerMode = .supplementary
        collectionView = UICollectionView(
            frame: .zero,
            collectionViewLayout: UICollectionViewCompositionalLayout.list(using: configuration))
        collectionView.backgroundColor = Theme.Color.codeBackground
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(collectionView)
        spinner.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(spinner)
        emptyLabel.font = Theme.Ramp.font(.panelDetail)
        emptyLabel.textColor = Theme.Color.secondaryLabel
        emptyLabel.textAlignment = .center
        emptyLabel.numberOfLines = 0
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            collectionView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            collectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            collectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            spinner.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            emptyLabel.leadingAnchor.constraint(
                equalTo: view.leadingAnchor, constant: Theme.Spacing.xl),
            emptyLabel.trailingAnchor.constraint(
                equalTo: view.trailingAnchor, constant: -Theme.Spacing.xl),
        ])

        let cell = UICollectionView.CellRegistration<GitDiffLineCell, GitDiffLine> { cell, _, line in
            cell.apply(line)
        }
        dataSource = UICollectionViewDiffableDataSource<Int, GitDiffLine>(
            collectionView: collectionView
        ) { view, indexPath, line in
            view.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: line)
        }
        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] cell, _, _ in
            guard let self else { return }
            var content = cell.defaultContentConfiguration()
            content.text = self.subtitleText
            content.textProperties.font = Theme.Ramp.font(.panelDetail)
            content.textProperties.color = Theme.Color.secondaryLabel
            content.textProperties.numberOfLines = 2
            let stats = GitPatchReader.stats(self.lines)
            content.secondaryText = "+\(stats.insertions) −\(stats.deletions)"
            content.secondaryTextProperties.font = .monospacedDigitSystemFont(
                ofSize: 12, weight: .medium)
            content.secondaryTextProperties.color = Theme.Color.tertiaryLabel
            content.prefersSideBySideTextAndSecondaryText = true
            cell.contentConfiguration = content
            var background = UIBackgroundConfiguration.listPlainCell()
            background.backgroundColor = Theme.Color.background
            cell.backgroundConfiguration = background
        }
        dataSource.supplementaryViewProvider = { view, _, indexPath in
            view.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }

        spinner.working(true, spoken: String(localized: "Loading the diff"))
        Task { [weak self] in
            guard let self else { return }
            let patch = (try? await self.load()) ?? nil
            self.lines = GitPatchReader.lines(patch ?? "")
            self.spinner.working(false)
            if self.lines.isEmpty {
                self.emptyLabel.text = patch == nil
                    ? String(localized: "This server could not produce a diff for that.")
                    : String(localized: "No textual change to show.")
                self.emptyLabel.isHidden = false
            }
            var snapshot = NSDiffableDataSourceSnapshot<Int, GitDiffLine>()
            snapshot.appendSections([0])
            snapshot.appendItems(self.lines, toSection: 0)
            await self.dataSource.apply(snapshot, animatingDifferences: false)
        }
    }
}

/// One line of a patch: its number in the file it belongs to, and the line itself on a wash of the
/// colour its meaning has. The gutter is a fixed width so the code starts at the same x on every
/// row — a column that jogs is a column the eye stops trusting.
final class GitDiffLineCell: UICollectionViewCell {
    private let gutter = UILabel()
    private let sign = UILabel()
    private let code = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        gutter.font = .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        gutter.textColor = Theme.Color.tertiaryLabel
        gutter.textAlignment = .right
        sign.font = .monospacedSystemFont(ofSize: 11, weight: .semibold)
        sign.textAlignment = .center
        code.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        code.numberOfLines = 0
        code.lineBreakMode = .byCharWrapping
        let row = UIStackView(arrangedSubviews: [gutter, sign, code])
        row.axis = .horizontal
        row.spacing = 4
        row.alignment = .top
        row.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(row)
        NSLayoutConstraint.activate([
            gutter.widthAnchor.constraint(equalToConstant: 34),
            sign.widthAnchor.constraint(equalToConstant: 10),
            row.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 1),
            row.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -1),
            row.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 6),
            row.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func apply(_ line: GitDiffLine) {
        switch line.kind {
        case .addition:
            gutter.text = line.newLine.map(String.init) ?? ""
            sign.text = "+"
            sign.textColor = Theme.Color.success
            code.textColor = Theme.Color.label
            contentView.backgroundColor = Theme.Color.success.withAlphaComponent(0.12)
        case .deletion:
            gutter.text = line.oldLine.map(String.init) ?? ""
            sign.text = "−"
            sign.textColor = Theme.Color.danger
            code.textColor = Theme.Color.label
            contentView.backgroundColor = Theme.Color.danger.withAlphaComponent(0.12)
        case .hunk:
            gutter.text = ""
            sign.text = ""
            code.textColor = Theme.Color.info
            contentView.backgroundColor = Theme.Color.info.withAlphaComponent(0.10)
        case .meta:
            gutter.text = ""
            sign.text = ""
            code.textColor = Theme.Color.tertiaryLabel
            contentView.backgroundColor = .clear
        case .context:
            gutter.text = line.newLine.map(String.init) ?? ""
            sign.text = ""
            code.textColor = Theme.Color.secondaryLabel
            contentView.backgroundColor = .clear
        }
        code.text = line.text.isEmpty ? " " : line.text
        isAccessibilityElement = true
        accessibilityLabel = Self.spoken(line)
    }

    private static func spoken(_ line: GitDiffLine) -> String {
        switch line.kind {
        case .addition: return String(localized: "added, \(line.text)")
        case .deletion: return String(localized: "removed, \(line.text)")
        case .hunk: return String(localized: "section, \(line.text)")
        case .meta: return line.text
        case .context: return line.text
        }
    }
}
