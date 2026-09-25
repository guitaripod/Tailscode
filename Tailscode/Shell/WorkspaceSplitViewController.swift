import CodingAgentKit
import TailscodeCore
import UIKit
import UIKit.UIGestureRecognizerSubclass

/// The iPad's window: places, chat lists and servers down the side, the conversations that were
/// chosen there beside them, and the open conversation — or Home — filling the rest.
///
/// A window too narrow for columns is the phone's app exactly: one stack with Home at its root.
/// The same view controllers serve both arrangements, carried from one to the other whenever the
/// window changes width, so nothing that was open is closed by a resize — a conversation keeps
/// its stream, its scroll position and its half-written message through Stage Manager, Split View
/// and Slide Over alike.
@MainActor
final class WorkspaceSplitViewController: UISplitViewController {
    let home: HomeViewController
    private(set) var chatList: SessionListViewController
    private let sidebar = SidebarViewController()
    private let sidebarNav: UINavigationController
    private let listNav: UINavigationController
    private let detailNav: UINavigationController
    private let compactNav: UINavigationController
    private var arrangedCollapsed: Bool?

    init(home: HomeViewController, startsCollapsed: Bool) {
        self.home = home
        self.chatList = SessionListViewController()
        sidebarNav = UINavigationController(rootViewController: sidebar)
        listNav = UINavigationController()
        detailNav = UINavigationController()
        compactNav = UINavigationController()
        super.init(style: .tripleColumn)
        sidebarNav.navigationBar.prefersLargeTitles = true
        detailNav.navigationBar.prefersLargeTitles = true
        compactNav.navigationBar.prefersLargeTitles = true
        listNav.delegate = self
        detailNav.delegate = self
        delegate = self
        preferredDisplayMode = .automatic
        preferredSplitBehavior = .automatic
        preferredPrimaryColumnWidth = 268
        minimumPrimaryColumnWidth = 232
        maximumPrimaryColumnWidth = 320
        preferredSupplementaryColumnWidth = 340
        minimumSupplementaryColumnWidth = 300
        maximumSupplementaryColumnWidth = 420
        showsSecondaryOnlyButton = true
        sidebar.owner = self
        adopt(chatList)
        arrange(collapsed: startsCollapsed)
        setViewController(sidebarNav, for: .primary)
        setViewController(listNav, for: .supplementary)
        setViewController(detailNav, for: .secondary)
        setViewController(compactNav, for: .compact)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.background
        installPressRouting()
        #if DEBUG
            flipWidthForVerification()
            walkForVerification()
        #endif
    }

    #if DEBUG
        /// A window turned a quarter by `TAILSCODE_WINDOW` would wear the portrait status bar
        /// down its side, so a photographed landscape workspace goes without one.
        override var prefersStatusBarHidden: Bool { isTurnedForVerification }

        override var childForStatusBarHidden: UIViewController? {
            isTurnedForVerification ? nil : super.childForStatusBarHidden
        }

        private var isTurnedForVerification: Bool {
            view.window.map { !$0.transform.isIdentity } ?? false
        }
    #endif

    override func viewIsAppearing(_ animated: Bool) {
        super.viewIsAppearing(animated)
        arrange(collapsed: isCollapsed)
        refreshMarks()
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        fitColumns(to: view.bounds.width)
    }

    override func viewWillTransition(
        to size: CGSize, with coordinator: any UIViewControllerTransitionCoordinator
    ) {
        super.viewWillTransition(to: size, with: coordinator)
        fitColumns(to: size.width)
    }

    private enum WidthBand { case narrow, medium, wide }
    private var widthBand: WidthBand?

