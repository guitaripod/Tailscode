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

    /// Drag-a-chat-into-this-pane hooks, owned by the tiling host so every pane is a drop target.
    var onDragEntered: ((NSDraggingInfo) -> Bool)?
    var onDragUpdated: ((NSDraggingInfo) -> NSDragOperation)?
    var onDragExited: (() -> Void)?
    var onDragPerform: ((NSDraggingInfo) -> Bool)?

    private let scrollView = NSScrollView()
    private let canvas = NSStackView()
    private let rowsStack = NSStackView()
    private let pendingStack = NSStackView()
    private let earlierButton = RowKit.ActionButton(title: "") {}
    private let statusBand = StatusBandView()
    private var bandGlass: NSView?
    private let authBanner = NSStackView()
    private var authGlass: NSView?
    let composer = ComposerView()
    private let findBar = FindBar()
    private let jumpButton = RowKit.ActionButton(title: "") {}
    private let emptyLabel = NSTextField(labelWithString: "")
    private let chooserView = ChooserView()
    private var chooser: PaneChooser?
    private var composerGlass: NSView?
    private var jumpGlass: NSView?

    private let context = TranscriptContext()
    private let rowBuilder = TranscriptRowBuilder()
    private let identityLabel = NSTextField(labelWithString: "")

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

    /// What this pane is showing, read by the hub and the tiling host: the focused pane's entry
    /// is the window's "current chat", and a restored layout rebinds by these.
    var currentEntry: SessionEntry? { entry }
    var currentBackend: (any CodingAgentBackend)? { backend }
    var currentState: ConversationState? { lastState }

    let cascade = CascadePainter()
    private(set) var renderedRows: [TranscriptRow] = []
    private(set) var rowViews: [NSView] = []
    /// Keys that have already made their entrance. A row is rebuilt whenever its value changes —
    /// a thought growing its word count, a tool call reaching its result — and fading a rebuild in
    /// from nothing is a flicker, not an arrival. Only the first sight of a key animates.
    private var enteredRows: Set<String> = []
    private var lastFullRows: [TranscriptRow] = []
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
    private var pendingSignature = "\u{0}"
    private var sessionRows: [String: [TranscriptRow]] = [:]
    private var sessionRowOrder: [String] = []
    private var inFlightImages: Set<String> = []
    private var inFlightSubagents: Set<String> = []
    private var findMatches: [Int] = []
    private var findCursor = 0
    private var highlightedView: NSView?
    private var agents: [SubagentSummary] = []
    private var usage: AgentUsage?
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
        emptyLabel.font = MacTheme.Font.body()
        emptyLabel.textColor = MacTheme.Color.tertiaryLabel
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(emptyLabel)

        chooserView.isHidden = true
        chooserView.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(chooserView)

        identityLabel.font = MacTheme.Font.caption()
        identityLabel.textColor = MacTheme.Color.secondaryLabel
        identityLabel.lineBreakMode = .byTruncatingMiddle
        identityLabel.isHidden = true
        identityLabel.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(identityLabel)

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

            identityLabel.topAnchor.constraint(
                equalTo: container.safeAreaLayoutGuide.topAnchor, constant: MacTheme.Spacing.s),
            identityLabel.leadingAnchor.constraint(
                equalTo: container.leadingAnchor, constant: MacTheme.Spacing.l),
            identityLabel.trailingAnchor.constraint(
                lessThanOrEqualTo: findBar.leadingAnchor, constant: -MacTheme.Spacing.m),

            emptyLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),

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

    /// The scroll view owns its insets so content can run underneath the floating glass: the top
    /// inset tracks the toolbar, the bottom one tracks the composer capsule.
    override func viewDidLayout() {
        super.viewDidLayout()
        let bottom = (composerGlass?.frame.height ?? 0) + MacTheme.Spacing.m + MacTheme.Spacing.l
        let top = view.safeAreaInsets.top + MacTheme.Spacing.s
        let insets = NSEdgeInsets(top: top, left: 0, bottom: bottom, right: 0)
        if scrollView.contentInsets.bottom != insets.bottom
            || scrollView.contentInsets.top != insets.top
        {
            scrollView.contentInsets = insets
            if followsBottom { schedulePinCorrector() }
        }
    }

    func open(_ entry: SessionEntry, backend: any CodingAgentBackend) {
        guard self.entry?.session.id != entry.session.id || self.entry?.profileID != entry.profileID
        else { return }
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
        windowLimit = 400
        rowTailMessages = 300
        lastFullRows = []
        lastFullCount = 0
        followsBottom = true
        pendingSignature = "\u{0}"
        pendingStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        setFindShown(false)
        agents = []
        usage = nil
        contextEstimate = nil
        countedMessages = -1
        turnStartedAt = nil
        tickerTask?.cancel()
        tickerTask = nil
        agentStreamTask?.cancel()
        agentStreamTask = nil
        agentStreamSessionID = nil
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
            for await state in await conversation.states() {
                guard !Task.isCancelled, let self else { return }
                let tail = self.rowTailMessages
                let messages =
                    state.messages.count > tail
                    ? Array(state.messages.suffix(tail)) : state.messages
                let rows = self.rowBuilder.rows(for: messages)
                self.apply(state: state, rows: rows)
            }
        }
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
        identityLabel.isHidden = !visible
        refreshIdentity()
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
            view.addSubview(slot, positioned: .below, relativeTo: identityLabel)
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
            view.addSubview(slot, positioned: .below, relativeTo: identityLabel)
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

    /// A slot answers its own keys while it is focused; everything it does not claim goes on to
    /// the shortcut table, so the chat panes lose nothing to a slot in the grid.
    func handleVideoChord(_ chord: KeyChord) -> Bool {
        guard let video, !video.isAsking else { return false }
        guard let command = VideoCommand.command(for: chord) else { return false }
        video.handle(command)
        return true
    }

    /// Everything the pane draws for a conversation, out of the way while it holds a stream —
    /// walked rather than named so a new piece of chat chrome cannot forget to hide itself.
    private func setChatFurnitureVisible(_ visible: Bool) {
        for subview in view.subviews
        where subview !== identityLabel && subview !== video && subview !== page {
            subview.isHidden = !visible
        }
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
    /// difference between a closed pane and a leak that keeps rendering into nothing.
    func shutdownPane() {
        cascade.release()
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
        rowsStack.orientation = .vertical
        rowsStack.alignment = .width
        rowsStack.spacing = MacTheme.Spacing.m
        rowsStack.translatesAutoresizingMaskIntoConstraints = false

        pendingStack.orientation = .vertical
        pendingStack.alignment = .width
        pendingStack.spacing = MacTheme.Spacing.s
        pendingStack.translatesAutoresizingMaskIntoConstraints = false

        earlierButton.isHidden = true
        earlierButton.isBordered = false
        earlierButton.contentTintColor = MacTheme.Color.secondaryLabel
        earlierButton.font = MacTheme.Font.caption()

        canvas.orientation = .vertical
        canvas.alignment = .width
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
        composer.onSubmitPrompt = { [weak self] text, model, effort, attachments in
            self?.sendPrompt(text, model: model, effort: effort, attachments: attachments)
        }
        composer.onRunCommand = { [weak self] command, arguments in
            guard let conversation = self?.conversation else { return }
            Task { try? await conversation.run(command, arguments: arguments) }
        }
        composer.onCompactRequested = { [weak self] instruction in
            self?.presentCompactPreflight(initialInstruction: instruction)
        }
        composer.onStop = { [weak self] in self?.stopTurn() }
        composer.onToast = { [weak self] text in self?.onToast?(text) }
        composer.onAttachmentsChanged = { [weak self] in self?.updateStatus() }
        composer.onBrowseCommands = { [weak self] in self?.presentCommandCatalog() }

        let column = NSStackView(views: [composer])
        column.orientation = .vertical
        column.alignment = .width
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
        authBanner.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.s, left: MacTheme.Spacing.m, bottom: MacTheme.Spacing.s,
            right: MacTheme.Spacing.m)
        let auth = MacTheme.tintedGlass(
            around: authBanner, tint: MacTheme.Color.warning,
            cornerRadius: MacTheme.Radius.card)
        auth.isHidden = true
        authGlass = auth

        let host = NSStackView(views: [auth, band, card])
        host.orientation = .vertical
        host.alignment = .width
        host.spacing = MacTheme.Spacing.s
        host.translatesAutoresizingMaskIntoConstraints = false
        let group = MacTheme.glassGroup()
        group.contentView = host
        return group
    }

    private func configureJumpPill() -> NSView {
        jumpButton.isBordered = false
        jumpButton.font = MacTheme.Font.emphasis()
        jumpButton.contentTintColor = MacTheme.Color.label
        jumpButton.target = self
        jumpButton.action = #selector(jumpToBottom)
        let padded = NSStackView(views: [jumpButton])
        padded.edgeInsets = NSEdgeInsets(top: 6, left: 12, bottom: 6, right: 12)
        padded.translatesAutoresizingMaskIntoConstraints = false
        let glass = MacTheme.glass(around: padded, cornerRadius: 16)
        glass.isHidden = true
        return glass
    }

    private func configureFindBar() {
        findBar.isHidden = true
        findBar.onQueryChanged = { [weak self] _ in self?.runFind(retarget: true) }
        findBar.onStep = { [weak self] delta in self?.stepFind(by: delta) }
        findBar.onClose = { [weak self] in self?.setFindShown(false) }
    }

    private func wireContext() {
        context.onToggle = { [weak self] key, open in
            guard let self else { return }
            if open {
                self.context.expanded.insert(key)
            } else {
                self.context.expanded.remove(key)
            }
            if open, self.followsBottom { self.schedulePinCorrector() }
        }
        context.requestImage = { [weak self] reference, key in
            self?.fetchImage(reference, key: key)
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
                guard case .file(let reference) = row.kind,
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
        echoedPrompt = text
        if let state = lastState { apply(state: state, rows: lastFullRows) }
        Task {
            do {
                try await conversation.send(
                    text, model: model, reasoningEffort: effort, attachments: attachments)
            } catch {
                NSSound.beep()
            }
        }
    }

    /// `/compact` never fires bare: it is irreversible, takes minutes, and accepts an
    /// instruction for what the summary must keep — so it always opens this preflight first.
    func presentCompactPreflight(initialInstruction: String = "") {
        guard let conversation else { return }
        MacDialogs.prompt(
            on: view.window,
            title: Localized.text("Compact this conversation?"),
            body: Localized.text(
                "The transcript so far is replaced by a summary. This is irreversible, takes minutes, and the agent works from the summary afterwards."),
            placeholder: Localized.text("What must the summary keep? (optional)"),
            initial: initialInstruction,
            confirmLabel: Localized.text("Compact"), destructive: true
        ) { instruction in
            Task {
                try? await conversation.compact(
                    instructions: instruction.isEmpty ? nil : instruction)
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
        label.font = MacTheme.Font.caption()
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
        lastState = state
        onState?(state)
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
        lastFullRows = rows
        if let entry { rememberRows(rows, for: entry.session.id) }
        let appended = max(0, rows.count - lastFullCount)
        lastFullCount = rows.count
        let limit = max(windowLimit, Self.transcriptWindowPreference)
        let windowed = rows.count > limit ? Array(rows.suffix(limit)) : rows
        let hiddenCount = rows.count - windowed.count
        earlierButton.isHidden = hiddenCount <= 0
        if hiddenCount > 0 {
            earlierButton.title = Localized.text(
                "… %@ earlier rows — show more", "\(hiddenCount)")
        }
        if rows.isEmpty {
            cascade.release()
            showPlaceholder(
                state.hasLoadedTranscript
                    ? Localized.text("Nothing here yet. Say something.")
                    : Localized.text("Loading…"))
        } else {
            applyRows(
                pacedByCascade(windowed, running: state.status == .running), appended: appended)
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

    /// The band between transcript and composer: what the turn is doing, which agents are out,
    /// how much of the context is spent, what the goal is — every fact clickable, so reading the
    /// status and steering the turn are one gesture rather than two.
    private func updateStatus() {
        guard let state = lastState else {
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
            attachments: composer.attachmentCount, contextTokens: contextEstimate, quotas: quotas)
        let bandNotice = quotaNotice(state: state, quotas: quotas) ?? notice
        statusBand.render(facts: facts, notice: bandNotice)
        bandGlass?.isHidden = !statusBand.hasContent
    }

    /// Pre-emptive used-up quota on the band while idle — a failed turn already carries the
    /// rewritten phase, so this only speaks when the wall is up before the next send.
    private func quotaNotice(state: ConversationState, quotas: [UsageQuota]) -> String? {
        guard state.lastFailure == nil, state.status != .running else { return nil }
        return QuotaSurface.hottestExhausted(in: quotas).map(QuotaSurface.short)
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
    /// stops settles the agents list on "done" instead of freezing mid-flight glyphs.
    private func refreshTurnFacts() {
        guard let backend, let entry else { return }
        startAgentStreamIfAvailable()
        let sessionID = entry.session.id
        let skipAgents = agentStreamSessionID == sessionID && agentStreamTask != nil
        Task { [weak self] in
            let agents = skipAgents ? nil : ((try? await backend.subagents(for: sessionID)) ?? [])
            let usage = (try? await backend.sessionUsage(sessionID)) ?? nil
            guard let self, self.entry?.session.id == sessionID else { return }
            self.usage = usage
            if let agents {
                self.applyAgentSummaries(agents)
            } else {
                self.updateStatus()
            }
        }
    }

    /// A proto-2 bridge pushes each fan-out's live facts as they change; older servers are
    /// polled. Started lazily on the first turn tick after a chat opens.
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
            if !stale.isEmpty {
                replaceRows {
                    if case .workflow(let call) = $0.kind { return stale.contains(call.id) }
                    return false
                }
            }
        }
        updateTicker(running: state.status == .running)
    }

    /// A background run outlives the turn that launched it, so the clock every live card is drawn
    /// against keeps moving after the turn ends — a frozen elapsed reads as a hang.
    private func advanceWorkflowClock() {
        guard workflowRuns.contains(where: \.isLive) else { return }
        context.workflowNow = Date()
        let live = Set(workflowRuns.filter(\.isLive).map(\.id))
        refreshWorkflowRuns()
        replaceRows {
            if case .workflow(let call) = $0.kind { return live.contains(call.id) }
            return false
        }
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
                if case .workflow = $0.kind { return true }
                return false
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
        guard let conversation, let window = view.window else { return }
        let hasGoal = lastState?.goal != nil
        let alert = NSAlert()
        alert.messageText = Localized.text("Change the goal")
        alert.informativeText = Localized.text(
            "The agent pursues the goal across turns and reports when it is met.")
        let field = NSTextField(string: lastState?.goal?.condition ?? "")
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
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                let condition = field.stringValue.trimmingCharacters(
                    in: .whitespacesAndNewlines)
                guard !condition.isEmpty else { return }
                Task { try? await conversation.setGoal(condition) }
            } else if hasGoal, response == .alertSecondButtonReturn {
                Task { try? await conversation.clearGoal() }
            }
        }
    }

    /// Re-renders every row at the current type scale: the builder's memo and the per-session
    /// row snapshots hold rendering baked at the old size, so both are dropped before the
    /// rebuild.
    func applyUIScale() {
        rowBuilder.invalidate()
        sessionRows = [:]
        sessionRowOrder = []
        pendingSignature = "\u{0}"
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
    func restateChooser(servers: [PaneChooserServer], entries: [SessionEntry]) {
        guard let current = chooser else { return }
        chooser = current.restated(servers: servers, entries: entries)
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
    /// after a ten-chunk climb. While streaming, everything before the first changed row keeps
    /// its view — and its disclosure state, its selection, its scroll cost — and a token appended
    /// to the last message rebuilds one row, not the conversation.
    ///
    /// `renderedRows` is always a contiguous slice of the applied row list that reaches its end;
    /// where that slice starts is re-found by key on every pass, because the window slides.
    /// A streamed token changes exactly one row, and rebuilding its view for every arrival is what
    /// makes a live answer flicker: the label is torn down and remade dozens of times a second,
    /// which restarts its entrance, drops any selection inside it, and asks the whole column to lay
    /// out again. When the only difference is more words in a row that can take them where it
    /// stands — the answer the painter is holding, or a thought counting itself up — the change is
    /// written into the view and the bookkeeping moves with it.
    private func updatedLastRowInPlace(_ rows: [TranscriptRow]) -> Bool {
        guard !placeholderShown, fillComplete,
            renderedRows.count == rows.count, let last = rows.indices.last, last > 0,
            renderedRows[last].key == rows[last].key, renderedRows[last] != rows[last],
            last < rowViews.count,
            renderedRows.dropLast().elementsEqual(rows.dropLast())
        else { return false }
        switch (renderedRows[last].kind, rows[last].kind) {
        case (.agentProse, .agentProse), (.codeBlock, .codeBlock):
            guard rows[last].key == cascade.key else { return false }
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

    private func applyRows(_ rows: [TranscriptRow], appended: Int = 0) {
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
                for viewToDrop in rowViews[..<anchor.rendered] {
                    if viewToDrop === highlightedView { clearFindHighlight() }
                    viewToDrop.removeFromSuperview()
                }
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
                renderedRows[same] == rows[start + same]
            {
                same += 1
            }
            for viewToDrop in rowViews[same...] {
                if viewToDrop === highlightedView { clearFindHighlight() }
                viewToDrop.removeFromSuperview()
            }
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
                position += 1
            }
            renderedRows.insert(contentsOf: rows[from..<start], at: 0)
            rowViews.insert(contentsOf: inserted, at: 0)
            start = from
        }

        let complete = tailDone && start == 0
        fillComplete = complete
        if !complete {
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
                        let rows = self.lastFullRows
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
        if complete, !findBar.isHidden { runFind(retarget: false) }
    }

    private func appendRowViews(_ rows: ArraySlice<TranscriptRow>) {
        let entering = !placeholderShown && !pendingReveal && fillComplete && followsBottom
        for (offset, row) in rows.enumerated() {
            let rowView = row.makeView(context: context)
            rowsStack.addArrangedSubview(rowView)
            let firstSight = enteredRows.insert(row.key).inserted
            if entering, firstSight, row.key != cascade.key {
                CascadeEntrance.animate(rowView, index: offset, of: rows.count)
            }
            rowViews.append(rowView)
            renderedRows.append(row)
        }
    }



    /// The wave letting go of a row is not the same as the row being rebuilt. A turn that simply
    /// ends leaves the rows identical, so the diff has nothing to do and the last glyphs would keep
    /// the heat of a stream that stopped — the row has to be handed back whole by hand.
    func settleCascade(on key: String, in rows: [TranscriptRow]) {
        guard let index = renderedRows.lastIndex(where: { $0.key == key }),
            index < rowViews.count,
            let label = Self.streamedLabel(in: rowViews[index], kind: renderedRows[index].kind)
        else { return }
        let row = rows.last(where: { $0.key == key }) ?? renderedRows[index]
        switch row.kind {
        case .agentProse(_, let rendered):
            label.attributedStringValue = rendered
        case .codeBlock(_, let body):
            label.stringValue = body
        default:
            break
        }
    }

    /// A code block's body as the row already draws it, so the wave tints the same glyphs the
    /// settled row shows rather than restyling them on its way past.
    static func codeRendering(_ body: String) -> NSAttributedString {
        NSAttributedString(
            string: body,
            attributes: [.font: MacTheme.Font.mono(12), .foregroundColor: MacTheme.Color.label])
    }

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
        for index in renderedRows.indices where predicate(renderedRows[index]) {
            guard index < rowViews.count else { continue }
            if rowViews[index] === highlightedView { clearFindHighlight() }
            rowViews[index].removeFromSuperview()
            let rowView = renderedRows[index].makeView(context: context)
            rowsStack.insertArrangedSubview(rowView, at: index)
            rowViews[index] = rowView
        }
        if followsBottom { schedulePinCorrector() }
    }

    /// What the turn is waiting on, docked where the CLI's prompt would sit: approvals first,
    /// then questions. Rebuilt only when what is pending actually changes — this runs on every
    /// streamed token, and cards that flicker under a click swallow the click.
    private func renderPendingCards(_ state: ConversationState) {
        let signature =
            (state.pendingPermissions.map(\.id) + state.pendingQuestions.map(\.id))
            .joined(separator: "|") + "|" + (state.compaction?.failure ?? "")
        guard signature != pendingSignature else { return }
        pendingSignature = signature
        pendingStack.arrangedSubviews.forEach { $0.removeFromSuperview() }
        for permission in state.pendingPermissions {
            pendingStack.addArrangedSubview(
                PendingCards.permission(permission) { [weak self] decision in
                    self?.respond(to: permission, decision: decision)
                })
        }
        for question in state.pendingQuestions {
            pendingStack.addArrangedSubview(
                PendingCards.question(question) { [weak self] answers in
                    self?.answer(question, answers: answers)
                })
        }
        if let compaction = state.compaction, let failure = compaction.failure {
            pendingStack.addArrangedSubview(PendingCards.compactionFailure(failure))
        }
        if followsBottom { schedulePinCorrector() }
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

    private func clearUnseen() {
        unseenRows = 0
        jumpGlass?.isHidden = true
    }

    private func noteAppendedWhileScrolledUp(_ count: Int) {
        guard count > 0 else { return }
        unseenRows += count
        jumpButton.title = "↓ \(unseenRows)"
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

    private func updateFindCount() {
        findBar.setCount(
            findMatches.isEmpty
                ? Localized.text("No matches") : "\(findCursor + 1)/\(findMatches.count)")
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
        rowView.layer?.borderColor = MacTheme.Color.accent.withAlphaComponent(0.6).cgColor
        rowView.layer?.borderWidth = 2
        rowView.layer?.cornerRadius = 6
        highlightedView = rowView
        guard scroll else { return }
        followsBottom = false
        view.layoutSubtreeIfNeeded()
        let frame = rowView.convert(rowView.bounds, to: canvas)
        adjustScroll { _ in frame.minY - self.scrollView.contentView.bounds.height * 0.3 }
    }

    private func clearFindHighlight() {
        highlightedView?.layer?.borderWidth = 0
        highlightedView = nil
    }

    /// Long machine-facing text — a compaction summary, a tool's full output — opens in its own
    /// reader window rather than cramped into the flow: title, the facts under it, the body at
    /// reading width, and a copy that hands over every byte.
    private func presentReader(title: String, subtitle: String?, body: String, mono: Bool) {
        let column = NSStackView()
        column.orientation = .vertical
        column.alignment = .width
        column.spacing = 0
        column.translatesAutoresizingMaskIntoConstraints = false

        if let subtitle {
            let header = RowKit.label(
                subtitle, font: MacTheme.Font.caption(), color: MacTheme.Color.tertiaryLabel)
            column.addArrangedSubview(
                RowKit.inset(header, leading: MacTheme.Spacing.l, top: MacTheme.Spacing.m))
            column.addArrangedSubview(RowKit.hairline(verticalPadding: 8))
        }

        if mono {
            let scrollable = NSTextView.scrollableTextView()
            let text = scrollable.documentView as? NSTextView
            text?.isEditable = false
            text?.string = body
            text?.font = MacTheme.Font.mono(12)
            text?.textContainerInset = NSSize(
                width: MacTheme.Spacing.l, height: MacTheme.Spacing.m)
            scrollable.drawsBackground = false
            scrollable.translatesAutoresizingMaskIntoConstraints = false
            column.addArrangedSubview(scrollable)
        } else {
            let content = TranscriptRow.richBody(body, context: context)
            let padded = NSStackView(views: [content])
            padded.orientation = .vertical
            padded.alignment = .width
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
