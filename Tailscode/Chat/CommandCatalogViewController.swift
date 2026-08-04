import CodingAgentKit
import TailscodeCore
import UIKit

/// Every command this server offers, on one browsable surface. The palette above the composer is
/// for speed — it lives or dies on the letters already typed. This is for discovery: a server can
/// contribute dozens of commands from plugins, projects, MCP servers and skills, and nobody can
/// complete a name they have never seen. Grouped by where each command came from, searchable
/// through the same shared ranking the palette uses, and honest about which ones want arguments.
@MainActor
final class CommandCatalogViewController: UIViewController {
    /// Picking a command hands it back rather than running it here: a command that takes
    /// arguments belongs in the composer half-typed, and only the chat knows about `/compact`'s
    /// preflight or a `/goal`'s own sheet.
    var onPick: ((AgentCommand) -> Void)?

    private struct Group: Hashable {
        let id: String
        let name: String
    }

    private let commands: [AgentCommand]
    private var collectionView: UICollectionView!
    private var dataSource: UICollectionViewDiffableDataSource<Group, AgentCommand>!
    private let search = UISearchController(searchResultsController: nil)
    private var query = ""

    init(commands: [AgentCommand]) {
        self.commands = commands
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Commands")
        view.backgroundColor = Theme.Color.groupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close, target: self, action: #selector(close))
        configureSearch()
        configureCollectionView()
        applySnapshot()
    }

    private func configureSearch() {
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = String(localized: "Search \(commands.count) commands")
        search.searchBar.autocapitalizationType = .none
        search.searchBar.autocorrectionType = .no
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
    }

    private func configureCollectionView() {
        var config = UICollectionLayoutListConfiguration(appearance: .insetGrouped)
        config.headerMode = .supplementary
        let layout = UICollectionViewCompositionalLayout.list(using: config)
        collectionView = UICollectionView(frame: view.bounds, collectionViewLayout: layout)
        collectionView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        collectionView.backgroundColor = .clear
        collectionView.delegate = self
        collectionView.keyboardDismissMode = .onDrag
        view.addSubview(collectionView)

        let cell = UICollectionView.CellRegistration<UICollectionViewListCell, AgentCommand> {
            cell, _, command in
            var content = cell.defaultContentConfiguration()
            content.attributedText = Self.signature(command)
            content.secondaryText = Self.detail(command)
            content.secondaryTextProperties.color = Theme.Color.secondaryLabel
            content.secondaryTextProperties.numberOfLines = 3
            content.image = UIImage(
                systemName: CommandSymbol.of(command),
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 15, weight: .medium))
            content.imageProperties.tintColor = Theme.Color.accent
            cell.contentConfiguration = content
            cell.accessories = [.disclosureIndicator()]
        }

        let header = UICollectionView.SupplementaryRegistration<UICollectionViewListCell>(
            elementKind: UICollectionView.elementKindSectionHeader
        ) { [weak self] view, _, indexPath in
            guard let self, let group = self.dataSource.sectionIdentifier(for: indexPath.section)
            else { return }
            var content = UIListContentConfiguration.header()
            let count = self.dataSource.snapshot().numberOfItems(inSection: group)
            content.text = "\(group.name.uppercased())  ·  \(count)"
            view.contentConfiguration = content
        }

