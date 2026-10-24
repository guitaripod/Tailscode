import AppKit
import CodingAgentKit
import MidgarCore
import TailscodeCore

/// The Agents window: the board of what every agent is doing, in Now or Hour, with the peek of the
/// one selected in an inspector beside it. It watches only while somebody can see it: the tower is
/// opened when the window is on screen and the app in front, and closed when it closes, hides,
/// miniaturizes or the app steps back.
@MainActor
final class AgentsWindowController: NSWindowController {
    enum Mode: Int {
        case now
        case hour
    }

    static let toolbarID = NSToolbar.Identifier("tailscode.agents.toolbar")
    static let modeItem = NSToolbarItem.Identifier("tailscode.agents.mode")
    static let inspectorItem = NSToolbarItem.Identifier("tailscode.agents.inspector")

    let feed: any AgentsFeed
    let actions: AgentsActions
    let context: AgentsContext
    let board: AgentsBoardViewController
    let hour: AgentsHourViewController
    let peek: AgentPeekViewController
    let content: AgentsContentViewController
    let split: NSSplitViewController
    private(set) var inspector: NSSplitViewItem
    private(set) var mode: Mode = .now
    private(set) var selectedKey: String?
    private(set) var isWatching = false
    var visibilityOverride: Bool?
    var onOpenChat: ((String) -> Void)?
    private var ticker: Timer?
    private var following: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    weak var modeGroup: NSToolbarItemGroup?

    init(feed: any AgentsFeed) {
        self.feed = feed
        let actions = AgentsActions(feed: feed)
        self.actions = actions
        let context = AgentsContext(actions: actions)
        self.context = context
        board = AgentsBoardViewController(context: context)
        hour = AgentsHourViewController(context: context)
        peek = AgentPeekViewController(context: context)
        content = AgentsContentViewController(board: board, hour: hour)
        let splitController = NSSplitViewController()
        let main = NSSplitViewItem(viewController: content)
        main.minimumThickness = 440
        let side = NSSplitViewItem(inspectorWithViewController: peek)
        side.minimumThickness = 300
        side.maximumThickness = 460
        side.canCollapse = true
        side.isCollapsed = true
        splitController.addSplitViewItem(main)
        splitController.addSplitViewItem(side)
        split = splitController
        inspector = side
        let window = AgentsWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = Localized.text("Agents")
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 760, height: 480)
        MacTheme.Chrome.adopt(window)
        super.init(window: window)
        window.contentViewController = split
        window.setContentSize(NSSize(width: 1180, height: 760))
        window.center()
        window.rememberFrame(as: "TailscodeAgents")
        window.onStop = { [weak self] in self?.stopSelected() }
        configureToolbar(for: window)
        wire()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    isolated deinit {
        for token in observers { NotificationCenter.default.removeObserver(token) }
        ticker?.invalidate()
    }

