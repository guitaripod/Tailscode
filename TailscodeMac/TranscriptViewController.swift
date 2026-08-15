import AppKit
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
    /// A click on the status band, routed through the hub — reading the status and steering the
    /// turn are one gesture, and the hub owns the steering.
    var onBandAction: ((StatusFacts.Action) -> Void)?
    /// An answered chooser row: which server, which chat, or a new one — acted on by the hub,
    /// which owns the servers and the minting of sessions.
    var onChooserAction: ((PaneChooserAction) -> Void)?
    /// Live quotas for used-up surfaces — the same numbers the sidebar footer shows.
    var quotasForStatus: (() -> [UsageQuota])?
    /// A turn still in flight when this pane moves on is handed to the hub's background watcher,
    /// so the row keeps its LIVE NOW seat until the turn settles.
    var onBackgroundWatch: ((AgentConversation, SessionEntry) -> Void)?
    var onStopWatch: ((String) -> Void)?

    /// Drag-a-chat-into-this-pane hooks, owned by the tiling host so every pane is a drop target.
    var onDragEntered: ((NSDraggingInfo) -> Bool)?
    var onDragUpdated: ((NSDraggingInfo) -> NSDragOperation)?
    var onDragExited: (() -> Void)?
    var onDragPerform: ((NSDraggingInfo) -> Bool)?

    private let scrollView = NSScrollView()
    private let canvas = FillingStack()
    private let rowsStack = FillingStack()
    private let pendingStack = FillingStack()
    private let earlierButton = RowKit.ActionButton(title: "") {}
    private let statusBand = StatusBandView()
    /// What a popover opened from a band fact points at.
    var bandAnchor: NSView { statusBand }
    private var bandGlass: NSView?
    private let authBanner = NSStackView()
    private var authGlass: NSView?
    let composer = ComposerView()
    private let findBar = FindBar()
    private let jumpButton = RowKit.ActionButton(title: "") {}
    private let emptyLabel = NSTextField(wrappingLabelWithString: "")
    private let chooserView = ChooserView()
    private var chooser: PaneChooser?
    private var composerGlass: NSView?
    private var jumpGlass: NSView?

    private let context = TranscriptContext()
    private let rowBuilder = TranscriptRowBuilder()
    private let identityLabel = NSTextField(labelWithString: "")
    private var identityGlass: NSView?
    /// What a slot took off the screen when it claimed the pane, so putting a conversation back
    /// shows exactly what was showing. Half this chrome owns its own visibility — an empty
    /// completion popover, a find bar nobody opened — and unhiding it wholesale reveals it.
    private var furnitureHidden: [NSView] = []

    private var conversation: AgentConversation?
    private var streamTask: Task<Void, Never>?
    private var backend: (any CodingAgentBackend)?
    private var entry: SessionEntry?
    /// What this pane is watching instead of talking, when it is a video slot rather than a chat.
    private var video: VideoSlotView?
    /// What this pane is reading instead of talking, when it is a browser slot rather than a chat.
    private var page: WebSlotView?

    /// Told to the hub when a slot starts, stops, or learns its stream's title, so the layout is
    /// written back exactly as an opened conversation writes it back.
    var onVideoChanged: (() -> Void)?
    private var lastState: ConversationState?
    /// The facts the band last drew, kept so the chat list can borrow the step the turn is on
    /// rather than scanning the transcript for it a second time.
    private var lastFacts: StatusFacts?
    private var wasRunningForHaptics = false
    private var hapticPermissionID: String?
    private var hapticQuestionID: String?

    /// What this pane is showing, read by the hub and the tiling host: the focused pane's entry
    /// is the window's "current chat", and a restored layout rebinds by these.
    var currentEntry: SessionEntry? { entry }
    var currentBackend: (any CodingAgentBackend)? { backend }
    var currentState: ConversationState? { lastState }

    /// What this pane knows first-hand about the conversation it is streaming, for the chat list's
    /// LIVE NOW. A turn stopped on a permission or a question is still a turn in flight and is the
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
    private(set) var renderedRows: [TranscriptRow] = []
    private(set) var rowViews: [NSView] = []
    /// Keys that have already made their entrance. A row is rebuilt whenever its value changes —
    /// a thought growing its word count, a tool call reaching its result — and fading a rebuild in
    /// from nothing is a flicker, not an arrival. Only the first sight of a key animates.
    private var enteredRows: Set<String> = []
    /// The row the wave last had its hands on, kept until it has actually been handed back whole.
    var lastStreamedKey: String?
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
    private(set) var lastFullRows: [TranscriptRow] = []
    private var lastFullCount = 0
    private var windowLimit = 400
    private var rowTailMessages = 300
    var placeholderShown = true
    private var currentPlaceholder: String?
    private var pendingReveal = false
    private var fillComplete = false
    private var isFillingInChunks = false
    var followsBottom = true
    private var isAutoScrolling = false
    private var pinScheduled = false
    private var unseenRows = 0
    private var echoedPrompt: String?
    private var pendingFirstMessage:
        (sessionID: String, text: String, attachments: [PendingAttachment])?
    private var pendingSignature = "\u{0}"
    private var compactingElapsed: NSTextField?
    private var sessionRows: [String: [TranscriptRow]] = [:]
    private var sessionRowOrder: [String] = []
    private var inFlightImages: Set<String> = []
    /// Pictures a row has asked for and the transcript has not yet judged worth fetching: held here
    /// until the reader is within a screen of the row that wants them.
    private var wantedImages: [String: FileReference] = [:]
    private var imageSweepScheduled = false
    private var inFlightSubagents: Set<String> = []
    private var findMatches: [Int] = []
    private var findCursor = 0
    private var highlightedView: NSView?
    /// What the highlighted row's own layer said before the mark was written over it. A row view is
    /// often the card itself — a code block's ground and its corner, a seam's border — so clearing
    /// the mark by writing nil and zero strips the card rather than the mark.
    private var highlightRestore:
        (background: CGColor?, border: CGColor?, width: CGFloat, radius: CGFloat)?
    private var agents: [SubagentSummary] = []
    private var usage: AgentUsage?
    /// What the whole conversation has cost. The server's own account when it keeps one, else what
    /// the transcript itself says — and never erased by a poll that came back with nothing, which
    /// is what left the chart on the one machine the session was started from.
    private var spendReading = SpendReading()
    var spend: SessionSpend? { spendReading.value }
    /// Which branch this conversation's work is landing on, read on the same slow poll. Nil for a
    /// server that cannot read a repository, which is how the band knows to say nothing at all.
    private(set) var git: GitState?
    /// The same backend the pane already talks to, when it can answer questions about a
    /// repository. Exposed instead of the backend itself: the window needs the one capability.
    var gitBackend: (any GitObservingBackend)? { backend as? any GitObservingBackend }
    private var contextEstimate: Int?
    private var countedMessages = -1
    private var notice: String?
    private var turnStartedAt: Date?
    private var tickerTask: Task<Void, Never>?
    private var workflowRuns: [WorkflowRun] = []
    private var agentStreamTask: Task<Void, Never>?
    private var agentStreamSessionID: String?

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

        chooserView.isHidden = true
        chooserView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(chooserView)

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

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: container.topAnchor),
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
                lessThanOrEqualTo: findBar.leadingAnchor, constant: -MacTheme.Spacing.m),

            emptyLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            emptyLabel.widthAnchor.constraint(
                lessThanOrEqualTo: container.widthAnchor, constant: -MacTheme.Spacing.xl * 2),

            chooserView.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            chooserView.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            chooserView.widthAnchor.constraint(
                lessThanOrEqualTo: container.widthAnchor, constant: -MacTheme.Spacing.xl * 2),
            chooserView.widthAnchor.constraint(lessThanOrEqualToConstant: 520),
            chooserView.leadingAnchor.constraint(
                greaterThanOrEqualTo: container.leadingAnchor, constant: MacTheme.Spacing.l),
        ])
        view = container
        wireContext()
        observeScrolling()
    }

    /// The pane's own name, on the same material as the rest of the floating layer. It is a control
    /// above the transcript rather than a caption inside it, and on bare canvas the prose that
    /// scrolls under it overprints it glyph for glyph.
    private func configureIdentityStrip() -> NSView {
        identityLabel.font = MacTheme.Ramp.font(.paneIdentity)
        identityLabel.textColor = MacTheme.Color.onGlassSecondary
        identityLabel.lineBreakMode = .byTruncatingMiddle
        let strip = NSStackView(views: [identityLabel])
        strip.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.xs, left: MacTheme.Spacing.s, bottom: MacTheme.Spacing.xs,
            right: MacTheme.Spacing.s)
        strip.translatesAutoresizingMaskIntoConstraints = false
        let glass = MacTheme.glass(around: strip, cornerRadius: MacTheme.Radius.control)
        glass.isHidden = true
        return glass
    }

    /// The scroll view owns its insets so content can run underneath the floating glass: the top
    /// inset tracks the toolbar and the identity strip, the bottom one tracks the composer capsule.
    override func viewDidLayout() {
        super.viewDidLayout()
        let bottom = (composerGlass?.frame.height ?? 0) + MacTheme.Spacing.m + MacTheme.Spacing.l
        let strip: CGFloat =
            identityGlass.map { $0.isHidden ? 0 : $0.frame.height + MacTheme.Spacing.s } ?? 0
        let top = view.safeAreaInsets.top + MacTheme.Spacing.s + strip
        let insets = NSEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
        if scrollView.contentInsets.bottom != insets.bottom
            || scrollView.contentInsets.top != insets.top
        {
            scrollView.contentInsets = insets
            if followsBottom { schedulePinCorrector() }
        }
    }

    func open(_ entry: SessionEntry, backend: any CodingAgentBackend) {
        clearSlot()
        guard self.entry?.session.id != entry.session.id || self.entry?.profileID != entry.profileID
        else { return }
        onStopWatch?(SessionPinStore.key(entry.profileID, entry.session.id))
        let previousEntry = self.entry
        let previousConversation = conversation
        let previousPresence = presence
        if let previousEntry, let previousConversation, previousPresence.isInFlight {
            onBackgroundWatch?(previousConversation, previousEntry)
        }
        streamTask?.cancel()
        self.entry = entry
        self.backend = backend
        lastState = nil
        dismissChooser()
        emptyLabel.isHidden = true
        composer.isHidden = false
        composer.prepare(for: entry, backend: backend)
        context.expanded = []
        context.subagentRows = [:]
        context.agentFacts = [:]
        inFlightImages = []
        inFlightSubagents = []
        echoedPrompt = nil
        clearUnseen()
        ActivityInbox.clear(sessionID: entry.session.id)
        windowLimit = 400
        rowTailMessages = 300
        lastFullRows = []
        lastFullCount = 0
        lastStreamedKey = nil
        stopTailRepair()
        abandoned = nil
        followsBottom = true
        pendingSignature = "\u{0}"
        pendingStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        setFindShown(false)
        agents = []
        usage = nil
        git = nil
        contextEstimate = nil
        countedMessages = -1
        turnStartedAt = nil
        tickerTask?.cancel()
        tickerTask = nil
        agentStreamTask?.cancel()
        agentStreamTask = nil
        agentStreamSessionID = nil
        wasRunningForHaptics = false
        hapticPermissionID = nil
        hapticQuestionID = nil
        updateStatus()
        refreshAuthBanner()
        refreshIdentity()

        if let remembered = sessionRows[entry.session.id] {
            placeholderShown = true
            lastFullRows = remembered
            lastFullCount = remembered.count
            let limit = max(windowLimit, Self.transcriptWindowPreference)
            applyRows(remembered.count > limit ? Array(remembered.suffix(limit)) : remembered)
        } else {
            showPlaceholder(Localized.text("Connecting…"))
        }

        let conversation = AgentConversation(
            backend: backend, sessionID: entry.session.id, cache: AppCache.sessionCache)
        self.conversation = conversation
        streamTask = Task { [weak self] in
            var resubscribes = 0
            while !Task.isCancelled {
                for await state in await conversation.states() {
                    guard !Task.isCancelled, let self else { return }
                    if state.connection == .live { resubscribes = 0 }
                    let tail = self.rowTailMessages
                    let messages =
                        state.messages.count > tail
                        ? Array(state.messages.suffix(tail)) : state.messages
                    let rows = self.rowBuilder.rows(for: messages)
                    self.apply(state: state, rows: rows)
                }
                guard !Task.isCancelled, self != nil else { return }
                resubscribes += 1
                let delay = min(30.0, pow(2.0, Double(min(resubscribes, 5))))
                try? await Task.sleep(for: .seconds(delay))
            }
        }
        refreshTurnFacts()
        if let queued = pendingFirstMessage {
            pendingFirstMessage = nil
            if queued.sessionID == entry.session.id {
                let choice = composer.promptChoice
                sendPrompt(
                    queued.text, model: choice.model, effort: choice.effort,
                    attachments: queued.attachments.map(\.prompt))
            }
        }
    }

    /// A quick ask's words arrive before this pane's conversation exists, so they wait here —
    /// keyed to the session they were minted for — and go out through `sendPrompt` the moment
    /// open() builds that session's conversation. Any other open drops them: the key is what
    /// makes sending a question into a stranger's chat impossible, and the caller queues in the
    /// same main-actor turn that opens the minted chat, so nothing can slip in between.
    func queueFirstMessage(
        _ text: String, attachments: [PendingAttachment] = [], forSession sessionID: String
    ) {
        pendingFirstMessage = (sessionID, text, attachments)
    }

    /// Re-dials without disturbing the stream — the socket a sleeping Mac wakes up holding looks
    /// alive and delivers nothing.
    func reconnect() {
        guard let conversation else { return }
        Task { await conversation.reconnect() }
    }

    /// The strip that says whose conversation this pane is — only worth its line once a second
    /// pane exists, so a lone pane stays exactly the window it always was.
    func setIdentityVisible(_ visible: Bool) {
        identityGlass?.isHidden = !visible
        refreshIdentity()
    }

    /// A pane holds one thing at a time. A chat opened into a slot binds, streams, retitles the
    /// window and starts notifying behind a player that still covers the pane edge to edge — live
    /// and invisible, with no way back short of closing the pane — so the slot goes first.
    private func clearSlot() {
        guard video != nil || page != nil else { return }
        video?.shutdown()
        video?.removeFromSuperview()
        video = nil
        page?.shutdown()
        page?.removeFromSuperview()
        page = nil
        setChatFurnitureVisible(true)
        refreshIdentity()
        onVideoChanged?()
    }

    /// Turns this pane into a video slot, or points the one it already is at something else. The
    /// chat furniture is hidden rather than destroyed, so a slot is a state of a pane and not a
    /// second kind of object the tiling would have to learn.
    func showVideo(_ target: VideoTarget?) {
        chooser = nil
        chooserView.isHidden = true
        if video == nil {
            let slot = VideoSlotView(target: target)
            slot.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(slot, positioned: .below, relativeTo: identityGlass)
            NSLayoutConstraint.activate([
                slot.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                slot.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                slot.topAnchor.constraint(equalTo: view.topAnchor),
                slot.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            video = slot
            slot.onChange = { [weak self] in
                self?.refreshIdentity()
                self?.onVideoChanged?()
            }
            setChatFurnitureVisible(false)
        } else if let target {
            video?.point(at: target)
        }
        if target == nil { video?.focusPrompt() }
        refreshIdentity()
    }

    /// Turns this pane into a browser slot, or points the one it already is at another address.
    func showWeb(_ target: WebTarget?) {
        chooser = nil
        chooserView.isHidden = true
        if page == nil {
            let slot = WebSlotView(target: target)
            slot.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(slot, positioned: .below, relativeTo: identityGlass)
            NSLayoutConstraint.activate([
                slot.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                slot.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                slot.topAnchor.constraint(equalTo: view.topAnchor),
                slot.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            ])
            page = slot
            slot.onChange = { [weak self] in
                self?.refreshIdentity()
                self?.onVideoChanged?()
            }
            setChatFurnitureVisible(false)
        } else if let target {
            page?.point(at: target)
        }
        if target == nil { page?.focusPrompt() }
        refreshIdentity()
    }

    var isBrowsing: Bool { page != nil }
    var webTarget: WebTarget? {
        page.flatMap { slot in slot.currentAddress.map(WebTarget.page) ?? slot.target }
    }
    var webSummary: String? { page?.summary }

    /// A browsing pane claims only the chords a browser owns; every other key belongs to the page,
    /// which is typing into a form as often as not.
    func handleWebChord(_ chord: KeyChord) -> Bool {
        guard let page, let command = WebCommand.command(for: chord) else { return false }
        if page.isAsking, command == .address { return false }
        page.handle(command)
        return true
    }

    var isWatching: Bool { video != nil }
    var videoTarget: VideoTarget? { video?.target }
    var videoSummary: String? { video?.summary }

    /// True while a slot is still asking what to watch. The board that asks lives under a text
    /// field, so its keys arrive in the insert context and the window has to offer them anyway.
    var isChoosingStream: Bool { video?.isAsking == true }

    /// A slot answers its own keys while it is focused; everything it does not claim goes on to
    /// the shortcut table, so the chat panes lose nothing to a slot in the grid. While it is still
    /// asking, the keys belong to the board rather than to the player it does not have yet.
    func handleVideoChord(_ chord: KeyChord) -> Bool {
        guard let video else { return false }
        guard !video.isAsking else { return video.handleBoard(chord) }
        guard let command = VideoCommand.command(for: chord) else { return false }
        video.handle(command)
        return true
    }

    /// Everything the pane draws for a conversation, out of the way while it holds a stream —
    /// walked rather than named so a new piece of chat chrome cannot forget to hide itself, and
    /// remembered rather than re-derived on the way back, because what was hidden is not what is
    /// wanted: unhiding the whole list shows an empty completion popover and a find bar nobody
    /// opened.
    private func setChatFurnitureVisible(_ visible: Bool) {
        guard !visible else {
            furnitureHidden.forEach { $0.isHidden = false }
            furnitureHidden = []
            return
        }
        guard furnitureHidden.isEmpty else { return }
        furnitureHidden = view.subviews.filter {
            $0 !== identityGlass && $0 !== video && $0 !== page && !$0.isHidden
        }
        furnitureHidden.forEach { $0.isHidden = true }
    }

    private func refreshIdentity() {
        if let page {
            identityLabel.stringValue = "\(page.slot.title) · \(page.slot.subtitle)"
            return
        }
        if let video {
            identityLabel.stringValue = "\(video.slot.title) · \(video.slot.subtitle)"
            return
        }
        guard let entry else {
            identityLabel.stringValue = Localized.text("No conversation")
            return
        }
        let title =
            entry.session.hasPlaceholderTitle
            ? Localized.text("New conversation") : entry.session.title
        let server = ServerLabel.display(name: entry.profileName, backend: entry.backendType)
        identityLabel.stringValue = "\(title) · \(server)"
    }

    /// A closing pane stops talking to the world before its views go: a cancelled stream is the
    /// difference between a closed pane and a leak that keeps rendering into nothing. What was
    /// half-typed into it is written first — closing a pane is not a decision to throw a prompt
    /// away, and the chat it belongs to can be opened again anywhere.
    func shutdownPane() {
        let previousEntry = entry
        let previousConversation = conversation
        let previousPresence = presence
        if let previousEntry, let previousConversation, previousPresence.isInFlight {
            onBackgroundWatch?(previousConversation, previousEntry)
        }
        composer.stashDraft()
        cascade.release()
        stopTailRepair()
        page?.shutdown()
        video?.shutdown()
        streamTask?.cancel()
        streamTask = nil
        tickerTask?.cancel()
        tickerTask = nil
        agentStreamTask?.cancel()
        agentStreamTask = nil
        agentStreamSessionID = nil
    }

    /// Empties the pane deliberately — a deleted or unresolvable session leaves an explanation,
    /// never a stale transcript that looks alive.
    func resetPane(placeholder: String) {
        shutdownPane()
        conversation = nil
        entry = nil
        backend = nil
        lastState = nil
        lastFullRows = []
        lastFullCount = 0
        lastStreamedKey = nil
        stopTailRepair()
        abandoned = nil
        echoedPrompt = nil
        pendingSignature = "\u{0}"
        pendingStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        composer.isHidden = true
        authGlass?.isHidden = true
        showPlaceholder(placeholder)
        refreshIdentity()
        updateStatus()
    }

    /// Browse every command this server offers — the completion popover is for speed.
    func presentCommandCatalog() {
        CommandCatalogWindow.present(commands: composer.availableCommands) { [weak self] command in
            self?.composer.acceptCatalogCommand(command)
        }
    }

    /// A notice is transient — the last thing the app did on your behalf — and it lives at the
    /// far end of the band so it never pushes a live fact off it.
    func setNotice(_ text: String) {
        notice = text
        updateStatus()
    }

    /// Where a toast belongs: over the transcript, above the floating glass layer, so glass
    /// never stacks on glass.
    var toastAnchor: (host: NSView, above: NSLayoutYAxisAnchor)? {
        guard let composerGlass else { return nil }
        return (view, composerGlass.topAnchor)
    }

    func focusComposer() {
        composer.takeFocus()
    }

    func scrollBy(_ points: CGFloat) {
        adjustScroll { $0 + points }
    }

    func scrollByPages(_ fraction: CGFloat) {
        adjustScroll { $0 + self.scrollView.contentView.bounds.height * fraction }
    }

    func scrollToTop() {
        adjustScroll { _ in -self.scrollView.contentInsets.top }
    }

    func scrollToBottom() {
        setFollowing(true)
        clearUnseen()
        schedulePinCorrector()
    }

    func setFindShown(_ shown: Bool) {
        if shown {
            findBar.isHidden = false
            findBar.focusField()
            runFind(retarget: false)
        } else {
            guard !findBar.isHidden else { return }
            findBar.isHidden = true
            findBar.clear()
            clearFindHighlight()
            findMatches = []
            view.window?.makeFirstResponder(nil)
        }
    }

    func respondToFirstPermission(_ decision: PermissionDecision) {
        guard let permission = lastState?.pendingPermissions.first else { return }
        respond(to: permission, decision: decision)
    }

    func stopTurn() {
        guard let conversation else { return }
        Task { try? await conversation.cancelCurrentTurn() }
    }

    /// Live facts for the running fan-out, keyed by spawning tool-use id: only the cards whose
    /// facts actually changed re-paint, in place, so a working agent's progress line ticks
    /// without touching the scroll or the forty cards around it.
    func applyAgentFacts(_ facts: [String: SubagentSummary]) {
        let changed = facts.keys.filter { context.agentFacts[$0] != facts[$0] }
        let vanished = context.agentFacts.keys.filter { facts[$0] == nil }
        context.agentFacts = facts
        let stale = Set(changed + vanished)
        guard !stale.isEmpty else { return }
        replaceRows {
            if case .subagent(let call) = $0.kind { return stale.contains(call.id) }
            return false
        }
    }

    private static var transcriptWindowPreference: Int {
        let stored = UserDefaults.standard.integer(forKey: "tailscode.transcriptWindow")
        return stored == 0 ? 400 : min(5000, max(50, stored))
    }

    private func configureCanvas() {
        rowsStack.spacing = MacTheme.Spacing.m
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        pendingStack.spacing = MacTheme.Spacing.s
        pendingStack.translatesAutoresizingMaskIntoConstraints = false

        earlierButton.isHidden = true
        earlierButton.isBordered = false
        earlierButton.contentTintColor = MacTheme.Color.secondaryLabel
        earlierButton.font = MacTheme.Ramp.font(.panelFootnote)

        canvas.spacing = MacTheme.Spacing.m
        canvas.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.l, left: MacTheme.Spacing.xl, bottom: MacTheme.Spacing.l,
            right: MacTheme.Spacing.xl)
        canvas.translatesAutoresizingMaskIntoConstraints = false
        canvas.addArrangedSubview(earlierButton)
        canvas.addArrangedSubview(rowsStack)
        canvas.addArrangedSubview(pendingStack)
    }

    private func configureScroll() {
        let clip = FlippedClipView()
        clip.drawsBackground = false
        scrollView.contentView = clip
        scrollView.documentView = canvas
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            canvas.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
            canvas.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
            canvas.topAnchor.constraint(equalTo: clip.topAnchor),
            canvas.widthAnchor.constraint(equalTo: clip.widthAnchor),
        ])
    }

    /// The whole floating layer — the status capsule and the writing card — is one glass group,
    /// so its neighbouring shapes read as a single wet surface and merge when they touch. The
    /// band is its own glass shape above the composer's: two facts, two capsules.
    private func configureComposerLayer() -> NSView {
        statusBand.perform = { [weak self] action in self?.onBandAction?(action) }

        composer.isHidden = true
        cascade.onFrame = { [weak self] in self?.paintCascade() }
        cascade.onStalled = { [weak self] in self?.giveUpCascade() }
        composer.onSubmitPrompt = { [weak self] text, model, effort, attachments in
            self?.sendPrompt(text, model: model, effort: effort, attachments: attachments)
        }
        composer.onRunCommand = { [weak self] command, arguments, model, effort in
            guard let conversation = self?.conversation else { return }
            Task {
                try? await conversation.run(
                    command, arguments: arguments, model: model, reasoningEffort: effort)
            }
        }
        composer.onCompactRequested = { [weak self] instruction in
            self?.presentCompactPreflight(initialInstruction: instruction)
        }
        composer.onStop = { [weak self] in self?.stopTurn() }
        composer.onToast = { [weak self] text in self?.onToast?(text) }
        composer.onAttachmentsChanged = { [weak self] in self?.updateStatus() }
        composer.onBrowseCommands = { [weak self] in self?.presentCommandCatalog() }
        composer.quotasForModels = { [weak self] in
            guard let self else { return [] }
            return QuotaSurface.relevantQuotas(
                for: self.backend?.agentType, among: self.quotasForStatus?() ?? [])
        }

        let column = FillingStack(views: [composer])
        column.spacing = MacTheme.Spacing.xs
        column.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.s, left: MacTheme.Spacing.m, bottom: MacTheme.Spacing.s,
            right: MacTheme.Spacing.m)
        column.translatesAutoresizingMaskIntoConstraints = false

        let card = MacTheme.glass(around: column, cornerRadius: MacTheme.Radius.card)
        let band = MacTheme.glass(around: statusBand, cornerRadius: MacTheme.Radius.card)
        band.isHidden = true
        bandGlass = band

        authBanner.orientation = .horizontal
        authBanner.spacing = MacTheme.Spacing.s
        authBanner.translatesAutoresizingMaskIntoConstraints = false
        authBanner.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.s, left: MacTheme.Spacing.m, bottom: MacTheme.Spacing.s,
            right: MacTheme.Spacing.m)
        let auth = MacTheme.tintedGlass(
            around: authBanner, tint: MacTheme.Color.warning,
            cornerRadius: MacTheme.Radius.card)
        auth.isHidden = true
        authGlass = auth

        let host = FillingStack(views: [auth, band, card])
        host.spacing = MacTheme.Spacing.m
        host.translatesAutoresizingMaskIntoConstraints = false
        let group = MacTheme.glassGroup()
        group.contentView = host
        return group
    }

    private func configureJumpPill() -> NSView {
        jumpButton.isBordered = false
        jumpButton.font = MacTheme.Ramp.font(.pill)
        jumpButton.contentTintColor = MacTheme.Color.onGlass
        jumpButton.target = self
        jumpButton.action = #selector(jumpToBottom)
        jumpButton.toolTip = Localized.text("Jump to the newest")
        jumpButton.setAccessibilityLabel(Localized.text("Jump to the newest"))
        let padded = NSStackView(views: [jumpButton])
        padded.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.s, left: MacTheme.Spacing.m, bottom: MacTheme.Spacing.s,
            right: MacTheme.Spacing.m)
        padded.translatesAutoresizingMaskIntoConstraints = false
        let glass = MacTheme.glass(around: padded, cornerRadius: MacTheme.Radius.card)
        glass.isHidden = true
        return glass
    }

    private func configureFindBar() {
        findBar.isHidden = true
        findBar.onQueryChanged = { [weak self] _ in self?.runFind(retarget: true) }
        findBar.onStep = { [weak self] delta in self?.stepFind(by: delta) }
        findBar.onClose = { [weak self] in self?.setFindShown(false) }
    }

    /// Opening or closing a row is a reading gesture: the person's eyes are on the header they
    /// clicked, so the transcript stops following the bottom — a stream that kept pinning would
    /// scroll the very card they opened out from under them — and the view moves only as far as
    /// ``revealDisclosure`` needs to show the opened body, never past the clicked header. Their
    /// own next prompt, or the jump pill, is what re-engages following.
    private func wireContext() {
        context.onToggle = { [weak self] key, open in
            guard let self else { return }
            if open {
                self.context.expanded.insert(key)
            } else {
                self.context.expanded.remove(key)
            }
            self.followsBottom = false
        }
        context.revealRow = { [weak self] row in
            DispatchQueue.main.async { [weak self] in self?.revealDisclosure(row) }
        }
        context.requestImage = { [weak self] reference, key in
            self?.noteImageWanted(reference, key: key)
        }
        context.requestSubagent = { [weak self] call in
            self?.fetchSubagent(call)
        }
        context.requestWorkflowAgent = { [weak self] agentID in
            self?.fetchWorkflowAgent(agentID)
        }
        context.openImage = { [weak self] key, name in
            guard let self else { return }
            let items: [ImageViewer.Item] = self.lastFullRows.compactMap { row in
                guard case .file(let reference, _) = row.kind,
                    (reference.mime ?? "").hasPrefix("image/")
                else { return nil }
                let itemName =
                    reference.filename
                    ?? reference.path.map { URL(fileURLWithPath: $0).lastPathComponent }
                    ?? "image"
                return ImageViewer.Item(key: row.key, name: itemName, reference: reference)
            }
            ImageViewer.present(
                items: items, startKey: key, host: self.view.window,
                fetch: { [weak self] reference, key in self?.fetchImage(reference, key: key) },
                toast: { [weak self] text in self?.onToast?(text) })
        }
        context.presentText = { [weak self] title, subtitle, body, mono in
            self?.presentReader(title: title, subtitle: subtitle, body: body, mono: mono)
        }
        context.toast = { [weak self] text in
            self?.onToast?(text)
        }
        context.askAgain = { [weak self] words in
            guard let self, !words.isEmpty else { return }
            guard self.composer.sendAgain(words) else {
                self.onToast?(Localized.text("Send or clear what is in the composer first."))
                return
            }
        }
        context.resumeInterrupted = { [weak self] in
            guard let conversation = self?.conversation else { return }
            Task { [weak self] in
                do {
                    try await conversation.resumeInterruptedTurn()
                } catch {
                    await MainActor.run {
                        self?.onToast?(
                            Localized.text("The server could not pick that turn back up."))
                    }
                }
            }
        }
        context.dismissInterrupted = { [weak self] in
            guard let conversation = self?.conversation else { return }
            Task { try? await conversation.dismissInterruptedTurn() }
        }
        earlierButton.target = self
        earlierButton.action = #selector(showEarlierRows)
    }

    @objc private func showEarlierRows() {
        guard let state = lastState else { return }
        windowLimit += 400
        rowTailMessages += 600
        apply(state: state, rows: lastFullRows)
        Task { [weak self] in await self?.conversation?.reconnect() }
    }

    @objc private func jumpToBottom() {
        scrollToBottom()
    }

    /// The prompt is on screen before the server has heard of it. A busy bridge can take seconds
    /// to answer, and a composer that empties into silence reads as a hang.
    private func sendPrompt(
        _ text: String, model: ModelSelection?, effort: String?,
        attachments: [PromptAttachment]
    ) {
        guard let conversation else { return }
        MacHaptics.shared.play(.send)
        echoedPrompt = text
        if let state = lastState { apply(state: state, rows: lastFullRows) }
        scrollToBottom()
        Task { [weak self] in
            do {
                try await conversation.send(
                    text, model: model, reasoningEffort: effort, attachments: attachments)
            } catch {
                MacHaptics.shared.play(.error)
                NSSound.beep()
                self?.undoEchoedPrompt(text)
            }
        }
    }

    /// A send that never reached the server is not a turn. The echo is the only thing on screen
    /// saying the words were delivered, so it comes off, the sentence goes back where it was
    /// written, and the failure is said in words — a beep under a prompt that still looks sent is
    /// the one outcome this path must not leave behind.
    private func undoEchoedPrompt(_ text: String) {
        echoedPrompt = nil
        if let state = lastState { apply(state: state, rows: lastFullRows) }
        composer.insertText(text)
        onToast?(Localized.text("That prompt did not reach the server."))
    }

    /// `/compact` never fires bare: it is irreversible, takes minutes, and accepts an
    /// instruction for what the summary must keep where the server takes one — so it always
    /// opens the shared decision screen first, whose every word is ``CompactPreflight``'s.
    func presentCompactPreflight(initialInstruction: String = "") {
        guard let conversation, let entry else { return }
        MacDialogs.compactPreflight(
            on: view.window,
            facts: CompactPreflight.make(
                state: lastState,
                showsInstruction: backend?.capabilities.supportsCompactionInstructions ?? true),
            initialInstruction: initialInstruction,
            draft: .compaction(profileID: entry.profileID, sessionID: entry.session.id)
        ) { [choice = composer.promptChoice] instruction in
            Task {
                try? await conversation.compact(
                    instructions: instruction, model: choice.model,
                    reasoningEffort: choice.effort)
            }
        }
    }

    /// A signed-out Claude is a state, not a reply: the CLI answers every turn with "Not logged
    /// in" instead of failing, so the warning lives here — above the prompt box someone is about
    /// to type into — with the one button that fixes it. Never "open a terminal".
    private func refreshAuthBanner() {
        authGlass?.isHidden = true
        guard let entry, let authenticating = backend as? any AuthenticatingBackend else { return }
        let sessionID = entry.session.id
        Task { [weak self] in
            guard let auth = try? await authenticating.authStatus() else { return }
            guard let self, self.entry?.session.id == sessionID else { return }
            self.renderAuthBanner(auth, backend: authenticating)
        }
    }

    private func renderAuthBanner(_ auth: ServerAuth, backend: any AuthenticatingBackend) {
        authBanner.arrangedSubviews.forEach { $0.removeFromSuperview() }
        guard !auth.loggedIn else {
            authGlass?.isHidden = true
            return
        }
        let name =
            entry.map { ServerLabel.display(name: $0.profileName, backend: $0.backendType) }
            ?? "server"
        let label = NSTextField(
            wrappingLabelWithString: Localized.text(
                "⚠ Claude is signed out on %@ — every turn will refuse until it signs in.", name))
        label.font = MacTheme.Ramp.font(.panelFootnote)
        label.setContentHuggingPriority(.init(1), for: .horizontal)
        let signIn = RowKit.ActionButton(title: Localized.text("Sign in")) { [weak self] in
            guard let self, let window = self.view.window else { return }
            SignInSheet.present(on: window, serverName: name, backend: backend) { [weak self] in
                self?.refreshAuthBanner()
            }
        }
        authBanner.addArrangedSubview(label)
        authBanner.addArrangedSubview(signIn)
        authGlass?.isHidden = false
    }

    private func respond(to permission: PermissionRequest, decision: PermissionDecision) {
        guard let conversation else { return }
        Task { try? await conversation.respond(to: permission, decision: decision) }
    }

    /// Claude answers by message, so the answer goes out through the ordinary send path — a
    /// bridge busy with a live turn refuses a side-channel call but queues a message. The card
    /// stops asking immediately either way.
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

    /// The transcript renders a tail window, not the whole history: a view per row is fine for
    /// four hundred rows and a multi-second lockup for four thousand. The rest waits behind one
    /// button that widens the window — the full rows are kept, so nothing is refetched.
    private func apply(state: ConversationState, rows: [TranscriptRow]) {
        noteHapticEdges(state: state, rows: rows)
        lastState = state
        if let entry, spendReading.note(messages: state.messages, for: entry.session.id) {
            updateStatus()
        }
        onState?(state)
        var confirmed = rows
        confirmed.removeAll { $0.key.hasPrefix("echo:") }
        lastFullRows = confirmed
        if let entry { rememberRows(confirmed, for: entry.session.id) }
        if let echoedPrompt,
            state.messages.contains(where: {
                $0.role == .user && $0.text.contains(echoedPrompt.prefix(80))
            })
        {
            self.echoedPrompt = nil
        }
        let shown = docked(echoed(confirmed), state: state)
        let appended = max(0, shown.count - lastFullCount)
        lastFullCount = shown.count
        let limit = max(windowLimit, Self.transcriptWindowPreference)
        let windowed = shown.count > limit ? Array(shown.suffix(limit)) : shown
        let hiddenCount = shown.count - windowed.count
        earlierButton.isHidden = hiddenCount <= 0
        if hiddenCount > 0 {
            earlierButton.title = Localized.text(
                "… %@ earlier rows — show more", "\(hiddenCount)")
        }
        if shown.isEmpty {
            cascade.release()
            showPlaceholder(
                state.hasLoadedTranscript
                    ? Localized.text("Nothing here yet. Say something.")
                    : Localized.text("Loading…"))
        } else {
            applyRows(
                pacedByCascade(windowed, running: state.status == .running), appended: appended)
            settleStreamedTail(in: windowed)
            paintCascade()
        }
        renderPendingCards(state)
        composer.noteState(state)
        if state.messages.count != countedMessages {
            countedMessages = state.messages.count
            contextEstimate = StatusFacts.estimateContextTokens(state.messages)
        }
        updateStatus()
        refreshWorkflowRuns()
        updateTicker(running: state.status == .running || state.compaction?.isRunning == true)
    }

    /// What the transcript draws: the rows the server has confirmed, plus the prompt this device is
    /// still echoing on its behalf.
    ///
    /// The echo never enters `lastFullRows`. It used to be appended to the row list that was then
    /// stored as that memo, and three callers hand the memo straight back in — the chunked fill on
    /// every runloop hop, the widening window, the next send — so each re-entry appended a second
    /// pair while the echo was pending. Nothing de-duplicates rows on the way to the stack and the
    /// diff's key index is first-occurrence-wins, so a cosmetic double prompt became an anchor
    /// resolved against the wrong row and a wrong-slice rebuild. The memo is what the server said;
    /// the echo is added on the way to the screen and nowhere else.
    private func echoed(_ rows: [TranscriptRow]) -> [TranscriptRow] {
        guard let echoedPrompt else { return rows }
        var rows = rows
        if !rows.isEmpty {
            rows.append(TranscriptRow(key: "echo:break", kind: .turnBreak))
        }
        rows.append(TranscriptRow(key: "echo:prompt", kind: .userText(echoedPrompt)))
        return rows
    }

    /// A turn the machine cut off is docked at the very end: it is an account of what already
    /// happened, and it belongs below everything that did. Like the echo, it is added on the way
    /// to the screen and never memoized — the server owns it, not this device.
    private func docked(_ rows: [TranscriptRow], state: ConversationState) -> [TranscriptRow] {
        guard let cutOff = InterruptedTurnReading.read(state.interruption) else { return rows }
        var rows = rows
        if !rows.isEmpty {
            rows.append(TranscriptRow(key: "interrupted:break", kind: .turnBreak))
        }
        rows.append(TranscriptRow(key: "interrupted", kind: .interruptedTurn(cutOff)))
        return rows
    }

    /// The same edges the phone reports to the hand, read before the new state replaces the old:
    /// a tool call landing while you wait, the turn ending, the agent stopping to ask. The cues
    /// are the waiting group's — the wait is what the app asks of someone, so the wait is what
    /// the trackpad reports.
    private func noteHapticEdges(state: ConversationState, rows: [TranscriptRow]) {
        let previous = Self.toolStatuses(lastFullRows)
        if !previous.isEmpty {
            let current = Self.toolStatuses(rows)
            for (id, status) in previous
            where status != .completed && current[id] == .completed {
                MacHaptics.shared.play(.step)
            }
        }
        if wasRunningForHaptics && state.status != .running {
            MacHaptics.shared.play(.received)
        }
        wasRunningForHaptics = state.status == .running
        if let permission = state.pendingPermissions.first, permission.id != hapticPermissionID {
            hapticPermissionID = permission.id
            MacHaptics.shared.play(.needsYou)
        }
        if let question = state.pendingQuestions.first, question.id != hapticQuestionID {
            hapticQuestionID = question.id
            MacHaptics.shared.play(.needsYou)
        }
    }

    private static func toolStatuses(_ rows: [TranscriptRow]) -> [String: ToolStatus] {
        var map: [String: ToolStatus] = [:]
        for row in rows {
            switch row.kind {
            case .tool(let call), .subagent(let call), .workflow(let call):
                map[call.id] = call.status
            case .run(let steps):
                for case .tool(let call) in steps { map[call.id] = call.status }
            default:
                break
            }
        }
        return map
    }

    /// The band between transcript and composer: what the turn is doing, which agents are out,
    /// how much of the context is spent, what the goal is — every fact clickable, so reading the
    /// status and steering the turn are one gesture rather than two.
    private func updateStatus() {
        guard let state = lastState else {
            lastFacts = nil
            statusBand.render(facts: nil, notice: notice)
            bandGlass?.isHidden = !statusBand.hasContent
            return
        }
        let running = state.status == .running || state.compaction?.isRunning == true
        if running {
            if turnStartedAt == nil { turnStartedAt = Date() }
        } else {
            turnStartedAt = nil
        }
        let quotas = quotasForStatus?() ?? []
        let facts = StatusFacts.from(
            state: state, turnStartedAt: turnStartedAt, agents: agents, usage: usage,
            attachments: composer.attachmentCount, contextTokens: contextEstimate, quotas: quotas,
            spend: spend, git: git, model: composer.activeModelID)
        lastFacts = facts
        let bandNotice = quotaNotice(state: state, quotas: quotas) ?? notice
        statusBand.render(facts: facts, notice: bandNotice)
        bandGlass?.isHidden = !statusBand.hasContent
    }

    /// Pre-emptive used-up quota on the band while idle — a failed turn already carries the
    /// rewritten phase, so this only speaks when the wall is up before the next send. Only the
    /// chat's own provider family speaks here, and only the wall standing in front of the model
    /// this chat would send with; every other wall is worn where a model is picked.
    private func quotaNotice(state: ConversationState, quotas: [UsageQuota]) -> String? {
        guard state.lastFailure == nil, state.status != .running else { return nil }
        let relevant = QuotaSurface.relevantQuotas(for: backend?.agentType, among: quotas)
        return QuotaSurface.hottestExhausted(
            in: QuotaSurface.billingQuotas(
                in: relevant, selection: composer.pickedModel, model: composer.activeModelID),
            model: composer.activeModelID
        )
        .map(QuotaSurface.short)
    }

    /// A once-a-second nudge while a turn runs, so elapsed time moves without any state event;
    /// every fifth tick also re-asks the server for agents and cost.
    private func updateTicker(running: Bool) {
        let running = running || workflowRuns.contains(where: \.isLive)
        if running, tickerTask == nil {
            tickerTask = Task { [weak self] in
                var tick = 0
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(1))
                    guard !Task.isCancelled, let self else { return }
                    tick += 1
                    self.updateStatus()
                    self.updateCompactingElapsed()
                    self.advanceWorkflowClock()
                    if tick % 5 == 0 { self.refreshTurnFacts() }
                }
            }
        } else if !running, tickerTask != nil {
            tickerTask?.cancel()
            tickerTask = nil
            refreshTurnFacts()
        }
    }

    /// Subagents and cost are polled rather than streamed: the bridge reports both on request
    /// only, and a fan-out is worth watching while it runs. One final refresh after the turn
    /// stops settles the agents list on "done" instead of freezing mid-flight glyphs, and one
    /// when the chat opens: a conversation started on another machine is never running here, so
    /// waiting for a turn tick meant its account, its usage and its branch never arrived at all.
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
            guard let self, self.entry?.session.id == sessionID else { return }
            self.usage = usage
            self.git = repository.map { GitState(snapshot: $0) }
            self.spendReading.note(report: report, for: sessionID)
            self.spendReading.note(messages: self.lastState?.messages ?? [], for: sessionID)
            if let agents {
                self.applyAgentSummaries(agents)
            } else {
                self.updateStatus()
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

    /// A proto-2 bridge pushes each fan-out's live facts as they change; older servers are
    /// polled. Started on the first fact refresh after a chat opens.
    private func startAgentStreamIfAvailable() {
        guard agentStreamSessionID != entry?.session.id else { return }
        guard let backend, let entry else { return }
        agentStreamSessionID = entry.session.id
        let sessionID = entry.session.id
        agentStreamTask?.cancel()
        agentStreamTask = Task { [weak self] in
            guard let streaming = backend as? SubagentStreaming,
                let changes = await streaming.subagentChanges(for: sessionID)
            else {
                self?.agentStreamSessionID = nil
                return
            }
            for await agents in changes {
                guard let self, !Task.isCancelled, self.entry?.session.id == sessionID
                else { return }
                self.applyAgentSummaries(agents)
            }
        }
    }

    /// This conversation's workflow runs, rebuilt from the transcript and the live fan-out. Only
    /// the cards whose run actually changed are replaced.
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
        updateTicker(running: state.status == .running || state.compaction?.isRunning == true)
    }

    /// A changed run is written into the card it already has; only a card whose structure no
    /// longer matches — an agent appeared, the result landed — is rebuilt, and only that card.
    /// A rebuild destroys the view under the pointer and the click that was in flight with it,
    /// so it is the exception, never the once-a-second path.
    private func refreshWorkflowCards(_ ids: Set<String>) {
        guard !ids.isEmpty, !placeholderShown else { return }
        var rebuilt: Set<String> = []
        for index in renderedRows.indices {
            guard case .workflow(let call) = renderedRows[index].kind, ids.contains(call.id),
                index < rowViews.count
            else { continue }
            if !WorkflowCardView.restate(rowViews[index], call: call, context: context) {
                rebuilt.insert(renderedRows[index].key)
            }
        }
        if !rebuilt.isEmpty { replaceRows { rebuilt.contains($0.key) } }
    }

    /// A background run outlives the turn that launched it, so the clock every live card is drawn
    /// against keeps moving after the turn ends — a frozen elapsed reads as a hang.
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
            guard let self else { return }
            self.inFlightSubagents.remove(agentID)
            self.context.subagentRows[WorkflowAgentRows.key(agentID)] = rows
            self.replaceRows {
                guard case .workflow(let call) = $0.kind else { return false }
                return self.context.workflowRuns[call.id]?.agents
                    .contains { $0.id == agentID } ?? true
            }
        }
    }

    private func applyAgentSummaries(_ agents: [SubagentSummary]) {
        self.agents = agents
        var keyed: [String: SubagentSummary] = [:]
        for agent in agents {
            if let toolUseID = agent.toolUseID { keyed[toolUseID] = agent }
        }
        applyAgentFacts(keyed)
        refreshWorkflowRuns()
        updateStatus()
    }

    /// The card for one named agent — matched to the tool call that spawned it, which is the id
    /// the summary carries — expanded in place and its transcript fetched on arrival.
    func scrollToAgent(_ id: String) {
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

    func scrollToNewestAgent() {
        for (index, row) in renderedRows.enumerated().reversed() {
            guard case .subagent = row.kind else { continue }
            scrollToRow(at: index)
            return
        }
        scrollToBottom()
    }

    private func scrollToRow(at index: Int) {
        guard index < rowViews.count else { return }
        followsBottom = false
        view.layoutSubtreeIfNeeded()
        let rowView = rowViews[index]
        let frame = rowView.convert(rowView.bounds, to: canvas)
        adjustScroll { _ in frame.minY - self.scrollView.contentView.bounds.height * 0.3 }
    }

    /// The goal in a sheet rather than a bare command: what stands, whether it is met, and the
    /// two things you can do about it — restate it or abandon it.
    func presentGoalSheet() {
        guard let conversation, let entry, let window = view.window else { return }
        let hasGoal = lastState?.goal != nil
        let alert = NSAlert()
        alert.messageText = Localized.text("Change the goal")
        alert.informativeText = Localized.text(
            "The agent pursues the goal across turns and reports when it is met.")
        let scope = DraftScope.goal(profileID: entry.profileID, sessionID: entry.session.id)
        let standing = lastState?.goal?.condition ?? ""
        let field = DraftingField(
            scope: scope, initial: standing.isEmpty ? DraftStore.text(for: scope) : standing)
        field.placeholderString = Localized.text("What must become true?")
        field.frame = NSRect(x: 0, y: 0, width: 340, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        alert.addButton(withTitle: Localized.text("Set goal"))
        if hasGoal {
            let clear = alert.addButton(withTitle: Localized.text("Clear goal"))
            clear.hasDestructiveAction = true
        }
        alert.addButton(withTitle: Localized.text("Cancel"))
        let choice = composer.promptChoice
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                let condition = field.stringValue.trimmingCharacters(
                    in: .whitespacesAndNewlines)
                guard !condition.isEmpty else { return }
                DraftStore.clear(scope)
                Task {
                    try? await conversation.setGoal(
                        condition, model: choice.model, reasoningEffort: choice.effort)
                }
            } else if hasGoal, response == .alertSecondButtonReturn {
                Task {
                    try? await conversation.clearGoal(
                        model: choice.model, reasoningEffort: choice.effort)
                }
            }
        }
    }

    /// Re-renders every row at the current type scale: the builder's memo and the per-session
    /// row snapshots hold rendering baked at the old size, so both are dropped before the
    /// rebuild.
    /// The pane's own opaque surfaces, which are `CGColor` in a layer and so keep whatever colour
    /// they were given until they are given another.
    func applyPaneColours() {
        view.layer?.backgroundColor = MacTheme.Color.canvas.cgColor
    }

    /// The pane restyled for a light/dark flip nobody chose inside the app. `applyPaneColours` is
    /// reached from the theme notification, which a change of *system* appearance never posts — and
    /// a `CGColor` in a layer, a rendering in a memo and a row built under the old face all keep the
    /// colours they were born with, which is white prose on a white pane behind dark chrome. So the
    /// flip takes the road a theme change takes: drop what was baked, rebuild what was drawn.
    func adoptEffectiveAppearance() {
        guard isViewLoaded else { return }
        MacMarkdown.invalidate()
        applyPaneColours()
        applyUIScale()
    }

    /// The labels the pane owns itself, restated. Every row is rebuilt from the ramp on this road,
    /// but a font and an `NSColor` already handed to a label are baked — so without this a pane
    /// showing a placeholder is the one surface a scale step and a theme change both miss entirely.
    private func restyleOwnChrome() {
        emptyLabel.font = MacTheme.Ramp.font(.panelLabel)
        emptyLabel.textColor = MacTheme.Color.secondaryLabel
        identityLabel.font = MacTheme.Ramp.font(.paneIdentity)
        identityLabel.textColor = MacTheme.Color.onGlassSecondary
        earlierButton.font = MacTheme.Ramp.font(.panelFootnote)
        earlierButton.contentTintColor = MacTheme.Color.secondaryLabel
        jumpButton.font = MacTheme.Ramp.font(.pill)
        jumpButton.contentTintColor = MacTheme.Color.onGlass
    }

    func applyUIScale() {
        rowBuilder.invalidate()
        Self.codeMemo = nil
        sessionRows = [:]
        sessionRowOrder = []
        pendingSignature = "\u{0}"
        restyleOwnChrome()
        guard let state = lastState else { return }
        tearDownAllRows()
        placeholderShown = true
        let tail = rowTailMessages
        let messages =
            state.messages.count > tail ? Array(state.messages.suffix(tail)) : state.messages
        apply(state: state, rows: rowBuilder.rows(for: messages))
    }

    /// An empty pane asks which server rather than captioning itself. The chooser owns the
    /// canvas until something fills it, and every re-render keeps the person's place.
    func showChooser(_ model: PaneChooser) {
        chooser = model
        emptyLabel.isHidden = true
        composer.isHidden = true
        chooserView.isHidden = false
        renderChooser()
    }

    var chooserShown: Bool { chooser != nil }
    var chooserServerID: String? { chooser?.serverID }

    /// One line describing the chooser, for the headless selftest: the question, then the rows
    /// with the cursor marked.
    var chooserSummary: String? {
        guard let chooser else { return nil }
        let rows = chooser.rows.enumerated().map { index, row in
            "\(index == chooser.cursor ? "*" : "")\(row.title)"
        }
        return "\(chooser.heading) [\(rows.joined(separator: " | "))]"
    }

    /// A fresh listing under an open chooser: the same question, answered with what is true now.
    /// - Parameter watch: what is on among the channels this device follows, when the check has
    ///   landed since the question was asked; nil leaves the watch row saying what it already said.
    func restateChooser(
        servers: [PaneChooserServer], entries: [SessionEntry], watch: WatchSummary?
    ) {
        guard let current = chooser else { return }
        var next = current.restated(servers: servers, entries: entries)
        next.watchSummary = watch ?? next.watchSummary
        chooser = next
        renderChooser()
    }

    /// The chooser answers the keyboard before the shortcut table does — but only for the keys it
    /// binds, so the ctrl+w verbs, ? and everything else still reach the window.
    func handleChooserChord(_ chord: KeyChord) -> Bool {
        guard var model = chooser, let command = PaneChooser.command(for: chord) else {
            return false
        }
        let (handled, action) = model.handle(command)
        guard handled else { return false }
        chooser = model
        if let action {
            onChooserAction?(action)
        } else {
            renderChooser()
        }
        return true
    }

    private func renderChooser() {
        guard let model = chooser else { return }
        chooserView.render(model) { [weak self] index in self?.activateChooserRow(index) }
    }

    private func activateChooserRow(_ index: Int) {
        guard var model = chooser, model.rows.indices.contains(index) else { return }
        model.focus(index)
        let outcome = model.activate(model.rows[index].action)
        chooser = model
        if let outcome {
            onChooserAction?(outcome)
        } else {
            renderChooser()
        }
    }

    private func dismissChooser() {
        chooser = nil
        chooserView.isHidden = true
    }

    private func showPlaceholder(_ text: String) {
        dismissChooser()
        if placeholderShown, currentPlaceholder == text { return }
        currentPlaceholder = text
        tearDownAllRows()
        placeholderShown = true
        pendingReveal = false
        canvas.alphaValue = 1
        emptyLabel.stringValue = text
        emptyLabel.isHidden = false
    }

    /// The rendering path, shaped around what a person is looking at. On first paint the tail —
    /// the rows the window actually shows — goes up immediately, and everything earlier backfills
    /// above it one chunk per pass, so a huge conversation is readable in one frame instead of
    /// after a ten-chunk climb. Once it is up, every row whose key survives keeps its view — and its
    /// disclosure state, its selection, its scroll cost — wherever the edit moved it, and a token
    /// appended to the last message rebuilds one row, not the conversation.
    ///
    /// `renderedRows` is always a contiguous slice of the applied row list that reaches its end;
    /// where that slice starts is re-found by key on every pass, because the window slides.
    /// A streamed token changes exactly one row, and rebuilding its view for every arrival is what
    /// makes a live answer flicker: the label is torn down and remade dozens of times a second,
    /// which restarts its entrance, drops any selection inside it, and asks the whole column to lay
    /// out again. When the only difference is more words in a row that can take them where it
    /// stands — the answer the painter is holding, or a thought counting itself up — the change is
    /// written into the view and the bookkeeping moves with it.
    ///
    /// A painter with no hands on the row is served here too, and settles it whole. Reduce Motion
    /// releases the wave on every arrival, so demanding the painter hold the row would send the one
    /// row a person is reading down the rebuild path dozens of times a second — the very flicker
    /// this exists to prevent, on the machine that asked for less movement.
    private func updatedLastRowInPlace(_ rows: [TranscriptRow]) -> Bool {
        guard !placeholderShown, fillComplete,
            renderedRows.count == rows.count, let last = rows.indices.last, last > 0,
            renderedRows[last].key == rows[last].key, renderedRows[last] != rows[last],
            last < rowViews.count,
            renderedRows.dropLast().elementsEqual(rows.dropLast())
        else { return false }
        switch (renderedRows[last].kind, rows[last].kind) {
        case (.agentProse, .agentProse), (.codeBlock, .codeBlock):
            let painting = cascade.isActive
            guard rows[last].key == cascade.key || !painting else { return false }
            let previous = renderedRows[last]
            renderedRows[last] = rows[last]
            guard painting ? paintCascade() : settleCascade(on: rows[last].key, in: rows) else {
                renderedRows[last] = previous
                return false
            }
            if !painting, followsBottom { scrollToBottom() }
            return true
        case (.reasoning, .reasoning(let text)):
            guard let disclosure = rowViews[last] as? DisclosureRow else { return false }
            context.liveReasoning[rows[last].key] = text
            disclosure.restate(header: ToolRowView.thoughtHeader(text))
            disclosure.restateBody(text)
        default:
            return false
        }
        renderedRows[last] = rows[last]
        if followsBottom { scrollToBottom() }
        return true
    }

    /// Forgets everything the transcript believes about the row the wave was painting and the rows
    /// after it, so the next fill cannot compare them equal and skip them. The words are the
    /// transcript's own, so nothing is refetched — only redrawn.
    ///
    /// Redrawn means the whole list `apply` draws, docked turn included. This clock is the path a
    /// failed settle takes, which is the path a turn cut off mid-stream takes — so rebuilding from
    /// the echo alone would delete the account of the interruption, with its resume and its dismiss,
    /// at exactly the moment it was written, and a turn that ended sends no state to put it back.
    func rebuildStreamedTail(from key: String) {
        guard !placeholderShown, let index = renderedRows.lastIndex(where: { $0.key == key }),
            index < rowViews.count
        else { return }
        for viewToDrop in rowViews[index...] {
            if viewToDrop === highlightedView { clearFindHighlight() }
            viewToDrop.removeFromSuperview()
        }
        forgetWantedImages(renderedRows[index...])
        rowViews.removeSubrange(index...)
        renderedRows.removeSubrange(index...)
        let limit = max(windowLimit, Self.transcriptWindowPreference)
        let rows = lastState.map { docked(echoed(lastFullRows), state: $0) } ?? echoed(lastFullRows)
        applyRows(rows.count > limit ? Array(rows.suffix(limit)) : rows)
    }

    /// How many rows go up in one runloop hop while a fill is still climbing, and the size of edit
    /// past which an arrival is treated as a fill rather than as growth.
    private static let rowChunk = 40

    private func applyRows(_ rows: [TranscriptRow], appended: Int = 0) {
        assert(
            Set(rows.map(\.key)).count == rows.count,
            "the transcript handed one key to two rows")
        if updatedLastRowInPlace(rows) { return }
        let initialFill = placeholderShown
        if placeholderShown {
            tearDownAllRows()
            placeholderShown = false
            currentPlaceholder = nil
            emptyLabel.isHidden = true
            canvas.alphaValue = 0
            pendingReveal = true
        }
        let stick = initialFill || followsBottom
        let growth = initialFill ? 0 : appended

        let edit = preservingScroll { editRows(rows) }
        repaintChangedRows(rows, from: edit.start)
        fillComplete = edit.complete
        if !edit.complete {
            if stick { followsBottom = true }
            if !isFillingInChunks {
                isFillingInChunks = true
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.isFillingInChunks = false
                    if let state = self.lastState {
                        self.apply(state: state, rows: self.lastFullRows)
                    } else {
                        let limit = max(self.windowLimit, Self.transcriptWindowPreference)
                        let rows = self.echoed(self.lastFullRows)
                        self.applyRows(rows.count > limit ? Array(rows.suffix(limit)) : rows)
                    }
                }
            }
        }

        if stick {
            setFollowing(true)
            schedulePinCorrector()
        } else {
            noteAppendedWhileScrolledUp(growth)
        }
        scheduleImageSweep()
        if edit.complete, !findBar.isHidden { runFind(retarget: false) }
    }

    /// What has to happen to the rows on screen for them to become `rows`, and whether that leaves
    /// the whole list showing. Also where the rendered slice starts inside `rows`, which is zero for
    /// everything except a fill that is still climbing.
    ///
    /// The steady state diffs by *key*. A row's identity says whether it is the same row; its value
    /// says only whether it needs repainting, and conflating the two is what used to make one
    /// changed row mid-window cost every row below it — `placeBoard` promotes only the last board
    /// call, so every TodoWrite update reverts a row dozens of positions back and tore the tail off
    /// after it. A backfill is still a fill: rows arriving above everything on screen when the
    /// window widens cannot become four hundred views inside one frame.
    private func editRows(_ rows: [TranscriptRow]) -> (complete: Bool, start: Int) {
        guard fillComplete, !renderedRows.isEmpty else { return fillRowsInChunks(rows) }
        let plan = RowDiff.plan(from: renderedRows.map(\.key), to: rows.map(\.key))
        if isBackfill(plan) { return fillRowsInChunks(rows) }
        applyPlan(plan, to: rows)
        return (true, 0)
    }

    /// Whether an edit is better spread over runloop hops than carried out whole — which is a
    /// question about *where* the rows land, never about how many of them there are. The widening
    /// window is the shape worth chunking: several hundred rows arrive above everything on screen,
    /// nothing already up moves, and the climb costs a chunk of view builds a hop instead of the
    /// whole backfill inside one frame.
    ///
    /// It is also the only shape the chunked fill can express without damage. Its walk stops at the
    /// first key that disagrees and tears off every row below that point, so a row arriving — or
    /// leaving — from *between* two rows that stay would collapse and regrow the entire tail under
    /// it, which is precisely what the keyed diff exists to have stopped. Survivors that are
    /// contiguous on both sides are exactly the promise that nothing lands between them; counting
    /// insertions instead was the same mistake in a new place, because forty-one rows appearing in
    /// the middle of a transcript are not a fill.
    ///
    /// A list with no survivor at all is a fill by definition — every row on screen is going either
    /// way — so a big one climbs rather than building itself inside one frame.
    private func isBackfill(_ plan: RowDiff.Plan) -> Bool {
        guard let first = plan.survivors.first, let last = plan.survivors.last else {
            return plan.insertions.count > Self.rowChunk
        }
        let span = plan.survivors.count - 1
        guard last.old - first.old == span, last.new - first.new == span else { return false }
        return plan.insertions.prefix(while: { $0 < first.new }).count > Self.rowChunk
    }

    /// The plan carried out against the stack: removals from the back, so every index still ahead of
    /// the cursor keeps meaning what it meant, then insertions from the front, which is the order
    /// the plan is stated in. Nothing here repaints — a row whose key survived keeps the view it
    /// already has, and whatever its value now says is written into that view afterwards.
    private func applyPlan(_ plan: RowDiff.Plan, to rows: [TranscriptRow]) {
        guard !plan.isOrderPreserving else { return }
        for index in plan.removals.reversed() where index < rowViews.count {
            let doomed = rowViews[index]
            if doomed === highlightedView { clearFindHighlight() }
            doomed.removeFromSuperview()
            forgetWantedImages([renderedRows[index]])
            rowViews.remove(at: index)
            renderedRows.remove(at: index)
        }
        let entering = rowsAnnounceArrival
        for index in plan.insertions {
            let row = rows[index]
            let rowView = row.makeView(context: context)
            let at = min(index, rowViews.count)
            rowsStack.insertArrangedSubview(rowView, at: at)
            rowViews.insert(rowView, at: at)
            renderedRows.insert(row, at: at)
            let firstSight = enteredRows.insert(row.key).inserted
            if entering, firstSight, row.key != cascade.key, row.announcesArrival {
                CascadeEntrance.animate(rowView)
            }
        }
    }

    /// The first fill and the widening window. A transcript of four thousand rows goes up as the
    /// tail the window actually shows, and everything earlier backfills above it a chunk per runloop
    /// hop, so it is readable in one frame instead of after a ten-chunk climb. The walk matches by
    /// key rather than by value: a row whose words changed while the fill was climbing keeps its
    /// place and is repainted after, instead of taking the rest of the fill down with it.
    private func fillRowsInChunks(_ rows: [TranscriptRow]) -> (complete: Bool, start: Int) {
        let chunk = Self.rowChunk
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
                for viewToDrop in rowViews[..<anchor.rendered] {
                    if viewToDrop === highlightedView { clearFindHighlight() }
                    viewToDrop.removeFromSuperview()
                }
                forgetWantedImages(renderedRows[..<anchor.rendered])
                rowViews.removeSubrange(..<anchor.rendered)
                renderedRows.removeSubrange(..<anchor.rendered)
                start = anchor.row
            } else {
                tearDownAllRows()
            }
        }

        if renderedRows.isEmpty {
            start = max(0, rows.count - chunk)
            appendRowViews(rows[start...])
        } else {
            var same = 0
            while same < renderedRows.count, start + same < rows.count,
                renderedRows[same].key == rows[start + same].key
            {
                same += 1
            }
            for viewToDrop in rowViews[same...] {
                if viewToDrop === highlightedView { clearFindHighlight() }
                viewToDrop.removeFromSuperview()
            }
            forgetWantedImages(renderedRows[same...])
            rowViews.removeSubrange(same...)
            renderedRows.removeSubrange(same...)
            let tailFrom = start + renderedRows.count
            let tailEnd = min(rows.count, tailFrom + chunk)
            appendRowViews(rows[tailFrom..<tailEnd])
        }

        let tailDone = start + renderedRows.count >= rows.count
        if tailDone, start > 0 {
            let from = max(0, start - chunk)
            var position = 0
            var inserted: [NSView] = []
            for row in rows[from..<start] {
                let rowView = row.makeView(context: context)
                rowsStack.insertArrangedSubview(rowView, at: position)
                inserted.append(rowView)
                enteredRows.insert(row.key)
                position += 1
            }
            renderedRows.insert(contentsOf: rows[from..<start], at: 0)
            rowViews.insert(contentsOf: inserted, at: 0)
            start = from
        }
        return (tailDone && start == 0, start)
    }

    /// Where the key survived but the value did not. Repainting happens where the row stands — the
    /// alternative is removing the view and putting another one back, which is what restarts an
    /// entrance, drops a selection inside the row and asks the whole column to lay out again.
    private func repaintChangedRows(_ rows: [TranscriptRow], from start: Int) {
        var stale: Set<String> = []
        for index in renderedRows.indices {
            let source = start + index
            guard source >= 0, source < rows.count, renderedRows[index] != rows[source] else {
                continue
            }
            renderedRows[index] = rows[source]
            stale.insert(rows[source].key)
        }
        guard !stale.isEmpty else { return }
        replaceRows { stale.contains($0.key) }
    }

    /// Whether a row arriving now is arriving in front of somebody: the transcript is built and
    /// visible, and they are at the bottom, where new rows land. Anything else is a fill or a
    /// backfill — the transcript coming into existence rather than growing — and fading that in is a
    /// flicker with no event behind it.
    private var rowsAnnounceArrival: Bool {
        !placeholderShown && !pendingReveal && fillComplete && followsBottom
    }

    private func appendRowViews(_ rows: ArraySlice<TranscriptRow>) {
        let entering = rowsAnnounceArrival
        for row in rows {
            let rowView = row.makeView(context: context)
            rowsStack.addArrangedSubview(rowView)
            let firstSight = enteredRows.insert(row.key).inserted
            if entering, firstSight, row.key != cascade.key, row.announcesArrival {
                CascadeEntrance.animate(rowView)
            }
            rowViews.append(rowView)
            renderedRows.append(row)
        }
    }



    /// The wave letting go of a row is not the same as the row being rebuilt. A turn that simply
    /// ends leaves the rows identical, so the diff has nothing to do and the last glyphs would keep
    /// the heat of a stream that stopped — the row has to be handed back whole by hand.
    ///
    /// Whole means the row's own words, which is what the transcript last received and never what
    /// the pacer handed the label: the paced copy is cut at the last position where no markdown
    /// token is half-open, and settling from it would bake that cut into the finished answer.
    /// Returns whether the row is now whole, so a repair that could not be made is not mistaken for
    /// one that was.
    @discardableResult
    func settleCascade(on key: String, in rows: [TranscriptRow]) -> Bool {
        guard let index = renderedRows.lastIndex(where: { $0.key == key }),
            index < rowViews.count,
            let label = Self.streamedLabel(in: rowViews[index], kind: renderedRows[index].kind)
        else { return false }
        let row =
            lastFullRows.last(where: { $0.key == key })
            ?? rows.last(where: { $0.key == key })
            ?? renderedRows[index]
        switch row.kind {
        case .agentProse(_, let rendered):
            label.attributedStringValue = rendered
        case .codeBlock(let language, let body):
            label.attributedStringValue = Self.codeRendering(body, language: language)
        default:
            return false
        }
        return true
    }

    /// A code block's body as the row already draws it — lexed by the shared highlighter in this
    /// theme's colours — so the wave tints the same glyphs the settled row shows rather than
    /// flattening them on its way past. A flat rendering here is not a frame's worth of drift: the
    /// settled row then equals what was painted, the diff finds nothing to repaint, and every block
    /// written under the reader's eyes stays monochrome beside coloured blocks loaded from history.
    ///
    /// The last rendering is kept because the wave asks for one every frame, and lexing a block that
    /// is still growing at the display's rate is the one cost this path cannot carry. Exactly one
    /// row is ever live, so one entry answers every ask.
    static func codeRendering(_ body: String, language: String?) -> NSAttributedString {
        if let memo = codeMemo, memo.body == body, memo.language == language {
            return memo.rendering
        }
        let font = MacTheme.Ramp.font(.code)
        let rendering: NSAttributedString
        if SyntaxHighlighter.isDiff(language) {
            rendering = RowKit.diffAttributed(body, font: font)
        } else {
            let lexed = NSMutableAttributedString(
                string: body,
                attributes: [.font: font, .foregroundColor: MacTheme.Color.label])
            for token in SyntaxHighlighter.tokens(body, language: language) {
                let range = NSRange(location: token.offset, length: token.length)
                guard NSMaxRange(range) <= lexed.length else { continue }
                lexed.addAttribute(
                    .foregroundColor, value: MacTheme.Color.syntax(token.role), range: range)
            }
            rendering = lexed
        }
        codeMemo = (body, language, rendering)
        return rendering
    }

    private static var codeMemo:
        (body: String, language: String?, rendering: NSAttributedString)?

    /// Where a live row keeps the words: prose is the label itself, a code block keeps its body
    /// under the header and behind a scroller once it is tall enough to need one.
    static func streamedLabel(in view: NSView, kind: TranscriptRow.Kind) -> NSTextField? {
        switch kind {
        case .agentProse:
            return view as? NSTextField
        case .codeBlock:
            guard let stack = view as? NSStackView,
                let last = stack.arrangedSubviews.last
            else { return nil }
            if let field = last as? NSTextField { return field }
            return (last as? NSScrollView)?.documentView as? NSTextField
        default:
            return nil
        }
    }

    /// At most a handful of transcripts are kept renderable; the oldest falls out so a long day
    /// of chats does not become a memory of every one of them.
    private func rememberRows(_ rows: [TranscriptRow], for sessionID: String) {
        if sessionRows[sessionID] == nil {
            sessionRowOrder.append(sessionID)
            if sessionRowOrder.count > 6 {
                let evicted = sessionRowOrder.removeFirst()
                sessionRows[evicted] = nil
            }
        }
        sessionRows[sessionID] = rows
    }

    private func tearDownAllRows() {
        enteredRows.removeAll(keepingCapacity: true)
        wantedImages.removeAll(keepingCapacity: true)
        clearFindHighlight()
        rowViews.forEach { $0.removeFromSuperview() }
        rowViews = []
        renderedRows = []
    }

    /// A cache arrival (a decoded picture, a fetched subagent transcript) redraws exactly the rows
    /// it belongs to, in place: the view is swapped where it stands, every other row keeps its
    /// state, and nothing scrolls. It is not new content — the unseen counter never moves.
    private func replaceRows(where predicate: (TranscriptRow) -> Bool) {
        guard !placeholderShown else { return }
        preservingScroll { () -> Void in
            for index in renderedRows.indices where predicate(renderedRows[index]) {
                guard index < rowViews.count else { continue }
                if rowViews[index] === highlightedView { clearFindHighlight() }
                rowViews[index].removeFromSuperview()
                let rowView = renderedRows[index].makeView(context: context)
                rowsStack.insertArrangedSubview(rowView, at: index)
                rowViews[index] = rowView
            }
        }
        if followsBottom { schedulePinCorrector() }
    }

    /// A change to the column above where somebody is reading is a change to what they are reading.
    /// A stack view in a scroll view anchors nothing by itself, so a picture finishing its decode
    /// forty rows up, a subagent transcript arriving inside a card, or a backfill inserting at the
    /// top of the stack each move the words out from under a reader who has scrolled back — the
    /// heights above them changed and their scroll origin did not. The fixed point is the topmost
    /// row still on screen that the edit left standing: whatever happened to the column, that row is
    /// put back where it was and the origin follows it. A reader at the bottom already has an
    /// anchor — the pin — so
    /// nothing is measured for them, and an edit that only touched the tail moves the anchor by
    /// nothing and scrolls by nothing.
    @discardableResult
    private func preservingScroll<T>(_ mutate: () -> T) -> T {
        guard !followsBottom else { return mutate() }
        let anchors = visibleAnchors()
        guard !anchors.isEmpty else { return mutate() }
        let result = mutate()
        view.layoutSubtreeIfNeeded()
        guard let moved = anchorDrift(anchors), abs(moved) > 0.5 else { return result }
        let clip = scrollView.contentView
        isAutoScrolling = true
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: clip.bounds.origin.y + moved))
        scrollView.reflectScrolledClipView(clip)
        isAutoScrolling = false
        return result
    }

    /// The rows with anything of themselves on screen, each named by the key that identifies it and
    /// paired with where it sits in the canvas: the fixed points a reflow has to leave looking
    /// unchanged. Ordered from the topmost down and stopped at the foot of the viewport, because a
    /// correction wants whichever of them survived the edit and none of the rest.
    private func visibleAnchors() -> [(key: String, offset: CGFloat)] {
        let clip = scrollView.contentView
        let top = clip.bounds.origin.y + scrollView.contentInsets.top
        let foot = clip.bounds.origin.y + clip.bounds.height
        var anchors: [(key: String, offset: CGFloat)] = []
        for (index, rowView) in rowViews.enumerated() where rowView.superview != nil {
            guard index < renderedRows.count else { break }
            let frame = rowView.convert(rowView.bounds, to: canvas)
            guard frame.maxY > top else { continue }
            if !anchors.isEmpty, frame.minY > foot { break }
            anchors.append((renderedRows[index].key, frame.minY))
        }
        return anchors
    }

    /// How far the topmost row that survived the edit moved, or nothing if not one of them did.
    ///
    /// The anchor is a key looked up afterwards rather than a view held across the mutation, because
    /// the edits that most need anchoring are the ones that rebuild the very row being read: a batch
    /// repaint takes every stale row's view out and puts a new one back under the same key, so an
    /// anchor holding the old view finds it orphaned and abandons the correction — for every row
    /// below it as well, which is exactly when it was needed. A key that is gone entirely is a row
    /// that genuinely left, and then the next one still standing holds the column in its place.
    private func anchorDrift(_ anchors: [(key: String, offset: CGFloat)]) -> CGFloat? {
        for anchor in anchors {
            guard let index = renderedRows.firstIndex(where: { $0.key == anchor.key }),
                index < rowViews.count
            else { continue }
            let rowView = rowViews[index]
            guard rowView.superview != nil else { continue }
            return rowView.convert(rowView.bounds, to: canvas).minY - anchor.offset
        }
        return nil
    }

    /// A row with no picture yet says so as it is built; whether those bytes are worth crossing the
    /// tailnet for right now is the transcript's call rather than the row's.
    private func noteImageWanted(_ reference: FileReference, key: String) {
        guard ImageStore.shared.entry(forKey: key) == nil else { return }
        wantedImages[key] = reference
        scheduleImageSweep()
    }

    /// Rows leaving the stack take their unmet picture requests with them, wherever they leave from
    /// — a plan's removals, a window sliding, the tail being handed back to be redrawn.
    ///
    /// A want the transcript declined because its row was off screen must not become a fetch the
    /// moment that row falls out of the window: there is nothing left to paint it into, and the
    /// bytes would cross the tailnet for a picture nobody can see. Pruning is also what lets an
    /// absent key keep its one honest meaning in the sweep — a row the flow never rendered at all,
    /// which is a picture inside a card somebody has just opened. A row that comes back asks again
    /// as it is built, so nothing is lost by forgetting.
    private func forgetWantedImages(_ rows: some Sequence<TranscriptRow>) {
        guard !wantedImages.isEmpty else { return }
        for row in rows { wantedImages.removeValue(forKey: row.key) }
    }

    /// Coalesced to once a runloop hop: a sweep costs a layout pass and a scroll delivers its
    /// notification many times a frame.
    private func scheduleImageSweep() {
        guard !imageSweepScheduled, !wantedImages.isEmpty else { return }
        imageSweepScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.imageSweepScheduled = false
            self.sweepWantedImages()
        }
    }

    /// Pictures fetch themselves when a reader is within a screen of them, and not before. A
    /// placeholder is a fixed frame and the thumbnail that replaces it is the picture's own shape,
    /// so every image in a four-hundred-row transcript decoding on the first fill is four hundred
    /// height changes, most of them above whoever has scrolled back. A key the flow does not render
    /// is inside a card somebody has just opened — opening it *was* the request — so those are
    /// fetched at once rather than waited on, which holds only because a row that leaves takes its
    /// want with it (`forgetWantedImages`) and so cannot arrive here wearing a card's meaning.
    private func sweepWantedImages() {
        guard !wantedImages.isEmpty, !placeholderShown else { return }
        view.layoutSubtreeIfNeeded()
        let clip = scrollView.contentView
        let margin = max(clip.bounds.height, 400)
        let top = clip.bounds.origin.y - margin
        let bottom = clip.bounds.origin.y + clip.bounds.height + margin
        var reach: [String: Bool] = [:]
        for (index, row) in renderedRows.enumerated()
        where wantedImages[row.key] != nil && index < rowViews.count {
            let frame = rowViews[index].convert(rowViews[index].bounds, to: canvas)
            reach[row.key] = frame.maxY >= top && frame.minY <= bottom
        }
        let ready = wantedImages.filter { reach[$0.key] ?? true }
        for (key, reference) in ready {
            wantedImages.removeValue(forKey: key)
            fetchImage(reference, key: key)
        }
    }

    /// What the turn is waiting on, docked where the CLI's prompt would sit: approvals first,
    /// then questions. Rebuilt only when what is pending actually changes — this runs on every
    /// streamed token, and cards that flicker under a click swallow the click.
    private func renderPendingCards(_ state: ConversationState) {
        let compactionKey = state.compaction.map {
            $0.failure ?? "compacting:\($0.startedAt.timeIntervalSince1970):\(echoedPrompt != nil)"
        } ?? ""
        let signature =
            (state.pendingPermissions.map(\.id) + state.pendingQuestions.map(\.id))
            .joined(separator: "|") + "|" + compactionKey
        guard signature != pendingSignature else { return }
        pendingSignature = signature
        compactingElapsed = nil
        pendingStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for permission in state.pendingPermissions {
            pendingStack.addArrangedSubview(
                PendingCards.permission(permission) { [weak self] decision in
                    self?.respond(to: permission, decision: decision)
                })
        }
        for question in state.pendingQuestions {
            pendingStack.addArrangedSubview(
                PendingCards.question(question, in: entry) { [weak self] answers in
                    self?.answer(question, answers: answers)
                })
        }
        if let compaction = state.compaction {
            if let failure = compaction.failure {
                pendingStack.addArrangedSubview(PendingCards.compactionFailure(failure))
            } else {
                pendingStack.addArrangedSubview(
                    PendingCards.compacting(
                        startedAt: compaction.startedAt, waiting: echoedPrompt != nil
                    ) { [weak self] label in
                        self?.compactingElapsed = label
                    })
            }
        }
        if followsBottom { schedulePinCorrector() }
    }

    /// The running card's own clock line, moved by the transcript's one-second ticker rather than
    /// a rebuild — the card must hold still while its wait counts up.
    private func updateCompactingElapsed() {
        guard let label = compactingElapsed,
            let compaction = lastState?.compaction, compaction.isRunning
        else { return }
        label.stringValue = CompactionStory.elapsedLine(startedAt: compaction.startedAt)
    }

    /// Disk first, tailnet second: a picture this machine has ever shown comes back in one frame,
    /// and only a genuinely new one crosses the network — then joins the cache. The decode
    /// happens off the main actor, because a large PNG decoded on the UI loop is a visible freeze.
    private func fetchImage(_ reference: FileReference, key: String) {
        guard !inFlightImages.contains(key) else { return }
        inFlightImages.insert(key)
        let backend = backend
        Task { [weak self] in
            var data = await Task.detached { ImageDisk.load(reference) }.value
            if data == nil, let backend {
                data = try? await backend.attachmentData(reference)
                if let fetched = data {
                    await Task.detached { ImageDisk.save(fetched, for: reference) }.value
                }
            }
            guard let bytes = data else { return }
            let decodeTask = Task.detached { ImageStore.decode(bytes) }
            guard let decoded = await decodeTask.value else { return }
            guard let self else { return }
            ImageStore.shared.store(decoded, forKey: key)
            self.replaceRows { $0.key == key }
        }
    }

    private func fetchSubagent(_ call: ToolCall) {
        guard let backend, let entry, !inFlightSubagents.contains(call.id) else { return }
        inFlightSubagents.insert(call.id)
        let sessionID = entry.session.id
        Task { [weak self] in
            let agents = (try? await backend.subagents(for: sessionID)) ?? []
            let match = agents.first { $0.toolUseID == call.id }
            let messages: [ChatMessage]
            if let match {
                messages =
                    (try? await backend.subagentMessages(
                        sessionID: sessionID, agentID: match.id)) ?? []
            } else {
                messages = []
            }
            guard let self else { return }
            let rows = TranscriptRow.rows(for: messages)
            let callID = call.id
            self.context.subagentRows[callID] = rows
            self.replaceRows {
                if case .subagent(let spawned) = $0.kind { return spawned.id == callID }
                return false
            }
        }
    }

    /// Following is a decision, not a measurement: the intent is held here and re-applied
    /// whenever the content actually grows, so an unfocused chat never drifts up as it streams.
    private func observeScrolling() {
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrollBoundsChanged),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
        canvas.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(contentGrew),
            name: NSView.frameDidChangeNotification, object: canvas)
    }

    @objc private func scrollBoundsChanged() {
        scheduleImageSweep()
        guard !isAutoScrolling else { return }
        let atBottom = isNearBottom()
        followsBottom = atBottom
        if atBottom { clearUnseen() }
    }

    @objc private func contentGrew() {
        guard followsBottom else { return }
        schedulePinCorrector()
    }

    private func isNearBottom() -> Bool {
        let clip = scrollView.contentView
        let ceiling = maxScrollOrigin()
        return clip.bounds.origin.y >= ceiling - 60
    }

    private func maxScrollOrigin() -> CGFloat {
        let clip = scrollView.contentView
        return max(
            -scrollView.contentInsets.top,
            canvas.frame.height - clip.bounds.height + scrollView.contentInsets.bottom)
    }

    private func setFollowing(_ following: Bool) {
        followsBottom = following
        if following { pinToBottom() }
    }

    private func pinToBottom() {
        let clip = scrollView.contentView
        let target = maxScrollOrigin()
        guard abs(clip.bounds.origin.y - target) > 0.5 else { return }
        isAutoScrolling = true
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: target))
        scrollView.reflectScrolledClipView(clip)
        isAutoScrolling = false
    }

    /// Runs after the current layout pass has settled, so the pixels always match the intent.
    /// It is also the moment a freshly-filled transcript is revealed: built invisible, it first
    /// appears already settled at the bottom rather than sliding into place.
    private func schedulePinCorrector() {
        guard !pinScheduled else { return }
        pinScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pinScheduled = false
            self.view.layoutSubtreeIfNeeded()
            if self.followsBottom { self.pinToBottom() }
            if self.pendingReveal, self.fillComplete {
                self.pendingReveal = false
                self.canvas.alphaValue = 1
            }
        }
    }

    private func adjustScroll(_ transform: (CGFloat) -> CGFloat) {
        let clip = scrollView.contentView
        let target = min(
            max(-scrollView.contentInsets.top, transform(clip.bounds.origin.y)),
            maxScrollOrigin())
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: target))
        scrollView.reflectScrolledClipView(clip)
    }

    /// The gentlest scroll that shows a just-opened body: down only as far as the body's end (or
    /// the page can hold), and never past the point where the clicked header would leave the top —
    /// a header that flies off the screen is the person losing the very thing they pointed at.
    /// Runs on the next hop, once the body has its layout; a row already torn down by then is no
    /// longer in the canvas and moves nothing.
    private func revealDisclosure(_ row: NSView) {
        guard row.window != nil, row.isDescendant(of: canvas) else { return }
        view.layoutSubtreeIfNeeded()
        let frame = row.convert(row.bounds, to: canvas)
        let clip = scrollView.contentView
        let margin: CGFloat = 8
        let visibleTop = clip.bounds.origin.y + scrollView.contentInsets.top
        let visibleBottom =
            clip.bounds.origin.y + clip.bounds.height - scrollView.contentInsets.bottom
        let needed = frame.maxY + margin - visibleBottom
        let slack = frame.minY - margin - visibleTop
        let delta = min(needed, slack)
        guard delta > 0 else { return }
        isAutoScrolling = true
        adjustScroll { $0 + delta }
        isAutoScrolling = false
    }

    private func clearUnseen() {
        unseenRows = 0
        jumpGlass?.isHidden = true
    }

    private func noteAppendedWhileScrolledUp(_ count: Int) {
        guard count > 0 else { return }
        unseenRows += count
        jumpButton.title = Localized.text("↓ %@", "\(unseenRows)")
        jumpGlass?.isHidden = false
    }

    private func runFind(retarget: Bool) {
        let needle = findBar.query.lowercased()
        clearFindHighlight()
        guard !needle.isEmpty else {
            findMatches = []
            findBar.setCount("")
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

    /// "No matches" is a claim about the conversation, and the search only ever ran over the tail
    /// window — so a word waiting behind the "… N earlier rows" button is counted and named. An
    /// absence of results reads as an answer, and that one would be a lie about the transcript.
    private func updateFindCount() {
        guard findMatches.isEmpty else {
            findBar.setCount("\(findCursor + 1)/\(findMatches.count)")
            return
        }
        let needle = findBar.query.lowercased()
        let shown = Set(renderedRows.map(\.key))
        let earlier =
            needle.isEmpty
            ? 0
            : lastFullRows.filter {
                !shown.contains($0.key) && $0.searchText.lowercased().contains(needle)
            }.count
        findBar.setCount(
            earlier > 0
                ? Localized.text("%@ in earlier rows", "\(earlier)")
                : Localized.text("No matches"))
    }

    /// Marks the current match with a subtle accent ring, and on an explicit jump scrolls it to
    /// the upper third so the eye lands on the hit rather than hunting for it.
    private func applyFindHighlight(scroll: Bool) {
        guard findMatches.indices.contains(findCursor) else { return }
        let index = findMatches[findCursor]
        guard index < rowViews.count else { return }
        clearFindHighlight()
        let rowView = rowViews[index]
        rowView.wantsLayer = true
        highlightRestore = (
            rowView.layer?.backgroundColor, rowView.layer?.borderColor,
            rowView.layer?.borderWidth ?? 0, rowView.layer?.cornerRadius ?? 0)
        rowView.layer?.borderColor = MacTheme.Color.accent.withAlphaComponent(0.6).cgColor
        rowView.layer?.borderWidth = 2
        rowView.layer?.cornerRadius = 6
        rowView.layer?.backgroundColor = MacTheme.Color.findHit.cgColor
        highlightedView = rowView
        guard scroll else { return }
        followsBottom = false
        view.layoutSubtreeIfNeeded()
        let frame = rowView.convert(rowView.bounds, to: canvas)
        adjustScroll { _ in frame.minY - self.scrollView.contentView.bounds.height * 0.3 }
    }

    private func clearFindHighlight() {
        if let layer = highlightedView?.layer, let restore = highlightRestore {
            layer.backgroundColor = restore.background
            layer.borderColor = restore.border
            layer.borderWidth = restore.width
            layer.cornerRadius = restore.radius
        }
        highlightRestore = nil
        highlightedView = nil
    }

    /// Long machine-facing text — a compaction summary, a tool's full output — opens in its own
    /// reader window rather than cramped into the flow: title, the facts under it, the body at
    /// reading width, and a copy that hands over every byte.
    private func presentReader(title: String, subtitle: String?, body: String, mono: Bool) {
        let column = FillingStack()
        column.spacing = 0
        column.wantsLayer = true
        column.layer?.backgroundColor = MacTheme.Color.canvas.cgColor
        column.translatesAutoresizingMaskIntoConstraints = false

        if let subtitle {
            let header = RowKit.label(
                subtitle, font: MacTheme.Ramp.font(.panelFootnote), color: MacTheme.Color.tertiaryLabel)
            column.addArrangedSubview(
                RowKit.inset(header, leading: MacTheme.Spacing.l, top: MacTheme.Spacing.m))
            column.addArrangedSubview(RowKit.hairline(verticalPadding: 8))
        }

        if mono {
            let scrollable = NSTextView.scrollableTextView()
            let text = scrollable.documentView as? NSTextView
            text?.isEditable = false
            text?.string = body
            text?.font = MacTheme.Ramp.font(.code)
            text?.textColor = MacTheme.Color.label
            text?.drawsBackground = false
            text?.textContainerInset = NSSize(
                width: MacTheme.Spacing.l, height: MacTheme.Spacing.m)
            scrollable.drawsBackground = false
            scrollable.translatesAutoresizingMaskIntoConstraints = false
            column.addArrangedSubview(scrollable)
        } else {
            let content = TranscriptRow.richBody(body, context: context)
            let padded = FillingStack(views: [content])
            padded.edgeInsets = NSEdgeInsets(
                top: MacTheme.Spacing.m, left: MacTheme.Spacing.l, bottom: MacTheme.Spacing.l,
                right: MacTheme.Spacing.l)
            padded.translatesAutoresizingMaskIntoConstraints = false

            let scroll = NSScrollView()
            let clip = FlippedClipView()
            clip.drawsBackground = false
            scroll.contentView = clip
            scroll.documentView = padded
            scroll.hasVerticalScroller = true
            scroll.drawsBackground = false
            scroll.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                padded.leadingAnchor.constraint(equalTo: clip.leadingAnchor),
                padded.trailingAnchor.constraint(equalTo: clip.trailingAnchor),
                padded.topAnchor.constraint(equalTo: clip.topAnchor),
                padded.widthAnchor.constraint(equalTo: clip.widthAnchor),
            ])
            column.addArrangedSubview(scroll)
        }

        column.addArrangedSubview(RowKit.hairline())
        let toast = onToast
        let copy = RowKit.ActionButton(title: Localized.text("Copy")) {
            RowKit.copyToClipboard(body)
            toast?(Localized.text("Copied"))
        }
        copy.bezelStyle = .rounded
        let actions = NSStackView(views: [RowKit.spacer(), copy])
        actions.orientation = .horizontal
        actions.spacing = MacTheme.Spacing.s
        actions.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.s, left: MacTheme.Spacing.l, bottom: MacTheme.Spacing.m,
            right: MacTheme.Spacing.l)
        actions.translatesAutoresizingMaskIntoConstraints = false
        column.addArrangedSubview(actions)

        let window = FloatingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 600),
            styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = title
        window.contentView = column
        if let host = view.window {
            window.setFrameOrigin(
                NSPoint(x: host.frame.midX - 380, y: host.frame.midY - 300))
        } else {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
    }
}

/// A clip view whose origin is the top, so a transcript grows downwards like a terminal instead
/// of upwards like a default AppKit document.
private final class FlippedClipView: NSClipView {
    override var isFlipped: Bool { true }
}

/// Forwards drag-destination events to the transcript so the tiling host can treat every pane as
/// a place a chat can land.
private final class DropForwardingView: NSView {
    weak var owner: TranscriptViewController?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        owner?.adoptEffectiveAppearance()
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        owner?.onDragEntered?(sender) == true ? .copy : []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        owner?.onDragUpdated?(sender) ?? []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        owner?.onDragExited?()
    }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        true
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        owner?.onDragPerform?(sender) ?? false
    }
}
