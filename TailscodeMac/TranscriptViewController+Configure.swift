import AppKit
import os
import CodingAgentKit
import TailscodeCore

extension TranscriptViewController {
    /// The page, read top-down. Every place this controller asks where a row stands — the prompt
    /// that rises to the top, the rows a reflow keeps still, the pictures near the reader, a find
    /// hit, a disclosure opened, the newest agent — compares that row's frame in the page with a
    /// clip whose origin is the top. Measured up from the bottom instead, as a stack view
    /// measures, a prompt sent at the foot of a long conversation read as standing near its head,
    /// and the rise scrolled the whole transcript to the top.
    static func page() -> FillingStack {
        FillingStack(topDown: true)
    }

    func configureCanvas() {
        rowColumn.spacing = MacTheme.Spacing.m
        rowColumn.metrics = ChatLayout.metrics
        rowColumn.translatesAutoresizingMaskIntoConstraints = false
        NotificationCenter.default.addObserver(
            self, selector: #selector(chatDensityChanged), name: ChatDensitySetting.didChange,
            object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(shortcutsReloaded), name: MainWindowController.shortcutsDidReload,
            object: nil)

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
        canvas.addArrangedSubview(rowColumn)
        canvas.addArrangedSubview(pendingStack)
    }

    func configureScroll() {
        let clip = FlippedClipView()
        clip.drawsBackground = false
        scrollView.contentView = clip
        scrollView.documentView = canvas
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.automaticallyAdjustsContentInsets = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        let leading = canvas.leadingAnchor.constraint(equalTo: clip.leadingAnchor)
        let trailing = canvas.trailingAnchor.constraint(equalTo: clip.trailingAnchor)
        trailing.priority = .defaultHigh
        let width = canvas.widthAnchor.constraint(equalTo: clip.widthAnchor)
        NSLayoutConstraint.activate([
            leading, trailing, canvas.topAnchor.constraint(equalTo: clip.topAnchor), width,
        ])
        canvasWidth = width
    }

    /// The whole floating layer — the status capsule and the writing card — is one glass group,
    /// so its neighbouring shapes read as a single wet surface and merge when they touch. The
    /// band is its own glass shape above the composer's: two facts, two capsules.
    func configureComposerLayer() -> NSView {
        statusBand.perform = { [weak self] action in self?.onBandAction?(action) }

        composer.isHidden = true
        cascade.onFrame = { [weak self] in self?.paintCascadeFrame() }
        cascade.onStalled = { [weak self] in self?.giveUpCascade() }
        context.editQueued = { [weak self] id in self?.editQueued(id) }
        context.resumeQueue = { [weak self] in self?.resumeQueue() }
        context.pendingAct = { [weak self] id, act in self?.actOnPending(id, act) }
        context.resumeAct = { [weak self] id, act in self?.actOnResume(id, act) }
        composer.onTakeBackQueued = { [weak self] in self?.takeBackLastQueued() ?? false }
        composer.isEditingQueued = { [weak self] in self?.editingQueued != nil }
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
        composer.onDesignRequested = { [weak self] request in
            self?.presentDesignPreflight(request: request)
        }
        composer.onDelegateRequested = { [weak self] goal in
            self?.handOff(goal: goal)
        }
        composer.onStop = { [weak self] in self?.stopTurn() }
        composer.onLane = { [weak self] lane in
            guard let self,
                let host = self.view.window?.windowController as? MainWindowController
            else { return }
            switch lane {
            case .chat: self.composer.takeFocus()
            case .ask: host.summonQuickAsk()
            case .video: host.presentStudio(lane: .video, brief: self.composer.currentText)
            case .image: host.presentStudio(lane: .image, brief: self.composer.currentText)
            }
        }
        composer.onToast = { [weak self] text in self?.onToast?(text) }
        composer.onDialToast = { [weak self] text in self?.onDialToast?(text) }
        composer.onMoveToServer = { [weak self] profileID, plan in
            guard let self,
                let host = self.view.window?.windowController as? MainWindowController,
                let profile = ServerDirectory.shared.profiles.first(where: { $0.id == profileID })
            else { return }
            host.presentNewChat(on: profile, carrying: plan)
        }
        composer.onAttachmentsChanged = { [weak self] in self?.updateStatus() }
        composer.onModelChanged = { [weak self] in self?.updateStatus() }
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

        calls.onEntryChanged = { [weak self] entry in self?.composer.setCallEntry(entry) }
        composer.onCall = { [weak self] in self?.calls.pressEntry() }

        let host = FillingStack(views: [auth, band, calls.glass, card])
        host.spacing = MacTheme.Spacing.m
        host.translatesAutoresizingMaskIntoConstraints = false
        let group = MacTheme.glassGroup()
        group.contentView = host
        return group
    }

