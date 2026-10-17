import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// What a pane keeps about its brains: which one the person opened, which ones list their rows,
/// the widgets that are alive, and what the conversation says about the turn being written.
///
/// What the person chose is remembered per conversation, in memory, and only means something while
/// the turn it was chosen against is the latest (`NeuralOpenPolicy`); the pane hands it to the row
/// builder, which decides each row's `open` from it, so the rule lives in Core and this is only
/// where the answer is kept. Everything here runs on the main loop.
final class BrainHost: @unchecked Sendable {
    private final class Weak {
        weak var view: BrainView?
        init(_ view: BrainView) { self.view = view }
    }

    private nonisolated(unsafe) static var choicesBySession: [String: [String: Bool]] = [:]
    private nonisolated(unsafe) static var rowsBySession: [String: Set<String>] = [:]

    /// Asks the pane to build its rows again and says what to build them with.
    var changed: (() -> Void)?
    /// Asked just before a brain above the reader's place changes height, so the pane holds the
    /// row at the top of the viewport where it is.
    var anchor: (() -> Void)?
    /// A person opened or closed a brain: a reading gesture, so the transcript stops following its end.
    var userToggled: (() -> Void)?
    /// The open policy the last row build made, for the pane's own turns.
    var policy: (() -> NeuralOpenPolicy?)?
    /// Whether a brain's row is in the part of the transcript the reader can see, which is what
    /// decides between a move and the end state alone.
    var onScreen: ((BrainView) -> Bool)?
    /// Scrolls to the approval or question card the readout's ask points at.
    var revealApproval: (() -> Void)?
    /// A zone a card's chip asked to open the brain diving into, by turn.
    var pendingDive: [String: NeuralZone] = [:]
    private var swapping: Set<String> = []
    private var scrollPending = false
    var sessionKey = "none" {
        didSet { if sessionKey != oldValue { views.removeAll() } }
    }
    private(set) var suspended = false
    private var views: [String: Weak] = [:]
    private var live = NeuralBrainContext.none
    private(set) var forced: ActivityKind?

    var choices: [String: Bool] {
        get { Self.choicesBySession[sessionKey] ?? [:] }
        set { Self.choicesBySession[sessionKey] = newValue }
    }

    var rowsShown: Set<String> {
        get { Self.rowsBySession[sessionKey] ?? [] }
        set { Self.rowsBySession[sessionKey] = newValue }
    }

    func settings() -> BrainBuildSettings {
        BrainBuildSettings(
            style: Preferences.effectiveActivityStyle, choices: choices, rowsShown: rowsShown,
            look: MatrixTheme.palette.name)
    }

    var liveViews: [BrainView] { views.values.compactMap(\.view) }

    func view(forTurn id: String) -> BrainView? { views[id]?.view }

    /// Every turn the pane draws as a brain, newest last, by the order of its widgets' turns.
    var turnIDs: [String] { policy?()?.turnIDs ?? [] }

    func register(_ view: BrainView) {
        views = views.filter { $0.value.view != nil }
        views[view.turnID] = Weak(view)
    }

    func forget(_ view: BrainView) {
        if views[view.turnID]?.view === view { views[view.turnID] = nil }
    }

    func context(for turnID: String) -> NeuralBrainContext {
        guard turnID == policy?()?.latest else {
            return NeuralBrainContext(fill: nil, providerID: live.providerID, effortOptions: live.effortOptions)
        }
        var context = live
        if let forced { context.activity = forced }
        return context
    }

    /// The conversation's own account of the live turn, applied to every brain that is up.
    func update(context: NeuralBrainContext) {
        guard context != live else { return }
        live = context
        for view in liveViews { view.refreshContext() }
    }

    /// A state worn by the live brain whatever the conversation says, for the harness.
    func force(activity: ActivityKind?) {
        forced = activity
        for view in liveViews { view.refreshContext() }
    }

    func toggleOpen(turnID: String) {
        guard let policy = policy?() else { return }
        userToggled?()
        noteSwap(policy: policy, toggling: turnID)
        choices = policy.toggle(turnID: turnID)
        changed?()
    }

    func setOpen(_ open: Bool, turnID: String) {
        guard let policy = policy?(), policy.isOpen(turnID: turnID) != open else { return }
        noteSwap(policy: policy, toggling: turnID)
        choices = policy.toggle(turnID: turnID)
        changed?()
    }

    /// Opening one brain closes the one that was open: the two moves are one, run together.
    private func noteSwap(policy: NeuralOpenPolicy, toggling turnID: String) {
        swapping = []
        guard let open = policy.openTurnID, open != turnID else { return }
        swapping = [open, turnID]
    }

    /// Whether this turn's move is half of a swap, asked once as the move begins.
    func consumeSwap(_ turnID: String) -> Bool {
        swapping.remove(turnID) != nil
    }

    func isOnScreen(_ view: BrainView) -> Bool { onScreen?(view) ?? true }

    func userOpened() {}

    func moveFinished(_ view: BrainView, opening: Bool) {}

    func toggleRows(turnID: String) {
        var shown = rowsShown
        if shown.contains(turnID) { shown.remove(turnID) } else { shown.insert(turnID) }
        rowsShown = shown
        changed?()
    }

    /// A key press while a head's stage holds the keyboard: the stage's own keys (walk, pin, let
    /// go) are taken before the window's normal mode can read them as commands, because a node
    /// walked with the arrows is the one thing in the window a letter or Return must not reach
    /// past. Nothing is taken when no stage has focus.
    func handleKey(keyval: UInt32, state: UInt32) -> Bool {
        for view in liveViews where view.stageHasFocus {
            return view.handleKey(keyval: keyval, state: state)
        }
        return false
    }

    /// The governor moved: heads that cannot afford their stage give it up, heads that can again
    /// take it, and every clock is asked again what it may run at.
    func budgetChanged() {
        BrainBudget.observe { [weak self] in self?.allowanceChanged() }
        for view in liveViews { view.motionChanged() }
    }

    /// The debounced verdict on the stage flipped.
    func allowanceChanged() {
        for view in liveViews { view.budgetChanged() }
    }

    /// The reader scrolled: every brain asks again whether it is in view, at most ten times a
    /// second however fast the wheel turns.
    func scrolled() {
        guard !scrollPending else { return }
        scrollPending = true
        Gtk.after(100) { [weak self] in
            Gtk.onMain { [weak self] in
                guard let self else { return }
                self.scrollPending = false
                self.viewportMoved()
            }
        }
    }

    func viewportMoved() {
        for view in liveViews { view.viewportMoved() }
    }

    /// A head held by a pane that is hidden owns no clock, no compositor and no surface.
    func suspend() {
        guard !suspended else { return }
        suspended = true
        for view in liveViews { view.suspend() }
    }

    func resume() {
        guard suspended else { return }
        suspended = false
        for view in liveViews { view.resume() }
    }

    /// The words the harness reads back: how many heads are up, which are open, what runs.
    var reading: String {
        let all = liveViews
        let open = all.filter(\.isOpen).count
        let clocks = all.filter(\.isClockRunning).count
        let stages = all.filter(\.hasStage).count
        return "brains=\(all.count) open=\(open) stages=\(stages) clocks=\(clocks) suspended=\(suspended)"
    }
}
