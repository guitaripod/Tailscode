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

    private let scrollView = NSScrollView()
    private let canvas = NSStackView()
    private let rowsStack = NSStackView()
    private let pendingStack = NSStackView()
    private let earlierButton = RowKit.ActionButton(title: "") {}
    private let statusLine = NSTextField(labelWithString: "")
    let composer = ComposerView()
    private let findBar = FindBar()
    private let jumpButton = RowKit.ActionButton(title: "") {}
    private let emptyLabel = NSTextField(labelWithString: "")
    private var composerGlass: NSView?
    private var jumpGlass: NSView?

    private let context = TranscriptContext()
    private let rowBuilder = TranscriptRowBuilder()

    private var conversation: AgentConversation?
    private var streamTask: Task<Void, Never>?
    private var backend: (any CodingAgentBackend)?
    private var entry: SessionEntry?
    private var lastState: ConversationState?

    private var renderedRows: [TranscriptRow] = []
    private var rowViews: [NSView] = []
    private var lastFullRows: [TranscriptRow] = []
    private var lastFullCount = 0
    private var windowLimit = 400
    private var rowTailMessages = 300
    private var placeholderShown = true
    private var currentPlaceholder: String?
    private var pendingReveal = false
    private var fillComplete = false
    private var isFillingInChunks = false
    private var followsBottom = true
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

    override func loadView() {
        let container = NSView()
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

            emptyLabel.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: container.centerYAnchor),
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

    /// The status line doubles as the notice line until the status band phase: a delete that
    /// failed or a broken keybindings file has to say so somewhere visible today.
    func setNotice(_ text: String) {
        statusLine.isHidden = false
        statusLine.stringValue = text
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

    /// Live facts for the running fan-out, delivered by the hub in a later phase: the cards
    /// re-paint in place so a working agent's progress line ticks without touching the scroll.
    func applyAgentFacts(_ facts: [String: SubagentSummary]) {
        context.agentFacts = facts
        replaceRows {
            if case .subagent = $0.kind { return true }
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

    /// The whole writing surface — chips, prompt box, pills — is one glass card inside one glass
    /// group, so its neighbouring shapes read as a single wet surface and merge when they touch.
    private func configureComposerLayer() -> NSView {
        statusLine.font = MacTheme.Font.mono(11)
        statusLine.textColor = MacTheme.Color.secondaryLabel
        statusLine.isHidden = true
        statusLine.lineBreakMode = .byTruncatingTail
        statusLine.translatesAutoresizingMaskIntoConstraints = false

        composer.isHidden = true
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

        let column = NSStackView(views: [statusLine, composer])
        column.orientation = .vertical
        column.alignment = .width
        column.spacing = MacTheme.Spacing.xs
        column.edgeInsets = NSEdgeInsets(
            top: MacTheme.Spacing.s, left: MacTheme.Spacing.m, bottom: MacTheme.Spacing.s,
            right: MacTheme.Spacing.m)
        column.translatesAutoresizingMaskIntoConstraints = false

        let card = MacTheme.glass(around: column, cornerRadius: MacTheme.Radius.card)
        let host = NSView()
        host.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(card)
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            card.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            card.topAnchor.constraint(equalTo: host.topAnchor),
            card.bottomAnchor.constraint(equalTo: host.bottomAnchor),
        ])
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
        context.openImage = { [weak self] key, name in
            guard let self, let entry = ImageStore.shared.entry(forKey: key) else { return }
            ImageViewer.present(
                entry: entry, name: name, host: self.view.window,
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
        guard let conversation, let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = Localized.text("Compact this conversation?")
        alert.informativeText = Localized.text(
            "The transcript so far is replaced by a summary. This is irreversible, takes minutes, and the agent works from the summary afterwards."
        )
        let field = NSTextField(string: initialInstruction)
        field.placeholderString = Localized.text("What must the summary keep? (optional)")
        field.frame = NSRect(x: 0, y: 0, width: 340, height: 24)
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        let confirm = alert.addButton(withTitle: Localized.text("Compact"))
        confirm.hasDestructiveAction = true
        alert.addButton(withTitle: Localized.text("Cancel"))
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn else { return }
            let instruction = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            Task {
                try? await conversation.compact(
                    instructions: instruction.isEmpty ? nil : instruction)
            }
        }
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
            showPlaceholder(
                state.hasLoadedTranscript
                    ? Localized.text("Nothing here yet. Say something.")
                    : Localized.text("Loading…"))
        } else {
            applyRows(windowed, appended: appended)
        }
        renderPendingCards(state)
        composer.noteState(state)
        statusLine.isHidden = state.status != .running
        statusLine.stringValue = Localized.text("Working…")
    }

    private func showPlaceholder(_ text: String) {
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
    private func applyRows(_ rows: [TranscriptRow], appended: Int = 0) {
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
        for row in rows {
            let rowView = row.makeView(context: context)
            rowsStack.addArrangedSubview(rowView)
            rowViews.append(rowView)
            renderedRows.append(row)
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