    func configureJumpPill() -> NSView {
        jumpChip.symbol = "arrow.down"
        jumpChip.target = self
        jumpChip.action = #selector(jumpToBottom)
        jumpChip.isHidden = true
        applyJumpReading()
        return jumpChip
    }

    /// A state drawn as though the conversation had just emitted it, for a harness that has no
    /// server to emit one.
    /// The rows for a conversation as it stands: the builder's, with the question or approval that
    /// waits on the person marked on its node, so the brain can say it. The builder owns the memo
    /// and the brain's reading of the turns, and this is the one place the state is handed to it.
    func buildRows(_ messages: [ChatMessage], state: ConversationState) -> [TranscriptRow] {
        rowBuilder.catalog = composer.catalog
        return rowBuilder.rows(
            for: messages, turnOpen: state.status == .running,
            awaiting: brains.isActive ? BrainStore.awaiting(for: state) : .none)
    }

    /// The rows rebuilt from the state the pane holds, for a choice that changes what they are: a
    /// brain opened or closed, its old rows listed, the style changed.
    func rebuildRows() {
        guard let state = lastState, !placeholderShown else { return }
        let tail = rowTailMessages
        let messages =
            state.messages.count > tail ? Array(state.messages.suffix(tail)) : state.messages
        let built = buildRows(messages, state: state)
        showRows(state: state, rows: built)
    }

    @objc private func activityStyleChanged() {
        guard isViewLoaded else { return }
        brains.clear()
        rebuildRows()
    }

    func show(state: ConversationState) {
        apply(state: state, rows: buildRows(state.messages, state: state))
    }

    func refreshJumpReading() { applyJumpReading() }

    /// What the control says: the bare arrow, how many rows arrived while the reader was away, or
    /// that something at the end is waiting for them — the one fact that stops the turn.
    func applyJumpReading() {
        let waiting =
            lastState.map { !$0.pendingPermissions.isEmpty || !$0.pendingQuestions.isEmpty }
            ?? false
        let reading = JumpReading.read(
            rowsNow: renderedRows.count, rowsAtDeparture: rowsAtDeparture, needsYou: waiting)
        jumpChip.symbol = waiting ? ActivityKind.needsApproval.icon.symbol : "arrow.down"
        jumpChip.text = reading.label ?? ""
        jumpChip.glyphTone = reading.tone == .attention ? .attention : nil
        jumpChip.toolTip = reading.spoken
        jumpChip.setAccessibilityLabel(reading.spoken)
    }

