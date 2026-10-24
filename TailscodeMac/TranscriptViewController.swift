import AppKit
import os
import CodingAgentKit
import TailscodeCore

/// The conversation, rendered the way a terminal agent renders it: the user's turn behind an
/// accent rule, the agent's answer as plain prose at full measure, and every tool call as one
/// dense line. The transcript is an opaque canvas; the composer, the find bar and the jump pill
/// float over it as glass, and content scrolls underneath them.
@MainActor
final class TranscriptViewController: NSViewController {
    /// Every state the stream delivers, surfaced to the hub: the shortcut engine needs to know
    /// whether an approval is waiting without owning the conversation itself.
    var onState: ((ConversationState) -> Void)?
    /// A floating confirmation, presented by the hub so it clears toasts app-wide.
    var onToast: ((String) -> Void)?
    var onDialToast: ((String) -> Void)?
    /// The board window this pane opened, held because an NSWindowController with nobody keeping
    /// it alive closes the moment the frame that made it returns.
    var designBoard: DesignBoardWindowController?
    var inFlightDesignBoards: Set<String> = []
    /// A click on the status band, routed through the hub — reading the status and steering the
    /// turn are one gesture, and the hub owns the steering.
    var onBandAction: ((StatusFacts.Action) -> Void)?
    /// An answered chooser row: which server, which chat, or a new one — acted on by the hub,
    /// which owns the servers and the minting of sessions.
    var onChooserAction: ((PaneChooserAction) -> Void)?
    /// Live quotas for used-up surfaces — the same numbers the sidebar footer shows.
    var quotasForStatus: (() -> [UsageQuota])?
    /// A turn still in flight when this pane moves on is handed to the hub's background watcher,
    /// so the row keeps its WORKING seat until the turn settles.
    var onBackgroundWatch: ((SessionEntry, any CodingAgentBackend) -> Void)?
    var onStopWatch: ((LiveKey) -> Void)?

    /// Drag-a-chat-into-this-pane hooks, owned by the tiling host so every pane is a drop target.
    var onDragEntered: ((NSDraggingInfo) -> Bool)?
    var onDragUpdated: ((NSDraggingInfo) -> NSDragOperation)?
    var onDragExited: (() -> Void)?
    var onDragPerform: ((NSDraggingInfo) -> Bool)?
    /// What dragging this pane's identity strip carries, set by the tiling host that knows which
    /// pane this is.
    var paneMovePayload: (() -> PaneMovePayload?)?
    /// What the strip says without its activity glyph: the name a divider gives this pane when it
    /// introduces itself to a screen reader.
    var paneName: String { identityLabel.stringValue }

    let scrollView = NSScrollView()
    let canvas = TranscriptViewController.page()
    var rowColumn = TranscriptColumn()
    let pendingStack = FillingStack()
    let earlierButton = RowKit.ActionButton(title: "") {}
    let statusBand = StatusBandView()
    /// What a popover opened from a band fact points at.
    var bandAnchor: NSView { statusBand }
    var bandGlass: NSView?
    let authBanner = NSStackView()
    var authGlass: NSView?
    let composer = ComposerView()
    lazy var calls = PaneCallController(host: callHost)
    let findBar = FindBar()
    let jumpChip = SymbolChip()
    /// How many rows the page held when the reader last left its end, so the jump control can say
    /// how many arrived while they were away. Nil while they are at the end.
    var rowsAtDeparture: Int?
    let emptyLabel = NSTextField(wrappingLabelWithString: "")
    let starters = NSStackView()
    let starterFlow = StarterFlow()
    let chooserView = ChooserView()
    let welcomeView = EmptyWelcomeView()
    var chooser: PaneChooser?
    var composerGlass: NSView?
    var jumpGlass: NSView?