    /// How many columns a window's width can hold without starving the conversation. A wide window
    /// tiles all three; a middling one keeps the list beside the conversation and slides the
    /// sidebar in over them when asked; a narrow one gives the conversation the width and lays
    /// the list over it on demand. Decided only when the width crosses a band, so a column a
    /// person put away stays put until the window itself changes.
    private func fitColumns(to width: CGFloat) {
        guard width > 0 else { return }
        let band: WidthBand = width >= 1180 ? .wide : width >= 820 ? .medium : .narrow
        guard band != widthBand else { return }
        widthBand = band
        switch band {
        case .wide:
            preferredSplitBehavior = .tile
            preferredSupplementaryColumnWidth = 360
            preferredDisplayMode = .twoBesideSecondary
        case .medium:
            preferredSplitBehavior = .displace
            preferredSupplementaryColumnWidth = 320
            preferredDisplayMode = .oneBesideSecondary
        case .narrow:
            preferredSplitBehavior = .overlay
            preferredSupplementaryColumnWidth = 320
            preferredDisplayMode = .secondaryOnly
        }
        AppLogger.ui.info("workspace width \(Int(width)) band=\(String(describing: band))")
    }

    /// Whether the window is showing columns right now rather than the phone's single stack.
    var isShowingColumns: Bool { !isCollapsed && arrangedCollapsed == false }

    private func arrange(collapsed: Bool) {
        guard arrangedCollapsed != collapsed else { return }
        let first = arrangedCollapsed == nil
        arrangedCollapsed = collapsed
        if first {
            listNav.setViewControllers([chatList], animated: false)
            if collapsed {
                compactNav.setViewControllers([home], animated: false)
                detailNav.setViewControllers([ColumnPlaceholderViewController()], animated: false)
            } else {
                detailNav.setViewControllers([home], animated: false)
                compactNav.setViewControllers([ColumnPlaceholderViewController()], animated: false)
            }
        } else if collapsed {
            gatherIntoOneStack()
        } else {
            spreadIntoColumns()
        }
        AppLogger.ui.info("workspace arranged \(collapsed ? "one stack" : "columns")")
        for case let list as SessionListViewController in listNav.viewControllers {
            list.showsAsColumn = !collapsed
        }
        for case let list as SessionListViewController in compactNav.viewControllers {
            list.showsAsColumn = false
        }
        home.workspaceDidRearrange()
        refreshMarks()
    }

    /// Columns fold into the phone's stack in the order a person would have walked them: Home,
    /// then the list they chose — when it is anything but the plain list every stack already
    /// reaches from Home — then whatever the conversation column held.
    private func gatherIntoOneStack() {
        let listStack = listNav.viewControllers.filter { !($0 is ColumnPlaceholderViewController) }
        let detailStack = detailNav.viewControllers.filter {
            $0 !== home && !($0 is ColumnPlaceholderViewController)
        }
        let plainList = listStack.count == 1 && listStack.first === chatList && chatList.isPlainListing
        let carried = plainList ? [] : listStack
        announceMove(from: detailNav)
        if !carried.isEmpty {
            listNav.setViewControllers([ColumnPlaceholderViewController()], animated: false)
        }
        detailNav.setViewControllers([ColumnPlaceholderViewController()], animated: false)
        compactNav.setViewControllers([home] + carried + detailStack, animated: false)
    }

    /// The stack spreads back out by what each screen is: lists go beside the conversation, and
    /// everything else — the conversation, usage, a delegate board — goes where the conversation
    /// is shown. A plain chat list pushed on the phone's stack becomes the column's list, so the
    /// one that was on screen is the one that stays.
    private func spreadIntoColumns() {
        let stack = compactNav.viewControllers.filter {
            $0 !== home && !($0 is ColumnPlaceholderViewController)
        }
        let lists = stack.filter(Self.belongsBesideConversation)
        let rest = Self.oneConversation(in: stack.filter { !Self.belongsBesideConversation($0) })
        announceMove(from: compactNav)
        retire(stack.filter { item in !lists.contains(item) && !rest.contains(item) })
        compactNav.setViewControllers([ColumnPlaceholderViewController()], animated: false)
        if let adopted = lists.first as? SessionListViewController, adopted.isUnscopedList {
            if adopted !== chatList { adopt(adopted) }
            listNav.setViewControllers(lists, animated: false)
        } else if lists.first is SavedChatsViewController || lists.first is ArchivedChatsViewController {
            listNav.setViewControllers(lists, animated: false)
        } else {
            listNav.setViewControllers([chatList] + lists, animated: false)
        }
        detailNav.setViewControllers([home] + rest, animated: false)
    }