    /// Opening or closing a row is a reading gesture: the person's eyes are on the header they
    /// clicked, so the transcript stops following the bottom — a stream that kept pinning would
    /// scroll the very card they opened out from under them — and the view moves only as far as
    /// ``revealDisclosure`` needs to show the opened body, never past the clicked header. Their
    /// own next prompt, or the jump pill, is what re-engages following.
    func wireContext() {
        rowBuilder.brains = brains
        context.brains = brains
        brains.onChange = { [weak self] in self?.rebuildRows() }
        brains.defersRebuild = true
        calls.onFaceChanged = { [weak self] in
            guard let self, let facts = self.lastFacts else { return }
            self.noteBrainContext(facts)
        }
        context.returnFocus = { [weak self] in self?.focusComposer() }
        context.revealSubagent = { [weak self] stepID in self?.revealAgent(ofStep: stepID) }
        brains.viewportHeight = { [weak self] in
            self.map { $0.scrollView.contentView.bounds.height }
        }
        brains.userToggled = { [weak self] in self?.followsBottom = false }
        brains.revealApproval = { [weak self] in self?.scrollToBottom() }
        brains.replyQuote = { [weak self] quote in self?.composer.insertText(quote) }
        brains.revealAnswerPart = { [weak self] messageID, part in
            self?.scrollToMessage(messageID, part: part)
        }
        brains.revealStepRow = { [weak self] stepID in
            guard let colon = stepID.firstIndex(of: ":") else { return }
            self?.scrollToMessage(String(stepID[..<colon]), part: stepID)
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(activityStyleChanged), name: ActivityStyleSetting.didChange,
            object: nil)
        context.onToggle = { [weak self] key, open in
            guard let self else { return }
            self.context.expanded.set(key, open: open)
            self.followsBottom = false
        }
        context.revealRow = { [weak self] row in
            DispatchQueue.main.async { [weak self] in self?.revealDisclosure(row) }
        }
        context.revealAhead = { [weak self] row, height in self?.revealAhead(of: row, height: height) }
        context.requestImage = { [weak self] reference, key in
            self?.noteImageWanted(reference, key: key)
        }
        context.isImageRefused = { [weak self] key in
            self?.refusedImages.contains(key) ?? false
        }
        context.requestSubagent = { [weak self] call in
            self?.fetchSubagent(call)
        }
        context.requestWorkflowAgent = { [weak self] agentID in
            self?.fetchWorkflowAgent(agentID)
        }
        context.openImage = { [weak self] key, name in
            guard let self else { return }
            let items = ImageViewer.items(in: self.lastFullRows)
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
        context.openDesign = { [weak self] source in
            self?.openDesign(source)
        }
        context.requestDesignBoard = { [weak self] directory in
            self?.readDesignBoard(directory)
        }
        context.resumeInterrupted = { [weak self] in
            self?.pressInterruption(.pickUp)
        }
        context.dismissInterrupted = { [weak self] in
            self?.pressInterruption(.letGo)
        }
        context.offersUndo = { [weak self] messageID in
            guard let self, self.revertOperation == nil,
                let state = self.lastState, let capabilities = self.backend?.capabilities,
                let message = state.messages.first(where: { $0.id == messageID })
            else { return false }
            return RevertReading.offersUndo(on: message, capabilities: capabilities)
        }
        context.confirmUndo = { [weak self] messageID in
            self?.presentUndoConfirmation(messageID)
        }
        context.restoreRevert = { [weak self] in
            self?.performRestore()
        }
        context.modelName = { [weak self] selection in
            self?.composer.catalog.first {
                $0.providerID == selection.providerID && $0.id == selection.modelID
            }?.name
        }
        earlierButton.target = self
        earlierButton.action = #selector(showEarlierRows)
    }

    @objc func showEarlierRows() {
        guard let state = lastState else { return }
        windowLimit += 400
        rowTailMessages += 600
        apply(state: state, rows: lastFullRows)
        Task { [weak self] in await self?.conversation?.reconnect() }
    }

    @objc private func jumpToBottom() {
        scrollToBottom()
    }

    /// The keys a card's buttons name are read when the card is made, so a rebinding made while one
    /// is up draws it again from the live set rather than leaving the old keys on it.
    @objc private func shortcutsReloaded() {
        guard let state = lastState else { return }
        pendingSignature = "\u{0}"
        renderPendingCards(state)
    }
}
