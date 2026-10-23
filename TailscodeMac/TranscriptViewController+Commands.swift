import AppKit
import os
import CodingAgentKit
import TailscodeCore

extension TranscriptViewController {
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

    /// The words of the answer a row of prose belongs to, found the way the hover capsule finds
    /// it: the message whose id leads the row's key.
    func copyAnswer(ofRowKey key: String) {
        guard
            let message = lastState?.messages.last(where: {
                $0.role == .assistant && key.hasPrefix($0.id + ":")
            })
        else { return }
        let words = MessageHover.words(of: message)
        guard !words.isEmpty else { return }
        RowKit.copyToClipboard(words)
        onToast?(Localized.text("Copied"))
    }

    /// The newest answer's own words on the pasteboard, said with the toast a Copy always says.
    /// False when the conversation has no answer to copy yet.
    @discardableResult
    func copyLastAnswer() -> Bool {
        guard
            let message = lastState?.messages.last(where: {
                $0.role == .assistant && !MessageHover.words(of: $0).isEmpty
            })
        else { return false }
        RowKit.copyToClipboard(MessageHover.words(of: message))
        onToast?(Localized.text("Copied"))
        return true
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
    ///
    /// The moment travels in with the facts. A row's clock is a reading of this arrival rather than
    /// of whenever the row happened to be built, so a card drawn between two polls states the time
    /// the facts on it are from.
    func applyAgentFacts(_ facts: [String: SubagentSummary]) {
        context.agentReadAt = Date()
        let changed = facts.keys.filter { context.agentFacts[$0] != facts[$0] }
        let vanished = context.agentFacts.keys.filter { facts[$0] == nil }
        context.agentFacts = facts
        let stale = Set(changed + vanished)
        guard !stale.isEmpty else { return }
        replaceRows {
            $0.kind.spawnedCalls.contains { stale.contains($0.id) }
        }
    }

    static var transcriptWindowPreference: Int {
        let stored = UserDefaults.standard.integer(forKey: "tailscode.transcriptWindow")
        return stored == 0 ? 400 : min(5000, max(50, stored))
    }

    /// `/compact` never fires bare: it is irreversible, takes minutes, and accepts an
    /// instruction for what the summary must keep where the server takes one — so it always
    /// `/design` opens the shared decision screen too: it spends a whole turn drawing pictures on
    /// somebody else's machine, and the brief leaves as an ordinary prompt so the board it produces
    /// lands in this transcript.
    func presentDesignPreflight(request: String = "") {
        MacDialogs.designPreflight(on: view.window, request: request) { [weak self] brief in
            guard let self else { return }
            guard self.composer.sendAgain(brief.prompt) else {
                self.onToast?(Localized.text("Send or clear what is in the composer first."))
                return
            }
        }
    }

    /// Opens the packet composer on this chat's machine, with the words as the goal and the chat's
    /// own directory as the repository. The road goes through the same gate as every other door.
    func handOff(goal: String) {
        guard let entry, !entry.host.isEmpty,
            let host = view.window?.windowController as? MainWindowController
        else { return }
        let handoff = DelegateHandoff(
            host: entry.host, serverName: entry.profileName, goal: goal,
            repo: entry.session.directory ?? "")
        AppLogger.session.info("delegate handoff from session \(entry.session.id) to \(entry.host)")
        host.presentDelegate(handoff: handoff)
    }

    /// What a board turned out to be, so its card names it rather than its folder. Asked once per
    /// directory: a card that only ever names a folder makes the reader open a board to find out
    /// whether it is worth opening.
    func readDesignBoard(_ directory: String) {
        guard let files = backend as? any FileBrowsingBackend,
            context.designBoards[directory] == nil,
            inFlightDesignBoards.insert(directory).inserted
        else { return }
        let path = DesignPaths.manifest(in: directory)
        Task { [weak self] in
            let text = try? await files.fileContent(path: path)
            await MainActor.run { [weak self] in
                guard let self, let text, let manifest = DesignManifest.parse(text) else { return }
                self.context.designBoards[directory] = manifest
                self.replaceRows { row in
                    guard case .designBoard(let sighting) = row.kind else { return false }
                    return sighting.source == .board(directory: directory)
                }
            }
        }
    }

    /// A board opens in a window of its own; a design published somewhere else is handed to the
    /// system, which is the only thing that can open it.
    func openDesign(_ source: DesignSource) {
        switch source {
        case .board(let directory):
            guard let backend else { return }
            let board = DesignBoardWindowController(directory: directory, backend: backend) {
                [weak self] prompt in
                guard let self else { return }
                guard self.composer.sendAgain(prompt) else {
                    self.onToast?(Localized.text("Send or clear what is in the composer first."))
                    return
                }
            }
            designBoard = board
            board.present()
        case .artifact(let url):
            guard let link = URL(string: url) else { return }
            NSWorkspace.shared.open(link)
        }
    }

    /// opens the shared decision screen first, whose every word is ``CompactPreflight``'s.
    func presentCompactPreflight(initialInstruction: String = "") {
        guard conversation != nil, let entry else { return }
        MacDialogs.compactPreflight(
            on: view.window,
            facts: CompactPreflight.make(
                state: lastState,
                showsInstruction: backend?.capabilities.supportsCompactionInstructions ?? true),
            initialInstruction: initialInstruction,
            draft: .compaction(profileID: entry.profileID, sessionID: entry.session.id)
        ) { [weak self] instruction in
            self?.requestCompaction(instruction: instruction ?? "")
        }
    }

    /// A compaction is a turn like any other, so one asked for while a turn runs waits behind
    /// it rather than cutting it off — oh-my-pi aborts the active turn for a compaction, and
    /// every server refuses two turns at once. It is queued as the command it is, so the
    /// waiting row reads `/compact` and drains through the command route, never as words.
    func requestCompaction(instruction: String) {
        let arguments = instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        let choice = composer.promptChoice
        let send = QueuedSend(
            text: arguments, model: choice.model, effort: choice.effort,
            kind: .command(name: "compact", arguments: arguments))
        if lastState?.status == .running || lastState?.compaction?.isRunning == true
            || !queueDisplay.isEmpty || handoff.isOpen
        {
            hold(send)
            if let state = lastState { apply(state: state, rows: lastFullRows) }
            scrollToBottom()
            return
        }
        runCommand(send)
    }

    /// A command goes out without an echo row: it is a turn the server runs from its own
    /// catalog, and no backend writes a user message for an echo to reconcile against, so a
    /// pending row would say "still sending" for the rest of the conversation.
    func runCommand(_ send: QueuedSend) {
        guard let conversation, case .command(let name, let arguments) = send.kind else { return }
        SlashRecents.record(name)
        openHandoff()
        Task { [weak self] in
            do {
                try await conversation.run(
                    AgentCommand(name: name, details: "", source: .builtin),
                    arguments: arguments.isEmpty ? nil : arguments, model: send.model,
                    reasoningEffort: send.effort)
            } catch {
                self?.handoff.end()
                self?.onToast?(AgentErrorText.readable(error))
            }
        }
    }

    /// A signed-out Claude is a state, not a reply: the CLI answers every turn with "Not logged
    /// in" instead of failing, so the warning lives here — above the prompt box someone is about
    /// to type into — with the one button that fixes it. Never "open a terminal".
    func refreshAuthBanner() {
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
        let label = NSTextField(wrappingLabelWithString: "")
        label.attributedStringValue = RowKit.symbolText(
            "exclamationmark.triangle",
            Localized.text(
                "Claude is signed out on %@ — every turn will refuse until it signs in.", name),
            font: MacTheme.Ramp.font(.panelFootnote), color: MacTheme.Color.label)
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

    func respond(to permission: PermissionRequest, decision: PermissionDecision) {
        guard let conversation else { return }
        Task { [weak self] in
            do {
                try await conversation.respond(to: permission, decision: decision)
            } catch {
                self?.onToast?(AgentErrorText.readable(error))
            }
        }
    }

    /// Claude answers by message, so the answer goes out through the ordinary send path — a
    /// bridge busy with a live turn refuses a side-channel call but queues a message. The card
    /// is settled only once the server has taken the message: an answer that did not go leaves the
    /// question standing, with the reason, instead of losing the words behind a card that vanished.
    /// A press while the first is still on the wire is ignored so one answer cannot go twice.
    func answer(_ question: QuestionRequest, answers: [[String]]) {
        guard let conversation, answeringQuestions.insert(question.id).inserted else { return }
        let byMessage = backend?.capabilities.answersQuestionsByMessage == true
        Task { [weak self] in
            do {
                if byMessage {
                    try await conversation.send(question.answerMessage(answers))
                    await conversation.markAnswered(question)
                } else {
                    try await conversation.answer(question, answers: answers)
                }
            } catch {
                self?.onToast?(AgentErrorText.readable(error))
            }
            self?.answeringQuestions.remove(question.id)
        }
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

    /// Long machine-facing text — a compaction summary, a tool's full output — opens in its own
    /// reader window rather than cramped into the flow: title, the facts under it, the body at
    /// reading width, and a copy that hands over every byte.
    func presentReader(title: String, subtitle: String?, body: String, mono: Bool) {
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
        window.contentMinSize = NSSize(width: 420, height: 280)
        if !window.restoreFrame(named: "TailscodeReader") {
            if let host = view.window {
                window.setFrameOrigin(
                    NSPoint(x: host.frame.midX - 380, y: host.frame.midY - 300))
            } else {
                window.center()
            }
        }
        window.makeKeyAndOrderFront(nil)
    }
}