    /// The conversation column holds one conversation. A phone stack can hold two — a fork pushed
    /// over the chat it came from — and spreading it keeps the one on top, so the back button
    /// beside the list leads Home rather than into another live chat.
    private static func oneConversation(in stack: [UIViewController]) -> [UIViewController] {
        guard let last = stack.last(where: { $0 is ChatViewController }) else { return stack }
        return stack.filter { !($0 is ChatViewController) || $0 === last }
    }

    /// Chats a stack lets go of while they are buried get no disappearance to end them, so they
    /// are ended here; the one on top is ended by its own, and ending it twice changes nothing.
    private func retire(_ dropped: [UIViewController]) {
        for case let chat as ChatViewController in dropped { chat.releaseConversation() }
    }

    private static func belongsBesideConversation(_ controller: UIViewController) -> Bool {
        controller is SessionListViewController || controller is SavedChatsViewController
            || controller is ArchivedChatsViewController
            || controller is TranscriptSearchViewController
    }

    /// Only the screen on top of a stack sees the move as a disappearance, so it is the one told
    /// that leaving this stack is not the reader leaving the conversation.
    private func announceMove(from stack: UINavigationController) {
        (stack.topViewController as? ChatViewController)?.isChangingColumns = true
    }

    private func adopt(_ list: SessionListViewController) {
        chatList = list
        list.onListingChange = { [weak self] in self?.refreshSidebar() }
    }

    /// Shows a conversation beside the list. A second chat replaces the first rather than stacking
    /// on it — the list is the way between conversations here, not a back button — and the chat
    /// already on screen is told it was asked for again rather than being rebuilt.
    func show(conversation chat: ChatViewController, animated: Bool) {
        if detailNav.transitionCoordinator != nil {
            DispatchQueue.main.async { [weak self] in
                self?.show(conversation: chat, animated: animated)
            }
            return
        }
        if let open = detailNav.topViewController as? ChatViewController,
            open.sessionID == chat.sessionID
        {
            Theme.Haptics.tap()
            open.announceIdentity()
            return
        }
        let fromHome = detailNav.topViewController === home
        if fromHome {
            detailNav.pushViewController(chat, animated: animated)
        } else {
            replaceDetail(with: [home, chat], animated: animated)
        }
        AppLogger.session.info("workspace opened session=\(chat.sessionID)")
    }

    /// A place that fills the conversation column — usage, a delegate board — replaces what is
    /// there, on top of Home so the back button always leads home.
    func show(place controller: UIViewController, animated: Bool = true) {
        if let top = detailNav.topViewController, type(of: top) == type(of: controller) { return }
        replaceDetail(with: [home, controller], animated: animated)
    }

    func showHome(animated: Bool = true) {
        guard detailNav.topViewController !== home else { return }
        replaceDetail(with: [home], animated: animated)
    }

    private func replaceDetail(with stack: [UIViewController], animated: Bool) {
        if animated, !UIAccessibility.isReduceMotionEnabled, detailNav.viewIfLoaded?.window != nil {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.18
            fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
            detailNav.view.layer.add(fade, forKey: "workspace.replace")
        }
        let kept = Set(stack.map(ObjectIdentifier.init))
        retire(detailNav.viewControllers.filter { !kept.contains(ObjectIdentifier($0)) })
        detailNav.setViewControllers(stack, animated: false)
    }

    /// Puts a chat list in the column beside the conversation and makes sure the column is out.
    func showChats(_ filter: SessionListViewController.ChatFilter) {
        if listNav.topViewController !== chatList || listNav.viewControllers.count > 1 {
            listNav.setViewControllers([chatList], animated: false)
        }
        chatList.show(filter: filter)
        revealList()
    }

