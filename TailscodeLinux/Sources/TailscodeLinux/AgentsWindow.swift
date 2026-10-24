import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// The agents board as a window of its own: Now and Hour in the header, the board on the left and
/// the peek of what is selected on the right, collapsed while nothing is.
///
/// One window for the process — raising it twice raises it, never builds a second — and it is the
/// only thing that keeps the tower open: it opens the source when it is shown, and closes it when
/// the window is closed or hidden by the compositor, so nothing is watched while nobody looks.
final class AgentsWindow: @unchecked Sendable {
    enum Mode: Equatable {
        case now
        case hour
    }

    nonisolated(unsafe) private static var shared: AgentsWindow?
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
    let hourView = AgentHourView()
    private let hooks: AgentsHooks
    private let onHeadline: @Sendable () -> Void
    private let stack = gtk_stack_new()!
    let revealer = gtk_revealer_new()!
    private let hourHeader = Gtk.label("", css: "agents-watch", wrap: true, selectable: false)
    private let nowButton = gtk_toggle_button_new_with_label(Localized.text("Now"))!
    private let hourButton = gtk_toggle_button_new_with_label(Localized.text("Hour"))!
    let toasts = adw_toast_overlay_new()!
    private(set) var mode: Mode = .now
    var selectedKey: String?
    var selectedLane: String?
    private(set) var board: AgentBoard = .empty
    private(set) var isLive = false
    private(set) var isDestroyed = false
    var facts: AgentFacts?
    private var boardTask: Task<Void, Never>?
    var factsTask: Task<Void, Never>?
    private var tickToken = 0
    private var fetchingHour = false
    var factsFlush = false
    var pendingFacts: (key: String, facts: AgentFacts?)?
    private var shortcuts = ShortcutSet.load()
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
        window = gtk_window_new()!
        let select: @Sendable (String) -> Void = { key in
            Gtk.onMain { AgentsWindow.shared?.toggleSelection(key) }
        }
        let open: @Sendable (String) -> Void = { key in hooks.openChat(key, nil) }
        boardView = AgentsBoardView(
            actions: actions, hooks: .init(select: select, openChat: open))
        peek = AgentPeekView(actions: actions, select: select)
        build(parent: parent)
        actions.changed = { [weak self] key in self?.actionChanged(key) }
        hourView.onSelect = { [weak self] lane in
            Gtk.onMain { [weak self] in self?.select(lane: lane) }
        }
        peek.onClose = { [weak self] in
            Gtk.onMain { [weak self] in self?.deselect() }
        }
        gtk_window_present(ptr(window))
        go()
    }

    private func build(parent: UnsafeMutablePointer<GtkWidget>?) {
        gtk_window_set_title(ptr(window), Localized.text("Agents"))
        gtk_window_set_default_size(ptr(window), 1180, 760)
        FeatureWindow.fill(window, near: parent, minimumWidth: 760, minimumHeight: 520)
        gtk_widget_set_size_request(window, 640, 420)
        Gtk.addClass(window, "agents-window")
        if let parent, let root = gtk_widget_get_root(parent) {
            gtk_window_set_transient_for(ptr(window), ptr(UnsafeMutableRawPointer(root)))
        }

        let header = adw_header_bar_new()!
        let switcher = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        Gtk.addClass(switcher, "linked")
        gtk_toggle_button_set_group(ptr(hourButton), ptr(nowButton))
        gtk_toggle_button_set_active(ptr(nowButton), 1)
        gtk_box_append(ptr(switcher), nowButton)
        gtk_box_append(ptr(switcher), hourButton)
        tailscode_set_accessible_label(nowButton, Localized.text("Now"))
        tailscode_set_accessible_label(hourButton, Localized.text("Hour"))
        adw_header_bar_set_title_widget(op(UnsafeMutableRawPointer(header)), switcher)
        gtk_window_set_titlebar(ptr(window), header)
        Gtk.connect(UnsafeMutableRawPointer(nowButton), "toggled") { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, gtk_toggle_button_get_active(ptr(self.nowButton)) != 0 else { return }
                self.show(.now)
            }
        }
        Gtk.connect(UnsafeMutableRawPointer(hourButton), "toggled") { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self, gtk_toggle_button_get_active(ptr(self.hourButton)) != 0 else { return }
                self.show(.hour)
            }
        }

        let hourPage = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 6)
        Gtk.margins(hourHeader, top: 14, bottom: 0, leading: 22, trailing: 22)
        gtk_box_append(ptr(hourPage), hourHeader)
        gtk_box_append(ptr(hourPage), hourView.widget)
        gtk_stack_add_named(op(stack), boardView.widget, "now")
        gtk_stack_add_named(op(stack), hourPage, "hour")
        gtk_widget_set_hexpand(stack, 1)

        let inspector = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        Gtk.addClass(inspector, "agents-inspector")
        gtk_widget_set_size_request(peek.widget, 380, -1)
        gtk_box_append(ptr(inspector), peek.widget)
        gtk_revealer_set_child(op(revealer), inspector)
        gtk_revealer_set_transition_type(op(revealer), GTK_REVEALER_TRANSITION_TYPE_SLIDE_LEFT)
        gtk_revealer_set_reveal_child(op(revealer), 0)

        let body = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        gtk_box_append(ptr(body), stack)
        gtk_box_append(ptr(body), revealer)
        adw_toast_overlay_set_child(op(UnsafeMutableRawPointer(toasts)), body)
        gtk_window_set_child(ptr(window), toasts)

        Gtk.onKey(window) { [weak self] keyval, state in
            self?.handleKey(keyval: keyval, state: state) ?? false
        }
        Gtk.onNotify(UnsafeMutableRawPointer(window), property: "suspended") { [weak self] in
            Gtk.onMain { [weak self] in self?.suspensionChanged() }
        }
        Gtk.connect(UnsafeMutableRawPointer(window), "destroy") { [weak self] in
            guard let self else { return }
            Self.destroyed(self)
        }
    }

    func close() {
        guard !isDestroyed else { return }
        gtk_window_destroy(ptr(window))
    }

    private static func destroyed(_ window: AgentsWindow) {
        window.isDestroyed = true
        if shared === window { shared = nil }
        window.stopWork()
    }

    func show(_ next: Mode) {
        mode = next
        gtk_stack_set_visible_child_name(op(stack), next == .now ? "now" : "hour")
        gtk_toggle_button_set_active(ptr(next == .now ? nowButton : hourButton), 1)
        if next == .hour { fetchHour() }
    }

    func handleKey(keyval: UInt32, state: UInt32) -> Bool {
        if keyval == Keymap.escape {
            if Gtk.focusTakesText(window) {
                gtk_window_set_focus(ptr(window), nil)
            } else if selectedKey != nil {
                deselect()
            } else {
                close()
            }
            return true
        }
        guard let chord = KeyChord.canonical(keyval: keyval, state: state),
            case .run(.toggleAgents) = shortcuts.resolve(
                chord, context: .insert, pending: [], awaitingApproval: false)
        else { return false }
        close()
        return true
    }

    private func suspensionChanged() {
        if gtk_window_is_suspended(ptr(window)) != 0 {
            stopWork()
        } else if Self.shared === self {
            go()
        }
    }

    func go() {
        guard !isLive else { return }
        isLive = true
        AppLog.write(.lifecycle, "agents board opened in \(mode == .now ? "now" : "hour")")
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
        if mode == .hour { fetchHour() }
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
        let source = source
        Task { await source.close() }
        AgentsRuntime.shared.openHeadline = nil
        onHeadline()
    }

    func apply(board next: AgentBoard) {
        guard isLive else { return }
        board = next
        boardsApplied += 1
        let now = Date()
        boardView.apply(next, now: now)
        var live = Set(next.needsYou.map(\.id))
        live.formUnion(next.working.map(\.id))
        live.formUnion(next.background.map(\.id))
        actions.reconcile(live: live, now: now)
        AgentsParts.setText(hourHeader, next.sentence + " · " + next.watchLine)
        AgentsRuntime.shared.openHeadline = next.headline
        onHeadline()
        if let index = wantedIndex, mode == .now, boardView.orderedKeys.indices.contains(index) {
            wantedIndex = nil
            select(key: boardView.orderedKeys[index])
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
    }

    private func fetchHour() {
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
        let now = Date()
        boardView.tick(now: now)
        peek.tick(now: now)
        actions.reconcile(live: Set(boardView.orderedKeys), now: now)
        if mode == .hour {
            fetchHour()
            hourView.tick()
        }
        scheduleTick()
    }
}