    let context = TranscriptContext()
    let rowBuilder = TranscriptRowBuilder()
    /// This pane's brains: the turns the conversation holds read into heads, and the person's
    /// choice of which one is open.
    let brains = BrainStore()
    /// What the rows are given, for a harness that builds a view the way the pane does.
    var driveContext: TranscriptContext { context }
    let hoverBar = MessageHoverBar()
    let railController = LinkRailController()
    let identityLabel = NSTextField(labelWithString: "")
    let identityPin = NSImageView()
    let identityAlso = NSTextField(labelWithString: "")
    let identityBadge = ActivityBadgeView(pointSize: 11)
    var identityGlass: NSView?
    var identityStrip: NSView?
    /// Where the page begins. With no strip it is the top of the pane and the toolbar's own safe
    /// area is a content inset, so the transcript scrolls under the glass bar; with a strip it is
    /// the strip's foot, so no line of the conversation ever runs under the pane's name.
    private var scrollTop: NSLayoutConstraint!
    /// What a slot took off the screen when it claimed the pane, so putting a conversation back
    /// shows exactly what was showing. Half this chrome owns its own visibility — an empty
    /// completion popover, a find bar nobody opened — and unhiding it wholesale reveals it.
    var furnitureHidden: [NSView] = []

    var conversation: AgentConversation?
    /// This pane's hold on the process's one live conversation for its chat. States land in the
    /// lease's latest-wins mailbox and the frame's drain applies the newest; a parked or closed
    /// pane holds none.
    var lease: LiveLease?
    var drainToken: DrainToken?
    var attachedKey: LiveKey?
    var lastSequence: UInt64 = 0
    /// Frames this pane applied, and states the drain skipped because a newer one had already
    /// landed — the coalescing, counted for the selftest and the bench.
    var appliedFrames = 0
    var skippedFrames = 0
    /// Main-thread time spent building and applying those frames.
    var applyTime: TimeInterval = 0
    /// Frames the wave painted on its own clock, and the main-thread time they took.
    var cascadeFrames = 0
    var cascadeTime: TimeInterval = 0
    /// The drain's name for this pane's slot.
    let paneID = PaneID()
    /// Everything this pane started that has to stop when it stops being alive: the lease, the
    /// drain slot, every clock and observer. Shutting the pane down and parking it both end it.
    let lifetime = PaneLifetime()
    var findIndexed = true
    var findIndexToken = 0
    var lifetimeArmed = false
    var scrollObserved = false
    /// Hidden from the reader — zoomed away, or the window not visible — so it owns no stream and
    /// no clock, and its last rows stay as they were.
    var isParked = false
    var isFocusedPane = false
    var backend: (any CodingAgentBackend)?
    var entry: SessionEntry?
    #if !TAILSCODE_MAS
        /// What this pane is watching instead of talking, when it is a video slot rather than a
        /// chat.
        var video: VideoSlotView?
    #endif
    /// What this pane is reading instead of talking, when it is a browser slot rather than a chat.
    var page: WebSlotView?
    /// What this pane is painting instead of talking, when it is a draw slot rather than a chat.
    var draw: DrawSlotView?
    /// What this pane is streaming instead of talking, when it is a preview slot rather than a chat.
    var preview: PreviewSlotView?
    /// Told to the window when a preview pane composes a request for the agent, which is a
    /// conversation's to send and not the pane's.
    var onPreviewAskAgent: ((String) -> Void)?
    /// Told to the hub when a slot starts, stops, or learns its stream's title, so the layout is
    /// written back exactly as an opened conversation writes it back.
    var onVideoChanged: (() -> Void)?
    var lastState: ConversationState?
    /// The facts the band last drew, kept so the chat list can borrow the step the turn is on
    /// rather than scanning the transcript for it a second time.
    var lastFacts: StatusFacts?
    var wasRunningForHaptics = false
    var hapticPermissionID: String?
    var hapticQuestionID: String?

    /// What this pane is showing, read by the hub and the tiling host: the focused pane's entry
    /// is the window's "current chat", and a restored layout rebinds by these.
    var currentEntry: SessionEntry? { entry }
    /// Whether the server behind this pane can be asked to compact, for a surface that offers it.
    var canCompact: Bool { backend?.capabilities.supportsCompaction != false }
    var currentBackend: (any CodingAgentBackend)? { backend }
    var currentState: ConversationState? { lastState }