    func showSaved() {
        guard !(listNav.topViewController is SavedChatsViewController) else { return revealList() }
        listNav.setViewControllers([SavedChatsViewController()], animated: false)
        revealList()
    }

    func showArchived() {
        guard !(listNav.topViewController is ArchivedChatsViewController) else { return revealList() }
        listNav.setViewControllers([ArchivedChatsViewController()], animated: false)
        revealList()
    }

    /// A list opened from somewhere else — a project's board, a search's results — is pushed in
    /// the list column, so leaving it is a back button to the list it was reached from.
    func push(list controller: UIViewController) {
        listNav.pushViewController(controller, animated: true)
        revealList()
    }

    func beginSearch() {
        showChats(chatList.filter)
        chatList.beginSearch()
    }

    /// Hands the keyboard to the chat list and lets it take the verb that asked for it, so the
    /// cursor keys pressed on Home walk the list beside it instead of pushing another one.
    func focusList(then action: KeyAction) {
        if listNav.topViewController !== chatList { showChats(chatList.filter) }
        revealList()
        chatList.becomeFirstResponder()
        _ = chatList.performKeyAction(action)
    }

    private func revealList() {
        guard !isCollapsed, displayMode == .secondaryOnly else { return }
        show(.supplementary)
    }

    /// The chord that shows and hides the chat list on the desktops shows and hides the columns
    /// here, giving the conversation the whole window and handing it back.
    func toggleColumns() {
        guard !isCollapsed else { return }
        Theme.Haptics.tap()
        let putAway = displayMode != .secondaryOnly
        UIView.animate(withDuration: UIAccessibility.isReduceMotionEnabled ? 0 : 0.3) {
            self.preferredDisplayMode = putAway ? .secondaryOnly : self.bandDisplayMode
        }
    }

    private var bandDisplayMode: UISplitViewController.DisplayMode {
        switch widthBand {
        case .wide: return .twoBesideSecondary
        case .medium, nil: return .oneBesideSecondary
        case .narrow: return .oneOverSecondary
        }
    }

    /// The conversation this window is showing, in whichever arrangement it is showing it.
    var openConversationID: String? {
        let stack = isShowingColumns ? detailNav.viewControllers : compactNav.viewControllers
        return stack.compactMap { $0 as? ChatViewController }.last?.sessionID
    }

    func startNewChat() {
        showHome(animated: true)
        home.beginNewChat()
    }

    func openSettings() {
        home.onOpenSettings?()
    }

    /// What the side of the window says is open, derived from what the columns actually hold
    /// every time either of them moves — never remembered alongside them, so it cannot drift.
    private func refreshMarks() {
        guard arrangedCollapsed == false else { return }
        let open = detailNav.topViewController as? ChatViewController
        chatList.markOpen(open.map { SessionPinStore.key($0.contextID, $0.sessionID) })
        refreshSidebar()
    }

    private func refreshSidebar() {
        guard arrangedCollapsed == false else { return }
        sidebar.render(
            SidebarReading(
                digest: chatList.digest(),
                scope: listScope(),
                place: detailPlace(),
                openChat: (detailNav.topViewController as? ChatViewController).map {
                    SessionPinStore.key($0.contextID, $0.sessionID)
                }))
    }

    private func listScope() -> SidebarScope? {
        switch listNav.topViewController {
        case let list as SessionListViewController:
            guard list.isUnscopedList else { return nil }
            switch list.filter {
            case .all: return .all
            case .live: return .live
            case .profile(let id): return .server(id)
            }
        case is SavedChatsViewController: return .saved
        case is ArchivedChatsViewController: return .archived
        default: return nil
        }
    }

    private func detailPlace() -> SidebarPlace? {
        switch detailNav.topViewController {
        case is HomeViewController: return .home
        case is UsageViewController, is AnalyticsViewController: return .usage
        case is DelegateBoardViewController, is DelegateRunViewController: return .delegate
        default: return nil
        }
    }

    #if DEBUG
        var tourStack: UINavigationController { isShowingColumns ? detailNav : compactNav }

