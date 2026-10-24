import CodingAgentKit
import TailscodeCore
import UIKit

/// Every model the server offers, from every provider, as one list.
///
/// A catalog is not a menu. Two hundred rows, each repeating the same provider key under a name,
/// is a thing to scroll past rather than choose from — so the sections are model families, the
/// provider is a fact on the row beside the id, and the same model reached through two gateways is
/// one row that says so and opens onto both. None of that is decided here: `ModelChooser` in the
/// Kit folds, ranks and walks the catalog, and this draws its answer.
@MainActor
final class ModelPickerViewController: UIViewController {
    let onSelect: (ModelPick) -> Void
    var chooser: ModelChooser
    let quotas: [UsageQuota]
    let recents: [ModelSelection]
    /// Runs when the picker leaves the screen by any road — a pick, the close button, a swipe-down —
    /// so the caller stops watching a catalog nobody is looking at.
    var onClose: (() -> Void)?

    /// What the picker needs to speak for the chat that opened it: the model's name and levels for
    /// the effort strip, the level in force for the pairs a swipe pins, and how big the
    /// conversation is for the cost of switching.
    struct Dial {
        let modelName: String
        var chip: ModelChip? = nil
        let options: [String]
        let agentOptions: [String]
        var effort: String?
        let contextTokens: Int?
        let onEffort: (String?) -> Void
    }

    /// Where the picker was opened from, which decides what a pick means and what the sheet says
    /// about it: a pick in a chat changes that chat, one from Home aims the message being written,
    /// and one from a server's own screen sets what that server runs by default. A pick from an
    /// answer's menu branches the chat from that question, on this machine or another. A pick from
    /// a party slot fills that slot, anywhere, and changes nothing else.
    enum Context {
        case chat, composer, serverDefault, branch, party

        var chooser: ChooserContext {
            switch self {
            case .chat: return .chat
            case .composer: return .composer
            case .serverDefault: return .serverDefault
            case .branch: return .branch
            case .party: return .party
            }
        }
    }

    let context: Context
    var dial: Dial?
    let effortStrip = EffortStripView()
    var collectionView: UICollectionView!
    var dataSource: UICollectionViewDiffableDataSource<String, String>!
    let search = UISearchController(searchResultsController: nil)
    let machineStrip = ChipStripView()
    let doorStrip = ChipStripView()
    let consequence = UILabel()
    let above = BandView()
    let aboveClip = ClippingBand()
    private var didScrollToSelected = false
    var sectionIDs: [String] = []
    var rowsByID: [String: ModelChooserRow] = [:]

    init(
        sources: [ModelSource], selected: ModelSelection?, quotas: [UsageQuota] = [],
        recents: [ModelSelection] = RecentModelsStore.all(), dial: Dial? = nil,
        context: Context = .chat, onSelect: @escaping (ModelPick) -> Void
    ) {
        self.context = context
        self.dial = dial
        self.chooser = Self.makeChooser(
            sources: sources, selected: selected, recents: recents, quotas: quotas, dial: dial,
            context: context)
        self.onSelect = onSelect
        self.quotas = quotas
        self.recents = recents
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// The list is told what the chat is doing — its level, and what each model can take — so a
    /// row can say what a pick would run at, and pinned pairs lead the list when there is a level
    /// to pair a model with. A server's own screen has neither: it sets a default, not a send.
    static func makeChooser(
        sources: [ModelSource], selected: ModelSelection?, recents: [ModelSelection],
        quotas: [UsageQuota], dial: Dial?, context: Context
    ) -> ModelChooser {
        ModelChooser(
            sources: sources, selected: selected, recents: recents, quotas: quotas,
            showsPairs: dial != nil && context != .serverDefault && context != .party,
            aim: dial.map { ChooserAim(effort: $0.effort, agentOptions: $0.agentOptions) })
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "Model")
        view.backgroundColor = Theme.Color.groupedBackground
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close, target: self, action: #selector(close))
        configureSearch()
        configureCollectionView()
        configureMachines()
        applySnapshot()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (picker: ModelPickerViewController, _) in
            picker.syncMachines()
            picker.applySnapshot(keepingScroll: true)
            picker.scrollBand()
        }
    }

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        scrollToSelected()
    }

    private func scrollToSelected() {
        guard !didScrollToSelected, let focused = chooser.focused, focused.isAuto == false else {
            return
        }
        didScrollToSelected = true
        guard let indexPath = dataSource.indexPath(for: focused.id) else { return }
        collectionView.scrollToItem(at: indexPath, at: .centeredVertically, animated: false)
    }

    private func configureSearch() {
        search.searchResultsUpdater = self
        search.obscuresBackgroundDuringPresentation = false
        search.searchBar.placeholder = String(localized: "Search models, providers, ids")
        navigationItem.searchController = search
        navigationItem.hidesSearchBarWhenScrolling = false
        navigationItem.preferredSearchBarPlacement = .stacked
    }

    override var keyCommands: [UIKeyCommand]? {
        var commands: [UIKeyCommand] = []
        if chooser.showsMachines {
            commands += (1...min(9, chooser.machines.count)).map { digit in
                let command = UIKeyCommand(
                    title: chooser.machines[digit - 1].title, action: #selector(machineKey(_:)),
                    input: "\(digit)", modifierFlags: .control)
                command.wantsPriorityOverSystemBehavior = true
                return command
            }
        }
        if chooser.showsDoors {
            commands += (0...min(9, chooser.doors.count)).map { digit in
                let title = digit == 0 ? String(localized: "All providers") : chooser.doors[digit - 1].title
                let command = UIKeyCommand(
                    title: title, action: #selector(doorKey(_:)),
                    input: "\(digit)", modifierFlags: .alternate)
                command.wantsPriorityOverSystemBehavior = true
                return command
            }
        }
        return commands.isEmpty ? nil : commands
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        fitBand()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        onClose?()
    }
}
