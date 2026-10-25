import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// The agents as a window of its own, in three lenses: Watch, the wall left up on a monitor; Now,
/// the board with the peek of what is selected beside it; and Hour, the last hour as lanes.
///
/// One window for the process — raising it twice raises it, never builds a second — and it is the
/// only thing that keeps the tower open: it opens the source when it is shown, and closes it when
/// the window is closed or hidden by the compositor, so nothing is watched while nobody looks.
/// It is sized from the window it came from and the monitor, never from what is in it: every body
/// scrolls or draws to fit, so no board can make it taller than the screen.
final class AgentsWindow: @unchecked Sendable {
    enum Mode: Equatable {
        case watch
        case now
        case hour
    }

    nonisolated(unsafe) static var shared: AgentsWindow?
    nonisolated(unsafe) private(set) static var built = 0

    static var current: AgentsWindow? { shared }

    @discardableResult
    static func present(
        parent: UnsafeMutablePointer<GtkWidget>?, source: any AgentsSource, hooks: AgentsHooks,
        mode: Mode? = nil, onHeadline: @escaping @Sendable () -> Void = {}
    ) -> AgentsWindow {
        if let open = shared {
            gtk_window_present(ptr(open.window))
            if let mode { open.show(mode) }
            return open
        }
        let made = AgentsWindow(parent: parent, source: source, hooks: hooks, onHeadline: onHeadline)
        shared = made
        if let mode { made.show(mode) }
        return made
    }

    /// The shortcut's answer: a board that is the window being used closes, one behind another
    /// window comes forward, and none opens.
    static func toggle(
        parent: UnsafeMutablePointer<GtkWidget>?, source: any AgentsSource, hooks: AgentsHooks,
        onHeadline: @escaping @Sendable () -> Void = {}
    ) {
        guard let open = shared else {
            present(parent: parent, source: source, hooks: hooks, onHeadline: onHeadline)
            return
        }
        if gtk_window_is_active(ptr(open.window)) != 0 {
            open.close()
        } else {
            gtk_window_present(ptr(open.window))
        }
    }

    static func close() { shared?.close() }

    let window: UnsafeMutablePointer<GtkWidget>
    let source: any AgentsSource
    let actions: AgentsActions
    let boardView: AgentsBoardView
    let peek: AgentPeekView
    let overlayPeek: AgentPeekView
    let hourView = AgentHourView()
    let watchView: AgentsWatchView
    let hooks: AgentsHooks
    let onHeadline: @Sendable () -> Void
    let stack = gtk_stack_new()!
    let revealer = gtk_revealer_new()!
    let hourHeader = Gtk.label("", css: "agents-watch", wrap: true, selectable: false)
    let watchButton = gtk_toggle_button_new_with_label(Localized.text("Watch"))!
    let nowButton = gtk_toggle_button_new_with_label(Localized.text("Now"))!
    let hourButton = gtk_toggle_button_new_with_label(Localized.text("Hour"))!
    let toasts = adw_toast_overlay_new()!
    var header: UnsafeMutablePointer<GtkWidget>?
    var controls: WatchControls!
    var openedSize = (width: Int32(0), height: Int32(0))
    var mode: Mode = .watch
    var selectedKey: String?
    var selectedLane: String?
    private(set) var board: AgentBoard = .empty
    private(set) var isLive = false
    var isDestroyed = false
    var facts: AgentFacts?
    var boardTask: Task<Void, Never>?
    var factsTask: Task<Void, Never>?
    var tickToken = 0
    var fetchingHour = false
    var factsFlush = false
    var pendingFacts: (key: String, facts: AgentFacts?)?
    var shortcuts = ShortcutSet.load()
    var selectionSeen = false
    var wantedIndex: Int?
    private(set) var boardsApplied = 0
    private(set) var hoursApplied = 0

    private init(
        parent: UnsafeMutablePointer<GtkWidget>?, source: any AgentsSource, hooks: AgentsHooks,
        onHeadline: @escaping @Sendable () -> Void
    ) {
        Self.built += 1
        self.source = source
        self.hooks = hooks
        self.onHeadline = onHeadline
        actions = AgentsActions(source: source, hooks: hooks)
        window = adw_window_new()!
        let select: @Sendable (String) -> Void = { key in
            Gtk.onMain { AgentsWindow.shared?.toggleSelection(key) }
        }
        let open: @Sendable (String) -> Void = { key in hooks.openChat(key, nil) }
        boardView = AgentsBoardView(
            actions: actions, hooks: .init(select: select, openChat: open))
        peek = AgentPeekView(actions: actions, select: select)
        overlayPeek = AgentPeekView(actions: actions, select: select)
        watchView = AgentsWatchView(context: WatchContext(actions: actions), peek: overlayPeek)
        build(parent: parent)
        actions.changed = { [weak self] key in self?.actionChanged(key) }
        hourView.onSelect = { [weak self] lane in
            Gtk.onMain { [weak self] in self?.select(lane: lane) }
        }
        peek.onClose = { [weak self] in
            Gtk.onMain { [weak self] in self?.deselect() }
        }
        overlayPeek.onClose = { [weak self] in
            Gtk.onMain { [weak self] in self?.deselect() }
        }
        wireWatch()
        plainWordsChanged()
        gtk_window_present(ptr(window))
        watchVisibility()
        if DemoMode.isActive { watchView.startScene("attention") }
        go()
    }

    /// The wall's plain-words model, built again from the settings: nothing at all while the switch
    /// is off or the address is not on this machine or the person's network.
    func plainWordsChanged(transport: any PlainWordsTransport = PlainWordsURLTransport()) {
        guard Preferences.plainWords else {
            usePlainWords(nil)
            return
        }
        let clock = watchView.context.clock
        usePlainWords(
            PlainWordsModel.make(
                address: Preferences.plainWordsAddress, model: Preferences.plainWordsModel,
                transport: transport, clock: { clock.now }))
    }

