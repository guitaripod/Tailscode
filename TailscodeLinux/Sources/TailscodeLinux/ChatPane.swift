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
    private let identityLabel = Gtk.label("", css: "pane-identity", selectable: false)
    private var identityActivity: ActivityKind?
    /// The row the wave last had its hands on. A reveal is a prefix painted straight into a label,
    /// so the row it was painting is the one row that can be left holding half a sentence.
    var lastStreamedKey: String?
    /// A row the wave gave up on, which it may not take back while the stream is still in it.
    var abandoned: String?
    /// Whether a settle that could not be made is being tried again, and how many times it has
    /// been. The wave lets go on the same main loop the settle rides on, so a settle that failed
    /// has no clock left of its own — this is that clock.
    private var repairingTail = false
    private var tailRepairs = 0
    /// The row the repair clock is trying to hand back, which is not always the row the wave last
    /// held: a turn can end and the next one start writing before a failed settle has landed.
    private var repairKey: String?
    let transcriptBox = Gtk.box(
        GTK_ORIENTATION_VERTICAL, spacing: Preferences.denseRows ? 3 : 10)
    private let pendingBox = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 8)
    private let authBanner = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
    private let statusBand = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 10)
    let bandState = StatusBand.State()
    private var agents: [SubagentSummary] = []
    private var workflowRuns: [WorkflowRun] = []
    private var usage: AgentUsage?
    /// What the whole conversation has cost. The server's own account when it keeps one, else what
    /// the transcript itself says — and never erased by a poll that came back with nothing, which
    /// is what left the chart on the one machine the session was started from.
    private var spendReading = SpendReading()
    private var spend: SessionSpend? { spendReading.value }
    /// Which branch this conversation's work is landing on, read on the same slow poll. Nil for a
    /// server that cannot read a repository, which is how the band knows to say nothing at all.
    private var git: GitState?
    private var contextEstimate: Int?
    /// What this device has written and the server has not echoed back, with what became of
    /// each. The ledger and every word it wears are Core's; this owns the clock and the sending.
    private var pending = PendingSendLedger()
    /// Prompts written while a turn was running, held here rather than handed to the server so
    /// they can still be reworded, reordered or taken back — which is the whole point of them
    /// being a queue and not a send.
    private var queue = SendQueue()
    /// Messages a spent provider window stopped, and the moment each goes again. The policy and
    /// every word are Core's; this owns the one clock that fires them and the ledger's copy on
    /// disk, so a window that opens after the app was closed is still explained rather than lost.
    var resume = ResumeLedger()
    var resumeTask: Task<Void, Never>?
    /// How many times this conversation has already been sent into the wall and bounced. A plan
    /// that fires and dies produces a *fresh* failure, and reading each fresh failure as a first
    /// attempt is how a bounded retry becomes an unbounded one — so the count lives here, beside
    /// the conversation, and only a turn that is not in a failed state clears it.
    private var resumeAttempts = 0
    /// Which waiting message the composer is rewriting. A message taken back and sent again would
    /// land at the end of the queue, which is not editing but deleting and re-adding, and it
    /// silently reorders what somebody wrote.
    private var editingQueued: UUID?
    private var pendingFirstMessage:
        (sessionID: String, send: QuickAskSend, attachments: [PendingAttachment])?
    private var notice: String?
    let editor = PromptEditor(
        css: "composer", placeholder: Localized.text("Message… (/ for commands)"))
    var entryView: UnsafeMutablePointer<GtkWidget> { editor.textView }
    private let sendButton = gtk_button_new_with_label("Send")!
    private let stopButton = gtk_button_new_with_label("⏹")!
    private var modelButton: UnsafeMutablePointer<GtkWidget>?
    private var effortButton: UnsafeMutablePointer<GtkWidget>?
    private var commandButton: UnsafeMutablePointer<GtkWidget>?
    private let destinationLabel = Gtk.label("", css: "row-detail", selectable: false)
    private(set) var transcriptScroller: UnsafeMutablePointer<GtkWidget>?
    private let helpOverlay = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
    private(set) var helpShown = false

    private let attachmentsBox = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 6)
    private var attachments: [PendingAttachment] = []
    private var pastedImageCount = 0

    private let jumpButton = gtk_button_new()!
    private(set) var unseenRows = 0
    private(set) var followsBottom = true
    private var isAutoScrolling = false
    private var isFillingInChunks = false
    private var pinCorrectorScheduled = false
    private var pendingReveal = false
    private var fillComplete = false
    /// How much of a transcript is folded into rows at all — read from the streaming task, so it
    /// is a plain value rather than anything that needs the main context.
    private nonisolated(unsafe) var rowTailMessages = 300

    private let findBar = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
    private let findEntry = gtk_search_entry_new()!
    private let findCountLabel = Gtk.label("", css: "row-detail", selectable: false)
    private var findMatches: [Int] = []
    private var findCursor = 0
    private var highlightedRow: UInt = 0
    private var canvasBox: UnsafeMutablePointer<GtkWidget>?
    private var pendingSignature = "\u{0}"
    private var compactingElapsed: UnsafeMutablePointer<GtkWidget>?
    private var compactingStartedAt: Date?

    private var attachButton: UnsafeMutablePointer<GtkWidget>?
    var composerScroller: UnsafeMutablePointer<GtkWidget> { editor.scroller }
    var vim: VimEngine { editor.vim }
    private let vimBadge = Gtk.label("", css: "vim-badge", selectable: false)
    private let earlierButton = gtk_button_new()!
    private var windowLimit = 400
    private(set) var lastFullRows: [TranscriptRow] = []
    private var lastFullCount = 0

    let context = TranscriptContext()
    let cascade = CascadePainter()
    private let rowBuilder = TranscriptRowBuilder()
    private(set) var renderedRows: [TranscriptRow] = []
    var rowWidgets: [UInt] = []
    /// Keys that have already made their entrance. A row is rebuilt whenever its value changes —
    /// a thought growing its word count, a tool call reaching its result — and fading a rebuild in
    /// from nothing is a flicker, not an arrival. Only the first sight of a key animates.
    private var enteredRows: Set<String> = []
    /// The widget each unfinished entrance is running on, by row key, so a row rebuilt mid-fade can
    /// be handed the opacity it had reached and the orphaned run can be stopped.
    private var entranceInFlight: [String: UInt] = [:]
    /// The pane's own entrance clock: the earliest moment the next row may begin fading in, in the
    /// display's monotonic seconds. Batches queue behind each other on it instead of each restarting
    /// the stagger from zero.
    private var nextEntranceAt: Double = 0
    var placeholderShown = false
    private var currentPlaceholder: String?
    private var chooser: PaneChooser?
    private var freshlyCreatedID: String?
    private var inFlightImages: Set<String> = []
    private var inFlightSubagents: Set<String> = []
    private var lastRecordedDraft = ""
    /// A press on the cut-off card this device is still waiting on an answer to.
    ///
    /// It is held here rather than folded into the record because it is this device's news and not
    /// the server's: between the press and the server's word the card must already say what was
    /// asked of it, and the moment the server's own account moves — resumed, gone, or refused and
    /// re-read — this is dropped and the card goes back to reporting only what the server said.
    private var interruptedPress: InterruptedTurnPress?

    private(set) var entry: SessionEntry?
    /// What this pane is watching instead of talking, when it is a video slot rather than a chat.
    private(set) var video: VideoPane?
    /// What this pane is reading instead of talking, when it is a browser slot rather than a chat.
    private(set) var page: WebPane?
    /// What this pane is making instead of talking, when it is the video forge rather than a chat.
    private(set) var forge: ForgePane?
    private(set) var backend: (any CodingAgentBackend)?
    private var inFlightDesignBoards: Set<String> = []
    private(set) var conversation: AgentConversation?
    private(set) var lastState: ConversationState?
    private var streamTask: Task<Void, Never>?
    private var agentStreamTask: Task<Void, Never>?
    private var agentStreamSessionID: String?
    private var tickerTask: Task<Void, Never>?
    private var turnStartedAt: Date?

    private var models: [ModelInfo] = []
    private var modelsReachable: Bool?
    private var catalogWatchTask: Task<Void, Never>?
    private var lastPillsSignature = ""
    private var lastStatusSignature = ""
    private var lastNetworkFactsAt: Date?
    private var lastGitFactsAt: Date?
    private var commands: [AgentCommand] = []
    private lazy var completion = SlashPopover(anchor: composerScroller)
    var completionMatches: [AgentCommand] { completion.matches }
    private var chosenModel: ModelSelection?
    private var chosenEffort: String?
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
        guard let state = lastState else { return entry == nil ? .unobserved : .unsettled }
        return SessionPresence.reading(state, step: bandState.facts.runningTool)
    }

    private var lastPresence: SessionPresence = .unobserved

    init(id: PaneID, host: MainWindow) {
        self.id = id
        self.host = host
        buildRoot()
        wireContext()
        cascade.onFrame = { [weak self] in self?.paintCascade() }
        cascade.onStalled = { [weak self] in self?.giveUpCascade() }
    }

    /// The vadjustment's `changed` signal fires when the content's extent moves — including while
    /// the window is unfocused and doing no other work — which is the only moment at which "stay
    /// at the bottom" can be honoured correctly. The pin must never run inside that signal: it
    /// fires during the viewport's own allocation, and a value written mid-layout is accepted but
    /// never drawn, so the pin runs on the next idle, outside layout.
    private func buildRoot() {
        Gtk.addClass(root, "canvas")
        Gtk.addClass(root, "chat-pane")
        gtk_widget_set_size_request(root, 280, -1)
        gtk_widget_set_hexpand(root, 1)
        gtk_widget_set_vexpand(root, 1)

        gtk_widget_set_visible(identityLabel, 0)
        gtk_label_set_ellipsize(op(identityLabel), PANGO_ELLIPSIZE_MIDDLE)
        gtk_box_append(ptr(root), identityLabel)

        Gtk.addClass(authBanner, "banner-auth")
        gtk_widget_set_visible(authBanner, 0)
        gtk_box_append(ptr(root), authBanner)

        gtk_box_append(ptr(root), makeFindBar())

        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(op(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        let canvas = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: Preferences.denseRows ? 4 : 10)
        Gtk.addClass(canvas, "transcript")
        canvasBox = canvas
        gtk_widget_set_visible(earlierButton, 0)
        Gtk.addClass(earlierButton, "flat")
        Gtk.addClass(earlierButton, "dim")
        Gtk.connect(UnsafeMutableRawPointer(earlierButton), "clicked") { [weak self] in
            guard let self, let state = self.lastState else { return }
            self.windowLimit += 400
            self.rowTailMessages += 600
            self.apply(state: state, rows: self.lastFullRows)
            Task { [weak self] in await self?.conversation?.reconnect() }
        }
        gtk_box_append(ptr(canvas), earlierButton)
        gtk_box_append(ptr(canvas), transcriptBox)
        Gtk.margins(pendingBox, top: 8)
        gtk_box_append(ptr(canvas), pendingBox)
        gtk_scrolled_window_set_child(op(scroller), makeTranscriptViewport(canvas))
        gtk_widget_set_vexpand(scroller, 1)
        Gtk.onPressHold(
            scroller,
            down: { [weak self] in Gtk.onMain { [weak self] in self?.pointerHeld = true } },
            up: { [weak self] in Gtk.onMain { [weak self] in self?.releasePointer() } })
        transcriptScroller = scroller

        let overlay = gtk_overlay_new()!
        gtk_overlay_set_child(op(overlay), scroller)
        gtk_widget_set_vexpand(overlay, 1)
        Gtk.addClass(jumpButton, "jump-pill")
        gtk_widget_set_halign(jumpButton, GTK_ALIGN_END)
        gtk_widget_set_valign(jumpButton, GTK_ALIGN_END)
        Gtk.margins(jumpButton, bottom: 14, trailing: 22)
        gtk_widget_set_visible(jumpButton, 0)
        Gtk.connect(UnsafeMutableRawPointer(jumpButton), "clicked") { [weak self] in
            self?.jumpToBottom()
        }
        gtk_overlay_add_overlay(op(overlay), jumpButton)
        gtk_box_append(ptr(root), overlay)

        if let adjustment = gtk_scrolled_window_get_vadjustment(op(scroller)) {
            Gtk.connect(UnsafeMutableRawPointer(adjustment), "changed") { [weak self] in
                guard let self, self.followsBottom else { return }
                self.schedulePinCorrector()
            }
            Gtk.connect(UnsafeMutableRawPointer(adjustment), "value-changed") { [weak self] in
                guard let self, !self.isAutoScrolling else { return }
                let atBottom = self.isNearBottom()
                self.followsBottom = atBottom
                if atBottom { self.clearUnseen() }
            }
        }

        gtk_widget_set_visible(helpOverlay, 0)
        Gtk.addClass(helpOverlay, "canvas")
        Gtk.margins(helpOverlay, top: 8, bottom: 8, leading: 26, trailing: 26)
        gtk_box_append(ptr(root), helpOverlay)

        Gtk.addClass(statusBand, "status-band")
        gtk_box_append(ptr(root), statusBand)
        gtk_widget_set_visible(attachmentsBox, 0)
        Gtk.margins(attachmentsBox, top: 4, leading: 26, trailing: 26)
        gtk_box_append(ptr(root), attachmentsBox)
        gtk_box_append(ptr(root), makeComposer())
        gtk_box_append(ptr(root), makePillRow())
    }

    /// Dropping files on the prompt box attaches them, which is how a file gets from a file
    /// manager into a conversation without a dialog in between. The box owns the whole width:
    /// its buttons live on the pill strip below, because a column of chrome beside the composer
    /// costs typing room all the time to serve clicks that almost never happen.
    private func makeComposer() -> UnsafeMutablePointer<GtkWidget> {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        Gtk.margins(row, top: 6, bottom: 2, leading: 26, trailing: 26)

        editor.onChanged = { [weak self] in
            self?.updateSlashCompletion()
            self?.refreshUltracodeAura()
            self?.recordDraft()
        }
        gtk_box_append(ptr(row), editor.widget)

        Gtk.acceptFileDrops(on: row) { [weak self] paths in
            self?.attach(paths: paths)
        }
        return row
    }

    /// The transcript's own search, over what the rows say rather than what the server indexes:
    /// it works offline, on a saved copy, and mid-turn.
    private func makeFindBar() -> UnsafeMutablePointer<GtkWidget> {
        Gtk.addClass(findBar, "find-bar")
        gtk_widget_set_visible(findBar, 0)
        Gtk.margins(findBar, top: 4, bottom: 4, leading: 26, trailing: 26)

        gtk_search_entry_set_placeholder_text(
            op(findEntry), Localized.text("Find in this conversation"))
        gtk_widget_set_hexpand(findEntry, 1)
        Gtk.connect(UnsafeMutableRawPointer(findEntry), "search-changed") { [weak self] in
            self?.runFind(retarget: true)
        }
        Gtk.connect(UnsafeMutableRawPointer(findEntry), "activate") { [weak self] in
            self?.stepFind(by: 1)
        }
        Gtk.connect(UnsafeMutableRawPointer(findEntry), "stop-search") { [weak self] in
            self?.setFindShown(false)
        }
        gtk_box_append(ptr(findBar), findEntry)
        gtk_box_append(ptr(findBar), findCountLabel)
        gtk_box_append(
            ptr(findBar), Gtk.button("↑", css: ["flat"]) { [weak self] in self?.stepFind(by: -1) })
        gtk_box_append(
            ptr(findBar), Gtk.button("↓", css: ["flat"]) { [weak self] in self?.stepFind(by: 1) })
        gtk_box_append(
            ptr(findBar),
            Gtk.button("✕", css: ["flat"]) { [weak self] in self?.setFindShown(false) })
        return findBar
    }

    /// The one strip under the composer: everything the old side column and button row said, at
    /// pill height — destination, model, effort, the command palette, attachments, send and
    /// stop. The CLI's status line, made clickable; send stays a visible verb, sized for what it
    /// is — a thing the keyboard does and a click may occasionally confirm.
    private func makePillRow() -> UnsafeMutablePointer<GtkWidget> {
        let row = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 8)
        Gtk.addClass(row, "pill-row")

        gtk_widget_set_visible(vimBadge, 0)
        gtk_label_set_ellipsize(op(vimBadge), PANGO_ELLIPSIZE_NONE)
        gtk_box_append(ptr(row), vimBadge)
        gtk_box_append(ptr(row), destinationLabel)

        let model = Gtk.menuButton(Localized.text("model")) { [weak self] in
            self?.modelRows() ?? []
        }
        modelButton = model
        gtk_box_append(ptr(row), model)

        let effort = Gtk.menuButton(Localized.text("effort")) { [weak self] in
            self?.effortRows() ?? []
        }
        effortButton = effort
        gtk_box_append(ptr(row), effort)

        let palette = Gtk.menuButton("/") { [weak self] in
            self?.commandRows() ?? []
        }
        commandButton = palette
        gtk_box_append(ptr(row), palette)

        let spacer = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 0)
        gtk_widget_set_hexpand(spacer, 1)
        gtk_box_append(ptr(row), spacer)

        let attach = Gtk.menuButton("📎") { [weak self] in
            self?.attachRows() ?? []
        }
        attachButton = attach
        gtk_box_append(ptr(row), attach)

        gtk_button_set_label(ptr(sendButton), Localized.text("⏎ send"))
        /// A pill whose label decides how narrow the pane may be is a pill that clips the whole
        /// transcript the moment Send becomes Queue: the longer word raised the pane's minimum
        /// past what the window could give it, and every row in it spilled over the edge for as
        /// long as a turn ran. The chrome shrinks before the conversation does.
        gtk_button_set_can_shrink(ptr(sendButton), 1)
        Gtk.addClass(sendButton, "send-pill")
        Gtk.connect(UnsafeMutableRawPointer(sendButton), "clicked") { [weak self] in
            self?.sendFromComposer()
        }
        gtk_box_append(ptr(row), sendButton)

        gtk_widget_set_visible(stopButton, 0)
        Gtk.addClass(stopButton, "stop-pill")
        Gtk.connect(UnsafeMutableRawPointer(stopButton), "clicked") { [weak self] in
            self?.stopTurn()
        }
        gtk_box_append(ptr(row), stopButton)
        return row
    }

    /// Opening or closing a row is a reading gesture: the person's eyes are on the header they
    /// clicked, so the transcript stops following the bottom — a stream that kept pinning would
    /// scroll the very card they opened out from under them — and the view moves only as far as
    /// ``revealDisclosure`` needs to show the opened body, never past the clicked header. Their
    /// own next prompt, or the jump pill, is what re-engages following.
    private func wireContext() {
        context.onToggle = { [weak self] key, open in
            Gtk.onMain { [weak self] in
                guard let self else { return }
                if open { self.context.expanded.set(key, open: true) } else {
                    self.context.expanded.set(key, open: false)
                }
                self.followsBottom = false
            }
        }
        context.revealRow = { [weak self] bits in
            if let raw = UnsafeMutableRawPointer(bitPattern: bits) { g_object_ref(raw) }
            Gtk.onMain { [weak self] in
                self?.revealDisclosure(bits)
                if let raw = UnsafeMutableRawPointer(bitPattern: bits) { g_object_unref(raw) }
            }
        }
        context.requestImage = { [weak self] reference, key in
            Gtk.onMain { [weak self] in self?.fetchImage(reference, key: key) }
        }
        context.requestSubagent = { [weak self] call in
            Gtk.onMain { [weak self] in self?.fetchSubagent(call) }
        }
        context.requestWorkflowAgent = { [weak self] agentID in
            Gtk.onMain { [weak self] in self?.fetchWorkflowAgent(agentID) }
        }
        context.openImage = { [weak self] key, name in
            Gtk.onMain { [weak self] in self?.presentImage(key: key, name: name) }
        }
        context.toast = { [weak self] text in
            Gtk.onMain { [weak self] in self?.host?.toast(text) }
        }
        context.editQueued = { [weak self] id in
            Gtk.onMain { [weak self] in self?.editQueued(id) }
        }
        context.pendingAct = { [weak self] id, act in
            Gtk.onMain { [weak self] in self?.actOnPending(id, act) }
        }
        context.resumeAct = { [weak self] id, act in
            Gtk.onMain { [weak self] in self?.actOnResume(id, act) }
        }
        context.askAgain = { [weak self] words in
            Gtk.onMain { [weak self] in self?.askAgain(words) }
        }
        context.openDesign = { [weak self] source in
            Gtk.onMain { [weak self] in self?.openDesign(source) }
        }
        context.requestDesignBoard = { [weak self] directory in
            Gtk.onMain { [weak self] in self?.readDesignBoard(directory) }
        }
        context.resumeInterrupted = { [weak self] in
            Gtk.onMain { [weak self] in self?.resumeInterruptedTurn() }
        }
        context.dismissInterrupted = { [weak self] in
            Gtk.onMain { [weak self] in self?.dismissInterruptedTurn() }
        }
        context.presentText = { [weak self] title, subtitle, body, mono in
            Gtk.onMain { [weak self] in
                Dialogs.reader(
                    title: title, subtitle: subtitle, body: body, mono: mono,
                    parent: self?.host?.windowWidget)
            }
        }
    }

    /// The strip that says whose conversation this pane is — only worth its line once a second
    /// pane exists, so a lone pane stays exactly the window it always was.
    func setIdentityVisible(_ visible: Bool) {
        gtk_widget_set_visible(identityLabel, visible ? 1 : 0)
        if visible { refreshIdentity() }
    }

    /// Turns this pane into a video slot, or points the one it already is at something else. The
    /// chat furniture is hidden rather than destroyed, so a slot is a state of a pane and not a
    /// second kind of object the split tree would have to learn.
    func showVideo(_ target: VideoTarget?) {
        chooser = nil
        if video == nil {
            let pane = VideoPane(target: target)
            video = pane
            gtk_box_append(ptr(root), pane.root)
            setChatFurnitureVisible(false)
            pane.onChange = { [weak self] in
                Gtk.onMain { [weak self] in
                    guard let self else { return }
                    self.refreshIdentity()
                    self.host?.videoSlotChanged()
                }
            }
        } else if let target {
            video?.point(at: target)
        }
        if target == nil { video?.focusPrompt() }
        refreshIdentity()
    }

    /// Turns this pane into a browser slot, or points the one it already is at another address.
    func showWeb(_ target: WebTarget?) {
        chooser = nil
        if page == nil {
            let pane = WebPane(target: target)
            page = pane
            gtk_box_append(ptr(root), pane.root)
            setChatFurnitureVisible(false)
            pane.onChange = { [weak self] in
                Gtk.onMain { [weak self] in
                    guard let self else { return }
                    self.refreshIdentity()
                    self.host?.videoSlotChanged()
                }
            }
        } else if let target {
            page?.point(at: target)
        }
        if target == nil { page?.focusPrompt() }
        refreshIdentity()
    }

    /// Turns this pane into the video forge. Like the other two slots it is a state of a pane
    /// rather than a second kind of object: the chat furniture goes out of sight, the board takes
    /// the pane, and the split tree keeps counting one pane.
    func showForge() {
        chooser = nil
        if forge == nil {
            let pane = ForgePane(parent: host?.windowWidget)
            forge = pane
            gtk_box_append(ptr(root), pane.root)
            setChatFurnitureVisible(false)
            pane.onChange = { [weak self] in
                Gtk.onMain { [weak self] in
                    guard let self else { return }
                    self.refreshIdentity()
                    self.host?.videoSlotChanged()
                }
            }
        }
        forge?.focusPrompt()
        refreshIdentity()
    }

    var isForging: Bool { forge != nil }
    var forgeSummary: String? { forge?.summary }

    /// The forge's own keys, offered in every key context. The prompt holds the keyboard while the
    /// board is up, so a board that waited for the transcript to be the focused region would never
    /// see an arrow, an Enter or a deliberate control chord.
    func handleForgeChord(_ chord: KeyChord) -> Bool {
        guard let forge else { return false }
        return forge.handleChord(chord)
    }

    /// Types into the forge's prompt from the driver, the same path a keystroke takes.
    func driveForgePrompt(_ text: String) {
        forge?.describe(text)
    }

    /// Puts the forge into one of its states without a renderer to reach it, so the states between
    /// pressing render and holding a file are provable in a build loop.
    func driveForgeState(_ name: String) {
        forge?.demonstrate(name)
    }

    var isBrowsing: Bool { page != nil }
    var webTarget: WebTarget? {
        page.flatMap { pane in pane.currentAddress.map(WebTarget.page) ?? pane.target }
    }
    var webSummary: String? { page?.summary }

    /// A browsing pane claims only the chords a browser owns; every other key belongs to the page,
    /// which is typing into a form as often as not.
    func handleWebChord(_ chord: KeyChord) -> Bool {
        guard let page else { return false }
        if page.isAsking {
            guard let command = WebCommand.command(for: chord), command != .address else {
                return false
            }
            page.handle(command)
            return true
        }
        guard let command = WebCommand.command(for: chord) else { return false }
        page.handle(command)
        return true
    }

    var isWatching: Bool { video != nil }
    var videoTarget: VideoTarget? { video?.target }
    var videoSummary: String? { video?.summary }

    /// A slot answers its own keys while it is focused; everything it does not claim goes on to
    /// the app's shortcut table, so the chat panes lose nothing to a slot in the grid.
    func handleVideoChord(_ chord: KeyChord) -> Bool {
        guard let video, !video.isAsking else { return false }
        guard let command = VideoCommand.command(for: chord) else { return false }
        video.handle(command)
        return true
    }

    /// One line of the board for the headless driver: its sections, its rows and where the cursor
    /// is, so a change to what an empty slot offers is provable without a screenshot.
    var watchBoardSummary: String? {
        guard let video, video.isAsking else { return nil }
        return video.boardSummary
    }

    /// Types into the slot's own prompt from the driver, which is how the board's search half is
    /// exercised without an input harness pushing keys at an X server.
    func driveWatchQuery(_ text: String) {
        video?.driveQuery(text)
    }

    /// The board an empty slot shows, offered its keys before the box it is typed into gets them.
    /// This one is asked in every key context rather than only in normal: the prompt has the
    /// keyboard while the board is up, so the arrows, Enter, Tab, Escape and the deliberate control
    /// chords would never arrive if the board waited for the transcript to be the focused region.
    func handleWatchChord(_ chord: KeyChord) -> Bool {
        guard let video, video.isAsking else { return false }
        return video.handleBoardChord(chord)
    }

    /// Everything the pane draws for a conversation, out of the way while it holds a stream —
    /// walked rather than named so a new piece of chat chrome cannot forget to hide itself.
    private func setChatFurnitureVisible(_ visible: Bool) {
        var child = gtk_widget_get_first_child(root)
        while let current = child {
            let next = gtk_widget_get_next_sibling(current)
            if current != identityLabel, current != video?.root, current != page?.root,
                current != forge?.root
            {
                gtk_widget_set_visible(current, visible ? 1 : 0)
            }
            child = next
        }
    }

    /// A pane wears what it is doing in its own identity strip, so a grid of four says which one
    /// is working without the reader having to find and read four status bands. The strip is what
    /// a pane is; the band is what its turn is; this is the one fact both have to agree on.
    private func refreshIdentity() {
        if let page {
            setIdentity("\(page.slot.title) · \(page.slot.subtitle)", activity: nil)
            return
        }
        if let video {
            setIdentity("\(video.slot.title) · \(video.slot.subtitle)", activity: nil)
            return
        }
        if let forge {
            setIdentity("\(forge.board.heading) · \(forge.board.job.subtitle)", activity: nil)
            return
        }
        guard let entry else {
            setIdentity(Localized.text("No conversation"), activity: nil)
            return
        }
        let title =
            entry.session.hasPlaceholderTitle
            ? Localized.text("New conversation") : entry.session.title
        let server = ServerLabel.display(name: entry.profileName, backend: entry.backendType)
        setIdentity("\(title) · \(server)", activity: identityActivity)
    }

    private func setIdentity(_ text: String, activity: ActivityKind?) {
        guard let activity else {
            ActivityPulse.apply(nil, to: identityLabel)
            gtk_label_set_text(op(identityLabel), text)
            return
        }
        let line = activity.icon.glyph + " " + text
        gtk_label_set_text(op(identityLabel), line)
        ActivityPulse.apply(activity.icon, to: identityLabel, text: line) { [identityLabel] frame in
            gtk_label_set_text(op(identityLabel), frame)
        }
    }

    /// The drive-run equivalent of clicking a picture: the gallery over every image in the
    /// conversation, on the first one. The harness reads the `GALLERY` lines it prints.
    func driverOpenGallery() {
        let items: [ImageGallery.Item] = lastFullRows.compactMap { row in
            guard case .file(let reference, _) = row.kind,
                (reference.mime ?? "").hasPrefix("image/")
            else { return nil }
            let name =
                reference.filename
                ?? reference.path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "image"
            return ImageGallery.Item(key: row.key, name: name, reference: reference)
        }
        guard let first = items.first else {
            FileHandle.standardOutput.write(Data("GALLERY none (\(lastFullRows.count) rows)\n".utf8))
            return
        }
        presentImage(key: first.key, name: first.name)
    }

    /// Opens the gallery over every picture in the conversation, landed on the one clicked.
    private func presentImage(key: String, name: String) {        let items: [ImageGallery.Item] = lastFullRows.compactMap { row in
            guard case .file(let reference, _) = row.kind,
                (reference.mime ?? "").hasPrefix("image/")
            else { return nil }
            let name =
                reference.filename
                ?? reference.path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "image"
            return ImageGallery.Item(key: row.key, name: name, reference: reference)
        }
        guard !items.isEmpty else { return }
        ImageGallery.present(
            items: items, startKey: key, parent: host?.windowWidget, context: context,
            fetch: { [weak self] reference, key in
                Gtk.onMain { [weak self] in self?.fetchImage(reference, key: key) }
            },
            notice: { [weak self] text in
                Gtk.onMain { [weak self] in self?.setNotice(text) }
            })
    }

    /// Switching chats resets per-conversation state, with deliberate exceptions and orderings —
    /// see the original single-pane implementation's reasoning: decoded textures survive,
    /// subagent transcripts do not, a freshly created session paints ready, rows fold off the
    /// main context, and the paint never waits on a statistic about it.
    ///
    /// A chat is which server as well as which session. The same bridge added twice mints two
    /// profiles and lists one server's sessions under both, so a session id alone would call the
    /// second copy the chat already open — leaving the pane naming the wrong server and writing
    /// its drafts under it.
    /// A quick ask's words arrive before the pane's conversation exists, so they wait here —
    /// keyed to the session they were minted for — and go out the moment the stream task has
    /// built that session's conversation: the same send a composer's Enter performs, echoed the
    /// same way. The key is what makes misdelivery impossible: a stream that reaches the words
    /// for any other session drops them rather than sending a question into a stranger's chat.
    func queueFirstMessage(
        _ send: QuickAskSend, attachments: [PendingAttachment] = [], forSession sessionID: String
    ) {
        pendingFirstMessage = (sessionID, send, attachments)
    }

    /// The one read of the queue, serialized through the GTK main loop because the queue is
    /// written there: whichever stream task reaches its conversation first takes the whole value,
    /// and everyone else sees nothing.
    private func takeQueuedFirstMessage() async
        -> (sessionID: String, send: QuickAskSend, attachments: [PendingAttachment])?
    {
        await withCheckedContinuation { continuation in
            Gtk.onMain { [weak self] in
                let queued = self?.pendingFirstMessage
                self?.pendingFirstMessage = nil
                continuation.resume(returning: queued)
            }
        }
    }

    /// Points the pane at another conversation, and every closure the last one left in flight is
    /// answered by the session it was started for rather than by the pane it lands in.
    ///
    /// Cancelling the stream task does not recall the work it already handed to the main loop:
    /// `Gtk.onMain` is a `g_idle_add`, and an idle that has been queued runs. So the swap of
    /// `entry` here is followed, one idle later, by the previous conversation's last state being
    /// rendered into this pane — and by that transcript being cached under the *new* session's id,
    /// which is the one thing in the pane that outlives the mistake: the wrong rows are replayed
    /// verbatim every later time that chat is opened. Every closure carrying a conversation's state
    /// across an await therefore captures the session it belongs to and drops itself if the pane
    /// has moved on.
    func open(_ entry: SessionEntry, freshlyCreated: Bool = false) {
        guard sessionID != entry.session.id || self.entry?.profileID != entry.profileID
        else { return }
        Trace.mark("open begin \(entry.session.id.prefix(8))")
        host?.stopWatching(SessionPinStore.key(entry.profileID, entry.session.id))
        let previousEntry = self.entry
        let previousConversation = self.conversation
        let previousPresence = presence
        if let previousEntry, let previousConversation, previousPresence.isInFlight {
            host?.keepWatching(previousConversation, entry: previousEntry)
        }
        chooser = nil
        freshlyCreatedID = freshlyCreated ? entry.session.id : nil
        stashDraft()
        self.entry = entry
        conversation = nil
        backend = nil
        lastState = nil
        interruptedPress = nil
        models = []
        commands = []
        chosenModel = ModelPreferenceStore.initialModel(
            sessionKey: Self.preferenceKey(entry), contextID: entry.profileID,
            sessionModel: entry.session.model,
            sessionModelProviderID: entry.session.modelProviderID)
        chosenEffort = EffortPreferenceStore.initialEffort(
            sessionKey: Self.preferenceKey(entry), contextID: entry.profileID,
            sessionEffort: entry.session.reasoningEffort)
        ultracodeInFlight = false
        refreshUltracodeAura()
        turnStartedAt = nil
        context.expanded.reset()
        context.subagentRows = [:]
        context.liveReasoning = [:]
        context.agentFacts = [:]
        context.workflowRuns = [:]
        inFlightImages = []
        inFlightSubagents = []
        attachments = []
        pastedImageCount = 0
        pending.removeAll()
        resume.removeAll()
        resumeTask?.cancel()
        resumeTask = nil
        renderAttachments()
        clearUnseen()
        ActivityInbox.clear(sessionID: entry.session.id)
        windowLimit = 400
        rowTailMessages = 300
        lastFullRows = []
        lastFullCount = 0
        lastStreamedKey = nil
        repairingTail = false
        repairKey = nil
        abandoned = nil
        followsBottom = true
        gtk_widget_set_visible(earlierButton, 0)
        if gtk_widget_get_visible(findBar) != 0 { setFindShown(false) }
        restoreDraft(for: entry)
        restoreHeldMessages()
        streamTask?.cancel()
        tickerTask?.cancel()
        tickerTask = nil
        if let remembered = host?.rememberedRows(for: entry.session.id) {
            placeholderShown = true
            lastFullRows = remembered
            lastFullCount = remembered.count
            let limit = max(windowLimit, Preferences.transcriptWindow)
            let windowed =
                remembered.count > limit ? Array(remembered.suffix(limit)) : remembered
            applyRows(windowed)
        } else if freshlyCreated {
            showPlaceholder(Localized.text("Nothing here yet. Say something."))
            gtk_widget_grab_focus(entryView)
        } else {
            showPlaceholder(Localized.text("Connecting…"))
        }
        pendingSignature = "\u{0}"
        compactingElapsed = nil
        compactingStartedAt = nil
        lastPillsSignature = ""
        lastStatusSignature = ""
        lastNetworkFactsAt = nil
        lastGitFactsAt = nil
        catalogWatchTask?.cancel()
        catalogWatchTask = nil
        Gtk.removeChildren(of: pendingBox)
        gtk_widget_set_visible(authBanner, 0)
        refreshPills()
        refreshIdentity()
        SessionSeenStore.markSeen(entry.session.id)
        agents = []
        usage = nil
        git = nil
        notice = nil
        agentStreamTask?.cancel()
        agentStreamTask = nil
        agentStreamSessionID = nil
        Trace.mark("open pane ready")
        host?.paneOpened(self)
        host?.paneRebound()
        Gtk.onMain { [weak self] in self?.host?.scheduleSidebarRender() }

        let sessionID = entry.session.id
        streamTask = Task { [weak self] in
            guard let self else { return }
            if await ServerDirectory.shared.profiles().isEmpty {
                await ServerDirectory.shared.reload()
            }
            guard
                let profile = await ServerDirectory.shared.profiles().first(where: {
                    $0.id == entry.profileID
                }), let backend = await ServerDirectory.shared.backend(for: profile)
            else {
                Gtk.onMain { [weak self] in
                    guard let self, self.sessionID == sessionID else { return }
                    self.showPlaceholder(Localized.text("That server is not configured."))
                }
                return
            }
            Gtk.onMain { [weak self] in
                guard let self, self.sessionID == sessionID else { return }
                self.backend = backend
                self.host?.workspaceSyncIfFocused(self)
            }
            self.loadSessionExtras(
                backend: backend, directory: entry.session.directory, sessionID: sessionID)
            let conversation = AgentConversation(
                backend: backend, sessionID: entry.session.id, cache: AppCache.sessionCache)
            self.conversation = conversation
            if !Task.isCancelled, let queued = await self.takeQueuedFirstMessage(),
                queued.sessionID == entry.session.id
            {
                let model = self.chosenModel
                let effort = ModelEffort.surviving(self.chosenEffort, options: self.effortOptions())
                let words = queued.send.text
                Gtk.onMain { [weak self] in
                    guard let self, self.sessionID == sessionID else { return }
                    self.pending.begin(
                        text: words,
                        userMessages: self.lastState?.messages.count { $0.role == .user } ?? 0)
                    if Ultracode.invokes(words) || effort == Ultracode.effortLevel {
                        self.ultracodeInFlight = true
                        self.refreshUltracodeAura()
                    }
                }
                switch queued.send.kind {
                case .prompt:
                    try? await conversation.send(
                        words, model: model, reasoningEffort: effort,
                        attachments: queued.attachments.map(\.prompt))
                case .command(let command, let arguments):
                    try? await conversation.run(
                        command, arguments: arguments, model: model, reasoningEffort: effort)
                }
            }
            var countedMessages = -1
            let tracing = ProcessInfo.processInfo.environment["TAILSCODE_DRIVE"] != nil
            var resubscribes = 0
            while !Task.isCancelled {
                for await state in await conversation.states() {
                    if Task.isCancelled { return }
                    if state.connection == .live { resubscribes = 0 }
                    let tail = self.rowTailMessages
                    let messages = state.messages.count > tail
                        ? Array(state.messages.suffix(tail)) : state.messages
                    let started = Date()
                    let rows = self.rowBuilder.rows(for: messages)
                    if tracing {
                        let ms = Int(Date().timeIntervalSince(started) * 1000)
                        FileHandle.standardOutput.write(
                            Data("BUILD \(messages.count) messages -> \(rows.count) rows in \(ms)ms\n".utf8))
                    }
                    Gtk.onMain { [weak self] in
                        guard let self, self.sessionID == sessionID else { return }
                        self.apply(state: state, rows: rows)
                    }
                    if state.messages.count != countedMessages {
                        countedMessages = state.messages.count
                        let estimate = StatusFacts.estimateContextTokens(state.messages)
                        Gtk.onMain { [weak self] in
                            guard let self, self.sessionID == sessionID else { return }
                            self.contextEstimate = estimate
                            self.updateStatus()
                        }
                    }
                }
                guard !Task.isCancelled else { return }
                resubscribes += 1
                let delay = min(30.0, pow(2.0, Double(min(resubscribes, 5))))
                try? await Task.sleep(for: .seconds(delay))
            }
        }
    }

    /// Empties the pane deliberately — a deleted or unresolvable session leaves an explanation,
    /// never a stale transcript that looks alive.
    ///
    /// The composer goes with the conversation. What was half-typed is stashed while it still has
    /// a scope to be stashed under, and the box is then emptied rather than left holding words it
    /// no longer has anywhere to send — a prompt that survives the chat it was for is a prompt the
    /// next Enter drops in silence.
    func reset(placeholder: String) {
        stashDraft()
        streamTask?.cancel()
        streamTask = nil
        agentStreamTask?.cancel()
        agentStreamTask = nil
        agentStreamSessionID = nil
        tickerTask?.cancel()
        tickerTask = nil
        catalogWatchTask?.cancel()
        catalogWatchTask = nil
        entry = nil
        clearComposer()
        backend = nil
        conversation = nil
        lastState = nil
        interruptedPress = nil
        lastFullRows = []
        lastFullCount = 0
        lastStreamedKey = nil
        repairingTail = false
        repairKey = nil
        abandoned = nil
        pendingSignature = "\u{0}"
        compactingElapsed = nil
        compactingStartedAt = nil
        lastPillsSignature = ""
        lastStatusSignature = ""
        lastNetworkFactsAt = nil
        lastGitFactsAt = nil
        Gtk.removeChildren(of: pendingBox)
        gtk_widget_set_visible(authBanner, 0)
        showPlaceholder(placeholder)
        refreshPills()
        refreshIdentity()
    }

    /// A closing pane stops talking to the world before its widgets go: a cancelled stream is
    /// the difference between a closed pane and a leak that keeps rendering into nothing. A turn
    /// still in flight is handed to the background watcher first, so the row keeps its LIVE NOW
    /// seat until the turn settles.
    func shutdown() {
        let previousEntry = entry
        let previousConversation = conversation
        let previousPresence = presence
        if let previousEntry, let previousConversation, previousPresence.isInFlight {
            host?.keepWatching(previousConversation, entry: previousEntry)
        }
        cascade.release()
        video?.shutdown()
        video = nil
        page?.shutdown()
        page = nil
        forge?.shutdown()
        forge = nil
        stashDraft()
        streamTask?.cancel()
        agentStreamTask?.cancel()
        tickerTask?.cancel()
        catalogWatchTask?.cancel()
        editor.stopAura()
        streamTask = nil
        agentStreamTask = nil
        tickerTask = nil
        catalogWatchTask = nil
    }

    /// Everything worth knowing about the session besides its transcript, fetched once per open:
    /// the models the server offers, the commands it resolves, and whether its Claude is signed in.
    /// The catalog is watched rather than asked once — a server asked while it restarts must not be
    /// remembered as having no models, so the ask retries and every answer re-paints the pills and
    /// an open chooser window.
    private func loadSessionExtras(
        backend: any CodingAgentBackend, directory: String?, sessionID: String
    ) {
        catalogWatchTask?.cancel()
        // Spend, agents and git are facts about the open chat — asked once the backend is known,
        // not held until a model catalog or command list happens to land. The backend pointer is
        // the one just resolved; the property may not have landed on the main context yet.
        Task { [weak self] in
            let agents = (try? await backend.subagents(for: sessionID)) ?? []
            let usage = (try? await backend.sessionUsage(sessionID)) ?? nil
            let report = (try? await backend.sessionSpend(sessionID)) ?? nil
            let repository = await Self.readGit(
                backend: backend, directory: directory, sessionID: sessionID)
            Gtk.onMain { [weak self] in
                guard let self, self.sessionID == sessionID else { return }
                self.usage = usage
                self.lastNetworkFactsAt = Date()
                self.git = repository.map { GitState(snapshot: $0) }
                self.lastGitFactsAt = Date()
                self.spendReading.note(report: report, for: sessionID)
                self.spendReading.note(
                    messages: self.lastState?.messages ?? [], for: sessionID)
                self.applyAgentFacts(agents)
            }
        }
        if let profileID = entry?.profileID {
            catalogWatchTask = Task { [weak self] in
                guard let self else { return }
                for await reading in ModelCatalogWatch.readings(
                    profileID: profileID, backend: backend)
                {
                    guard self.sessionID == sessionID else { return }
                    Gtk.onMain { [weak self] in
                        guard let self, self.sessionID == sessionID else { return }
                        self.models = reading.models
                        self.modelsReachable = reading.reachable
                        ModelChooserWindow.updateOpen(sources: self.modelSources())
                        self.refreshPills()
                    }
                }
            }
        }
        Task { [weak self] in
            let commands = (try? await backend.availableCommands(directory: directory)) ?? []
            Gtk.onMain { [weak self] in
                guard let self, self.sessionID == sessionID else { return }
                self.commands = commands
                self.refreshPills()
            }
        }
        if let authenticating = backend as? any AuthenticatingBackend {
            Task { [weak self] in
                guard let auth = try? await authenticating.authStatus() else { return }
                Gtk.onMain { [weak self] in
                    guard let self, self.sessionID == sessionID else { return }
                    self.renderAuthBanner(auth, backend: authenticating)
                }
            }
        }
    }

    private func renderAuthBanner(_ auth: ServerAuth, backend: any AuthenticatingBackend) {
        Gtk.removeChildren(of: authBanner)
        guard !auth.loggedIn else {
            gtk_widget_set_visible(authBanner, 0)
            return
        }
        let name = entry.map { ServerLabel.display(name: $0.profileName, backend: $0.backendType) } ?? "server"
        let label = Gtk.label(
            Localized.text("⚠ Claude is signed out on %@ — every turn will refuse until it signs in.", name),
            css: "banner-auth", wrap: true, selectable: false)
        gtk_widget_set_hexpand(label, 1)
        gtk_box_append(ptr(authBanner), label)
        let rootBits = host?.windowWidget.map { UInt(bitPattern: $0) } ?? 0
        gtk_box_append(
            ptr(authBanner),
            Gtk.button(Localized.text("Sign in")) { [weak self] in
                let parent = UnsafeMutableRawPointer(bitPattern: rootBits).map {
                    raw -> UnsafeMutablePointer<GtkWidget> in ptr(raw)
                }
                SignInDialog.present(
                    parent: parent, serverName: name, backend: backend
                ) { [weak self] in
                    Gtk.onMain { [weak self] in
                        guard let self else { return }
                        gtk_widget_set_visible(self.authBanner, 0)
                    }
                }
            })
        gtk_widget_set_visible(authBanner, 1)
    }

    /// The transcript renders a tail window, not the whole history; the rest waits behind one
    /// button that widens the window. The locally echoed prompt stands only until the transcript
    /// carries the same words back.
    private func apply(state: ConversationState, rows: [TranscriptRow]) {
        Trace.mark(
            "apply state loaded=\(state.hasLoadedTranscript) rows=\(rows.count) status=\(state.status)")
        lastState = state
        if let entry, spendReading.note(messages: state.messages, for: entry.session.id) {
            updateStatus()
        }
        if ultracodeInFlight, state.status != .running, state.hasLoadedTranscript {
            ultracodeInFlight = false
            refreshUltracodeAura()
        }
        if Ultracode.turnInvoked(state), !ultracodeInFlight {
            ultracodeInFlight = true
            refreshUltracodeAura()
        }
        if let entry {
            Notifier.shared.observeConversation(
                profileID: entry.profileID, sessionID: entry.session.id,
                title: MissedActivity.name(
                    title: entry.session.title,
                    latestPrompt: state.messages.last { $0.role == .user }?
                        .parts.compactMap(\.text).joined(separator: "\n")),
                state: state, windowActive: host?.windowIsActive ?? false)
        }
        // Everything this device docks at the end — the echo, the cut-off card, the queue — is
        // added on the way to the screen and then memoized in `lastFullRows`, and three callers
        // hand that memo straight back in. Taking them off first is what makes this idempotent:
        // without it a re-entrant apply appends a second copy and every consumer downstream, which
        // assumes one row per key, tears.
        var rows = rows.filter { !Self.dockedKey($0.key) }
        pending.reconcile(userMessages: state.messages.count { $0.role == .user })
        armResumeForWalledTurn(state)
        if !pending.isEmpty {
            if !rows.isEmpty {
                rows.append(TranscriptRow(key: "pending:break", kind: .turnBreak))
            }
            for send in pending.sends {
                // The key carries the phase so a send that becomes sent, or fails, is a row the
                // diff rebuilds rather than one it recognises and leaves alone. Caption aging is
                // the ticker's job — a Date in the row value rebuilt every token for nothing.
                let plan = resume.plan(for: send.id)
                rows.append(
                    TranscriptRow(
                        key: "pending:\(send.id.uuidString):\(Self.phaseKey(send))"
                            + (plan.map { ":wait\($0.attempt)" } ?? ""),
                        kind: .pendingSend(send, plan)))
            }
        }
        // A turn the machine cut off is docked at the very end: it is an account of what already
        // happened, and it belongs below everything that did.
        if let cutOff = interruptedCard(state) {
            if !rows.isEmpty {
                rows.append(TranscriptRow(key: "interrupted:break", kind: .turnBreak))
            }
            rows.append(
                TranscriptRow(
                    key: "interrupted:\(Self.cardKey(cutOff.state))",
                    kind: .interruptedTurn(cutOff)))
        }
        // What has been written and not sent sits at the very end, in the order it will go.
        for (index, waiting) in queue.items.enumerated() {
            rows.append(
                TranscriptRow(
                    key: "queued:\(waiting.id.uuidString)",
                    kind: .queuedSend(waiting, position: index + 1, of: queue.count)))
        }
        lastFullRows = rows
        refreshWorkflowRuns()
        if let sessionID { host?.rememberRows(rows, for: sessionID) }
        let appended = max(0, rows.count - lastFullCount)
        lastFullCount = rows.count
        let limit = max(windowLimit, Preferences.transcriptWindow)
        let windowed = rows.count > limit ? Array(rows.suffix(limit)) : rows
        let hiddenCount = rows.count - windowed.count
        gtk_widget_set_visible(earlierButton, hiddenCount > 0 ? 1 : 0)
        if hiddenCount > 0 {
            gtk_button_set_label(
                ptr(earlierButton),
                Localized.text("… %@ earlier rows — show more", "\(hiddenCount)"))
        }
        let placeholder: String? =
            rows.isEmpty
            ? (state.hasLoadedTranscript || sessionID == freshlyCreatedID
                ? Localized.text("Nothing here yet. Say something.") : Localized.text("Loading…"))
            : nil
        if let placeholder {
            cascade.release()
            showPlaceholder(placeholder)
        } else {
            applyRows(
                pacedByCascade(windowed, running: state.status == .running), appended: appended)
            settleStreamedTail(in: windowed)
            paintCascade()
        }
        renderPendingCards(state)
        refreshPills()
        updateStatus()
        updateTicker(running: state.status == .running || state.compaction?.isRunning == true)
        drainQueue(state)
    }

    /// The moment the turn yields, the next thing written goes. Never while one is running and
    /// never while the composer is holding one open for rewriting: sending it out from under the
    /// person editing it is the one thing the queue exists to prevent.
    private func drainQueue(_ state: ConversationState) {
        guard state.status != .running, state.compaction?.isRunning != true,
            state.lastFailure == nil, editingQueued == nil, !queue.isEmpty, let conversation
        else { return }
        guard !draining else { return }
        draining = true
        defer { draining = false }
        guard let next = queue.takeFirst() else { return }
        deliver(next, through: conversation)
        // Re-rendering from inside the render is what makes a transcript write itself twice: the
        // second pass adopts the tail the first one is still revealing. The queue is one row at the
        // end of the list, so the next ordinary state is soon enough to take it off.
        Gtk.onMain { [weak self] in
            guard let self, let state = self.lastState else { return }
            self.apply(state: state, rows: self.lastFullRows)
        }
    }

    /// Guards the drain against re-entering itself: `drainQueue` runs at the end of `apply`, and
    /// sending re-applies.
    private var draining = false

    private func deliver(
        _ send: QueuedSend, through conversation: AgentConversation, reusing row: UUID? = nil
    ) {
        let userMessages = lastState?.messages.count { $0.role == .user } ?? 0
        let id: UUID
        if let row, pending.restart(id: row, userMessages: userMessages) != nil {
            id = row
        } else {
            id = pending.begin(
                text: send.text, attachments: send.attachments, model: send.model,
                effort: send.effort, userMessages: userMessages).id
        }
        redrawPending()
        if Ultracode.invokes(send.text) || send.effort == Ultracode.effortLevel {
            ultracodeInFlight = true
            refreshUltracodeAura()
        }
        // Only prompts are ever queued here: a slash command is answered before the composer
        // reaches the queue, by the server's own grammar.
        Task { [weak self] in
            do {
                try await conversation.send(
                    send.text, model: send.model, reasoningEffort: send.effort,
                    attachments: send.attachments)
                Gtk.onMain { [weak self] in
                    guard let self, self.pending.mark(id: id, .accepted) else { return }
                    self.redrawPending()
                }
            } catch {
                // A send that never left is not a silence: the row keeps the words and says so.
                Gtk.onMain { [weak self] in
                    guard let self else { return }
                    let reason = AgentErrorText.readable(error)
                    self.pending.mark(id: id, .failed(reason: reason))
                    self.armResume(row: id, reason: reason)
                    self.redrawPending()
                }
            }
        }
    }

    /// The part of a phase that has to change for the diff to rebuild the row.
    private static func phaseKey(_ send: PendingSend) -> String {
        switch send.phase {
        case .sending: return "sending"
        case .accepted: return "accepted"
        case .failed: return "failed"
        }
    }

    /// Redraws what this device is holding without rebuilding the transcript from the server's
    /// account of the conversation — the account did not move, and walking it again to add one
    /// row of one's own is the whole reason a long conversation used to swallow a send.
    private func redrawPending() {
        guard let state = lastState else { return }
        apply(state: state, rows: lastFullRows)
    }

    private func actOnPending(_ id: UUID, _ act: PendingSend.Act) {
        guard let send = pending.send(id: id), send.isFailed else { return }
        switch act {
        case .retry:
            guard let conversation else { return }
            deliver(
                QueuedSend(
                    text: send.text, model: send.model, effort: send.effort,
                    attachments: send.attachments),
                through: conversation, reusing: id)
        case .edit:
            pending.remove(id: id)
            gtk_text_buffer_set_text(
                gtk_text_view_get_buffer(ptr(entryView)), send.text, -1)
            vim.reset(to: send.text, cursor: send.text.count, mode: .insert)
            updateVimBadge()
            gtk_widget_grab_focus(entryView)
            if !send.attachments.isEmpty {
                attachments = send.attachments.map {
                    PendingAttachment(
                        name: $0.filename ?? "attachment", mime: $0.mime, data: $0.data ?? Data())
                }
                renderAttachments()
            }
            redrawPending()
        case .discard:
            pending.remove(id: id)
            redrawPending()
        }
    }

    /// Whether this pane waits out a spent window on the person's behalf.
    private var resumeEnabled: Bool {
        Preferences.autoResume
    }

    /// The windows that stand in front of what this chat would send with — the same reading the
    /// band and the model picker use, so a wall never means one thing in one place and another
    /// somewhere else.
    private func resumeQuotas() -> [UsageQuota] {
        QuotaSurface.relevantQuotas(
            for: backend?.agentType, among: host?.quotasForStatus() ?? [])
    }

    /// A send a wall stopped is held rather than left as a failure nobody will come back to.
    /// Anything that is not a wall keeps its own sentence and never reaches this.
    private func armResume(row: UUID, reason: String) {
        guard let entry, let send = pending.send(id: row) else { return }
        let verdict = AutoResume.decide(
            row: row, profileID: entry.profileID, sessionID: entry.session.id, trigger: .refused,
            failure: reason, quotas: resumeQuotas(), model: activeModelID,
            selection: chosenModel, enabled: resumeEnabled, attempt: resumeAttempts)
        adopt(verdict, text: send.text, attachments: send.attachments, model: send.model,
            effort: send.effort)
    }

    /// A turn that reached the server, ran into the wall and produced nothing is the commonest
    /// shape of this on a Claude machine: the prompt is already in the transcript, so the words
    /// come from there rather than from a send this device happens to remember.
    private func armResumeForWalledTurn(_ state: ConversationState) {
        guard let entry, let failure = state.lastFailure else {
            resumeAttempts = 0
            return
        }
        guard !resume.plans.values.contains(where: { $0.trigger == .answerless }) else { return }
        guard let asked = state.messages.last(where: { $0.role == .user }) else { return }
        let words = asked.parts.compactMap(\.text).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        let answer = state.messages.last { $0.role == .assistant && $0.createdAt >= asked.createdAt }
        guard answer == nil || AutoResume.mayAskAgain(answer) else {
            if QuotaSurface.isQuotaFailure(failure.message) {
                setNotice(ResumeReading.obstacle(.turnHadStarted))
            }
            return
        }
        let verdict = AutoResume.decide(
            row: UUID(), profileID: entry.profileID, sessionID: entry.session.id,
            trigger: .answerless, failure: failure.message, quotas: resumeQuotas(),
            model: activeModelID, selection: chosenModel, enabled: resumeEnabled,
            attempt: resumeAttempts)
        adopt(verdict, text: words, attachments: [], model: chosenModel, effort: chosenEffort)
    }

    /// Takes a verdict and does the one thing it asks for: hold the words and start the clock, or
    /// say out loud why nothing is being waited for.
    private func adopt(
        _ verdict: ResumeVerdict, text: String, attachments: [PromptAttachment],
        model: ModelSelection?, effort: String?
    ) {
        switch verdict {
        case .notAWall:
            return
        case .cannot(let obstacle):
            setNotice(ResumeReading.obstacle(obstacle))
        case .resume(let plan):
            resume.hold(plan)
            ResumeStore.hold(
                ResumeRecord(
                    plan: plan, text: text, attachments: attachments, model: model,
                    effort: effort))
            startResumeClock()
            redrawPending()
        }
    }

    /// One clock for the whole pane. A countdown written in minutes needs nothing finer than this,
    /// and the grace this policy adds to every reset is three times the slop — so a wait measured
    /// in hours costs a quarter-minute wakeup that touches one label, rather than a per-second
    /// tick dragging the status band and its network facts along behind it.
    private func startResumeClock() {
        guard resumeTask == nil, !resume.isEmpty else { return }
        resumeTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(Self.resumeTickSeconds))
                guard !Task.isCancelled else { break }
                Gtk.onMain { [weak self] in self?.serviceResume() }
            }
        }
    }

    private static let resumeTickSeconds: TimeInterval = 15

    /// The moment a plan is due: look at the gauges rather than assume, then send, wait again, or
    /// stop and say why.
    private func serviceResume() {
        guard !resume.isEmpty else {
            resumeTask?.cancel()
            resumeTask = nil
            return
        }
        for plan in resume.stale() {
            resume.drop(plan.id)
            ResumeStore.release(plan.id)
            setNotice(ResumeReading.missed(plan))
        }
        for plan in resume.due() {
            switch AutoResume.recheck(
                plan, quotas: resumeQuotas(), model: activeModelID, selection: chosenModel,
                enabled: resumeEnabled)
            {
            case .send:
                setNotice(ResumeReading.firing(plan))
                fireResume(plan)
            case .wait(let next):
                resume.hold(next)
                ResumeStore.replan(next)
            case .cancel(let obstacle):
                resume.drop(plan.id)
                ResumeStore.release(plan.id)
                setNotice(ResumeReading.obstacle(obstacle))
            }
        }
        updatePendingCaptions()
        redrawPending()
        if resume.isEmpty {
            resumeTask?.cancel()
            resumeTask = nil
        }
    }

    /// Sends what a plan was holding, through the pane's own send so a resumed message is a
    /// message like any other rather than a second road into the backend.
    private func fireResume(_ plan: ResumePlan) {
        guard let conversation else { return }
        resumeAttempts = plan.attempt + 1
        let record = ResumeStore.release(plan.id)
        resume.drop(plan.id)
        let held = pending.send(id: plan.id)
        let text = held?.text ?? record?.text ?? ""
        guard !text.isEmpty else { return }
        let outgoing = QueuedSend(
            text: text, model: held?.model ?? record?.model,
            effort: held?.effort ?? record?.effort,
            attachments: held?.attachments ?? record?.attachments ?? [])
        if held != nil {
            deliver(outgoing, through: conversation, reusing: plan.id)
        } else {
            deliver(outgoing, through: conversation)
        }
    }

    private func actOnResume(_ id: UUID, _ act: ResumeReading.Act) {
        guard let plan = resume.plan(for: id) else { return }
        switch act {
        case .sendNow:
            fireResume(plan)
        case .edit:
            resume.drop(id)
            ResumeStore.release(id)
            actOnPending(id, .edit)
        case .stopWaiting:
            resume.drop(id)
            ResumeStore.release(id)
            setNotice(ResumeReading.stopped(plan))
            redrawPending()
        }
        if resume.isEmpty {
            resumeTask?.cancel()
            resumeTask = nil
        }
    }

    /// Picks back up what this device was holding for this conversation when it was last running.
    /// A plan whose window opened while nothing was awake is reported rather than fired.
    private func restoreHeldMessages() {
        guard let entry else { return }
        let records = ResumeStore.records(
            profileID: entry.profileID, sessionID: entry.session.id)
        guard !records.isEmpty else { return }
        let userMessages = lastState?.messages.count { $0.role == .user } ?? 0
        for record in records {
            if record.plan.isStale() {
                ResumeStore.release(record.id)
                setNotice(ResumeReading.missed(record.plan))
                continue
            }
            let restored = pending.begin(
                text: record.text, attachments: record.attachments, model: record.model,
                effort: record.effort, userMessages: userMessages, now: record.plan.plannedAt,
                id: record.id)
            pending.mark(
                id: restored.id,
                .failed(
                    reason: Localized.text(
                        "%@ %@ is used up", record.plan.provider, record.plan.window)))
            resume.hold(record.plan)
        }
        startResumeClock()
        redrawPending()
    }

    /// Opens a waiting message for rewriting. It keeps its place in the queue; only sending
    /// replaces it.
    private func editQueued(_ id: UUID) {
        guard let waiting = queue.item(id: id), !waiting.isCommand else { return }
        let pending = composerText().trimmingCharacters(in: .whitespacesAndNewlines)
        guard pending.isEmpty else {
            setNotice(Localized.text("Send or clear what is in the composer first."))
            return
        }
        editingQueued = id
        gtk_text_buffer_set_text(
            gtk_text_view_get_buffer(ptr(entryView)), waiting.text, -1)
        vim.reset(to: waiting.text, cursor: waiting.text.count, mode: .insert)
        updateVimBadge()
        gtk_widget_grab_focus(entryView)
        attachments = waiting.attachments.map {
            PendingAttachment(
                name: $0.filename ?? "attachment", mime: $0.mime, data: $0.data ?? Data())
        }
        renderAttachments()
        if let state = lastState { apply(state: state, rows: lastFullRows) }
    }

    /// ↑ in an empty composer takes back the last thing written — the one being reconsidered.
    /// Only from an empty box: in a half-typed paragraph that key is moving the caret.
    func takeBackLastQueued() -> Bool {
        guard
            SendQueueReading.upArrowTakesBack(
                composerText: composerText(), queue: queue),
            let last = queue.items.last
        else { return false }
        editQueued(last.id)
        return true
    }

    /// Whether a row is one this device docks at the end rather than one the server reported.
    private static func dockedKey(_ key: String) -> Bool {
        key.hasPrefix("echo:") || key.hasPrefix("pending:") || key.hasPrefix("queued:")
            || key.hasPrefix("interrupted")
    }

    /// An empty pane asks which server rather than captioning itself. The chooser owns the
    /// transcript area until something fills it, and every re-render keeps the person's place.
    func showChooser(_ model: PaneChooser) {
        chooser = model
        renderChooser()
    }

    var chooserShown: Bool { chooser != nil }
    var chooserServerID: String? { chooser?.serverID }

    /// A pane holding an unanswered question or a slot is not an empty pane looking for a chat:
    /// the listing may refresh under it, but nothing may fill it except the person who opened it.
    var isAnswering: Bool {
        chooser != nil || video != nil || page != nil || forge != nil
    }

    /// One line describing the chooser, for the headless driver: the question, then the rows with
    /// the cursor marked.
    var chooserSummary: String? {
        guard let chooser else { return nil }
        let rows = chooser.rows.enumerated().map { index, row in
            let badge = row.badge.map { " (\($0.text))" } ?? ""
            return "\(index == chooser.cursor ? "*" : "")\(row.title)\(badge) — \(row.detail)"
        }
        return "\(chooser.heading) [\(rows.joined(separator: " | "))]"
    }

    /// A fresh listing under an open chooser: the same question, answered with what is true now.
    func restateChooser(
        servers: [PaneChooserServer], entries: [SessionEntry], watching: WatchSummary? = nil
    ) {
        guard let current = chooser else { return }
        var next = current.restated(servers: servers, entries: entries)
        if let watching { next.watchSummary = watching }
        chooser = next
        renderChooser()
    }

    /// The chooser answers the keyboard before the shortcut table does — but only for the keys it
    /// binds, so `ctrl+w` verbs, `?` and everything else still reach the window.
    func handleChooserChord(_ chord: KeyChord) -> Bool {
        guard var model = chooser, let command = PaneChooser.command(for: chord) else {
            return false
        }
        let (handled, action) = model.handle(command)
        guard handled else { return false }
        chooser = model
        if let action {
            host?.pane(self, chose: action)
        } else {
            renderChooser()
        }
        return true
    }

    private func renderChooser() {
        guard let model = chooser else { return }
        Gtk.removeChildren(of: transcriptBox)
        forgetRowWidgets()
        placeholderShown = true
        currentPlaceholder = nil
        pendingReveal = false
        gtk_widget_set_opacity(transcriptBox, 1)
        gtk_box_append(
            ptr(transcriptBox),
            ChooserView.make(model) { [weak self] index in
                Gtk.onMain { [weak self] in self?.activateChooserRow(index) }
            })
    }

    private func activateChooserRow(_ index: Int) {
        guard var model = chooser else { return }
        host?.paneClicked(self)
        model.focus(index)
        let action = model.rows.indices.contains(index) ? model.rows[index].action : nil
        guard let action else { return }
        let outcome = model.activate(action)
        chooser = model
        if let outcome {
            host?.pane(self, chose: outcome)
        } else {
            renderChooser()
        }
    }

    func showPlaceholder(_ text: String) {
        chooser = nil
        if placeholderShown, currentPlaceholder == text { return }
        currentPlaceholder = text
        Gtk.removeChildren(of: transcriptBox)
        forgetRowWidgets()
        placeholderShown = true
        pendingReveal = false
        gtk_widget_set_opacity(transcriptBox, 1)
        let label = Gtk.label(text, css: "dim", selectable: false)
        Gtk.margins(label, top: 24, bottom: 24, leading: 4, trailing: 4)
        gtk_box_append(ptr(transcriptBox), label)
    }

    /// The rendering path, shaped around what a person is looking at: tail-first fill, chunked
    /// backfill on idle, widget reuse for every row whose identity survived, and a follow decision
    /// that is the person's, not the scrollbar's. `renderedRows` is always a contiguous slice of
    /// the applied row list that reaches its end.
    ///
    /// Every consumer of a row list here assumes each key names one row: the anchor search below
    /// takes the first key it finds, `enteredRows` is a set, and `context.expanded` is keyed by the
    /// same string. A duplicate is therefore not a cosmetic problem but a torn tail on every
    /// arrival, so a build that produces one says so where it is produced rather than being
    /// diagnosed later from the flicker.
    private func applyRows(_ rows: [TranscriptRow], appended: Int = 0) {
        assert(
            Set(rows.map(\.key)).count == rows.count,
            "transcript rows share a key: "
                + Dictionary(grouping: rows, by: \.key).filter { $0.value.count > 1 }
                    .keys.sorted().joined(separator: ", "))
        if updatedLastRowInPlace(rows) { return }
        if pointerHeld, !placeholderShown, fillComplete {
            let first = heldRows == nil
            heldRows = rows
            if first {
                Gtk.after(Self.pointerHoldCeiling) { [weak self] in
                    Gtk.onMain { [weak self] in self?.releasePointer() }
                }
            }
            return
        }
        let initialFill = placeholderShown
        if placeholderShown {
            Gtk.removeChildren(of: transcriptBox)
            forgetRowWidgets()
            placeholderShown = false
            currentPlaceholder = nil
            gtk_widget_set_opacity(transcriptBox, 0)
            pendingReveal = true
        }
        let stick = initialFill || followsBottom
        let growth = initialFill ? 0 : appended
        let chunk = 40

        var start = 0
        if !renderedRows.isEmpty {
            var indexByKey = [String: Int](minimumCapacity: rows.count)
            for (index, row) in rows.enumerated() where indexByKey[row.key] == nil {
                indexByKey[row.key] = index
            }
            var anchor: (rendered: Int, row: Int)?
            for (rendered, row) in renderedRows.enumerated() {
                if let index = indexByKey[row.key] {
                    anchor = (rendered, index)
                    break
                }
            }
            if let anchor {
                for _ in 0..<anchor.rendered { removeRowWidget(at: 0) }
                start = anchor.row
            } else {
                tearDownAllRows()
            }
        }

        if renderedRows.isEmpty {
            start = max(0, rows.count - chunk)
            appendRowWidgets(rows[start...])
        } else {
            reconcileRows(with: rows, from: start)
        }

        let tailDone = start + renderedRows.count >= rows.count
        if tailDone, start > 0 {
            let from = max(0, start - chunk)
            var previous: UnsafeMutablePointer<GtkWidget>?
            var bits: [UInt] = []
            for row in rows[from..<start] {
                let widget = row.makeWidget(context: context)
                gtk_box_insert_child_after(ptr(transcriptBox), widget, previous)
                previous = widget
                bits.append(UInt(bitPattern: widget))
            }
            renderedRows.insert(contentsOf: rows[from..<start], at: 0)
            rowWidgets.insert(contentsOf: bits, at: 0)
            enteredRows.formUnion(rows[from..<start].lazy.map(\.key))
            start = from
        }

        let complete = tailDone && start == 0
        fillComplete = complete
        if !complete {
            if stick { followsBottom = true }
            if !isFillingInChunks {
                isFillingInChunks = true
                Gtk.onMain { [weak self] in
                    guard let self else { return }
                    self.isFillingInChunks = false
                    if let state = self.lastState {
                        self.apply(state: state, rows: self.lastFullRows)
                    } else {
                        let limit = max(self.windowLimit, Preferences.transcriptWindow)
                        let rows = self.lastFullRows
                        self.applyRows(rows.count > limit ? Array(rows.suffix(limit)) : rows)
                    }
                }
            }
        }

        if stick {
            scrollToBottom()
        } else {
            noteAppendedWhileScrolledUp(growth)
        }
        if complete, gtk_widget_get_visible(findBar) != 0 { runFind(retarget: false) }
    }

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
    private var pointerHeld = false
    private var heldRows: [TranscriptRow]?
    /// A press the toolkit never finishes — a gesture claimed and then dropped without a cancel —
    /// must not stop the transcript for the rest of the turn. Long enough that no click reaches it.
    private static let pointerHoldCeiling: UInt32 = 1200

    private func releasePointer() {
        pointerHeld = false
        guard let rows = heldRows else { return }
        heldRows = nil
        applyRows(rows)
    }

    private func reconcileRows(with rows: [TranscriptRow], from start: Int) {
        let window = Array(rows[start...])
        let plan = RowDiff.plan(from: renderedRows.map(\.key), to: window.map(\.key))
        if !plan.isOrderPreserving {
            for index in plan.removals.reversed() { removeRowWidget(at: index) }
            for index in plan.insertions { insertRowWidget(window[index], at: index) }
        }
        guard renderedRows.count == window.count else {
            tearDownAllRows()
            appendRowWidgets(window[...])
            return
        }
        for index in renderedRows.indices where renderedRows[index] != window[index] {
            renderedRows[index] = window[index]
            rebuildRow(at: index)
        }
    }

    private func appendRowWidgets(_ rows: ArraySlice<TranscriptRow>) {
        for row in rows {
            let widget = row.makeWidget(context: context)
            gtk_box_append(ptr(transcriptBox), widget)
            rowWidgets.append(UInt(bitPattern: widget))
            renderedRows.append(row)
            noteEntrance(of: widget, for: row)
        }
    }

    /// A row arriving somewhere other than the end, put in the box between the neighbours it will
    /// have. The insertions are applied in ascending order, so everything before this index is
    /// already the row it should be and the widget before it is the one to insert after.
    private func insertRowWidget(_ row: TranscriptRow, at index: Int) {
        guard index <= rowWidgets.count else { return }
        let widget = row.makeWidget(context: context)
        let previous: UnsafeMutablePointer<GtkWidget>? =
            index > 0
            ? UnsafeMutableRawPointer(bitPattern: rowWidgets[index - 1]).map { ptr($0) } : nil
        gtk_box_insert_child_after(ptr(transcriptBox), widget, previous)
        rowWidgets.insert(UInt(bitPattern: widget), at: index)
        renderedRows.insert(row, at: index)
        noteEntrance(of: widget, for: row)
    }

    private func removeRowWidget(at index: Int) {
        guard index < rowWidgets.count, index < renderedRows.count else { return }
        let bits = rowWidgets[index]
        if bits == highlightedRow { clearFindHighlight() }
        if entranceInFlight[renderedRows[index].key] == bits {
            entranceInFlight[renderedRows[index].key] = nil
        }
        CascadeEntrance.cancel(bits)
        if let raw = UnsafeMutableRawPointer(bitPattern: bits) {
            gtk_box_remove(ptr(transcriptBox), ptr(raw) as UnsafeMutablePointer<GtkWidget>)
        }
        rowWidgets.remove(at: index)
        renderedRows.remove(at: index)
    }

    /// One row's widget remade where it stands, which is the whole answer to a row whose value
    /// changed and whose identity did not: it keeps its place in the box, its neighbours are not
    /// touched, and a fade it was still in the middle of is carried across rather than restarted or
    /// left running on the widget being thrown away.
    private func rebuildRow(at index: Int) {
        guard index < rowWidgets.count, index < renderedRows.count,
            let raw = UnsafeMutableRawPointer(bitPattern: rowWidgets[index])
        else { return }
        if rowWidgets[index] == highlightedRow { clearFindHighlight() }
        let key = renderedRows[index].key
        let carried = takeEntrance(of: rowWidgets[index], for: key)
        let old: UnsafeMutablePointer<GtkWidget> = ptr(raw)
        let previous: UnsafeMutablePointer<GtkWidget>? =
            index > 0
            ? UnsafeMutableRawPointer(bitPattern: rowWidgets[index - 1]).map { ptr($0) } : nil
        gtk_box_remove(ptr(transcriptBox), old)
        let widget = renderedRows[index].makeWidget(context: context)
        gtk_box_insert_child_after(ptr(transcriptBox), widget, previous)
        rowWidgets[index] = UInt(bitPattern: widget)
        if let carried { beginEntrance(of: widget, for: key, delay: 0, from: carried) }
    }

    /// Whether a row appearing on screen fades in, and when it may start.
    ///
    /// The stagger belongs to the pane rather than to the batch a row happened to arrive in. Given
    /// a position within one slice, a state carrying seven rows starts the last of them a third of
    /// a second out while the next state's first row starts immediately — so a newer row below is
    /// readable while the gap above it is still blank. Queued against one clock the batches simply
    /// follow each other, and the ceiling keeps a burst from staggering for two seconds.
    private func noteEntrance(of widget: UnsafeMutablePointer<GtkWidget>, for row: TranscriptRow) {
        let firstSight = enteredRows.insert(row.key).inserted
        guard !placeholderShown, !pendingReveal, fillComplete, followsBottom, firstSight,
            row.announcesArrival, row.key != cascade.key
        else { return }
        let now = CascadePainter.now
        let at = min(max(now, nextEntranceAt), now + StreamCascade.entranceCeiling)
        nextEntranceAt = at + StreamCascade.entranceStep
        beginEntrance(of: widget, for: row.key, delay: at - now)
    }

    private func beginEntrance(
        of widget: UnsafeMutablePointer<GtkWidget>, for key: String, delay: Double,
        from opacity: Double = 0
    ) {
        let bits = UInt(bitPattern: widget)
        entranceInFlight[key] = bits
        CascadeEntrance.animate(widget, delay: delay, from: opacity) { [weak self] in
            guard let self, self.entranceInFlight[key] == bits else { return }
            self.entranceInFlight[key] = nil
        }
    }

    /// How far into its entrance a row had got, and the end of that run. A rebuilt row's old widget
    /// has nothing left to fade in, but the fade does not know that: it goes on setting the opacity
    /// of something detached while the replacement — whose key `enteredRows` has already seen, so
    /// it does not animate — is drawn at full strength. The row pops mid-fade. Handing the opacity
    /// over instead continues the same curve on the new widget.
    private func takeEntrance(of bits: UInt, for key: String) -> Double? {
        guard entranceInFlight[key] == bits, let raw = UnsafeMutableRawPointer(bitPattern: bits)
        else { return nil }
        entranceInFlight[key] = nil
        CascadeEntrance.cancel(bits)
        return gtk_widget_get_opacity(ptr(raw) as UnsafeMutablePointer<GtkWidget>)
    }

    private func tearDownAllRows() {
        for bits in rowWidgets {
            CascadeEntrance.cancel(bits)
            guard let raw = UnsafeMutableRawPointer(bitPattern: bits) else { continue }
            gtk_box_remove(ptr(transcriptBox), ptr(raw) as UnsafeMutablePointer<GtkWidget>)
        }
        forgetRowWidgets()
    }

    /// Drops everything the pane believes about the widgets it had, for the paths that empty the
    /// transcript box wholesale. The entrance clock goes with them: a queue built up for rows that
    /// no longer exist would delay the first row of whatever fills the pane next.
    ///
    /// This is the single answer to "the pane no longer has these rows", so every ledger keyed by a
    /// row key is emptied here rather than by the caller that happened to notice. `enteredRows` is
    /// the one that matters: its keys are `messageID:partID`, unique per session, so a pane that
    /// only ever cleared it on the teardown path grew the set for the life of the window — a chat
    /// switch reaches `showPlaceholder` or the placeholder branch of `applyRows`, and neither of
    /// those tears rows down, because the box was already emptied.
    private func forgetRowWidgets() {
        renderedRows = []
        rowWidgets = []
        highlightedRow = 0
        enteredRows.removeAll(keepingCapacity: true)
        entranceInFlight.removeAll(keepingCapacity: true)
        nextEntranceAt = 0
    }

    /// A streamed token changes exactly one row, and rebuilding its widget for every arrival is
    /// what makes a live answer flicker: the label is torn down and remade dozens of times a
    /// second, which restarts its entrance, drops any selection inside it, and asks the whole
    /// column to lay out again. When the only difference is more words in a row that can take them
    /// where it stands — the answer the painter is holding, or a thought counting itself up — the
    /// change is written into the widget and the bookkeeping moves with it.
    private func updatedLastRowInPlace(_ rows: [TranscriptRow]) -> Bool {
        guard !placeholderShown, fillComplete,
            renderedRows.count == rows.count, let last = rows.indices.last, last > 0,
            renderedRows[last].key == rows[last].key, renderedRows[last] != rows[last],
            last < rowWidgets.count,
            let raw = UnsafeMutableRawPointer(bitPattern: rowWidgets[last]),
            renderedRows.dropLast().elementsEqual(rows.dropLast())
        else { return false }
        let widget: UnsafeMutablePointer<GtkWidget> = ptr(raw)
        switch (renderedRows[last].kind, rows[last].kind) {
        case (.agentProse, .agentProse), (.codeBlock, .codeBlock):
            guard rows[last].key == cascade.key else { return false }
            let previous = renderedRows[last]
            renderedRows[last] = rows[last]
            guard paintCascade() else {
                renderedRows[last] = previous
                return false
            }
            return true
        case (.reasoning, .reasoning(let text)):
            guard TranscriptRow.restateReasoning(
                widget, text: text, key: rows[last].key, context: context)
            else { return false }
        default:
            return false
        }
        renderedRows[last] = rows[last]
        if followsBottom { scrollToBottom() }
        return true
    }



    /// A row that stopped being written ends up whole, whatever the wave was doing when it let go.
    ///
    /// Settling is normally the release path's job, but that path can only settle the row the
    /// painter still holds: a key that changed as the message completed, a widget rebuilt between
    /// frames, a turn that ended in the same update its last words arrived in, or a painter that
    /// declined the row all leave it holding nothing. So the pane remembers the row the wave last
    /// had its hands on and hands it back the first state where the wave is no longer on it —
    /// which is any state at all, not only one that says the turn is over. A stream that simply
    /// stops sending never says that, and the reveal is a prefix painted into the row's own label:
    /// the rows are equal by then, so the diff sees nothing to do and nothing else would ever put
    /// the rest of the sentence back.
    ///
    /// The row is let go of only once it has actually been handed back. A settle can find nothing
    /// to write into — the row is mid-chunk, its widget was rebuilt between frames, the pane is
    /// showing a placeholder — and forgetting the key on the way in turns one missed repair into a
    /// permanent one: nothing else in the pane knows that widget is holding a prefix. Keeping it
    /// costs a string and retries on the next state, which is where the widget usually is by then.
    private func settleStreamedTail(in rows: [TranscriptRow]) {
        guard let key = lastStreamedKey, key != cascade.key else { return }
        if settleCascade(on: key, in: rows) || !lastFullRows.contains(where: { $0.key == key }) {
            lastStreamedKey = nil
            return
        }
        scheduleTailRepair(on: key)
    }

    /// A settle that could not be made, tried again on a clock of its own.
    ///
    /// Every other road back to a whole row runs through a state arriving: the diff, the release
    /// path, the tail settle. A turn that has just ended sends no more states, and the wave let go
    /// of its frame clock and its watchdog in the same breath — so a settle that failed at exactly
    /// that moment is the last thing anybody was ever going to try, and the row keeps the prefix
    /// for as long as the chat is open. This is the clock nothing else can take down.
    ///
    /// It gives up on being polite before it gives up on the reader: three refusals and the row's
    /// bookkeeping is thrown away so the ordinary diff has to build it again from the words the
    /// pane actually holds, which is slower, loses a selection inside that one row, and is still
    /// enormously better than a paragraph that stops mid-sentence.
    func scheduleTailRepair(on key: String) {
        repairKey = key
        guard !repairingTail else { return }
        repairingTail = true
        tailRepairs = 0
        repairStreamedTail()
    }

    private func repairStreamedTail() {
        Gtk.after(320) { [weak self] in
            guard let self, self.repairingTail else { return }
            guard let key = self.repairKey, key != self.cascade.key else {
                self.repairingTail = false
                self.repairKey = nil
                return
            }
            if self.settleCascade(on: key, in: self.lastFullRows) {
                if self.lastStreamedKey == key { self.lastStreamedKey = nil }
                self.repairingTail = false
                self.repairKey = nil
                return
            }
            self.tailRepairs += 1
            guard self.tailRepairs >= 3 else {
                self.repairStreamedTail()
                return
            }
            self.repairingTail = false
            self.repairKey = nil
            if self.lastStreamedKey == key { self.lastStreamedKey = nil }
            self.rebuildStreamedTail(from: key)
        }
    }

    /// Forgets everything the pane believes about the row the wave was painting and the rows after
    /// it, so the next fill cannot compare them equal and skip them. The words are the pane's own,
    /// so nothing is refetched — only redrawn.
    private func rebuildStreamedTail(from key: String) {
        guard !placeholderShown, let index = renderedRows.lastIndex(where: { $0.key == key }),
            index < rowWidgets.count
        else { return }
        while renderedRows.count > index { removeRowWidget(at: renderedRows.count - 1) }
        let limit = max(windowLimit, Preferences.transcriptWindow)
        let rows = lastFullRows
        applyRows(rows.count > limit ? Array(rows.suffix(limit)) : rows)
    }

    /// The reveal stopped moving while it still owed the reader text — the frame clock died under
    /// it, or the words stopped arriving. Either way the hand is not coming back, so the row is
    /// given up and shown whole rather than left mid-sentence.
    ///
    /// Given up means for good, for as long as that row is the one being written: taking it back
    /// on the next arrival would start its reveal again from nothing, and an answer that snapped
    /// to whole and then rewound would be a worse lie than the stall.
    private func giveUpCascade() {
        if reopenGatedCascade() { return }
        let key = cascade.key ?? lastStreamedKey
        cascade.release()
        abandoned = key
        lastStreamedKey = key
        guard let key else { return }
        if settleCascade(on: key, in: lastFullRows) {
            lastStreamedKey = nil
        } else {
            scheduleTailRepair(on: key)
        }
    }

    /// The wave letting go of a row is not the same as the row being rebuilt. A turn that simply
    /// ends leaves the rows identical, so the diff has nothing to do and the last glyphs would keep
    /// the heat of a stream that stopped — the row has to be handed back whole by hand.
    ///
    /// Whole means the row's own words, which is what the pane last received and never what the
    /// pacer handed the widget: the paced copy is cut at the last position where no markdown token
    /// is half-open, and settling from it would bake that cut into the finished answer. Returns
    /// whether the row is now whole, so a repair that could not be made is not mistaken for one
    /// that was.
    @discardableResult
    func settleCascade(on key: String, in rows: [TranscriptRow]) -> Bool {
        guard let index = renderedRows.lastIndex(where: { $0.key == key }),
            index < rowWidgets.count,
            let raw = UnsafeMutableRawPointer(bitPattern: rowWidgets[index]),
            let label = Self.streamedLabel(in: ptr(raw), kind: renderedRows[index].kind)
        else { return false }
        let row =
            lastFullRows.last(where: { $0.key == key })
            ?? rows.last(where: { $0.key == key })
            ?? renderedRows[index]
        guard let markup = Self.settleMarkup(for: row) else { return false }
        return cascade.settle(label, markup: markup)
    }

    /// What the shim should parse for this row while the wave is on it. Prose already carries its
    /// markup; a code block is its own body, escaped, so the one reveal path serves both.
    ///
    /// The painter parses markup with Pango's own parser, and Pango has no anchor of its own —
    /// GtkLabel resolves `<a href>` before Pango ever sees it. So a link is dressed as the span
    /// the label would have made of it: same ink, same underline, no semantics. A frame needs none.
    /// Prose that carries no link is handed back exactly as it came, because the dressing below
    /// rewrites a string the size of the whole answer and most answers have nothing in them to
    /// rewrite. Returning the markup itself costs nothing at all; building an identical copy of it
    /// costs the answer, every time somebody asks.
    static func cascadeMarkup(for row: TranscriptRow) -> String? {
        switch row.kind {
        case .agentProse(_, let markup):
            guard markup.contains("<a href=\"") else { return markup }
            let accent = MatrixTheme.palette.accent
            var text = markup.replacingOccurrences(of: "</a>", with: "</span>")
            while let open = text.range(of: "<a href=\""),
                let close = text[open.upperBound...].range(of: "\">")
            {
                text.replaceSubrange(
                    open.lowerBound..<close.upperBound,
                    with: "<span foreground=\"\(accent)\" underline=\"single\">")
            }
            return text
        case .codeBlock(_, let body):
            return PangoMarkdown.escape(body)
        default:
            return nil
        }
    }

    /// What a row is handed back whole with. Settling writes through `gtk_label_set_markup`, which
    /// is GtkLabel's own road — the one that turns `<a href>` into a link a click can follow. The
    /// painter's dressed markup must never reach it: a span carries the link's ink but not its
    /// address, so a row settled in what the frames were painted with would spend the rest of the
    /// chat looking touchable and doing nothing. The undressed markup is the row's own, exactly
    /// what a rebuild would have set; a code block still rides escaped, as it always did.
    static func settleMarkup(for row: TranscriptRow) -> String? {
        switch row.kind {
        case .agentProse(_, let markup): return markup
        case .codeBlock(_, let body): return PangoMarkdown.escape(body)
        default: return nil
        }
    }

    /// Where a live row keeps the words: prose is the label, a code block keeps its body under the
    /// header and behind a scroller once it is tall enough to need one.
    static func streamedLabel(
        in widget: UnsafeMutablePointer<GtkWidget>, kind: TranscriptRow.Kind
    ) -> UnsafeMutablePointer<GtkWidget>? {
        func isA(_ candidate: UnsafeMutablePointer<GtkWidget>, _ type: GType) -> Bool {
            let instance = UnsafeMutableRawPointer(candidate).assumingMemoryBound(
                to: GTypeInstance.self)
            return g_type_check_instance_is_a(instance, type) != 0
        }
        switch kind {
        case .agentProse:
            return isA(widget, gtk_label_get_type()) ? widget : nil
        case .codeBlock:
            guard let last = gtk_widget_get_last_child(widget) else { return nil }
            if isA(last, gtk_label_get_type()) { return last }
            guard isA(last, gtk_scrolled_window_get_type()),
                let child = gtk_scrolled_window_get_child(op(last)),
                isA(child, gtk_label_get_type())
            else { return nil }
            return child
        default:
            return nil
        }
    }

    /// A cache arrival (a decoded picture, a fetched subagent transcript) redraws exactly the rows
    /// it belongs to, in place. It is not new content — the unseen counter never moves.
    private func replaceRows(where predicate: (TranscriptRow) -> Bool) {
        guard !placeholderShown else { return }
        for index in renderedRows.indices where predicate(renderedRows[index]) {
            rebuildRow(at: index)
        }
    }

    /// What the turn is waiting on, docked where the CLI's prompt would sit: approvals first,
    /// then questions. Rebuilt only when what is pending actually changes.
    private func renderPendingCards(_ state: ConversationState) {
        let compactionKey = state.compaction.map {
            $0.failure ?? "compacting:\($0.startedAt.timeIntervalSince1970):\(pending.hasInFlight)"
        } ?? ""
        let signature = (state.pendingPermissions.map(\.id) + state.pendingQuestions.map(\.id))
            .joined(separator: "|") + "|" + compactionKey
        guard signature != pendingSignature else { return }
        pendingSignature = signature
        compactingElapsed = nil
        compactingStartedAt = nil
        Gtk.removeChildren(of: pendingBox)
        for permission in state.pendingPermissions {
            gtk_box_append(
                ptr(pendingBox),
                PendingCards.permission(permission) { [weak self] decision in
                    self?.respond(to: permission, decision: decision)
                })
        }
        for question in state.pendingQuestions {
            gtk_box_append(
                ptr(pendingBox),
                PendingCards.question(question, in: entry) { [weak self] answers in
                    self?.answer(question, answers: answers)
                })
        }
        if let compaction = state.compaction {
            if let failure = compaction.failure {
                gtk_box_append(ptr(pendingBox), PendingCards.compactionFailure(failure))
            } else {
                compactingStartedAt = compaction.startedAt
                gtk_box_append(
                    ptr(pendingBox),
                    PendingCards.compacting(
                        startedAt: compaction.startedAt, waiting: pending.hasInFlight
                    ) { [weak self] label in
                        self?.compactingElapsed = label
                    })
            }
        }
    }

    /// The running card's own clock line, moved by the pane's one-second ticker rather than a
    /// rebuild — the card must hold still while its wait counts up.
    private func updateCompactingElapsed() {
        guard let label = compactingElapsed, let startedAt = compactingStartedAt else { return }
        gtk_label_set_text(op(label), CompactionStory.elapsedLine(startedAt: startedAt))
    }

    func respond(to permission: PermissionRequest, decision: PermissionDecision) {
        guard let conversation else { return }
        Task { try? await conversation.respond(to: permission, decision: decision) }
    }

    func respondToFirstPermission(_ decision: PermissionDecision) {
        guard let permission = lastState?.pendingPermissions.first else { return }
        respond(to: permission, decision: decision)
    }

    /// Claude answers by message, so the answer goes out through the ordinary send path — a
    /// bridge busy with a live turn refuses a side-channel call but queues a message.
    private func answer(_ question: QuestionRequest, answers: [[String]]) {
        guard let conversation else { return }
        let byMessage = backend?.capabilities.answersQuestionsByMessage == true
        Task {
            if byMessage {
                await conversation.markAnswered(question)
                try? await conversation.send(question.answerMessage(answers))
            } else {
                try? await conversation.answer(question, answers: answers)
            }
        }
    }

    /// The band above the prompt box: what the turn is doing, which agents are out, how much of
    /// the context is spent, what the goal is — every fact clickable. Segment text is the gate —
    /// streaming fires many applies a second and the band already paints in place, so an identical
    /// reading is not walked again.
    private func updateStatus() {
        guard let state = lastState else { return }
        let running = state.status == .running || state.compaction?.isRunning == true
        if running {
            if turnStartedAt == nil { turnStartedAt = Date() }
        } else {
            turnStartedAt = nil
        }
        let quotas = host?.quotasForStatus() ?? []
        let facts = StatusFacts.from(
            state: state, turnStartedAt: turnStartedAt, agents: agents, usage: usage,
            attachments: attachments.count, contextTokens: contextEstimate, quotas: quotas,
            spend: spend, git: git, model: activeModelID)
        if identityActivity != facts.activity {
            identityActivity = facts.activity
            refreshIdentity()
        }
        let bandNotice = quotaNotice(state: state, quotas: quotas) ?? notice
        let signature =
            facts.segments.map { "\($0.id):\($0.text):\($0.css)" }.joined(separator: "|")
            + "|\(bandNotice ?? "")|\(running)|\(facts.activity.map { String(describing: $0) } ?? "")"
        if signature != lastStatusSignature {
            lastStatusSignature = signature
            StatusBand.render(into: statusBand, state: bandState, facts: facts, notice: bandNotice)
            {
                [weak self] action in
                Gtk.onMain { [weak self] in self?.perform(bandAction: action) }
            }
        }
        gtk_button_set_label(
            ptr(sendButton), running ? Localized.text("⏎ queue") : Localized.text("⏎ send"))
        gtk_widget_set_visible(stopButton, running ? 1 : 0)
        notePresenceChange()
    }

    /// Tells the window when what this pane is watching has actually changed, which is what puts
    /// the conversation being talked in into LIVE NOW without waiting for the server's sweep. Only
    /// a change is reported: a running turn applies state many times a second, and rebuilding two
    /// hundred sidebar rows per lump is the stutter the list spent a rewrite removing.
    private func notePresenceChange() {
        let now = presence
        guard now != lastPresence else { return }
        lastPresence = now
        Gtk.onMain { [weak self] in self?.host?.scheduleSidebarRender() }
    }

    /// Pre-emptive used-up quota on the band while idle — a failed turn already carries the
    /// rewritten phase, so this only speaks when the wall is up before the next send. Only the
    /// chat's own provider family speaks here, and only the wall standing in front of the model
    /// this chat would send with; every other wall is worn where a model is picked.
    private func quotaNotice(state: ConversationState, quotas: [UsageQuota]) -> String? {
        if let waiting = resume.plans.values.filter({ !$0.isStale() })
            .min(by: { $0.resumesAt < $1.resumesAt })
        {
            return ResumeReading.short(waiting)
        }
        guard state.lastFailure == nil, state.status != .running else { return nil }
        let relevant = QuotaSurface.relevantQuotas(for: backend?.agentType, among: quotas)
        return QuotaSurface.hottestExhausted(
            in: QuotaSurface.billingQuotas(
                in: relevant, selection: chosenModel, model: activeModelID),
            model: activeModelID
        )
        .map(QuotaSurface.short)
    }

    /// The used-up windows on this server's account, for marking a model spent where it is picked.
    private func modelQuotas() -> [UsageQuota] {
        QuotaSurface.relevantQuotas(
            for: backend?.agentType, among: host?.quotasForStatus() ?? [])
    }

    private func perform(bandAction action: StatusFacts.Action) {
        switch action {
        case .stop: stopTurn()
        case .compact: host?.presentCompactPreflight(for: self)
        case .goal: insertIntoComposer("/goal ")
        case .scrollToPending: scroll(toEnd: true)
        case .scrollToAgents: scrollToNewestAgent()
        case .agent(let id): scrollToAgent(id)
        case .git:
            guard let git, let backend, let entry else { return }
            let directory = entry.session.directory
            let sessionID = entry.session.id
            GitPanel.present(
                parent: host?.windowWidget, state: git,
                title: entry.session.title,
                patch: { row in
                    guard let observer = backend as? any GitObservingBackend else { return nil }
                    return try? await observer.gitPatch(
                        directory: directory, sessionID: sessionID, path: row.path,
                        staged: row.staged)?.patch
                },
                commit: { commit in
                    guard let observer = backend as? any GitObservingBackend else { return nil }
                    return try? await observer.gitCommit(
                        directory: directory, sessionID: sessionID, hash: commit.hash)?.patch
                })
        case .spend:
            guard let spend else { return }
            SpendPanel.present(
                parent: host?.windowWidget, spend: spend,
                title: entry.map { $0.session.title } ?? Localized.text("This conversation"))
        case .reconnect:
            guard let conversation else { return }
            Task { await conversation.reconnect() }
        }
    }

    /// The card for one named agent — matched to the tool call that spawned it — and its
    /// transcript opened on arrival.
    private func scrollToAgent(_ id: String) {
        for (index, row) in renderedRows.enumerated() {
            guard case .subagent(let call) = row.kind, call.id == id else { continue }
            context.expanded.set(row.key, open: true)
            replaceRows { $0.key == row.key }
            fetchSubagent(call)
            scrollToRow(at: index)
            return
        }
        scrollToNewestAgent()
    }

    private func scrollToRow(at index: Int) {
        guard index < rowWidgets.count,
            let raw = UnsafeMutableRawPointer(bitPattern: rowWidgets[index])
        else { return }
        let widget: UnsafeMutablePointer<GtkWidget> = ptr(raw)
        let offset = tailscode_widget_offset_y(widget, canvasBox ?? transcriptBox)
        guard offset >= 0, let scroller = transcriptScroller,
            let adjustment = gtk_scrolled_window_get_vadjustment(op(scroller))
        else { return }
        followsBottom = false
        let page = gtk_adjustment_get_page_size(adjustment)
        gtk_adjustment_set_value(
            adjustment,
            min(max(0, offset - page * 0.3), max(0, gtk_adjustment_get_upper(adjustment) - page)))
    }

    private func scrollToNewestAgent() {
        for (index, row) in renderedRows.enumerated().reversed() {
            guard case .subagent = row.kind, index < rowWidgets.count,
                let raw = UnsafeMutableRawPointer(bitPattern: rowWidgets[index])
            else { continue }
            let widget: UnsafeMutablePointer<GtkWidget> = ptr(raw)
            let offset = tailscode_widget_offset_y(widget, canvasBox ?? transcriptBox)
            guard offset >= 0, let scroller = transcriptScroller,
                let adjustment = gtk_scrolled_window_get_vadjustment(op(scroller))
            else { return }
            let page = gtk_adjustment_get_page_size(adjustment)
            gtk_adjustment_set_value(
                adjustment,
                min(max(0, offset - page * 0.3), max(0, gtk_adjustment_get_upper(adjustment) - page)))
            return
        }
        scroll(toEnd: true)
    }

    /// A notice is transient — the last thing the app did on this pane's behalf — and it lives at
    /// the far end of the band so it never pushes a live fact off it.
    func setNotice(_ text: String) {
        notice = text
        updateStatus()
    }

    /// A proto-2 bridge pushes each fan-out's live facts as they change; older servers are
    /// polled. Started lazily on the first turn tick after a chat opens.
    private func startAgentStreamIfAvailable() {
        guard agentStreamSessionID != sessionID else { return }
        guard let backend, let entry else { return }
        agentStreamSessionID = entry.session.id
        let sessionID = entry.session.id
        agentStreamTask?.cancel()
        agentStreamTask = Task { [weak self] in
            guard let streaming = backend as? SubagentStreaming,
                let changes = await streaming.subagentChanges(for: sessionID)
            else {
                Gtk.onMain { [weak self] in self?.agentStreamSessionID = nil }
                return
            }
            for await agents in changes {
                Gtk.onMain { [weak self] in
                    guard let self, self.sessionID == sessionID else { return }
                    self.applyAgentFacts(agents)
                }
            }
        }
    }

    private func applyAgentFacts(_ agents: [SubagentSummary]) {
        self.agents = agents
        var facts: [String: SubagentSummary] = [:]
        for agent in agents {
            if let toolUseID = agent.toolUseID { facts[toolUseID] = agent }
        }
        let changed = facts.keys.filter { context.agentFacts[$0] != facts[$0] }
        let vanished = context.agentFacts.keys.filter { facts[$0] == nil }
        context.agentFacts = facts
        let stale = Set(changed + vanished)
        if !stale.isEmpty {
            replaceRows {
                if case .subagent(let call) = $0.kind { return stale.contains(call.id) }
                return false
            }
        }
        refreshWorkflowRuns()
        updateStatus()
    }

    /// Subagents and cost are polled rather than streamed: the bridge reports both on request
    /// only, and a fan-out is worth watching while it runs. Git porcelain is the expensive half
    /// and moves on its own slower clock — a live workflow does not need a repo re-read every few
    /// seconds to keep its elapsed reading honest.
    private func refreshTurnFacts(includeGit: Bool = true) {
        guard let backend, let entry else { return }
        startAgentStreamIfAvailable()
        let sessionID = entry.session.id
        let skipAgents = agentStreamSessionID == sessionID && agentStreamTask != nil
        let wantGit = includeGit
        Task { [weak self] in
            let agents = skipAgents ? nil : ((try? await backend.subagents(for: sessionID)) ?? [])
            let usage = (try? await backend.sessionUsage(sessionID)) ?? nil
            let report = (try? await backend.sessionSpend(sessionID)) ?? nil
            let repository =
                wantGit ? await Self.readGit(backend: backend, session: entry.session) : nil
            Gtk.onMain { [weak self] in
                guard let self, self.sessionID == sessionID else { return }
                self.usage = usage
                self.lastNetworkFactsAt = Date()
                if wantGit {
                    self.git = repository.map { GitState(snapshot: $0) }
                    self.lastGitFactsAt = Date()
                }
                self.spendReading.note(report: report, for: sessionID)
                self.spendReading.note(
                    messages: self.lastState?.messages ?? [], for: sessionID)
                if let agents {
                    self.applyAgentFacts(agents)
                } else {
                    self.updateStatus()
                }
            }
        }
    }

    /// The repository the conversation is working in, when the server can read one. A backend
    /// without the routes, or a directory outside version control, answers nil and the band simply
    /// has one fewer fact — never an error about a repository nobody asked for.
    private static func readGit(backend: any CodingAgentBackend, session: AgentSession) async
        -> GitSnapshot?
    {
        await readGit(backend: backend, directory: session.directory, sessionID: session.id)
    }

    private static func readGit(
        backend: any CodingAgentBackend, directory: String?, sessionID: String
    ) async -> GitSnapshot? {
        guard let observer = backend as? any GitObservingBackend else { return nil }
        let snapshot = try? await observer.gitSnapshot(
            directory: directory, sessionID: sessionID)
        return (snapshot?.repo == true) ? snapshot : nil
    }

    /// A once-a-second nudge while anything on screen still needs a clock: elapsed, pending
    /// captions, workflow spinners. Network facts and git ride slower cadences so a multi-pane
    /// window does not re-read porcelain six times a minute per chat.
    private func updateTicker(running: Bool) {
        let running = running || needsTicker
        if running, tickerTask == nil {
            lastNetworkFactsAt = nil
            lastGitFactsAt = nil
            refreshTurnFacts(includeGit: true)
            tickerTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    Gtk.onMain { [weak self] in
                        guard let self else { return }
                        self.updateStatus()
                        self.updateCompactingElapsed()
                        self.updatePendingCaptions()
                        self.advanceWorkflowClock()
                        self.tickTurnFacts()
                    }
                }
            }
        } else if !running {
            if tickerTask != nil {
                tickerTask?.cancel()
                tickerTask = nil
                refreshTurnFacts(includeGit: true)
            }
        }
    }

    private static let networkFactsInterval: TimeInterval = 15
    private static let gitFactsInterval: TimeInterval = 60

    private func tickTurnFacts() {
        guard needsTicker else { return }
        let now = Date()
        let networkDue =
            lastNetworkFactsAt.map { now.timeIntervalSince($0) >= Self.networkFactsInterval }
            ?? true
        let gitDue =
            lastGitFactsAt.map { now.timeIntervalSince($0) >= Self.gitFactsInterval } ?? true
        guard networkDue || gitDue else { return }
        refreshTurnFacts(includeGit: gitDue)
    }

    /// Ages every pending-send caption that is still on screen. Phase changes rebuild the row;
    /// the wait itself must not.
    private func updatePendingCaptions() {
        guard !pending.isEmpty || !resume.isEmpty else { return }
        let now = Date()
        for index in renderedRows.indices {
            guard case .pendingSend = renderedRows[index].kind, index < rowWidgets.count,
                let raw = UnsafeMutableRawPointer(bitPattern: rowWidgets[index])
            else { continue }
            TranscriptRow.agePendingCaption(on: ptr(raw), now: now)
        }
    }

    func refreshPills() {
        let destination = [
            entry.map { ServerLabel.display(name: $0.profileName, backend: $0.backendType) },
            entry?.session.directory.map { URL(fileURLWithPath: $0).lastPathComponent },
        ].compactMap { $0 }.joined(separator: " · ")
        let model = modelPillText()
        let effort = effortPillText() ?? ""
        let tint = modelTintClass() ?? ""
        let effortTint = effortPillText().flatMap(ModelTint.effortClass) ?? ""
        let signature =
            "\(destination)|\(model)|\(effort)|\(tint)|\(effortTint)|\(abilities.attachments)"
        guard signature != lastPillsSignature else {
            dropUnsendableAttachments()
            return
        }
        lastPillsSignature = signature
        gtk_label_set_text(op(destinationLabel), destination)

        if let modelButton {
            gtk_menu_button_set_label(op(modelButton), model)
            applyTintClass(to: modelButton, from: modelTintClasses, chosen: modelTintClass())
        }
        if let effortButton {
            let word = effortPillText()
            gtk_widget_set_visible(effortButton, word == nil ? 0 : 1)
            gtk_menu_button_set_label(op(effortButton), word ?? "")
            applyTintClass(
                to: effortButton, from: effortTintClasses, chosen: word.flatMap(ModelTint.effortClass))
        }
        if let attachButton {
            gtk_widget_set_visible(attachButton, abilities.attachments ? 1 : 0)
        }
        dropUnsendableAttachments()
    }

    /// A model switch is the one way something already picked becomes unsendable. It is dropped
    /// out loud rather than left to fail on the other machine, and never silently: a picture that
    /// vanishes from a composer with no word is the app losing work.
    private func dropUnsendableAttachments() {
        let able = abilities
        let refused = attachments.filter { !able.accepts(mime: $0.mime) }
        guard !refused.isEmpty else { return }
        attachments.removeAll { attachment in refused.contains { $0.id == attachment.id } }
        renderAttachments()
        setNotice(ModelAbilities.dropped(refused.count))
    }

    /// The composer's two pills wear the same colours the list chips do — the family's hue on the
    /// model, the tier's heat on the effort — swapped as one class out of the set, so a change of
    /// model repaints the pill it already has.
    private func applyTintClass(
        to button: UnsafeMutablePointer<GtkWidget>, from all: [String], chosen: String?
    ) {
        for cls in all where cls != chosen { gtk_widget_remove_css_class(button, cls) }
        if let chosen { gtk_widget_add_css_class(button, chosen) }
    }

    private var modelTintClasses: [String] {
        ModelTint.Family.allCases.map(ModelTint.cssClass) + (0..<12).map { "model-hue-\($0)" }
            + ["model-plain"]
    }

    private var effortTintClasses: [String] {
        ModelTint.effortTiers.map { "effort-\($0)" } + ["effort-ultracode"]
    }

    private func modelTintClass() -> String? {
        guard let active = activeModelID, let chip = ModelBadge.chip(model: active, effort: nil)
        else { return nil }
        return ModelTint.identityClass(family: chip.family, name: chip.name)
    }

    /// What the chat is actually being answered by: the explicit pick, else the model observed on
    /// the last assistant turn, else the session's own record.
    var activeModelID: String? {
        chosenModel?.modelID ?? observedModelID() ?? entry?.session.model
    }

    private func modelPillText() -> String {
        if let chosenModel { return ModelBadge.label(model: chosenModel, effort: nil) }
        if let observed = observedModelID() {
            return ModelBadge.label(model: ModelSelection(providerID: "server", modelID: observed), effort: nil)
        }
        if let stored = entry?.session.model {
            return ModelBadge.label(model: ModelSelection(providerID: "server", modelID: stored), effort: nil)
        }
        return Localized.text("model")
    }

    private func observedModelID() -> String? {
        guard let messages = lastState?.messages else { return nil }
        for message in messages.reversed() where message.role == .assistant {
            if let id = message.modelID, !id.isEmpty { return id }
        }
        return nil
    }

    /// What the effort pill says, or nil where the model takes no effort at all — a pill reading
    /// "no effort control" spent a permanent slot in the chrome explaining the absence of a control
    /// nobody asked for, and on a catalog where most models have no levels it was the usual state.
    private func effortPillText() -> String? {
        let options = effortOptions()
        guard !options.isEmpty else { return nil }
        if let kept = ModelEffort.surviving(chosenEffort, options: options) { return kept }
        if let stored = ModelEffort.surviving(entry?.session.reasoningEffort, options: options) {
            return stored
        }
        if let observed = ModelEffort.surviving(observedEffort(), options: options) {
            return observed
        }
        return ModelEffort.label(nil, options: options)
    }

    private func observedEffort() -> String? {
        guard let messages = lastState?.messages else { return nil }
        for message in messages.reversed() where message.role == .assistant {
            if let effort = message.reasoningEffort, !effort.isEmpty { return effort }
        }
        return nil
    }

    /// Effort is a property of the model on servers whose catalog says so; the backend-wide list
    /// is the fallback for agents where every model takes the same levels. The rule is Core's, so
    /// what this offers and what the phone offers for the same model can never differ.
    private func effortOptions() -> [String] {
        ModelEffort.options(
            models: models,
            selection: chosenModel
                ?? activeModelID.map { ModelSelection(providerID: "server", modelID: $0) },
            agentOptions: backend?.reasoningEffortOptions ?? [])
    }

    /// What the picked model can be handed. A capability is the model's far more often than the
    /// server's — one opencode machine fronts a hundred, and half of them cannot see a picture.
    private var abilities: ModelAbilities {
        ModelAbilities.resolve(
            supportsAttachments: backend?.capabilities.supportsAttachments != false,
            models: models,
            selection: chosenModel
                ?? activeModelID.map { ModelSelection(providerID: "server", modelID: $0) })
    }

    /// The pill offers what this person actually works with — the shared shortlist — and hands the
    /// rest to the chooser, which is the only surface that can hold a catalog of two hundred and
    /// still be read. The two are the same list at two lengths.
    private func modelRows() -> [(String, String?, @Sendable () -> Void)] {
        guard !models.isEmpty else {
            return [(Localized.text("This server lists no models"), nil, {})]
        }
        var rows: [(String, String?, @Sendable () -> Void)] = [
            (Localized.text("Server default"), nil, { [weak self] in
                Gtk.onMain { [weak self] in
                    self?.setChosenModel(nil)
                }
            })
        ]
        let quotas = modelQuotas()
        for candidate in ModelChooser.shortlist(models, selected: chosenModel) {
            let selection = candidate.selection
            let providers = candidate.providerNames.joined(separator: " · ")
            let wall = ModelChooser.wall(for: candidate, quotas: quotas)
            rows.append(
                (candidate.name,
                 wall.map { "\(QuotaSurface.rowNote($0)) · \(providers)" } ?? providers,
                 { [weak self] in
                    Gtk.onMain { [weak self] in
                        self?.setChosenModel(selection)
                    }
                }))
        }
        rows.append(
            (Localized.text("All models…"),
             ModelChooser(models: models, selected: chosenModel, quotas: quotas).summary,
             { [weak self] in
                Gtk.onMain { [weak self] in self?.openModelChooser() }
             }))
        return rows
    }

    private func openModelChooser() {
        ModelChooserWindow.present(
            sources: modelSources(), selected: chosenModel,
            parent: host?.windowWidget ?? root, quotas: modelQuotas()
        ) { [weak self] pick in
            Gtk.onMain { [weak self] in self?.apply(pick) }
        }
    }

    /// Every server this app is connected to, with this pane's own at the front. A catalog is a
    /// fact about a machine, so the list can name what the other machine runs without this pane
    /// ever having talked to it — and whether this one answered its last ask, so a restart reads
    /// as a state rather than a machine with no models.
    private func modelSources() -> [ModelSource] {
        let profiles = host?.fleetProfiles() ?? []
        var reachability: [String: Bool] = [:]
        if let profileID = entry?.profileID, let reachable = modelsReachable {
            reachability[profileID] = reachable
        }
        let sources = ModelFleet.sources(
            profiles: profiles, current: entry?.profileID, currentModels: models,
            reachability: reachability)
        guard sources.isEmpty else { return sources }
        return [
            ModelSource(
                profileID: entry?.profileID ?? "", name: "", backend: backend?.agentType ?? .openCode,
                models: models, isCurrent: true, allowsServerDefault: true,
                acceptsAnyModelID: backend?.agentType == .claudeCode,
                isReachable: modelsReachable)
        ]
    }

    /// A model on this machine changes what this chat runs. A model on another one cannot: the
    /// conversation is a process on the machine that answers it, so the pick is remembered as that
    /// server's own choice and the pane opens a new chat there.
    private func apply(_ pick: ModelPick) {
        guard pick.isElsewhere else {
            setChosenModel(pick.selection)
            return
        }
        ModelFleet.adopt(pick)
        host?.startChat(on: pick.profileID, into: self)
    }

    private func setChosenModel(_ selection: ModelSelection?) {
        chosenModel = selection
        if let entry {
            ModelPreferenceStore.recordPick(
                selection, sessionKey: Self.preferenceKey(entry), contextID: entry.profileID)
        }
        let kept = ModelEffort.adopt(
            chosenEffort, for: selection, models: models,
            agentOptions: backend?.reasoningEffortOptions ?? [])
        if kept != chosenEffort {
            setChosenEffort(kept)
            return
        }
        if let entry {
            SettingsFile.capture()
        }
        refreshPills()
    }

    private func effortRows() -> [(String, String?, @Sendable () -> Void)] {
        let options = effortOptions()
        guard !options.isEmpty else {
            return [(Localized.text("This model has no effort control"), nil, {})]
        }
        var rows: [(String, String?, @Sendable () -> Void)] = [
            (Localized.text("Server default"), nil, { [weak self] in
                Gtk.onMain { [weak self] in
                    self?.setChosenEffort(nil)
                }
            })
        ]
        for option in options {
            let isPower = option == Ultracode.effortLevel
            rows.append(
                (isPower ? "\(option) ✦" : option,
                 isPower ? Ultracode.menuSubtitle : nil,
                 { [weak self] in
                     Gtk.onMain { [weak self] in
                         self?.setChosenEffort(option)
                     }
                 }))
        }
        return rows
    }

    private func setChosenEffort(_ level: String?) {
        chosenEffort = level
        if let entry {
            EffortPreferenceStore.recordPick(
                level, sessionKey: Self.preferenceKey(entry), contextID: entry.profileID)
            SettingsFile.capture()
        }
        refreshPills()
        refreshUltracodeAura()
    }

    private static func preferenceKey(_ entry: SessionEntry) -> String {
        "\(entry.profileID)/\(entry.session.id)"
    }

    private func refreshUltracodeAura() {
        let was = editor.auraActive
        editor.setAura(effort: chosenEffort, inFlight: ultracodeInFlight)
        if editor.auraActive != was { host?.refreshOrb() }
    }

    /// On the server first — what this machine will actually resolve — then what the app itself
    /// can do. Picking one drops it into the composer so arguments can follow.
    private func commandRows() -> [(String, String?, @Sendable () -> Void)] {
        var rows: [(String, String?, @Sendable () -> Void)] = []
        rows.append(
            ("/compact", Localized.text("Trade the transcript for a summary — with a preflight"),
             { [weak self] in Gtk.onMain { [weak self] in
                 guard let self else { return }
                 self.host?.presentCompactPreflight(for: self)
             } }))
        rows.append(
            ("/goal", Localized.text("Set a standing goal the agent pursues"),
             { [weak self] in Gtk.onMain { [weak self] in self?.insertIntoComposer("/goal ") } }))
        if supportsDesign {
            rows.append(
                ("/design", CommandCatalogStore.designCommand.details,
                 { [weak self] in Gtk.onMain { [weak self] in
                     guard let self else { return }
                     self.host?.presentDesignPreflight(for: self, request: "")
                 } }))
        }
        for command in commands
        where command.name != "compact" && command.name != "goal"
            && !(supportsDesign && command.name == SlashDispatch.designWord)
        {
            let insertion = command.takesArguments ? "/\(command.name) " : "/\(command.name)"
            rows.append(
                ("/\(command.name)", command.details.isEmpty ? command.source.rawValue : command.details,
                 { [weak self] in Gtk.onMain { [weak self] in self?.insertIntoComposer(insertion) } }))
        }
        return rows
    }

    func actionRows() -> [(String, String?, @Sendable () -> Void)] {
        guard let entry else { return [] }
        let capabilities = backend?.capabilities
        var rows: [(String, String?, @Sendable () -> Void)] = []

        let saved = SavedChatStore.contains(entry)
        rows.append(
            (saved ? Localized.text("Unsave") : Localized.text("Save"),
             Localized.text("A saved chat lists itself even when its server is unreachable"),
             { [weak self] in Gtk.onMain { [weak self] in self?.host?.toggleSaved(entry) } }))

        if capabilities?.supportsRenaming == true, let backend {
            rows.append(
                (Localized.text("Rename…"), nil,
                 { [weak self] in Gtk.onMain { [weak self] in
                     self?.host?.presentRename(entry: entry, backend: backend)
                 } }))
        }
        if capabilities?.supportsForking == true, let backend {
            rows.append(
                (Localized.text("Fork"),
                 Localized.text("A new session with this history, for a different direction"),
                 { [weak self] in Gtk.onMain { [weak self] in
                     self?.host?.fork(entry: entry, backend: backend)
                 } }))
        }
        if capabilities?.supportsCompaction == true {
            rows.append(
                (Localized.text("Compact…"),
                 Localized.text("Irreversible, takes minutes"),
                 { [weak self] in Gtk.onMain { [weak self] in
                     guard let self else { return }
                     self.host?.presentCompactPreflight(for: self)
                 } }))
        }
        if !commands.isEmpty {
            rows.append(
                (Localized.text("All commands…"),
                 Localized.text("Browse every command this server offers"),
                 { [weak self] in Gtk.onMain { [weak self] in self?.presentCommandCatalog() } }))
        }
        if capabilities?.supportsClearing == true, let backend {
            rows.append(
                (Localized.text("Clear…"), Localized.text("Empty the conversation in place"),
                 { [weak self] in Gtk.onMain { [weak self] in
                     self?.host?.presentClear(entry: entry, backend: backend)
                 } }))
        }
        if let backend {
            rows.append(
                (Localized.text("Delete…"), Localized.text("Remove the session from its server"),
                 { [weak self] in Gtk.onMain { [weak self] in
                     self?.host?.presentDelete(entry: entry, backend: backend)
                 } }))
        }
        return rows
    }

    /// Alongside the badge, the caret itself says which mode this is: it blinks only in insert.
    func updateVimBadge() {
        editor.refreshMode()
        guard Preferences.vimComposer else {
            gtk_widget_set_visible(vimBadge, 0)
            return
        }
        gtk_widget_set_visible(vimBadge, 1)
        gtk_label_set_text(op(vimBadge), vim.mode.label)
        gtk_widget_remove_css_class(vimBadge, "vim-badge-visual")
        gtk_widget_remove_css_class(vimBadge, "vim-badge-insert")
        switch vim.mode {
        case .insert: Gtk.addClass(vimBadge, "vim-badge-insert")
        case .visual, .visualLine: Gtk.addClass(vimBadge, "vim-badge-visual")
        case .normal: break
        }
    }

    func composerHasFocus() -> Bool {
        guard let window = host?.windowWidget, let focused = tailscode_focused_widget(window)
        else { return false }
        return focused == entryView
    }

    /// The prompt box's own key handling: vim first when it is on, then Return-to-send. `nil`
    /// means this pane's composer does not have focus and the window should keep looking.
    func handleComposerKey(keyval: UInt32, state: UInt32) -> Bool? {
        guard composerHasFocus() else { return nil }
        let control = state & Keymap.control != 0
        let shift = state & Keymap.shift != 0

        if completionShown {
            switch keyval {
            case Keymap.tab:
                if let command = completion.selected { acceptSlashCommand(command) }
                return true
            case Keymap.shiftTab: completion.move(by: -1); return true
            case Keymap.down: completion.move(by: 1); return true
            case Keymap.up: completion.move(by: -1); return true
            case Keymap.escape: completion.dismiss(); return true
            default:
                if control, Keymap.scalar(keyval) == "n" { completion.move(by: 1); return true }
                if control, Keymap.scalar(keyval) == "p" { completion.move(by: -1); return true }
            }
        }

        if Preferences.vimComposer {
            let key = VimKey(
                character: Keymap.scalar(keyval),
                isEscape: keyval == Keymap.escape,
                isEnter: keyval == Keymap.enter || keyval == Keymap.keypadEnter,
                isBackspace: keyval == 0xFF08,
                control: control)
            if vim.mode == .insert, key.isEscape || (control && Keymap.scalar(keyval) == "[") {
                applyVim(vim.handle(VimKey(isEscape: true), text: composerText(), cursor: composerCursor()))
                return true
            }
            if vim.mode != .insert {
                return composerNormalKey(key, keyval: keyval, state: state)
            }
        }

        if control, !shift, Keymap.scalar(keyval) == "v" {
            pasteIntoComposer()
            return true
        }

        // ↑ in an empty box takes the last thing written back for rewriting. Only from an empty
        // box: in a half-typed paragraph that key is moving the caret, and taking it would be the
        // worse bug by far.
        if keyval == Keymap.up || keyval == 0xFF97, !control, !shift, takeBackLastQueued() {
            return true
        }

        let isReturn = keyval == Keymap.enter || keyval == Keymap.keypadEnter
        if isReturn, !shift, Preferences.sendOnReturn || control {
            sendFromComposer()
            return true
        }
        if isReturn, shift || !Preferences.sendOnReturn { return false }
        return nil
    }

    /// The composer's normal mode is the app's normal mode: every key answers to the shortcut
    /// table first while vim keeps what makes it vim — and a chord sequence in flight outranks
    /// both, so `ctrl+w v` splits rather than entering visual mode. A key neither side binds goes
    /// back to vim rather than to the text view, so no stray letter types itself into the draft.
    private func composerNormalKey(
        _ key: VimKey, keyval: UInt32, state: UInt32
    ) -> Bool? {
        guard let host else { return nil }
        if key.control, Keymap.scalar(keyval) == "c", copyComposerSelection() { return true }
        guard let chord = KeyChord.canonical(keyval: keyval, state: state) else { return nil }
        let awaiting = !(lastState?.pendingPermissions.isEmpty ?? true)
        if awaiting, !chord.control, !chord.alt, host.pendingChords.isEmpty,
            let action = host.shortcuts.approval[chord.token]
        {
            host.pendingChords = []
            return host.perform(action)
        }
        if key.isEnter, chord.control {
            host.pendingChords = []
            sendFromComposer()
            return true
        }
        let plain = !chord.control && !chord.alt
        if vim.claims(key, plain: plain, chordPending: !host.pendingChords.isEmpty) {
            host.pendingChords = []
            applyVim(vim.handle(key, text: composerText(), cursor: composerCursor()))
            return true
        }
        let resolution = host.shortcuts.resolve(
            chord, context: .normal, pending: host.pendingChords, awaitingApproval: false)
        switch resolution {
        case .run(let action):
            host.pendingChords = []
            return host.perform(action)
        case .pending(let chords):
            host.pendingChords = chords
            return true
        case .unbound:
            host.pendingChords = []
            applyVim(vim.handle(key, text: composerText(), cursor: composerCursor()))
            return true
        }
    }

    private func copyComposerSelection() -> Bool {
        let buffer = gtk_text_view_get_buffer(ptr(entryView))
        var start = GtkTextIter()
        var end = GtkTextIter()
        guard gtk_text_buffer_get_selection_bounds(buffer, &start, &end) != 0,
            let raw = gtk_text_buffer_get_text(buffer, &start, &end, 0)
        else { return false }
        Gtk.copyToClipboard(String(cString: raw))
        g_free(raw)
        host?.toast(Localized.text("Copied"))
        return true
    }

    private func applyVim(_ outcome: VimOutcome) {
        switch outcome {
        case .passThrough, .handled:
            if case .handled = outcome { editor.write(vim.document, selection: vim.selection) }
        case .send:
            sendFromComposer()
        }
        updateVimBadge()
    }

    private func composerCursor() -> Int { editor.cursor }

    func stopTurn() {
        guard let conversation else { return }
        Task { try? await conversation.cancelCurrentTurn() }
    }

    private func isNearBottom() -> Bool {
        guard let scroller = transcriptScroller,
            let adjustment = gtk_scrolled_window_get_vadjustment(op(scroller))
        else { return true }
        let value = gtk_adjustment_get_value(adjustment)
        let ceiling = gtk_adjustment_get_upper(adjustment)
            - gtk_adjustment_get_page_size(adjustment)
        return value >= ceiling - 60
    }

    /// Following is a decision, not a measurement: the intent is held here and re-applied
    /// whenever the extent actually changes, focused or not.
    private func setFollowing(_ following: Bool) {
        followsBottom = following
        if following { pinToBottom() }
    }

    private func pinToBottom() {
        guard let scroller = transcriptScroller,
            let adjustment = gtk_scrolled_window_get_vadjustment(op(scroller))
        else { return }
        let target = max(
            gtk_adjustment_get_lower(adjustment),
            gtk_adjustment_get_upper(adjustment) - gtk_adjustment_get_page_size(adjustment))
        guard abs(gtk_adjustment_get_value(adjustment) - target) > 0.5 else { return }
        isAutoScrolling = true
        gtk_adjustment_set_value(adjustment, target)
        isAutoScrolling = false
    }

    func scrollToBottom() {
        setFollowing(true)
        schedulePinCorrector()
    }

    /// Runs outside layout, after the current pass has settled: pins, then queues an allocation
    /// on the viewport, so the pixels always match the adjustment. Also the moment a
    /// freshly-filled transcript is revealed.
    private func schedulePinCorrector() {
        guard !pinCorrectorScheduled else { return }
        pinCorrectorScheduled = true
        Gtk.onMain { [weak self] in
            guard let self else { return }
            self.pinCorrectorScheduled = false
            if self.followsBottom { self.pinToBottom() }
            if let scroller = self.transcriptScroller {
                gtk_widget_queue_allocate(scroller)
                if let viewport = gtk_widget_get_first_child(scroller) {
                    gtk_widget_queue_allocate(viewport)
                }
            }
            if self.pendingReveal, self.fillComplete {
                self.pendingReveal = false
                gtk_widget_set_opacity(self.transcriptBox, 1)
            }
        }
    }

    /// The gentlest scroll that shows a just-opened body: down only as far as the body's end (or
    /// the page can hold), and never past the point where the clicked header would leave the top —
    /// a header that flies off the screen is the person losing the very thing they pointed at.
    /// Runs on the idle after the open, once the body has its allocation; a row already rebuilt or
    /// torn off screen by then simply fails the bounds check and moves nothing.
    private func revealDisclosure(_ bits: UInt) {
        guard let raw = UnsafeMutableRawPointer(bitPattern: bits),
            let canvas = canvasBox, let scroller = transcriptScroller,
            let adjustment = gtk_scrolled_window_get_vadjustment(op(scroller))
        else { return }
        var x = 0.0
        var y = 0.0
        var width = 0.0
        var height = 0.0
        guard tailscode_widget_bounds_in(ptr(raw), canvas, &x, &y, &width, &height) != 0,
            height > 0
        else { return }
        let value = gtk_adjustment_get_value(adjustment)
        let page = gtk_adjustment_get_page_size(adjustment)
        guard page > 0 else { return }
        let margin = 8.0
        let needed = y + height + margin - (value + page)
        let slack = y - margin - value
        let delta = min(needed, slack)
        guard delta > 0 else { return }
        let ceiling = max(0, gtk_adjustment_get_upper(adjustment) - page)
        isAutoScrolling = true
        gtk_adjustment_set_value(adjustment, min(value + delta, ceiling))
        isAutoScrolling = false
    }

    func scroll(by amount: Double) {
        adjust { $0 + amount }
    }

    func scroll(byPages fraction: Double) {
        guard let scroller = transcriptScroller,
            let adjustment = gtk_scrolled_window_get_vadjustment(op(scroller))
        else { return }
        let page = gtk_adjustment_get_page_size(adjustment) * fraction
        adjust { $0 + page }
    }

    func scroll(toEnd bottom: Bool) {
        guard let scroller = transcriptScroller,
            let adjustment = gtk_scrolled_window_get_vadjustment(op(scroller))
        else { return }
        let limit =
            bottom
            ? gtk_adjustment_get_upper(adjustment) - gtk_adjustment_get_page_size(adjustment)
            : gtk_adjustment_get_lower(adjustment)
        adjust { _ in limit }
    }

    private func adjust(_ transform: (Double) -> Double) {
        guard let scroller = transcriptScroller,
            let adjustment = gtk_scrolled_window_get_vadjustment(op(scroller))
        else { return }
        let ceiling = gtk_adjustment_get_upper(adjustment)
            - gtk_adjustment_get_page_size(adjustment)
        let next = min(max(gtk_adjustment_get_lower(adjustment),
            transform(gtk_adjustment_get_value(adjustment))), max(0, ceiling))
        gtk_adjustment_set_value(adjustment, next)
    }

    /// Typing `/word` offers what it could become, right above the prompt box, through the same
    /// popover the quick ask paints — one list, so neither composer can learn something the other
    /// does not.
    var completionShown: Bool { completion.isShown }

    private func updateSlashCompletion() {
        let typing = !Preferences.vimComposer || vim.mode == .insert
        guard typing else {
            completion.dismiss()
            return
        }
        completion.hasProject = entry?.session.directory?.isEmpty == false
        let offered = composerCommands
        completion.catalogSize = offered.count
        completion.renderCompletion(
            SlashPresentation.of(
                text: composerText(), commands: offered,
                recents: SlashRecents.surviving(in: offered)),
            cursor: completion.cursor)
    }

    private func acceptSlashCommand(_ command: AgentCommand) {
        SlashRecents.record(command.name)
        let text = command.takesArguments ? "/\(command.name) " : "/\(command.name)"
        let buffer = gtk_text_view_get_buffer(ptr(entryView))
        gtk_text_buffer_set_text(buffer, text, -1)
        var end = GtkTextIter()
        gtk_text_buffer_get_end_iter(buffer, &end)
        gtk_text_buffer_place_cursor(buffer, &end)
        vim.reset(to: text, cursor: text.count, mode: .insert)
        updateVimBadge()
        gtk_widget_grab_focus(entryView)
        if !command.takesArguments { updateSlashCompletion() }
    }

    func dismissCompletion() {
        completion.dismiss()
    }

    /// The greppable catalog surface for Linux — every command this server offers.
    func presentCommandCatalog() {
        dismissCompletion()
        CommandCatalog.present(parent: root, commands: composerCommands) { [weak self] command in
            Gtk.onMain { [weak self] in self?.acceptSlashCommand(command) }
        }
    }

    /// A paste is an attach as much as a paste, so the composer takes the clipboard rather than
    /// letting the text widget take it: files and pictures become chips where they would otherwise
    /// have to be saved to disk and picked back up, and only words go in as words. What this model
    /// cannot be handed is refused by name in the notice line rather than dropped.
    private func pasteIntoComposer() {
        let able = abilities
        let named = pastedImageCount
        Gtk.readClipboard { offer in
            Gtk.onMain { [weak self] in
                guard let self else { return }
                let plan = PasteIntake.plan(for: offer, abilities: able, alreadyNamed: named)
                self.pastedImageCount = plan.named
                if let text = plan.text, !text.isEmpty { self.insertAtCaret(text) }
                if !plan.attachments.isEmpty {
                    self.attachments.append(contentsOf: plan.attachments)
                    self.renderAttachments()
                }
                if let notice = plan.notices.first { self.setNotice(notice) }
            }
        }
    }

    /// Where a paste actually lands, which is at the caret and never at the end: the composer is a
    /// document a person moves around in, and vim's shadow of it has to be told what was written
    /// or the next normal-mode key would edit a string that no longer exists.
    private func insertAtCaret(_ text: String) {
        editor.insertAtCaret(text)
    }

    func insertIntoComposer(_ text: String) {
        editor.insertAtEnd(text)
    }

    func composerText() -> String { editor.text }

    /// Empties the prompt box and the vim document that shadows it, without touching any stored
    /// draft: called where the pane has already let go of the conversation the text belonged to.
    private func clearComposer() {
        editor.clear()
        lastRecordedDraft = ""
        updateVimBadge()
    }

    /// What is in the composer right now, recorded as it is typed. The store is built to be told
    /// on every keystroke, so nothing here throttles it a second time.
    private func recordDraft() {
        guard let draftScope else { return }
        let text = composerText()
        lastRecordedDraft = text
        DraftStore.record(text, for: draftScope)
    }

    /// Half-typed prompts follow their conversation, not the pane: switching chats stashes what
    /// was in the composer and restores whatever was stashed for the chat being opened. Called
    /// where the pane is about to stop being asked, so the write happens now rather than on the
    /// next quiet moment that may never come.
    ///
    /// Two panes can hold the same chat, and a scope is the conversation's rather than the pane's,
    /// so a pane that has not been typed into since it last recorded has nothing to say about that
    /// draft: it writes only when its own buffer has moved, and the pane still being typed into
    /// keeps the text. The flush is unconditional — someone else's newer edit is still owed a disk.
    func stashDraft() {
        if composerText() != lastRecordedDraft { recordDraft() }
        DraftStore.flush()
    }

    private func restoreDraft(for entry: SessionEntry) {
        let draft = DraftStore.text(
            for: .chat(profileID: entry.profileID, sessionID: entry.session.id))
        gtk_text_buffer_set_text(gtk_text_view_get_buffer(ptr(entryView)), draft, -1)
        lastRecordedDraft = draft
        vim.reset(to: draft, cursor: draft.count, mode: .insert)
        updateVimBadge()
    }

    /// The prompt is on screen before the server has heard of it: a busy bridge can take seconds
    /// to answer, and a composer that empties into silence reads as a hang.
    func sendFromComposer() {
        let text = composerText().trimmingCharacters(in: .whitespacesAndNewlines)
        let outgoing = attachments
        // Emptying the box is how a message being rewritten is taken back, so a send with nothing
        // in it is a real action while one is open — and nothing at all otherwise.
        guard !text.isEmpty || !outgoing.isEmpty || editingQueued != nil, let conversation
        else { return }
        let buffer = gtk_text_view_get_buffer(ptr(entryView))
        gtk_text_buffer_set_text(buffer, "", 0)
        if let draftScope { DraftStore.clear(draftScope) }
        vim.reset(to: "", cursor: 0, mode: .insert)
        updateVimBadge()
        if let id = editingQueued {
            editingQueued = nil
            if let draftScope { DraftStore.clear(draftScope) }
            attachments = []
            renderAttachments()
            _ = queue.replace(id: id, text: text, attachments: outgoing.map(\.prompt))
            if let state = lastState { apply(state: state, rows: lastFullRows) }
            return
        }
        if handleSlashCommand(text) { return }
        attachments = []
        renderAttachments()
        let send = QueuedSend(
            text: text, model: chosenModel,
            effort: ModelEffort.surviving(chosenEffort, options: effortOptions()),
            attachments: outgoing.map(\.prompt))
        // A prompt written while a turn runs is held here, not handed over: a message you can
        // still change is worth more than a message one place further along.
        guard lastState?.status != .running, lastState?.compaction?.isRunning != true else {
            queue.append(send)
            if let state = lastState { apply(state: state, rows: lastFullRows) }
            scrollToBottom()
            return
        }
        if let state = lastState { apply(state: state, rows: lastFullRows) }
        scrollToBottom()
        deliver(send, through: conversation)
        refreshUltracodeAura()
    }

    /// The words of a turn that said nothing, asked again. They go through the composer rather
    /// than straight to the backend so the retry is the same send as any other — echoed, drafted,
    /// and refused for the same reasons — and anything half-typed is kept rather than replaced.
    private func askAgain(_ words: String) {
        guard !words.isEmpty else { return }
        let pending = composerText().trimmingCharacters(in: .whitespacesAndNewlines)
        guard pending.isEmpty else {
            setNotice(Localized.text("Send or clear what is in the composer first."))
            return
        }
        gtk_text_buffer_set_text(gtk_text_view_get_buffer(ptr(entryView)), words, -1)
        sendFromComposer()
    }

    /// A prompt the app composed rather than the person typed — a design brief, a follow-up on an
    /// artboard — sent through the same composer for the same reasons: it is echoed, drafted and
    /// refused exactly like the words somebody types, and nothing half-written is thrown away.
    func sendComposed(_ words: String) {
        askAgain(words)
    }

    /// Whether a board could be read back at all. The brief is only worth spending a turn on where
    /// this server can hand files over — otherwise the mocks would be written somewhere no client
    /// could ever open them.
    var supportsDesign: Bool { backend?.capabilities.supportsFileBrowsing == true }

    /// The catalog a composer offers here: the server's own, plus the word this app answers.
    var composerCommands: [AgentCommand] {
        CommandCatalogStore.forComposer(commands, supportsDesign: supportsDesign)
    }

    /// What a board turned out to be, so its card names it rather than its folder. Asked once per
    /// directory: a card that only ever names a folder makes the reader open a board to find out
    /// whether it is worth opening.
    private func readDesignBoard(_ directory: String) {
        guard let files = backend as? any FileBrowsingBackend,
            context.designBoards[directory] == nil,
            inFlightDesignBoards.insert(directory).inserted
        else { return }
        let path = DesignPaths.manifest(in: directory)
        Task { [weak self] in
            let text = try? await files.fileContent(path: path)
            Gtk.onMain { [weak self] in
                guard let self, let text, let manifest = DesignManifest.parse(text) else { return }
                self.context.designBoards[directory] = manifest
                self.replaceRows { row in
                    guard case .designBoard(let sighting) = row.kind else { return false }
                    return sighting.source == .board(directory: directory)
                }
            }
        }
    }

    private func openDesign(_ source: DesignSource) {
        switch source {
        case .board(let directory):
            DesignBoardWindow.present(
                directory: directory, backend: backend, parent: host?.windowWidget,
                send: { [weak self] prompt in
                    Gtk.onMain { [weak self] in self?.sendComposed(prompt) }
                },
                notice: { [weak self] text in
                    Gtk.onMain { [weak self] in self?.setNotice(text) }
                })
        case .artifact(let url):
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/xdg-open")
            process.arguments = [url]
            try? process.run()
        }
    }

    /// Continues a turn the server's machine stopped in the middle of. The work resumes on that
    /// machine, so nothing is sent from here and the card comes down on the server's answer.
    ///
    /// The press is worn by the card before the request goes out, and a refusal is reported in the
    /// server's own sentence rather than a substitute — the Kit has already re-read the record by
    /// then, so the card either corrects itself or comes down in the same redraw.
    private func resumeInterruptedTurn() {
        guard let conversation else { return }
        beginInterruptedPress(.pickUp)
        Task {
            do {
                try await conversation.resumeInterruptedTurn()
                Gtk.onMain { [weak self] in self?.endInterruptedPress() }
            } catch {
                let said = Self.refusalText(error)
                Gtk.onMain { [weak self] in
                    self?.endInterruptedPress()
                    self?.setNotice(said)
                }
            }
        }
    }

    /// Sets the cut-off turn aside. A server that no longer holds the record has nothing to refuse:
    /// the press asked for it gone and it is gone, so the card comes down without a word.
    private func dismissInterruptedTurn() {
        guard let conversation else { return }
        beginInterruptedPress(.letGo)
        Task {
            do {
                try await conversation.dismissInterruptedTurn()
                Gtk.onMain { [weak self] in self?.endInterruptedPress() }
            } catch {
                let said = Self.refusalText(error)
                Gtk.onMain { [weak self] in
                    self?.endInterruptedPress()
                    self?.setNotice(said)
                }
            }
        }
    }

    /// The card as this device must draw it: the server's record, wearing a press this device is
    /// still waiting on the answer to. The press is dropped the instant the server's own account
    /// says something — which is what stops a button sitting in flight forever.
    private func interruptedCard(_ state: ConversationState) -> InterruptedTurn? {
        guard let card = InterruptedTurnReading.read(state.interruption) else {
            interruptedPress = nil
            return nil
        }
        guard let press = interruptedPress, !card.isResumed else {
            interruptedPress = nil
            return card
        }
        return InterruptedTurnReading.pressed(card, press)
    }

    /// Acknowledges a press where it happened. The card is redrawn from what this device holds
    /// before the request leaves, so nobody presses twice wondering whether the first one landed.
    private func beginInterruptedPress(_ press: InterruptedTurnPress) {
        interruptedPress = press
        redrawPending()
    }

    private func endInterruptedPress() {
        interruptedPress = nil
        redrawPending()
    }

    /// The row key carries the card's state so a press is a row the diff rebuilds rather than one
    /// it recognises by key and leaves exactly as it was.
    private static func cardKey(_ state: InterruptedTurn.State) -> String {
        switch state {
        case .waiting: return "waiting"
        case .pickingUp: return "pickingup"
        case .lettingGo: return "lettinggo"
        case .resumed: return "resumed"
        }
    }

    /// What to say about a press the server would not take.
    ///
    /// A conflict is the only refusal this side has already acted on — the record was re-read and
    /// the card redrawn — so it is the only one that may carry Core's promise that the card is now
    /// right. Every other failure is reported in the words it arrived with, which are the server's
    /// or the transport's; this client writes neither.
    private static func refusalText(_ error: Error) -> String {
        guard case AgentError.http(let status, let body) = error else {
            return (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
        let named = InterruptedTurnReading.conflict(body: body) != .unstated
        guard status == 409 || (status == 404 && named) else {
            return (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        }
        return InterruptedTurnReading.refusal(body: body)
    }

    private func attachRows() -> [(String, String?, @Sendable () -> Void)] {
        let able = abilities
        let supported = backend?.capabilities.supportsAttachments != false
        if let reason = able.unavailableReason(supportsAttachments: supported) {
            return [(reason, nil, {})]
        }
        var rows: [(String, String?, @Sendable () -> Void)] = [
            (Localized.text("Attach files…"), Localized.text("Up to 8 MB each"),
             { [weak self] in Gtk.onMain { [weak self] in self?.pickAttachments() } })
        ]
        guard able.vision else { return rows }
        rows.append(
            (Localized.text("Paste image"), Localized.text("From the clipboard, as PNG"),
             { [weak self] in Gtk.onMain { [weak self] in self?.pasteImageAttachment() } }))
        return rows
    }

    private func pickAttachments() {
        Gtk.openFiles(parent: host?.windowWidget) { [weak self] paths in
            self?.attach(paths: paths)
        }
    }

    private func attach(paths: [String]) {
        for path in paths {
            switch AttachmentIntake.read(path: path) {
            case .success(let attachment):
                attachments.append(attachment)
            case .failure(let refusal):
                setNotice(refusal.message)
            }
        }
        renderAttachments()
    }

    private func pasteImageAttachment() {
        Gtk.readClipboardImage { [weak self] data in
            guard let self else { return }
            guard let data else {
                self.setNotice(
                            Localized.text("The clipboard holds no picture."))
                return
            }
            guard data.count <= AttachmentIntake.byteCap else {
                self.setNotice(
                            Localized.text(
                        "That picture is %@ — the cap is 8 MB",
                        AttachmentIntake.sizeText(data.count)))
                return
            }
            self.pastedImageCount += 1
            self.attachments.append(
                PendingAttachment(
                    name: "pasted-\(self.pastedImageCount).png", mime: "image/png", data: data))
            self.renderAttachments()
        }
    }

    private func renderAttachments() {
        Gtk.removeChildren(of: attachmentsBox)
        gtk_widget_set_visible(attachmentsBox, attachments.isEmpty ? 0 : 1)
        if let attachButton {
            gtk_menu_button_set_label(
                op(attachButton), attachments.isEmpty ? "📎" : "📎 \(attachments.count)")
        }
        for attachment in attachments {
            let title = "\(attachment.name) · \(AttachmentIntake.sizeText(attachment.data.count))  ✕"
            let id = attachment.id
            gtk_box_append(
                ptr(attachmentsBox),
                Gtk.button(title, css: ["chip"]) { [weak self] in
                    guard let self else { return }
                    self.attachments.removeAll { $0.id == id }
                    self.renderAttachments()
                })
        }
    }

    func jumpToBottom() {
        scrollToBottom()
        clearUnseen()
    }

    private func clearUnseen() {
        unseenRows = 0
        gtk_widget_set_visible(jumpButton, 0)
    }

    private func noteAppendedWhileScrolledUp(_ count: Int) {
        guard count > 0 else { return }
        unseenRows += count
        gtk_button_set_label(ptr(jumpButton), "↓ \(unseenRows)")
        gtk_widget_set_visible(jumpButton, 1)
    }

    func setFindShown(_ shown: Bool) {
        gtk_widget_set_visible(findBar, shown ? 1 : 0)
        if shown {
            gtk_widget_grab_focus(findEntry)
            runFind(retarget: false)
        } else {
            gtk_editable_set_text(op(findEntry), "")
            clearFindHighlight()
            findMatches = []
            gtk_label_set_text(op(findCountLabel), "")
            gtk_widget_grab_focus(transcriptBox)
        }
    }

    var findShown: Bool { gtk_widget_get_visible(findBar) != 0 }

    private func findQuery() -> String {
        guard let raw = gtk_editable_get_text(op(findEntry)) else { return "" }
        return String(cString: raw)
    }

    private func runFind(retarget: Bool) {
        let needle = findQuery().lowercased()
        clearFindHighlight()
        guard !needle.isEmpty else {
            findMatches = []
            gtk_label_set_text(op(findCountLabel), "")
            return
        }
        findMatches = renderedRows.indices.filter {
            renderedRows[$0].searchText.lowercased().contains(needle)
        }
        if retarget { findCursor = 0 }
        if findCursor >= findMatches.count { findCursor = max(0, findMatches.count - 1) }
        updateFindCount()
        guard !findMatches.isEmpty else { return }
        applyFindHighlight(scroll: retarget)
    }

    private func stepFind(by delta: Int) {
        guard !findMatches.isEmpty else { return }
        let count = findMatches.count
        findCursor = ((findCursor + delta) % count + count) % count
        updateFindCount()
        applyFindHighlight(scroll: true)
    }

    private func updateFindCount() {
        gtk_label_set_text(
            op(findCountLabel),
            findMatches.isEmpty
                ? Localized.text("No matches") : "\(findCursor + 1)/\(findMatches.count)")
    }

    /// Marks the current match, and on an explicit jump scrolls it to the upper third so the eye
    /// lands on the hit rather than hunting for it.
    private func applyFindHighlight(scroll: Bool) {
        guard findMatches.indices.contains(findCursor) else { return }
        let index = findMatches[findCursor]
        guard index < rowWidgets.count,
            let raw = UnsafeMutableRawPointer(bitPattern: rowWidgets[index])
        else { return }
        clearFindHighlight()
        let widget: UnsafeMutablePointer<GtkWidget> = ptr(raw)
        Gtk.addClass(widget, "find-hit")
        highlightedRow = rowWidgets[index]
        guard scroll else { return }
        let offset = tailscode_widget_offset_y(widget, canvasBox ?? transcriptBox)
        guard offset >= 0, let scroller = transcriptScroller,
            let adjustment = gtk_scrolled_window_get_vadjustment(op(scroller))
        else { return }
        let page = gtk_adjustment_get_page_size(adjustment)
        let ceiling = max(0, gtk_adjustment_get_upper(adjustment) - page)
        gtk_adjustment_set_value(adjustment, min(max(0, offset - page * 0.3), ceiling))
    }

    private func clearFindHighlight() {
        guard highlightedRow != 0,
            let raw = UnsafeMutableRawPointer(bitPattern: highlightedRow)
        else { return }
        gtk_widget_remove_css_class(ptr(raw) as UnsafeMutablePointer<GtkWidget>, "find-hit")
        highlightedRow = 0
    }

    /// Disk first, tailnet second: a picture this machine has ever shown comes back in one frame.
    /// The decode happens off the main context, and the texture is downsampled — the transcript
    /// shows a reference, not the original, and the original costs megabytes of VRAM a bubble has
    /// no use for. The gallery decodes the original itself, one page at a time.
    private func fetchImage(_ reference: FileReference, key: String) {
        guard !inFlightImages.contains(key) else { return }
        inFlightImages.insert(key)
        let backend = backend
        let sessionID = self.sessionID
        Task { [weak self] in
            var data = ImageCache.load(reference)
            if data == nil, let backend {
                data = try? await backend.attachmentData(reference)
                if let data { ImageCache.save(data, for: reference) }
            }
            guard let data else {
                Gtk.onMain { [weak self] in self?.inFlightImages.remove(key) }
                return
            }
            let decoded: (bits: UInt, width: Int32, height: Int32) = data.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return (0, 0, 0) }
                var width: Int32 = 0
                var height: Int32 = 0
                guard
                    let texture = tailscode_texture_scaled(
                        base, gsize(buffer.count), TranscriptContext.bubbleMaxDimension,
                        &width, &height)
                else { return (0, 0, 0) }
                return (UInt(bitPattern: texture), width, height)
            }
            guard decoded.bits != 0 else {
                Gtk.onMain { [weak self] in self?.inFlightImages.remove(key) }
                return
            }
            Gtk.onMain { [weak self] in
                guard let self else { return }
                self.inFlightImages.remove(key)
                self.adoptImage(decoded, data: data, key: key, from: sessionID)
            }
        }
    }

    /// A decoded picture landing after the pane may have moved on, which is two halves with two
    /// owners. The cache belongs to the device — `TranscriptContext.store` is deliberately kept
    /// across a chat switch, LRU-bounded by VRAM, so a picture already decoded comes back in one
    /// frame and the store must happen whatever the pane is showing now. The rows belong to the
    /// session that asked, so only a pane still on that session may be told to repaint one.
    private func adoptImage(
        _ decoded: (bits: UInt, width: Int32, height: Int32), data: Data, key: String,
        from sessionID: String?
    ) {
        context.store(
            textureBits: decoded.bits, data: data,
            dimensions: (decoded.width, decoded.height), forKey: key)
        guard self.sessionID == sessionID else { return }
        replaceRows { $0.key == key }
    }

    /// A workflow's runs, rebuilt from the transcript and the live fan-out. Only the cards whose
    /// run actually changed are replaced: a run reports every second and a full rebuild of the
    /// transcript for a spinner frame is a flicker.
    private func refreshWorkflowRuns() {
        guard let state = lastState else { return }
        let runs = WorkflowRunAssembly.runs(
            messages: state.messages, agents: agents, now: context.workflowNow)
        if runs != workflowRuns {
            var byCall: [String: WorkflowRun] = [:]
            for run in runs { byCall[run.id] = run }
            let stale = Set(
                byCall.keys.filter { context.workflowRuns[$0] != byCall[$0] }
                    + context.workflowRuns.keys.filter { byCall[$0] == nil })
            workflowRuns = runs
            context.workflowRuns = byCall
            refreshWorkflowCards(stale)
        }
        updateTicker(running: state.status == .running)
    }

    /// A changed run is written into the card it already has; only a card whose structure no
    /// longer matches — an agent appeared, the result landed — is rebuilt, and only that card.
    /// A rebuild destroys the widget under the pointer and the click that was in flight with it,
    /// so it is the exception, never the once-a-second path.
    private func refreshWorkflowCards(_ ids: Set<String>) {
        guard !ids.isEmpty, !placeholderShown else { return }
        var rebuilt: Set<String> = []
        for index in renderedRows.indices {
            guard case .workflow(let call) = renderedRows[index].kind, ids.contains(call.id),
                index < rowWidgets.count,
                let raw = UnsafeMutableRawPointer(bitPattern: rowWidgets[index])
            else { continue }
            if !WorkflowCardView.restate(ptr(raw), call: call, context: context) {
                rebuilt.insert(renderedRows[index].key)
            }
        }
        if !rebuilt.isEmpty { replaceRows { rebuilt.contains($0.key) } }
    }

    /// Whether anything on screen still needs a clock: a turn in flight, a workflow that outlived
    /// it, a compaction counting up, or a pending send whose caption ages. A background run keeps
    /// four agents working for minutes after the turn that launched it ended, and a card whose
    /// elapsed reading froze at launch reads as a hang.
    private var needsTicker: Bool {
        lastState?.status == .running
            || lastState?.compaction?.isRunning == true
            || workflowRuns.contains(where: \.isLive)
            || pending.sends.contains {
                switch $0.phase {
                case .sending, .accepted: return true
                case .failed: return false
                }
            }
    }

    /// The clock every live workflow card is drawn against, moved once a second so spinners turn and
    /// elapsed readings climb without a state event.
    private func advanceWorkflowClock() {
        guard workflowRuns.contains(where: \.isLive) else { return }
        context.workflowNow = Date()
        let live = Set(workflowRuns.filter(\.isLive).map(\.id))
        refreshWorkflowRuns()
        refreshWorkflowCards(live)
    }

    private func fetchWorkflowAgent(_ agentID: String) {
        guard let backend, let entry, !inFlightSubagents.contains(agentID) else { return }
        inFlightSubagents.insert(agentID)
        let sessionID = entry.session.id
        Task { [weak self] in
            let messages =
                (try? await backend.subagentMessages(sessionID: sessionID, agentID: agentID)) ?? []
            let rows = TranscriptRow.rows(for: messages)
            Gtk.onMain { [weak self] in
                guard let self, self.sessionID == sessionID else { return }
                self.inFlightSubagents.remove(agentID)
                self.context.subagentRows[WorkflowAgentRows.key(agentID)] = rows
                self.replaceRows {
                    guard case .workflow(let call) = $0.kind else { return false }
                    return self.context.workflowRuns[call.id]?.agents
                        .contains { $0.id == agentID } ?? true
                }
            }
        }
    }

    private func fetchSubagent(_ call: ToolCall) {
        guard let backend, let entry,
            !inFlightSubagents.contains(call.id)
        else { return }
        inFlightSubagents.insert(call.id)
        let sessionID = entry.session.id
        Task { [weak self] in
            let agents = (try? await backend.subagents(for: sessionID)) ?? []
            let match = agents.first { $0.toolUseID == call.id }
            let messages: [ChatMessage]
            if let match {
                messages = (try? await backend.subagentMessages(
                    sessionID: sessionID, agentID: match.id)) ?? []
            } else {
                messages = []
            }
            let rows = TranscriptRow.rows(for: messages)
            let callID = call.id
            Gtk.onMain { [weak self] in
                guard let self, self.sessionID == sessionID else { return }
                self.context.subagentRows[callID] = rows
                self.replaceRows {
                    if case .subagent(let spawned) = $0.kind { return spawned.id == callID }
                    return false
                }
            }
        }
    }

    /// The cheatsheet is generated from the registry, so it always tells the truth — overrides
    /// included. Two columns, because forty rows in one column is a scroll, not a glance.
    func rebuildHelpOverlay() {
        guard let shortcuts = host?.shortcuts else { return }
        Gtk.removeChildren(of: helpOverlay)
        let sections = shortcuts.helpSections()
        let columns = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 44)
        let left = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        let right = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        gtk_widget_set_hexpand(left, 1)
        gtk_widget_set_hexpand(right, 1)
        gtk_widget_set_valign(left, GTK_ALIGN_START)
        gtk_widget_set_valign(right, GTK_ALIGN_START)
        let total = sections.reduce(0) { $0 + $1.rows.count + 2 }
        var used = 0
        for section in sections {
            let target = used < (total + 1) / 2 ? left : right
            used += section.rows.count + 2
            let header = Gtk.label(section.title, css: "section-header", selectable: false)
            Gtk.margins(header, top: 8, bottom: 2)
            gtk_box_append(ptr(target), header)
            for row in section.rows {
                let line = Gtk.box(GTK_ORIENTATION_HORIZONTAL, spacing: 12)
                let keys = Gtk.label(row.keys, css: "tool-name", selectable: false)
                gtk_widget_set_size_request(keys, 150, -1)
                gtk_box_append(ptr(line), keys)
                gtk_box_append(
                    ptr(line), Gtk.label(row.what, css: "row-detail", selectable: false))
                gtk_box_append(ptr(target), line)
            }
        }
        gtk_box_append(ptr(columns), left)
        gtk_box_append(ptr(columns), right)
        gtk_box_append(ptr(helpOverlay), columns)
        let hint = Gtk.label(
            Localized.text(
                "Rebind any of these: %@ · Settings → Keyboard", ShortcutSet.configURL.path),
            css: "dim", selectable: false)
        Gtk.margins(hint, top: 10)
        gtk_box_append(ptr(helpOverlay), hint)
    }

    func setHelp(_ shown: Bool) {
        helpShown = shown
        gtk_widget_set_visible(helpOverlay, shown ? 1 : 0)
    }

    func popupCommandPalette() {
        if let commandButton { gtk_menu_button_popup(op(commandButton)) }
    }

    func focusComposer() {
        gtk_widget_grab_focus(entryView)
    }

    /// A scrolled window conjures its own viewport, and a conjured one scrolls to whatever takes
    /// focus. Every row in a transcript is a button: a rebuild that destroys the row holding focus
    /// — which is every arrival of a running turn — and the close of a sibling pane both re-home
    /// focus inside this list, and the viewport answered by animating the transcript to the top
    /// under a reader who was mid-conversation. The sidebar paid this debt already
    /// (`makeSidebarViewport`); nothing had paid it here. What genuinely wants the transcript to
    /// move — find, a disclosure opening — scrolls by hand and is unaffected.
    private func makeTranscriptViewport(
        _ child: UnsafeMutablePointer<GtkWidget>
    ) -> UnsafeMutablePointer<GtkWidget> {
        let viewport = gtk_viewport_new(nil, nil)!
        gtk_viewport_set_scroll_to_focus(op(viewport), 0)
        gtk_viewport_set_child(op(viewport), child)
        return viewport
    }

    /// The transcript box is a plain `GtkBox` and cannot hold focus, so grabbing it moved nothing
    /// and `ctrl+w` left the keyboard wherever it happened to be — often on a disclosure inside
    /// the transcript it had just left. The composer is what a person types into when a pane takes
    /// the keyboard, so that is what takes it.
    func focusTranscript() {
        focusComposer()
    }

    /// Everything the settings window can change that is not a colour, applied to this pane.
    /// Compact and dense change what a row *is*, so the transcript is rebuilt rather than
    /// restyled.
    func applyLayoutPreferences() {
        editor.applyPreferences()
        gtk_box_set_spacing(ptr(transcriptBox), Preferences.denseRows ? 3 : 10)
        windowLimit = max(windowLimit, Preferences.transcriptWindow)
        updateVimBadge()
        tearDownAllRows()
        placeholderShown = true
        rebuildTranscriptRows()
    }

    func retheme() {
        rebuildTranscriptRows()
    }

    /// Rows for the current state, folded off the GLib main context — a ten-thousand-message
    /// conversation must never be re-parsed where the frame clock lives.
    private func rebuildTranscriptRows() {
        guard let state = lastState else { return }
        let tail = rowTailMessages
        let sessionID = self.sessionID
        Task.detached { [weak self] in
            guard let self else { return }
            let messages =
                state.messages.count > tail ? Array(state.messages.suffix(tail)) : state.messages
            let rows = self.rowBuilder.rows(for: messages)
            Gtk.onMain { [weak self] in
                guard let self, self.sessionID == sessionID else { return }
                self.apply(state: state, rows: rows)
            }
        }
    }

    /// A typed slash command goes where the completion list would send it. The decision is the
    /// shared one so all three clients answer a typed command the same way; false means the words
    /// go out as an ordinary prompt.
    private func handleSlashCommand(_ text: String) -> Bool {
        switch SlashDispatch.decide(
            text: text, commands: composerCommands,
            supportsCompaction: backend?.capabilities.supportsCompaction != false,
            resolvesFromPromptText: backend?.resolvesCommandsFromPromptText == true,
            supportsDesign: supportsDesign)
        {
        case .compactPreflight(let instruction):
            host?.presentCompactPreflight(for: self, initialInstruction: instruction)
            return true
        case .designPreflight(let request):
            host?.presentDesignPreflight(for: self, request: request)
            return true
        case .run(let command, let arguments):
            guard let conversation else { return false }
            SlashRecents.record(command.name)
            let model = chosenModel
            let effort = ModelEffort.surviving(chosenEffort, options: effortOptions())
            Task {
                try? await conversation.run(
                    command, arguments: arguments, model: model, reasoningEffort: effort)
            }
            return true
        case .plainText:
            return false
        }
    }

    /// A synthetic conversation around a compaction — the finished seam, the summarize still
    /// running, or the refusal — so every face of the card can be photographed headlessly without
    /// spending minutes compacting a real transcript.
    /// A conversation whose turn the machine was pulled out from under, so the card can be driven
    /// and photographed headlessly without stopping a real server mid-answer.
    func driverInterruptedDemo(_ mode: String) {
        let now = Date()
        let asked = ChatMessage(
            id: "demo-cut-prompt", role: .user, agentType: .claudeCode,
            parts: [
                MessagePart(
                    id: "t", kind: .text("port the toggles to the mac and keep the tests green"))
            ],
            createdAt: now.addingTimeInterval(-900))
        var state = ConversationState(messages: [asked], status: .idle, hasLoadedTranscript: true)
        state.interruption = TurnInterruption(
            turnID: "demo-turn", prompt: "port the toggles to the mac and keep the tests green",
            startedAt: now.addingTimeInterval(-900), detectedAt: now.addingTimeInterval(-120),
            progress: mode == "clean"
                ? TurnInterruption.Progress()
                : TurnInterruption.Progress(
                    toolCount: 9, lastTool: "Edit",
                    filesTouched: [
                        "/home/m/Dev/Tailscode/TailscodeMac/Toggles.swift",
                        "/home/m/Dev/Tailscode/TailscodeMac/Theme.swift",
                    ],
                    commands: ["swift build", "swift test --filter Toggles"],
                    partialAnswer: "I have moved the first two toggles across and"),
            queued: mode == "queued" ? ["then do the same for the sidebar"] : [],
            resumedAt: mode == "resumed" ? now : nil)
        apply(state: state, rows: rowBuilder.rows(for: state.messages))
    }

    func driverCompactionDemo(_ mode: String) {
        let now = Date()
        let compaction = Compaction(
            trigger: .manual, tokensBefore: 148_000, tokensAfter: 11_200, duration: 96,
            preservedMessageCount: 4,
            summary: """
                ## Task
                Refactor the settings store behind a SettingsFile prefix so preferences survive \
                restart on Linux.

                ## State
                The store reads through the prefix; the migration test still fails on the legacy \
                path. Next: keep the failing test names and re-run the suite.
                """)
        let before = ChatMessage(
            id: "demo-cbefore", role: .user, agentType: .claudeCode,
            parts: [
                MessagePart(
                    id: "t", kind: .text("Refactor the settings store, keep the tests green."))
            ],
            createdAt: now.addingTimeInterval(-660))
        let seam = ChatMessage(
            id: "demo-compaction", role: .assistant, agentType: .claudeCode,
            parts: [MessagePart(id: "c", kind: .compaction(compaction))],
            createdAt: now.addingTimeInterval(-300))
        let after = ChatMessage(
            id: "demo-cafter", role: .assistant, agentType: .claudeCode,
            parts: [
                MessagePart(
                    id: "t",
                    kind: .text(
                        "Picking up from the summary: the migration test still names the legacy path."
                    ))
            ],
            createdAt: now.addingTimeInterval(-200))
        var state = ConversationState()
        state.hasLoadedTranscript = true
        state.status = .idle
        switch mode {
        case "running":
            state.messages = [before]
            state.status = .running
            state.compaction = CompactionActivity(startedAt: now.addingTimeInterval(-75))
        case "queued":
            state.messages = [before]
            state.status = .running
            state.compaction = CompactionActivity(startedAt: now.addingTimeInterval(-75))
            pending.begin(text: "and while you are at it, run the tests", userMessages: 1)
        case "failed":
            state.messages = [before]
            state.compaction = CompactionActivity(
                startedAt: now.addingTimeInterval(-8),
                failure: "Conversation too small to compact — nothing would be freed.")
        default:
            state.messages = [before, seam, after]
        }
        apply(state: state, rows: rowBuilder.rows(for: state.messages))
    }

    /// Seeds the composer for the headless driver, through the same paths a keystroke takes.
    /// A synthetic conversation carrying one live workflow and one finished one, so the card can be
    /// driven and photographed headlessly without waiting three minutes on a real fan-out.
    /// A conversation whose last send a spent window stopped, so the wait can be driven and
    /// photographed without an account that is actually out of quota. `stale` is the one nobody
    /// was awake for; anything else is a live wait.
    func driverResumeDemo(_ mode: String) {
        let now = Date()
        let asked = ChatMessage(
            id: "demo-resume-user", role: .user, agentType: .claudeCode,
            parts: [MessagePart(id: "t", kind: .text("Refactor the settings store."))],
            createdAt: now.addingTimeInterval(-900))
        var state = ConversationState()
        state.hasLoadedTranscript = true
        state.status = .idle
        state.messages = [asked]
        pending.removeAll()
        resume.removeAll()
        let row = pending.begin(
            text: "and while you are at it, run the tests", userMessages: 1, now: now)
        pending.mark(id: row.id, .failed(reason: "Claude usage limit reached"))
        let fires = mode == "stale" ? -(AutoResume.staleAfter + 120) : 2 * 3600 + 45
        resume.hold(
            ResumePlan(
                id: row.id, profileID: entry?.profileID ?? "demo",
                sessionID: entry?.session.id ?? "demo", provider: "Claude", window: "Session",
                resumesAt: now.addingTimeInterval(fires), trustedReset: true, trigger: .refused,
                attempt: mode == "again" ? 2 : 0, plannedAt: now))
        startResumeClock()
        apply(state: state, rows: rowBuilder.rows(for: state.messages))
        reportResumeState()
    }

    /// What the pane is holding, for the headless driver: the rows, the plans, and the line the
    /// first one is wearing.
    func reportResumeState() {
        let now = Date()
        let plan = resume.plans.values.min { $0.resumesAt < $1.resumesAt }
        FileHandle.standardOutput.write(
            Data(
                ("RESUME pending=\(pending.count) plans=\(resume.count) "
                    + (plan.map { ResumeReading.caption($0, now: now) }
                        ?? pending.sends.first.map { PendingSendReading.caption($0, now: now) }
                        ?? "none") + "\n").utf8))
    }

    func driverWorkflowDemo() {
        let now = Date()
        let script = """
            export const meta = {
              name: 'kaytetty-best',
              description: 'Recommend the best USED-market buy in Finland — priced live across Tori.fi and Huuto.net',
              phases: [
                { title: 'Scope', detail: 'classify the request and build the used-market search plan' },
                { title: 'Hunt', detail: 'pull live listings from Tori.fi + Huuto.net', model: 'claude-haiku-4-5-20251001' },
                { title: 'Appraise', detail: 'compute the fair band, flag scams, pick the best listing' },
              ],
            }
            """
        let call = ToolCall(
            id: "demo-wf", name: "Workflow", status: .running,
            input: .object(["script": .string(script)]),
            output: "Workflow launched in background. Task ID: demo-task\nRun ID: wf_demo")
        let prompt = ChatMessage(
            id: "demo-user", role: .user, agentType: .claudeCode,
            parts: [MessagePart(id: "t", kind: .text("/kaytetty-best Pokemon Yellow"))],
            createdAt: now.addingTimeInterval(-104))
        let launch = ChatMessage(
            id: "demo-launch", role: .assistant, agentType: .claudeCode,
            parts: [MessagePart(id: "p", kind: .tool(call))],
            createdAt: now.addingTimeInterval(-100))
        agents = [
            SubagentSummary(
                id: "d0", title: "You are scoping a \"best thing to buy SECOND-HAND in Finland\" request",
                agentType: WorkflowRunAssembly.agentType, updatedAt: now.addingTimeInterval(-41),
                isActive: false, isCompleted: true, startedAt: now.addingTimeInterval(-100)),
            SubagentSummary(
                id: "d1", title: "Use the WebFetch tool on this Tori.fi used-marketplace search URL",
                agentType: WorkflowRunAssembly.agentType, updatedAt: now,
                isActive: true, isCompleted: false, startedAt: now.addingTimeInterval(-41),
                toolCount: 3, currentTool: "WebFetch"),
            SubagentSummary(
                id: "d2", title: "Run EXACTLY these commands (Huuto.net public JSON API, two pages)",
                agentType: WorkflowRunAssembly.agentType, updatedAt: now,
                isActive: true, isCompleted: false, startedAt: now.addingTimeInterval(-41),
                toolCount: 2, currentTool: "Bash"),
        ]
        var state = ConversationState()
        state.messages = [prompt, launch]
        state.hasLoadedTranscript = true
        state.status = .idle
        apply(state: state, rows: rowBuilder.rows(for: state.messages))
        context.expanded.set("demo-launch:p", open: true)
        refreshWorkflowRuns()
        replaceRows { if case .workflow = $0.kind { return true } else { return false } }
    }

    func driverType(_ text: String) {
        gtk_widget_grab_focus(entryView)
        vim.reset(to: text, cursor: text.count, mode: .insert)
        gtk_text_buffer_set_text(gtk_text_view_get_buffer(ptr(entryView)), text, -1)
    }
}