    private func wire() {
        actions.openChat = { [weak self] key in self?.openChat(key) }
        actions.confirmStop = { [weak self] title, proceed in self?.confirmStop(title, proceed: proceed) }
        actions.observe { [weak self] _ in
            self?.board.refresh()
            self?.peek.refreshActions()
        }
        board.onSelect = { [weak self] key in self?.select(key: key, from: .board) }
        board.onOpenChat = { [weak self] key in self?.openChat(key) }
        board.onPeek = { [weak self] key in self?.select(key: key, from: .menu) }
        board.onStop = { [weak self] key in self?.requestStop(key) }
        board.onToggleInspector = { [weak self] in self?.toggleInspector() }
        hour.lanes.onSelect = { [weak self] key in self?.select(key: key, from: .hour) }
        hour.lanes.onOpenChat = { [weak self] key in self?.openChat(key) }
        hour.lanes.onToggleInspector = { [weak self] in self?.toggleInspector() }
        hour.fetch = { [feed] in await feed.hour() }
        peek.onOpenChat = { [weak self] key in self?.openChat(key) }
        peek.onWatch = { [weak self] key in self?.feed.watch(key) }
        content.onGate = { [weak self] in self?.reconcile() }
        let center = NotificationCenter.default
        guard let window else { return }
        for name in [
            NSWindow.willCloseNotification, NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification, NSWindow.didBecomeKeyNotification,
            NSWindow.didChangeOcclusionStateNotification,
        ] {
            observers.append(
                center.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                    let closing = note.name == NSWindow.willCloseNotification
                    MainThread.call {
                        if closing {
                            self?.stopWatching()
                        } else {
                            self?.reconcile()
                        }
                    }
                })
        }
        observers.append(
            center.addObserver(forName: MacTheme.Chrome.didRepaint, object: nil, queue: .main) {
                [weak self] _ in
                MainThread.call { self?.board.refresh() }
            })
    }

    func present() {
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        reconcile()
    }

    func toggle() {
        if window?.isVisible == true, window?.isKeyWindow == true {
            window?.performClose(nil)
        } else {
            present()
        }
    }

    func setMode(_ next: Mode) {
        mode = next
        content.show(next)
        modeGroup?.selectedIndex = next.rawValue
        if next == .hour, isWatching {
            hour.reload()
            window?.makeFirstResponder(hour.lanes)
        } else if next == .now {
            window?.makeFirstResponder(board.table)
        }
        hour.lanes.select(key: selectedKey)
    }

    func reconcile() {
        let wanted = visibilityOverride ?? (window?.isVisible == true && content.isVisibleToEyes)
        if wanted, !isWatching {
            startWatching()
        } else if !wanted, isWatching {
            stopWatching()
        }
    }

    func startWatching() {
        guard !isWatching else { return }
        isWatching = true
        MidgarLog.info("agents: board open", category: .lifecycle)
        feed.open { [weak self] board in self?.received(board) }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
            MainThread.call { self?.tick() }
        }
        timer.tolerance = 0.2
        RunLoop.main.add(timer, forMode: .common)
        ticker = timer
        if let selectedKey { follow(selectedKey) }
        if mode == .hour { hour.reload() }
    }

    func stopWatching() {
        guard isWatching else { return }
        isWatching = false
        MidgarLog.info("agents: board closed", category: .lifecycle)
        ticker?.invalidate()
        ticker = nil
        following?.cancel()
        following = nil
        feed.close()
        AgentsCenter.shared.note(board: nil)
    }

    private func received(_ next: AgentBoard) {
        board.apply(next)
        window?.subtitle = next.sentence
        AgentsCenter.shared.note(board: next)
        if let key = selectedKey {
            if let subject = AgentsSubject.resolve(key: key, in: next, lane: lane(forBoard: key)) {
                peek.show(subject)
            } else {
                select(key: nil, from: .board)
            }
        }
        if mode == .hour { hour.reload() }
    }

    private func tick() {
        let now = context.now()
        board.tick()
        peek.tick(now: now)
        if mode == .hour { hour.tick(now: now) }
    }

    enum Source {
        case board
        case hour
        case menu
        case code
    }

    func select(key: String?, from source: Source) {
        selectedKey = key
        if source != .board { board.select(key: key) }
        if source != .hour { hour.lanes.select(key: key) }
        following?.cancel()
        following = nil
        guard let key else {
            peek.show(nil)
            setInspector(collapsed: true)
            return
        }
        let subject = AgentsSubject.resolve(key: key, in: feed.board, lane: lane(forBoard: key))
        peek.show(subject)
        setInspector(collapsed: subject == nil)
        if isWatching { follow(key) }
    }

    private func follow(_ key: String) {
        following?.cancel()
        following = feed.follow(key) { [weak self] facts in self?.peek.apply(facts: facts) }
    }

    func toggleInspector() {
        setInspector(collapsed: !inspector.isCollapsed)
    }

    private func setInspector(collapsed: Bool) {
        guard inspector.isCollapsed != collapsed else { return }
        if window?.isVisible == true {
            inspector.animator().isCollapsed = collapsed
        } else {
            inspector.isCollapsed = collapsed
        }
    }

    func openChat(_ key: String) {
        onOpenChat?(key)
    }

    private func requestStop(_ key: String) {
        guard let subject = AgentsSubject.resolve(key: key, in: feed.board, lane: lane(forBoard: key)),
            subject.isRunning
        else {
            NSSound.beep()
            return
        }
        actions.requestStop(key, title: subject.title)
    }

    private func stopSelected() {
        guard let selectedKey else {
            NSSound.beep()
            return
        }
        requestStop(selectedKey)
    }

    var confirmStopOverride: ((String, @escaping () -> Void) -> Void)?

    private func confirmStop(_ title: String, proceed: @escaping () -> Void) {
        if let confirmStopOverride {
            confirmStopOverride(title, proceed)
            return
        }
        let alert = NSAlert()
        alert.messageText = AgentsWords.stopQuestion(title)
        alert.informativeText = Localized.text("The turn it is on ends where it stands.")
        alert.alertStyle = .warning
        let stop = alert.addButton(withTitle: Localized.text("Stop"))
        stop.hasDestructiveAction = true
        alert.addButton(withTitle: Localized.text("Cancel"))
        guard let window else { return }
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { proceed() }
        }
    }

    private func lane(forBoard key: String) -> AgentHourLane? {
        hour.lanes.lanes.first { AgentHourView.key(of: $0) == key }
    }
}