    /// What this pane knows first-hand about the conversation it is streaming, for the chat list's
    /// WORKING. A turn stopped on a permission or a question is still a turn in flight and is the
    /// one the person most needs to find, so it outranks merely running; a failure is only
    /// reported once nothing is running, and the step is the tool the band is already naming.
    /// Nothing is inferred here that the pane's own state does not already say.
    /// A pane that has taken a chat and has not heard anything about it yet is watching, not
    /// reporting that nothing is running: the row it just took over from the background watcher
    /// must not settle on the difference between two witnesses.
    var presence: SessionPresence {
        guard let state = lastState else { return entry == nil ? .unobserved : .unsettled }
        return SessionPresence.reading(state, step: lastFacts?.runningTool)
    }

    let cascade = CascadePainter()
    var renderedRows: [TranscriptRow] = []
    var rowViews: [NSView] = []
    /// Keys that have already made their entrance. A row is rebuilt whenever its value changes —
    /// a thought growing its word count, a tool call reaching its result — and fading a rebuild in
    /// from nothing is a flicker, not an arrival. Only the first sight of a key animates.
    var enteredRows: Set<String> = []
    /// The row the wave last had its hands on, kept until it has actually been handed back whole.
    var lastStreamedKey: String?
    /// The rendering the wave last painted in full. A frame that paints the same rendering again
    /// changes its colours and nothing else, so the label is repainted without being measured.
    var waveMeasured: NSAttributedString?
    /// The paint the live row last had and what that paint was made at, so a frame changes the
    /// characters that moved and a repaint of the same revision changes nothing.
    var waveBuffer: CascadePaintBuffer?
    var wavePainted: (key: String, revision: Int, view: ObjectIdentifier, rendered: ObjectIdentifier)?
    /// A row the wave gave up on. It is not taken back: restarting a reveal that already snapped to
    /// whole would rewind the answer under the reader.
    var abandoned: String?
    /// The clock that keeps trying a settle nothing else would ever try again. The wave lets go of
    /// its display link and its watchdog in the same breath, and a turn that ended sends no more
    /// states, so a settle that failed at that moment has no other road back.
    var tailRepair: Timer?
    /// The row the repair clock is trying to hand back, which is not always the row the wave last
    /// held: a turn can end and the next one start writing before a failed settle has landed.
    var repairKey: String?
    var lastFullRows: [TranscriptRow] = []
    var windowLimit = 400
    var rowTailMessages = 300
    var placeholderShown = true
    var currentPlaceholder: String?
    var pendingReveal = false
    var fillComplete = false
    var isFillingInChunks = false
    var followsBottom = true {
        didSet {
            if followsBottom {
                rowsAtDeparture = nil
            } else if oldValue {
                rowsAtDeparture = renderedRows.count
            }
            syncJumpPill()
        }
    }
    var isAutoScrolling = false
    var pinScheduled = false
    /// What this device has written and the server has not echoed back, with what became of
    /// each. The ledger and every word it wears are Core's; this owns the clock and the sending.
    var pending = PendingSendLedger()
    /// Messages a spent provider window stopped, and the moment each goes again. The policy and
    /// every word are Core's; this owns the one clock that fires them and the copy on disk.
    var resume = ResumeLedger()
    var resumeClock: Task<Void, Never>?
    /// How many times this conversation has already been sent into the wall and bounced. A plan
    /// that fires and dies produces a *fresh* failure, and reading each fresh failure as a first
    /// attempt is how a bounded retry becomes an unbounded one — so the count lives here, beside
    /// the conversation, and only a turn that is not in a failed state clears it.
    var resumeAttempts = 0
    var pendingFirstMessage:
        (sessionID: String, send: QuickAskSend, attachments: [PendingAttachment])?
    var pendingSignature = "\u{0}"
    var compactingElapsed: NSTextField?
    /// The rows of the last few chats this pane showed, keyed as every other store keys a chat
    /// (`SessionPinStore.key`): a session id alone is not unique across servers.
    var sessionRows: [String: [TranscriptRow]] = [:]
    var sessionRowOrder: [String] = []
    var inFlightImages: Set<String> = []
    /// Pictures whose bytes arrived and would not decode — an SVG, a truncated file — so their row
    /// settles as a filename and is not asked for again. A fetch that failed on the network is not
    /// listed: the next time the row is built it asks again. Forgotten with the chat.
    var refusedImages: Set<String> = []
    /// Pictures a row has asked for and the transcript has not yet judged worth fetching: held here
    /// until the reader is within a screen of the row that wants them.
    var wantedImages: [String: FileReference] = [:]
    var imageSweepScheduled = false
    var inFlightSubagents: Set<String> = []
    var answeringQuestions: Set<String> = []
    var findMatches: [Int] = []
    var findCursor = 0
    var highlightedView: NSView?
    /// What the highlighted row's own layer said before the mark was written over it. A row view is
    /// often the card itself — a code block's ground and its corner, a seam's border — so clearing
    /// the mark by writing nil and zero strips the card rather than the mark.
    var highlightRestore:
        (background: CGColor?, border: CGColor?, width: CGFloat, radius: CGFloat)?
    var agents: [SubagentSummary] = []
    var usage: AgentUsage?
    /// What the whole conversation has cost. The server's own account when it keeps one, else what
    /// the transcript itself says — and never erased by a poll that came back with nothing, which
    /// is what left the chart on the one machine the session was started from.
    var spendReading = SpendReading()
    var spend: SessionSpend? { spendReading.value }
    /// Which branch this conversation's work is landing on, read on the same slow poll. Nil for a
    /// server that cannot read a repository, which is how the band knows to say nothing at all.
    var git: GitState?
    /// The same backend the pane already talks to, when it can answer questions about a
    /// repository. Exposed instead of the backend itself: the window needs the one capability.
    var gitBackend: (any GitObservingBackend)? { backend as? any GitObservingBackend }
    /// How full the model's window is, re-read whenever the transcript changes and offered to the
    /// band and to the panel behind it.
    var transcriptFill: ContextFill?
    /// The transcript's fill read against the model the next send will run on, so a model switch
    /// re-sizes the ring at once.
    var contextFill: ContextFill?
    var countedMessages = -1
    var notice: String?
    var tickerTask: Task<Void, Never>?
    var workflowRuns: [WorkflowRun] = []
    let workflowFold = WorkflowRunFold()
    var agentStreamTask: Task<Void, Never>?
    var agentStreamSessionID: String?

