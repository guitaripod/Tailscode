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
    /// What the whole conversation has cost, asked of the server on the same slow poll as the
    /// agents. A backend that cannot account for it leaves this nil and the band falls back to the
    /// last turn's price.
    private var spend: SessionSpend?
    /// Which branch this conversation's work is landing on, read on the same slow poll. Nil for a
    /// server that cannot read a repository, which is how the band knows to say nothing at all.
    private var git: GitState?
    private var contextEstimate: Int?
    private var echoedPrompt: String?
    private var pendingFirstMessage:
        (sessionID: String, text: String, attachments: [PendingAttachment])?
    private var notice: String?
    let entryView = gtk_text_view_new()!
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
    private(set) var composerScroller: UnsafeMutablePointer<GtkWidget>?
    private var composerHeight: Int32 = 0
    private var isMeasuringComposer = false
    let vim = VimEngine()
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

    private(set) var entry: SessionEntry?
    /// What this pane is watching instead of talking, when it is a video slot rather than a chat.
    private(set) var video: VideoPane?
    /// What this pane is reading instead of talking, when it is a browser slot rather than a chat.
    private(set) var page: WebPane?
    private(set) var backend: (any CodingAgentBackend)?
    private(set) var conversation: AgentConversation?
    private(set) var lastState: ConversationState?
    private var streamTask: Task<Void, Never>?
    private var agentStreamTask: Task<Void, Never>?
    private var agentStreamSessionID: String?
    private var tickerTask: Task<Void, Never>?
    private var turnStartedAt: Date?

    private var models: [ModelInfo] = []
    private var commands: [AgentCommand] = []
    private var completionPopover: UnsafeMutablePointer<GtkWidget>?
    private(set) var completionMatches: [AgentCommand] = []
    private var completionCursor = 0
    private var chosenModel: ModelSelection?
    private var chosenEffort: String?
    private let aura = AuraPainter()
    var ultracodeInFlight = false

    /// What the next turn out of this pane runs on, however it is started — a typed prompt, a
    /// slash command, or a compaction someone opened from the window's own chrome.
    var promptChoice: (model: ModelSelection?, effort: String?) { (chosenModel, chosenEffort) }

    var sessionID: String? { entry?.session.id }
    var auraActive: Bool { aura.isActive }

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
    /// it stopped to ask something, or that its last turn failed. The order is the status band's
    /// own — a failure outranks everything, a question or an approval outranks merely being busy —
    /// and the step is the running tool `StatusFacts` already named, so the row and the band never
    /// speak two vocabularies for one turn.
    var presence: SessionPresence {
        guard let state = lastState else { return .unobserved }
        if state.lastFailure != nil { return .failed }
        if !state.pendingPermissions.isEmpty || !state.pendingQuestions.isEmpty {
            return .awaitingApproval
        }
        if state.status == .running || state.compaction?.isRunning == true {
            return .running(bandState.facts.runningTool)
        }
        return .unobserved
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
        gtk_scrolled_window_set_child(op(scroller), canvas)
        gtk_widget_set_vexpand(scroller, 1)
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

        let scroller = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(op(scroller), GTK_POLICY_NEVER, GTK_POLICY_AUTOMATIC)
        gtk_widget_set_hexpand(scroller, 1)
        composerScroller = scroller
        gtk_text_view_set_wrap_mode(ptr(entryView), GTK_WRAP_WORD_CHAR)
        gtk_text_view_set_monospace(ptr(entryView), 1)
        gtk_text_view_set_top_margin(ptr(entryView), 8)
        gtk_text_view_set_left_margin(ptr(entryView), 10)
        gtk_text_view_set_right_margin(ptr(entryView), 10)
        gtk_scrolled_window_set_child(op(scroller), entryView)
        Gtk.addClass(scroller, "composer")
        Gtk.connect(
            UnsafeMutableRawPointer(gtk_text_view_get_buffer(ptr(entryView))), "changed"
        ) { [weak self] in
            self?.growComposer()
            self?.updateSlashCompletion()
            self?.refreshUltracodeAura()
            self?.recordDraft()
        }

        let auraHost = gtk_overlay_new()!
        gtk_overlay_set_child(op(auraHost), scroller)
        gtk_overlay_add_overlay(op(auraHost), aura.widget)
        gtk_widget_set_hexpand(auraHost, 1)
        gtk_box_append(ptr(row), auraHost)

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
                if open { self.context.expanded.insert(key) } else {
                    self.context.expanded.remove(key)
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
        context.askAgain = { [weak self] words in
            Gtk.onMain { [weak self] in self?.askAgain(words) }
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
            if current != identityLabel, current != video?.root, current != page?.root {
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
        _ text: String, attachments: [PendingAttachment] = [], forSession sessionID: String
    ) {
        pendingFirstMessage = (sessionID, text, attachments)
    }

    /// The one read of the queue, serialized through the GTK main loop because the queue is
    /// written there: whichever stream task reaches its conversation first takes the whole value,
    /// and everyone else sees nothing.
    private func takeQueuedFirstMessage() async
        -> (sessionID: String, text: String, attachments: [PendingAttachment])?
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
        chooser = nil
        freshlyCreatedID = freshlyCreated ? entry.session.id : nil
        stashDraft()
        self.entry = entry
        conversation = nil
        backend = nil
        lastState = nil
        models = []
        commands = []
        chosenModel = ModelPreferenceStore.initialModel(
            sessionKey: Self.preferenceKey(entry), contextID: entry.profileID,
            sessionModel: entry.session.model)
        chosenEffort = EffortPreferenceStore.initialEffort(
            sessionKey: Self.preferenceKey(entry), contextID: entry.profileID,
            sessionEffort: entry.session.reasoningEffort)
        ultracodeInFlight = false
        refreshUltracodeAura()
        turnStartedAt = nil
        context.expanded = []
        context.subagentRows = [:]
        context.liveReasoning = [:]
        context.agentFacts = [:]
        context.workflowRuns = [:]
        inFlightImages = []
        inFlightSubagents = []
        attachments = []
        pastedImageCount = 0
        echoedPrompt = nil
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
        streamTask?.cancel()
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
        Gtk.removeChildren(of: pendingBox)
        gtk_widget_set_visible(authBanner, 0)
        refreshPills()
        refreshIdentity()
        SessionSeenStore.markSeen(entry.session.id)
        agents = []
        usage = nil
        notice = nil
        agentStreamTask?.cancel()
        agentStreamTask = nil
        agentStreamSessionID = nil
        Trace.mark("open pane ready")
        host?.paneOpened(self)
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
                let effort = self.chosenEffort
                Gtk.onMain { [weak self] in
                    guard let self, self.sessionID == sessionID else { return }
                    self.echoedPrompt = queued.text
                    if Ultracode.invokes(queued.text) || effort == Ultracode.effortLevel {
                        self.ultracodeInFlight = true
                        self.refreshUltracodeAura()
                    }
                }
                try? await conversation.send(
                    queued.text, model: model, reasoningEffort: effort,
                    attachments: queued.attachments.map(\.prompt))
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
        entry = nil
        clearComposer()
        backend = nil
        conversation = nil
        lastState = nil
        lastFullRows = []
        lastFullCount = 0
        lastStreamedKey = nil
        repairingTail = false
        repairKey = nil
        abandoned = nil
        pendingSignature = "\u{0}"
        compactingElapsed = nil
        compactingStartedAt = nil
        Gtk.removeChildren(of: pendingBox)
        gtk_widget_set_visible(authBanner, 0)
        showPlaceholder(placeholder)
        refreshPills()
        refreshIdentity()
    }

    /// A closing pane stops talking to the world before its widgets go: a cancelled stream is
    /// the difference between a closed pane and a leak that keeps rendering into nothing.
    func shutdown() {
        cascade.release()
        video?.shutdown()
        video = nil
        page?.shutdown()
        page = nil
        stashDraft()
        streamTask?.cancel()
        agentStreamTask?.cancel()
        tickerTask?.cancel()
        aura.setActive(false)
        streamTask = nil
        agentStreamTask = nil
        tickerTask = nil
    }

    /// Everything worth knowing about the session besides its transcript, fetched once per open:
    /// the models the server offers, the commands it resolves, and whether its Claude is signed in.
    private func loadSessionExtras(
        backend: any CodingAgentBackend, directory: String?, sessionID: String
    ) {
        Task { [weak self] in
            let models = (try? await backend.availableModels()) ?? []
            let commands = (try? await backend.availableCommands(directory: directory)) ?? []
            Gtk.onMain { [weak self] in
                guard let self, self.sessionID == sessionID else { return }
                self.models = models
                if let profileID = self.entry?.profileID {
                    ModelCatalogStore.store(models, for: profileID)
                }
                self.commands = commands
                self.refreshPills()
                self.refreshTurnFacts()
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
        var rows = rows
        if let echoedPrompt {
            if state.messages.contains(where: {
                $0.role == .user && $0.text.contains(echoedPrompt.prefix(80))
            }) {
                self.echoedPrompt = nil
            } else {
                if !rows.isEmpty {
                    rows.append(TranscriptRow(key: "echo:break", kind: .turnBreak))
                }
                rows.append(TranscriptRow(key: "echo:prompt", kind: .userText(echoedPrompt)))
            }
        }
        // A turn the machine cut off is docked at the very end: it is an account of what already
        // happened, and it belongs below everything that did.
        if let cutOff = InterruptedTurnReading.read(state.interruption) {
            if !rows.isEmpty {
                rows.append(TranscriptRow(key: "interrupted:break", kind: .turnBreak))
            }
            rows.append(TranscriptRow(key: "interrupted", kind: .interruptedTurn(cutOff)))
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
    var isAnswering: Bool { chooser != nil || video != nil || page != nil }

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
        guard let markup = Self.cascadeMarkup(for: row) else { return false }
        return cascade.settle(label, markup: markup)
    }

    /// What the shim should parse for this row. Prose already carries its markup; a code block is
    /// its own body, escaped, so the one reveal path serves both.
    ///
    /// GtkLabel resolves `<a href>` itself and never hands it to Pango, but a live row is painted
    /// through Pango's own parser — so a link is dressed as what the label would have made of it,
    /// and becomes a real link again the moment the row settles and is rendered the ordinary way.
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
            $0.failure ?? "compacting:\($0.startedAt.timeIntervalSince1970):\(echoedPrompt != nil)"
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
                        startedAt: compaction.startedAt, waiting: echoedPrompt != nil
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
    /// the context is spent, what the goal is — every fact clickable.
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
        StatusBand.render(into: statusBand, state: bandState, facts: facts, notice: bandNotice) {
            [weak self] action in
            Gtk.onMain { [weak self] in self?.perform(bandAction: action) }
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
        guard state.lastFailure == nil, state.status != .running else { return nil }
        let relevant = QuotaSurface.relevantQuotas(for: backend?.agentType, among: quotas)
        return QuotaSurface.hottestExhausted(in: relevant, model: activeModelID)
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
            context.expanded.insert(row.key)
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
    /// only, and a fan-out is worth watching while it runs.
    private func refreshTurnFacts() {
        guard let backend, let entry else { return }
        startAgentStreamIfAvailable()
        let sessionID = entry.session.id
        let skipAgents = agentStreamSessionID == sessionID && agentStreamTask != nil
        Task { [weak self] in
            let agents = skipAgents ? nil : ((try? await backend.subagents(for: sessionID)) ?? [])
            let usage = (try? await backend.sessionUsage(sessionID)) ?? nil
            let report = (try? await backend.sessionSpend(sessionID)) ?? nil
            let repository = await Self.readGit(backend: backend, session: entry.session)
            Gtk.onMain { [weak self] in
                guard let self, self.sessionID == sessionID else { return }
                self.usage = usage
                self.git = repository.map { GitState(snapshot: $0) }
                self.spend = report.map(SessionSpend.init(report:))
                    ?? SessionSpend(messages: self.lastState?.messages ?? [])
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
        guard let observer = backend as? any GitObservingBackend else { return nil }
        let snapshot = try? await observer.gitSnapshot(
            directory: session.directory, sessionID: session.id)
        return (snapshot?.repo == true) ? snapshot : nil
    }

    /// A once-a-second nudge while a turn runs, so elapsed time moves without any state event.
    private func updateTicker(running: Bool) {
        let running = running || needsTicker
        if running, tickerTask == nil {
            tickerTask = Task { [weak self] in
                var tick = 0
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    tick += 1
                    let facts = tick % 5 == 0
                    Gtk.onMain { [weak self] in
                        self?.updateStatus()
                        self?.updateCompactingElapsed()
                        self?.advanceWorkflowClock()
                        if facts { self?.refreshTurnFacts() }
                    }
                }
            }
        } else if !running {
            if tickerTask != nil {
                tickerTask?.cancel()
                tickerTask = nil
                refreshTurnFacts()
            }
        }
    }

    func refreshPills() {
        let destination = [
            entry.map { ServerLabel.display(name: $0.profileName, backend: $0.backendType) },
            entry?.session.directory.map { URL(fileURLWithPath: $0).lastPathComponent },
        ].compactMap { $0 }.joined(separator: " · ")
        gtk_label_set_text(op(destinationLabel), destination)

        if let modelButton {
            gtk_menu_button_set_label(op(modelButton), modelPillText())
            applyTintClass(to: modelButton, from: modelTintClasses, chosen: modelTintClass())
        }
        if let effortButton {
            gtk_menu_button_set_label(op(effortButton), effortPillText())
            applyTintClass(
                to: effortButton, from: effortTintClasses,
                chosen: ModelTint.effortClass(effortPillText()))
        }
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

    private func effortPillText() -> String {
        if let chosenEffort { return chosenEffort }
        if let stored = entry?.session.reasoningEffort, !stored.isEmpty { return stored }
        if let observed = observedEffort() { return observed }
        guard !effortOptions().isEmpty else { return Localized.text("no effort control") }
        return Localized.text("server effort")
    }

    private func observedEffort() -> String? {
        guard let messages = lastState?.messages else { return nil }
        for message in messages.reversed() where message.role == .assistant {
            if let effort = message.reasoningEffort, !effort.isEmpty { return effort }
        }
        return nil
    }

    /// Effort is a property of the model on servers whose catalog says so; the backend-wide list
    /// is the fallback for agents where every model takes the same levels.
    private func effortOptions() -> [String] {
        let active = activeModelID
        if let active, let variants = models.first(where: { $0.id == active })?.variants,
            !variants.isEmpty
        {
            return variants
        }
        return backend?.reasoningEffortOptions ?? []
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
    /// ever having talked to it.
    private func modelSources() -> [ModelSource] {
        let profiles = host?.fleetProfiles() ?? []
        let sources = ModelFleet.sources(
            profiles: profiles, current: entry?.profileID, currentModels: models)
        guard sources.isEmpty else { return sources }
        return [
            ModelSource(
                profileID: entry?.profileID ?? "", name: "", backend: backend?.agentType ?? .openCode,
                models: models, isCurrent: true, allowsServerDefault: true,
                acceptsAnyModelID: backend?.agentType == .claudeCode)
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
            SettingsFile.capture()
        }
        refreshPills()
    }

    private func effortRows() -> [(String, String?, @Sendable () -> Void)] {
        let options = effortOptions()
        guard !options.isEmpty else {
            return [(Localized.text("This agent has no effort control"), nil, {})]
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
        let was = aura.isActive
        aura.setActive(
            Ultracode.auraActive(
                effort: chosenEffort, draft: composerText(), inFlightInvoked: ultracodeInFlight))
        if aura.isActive != was { host?.refreshOrb() }
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
        for command in commands where command.name != "compact" && command.name != "goal" {
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
        guard Preferences.vimComposer else {
            gtk_text_view_set_cursor_visible(ptr(entryView), 1)
            gtk_widget_set_visible(vimBadge, 0)
            if let composerScroller {
                gtk_widget_remove_css_class(composerScroller, "composer-normal")
                gtk_widget_remove_css_class(composerScroller, "composer-visual")
            }
            return
        }
        gtk_text_view_set_cursor_visible(ptr(entryView), vim.mode == .insert ? 1 : 0)
        gtk_widget_set_visible(vimBadge, 1)
        gtk_label_set_text(op(vimBadge), vim.mode.label)
        gtk_widget_remove_css_class(vimBadge, "vim-badge-visual")
        gtk_widget_remove_css_class(vimBadge, "vim-badge-insert")
        switch vim.mode {
        case .insert: Gtk.addClass(vimBadge, "vim-badge-insert")
        case .visual, .visualLine: Gtk.addClass(vimBadge, "vim-badge-visual")
        case .normal: break
        }
        guard let composerScroller else { return }
        gtk_widget_remove_css_class(composerScroller, "composer-normal")
        gtk_widget_remove_css_class(composerScroller, "composer-visual")
        switch vim.mode {
        case .normal: Gtk.addClass(composerScroller, "composer-normal")
        case .visual, .visualLine: Gtk.addClass(composerScroller, "composer-visual")
        case .insert: break
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
            case Keymap.tab: acceptCompletion(at: completionCursor); return true
            case Keymap.shiftTab: moveCompletion(by: -1); return true
            case Keymap.down: moveCompletion(by: 1); return true
            case Keymap.up: moveCompletion(by: -1); return true
            case Keymap.escape: dismissCompletion(); return true
            default:
                if control, Keymap.scalar(keyval) == "n" { moveCompletion(by: 1); return true }
                if control, Keymap.scalar(keyval) == "p" { moveCompletion(by: -1); return true }
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
            if case .handled = outcome { writeComposer(vim.document, selection: vim.selection) }
        case .send:
            sendFromComposer()
        }
        updateVimBadge()
    }

    /// The prompt box is as tall as what is in it, and it stops growing at the height the
    /// settings window sets. Measured on the next idle, never inline.
    private func growComposer() {
        guard !isMeasuringComposer else { return }
        isMeasuringComposer = true
        Gtk.onMain { [weak self] in
            guard let self else { return }
            self.isMeasuringComposer = false
            self.measureComposer()
        }
    }

    private func measureComposer() {
        guard let composerScroller else { return }
        let line = 20.0 * Preferences.scale(.mono)
        let ceiling = Int32(line * Double(Preferences.composerLines) + 18)
        let floor = Int32(line + 18)

        var minimum: Int32 = 0
        var natural: Int32 = 0
        let width = gtk_widget_get_width(entryView)
        gtk_widget_measure(
            entryView, GTK_ORIENTATION_VERTICAL, width > 0 ? width : -1, &minimum, &natural,
            nil, nil)
        let wanted = composerText().isEmpty ? floor : max(floor, min(ceiling, natural + 18))
        guard wanted != composerHeight else { return }
        composerHeight = wanted
        gtk_widget_set_size_request(composerScroller, -1, wanted)
    }

    private func composerCursor() -> Int {
        let buffer = gtk_text_view_get_buffer(ptr(entryView))
        var iter = GtkTextIter()
        gtk_text_buffer_get_iter_at_mark(buffer, &iter, gtk_text_buffer_get_insert(buffer))
        return Int(gtk_text_iter_get_offset(&iter))
    }

    private func writeComposer(_ document: VimDocument, selection: Range<Int>?) {
        let buffer = gtk_text_view_get_buffer(ptr(entryView))
        if composerText() != document.text {
            gtk_text_buffer_set_text(buffer, document.text, -1)
        }
        var caret = GtkTextIter()
        gtk_text_buffer_get_iter_at_offset(buffer, &caret, Int32(document.cursor))
        if let selection {
            var start = GtkTextIter()
            var end = GtkTextIter()
            gtk_text_buffer_get_iter_at_offset(buffer, &start, Int32(selection.lowerBound))
            gtk_text_buffer_get_iter_at_offset(buffer, &end, Int32(selection.upperBound))
            gtk_text_buffer_select_range(buffer, &end, &start)
        } else {
            gtk_text_buffer_place_cursor(buffer, &caret)
        }
        gtk_text_view_scroll_to_mark(
            ptr(entryView), gtk_text_buffer_get_insert(buffer), 0, 0, 0, 0)
    }

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

    /// Typing `/word` offers what it could become, right above the prompt box. The popover never
    /// takes focus — it is a suggestion, not a dialog.
    var completionShown: Bool {
        completionPopover.map { gtk_widget_get_visible($0) != 0 } ?? false
    }

    private func updateSlashCompletion() {
        let typing = !Preferences.vimComposer || vim.mode == .insert
        guard typing else {
            dismissCompletion()
            return
        }
        let presentation = SlashPresentation.of(
            text: composerText(), commands: commands,
            recents: SlashRecents.surviving(in: commands))
        switch presentation {
        case .hidden:
            dismissCompletion()
        case .naming(let matches):
            completionMatches = matches.map(\.command)
            completionCursor = min(completionCursor, max(0, matches.count - 1))
            renderCompletion(presentation)
        case .arguments, .noMatch:
            completionMatches = []
            completionCursor = 0
            renderCompletion(presentation)
        }
    }

    private func moveCompletion(by delta: Int) {
        let count = completionMatches.count
        guard count > 0 else { return }
        completionCursor = ((completionCursor + delta) % count + count) % count
        renderCompletion(
            .naming(
                matches: completionMatches.map {
                    SlashMatch(command: $0, kind: .prefix, highlight: [])
                }))
    }

    private func acceptCompletion(at index: Int) {
        guard index < completionMatches.count else { return }
        acceptSlashCommand(completionMatches[index])
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
        guard let completionPopover, gtk_widget_get_visible(completionPopover) != 0 else {
            return
        }
        gtk_popover_popdown(ptr(completionPopover))
    }

    /// Argument stage, hints, and no-match live here with the naming list — the greppable anchor
    /// for slashCompletion on Linux.
    private func renderCompletion(_ presentation: SlashPresentation? = nil) {
        guard let anchor = composerScroller else { return }
        let surface =
            presentation
            ?? SlashPresentation.of(
                text: composerText(), commands: commands,
                recents: SlashRecents.surviving(in: commands))
        guard surface.isVisible else {
            dismissCompletion()
            return
        }
        let popover: UnsafeMutablePointer<GtkWidget>
        if let existing = completionPopover {
            popover = existing
        } else {
            popover = gtk_popover_new()!
            gtk_widget_set_parent(popover, anchor)
            gtk_popover_set_autohide(ptr(popover), 0)
            gtk_popover_set_has_arrow(ptr(popover), 0)
            gtk_popover_set_position(ptr(popover), GTK_POS_TOP)
            completionPopover = popover
        }
        let column = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 2)
        switch surface {
        case .hidden:
            break
        case .naming(let matches):
            let start = max(0, min(completionCursor - 3, matches.count - 8))
            let end = min(matches.count, start + 8)
            for index in start..<end {
                let command = matches[index].command
                gtk_box_append(
                    ptr(column),
                    completionButton(
                        title: "/\(command.name)",
                        detail: [command.argumentHint, command.details, command.scope]
                            .compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: " · "),
                        selected: index == completionCursor
                    ) { [weak self] in
                        Gtk.onMain { [weak self] in self?.acceptSlashCommand(command) }
                    })
            }
            if start > 0 || end < matches.count {
                let hidden = matches.count - (end - start)
                gtk_box_append(
                    ptr(column),
                    Gtk.label("… \(hidden) more", css: "row-detail", selectable: false))
            }
        case .arguments(let command, let typed):
            gtk_box_append(
                ptr(column),
                Gtk.label("/\(command.name)", css: "row-title", selectable: false))
            if let hint = command.argumentHint, !hint.isEmpty {
                gtk_box_append(
                    ptr(column), Gtk.label(hint, css: "row-title", selectable: false))
            }
            if !command.details.isEmpty {
                gtk_box_append(
                    ptr(column),
                    Gtk.label(command.details, css: "row-detail", selectable: false))
            }
            if !typed.isEmpty {
                gtk_box_append(
                    ptr(column),
                    Gtk.label(
                        Localized.text("Writing: %@", typed), css: "row-detail",
                        selectable: false))
            }
        case .noMatch(let query):
            gtk_box_append(
                ptr(column),
                Gtk.label(
                    Localized.text("No command named “%@”", query), css: "row-detail",
                    selectable: false))
            if !commands.isEmpty {
                gtk_box_append(
                    ptr(column),
                    completionButton(
                        title: Localized.text("Browse every command"),
                        detail: Localized.text("%@ on this server", "\(commands.count)"),
                        selected: false
                    ) { [weak self] in
                        Gtk.onMain { [weak self] in self?.presentCommandCatalog() }
                    })
            }
        }
        gtk_popover_set_child(ptr(popover), column)
        gtk_popover_popup(ptr(popover))
    }

    private func completionButton(
        title: String, detail: String, selected: Bool, action: @escaping @Sendable () -> Void
    ) -> UnsafeMutablePointer<GtkWidget> {
        let item = gtk_button_new()!
        Gtk.addClass(item, "flat")
        if selected { Gtk.addClass(item, "completion-selected") }
        let lines = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_box_append(ptr(lines), Gtk.label(title, css: "row-title", selectable: false))
        if !detail.isEmpty {
            let label = Gtk.label(detail, css: "row-detail", selectable: false)
            gtk_label_set_max_width_chars(op(label), 64)
            gtk_box_append(ptr(lines), label)
        }
        gtk_button_set_child(ptr(item), lines)
        Gtk.connect(UnsafeMutableRawPointer(item), "clicked", action)
        return item
    }

    /// The greppable catalog surface for Linux — every command this server offers.
    func presentCommandCatalog() {
        dismissCompletion()
        CommandCatalog.present(parent: root, commands: commands) { [weak self] command in
            Gtk.onMain { [weak self] in self?.acceptSlashCommand(command) }
        }
    }

    /// A paste is an attach as much as a paste, so the composer takes the clipboard rather than
    /// letting the text widget take it: files and pictures become chips where they would otherwise
    /// have to be saved to disk and picked back up, and only words go in as words. What this model
    /// cannot be handed is refused by name in the notice line rather than dropped.
    private func pasteIntoComposer() {
        let able = QuickAskAbilities.resolve(
            supportsAttachments: backend?.capabilities.supportsAttachments != false,
            model: chosenModel.flatMap { pick in
                models.first { $0.providerID == pick.providerID && $0.id == pick.modelID }?
                    .capabilities
            })
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
        let buffer = gtk_text_view_get_buffer(ptr(entryView))
        gtk_text_buffer_insert_at_cursor(buffer, text, -1)
        gtk_widget_grab_focus(entryView)
        vim.reset(to: composerText(), cursor: composerCursor(), mode: vim.mode)
    }

    func insertIntoComposer(_ text: String) {
        let buffer = gtk_text_view_get_buffer(ptr(entryView))
        var end = GtkTextIter()
        gtk_text_buffer_get_end_iter(buffer, &end)
        gtk_text_buffer_insert(buffer, &end, text, -1)
        gtk_widget_grab_focus(entryView)
    }

    func composerText() -> String {
        let buffer = gtk_text_view_get_buffer(ptr(entryView))
        var start = GtkTextIter()
        var end = GtkTextIter()
        gtk_text_buffer_get_bounds(buffer, &start, &end)
        guard let raw = gtk_text_buffer_get_text(buffer, &start, &end, 0) else { return "" }
        defer { g_free(raw) }
        return String(cString: raw)
    }

    /// Empties the prompt box and the vim document that shadows it, without touching any stored
    /// draft: called where the pane has already let go of the conversation the text belonged to.
    private func clearComposer() {
        gtk_text_buffer_set_text(gtk_text_view_get_buffer(ptr(entryView)), "", 0)
        lastRecordedDraft = ""
        vim.reset(to: "", cursor: 0, mode: .insert)
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
        guard !text.isEmpty || !outgoing.isEmpty, let conversation else { return }
        let buffer = gtk_text_view_get_buffer(ptr(entryView))
        gtk_text_buffer_set_text(buffer, "", 0)
        if let draftScope { DraftStore.clear(draftScope) }
        vim.reset(to: "", cursor: 0, mode: .insert)
        updateVimBadge()
        if handleSlashCommand(text) { return }
        echoedPrompt = text
        if let state = lastState { apply(state: state, rows: lastFullRows) }
        scrollToBottom()
        attachments = []
        renderAttachments()
        let model = chosenModel
        let effort = chosenEffort
        if Ultracode.invokes(text) || effort == Ultracode.effortLevel {
            ultracodeInFlight = true
        }
        refreshUltracodeAura()
        Task {
            try? await conversation.send(
                text, model: model, reasoningEffort: effort,
                attachments: outgoing.map(\.prompt))
        }
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

    /// Continues a turn the server's machine stopped in the middle of. The work resumes on that
    /// machine, so nothing is sent from here and the card comes down on the server's answer.
    private func resumeInterruptedTurn() {
        guard let conversation else { return }
        Task {
            do {
                try await conversation.resumeInterruptedTurn()
            } catch {
                Gtk.onMain { [weak self] in
                    self?.setNotice(Localized.text("The server could not pick that turn back up."))
                }
            }
        }
    }

    private func dismissInterruptedTurn() {
        guard let conversation else { return }
        Task { try? await conversation.dismissInterruptedTurn() }
    }

    private func attachRows() -> [(String, String?, @Sendable () -> Void)] {
        guard backend?.capabilities.supportsAttachments != false else {
            return [(Localized.text("This server does not take attachments"), nil, {})]
        }
        return [
            (Localized.text("Attach files…"), Localized.text("Up to 8 MB each"),
             { [weak self] in Gtk.onMain { [weak self] in self?.pickAttachments() } }),
            (Localized.text("Paste image"), Localized.text("From the clipboard, as PNG"),
             { [weak self] in Gtk.onMain { [weak self] in self?.pasteImageAttachment() } }),
        ]
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
            guard let data else { return }
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
            guard decoded.bits != 0 else { return }
            Gtk.onMain { [weak self] in
                guard let self else { return }
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

    /// Whether anything on screen still needs a clock: a turn in flight, or a workflow that outlived
    /// it. A background run keeps four agents working for minutes after the turn that launched it
    /// ended, and a card whose elapsed reading froze at launch reads as a hang.
    private var needsTicker: Bool {
        lastState?.status == .running || workflowRuns.contains(where: \.isLive)
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

    func focusTranscript() {
        gtk_widget_grab_focus(transcriptBox)
    }

    /// Everything the settings window can change that is not a colour, applied to this pane.
    /// Compact and dense change what a row *is*, so the transcript is rebuilt rather than
    /// restyled.
    func applyLayoutPreferences() {
        composerHeight = 0
        growComposer()
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
            text: text, commands: commands,
            supportsCompaction: backend?.capabilities.supportsCompaction != false,
            resolvesFromPromptText: backend?.resolvesCommandsFromPromptText == true)
        {
        case .compactPreflight(let instruction):
            host?.presentCompactPreflight(for: self, initialInstruction: instruction)
            return true
        case .run(let command, let arguments):
            guard let conversation else { return false }
            SlashRecents.record(command.name)
            let model = chosenModel
            let effort = chosenEffort
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
            echoedPrompt = "and while you are at it, run the tests"
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
        context.expanded.insert("demo-launch:p")
        refreshWorkflowRuns()
        replaceRows { if case .workflow = $0.kind { return true } else { return false } }
    }

    func driverType(_ text: String) {
        gtk_widget_grab_focus(entryView)
        vim.reset(to: text, cursor: text.count, mode: .insert)
        gtk_text_buffer_set_text(gtk_text_view_get_buffer(ptr(entryView)), text, -1)
    }
}