        /// `TAILSCODE_WORKSPACE_WALK=6:server=studio,10:saved,14:usage,18:hide` presses the
        /// sidebar's rows on a clock, through the same calls a finger makes, so every arrangement
        /// the side of the window can ask for is photographed without a hand on the simulator.
        private func walkForVerification() {
            guard let walk = ProcessInfo.processInfo.environment["TAILSCODE_WORKSPACE_WALK"] else {
                return
            }
            for step in walk.split(separator: ",") {
                let parts = step.split(separator: ":", maxSplits: 1).map(String.init)
                guard parts.count == 2, let time = Double(parts[0]) else { continue }
                DispatchQueue.main.asyncAfter(deadline: .now() + time) { [weak self] in
                    self?.walkStep(parts[1])
                }
            }
        }

        private func walkStep(_ step: String) {
            AppLogger.ui.info("workspace walk \(step)")
            let pieces = step.split(separator: "=", maxSplits: 1).map(String.init)
            let argument = pieces.count > 1 ? pieces[1] : ""
            switch pieces[0] {
            case "all": showChats(.all)
            case "live": showChats(.live)
            case "server":
                let id = ConnectionController.shared.profiles.first { $0.name == argument }?.id
                if let id { showChats(.profile(id)) }
            case "saved": showSaved()
            case "archived": showArchived()
            case "usage": show(place: UsageViewController())
            case "analytics": show(place: AnalyticsViewController(analytics: nil))
            case "delegate":
                let profile = ConnectionController.shared.profiles.first { $0.name == argument }
                guard let profile else { return }
                showHome(animated: false)
                DelegateGate.open(from: home, profile: profile)
            case "home": showHome()
            case "search": beginSearch()
            case "hide", "show": toggleColumns()
            case "new": startNewChat()
            case "pin":
                let key = argument.split(separator: "/", maxSplits: 1).map(String.init)
                guard key.count == 2 else { return }
                _ = SessionPinStore.toggle(profileID: key[0], sessionID: key[1])
            case "open": chatList.open(key: argument)
            default: break
            }
        }

        /// `TAILSCODE_WIDTH_FLIPS=4,9` narrows the window to one column at the first mark and
        /// widens it back at the next, so a simulator — which cannot be resized from a script —
        /// walks every carry between the two arrangements with a conversation open.
        private func flipWidthForVerification() {
            guard let marks = ProcessInfo.processInfo.environment["TAILSCODE_WIDTH_FLIPS"] else {
                return
            }
            let times = marks.split(separator: ",").compactMap { Double($0) }
            for (index, time) in times.enumerated() {
                DispatchQueue.main.asyncAfter(deadline: .now() + time) { [weak self] in
                    guard let self else { return }
                    if index.isMultiple(of: 2) {
                        self.traitOverrides.horizontalSizeClass = .compact
                    } else {
                        self.traitOverrides.remove(UITraitHorizontalSizeClass.self)
                    }
                    AppLogger.ui.info("workspace width flip \(index) collapsed=\(self.isCollapsed)")
                }
            }
        }
    #endif
}

extension WorkspaceSplitViewController {
    /// Where a finger or the pointer goes down is the column the keyboard works in. The press is
    /// read from the window before the control under it acts and is never claimed, so it keeps its
    /// ordinary meaning; it only hands first responder to the screen on top of the column that was
    /// pressed, and only when the keyboard was working somewhere else — a tap in the transcript
    /// must not take the keyboard from the composer beside it.
    private func installPressRouting() {
        let press = ColumnPressRecognizer { [weak self] location in
            self?.columnPressed(at: location)
        }
        view.addGestureRecognizer(press)
    }

    private func columnPressed(at location: CGPoint) {
        guard isShowingColumns else { return }
        let columns = [sidebarNav, listNav, detailNav]
        guard
            let column = columns.first(where: { nav in
                guard let columnView = nav.viewIfLoaded, columnView.window != nil else { return false }
                return columnView.bounds.contains(view.convert(location, to: columnView))
            }),
            let target = column.topViewController, target.canBecomeFirstResponder
        else { return }
        if let focused = UIResponder.currentFirstResponder, Self.responder(focused, isInside: column) {
            return
        }
        target.becomeFirstResponder()
    }

