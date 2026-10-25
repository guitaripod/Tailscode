import MidgarCore
import TailscodeCore
import UIKit

/// Every agent this device knows of, across every machine, in the order a person has to deal with
/// them: what waits on them, what is working, what the machines carry on in the background, what
/// just ended. It is live while it is on screen and holds nothing otherwise: the tower opens when
/// it appears and lets go when it is dismissed or the app stops being active.
@MainActor
final class AgentsBoardViewController: UIViewController {
    let hub = AgentsHub.shared
    var collectionView: UICollectionView!
    var dataSource: UICollectionViewDiffableDataSource<AgentsSection, AgentsItem>!
    var board = AgentBoard.empty
    var actionStates: [String: AgentsActionState] = [:]
    var expanded: Set<String> = []
    var gateInFlight = false
    weak var peek: AgentPeekViewController?

    let modeControl = UISegmentedControl(items: [String(localized: "Now"), String(localized: "Hour")])
    let hourPane = AgentsHourPane()
    var showsHour = false
    var hourRefresh: Task<Void, Never>?

    private var consumer: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var isAcquired = false
    private var hasSeenBoard = false

    #if DEBUG
        override var prefersStatusBarHidden: Bool {
            ProcessInfo.processInfo.environment["TAILSCODE_WINDOW"] != nil
        }
    #endif

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.groupedBackground
        title = String(localized: "Agents")
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            systemItem: .done,
            primaryAction: UIAction { [weak self] _ in self?.dismiss(animated: true) })
        configureCollectionView()
        configureDataSource()
        configureHour()
        observeScene()
        apply(.empty)
    }

    deinit {
        consumer?.cancel()
        ticker?.cancel()
        hourRefresh?.cancel()
        if isAcquired { Task { @MainActor in AgentsHub.shared.release() } }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        resume()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateModeControl()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard isBeingDismissed || navigationController?.isBeingDismissed == true else { return }
        suspend()
    }

    override var canBecomeFirstResponder: Bool { true }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        if handleKeyPresses(presses) { return }
        super.pressesBegan(presses, with: event)
    }

    func resume() {
        guard !isAcquired else { return }
        isAcquired = true
        hub.acquire()
        MidgarLog.info("agents board shown", category: .ui)
        consumer = Task { [weak self] in
            guard let stream = await self?.hub.boards() else { return }
            for await board in stream {
                guard !Task.isCancelled, let self else { return }
                self.apply(board)
            }
        }
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled, let self else { return }
                self.tick()
            }
        }
        refreshHour()
    }

    func suspend() {
        consumer?.cancel()
        consumer = nil
        ticker?.cancel()
        ticker = nil
        hourRefresh?.cancel()
        hourRefresh = nil
        guard isAcquired else { return }
        isAcquired = false
        hub.release()
        MidgarLog.info("agents board hidden", category: .ui)
    }

    private func observeScene() {
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(sceneWillDeactivate(_:)),
            name: UIScene.willDeactivateNotification, object: nil)
        center.addObserver(
            self, selector: #selector(sceneDidEnterBackground(_:)),
            name: UIScene.didEnterBackgroundNotification, object: nil)
        center.addObserver(
            self, selector: #selector(sceneDidActivate(_:)),
            name: UIScene.didActivateNotification, object: nil)
    }

    private func ownsScene(_ note: Notification) -> Bool {
        guard let scene = note.object as? UIScene else { return true }
        return scene === viewIfLoaded?.window?.windowScene
    }

    @objc private func sceneWillDeactivate(_ note: Notification) {
        guard ownsScene(note), !gateInFlight else { return }
        suspend()
    }

    @objc private func sceneDidEnterBackground(_ note: Notification) {
        guard ownsScene(note) else { return }
        suspend()
    }

    @objc private func sceneDidActivate(_ note: Notification) {
        guard ownsScene(note), viewIfLoaded?.window != nil else { return }
        resume()
    }

    func apply(_ next: AgentBoard) {
        let previous = board
        board = next
        let live = Set(next.needsYou.map(\.ask.id))
        actionStates = actionStates.filter { live.contains($0.key) }

        var snapshot = NSDiffableDataSourceSnapshot<AgentsSection, AgentsItem>()
        snapshot.appendSections([.header])
        snapshot.appendItems(next.isEmpty ? [.header, .empty] : [.header], toSection: .header)
        var seen = Set<AgentsItem>()
        append(.needsYou, next.needsYou.map { .ask($0.id) }, seen: &seen, to: &snapshot)
        append(.working, next.working.map { .row($0.id) }, seen: &seen, to: &snapshot)
        append(.background, next.background.map { .row($0.id) }, seen: &seen, to: &snapshot)
        append(.finished, next.finished.map { .finish($0.id) }, seen: &seen, to: &snapshot)
        snapshot.reconfigureItems(changedItems(from: previous, to: next, in: snapshot))
        let animate = view.window != nil && !UIAccessibility.isReduceMotionEnabled
        dataSource.apply(snapshot, animatingDifferences: animate)
        refreshSectionHeaders()
        peek?.update(board: next)
        announceNewAsks(previous: previous, next: next)
    }

    private func append(
        _ section: AgentsSection, _ items: [AgentsItem], seen: inout Set<AgentsItem>,
        to snapshot: inout NSDiffableDataSourceSnapshot<AgentsSection, AgentsItem>
    ) {
        let fresh = items.filter { seen.insert($0).inserted }
        guard !fresh.isEmpty else { return }
        snapshot.appendSections([section])
        snapshot.appendItems(fresh, toSection: section)
    }

    private func changedItems(
        from old: AgentBoard, to new: AgentBoard,
        in snapshot: NSDiffableDataSourceSnapshot<AgentsSection, AgentsItem>
    ) -> [AgentsItem] {
        snapshot.itemIdentifiers.filter { item in
            switch item {
            case .header: return old != new
            case .empty: return false
            case .ask(let id): return old.ask(id) != new.ask(id)
            case .row(let id): return old.row(id) != new.row(id)
            case .finish(let id): return old.finish(id) != new.finish(id)
            }
        }
    }

    private func announceNewAsks(previous: AgentBoard, next: AgentBoard) {
        defer { hasSeenBoard = true }
        guard hasSeenBoard, next.needsYou.count > previous.needsYou.count,
            let card = next.needsYou.last(where: { ask in !previous.needsYou.contains { $0.id == ask.id } })
        else { return }
        Theme.Haptics.needsYou()
        UIAccessibility.post(
            notification: .announcement, argument: String(localized: "\(card.title) needs you"))
    }

    func reconfigure(_ items: [AgentsItem]) {
        var snapshot = dataSource.snapshot()
        let present = items.filter { snapshot.indexOfItem($0) != nil }
        guard !present.isEmpty else { return }
        snapshot.reconfigureItems(present)
        dataSource.apply(snapshot, animatingDifferences: false)
        collectionView.collectionViewLayout.invalidateLayout()
    }

    func tick() {
        let now = Date()
        for cell in collectionView.visibleCells {
            switch cell {
            case let cell as AgentsRowCell: cell.tick(now: now)
            case let cell as AgentsAskCell: cell.tick(now: now)
            case let cell as AgentsFinishCell: cell.tick(now: now)
            default: break
            }
        }
        if showsHour {
            hourPane.redraw()
            refreshHour()
        }
    }
}

extension AgentsBoardViewController: KeyActionHost {
    var keyContext: KeyContext { .normal }

    func performKeyAction(_ action: KeyAction) -> Bool {
        switch action {
        case .toggleAgents, .leaveInsert:
            dismiss(animated: true)
            return true
        default:
            return false
        }
    }
}
