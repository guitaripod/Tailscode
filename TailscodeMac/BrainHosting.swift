import AppKit
import TailscodeCore

/// What the parts of an open brain (the head, the filter chips, the step list, the account and the
/// footer) ask of the row that holds them, and nothing more. The row owns the turn's model through
/// the pane's `BrainStore`; a part reads it, changes it only by running an action through
/// `browse`, and tells the row when it needs the row's size or its clocks looked at again.
@MainActor
protocol BrainSurfaceHost: AnyObject {
    var turnID: String { get }
    /// The turn's model as the store holds it now.
    var model: NeuralBrainModel { get }
    /// Changes the stored model in place and returns what the change answered.
    @discardableResult
    func updateModel<Value>(_ body: (inout NeuralBrainModel) -> Value) -> Value
    var inks: BrainInks { get }
    /// The metrics for the row's width now.
    var currentMetrics: NeuralStageMetrics { get }
    var density: ChatDensity { get }
    /// The words of the final message, which the account's answer item and the footer's chips read.
    var answerText: String { get }
    var reduceMotion: Bool { get }
    /// Whether the brain is in the part of the transcript the reader can see.
    var isVisible: Bool { get }
    /// Runs one of Core's actions through the model and performs what it asks for. `grabFocus` is
    /// false for events that did not come from the list itself (a filter's click, the search
    /// field's typing, a wheel), which must not take the keyboard from where the person put it.
    func browse(_ action: NeuralBrowse.Action, grabFocus: Bool)
    /// The pointer is over a step's row (or none): the readout previews it and the head rings it.
    func hoverStep(_ id: String?)
    /// A row or part changed the size it wants.
    func relayout()
    /// A part started or stopped something that moves, so the row asks its clocks again.
    func animationChanged()
    /// Puts words on the pasteboard and says so.
    func copyToPasteboard(_ text: String)
    func announce(_ words: String)
    /// Scrolls the transcript to the approval or question card the account's ask points at.
    func goToApproval()
    /// Puts a quote in the composer, focused, and sends nothing.
    func replyWithQuote(_ quote: String)
    /// Scrolls the transcript to the answer under this turn's brain.
    func revealAnswer()
    /// Sends the keyboard to the list (or the search field when it is open).
    func focusList()
    func focusSearchField()
    /// The brain is asked to put the open row away (the fourth Esc).
    func collapseBrain()
    /// A step's old row is shown in the transcript under the brain.
    func showInRows(_ stepID: String)
    /// Opens a Task node's agent card in the transcript.
    func openSubagent(_ stepID: String)
    /// Whether the person asked for this turn's old rows to be listed under the brain.
    var isShowingRows: Bool { get }
    /// The literal paths and commands the answer quotes that some step carries.
    var answerChips: [String] { get }
    /// What a screen reader says for the whole brain.
    var accessibleLabel: String { get }
    /// The stage took a press or focus.
    func stageFocusChanged(_ focused: Bool)
    func stagePressed()
    /// A key arrived in a part that holds the brain's keyboard; true when the brain used it.
    func handleBrainKey(_ event: NSEvent, from view: NSView) -> Bool
    /// Whether the brain would use this key now, for the window's own key monitor to stand aside.
    func brainKeyApplies(_ event: NSEvent) -> Bool
    /// The context menu for a step, at the pointer.
    func presentMenu(forStep id: String, event: NSEvent, in view: NSView)
}

/// A view that holds the brain's keyboard: the window's key monitor lets its keys through.
@MainActor
protocol BrainKeyTaker: AnyObject {
    func takesBrainKey(_ event: NSEvent) -> Bool
}

/// The display clock a part uses for the short stretches it animates in, and nothing else: a part
/// that has nothing moving owns no link at all. It is gated like every clock in the window: a
/// window nobody can see runs none.
@MainActor
final class BrainClock {
    private weak var view: NSView?
    private var link: CADisplayLink?
    private let onTick: (Double) -> Void
    private(set) var isRunning = false
    private let tempo: NeuralTempo

    init(view: NSView, tempo: NeuralTempo = .display, onTick: @escaping (Double) -> Void) {
        self.view = view
        self.tempo = tempo
        self.onTick = onTick
    }

    static var now: Double { CACurrentMediaTime() }

    func run() {
        guard link == nil, let view, view.window != nil, DisplayGate.allows(view) else { return }
        let made = view.displayLink(target: self, selector: #selector(step(_:)))
        if tempo == .activity {
            let cap = Float(ActivityTuning.frameRate)
            made.preferredFrameRateRange = CAFrameRateRange(
                minimum: Float(ActivityTuning.minimumFrameRate), maximum: cap, preferred: cap)
        }
        made.add(to: .main, forMode: .common)
        link = made
        isRunning = true
    }

    func stop() {
        link?.invalidate()
        link = nil
        isRunning = false
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let view, DisplayGate.allows(view) else {
            stop()
            return
        }
        onTick(link.timestamp)
    }

    isolated deinit { stop() }
}