    private static func responder(_ responder: UIResponder, isInside column: UIViewController) -> Bool {
        if let view = responder as? UIView { return view.isDescendant(of: column.view) }
        if let controller = responder as? UIViewController, let view = controller.viewIfLoaded {
            return view.isDescendant(of: column.view)
        }
        return false
    }
}

/// Reports where a touch begins and then steps aside: it never recognises, so every control,
/// scroll view and gesture under the press behaves exactly as if it were not there.
private final class ColumnPressRecognizer: UIGestureRecognizer, UIGestureRecognizerDelegate {
    private let onPress: (CGPoint) -> Void

    init(onPress: @escaping (CGPoint) -> Void) {
        self.onPress = onPress
        super.init(target: nil, action: nil)
        cancelsTouchesInView = false
        delaysTouchesBegan = false
        delaysTouchesEnded = false
        delegate = self
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if let touch = touches.first, let view { onPress(touch.location(in: view)) }
        state = .failed
    }

    func gestureRecognizer(
        _ gestureRecognizer: UIGestureRecognizer,
        shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool { true }
}

extension UIResponder {
    private static weak var captured: UIResponder?

    /// The responder the keyboard is talking to, found the only public way there is: an action
    /// sent to nobody lands on the first responder.
    static var currentFirstResponder: UIResponder? {
        captured = nil
        UIApplication.shared.sendAction(
            #selector(captureFirstResponder(_:)), to: nil, from: nil, for: nil)
        return captured
    }

    @objc private func captureFirstResponder(_ sender: Any?) {
        UIResponder.captured = self
    }
}

extension WorkspaceSplitViewController: UISplitViewControllerDelegate {
    func splitViewController(
        _ svc: UISplitViewController,
        topColumnForCollapsingToProposedTopColumn proposedTopColumn: UISplitViewController.Column
    ) -> UISplitViewController.Column {
        AppLogger.ui.info("workspace will collapse")
        arrange(collapsed: true)
        return .compact
    }

    func splitViewController(
        _ svc: UISplitViewController,
        displayModeForExpandingToProposedDisplayMode proposedDisplayMode: UISplitViewController
            .DisplayMode
    ) -> UISplitViewController.DisplayMode {
        AppLogger.ui.info("workspace will expand")
        arrange(collapsed: false)
        return proposedDisplayMode
    }

    func splitViewControllerDidCollapse(_ svc: UISplitViewController) {
        arrange(collapsed: true)
    }

    func splitViewControllerDidExpand(_ svc: UISplitViewController) {
        arrange(collapsed: false)
    }
}

extension WorkspaceSplitViewController: UINavigationControllerDelegate {
    func navigationController(
        _ navigationController: UINavigationController, didShow viewController: UIViewController,
        animated: Bool
    ) {
        refreshMarks()
    }
}

/// What fills a column whose screens have been carried to the other arrangement. Nothing ever
/// looks at it; it exists so every column always holds a controller of its own.
final class ColumnPlaceholderViewController: UIViewController {
    init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Theme.Color.background
    }
}

extension UIViewController {
    /// The workspace this screen lives in, when it lives in one that is showing columns.
    var workspace: WorkspaceSplitViewController? {
        guard let split = splitViewController as? WorkspaceSplitViewController,
            split.isShowingColumns
        else { return nil }
        return split
    }

    /// Opens a conversation wherever this window keeps conversations: in the column beside the
    /// list on a wide iPad, pushed onto this stack everywhere else.
    func showConversation(_ chat: ChatViewController, animated: Bool = true) {
        if let workspace {
            workspace.show(conversation: chat, animated: animated)
        } else {
            navigationController?.pushViewController(chat, animated: animated)
        }
    }
}