    override func loadView() {
        let container = DropForwardingView()
        container.owner = self
        container.wantsLayer = true
        container.layer?.backgroundColor = MacTheme.Color.canvas.cgColor

        configureCanvas()
        configureScroll()
        container.addSubview(scrollView)

        emptyLabel.stringValue = Localized.text("Pick a conversation")
        emptyLabel.font = MacTheme.Ramp.font(.panelLabel)
        emptyLabel.textColor = MacTheme.Color.secondaryLabel
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(emptyLabel)
        configureStarters()
        container.addSubview(starters)

        chooserView.isHidden = true
        chooserView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(chooserView)
        container.addSubview(welcomeView)

        let identity = configureIdentityStrip()
        container.addSubview(identity)
        identityGlass = identity

        let glass = configureComposerLayer()
        container.addSubview(glass)
        composerGlass = glass

        container.addSubview(composer.completion)

        let jump = configureJumpPill()
        container.addSubview(jump)
        jumpGlass = jump

        configureFindBar()
        container.addSubview(findBar)

        hoverBar.install(in: container, over: scrollView, canvas: canvas)
        hoverBar.locate = { [weak self] point in self?.messageTarget(at: point) }
        hoverBar.message = { [weak self] id in self?.lastState?.messages.first { $0.id == id } }
        hoverBar.offersUndo = { [weak self] id in self?.context.offersUndo?(id) ?? false }
        hoverBar.undo = { [weak self] id in self?.context.confirmUndo?(id) }
        hoverBar.offersBranch = { [weak self] id in self?.composer.offersBranch(from: id) ?? false }
        hoverBar.branch = { [weak self] id in self?.composer.openBranchChooser(from: id) }
        hoverBar.toast = { [weak self] text in self?.onToast?(text) }
        context.copyAnswer = { [weak self] rowKey in self?.copyAnswer(ofRowKey: rowKey) }
        hoverBar.locateCode = { [weak self] point in self?.codeTarget(at: point) }
        hoverBar.blocked = { [weak self] in self?.railController.isOpen ?? false }

        railController.install(in: container, over: scrollView, canvas: canvas)
        railController.locate = { [weak self] point in self?.railLine(at: point) }
        railController.lineForKey = { [weak self] key in self?.railLine(forKey: key) }
        railController.toast = { [weak self] text in self?.onToast?(text) }
        context.activateRail = { [weak self] line, viaKeyboard in
            self?.railController.activate(line, viaKeyboard: viaKeyboard)
        }

        scrollTop = scrollView.topAnchor.constraint(equalTo: container.topAnchor)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollTop,
            scrollView.bottomAnchor.constraint(equalTo: container.bottomAnchor),

            glass.leadingAnchor.constraint(
                equalTo: container.leadingAnchor, constant: MacTheme.Spacing.l),
            glass.trailingAnchor.constraint(
                equalTo: container.trailingAnchor, constant: -MacTheme.Spacing.l),
            glass.bottomAnchor.constraint(
                equalTo: container.bottomAnchor, constant: -MacTheme.Spacing.m),

            composer.completion.bottomAnchor.constraint(
                equalTo: glass.topAnchor, constant: -MacTheme.Spacing.s),
            composer.completion.leadingAnchor.constraint(
                equalTo: glass.leadingAnchor, constant: MacTheme.Spacing.m),
            composer.completion.trailingAnchor.constraint(
                lessThanOrEqualTo: glass.trailingAnchor, constant: -MacTheme.Spacing.m),

            jump.trailingAnchor.constraint(
                equalTo: container.trailingAnchor, constant: -MacTheme.Spacing.xl),
            jump.bottomAnchor.constraint(equalTo: glass.topAnchor, constant: -MacTheme.Spacing.m),

            findBar.topAnchor.constraint(
                equalTo: container.safeAreaLayoutGuide.topAnchor, constant: MacTheme.Spacing.s),
            findBar.trailingAnchor.constraint(
                equalTo: container.trailingAnchor, constant: -MacTheme.Spacing.l),

            identity.topAnchor.constraint(
                equalTo: container.safeAreaLayoutGuide.topAnchor, constant: MacTheme.Spacing.s),
            identity.leadingAnchor.constraint(
                equalTo: container.leadingAnchor, constant: MacTheme.Spacing.l),
            identity.trailingAnchor.constraint(
                lessThanOrEqualTo: container.trailingAnchor, constant: -MacTheme.Spacing.l),

            emptyLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            emptyLabel.widthAnchor.constraint(
                lessThanOrEqualTo: container.widthAnchor, constant: -MacTheme.Spacing.xl * 2),

            starters.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            starters.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            starters.widthAnchor.constraint(
                lessThanOrEqualTo: container.widthAnchor, constant: -MacTheme.Spacing.xl * 2),
            fillWidth(of: starters, in: container),

            chooserView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            chooserView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            chooserView.widthAnchor.constraint(
                lessThanOrEqualTo: container.widthAnchor, constant: -MacTheme.Spacing.xl * 2),
            chooserView.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
            chooserView.leadingAnchor.constraint(
                greaterThanOrEqualTo: container.leadingAnchor, constant: MacTheme.Spacing.l),

            welcomeView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            welcomeView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            welcomeView.widthAnchor.constraint(
                lessThanOrEqualTo: container.widthAnchor, constant: -MacTheme.Spacing.xl * 2),
            welcomeView.widthAnchor.constraint(lessThanOrEqualToConstant: 460),
        ])
        identityBesideFind = identity.trailingAnchor.constraint(
            lessThanOrEqualTo: findBar.leadingAnchor, constant: -MacTheme.Spacing.m)
        identityBesideFind?.isActive = !findBar.isHidden
        view = container
        wireContext()
        beginLifetime()
    }

    /// The pane's name gives way to the find bar only while the bar is open; a hidden bar still
    /// has its width, and held to it the name of a narrow pane was cut to nothing.
    var identityBesideFind: NSLayoutConstraint?

    /// The pane's own name, on the same material as the rest of the floating layer. It is a control
    /// above the transcript rather than a caption inside it, and on bare canvas the prose that
    /// scrolls under it overprints it glyph for glyph.
    private func configureIdentityStrip() -> NSView {
        identityLabel.font = MacTheme.Ramp.font(.paneIdentity)
        identityLabel.textColor = MacTheme.Color.onGlassSecondary
        identityLabel.lineBreakMode = .byTruncatingMiddle
        identityLabel.setContentCompressionResistancePriority(.init(300), for: .horizontal)
        identityPin.image = NSImage(
            systemSymbolName: "pin.fill", accessibilityDescription: Localized.text("Keep live"))
        identityPin.contentTintColor = MacTheme.Color.onGlassSecondary
        identityPin.isHidden = true
        identityPin.setContentHuggingPriority(.required, for: .horizontal)
        identityAlso.font = MacTheme.Ramp.font(.paneIdentity)
        identityAlso.textColor = MacTheme.Color.onGlassSecondary
        identityAlso.isHidden = true
        identityAlso.setContentCompressionResistancePriority(.init(250), for: .horizontal)
        identityBadge.isHidden = true
        let strip = PaneStripView(views: [identityBadge, identityPin, identityLabel, identityAlso])
        strip.payload = { [weak self] in self?.paneMovePayload?() }
        strip.spacing = MacTheme.Spacing.xs
        strip.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.xs, left: MacTheme.Spacing.s, bottom: MacTheme.Spacing.xs,
            right: MacTheme.Spacing.s)
        strip.translatesAutoresizingMaskIntoConstraints = false
        let glass = MacTheme.glass(around: strip, cornerRadius: MacTheme.Radius.control)
        glass.isHidden = true
        strip.isHidden = true
        identityStrip = strip
        return glass
    }

    /// The scroll view owns its insets so content can run underneath the floating glass: the top
    /// inset tracks the toolbar and the identity strip, the bottom one tracks the composer capsule.
    override func viewDidLayout() {
        super.viewDidLayout()
        let bottom = (composerGlass?.frame.height ?? 0) + MacTheme.Spacing.m + MacTheme.Spacing.l
        let safe = view.safeAreaInsets.top + MacTheme.Spacing.s
        let strip: CGFloat =
            identityGlass.map { $0.isHidden ? 0 : $0.fittingSize.height + MacTheme.Spacing.s } ?? 0
        let foot = strip > 0 ? safe + strip : 0
        if scrollTop.constant != foot { scrollTop.constant = foot }
        let top = strip > 0 ? CGFloat(0) : safe
        preview?.topClearance = strip > 0 ? foot : safe
        chromeInsets = NSEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
        applyInsets()
        railController.reposition()
    }

    /// What the floating chrome covers, kept apart from the room the fresh canvas adds under the
    /// transcript so the two can change independently.
    var chromeInsets = NSEdgeInsets()

    func applyInsets() {
        let insets = NSEdgeInsets(
            top: chromeInsets.top, left: 0, bottom: chromeInsets.bottom + canvasPadding, right: 0)
        guard scrollView.contentInsets.bottom != insets.bottom
            || scrollView.contentInsets.top != insets.top
        else { return }
        scrollView.contentInsets = insets
        if followsBottom, canvasHold == nil { schedulePinCorrector() }
    }

    /// The room held under the transcript so a just-sent prompt can rest at the top of the window
    /// with the answer streaming onto an empty page under it. Zero whenever nothing is rising.
    var canvasPadding: CGFloat = 0

    /// Where the prompt the canvas is holding room for stands in the canvas, re-measured on every
    /// change of the page rather than captured when it rose: the echo is one card and the server's
    /// account of the same send is a row per picture and one for the words, and a place frozen at
    /// the first of those counts the room from somewhere the prompt no longer is.
    var canvasHold: (top: CGFloat, height: CGFloat)? {
        didSet { syncJumpPill() }
    }

    /// The anchor the canvas rose to, followed across the swap from this device's echo to the
    /// server's own account of the same send.
    var canvasKey: String?
    /// Where in the transcript that send was drawn. A pending row discarded rather than reconciled
    /// leaves an older prompt as the last thing the person said, and a canvas that fell back to
    /// that one would rise to the wrong page.
    var canvasFloor = 0
    /// The rise is being set up: the room has been asked for but the motion is not finished, and
    /// nothing may retire the canvas until it is.
    var canvasRising = false
    /// Whether the prompt is still being kept at the headroom. It is put there and held there:
    /// every reason the one motion misses — a row measured after it is drawn, the room allocated a
    /// pass late, the server's rows replacing this device's — happens after the motion is over.
    var canvasPinned = false
    /// Guards the pin against the layout its own scroll provokes.
    var isPinningCanvas = false
    var canvasRiseDeadline: CFTimeInterval?

    /// When the band's facts — the branch, the spend, the agents — were last asked for. A chat that
    /// was idle when the Mac slept is still idle when it wakes, and only a running turn polls, so
    /// coming back used to leave the band as stale as it was the night before; coming back to the
    /// app is also something a person does dozens of times an hour, so a fresh reading is left
    /// alone.
    var factsReadAt: Date?

    var isPreviewing: Bool { preview != nil }
    var previewTarget: PreviewTarget? { preview?.target }
    var previewSummary: String? { preview?.summary }
    var previewView: PreviewSlotView? { preview }

    var isDrawing: Bool { draw != nil }
    var drawEndpoint: ImageGenEndpoint? { draw?.endpoint }
    var drawSummary: String? { draw?.summary }

    var isBrowsing: Bool { page != nil }
    var webSummary: String? { page?.summary }

    #if TAILSCODE_MAS
        let isWatching = false
    #else
        var isWatching: Bool { video != nil }
        var videoTarget: VideoTarget? { video?.target }
        var videoSummary: String? { video?.summary }

        /// True while a slot is still asking what to watch. The board that asks lives under a text
        /// field, so its keys arrive in the insert context and the window has to offer them anyway.
        var isChoosingStream: Bool { video?.isAsking == true }

        /// A slot answers its own keys while it is focused; everything it does not claim goes on
        /// to the shortcut table, so the chat panes lose nothing to a slot in the grid. While it
        /// is still asking, the keys belong to the board rather than to the player it does not
        /// have yet.
        func handleVideoChord(_ chord: KeyChord) -> Bool {
            guard let video else { return false }
            guard !video.isAsking else { return video.handleBoard(chord) }
            guard let command = VideoCommand.command(for: chord) else { return false }
            video.handle(command)
            return true
        }
    #endif

    /// The governor's row window for this pane while it is a full peer; nil until a decision
    /// names one.
    var peerRowWindow: Int?

    /// Whether the window's live resize has asked this pane to keep its rows at the width they
    /// were measured at: a peer takes its new frame at once and re-measures its rows once, when
    /// the resize ends, rather than on every step of the drag.
    var defersRowWidth = false
    var heldCanvasWidth: NSLayoutConstraint?

    /// Whether the pane holds any row views, for the selftest that proves a demoted pane let them go.
    var holdsRows: Bool { !rowViews.isEmpty || !keptPages.isEmpty }

    /// Messages waiting in this chat's queue, as this pane last read them.
    var queuedCount: Int { queueDisplay.count }

    /// Whether this pane may take a streaming row up for the reveal: only the focused one.
    var revealsAnswers: Bool { MotionBudget.reveals(focused: isFocusedPane) }

    /// The canvas's width as the clip's, released while a live resize holds the rows still.
    var canvasWidth: NSLayoutConstraint?

    /// The control, for a harness that proves what it says.
    var jumpControl: SymbolChip { jumpChip }

    /// The prompt is on screen before the server has heard of it. A busy bridge can take seconds
    /// to answer, and a composer that empties into silence reads as a hang.
    /// Prompts written while a turn was running, held here rather than handed to the server so
    /// they can still be reworded, reordered or taken back — which is the whole point of them
    /// being a queue and not a send.
    var queue: ConversationQueue?
    /// Which waiting message the composer is rewriting. A message taken back and sent again would
    /// land at the end of the queue, which is not editing but deleting and re-adding.
    var editingQueued: String?

    /// Guards the drain against re-entering itself: `drainQueue` runs at the end of `apply`, and
    /// sending re-applies. Re-rendering from inside the render is what makes a transcript write
    /// itself twice — the second pass adopts the tail the first one is still revealing.
    var draining = false

    /// The stretch after a send during which the server still reads idle. The queue waits it out,
    /// or every message written during a turn goes at once and the agent answers only the last.
    var handoff = TurnHandoff()
    var handoffWakeGeneration = 0

    /// Whether this transcript waits out a spent window on the person's behalf.
    var resumeEnabled: Bool { AutoResumeSetting.isEnabled }

    /// The transcript renders a tail window, not the whole history: a view per row is fine for
    /// four hundred rows and a multi-second lockup for four thousand. The rest waits behind one
    /// button that widens the window — the full rows are kept, so nothing is refetched.
    var lastReadMark = Date.distantPast
    var wasRunningWhenMarked = false

    /// The one moment a pending row's line changes on its own — a send still on the wire past
    /// `slowAfter`, a machine that has not started past `quietAfter` — so the row is redrawn then
    /// rather than on a clock ticking under words that have nothing to say.
    var captionWake: Task<Void, Never>?

    /// A press this device has made on the cut-off card and has no answer to yet.
    ///
    /// The server's word travels a tailnet and may never arrive at all, so what was asked for is
    /// this device's own account until something answers it — never mistaken for the server having
    /// agreed, which is a different state with different words.
    var interruptionPress: InterruptedTurnPress?
    var revertOperation: RevertOperation?
    /// The exact words a successful undo put in the composer, remembered so a later Restore can
    /// tell an untouched offer from a sentence the person kept writing on top of it.
    var revertComposerFill: String?

    /// The clock a provider-retry card wakes on: never once a second, only at the exact moment
    /// `ProviderRetryReading` says the words themselves change. Armed on every state and every
    /// self-wake, so a card that ticked down to its last second re-arms itself for the next one.
    var retryWake: Task<Void, Never>?

    var bandShown = false
    var bandFade = 0

    var chooserShown: Bool { chooser != nil }
    var chooserServerID: String? { chooser?.serverID }

    var shownWelcome: EmptyWelcome? { welcomeView.isHidden ? nil : welcomeView.shown }

    /// The click on a chat and the moment its words are on screen, measured end to end: from the
    /// open to the first batch revealed, or to a kept page put back. A chat that opens on its
    /// placeholder keeps the journey going until its rows arrive, because that wait is the one a
    /// person sat through.
    var openJourney: (started: CFTimeInterval, interval: OSSignpostIntervalState)?

    /// A click is a press and a release, and a row rebuilt between the two never becomes one.
    ///
    /// A run row's value changes on every arrival — a tool's status, its output, a thought still
    /// being written inside it — so the view under the pointer is destroyed and remade dozens of
    /// times a second while a turn runs, and AppKit resets a click recognizer whose view left the
    /// window: the disclosure the reader is trying to open is gone before their finger comes up.
    /// The rows are held for the length of the press and applied on the release, so a click always
    /// lands on the row it was aimed at and the transcript catches up a tenth of a second later.
    var heldRows: [TranscriptRow]?
    /// Rows a cache arrival asked to redraw while the pointer was down, redrawn on the release.
    var heldReplacements: Set<String> = []
    var holdMonitor: Any?
    var holdGeneration = 0

    var keptPages: [String: KeptPage] = [:]
    var keptOrder: [String] = []

    /// When the follow last moved, so a glide knows how much time one frame was.
    var followClock: CFTimeInterval?

    /// A step asked for while every match sits in rows the window has not drawn: the window widens
    /// to take them in, and the step lands on the nearest one once they are laid out. The count
    /// used to say "3 in earlier rows" while Next and Previous did nothing at all.
    var findStepAfterWidening = false
}
