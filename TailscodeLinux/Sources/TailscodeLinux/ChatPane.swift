import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

/// One conversation, whole: its own stream, transcript, composer, vim, find, status band and
/// pills. The tiling tree composes any number of these side by side, so nothing in here may
/// touch the window's chrome directly — everything a pane needs from the window (dialogs,
/// toasts, the sidebar, the shortcut table) goes through its host.
final class ChatPane: @unchecked Sendable {
    let id: PaneID
    weak var host: MainWindow?

    let root = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    /// What the tiling puts in the canvas for this pane — its shell — when it has one, so a caller
    /// asking where the pane is gets the rectangle it was given even while a glance covers the
    /// conversation. Without a shell it is the conversation itself.
    var outer: UnsafeMutablePointer<GtkWidget>?
    var frame: UnsafeMutablePointer<GtkWidget> { outer ?? root }
    let identityLabel = Gtk.label("", css: "pane-identity", selectable: false)
    /// What the strip says without the activity glyph: the name a divider gives this pane when it
    /// introduces itself to a screen reader.
    var identityName = ""
    var identityActivity: ActivityKind?
    /// The row the wave last had its hands on. A reveal is a prefix painted straight into a label,
    /// so the row it was painting is the one row that can be left holding half a sentence.
    var lastStreamedKey: String?
    /// A row the wave gave up on, which it may not take back while the stream is still in it.
    var abandoned: String?
    /// Whether a settle that could not be made is being tried again, and how many times it has
    /// been. The wave lets go on the same main loop the settle rides on, so a settle that failed
    /// has no clock left of its own — this is that clock.
    var repairingTail = false
    var tailRepairs = 0
    /// The row the repair clock is trying to hand back, which is not always the row the wave last
    /// held: a turn can end and the next one start writing before a failed settle has landed.
    var repairKey: String?
    let transcriptBox = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    let pendingBox = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 8)
    let authBanner = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
    let laneRow = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 2)
    let statusBand = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
    var bandFrame: UnsafeMutablePointer<GtkWidget>?
    var bandReveal: UnsafeMutablePointer<GtkWidget>?
    let bandState = StatusBand.State()
    var agents: [SubagentSummary] = []
    var workflowRuns: [WorkflowRun] = []
    let workflowFold = WorkflowRunFold()
    var userTally = UserMessageTally()
    var usage: AgentUsage?
    /// What the whole conversation has cost. The server's own account when it keeps one, else what
    /// the transcript itself says — and never erased by a poll that came back with nothing, which
    /// is what left the chart on the one machine the session was started from.
    var spendReading = SpendReading()
    var spend: SessionSpend? { spendReading.value }
    /// Which branch this conversation's work is landing on, read on the same slow poll. Nil for a
    /// server that cannot read a repository, which is how the band knows to say nothing at all.
    var git: GitState?
    var contextFill: ContextFill?
    /// What this device has written and the server has not echoed back, with what became of
    /// each. The ledger and every word it wears are Core's; this owns the clock and the sending.
    var pending = PendingSendLedger()
    /// Prompts written while a turn was running, held here rather than handed to the server so
    /// they can still be reworded, reordered or taken back — which is the whole point of them
    /// being a queue and not a send.
    var queue: ConversationQueue?
    /// Messages a spent provider window stopped, and the moment each goes again. The policy and
    /// every word are Core's; this owns the one clock that fires them and the ledger's copy on
    /// disk, so a window that opens after the app was closed is still explained rather than lost.
    var resume = ResumeLedger()
    var resumeTask: Task<Void, Never>?
    /// How many times this conversation has already been sent into the wall and bounced. A plan
    /// that fires and dies produces a *fresh* failure, and reading each fresh failure as a first
    /// attempt is how a bounded retry becomes an unbounded one — so the count lives here, beside
    /// the conversation, and only a turn that is not in a failed state clears it.
    var resumeAttempts = 0
    /// Which waiting message the composer is rewriting. A message taken back and sent again would
    /// land at the end of the queue, which is not editing but deleting and re-adding, and it
    /// silently reorders what somebody wrote.
    var editingQueued: String?
    var pendingFirstMessage:
        (sessionID: String, send: QuickAskSend, attachments: [PendingAttachment])?
    var notice: String?
    let editor = PromptEditor(
        css: "composer", placeholder: Localized.text("Message… (/ for commands)"))
    var entryView: UnsafeMutablePointer<GtkWidget> { editor.textView }
    let sendButton = gtk_button_new()!
    let stopButton = gtk_button_new()!
    var sendWord: UnsafeMutablePointer<GtkWidget>?
    var stopWord: UnsafeMutablePointer<GtkWidget>?
    var compactOn = false
    var sendWordWidth: Int32 = 0
    var measuredScales: [Double] = []
    var stopWordWidth: Int32 = 0
    var attachAble = true
    var commandWidth: Int32 = 0
    var attachWidth: Int32 = 0
    var dial: DialPill?
    var stripRow: UnsafeMutablePointer<GtkWidget>?
    /// The mode badge and the machine and project, kept together so they move as one: beside the
    /// pill while the strip has room, on `placeLine` above it when it does not.
    let placeBox = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
    let placeLine = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
    var stripFrame: UnsafeMutablePointer<GtkWidget>?
    /// The lanes' own width, read while they were last on show, since a hidden widget measures
    /// as nothing and the question is whether they would fit if shown again.
    var laneWidth: Int32 = 0
    var commandButton: UnsafeMutablePointer<GtkWidget>?
    let destinationLabel = Gtk.label("", css: "row-detail", selectable: false)
    var transcriptScroller: UnsafeMutablePointer<GtkWidget>?
    let helpOverlay = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
    var helpShown = false

    let attachmentsBox = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
    var attachments: [PendingAttachment] = []
    var pastedImageCount = 0

    let jumpButton = gtk_button_new()!
    var jumpGlyph: UnsafeMutablePointer<GtkWidget>?
    var jumpWord: UnsafeMutablePointer<GtkWidget>?
    var rowsAtDeparture: Int?
    var followsBottom = true {
        didSet {
            if oldValue != followsBottom {
                rowsAtDeparture = followsBottom ? nil : lastFullRows.count
            }
            syncJumpPill()
        }
    }
    var isAutoScrolling = false
    var scrollAnchor: ScrollAnchor?
    var isFillingInChunks = false
    var pinCorrectorScheduled = false
    var pendingReveal = false
    var fillComplete = false
    var openTimer = OpenTimer()
    var rushing = false
    /// How much of a transcript is folded into rows at all — read from the streaming task, so it
    /// is a plain value rather than anything that needs the main context.
    var rowTailMessages = 300 {
        didSet { feed.update { [rowTailMessages] in $0.tail = rowTailMessages } }
    }

    let findBar = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
    let findEntry = gtk_search_entry_new()!
    let findCountLabel = Gtk.label("", css: "row-detail", selectable: false)
    var findMatches: [Int] = []
    var findCursor = 0
    var highlightedRow: UInt = 0
    var canvasBox: UnsafeMutablePointer<GtkWidget>?
    let messageBar = MessageHoverBar()
    let rails = LinkRailController()
    var hoverOverlay: UnsafeMutablePointer<GtkWidget>?
    var hoverPointer: (x: Double, y: Double)?
    var hoverHeldOff = false
    var hoverDirty = true
    var hoverRefreshQueued = false
    var hoverQuietToken: UInt = 0
    var hoverVerbs: (id: String, verbs: MessageHover.Verbs)?
    var hoverOwners: [String: String] = [:]
    /// The room under the transcript that lets a just-sent prompt rest at the top of the window,
    /// and the row it was made for. Zero once the answer has filled it or the turn has ended.
    var canvasPadding = 0.0
    var canvasPromptKey: String? {
        didSet { syncJumpPill() }
    }
    var canvasPromptTop: Double?
    var canvasSettle: FreshCanvasScroll?
    /// Where in the transcript the send the canvas rose to was drawn. The rows this device drew
    /// are replaced by the server's own account of the same message, and the canvas follows them
    /// across — but a pending row that was discarded rather than reconciled leaves an *older*
    /// prompt as the last thing the person said, and a canvas that rose to that one would be the
    /// wrong page.
    var canvasFloor = 0
    /// The first row whose top margin has to be set again, and the density the margins were last
    /// set for; see ``applyGaps()``.
    var gapsDirtyFrom = 0
    var gapDensity: ChatDensity?
    /// Whether the prompt is still being kept at the top. It is put there and held there, because
    /// every reason the one motion misses — room that lands a frame late, a row measured after it
    /// is drawn, the server's own rows replacing this device's — happens after the motion is over.
    /// A hand on the scroll ends the pin and leaves the room alone.
    var canvasPinned = false
    /// The rise is being set up: the room has been asked for but the motion has not finished. The
    /// canvas may not be retired while this is true — the first settle runs before the motion is
    /// even started, and a prompt that needs no room was being retired there, which left the
    /// motion aiming at a canvas that no longer existed and the page pinned to its own bottom.
    var canvasRising = false
    var captionWakeGeneration = 0
    var pendingSignature = "\u{0}"
    var announcedPending: Set<String> = []
    var turnSession: String?
    var compactingElapsed: UnsafeMutablePointer<GtkWidget>?
    var compactingStartedAt: Date?

    var attachButton: UnsafeMutablePointer<GtkWidget>?
    /// This pane's part in a call: the control in the strip below the composer and the strip above
    /// it. A call is a state of the conversation the pane holds, not a window.
    lazy var call = PaneCall(host: self)
    var callWordWidth: Int32 = 0
    var composerScroller: UnsafeMutablePointer<GtkWidget> { editor.scroller }
    var vim: VimEngine { editor.vim }
    let vimBadge = Gtk.label("", css: "vim-badge", selectable: false)
    let earlierButton = gtk_button_new()!
    var windowLimit = 400
    var windowWidened = false

    var lastFullRows: [TranscriptRow] = []
    var lastFullCount = 0

    let context = TranscriptContext()
    /// The turns drawn as heads: which one is open, which list their rows, the widgets alive.
    let brains = BrainHost()
    var liveDemoTicket = 0
    var liveDemoDeadline = Date.distantPast
    let cascade = CascadePainter()
    let rowBuilder = TranscriptRowBuilder()
    var renderedRows: [TranscriptRow] = []
    var rowWidgets: [UInt] = []
    /// Keys that have already made their entrance. A row is rebuilt whenever its value changes —
    /// a thought growing its word count, a tool call reaching its result — and fading a rebuild in
    /// from nothing is a flicker, not an arrival. Only the first sight of a key animates.
    var enteredRows: Set<String> = []
    /// The widget each unfinished entrance is running on, by row key, so a row rebuilt mid-fade can
    /// be handed the opacity it had reached and the orphaned run can be stopped.
    var entranceInFlight: [String: UInt] = [:]
    /// The pane's own entrance clock: the earliest moment the next row may begin fading in, in the
    /// display's monotonic seconds. Batches queue behind each other on it instead of each restarting
    /// the stagger from zero.
    var nextEntranceAt: Double = 0
    var placeholderShown = false
    var currentPlaceholder: String?
    var chooser: PaneChooser?
    var freshlyCreatedID: String?
    var landedPictures: Set<String> = []
    var landingFlushPending = false
    var inFlightSubagents: Set<String> = []
    var lastRecordedDraft = ""
    /// A press on the cut-off card this device is still waiting on an answer to.
    ///
    /// It is held here rather than folded into the record because it is this device's news and not
    /// the server's: between the press and the server's word the card must already say what was
    /// asked of it, and the moment the server's own account moves — resumed, gone, or refused and
    /// re-read — this is dropped and the card goes back to reporting only what the server said.
    var interruptedPress: InterruptedTurnPress?
    /// A wind-back in flight from this device: set the instant the confirm dialog answers, so a
    /// second right-click cannot fire a second one while the first is still on the wire.
    var revertUndoInFlight = false
    /// This device's own press on a standing revert's Restore button, worn by the row until the
    /// server answers (the banner itself carries no such state, so it lives here the same way
    /// ``interruptedPress`` carries the interrupted-turn card's).
    var revertRestoring = false
    /// The exact words a successful undo put in an empty composer, remembered so a Restore that
    /// follows clears them only if they are still exactly what was put there. A draft typed over
    /// them in the meantime is never thrown away.
    var revertComposerFill: String?
    var retryWakeGeneration = 0

    var entry: SessionEntry?
    /// What this pane is watching instead of talking, when it is a video slot rather than a chat.
    var video: VideoPane?
    /// What this pane is reading instead of talking, when it is a browser slot rather than a chat.
    var page: WebPane?
    /// What this pane is painting instead of talking, when it is a draw slot rather than a chat.
    var draw: DrawPane?
    /// What this pane is streaming instead of talking, when it is a preview slot rather than a chat.
    var preview: PreviewPane?
    var backend: (any CodingAgentBackend)?
    var inFlightDesignBoards: Set<String> = []
    var conversation: AgentConversation?
    var lastState: ConversationState?
    /// Everything the pane started that must stop when the pane stops being alive: lane
    /// observers and the like, for the life of the pane.
    let lifetime = PaneLifetime()
    /// What the open conversation started — its extras, its fetches, its resume clock — ended on
    /// every switch of conversation, reset, slot swap and shutdown.
    let chatLife = PaneLifetime()
    /// What keeps the pane live — its hub lease, its row pump, its drain slot, its ticker, its
    /// reveal and its identity pulse — ended also when the pane is hidden (parked), and taken
    /// again when it is shown.
    let streamLife = PaneLifetime()
    let feed = PaneFeed()
    var lease: LiveLease?
    var drainToken: DrainToken?
    /// Which conversation a build was made for: bumped by every open, so a build that was already
    /// on its way when the pane moved on is dropped at the drain rather than drawn into the wrong
    /// chat.
    var streamGeneration: UInt64 = 0
    /// Hidden by a zoom: no lease, no pump, no clocks, the last rows frozen.
    var isParked = false
    /// Whether the window's focus is on this pane. Only the focused pane runs the reveal.
    var isFocusedPane = true
    var drainPriority: DrainPriority = .focused
    var agentStreamTask: Task<Void, Never>?
    var agentStreamSessionID: String?
    var tickerTask: Task<Void, Never>?

    var models: [ModelInfo] = [] {
        didSet { feed.update { [models] in $0.models = models } }
    }
    var modelsReachable: Bool?
    var catalogWatchTask: Task<Void, Never>?
    var lastPillsSignature = ""
    var lastStatusSignature = ""
    var lastNetworkFactsAt: Date?
    var lastGitFactsAt: Date?
    var commands: [AgentCommand] = []
    lazy var completion = SlashPopover(anchor: composerScroller)
    var completionMatches: [AgentCommand] { completion.matches }
    var chosenModel: ModelSelection?
    var chosenEffort: String?
    var ultracodeInFlight = false

    /// What the next turn out of this pane runs on, however it is started — a typed prompt, a
    /// slash command, or a compaction someone opened from the window's own chrome.
    var promptChoice: (model: ModelSelection?, effort: String?) {
        (chosenModel, ModelEffort.surviving(chosenEffort, options: effortOptions()))
    }

    var sessionID: String? { entry?.session.id }
    var auraActive: Bool { editor.auraActive }

    /// Which prompt box this pane's composer is: the conversation, never the pane, so what was
    /// half-typed here is waiting in whichever pane opens that chat next.
    var draftScope: DraftScope? {
        guard let entry else { return nil }
        return .chat(profileID: entry.profileID, sessionID: entry.session.id)
    }

    /// The `/compact` instruction is its own box, kept apart from the prompt being written: what
    /// the summary must keep is not what you were about to say.
    var compactionScope: DraftScope? {
        guard let entry else { return nil }
        return .compaction(profileID: entry.profileID, sessionID: entry.session.id)
    }

    /// What this pane is watching first-hand, for the chat list's own LIVE NOW.
    ///
    /// A listing reports `active` only for the seconds a turn is literally open on the server, so
    /// the pane streaming a conversation is the only witness that can say it is running now, that
    /// it stopped to ask something, or that its last turn failed. The reading is shared with the
    /// background watcher, so the row and the band never speak two vocabularies for one turn.
    /// A pane that has taken a chat and has not heard anything about it yet is watching, not
    /// reporting that nothing is running: the row it just took over from the background watcher
    /// must not settle on the difference between two witnesses.
    var presence: SessionPresence {
        guard !isParked else { return entry == nil ? .unobserved : .unsettled }
        guard let state = lastState else { return entry == nil ? .unobserved : .unsettled }
        return SessionPresence.reading(state, step: bandState.facts.runningTool)
    }

    var lastPresence: SessionPresence = .unobserved

    init(id: PaneID, host: MainWindow) {
        self.id = id
        self.host = host
        host.live.attach(window: host)
        buildRoot()
        wireContext()
        cascade.holder = UnsafeMutableRawPointer(transcriptBox)
        cascade.onFrame = { [weak self] in self?.paintCascade() }
        cascade.onStalled = { [weak self] in self?.giveUpCascade() }
    }

    lazy var effortVoice = EffortVoice { [weak self] words in
        Gtk.onMain { [weak self] in self?.announce(words) }
    }

    var identityPinned = false
    var identityAlsoOpenIn: Int?

    /// What the selftest says a pane is, so a pane can be a chat for the tiling's rules without a
    /// server to hold the conversation.
    var kindOverride: PaneKind?

    /// How many rows a peer of the focused pane realises: the governor's window for the shed level,
    /// or nothing in particular for the focused pane, which uses the person's own preference.
    var rowWindowOverride: Int?

    var hiddenFurniture: [UInt] = []

    var identityNamesServer = false

    /// Set once the pane has been closed: nothing may take a lease or a clock for it again.
    var isShutDown = false

    /// The transcript renders a tail window, not the whole history; the rest waits behind one
    /// button that widens the window. The locally echoed prompt stands only until the transcript
    /// carries the same words back.
    var lastReadMark = Date.distantPast
    var wasRunningWhenMarked = false

    /// What has been read of each long passage so far, so a streamed token hashes the one row it
    /// changed and not every row of the conversation.
    var doubledRows = DoubledRowWatch()

    /// One line per doubled passage per pane: the diff rebuilds these rows many times a second,
    /// and a log that repeated itself at that rate would bury the thing it is reporting.
    var reportedDoubles: Set<Int> = []

    /// Guards the drain against re-entering itself: `drainQueue` runs at the end of `apply`, and
    /// sending re-applies.
    var draining = false

    /// The stretch after a send during which the server still reads idle. The queue waits it out,
    /// or every message written during a turn goes at once and the agent answers only the last.
    var handoff = TurnHandoff()
    var handoffWakeGeneration = 0

    var shownWelcome: EmptyWelcome?

    /// Turns what is on screen into what the rows say, by identity rather than by value.
    ///
    /// The applier this replaces walked the two lists comparing rows *whole* and threw away
    /// everything from the first pair that differed. That is right only for a transcript that grows
    /// at its end, and this one does not: a tool result lands on a call fifty rows back, a second
    /// TodoWrite demotes the row the previous one had promoted, a picture finishes decoding. Each
    /// of those changes one row's value in the middle and cost the entire tail below it — torn
    /// down, re-appended a batch per idle hop, the transcript visibly collapsing and regrowing over
    /// several frames — and not one of them was an insertion. `RowDiff` answers from the keys
    /// alone, so a value change can only ever repaint the row it happened to, and the ordinary
    /// streaming case moves no widget at all.
    ///
    /// Nothing here is chunked. Chunking is for the first fill, where the rows have never been on
    /// screen and the cost is real; a tail being put back from rows the pane already holds must
    /// land in one frame, because the alternative is the collapse this exists to remove.
    /// A click is a press and a release, and a row rebuilt between the two never becomes one.
    ///
    /// A run row's value changes on every arrival — a tool's status, its output, a thought still
    /// being written inside it — so the widget under the pointer is destroyed and remade dozens of
    /// times a second while a turn runs, and the disclosure the reader is trying to open is gone
    /// before their finger comes up. The rows are held for the length of the press and applied on
    /// the release: a click always lands on the row it was aimed at, and the transcript catches up
    /// a tenth of a second later.
    var pointerHeld = false
    var heldRows: [TranscriptRow]?
    /// Rows a cache arrival asked to redraw while the pointer was down, redrawn on the release.
    var heldReplacements: Set<String> = []
}

/// A notification observer carried into a pane's lifetime, which only holds `Sendable` cancels.
final class ObserverToken: @unchecked Sendable {
    let observer: NSObjectProtocol
    init(_ observer: NSObjectProtocol) { self.observer = observer }
}