    func usePlainWords(_ next: PlainWordsModel?) {
        let context = watchView.context
        context.plainModel?.halt()
        context.plainModel = next
        next?.onReady = { [weak self] in self?.watchView.replayWords() }
        watchView.replayWords()
    }

    func close() {
        guard !isDestroyed else { return }
        rememberSize()
        gtk_window_destroy(ptr(window))
    }

    static func destroyed(_ window: AgentsWindow) {
        window.isDestroyed = true
        if shared === window { shared = nil }
        window.stopWork()
        window.controls.releaseAll()
    }

    func handleKey(keyval: UInt32, state: UInt32) -> Bool {
        if keyval == Keymap.escape {
            controls.noteInput()
            if Gtk.focusTakesText(window) {
                gtk_window_set_focus(ptr(window), nil)
            } else if selectedKey != nil {
                deselect()
            } else if controls.isFullscreen {
                controls.setFullscreen(false)
            } else {
                close()
            }
            return true
        }
        if let chord = KeyChord.canonical(keyval: keyval, state: state),
            case .run(.toggleAgents) = shortcuts.resolve(
                chord, context: .insert, pending: [], awaitingApproval: false)
        {
            close()
            return true
        }
        return controls.handle(keyval: keyval, state: state, watch: watchView)
    }

    private func suspensionChanged() {
        if gtk_window_is_suspended(ptr(window)) != 0 {
            stopWork()
        } else if Self.shared === self {
            go()
        }
    }

    func windowSuspended() { suspensionChanged() }

    func go() {
        guard !isLive else { return }
        isLive = true
        AppLog.write(.lifecycle, "agents board opened in \(mode)")
        AgentsRuntime.shared.watching = true
        let source = source
        boardTask = Task { [weak self] in
            await source.open()
            let stream = await source.boards()
            for await next in stream {
                if Task.isCancelled { break }
                Gtk.onMain { [weak self] in self?.apply(board: next) }
            }
        }
        if let key = selectedKey { watchFacts(key) }
        if mode != .now { fetchHour() }
        watchView.start()
        controls.syncInhibit()
        scheduleTick()
    }

    /// The board is not being looked at: every task ends, the source is closed, and the sidebar's
    /// chip goes back to what the chat list can tell.
    func stopWork() {
        guard isLive else { return }
        isLive = false
        AppLog.write(.lifecycle, "agents board closed")
        AgentsRuntime.shared.watching = false
        tickToken += 1
        boardTask?.cancel()
        boardTask = nil
        factsTask?.cancel()
        factsTask = nil
        pendingFacts = nil
        watchView.stop()
        controls?.syncInhibit()
        let source = source
        Task { await source.close() }
        AgentsRuntime.shared.openHeadline = nil
        AgentsRuntime.shared.openBoard = nil
        onHeadline()
    }

    func apply(board next: AgentBoard) {
        guard isLive else { return }
        board = next
        boardsApplied += 1
        let now = Date()
        boardView.apply(next, now: now)
        watchView.apply(board: next)
        var live = Set(next.needsYou.map(\.id))
        live.formUnion(next.working.map(\.id))
        live.formUnion(next.background.map(\.id))
        actions.reconcile(live: live, now: now)
        AgentsParts.setText(hourHeader, next.sentence + " · " + next.watchLine)
        AgentsRuntime.shared.openHeadline = next.headline
        AgentsRuntime.shared.openBoard = next
        onHeadline()
        if let index = wantedIndex, mode == .now, boardView.orderedKeys.indices.contains(index) {
            wantedIndex = nil
            select(key: boardView.orderedKeys[index])
        }
        if let index = wantedIndex, mode == .watch, watchView.orderedKeys.indices.contains(index) {
            wantedIndex = nil
            select(key: watchView.orderedKeys[index])
        }
        if let key = selectedKey {
            if AgentPeekSubject.find(key, in: next) != nil { selectionSeen = true }
            if selectionSeen, AgentPeekSubject.find(key, in: next) == nil, selectedLane == nil {
                deselect()
            } else {
                refreshPeek(now: now)
            }
        }
    }

    private func applyHour(_ next: AgentHour) {
        guard isLive else { return }
        hoursApplied += 1
        hourView.apply(next, now: Date())
        watchView.apply(hour: next)
    }

    func fetchHour() {
        guard isLive, !fetchingHour else { return }
        fetchingHour = true
        let source = source
        Task { [weak self] in
            let hour = await source.hour()
            Gtk.onMain { [weak self] in
                self?.fetchingHour = false
                self?.applyHour(hour)
            }
        }
    }

    private func scheduleTick() {
        tickToken += 1
        let token = tickToken
        Gtk.after(1000) { [weak self] in self?.tickFired(token) }
    }

    private func tickFired(_ token: Int) {
        guard token == tickToken, isLive else { return }
        secondPassed()
        scheduleTick()
    }

    /// One second of the window's life: every clock it shows, every wait it keeps. A check calls
    /// it directly after moving the wall's clock, instead of sleeping through the second.
    func secondPassed() {
        let now = Date()
        boardView.tick(now: now)
        peek.tick(now: now)
        overlayPeek.tick(now: now)
        actions.reconcile(live: Set(boardView.orderedKeys), now: now)
        if mode == .hour {
            fetchHour()
            hourView.tick()
        }
        watchView.tickSecond()
        controls.evaluateIdle(now: watchView.context.clock.now)
        rememberSize()
    }
}
