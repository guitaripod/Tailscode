import TailscodeCore
import UIKit

/// Every conversation across every server in one list, grouped into the shared sections —
/// NEEDS YOU, WORKING, PINNED, SAVED, RECENT — with filter chips narrowing what is grouped, so finding a
/// chat is scroll-or-search instead of expand-and-hunt.
@MainActor
final class SessionListViewController: UIViewController {
    enum ChatFilter: Equatable {
        case all, live, profile(String)
    }

    let viewModel: SessionListViewModel
    var collectionView: UICollectionView!
    var dataSource: UICollectionViewDiffableDataSource<SessionSection, SessionEntry>!
    let refreshControl = UIRefreshControl()
    let searchController = UISearchController(searchResultsController: nil)
    let chipBar = UIScrollView()
    let chipStack = UIStackView()
    let unreachableLabel = UILabel()
    let selectionBar = Theme.Glass.view()
    let selectionStack = UIStackView()
    var bulkButtons: [BulkChatAction: UIButton] = [:]
    var filter: ChatFilter
    let scope: ProjectScope?
    var chipBarHeight: NSLayoutConstraint!
    var chipBarTop: NSLayoutConstraint!
    var listEdges: [NSLayoutConstraint] = []
    var columnEdges: [NSLayoutConstraint] = []
    var openKey: String?

    /// Told whenever the listing this screen draws moves, so the side of an iPad's window can say
    /// what the list knows without asking any server itself.
    var onListingChange: (() -> Void)?

    /// Whether this list is the column beside an open conversation rather than a screen of its
    /// own. A column's rows open beside it, so they drop the push chevron and keep the open chat
    /// marked; its scope is chosen by the sidebar, so the chips that would repeat it step aside.
    var showsAsColumn = false {
        didSet {
            guard showsAsColumn != oldValue, isViewLoaded else { return }
            applyColumnMode()
        }
    }

    var isUnscopedList: Bool { scope == nil }

    /// The list every stack already reaches from Home: no project, no filter.
    var isPlainListing: Bool { scope == nil && filter == .all }
    var hasAppeared = false
    var hasLoadedOnce = false
    var searchQuery = ""
    var keyCursor: Int?

    /// The rows the list is drawing, flattened across every section in the order the eye reads
    /// them. The keyboard cursor, select-all and the pruning of a held selection all address this
    /// one list, because an `IndexPath` into a sectioned snapshot is not a position a person has.
    var visibleEntries: [SessionEntry] = []

    /// Each visible row's derived state, keyed the way every store here is keyed, so a cell reads
    /// what `SessionRowModel` already decided instead of re-deciding it per configure.
    var rowModels: [String: SessionRowModel] = [:]
    /// What the whole listing already says, so no row repeats it: one server's name written on
    /// every row of a one-server fleet is the word a reader's eye lands on and learns nothing from.
    var vocabulary: ChatListVocabulary = .full

    var selection = ChatSelection()
    var isSelecting = false

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
        navigationItem.largeTitleDisplayMode = .never
        updateTitle()
        view.backgroundColor = Theme.Color.groupedBackground
        configureSearch()
        configureChipBar()
        configureCollectionView()
        configureSelectionBar()
        configureEdges()
        configureDataSource()
        bind()
        applyColumnMode()
        collectionView.showsWork(true)
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
        takeDeferredRender()
        hasAppeared = true
        startClockRefresh()
    }

    /// A list nobody can see is not drawn. On a phone this controller outlives its visit — Home
    /// sits in front of it, or a conversation does — and every listing, activity tick and read mark
    /// that arrived meanwhile used to rebuild a row model and a snapshot for each chat the servers
    /// hold, for a screen no one was looking at. The reading is kept as a debt and paid when the
    /// list is about to appear, from the state it holds by then rather than from each step on the
    /// way.
    private var owesRender = false

    /// Whether this list may draw itself now; when it may not, the draw is remembered.
    func mayRender() -> Bool {
        guard viewIfLoaded?.window != nil || isAppearing else {
            owesRender = true
            return false
        }
        return true
    }

    private var isAppearing = false

    private func takeDeferredRender() {
        guard owesRender else { return }
        owesRender = false
        isAppearing = true
        defer { isAppearing = false }
        rebuildChips()
        applySnapshot()
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

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if keyContext == .normal, handleKeyPresses(presses) { return }
        super.pressesBegan(presses, with: event)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        clockRefreshTask?.cancel()
        clockRefreshTask = nil
    }

    var clockRefreshTask: Task<Void, Never>?
}