        dataSource = UICollectionViewDiffableDataSource(collectionView: collectionView) {
            collectionView, indexPath, command in
            collectionView.dequeueConfiguredReusableCell(using: cell, for: indexPath, item: command)
        }
        dataSource.supplementaryViewProvider = { collectionView, _, indexPath in
            collectionView.dequeueConfiguredReusableSupplementary(using: header, for: indexPath)
        }
    }

    /// A search reorders into one relevance-ranked run — grouping by source there would scatter
    /// the best match down the screen. Unsearched, the sections are the useful shape.
    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<Group, AgentCommand>()
        guard query.isEmpty else {
            let ranked = SlashCompletion.ranked(
                filteredByDetails(query), query: query,
                recents: SlashRecents.surviving(in: commands))
            let group = Group(id: "·results", name: String(localized: "Results"))
            if !ranked.isEmpty {
                snapshot.appendSections([group])
                snapshot.appendItems(ranked.map(\.command), toSection: group)
            }
            dataSource.apply(snapshot, animatingDifferences: false)
            contentUnavailableConfiguration =
                ranked.isEmpty ? UIContentUnavailableConfiguration.search() : nil
            return
        }

        let recents = SlashRecents.surviving(in: commands)
            .compactMap { name in commands.first { $0.name == name } }
        if !recents.isEmpty {
            let group = Group(id: "·recent", name: String(localized: "Recent"))
            snapshot.appendSections([group])
            snapshot.appendItems(recents, toSection: group)
        }
        for source in sourceOrder {
            let members = commands
                .filter { $0.source == source && !recents.contains($0) }
                .sorted { $0.name < $1.name }
            guard !members.isEmpty else { continue }
            let group = Group(id: source.rawValue, name: Self.sourceName(source))
            snapshot.appendSections([group])
            snapshot.appendItems(members, toSection: group)
        }
        dataSource.apply(snapshot, animatingDifferences: false)
        contentUnavailableConfiguration = commands.isEmpty ? emptyCatalog : nil
    }

    private var sourceOrder: [AgentCommand.Source] {
        [.builtin, .project, .user, .plugin, .skill, .mcp, .custom]
    }

    private var emptyCatalog: UIContentUnavailableConfiguration {
        var config = UIContentUnavailableConfiguration.empty()
        config.image = UIImage(systemName: "terminal")
        config.text = String(localized: "No commands")
        config.secondaryText = String(
            localized: "This server didn't offer a command catalog. Typed slashes still go through as messages.")
        return config
    }

    /// A search matches a command's description too — half the time the name is the thing being
    /// looked for, and the ranking cannot rank what it never sees.
    private func filteredByDetails(_ query: String) -> [AgentCommand] {
        let ranked = Set(SlashCompletion.ranked(commands, query: query).map(\.command.name))
        let byDetails = commands.filter {
            !ranked.contains($0.name)
                && ($0.details.localizedCaseInsensitiveContains(query)
                    || ($0.scope?.localizedCaseInsensitiveContains(query) ?? false))
        }
        return commands.filter { ranked.contains($0.name) } + byDetails
    }

    private static func signature(_ command: AgentCommand) -> NSAttributedString {
        let line = NSMutableAttributedString(
            string: "/\(command.name)",
            attributes: [
                .font: Theme.Font.body(), .foregroundColor: Theme.Color.label,
            ])
        guard let hint = command.argumentHint, !hint.isEmpty else { return line }
        line.append(
            NSAttributedString(
                string: " \(hint)",
                attributes: [
                    .font: Theme.Font.mono(12), .foregroundColor: Theme.Color.tertiaryLabel,
                ]))
        return line
    }

    private static func detail(_ command: AgentCommand) -> String? {
        let parts = [command.details, command.scope]
            .compactMap { $0?.isEmpty == false ? $0 : nil }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private static func sourceName(_ source: AgentCommand.Source) -> String {
        switch source {
        case .builtin: return String(localized: "Built in")
        case .user: return String(localized: "Yours")
        case .project: return String(localized: "This project")
        case .plugin: return String(localized: "Plugins")
        case .mcp: return String(localized: "MCP servers")
        case .skill: return String(localized: "Skills")
        case .custom: return String(localized: "Other")
        }
    }

    @objc private func close() { dismiss(animated: true) }
}

extension CommandCatalogViewController: UICollectionViewDelegate {
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let command = dataSource.itemIdentifier(for: indexPath) else { return }
        Theme.Haptics.selection()
        dismiss(animated: true) { [onPick] in onPick?(command) }
    }
}

extension CommandCatalogViewController: UISearchResultsUpdating {
    func updateSearchResults(for searchController: UISearchController) {
        let raw = searchController.searchBar.text ?? ""
        query = raw.trimmingCharacters(in: .whitespaces).drop { $0 == "/" }.lowercased()
        applySnapshot()
    }
}

/// The glyph a command wears, wherever it is drawn. Well-known verbs get their own; everything
/// else is named by where it came from, which is the most useful thing a stranger's command can
/// say about itself.
enum CommandSymbol {
    static func of(_ command: AgentCommand) -> String {
        switch command.name {
        case "goal": return "target"
        case "recap": return "text.line.first.and.arrowtriangle.forward"
        case "compact": return "arrow.down.right.and.arrow.up.left"
        case "context": return "chart.pie"
        case "usage", "cost": return "creditcard"
        case "init": return "doc.badge.plus"
        case "review": return "checklist"
        case "clear": return "eraser"
        case "help": return "questionmark.circle"
        case "model": return "cpu"
        case "test": return "testtube.2"
        case "commit": return "checkmark.seal"
        default: break
        }
        switch command.source {
        case .plugin: return "puzzlepiece.extension"
        case .project: return "folder"
        case .mcp: return "cable.connector"
        case .skill: return "wand.and.stars"
        case .user: return "person"
        default: return "terminal"
        }
    }
}
