import AppKit
import CodingAgentKit
import TailscodeCore

/// What a row needs from the transcript that is not in the row itself: which rows are open, the
/// pictures and subagent transcripts already fetched, and the callbacks that fetch more. Rows are
/// rebuilt freely; this survives them.
@MainActor
final class TranscriptContext {
    var expanded = TranscriptExpansion()
    /// Whether the turn these rows belong to is still open. A tool call the record still says is
    /// running only moves while it is; once the turn has ended the same record is a stale mark.
    var turnOpen = false
    /// The newest text of a thought that is still being written. A reasoning row's header counts
    /// its words, so it changes on every arrival — and rebuilding the row for that is a flicker.
    /// The row is updated in place instead, and a body opened afterwards reads the current text
    /// from here rather than the one its closure was built with.
    var liveReasoning: [String: String] = [:]
    var subagentRows: [String: [TranscriptRow]] = [:]
    /// Live facts for the agents of the running fan-out, keyed by spawning tool-use id — what an
    /// inline agent card shows for progress while its transcript is still being written.
    var agentFacts: [String: SubagentSummary] = [:]
    /// The moment those facts were read at. It belongs to the arrival rather than to the row: an
    /// agent's clock is a reading of one snapshot, so a card built between two polls states the
    /// time the facts it draws are from, and two cards in the same transcript can never disagree
    /// about what time it is.
    var agentReadAt: Date = Date()
    /// The workflow runs of this conversation, keyed by the Workflow call that started each. A run
    /// outlives its tool call by minutes, so the card reads its state from here rather than from a
    /// call that has said all it will say.
    var workflowRuns: [String: WorkflowRun] = [:]
    /// The clock the live parts of a workflow card are drawn against, moved by the ticker so every
    /// spinner and elapsed reading in one frame agrees.
    var workflowNow: Date = Date()
    var onToggle: ((String, Bool) -> Void)?
    /// The words of the answer a row belongs to, onto the pasteboard — what the hover capsule's
    /// Copy does, reachable from the row's accessibility actions.
    var copyAnswer: ((String) -> Void)?
    /// Called with a just-opened disclosure row: the transcript scrolls the minimum needed to
    /// show the opened body, never past the point where the clicked header would leave the top.
    var revealRow: ((NSView) -> Void)?
    /// Called on the first frame of a brain's opening move with the row and the height it will
    /// rest at: the transcript begins to scroll to where the whole of it can be seen, so what the
    /// move reveals is drawn as the parts come in and not all at once when the move lands.
    var revealAhead: ((NSView, CGFloat) -> Void)?
    var requestImage: ((FileReference, String) -> Void)?
    /// Whether a picture's bytes arrived and would not decode, so its row settles as a filename.
    var isImageRefused: ((String) -> Bool)?
    var requestSubagent: ((ToolCall) -> Void)?
    /// A workflow agent is fetched by its own id: it has no spawning call to name it.
    var requestWorkflowAgent: ((String) -> Void)?
    var openImage: ((String, String) -> Void)?
    var presentText: ((_ title: String, _ subtitle: String?, _ body: String, _ mono: Bool) -> Void)?
    /// A short confirmation the window floats over everything — "Command copied".
    var toast: ((String) -> Void)?
    /// The words of a turn that said nothing, sent again — the transcript's own send, so the
    /// retry is a message like any other rather than a second road into the backend.
    var askAgain: ((String) -> Void)?
    /// A board of design alternatives, opened. The pane owns it because reading the mocks is the
    /// server's file route and building one is the pane's own send.
    var openDesign: ((DesignSource) -> Void)?
    /// What each board in this transcript turned out to be, so its card can name it rather than
    /// its folder. Filled by the pane the first time a card asks.
    var designBoards: [String: DesignManifest] = [:]
    var requestDesignBoard: ((String) -> Void)?
    /// A message still waiting behind the running turn, opened for rewriting. It is the one row in
    /// a transcript that has not happened yet, so it is the one row a press means something on.
    var editQueued: ((String) -> Void)?
    /// Lifts the pause a Stop left on the queue, which is the queue's and not any one message's.
    var resumeQueue: (() -> Void)?
    var pendingAct: ((UUID, PendingSend.Act) -> Void)?
    /// A message being held for a provider's window: sent into it now anyway, opened for
    /// rewriting, or let out of the wait.
    var resumeAct: ((UUID, ResumeReading.Act) -> Void)?
    /// A turn the server's machine cut off, picked back up or let go on that machine.
    var resumeInterrupted: (() -> Void)?
    var dismissInterrupted: (() -> Void)?
    /// Whether "Undo from here" belongs on this message's row: a live question, since the answer
    /// depends on the conversation's own capabilities and on whatever else this device is already
    /// winding back, both of which change while the row just sits there.
    var offersUndo: ((String) -> Bool)?
    /// The row asked to undo back to its own message; the confirmation and the request itself
    /// belong to the transcript, which is the one thing that knows the conversation well enough
    /// to ask and to carry the answer out.
    var confirmUndo: ((String) -> Void)?
    /// The standing revert's own Restore press.
    var restoreRevert: (() -> Void)?
    /// Names a model the way this device already names it elsewhere, for a note that mentions
    /// one. Nil leaves Core's own fallback, the model's bare id, standing.
    var modelName: (ModelSelection) -> String? = { _ in nil }
    /// Where a rail learns its addresses' titles and icons: the shared fetcher, or a stub when a
    /// harness has no network.
    var linkSource: LinkCardSource = .live
    /// A rail was pressed, or a key was pressed on it: the pane owns the plate it opens.
    var activateRail: ((LinkRailLine, _ viaKeyboard: Bool) -> Void)?
    /// The pane's brains, which a brain row reads its model from and tells what the person did.
    var brains: BrainStore?
    /// Hands the keyboard back to the composer: a brain's stage takes it for the arrow keys and
    /// gives it up when it has nothing more to say with it.
    var returnFocus: (() -> Void)?
    /// Reveals a subagent's own card in the transcript, for the brain's Task node.
    var revealSubagent: ((String) -> Void)?

    /// A run reads as open when any step inside it is, so folding a step into a run carries the
    /// reader's decision in with it rather than collapsing it.
    func isExpanded(_ key: String) -> Bool { expanded.reads(key) }
}
