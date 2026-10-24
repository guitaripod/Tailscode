import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension ChatPane {
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
    func takeQueuedFirstMessage() async
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
        openTimer.begin()
        host?.stopWatching(SessionPinStore.key(entry.profileID, entry.session.id))
        let previousEntry = self.entry
        let previousPresence = presence
        if let previousEntry, previousPresence.isInFlight {
            host?.keepWatching(previousEntry)
        }
        leaveSlots()
        chooser = nil
        leaveFreshCanvas()
        freshlyCreatedID = freshlyCreated ? entry.session.id : nil
        if let previousEntry, let carry { carryStash[Self.preferenceKey(previousEntry)] = carry }
        stashDraft()
        self.entry = entry
        brains.sessionKey = entry.session.id
        syncBrainSettings()
        call.chatChanged()
        editingQueued = nil
        queue = ConversationQueue(profileID: entry.profileID, sessionID: entry.session.id)
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
        context.expanded.reset()
        context.subagentRows = [:]
        context.liveReasoning = [:]
        context.agentFacts = [:]
        context.workflowRuns = [:]
        landedPictures = []
        inFlightSubagents = []
        attachments = []
        carry = carryStash.removeValue(forKey: Self.preferenceKey(entry))
        pastedImageCount = 0
        pending.removeAll()
        resume.removeAll()
        resumeTask?.cancel()
        resumeTask = nil
        renderAttachments()
        ActivityInbox.clear(sessionID: entry.session.id)
        rushing = false
        windowLimit = 400
        windowWidened = false
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
        releaseStream()
        chatLife.cancelAll()
        streamGeneration &+= 1
        let generation = streamGeneration
        feed.update { context in
            context.generation = generation
            context.tail = 300
            context.profileID = entry.profileID
            context.sessionModel = entry.session.model
            context.sessionProviderID = entry.session.modelProviderID
            context.models = []
        }
        if let remembered = host?.rememberedRows(for: entry.session.id) {
            placeholderShown = true
            lastFullRows = remembered
            lastFullCount = remembered.count
            let limit = rowLimit
            let windowed =
                remembered.count > limit ? Array(remembered.suffix(limit)) : remembered
            applyRows(windowed)
        } else if freshlyCreated {
            showStarters()
            gtk_widget_grab_focus(entryView)
        } else {
            showPlaceholder(Localized.text("Connecting…"))
        }
        pendingSignature = "\u{0}"
        compactingElapsed = nil
        compactingStartedAt = nil
        lastPillsSignature = ""
        lastStatusSignature = ""
        bandState.resetSlots()
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
        host?.live.edges.note(entry)
        if !isParked { attachStream() }
        host?.live.warmer.handOver(LiveKey(entry))
        let key = LiveKey(entry)
        let hub = host?.live.hub
        let task = Task { [weak self] in
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
                self.loadSessionExtras(
                    backend: backend, directory: entry.session.directory, sessionID: sessionID)
            }
            guard let conversation = await hub?.conversation(for: key), !Task.isCancelled else {
                return
            }
            await self?.adoptConversation(conversation, for: entry)
        }
        chatLife.add { task.cancel() }
    }

    /// The hub's conversation for the chat this pane opened, once it exists: kept for sending, and
    /// the quick ask's first words — waiting under exactly this session's id — go out through it.
    func adoptConversation(_ conversation: AgentConversation, for entry: SessionEntry) async {
        let sessionID = entry.session.id
        let adopted: Bool = await withCheckedContinuation { continuation in
            Gtk.onMain { [weak self] in
                guard let self, self.sessionID == sessionID, self.entry?.profileID == entry.profileID
                else {
                    continuation.resume(returning: false)
                    return
                }
                self.conversation = conversation
                if let state = self.lastState { self.drainHeldQueue(state) }
                continuation.resume(returning: true)
            }
        }
        guard adopted, let queued = await takeQueuedFirstMessage(), queued.sessionID == sessionID
        else { return }
        let words = queued.send.text
        let choice: (ModelSelection?, String?) = await withCheckedContinuation { continuation in
            Gtk.onMain { [weak self] in
                guard let self, self.sessionID == sessionID else {
                    continuation.resume(returning: (nil, nil))
                    return
                }
                let effort = ModelEffort.surviving(self.chosenEffort, options: self.effortOptions())
                let row = self.pending.begin(
                    text: words,
                    userMessages: self.lastState?.messages.count { $0.role == .user } ?? 0)
                self.openHandoff()
                self.redrawPending()
                self.raiseFreshCanvas(for: row.id)
                if Ultracode.invokes(words) || effort == Ultracode.effortLevel {
                    self.ultracodeInFlight = true
                    self.refreshUltracodeAura()
                }
                continuation.resume(returning: (self.chosenModel, effort))
            }
        }
        switch queued.send.kind {
        case .prompt:
            try? await conversation.send(
                words, model: choice.0, reasoningEffort: choice.1,
                attachments: queued.attachments.map(\.prompt))
        case .command(let command, let arguments):
            try? await conversation.run(
                command, arguments: arguments, model: choice.0, reasoningEffort: choice.1)
        }
    }

    /// Takes the hub lease and wires it through the pump to the window's drain. Every piece is
    /// registered in `streamLife`, so parking, a switch of chat and shutdown all end it at once.
    func attachStream() {
        guard let entry, let host, lease == nil, !isShutDown else { return }
        let live = host.live
        let feed = self.feed
        let lease = live.hub.lease(LiveKey(entry), interest: .full) { feed.pull() }
        self.lease = lease
        feed.attach(lease: lease, builder: rowBuilder, drain: live.drain)
        let token = live.drain.register(drainSlot())
        drainToken = token
        streamLife.add { [weak self] in
            token.cancel()
            feed.detach()
            lease.cancel()
            self?.lease = nil
            self?.drainToken = nil
        }
        feed.pull()
    }

    func drainSlot() -> DrainSlot {
        let feed = self.feed
        return DrainSlot(
            pane: id, priority: drainPriority,
            minInterval: drainPriority == .focused
                ? CascadeBudget.focusedApplyInterval : Self.peerApplyInterval,
            hasWork: { feed.hasBuilt }, apply: { [weak self] in self?.applyBuilt() })
    }

    /// The shortest gap between two applies for a pane the focus is not on. A peer shows an
    /// answer at arrival granularity, and an arrival is measured in fifths of a second rather than
    /// in frames: five applies a second read as the answer growing, and every apply past that is a
    /// relayout, a scroll and a repaint of a column nobody is reading — measured, the largest cost
    /// of a window of streaming panes. The focused pane applies at the reveal's own tick.
    static let peerApplyInterval: TimeInterval = 0.2

    /// The drain's turn for this pane: the newest built state, if it is still this pane's chat.
    func applyBuilt() {
        guard let built = feed.takeBuilt(), built.generation == streamGeneration, !isParked else {
            return
        }
        Trace.mark("applyBuilt \(built.rows.count) rows")
        Soak.timeApply { apply(state: built.state, rows: built.rows) }
        if built.fill != contextFill {
            contextFill = built.fill
            updateStatus()
        }
    }

    /// A pane that is about to show a scripted conversation stops listening to the real one, so
    /// nothing the server says overwrites what the harness put there.
    func detachStreamForScript() {
        releaseStream()
    }

    /// Ends everything that keeps the pane live, and the reveal with it, settling the row it held.
    func releaseStream() {
        streamLife.cancelAll()
        letGoOfCascade()
        updateTicker(running: false, quietly: true)
        ActivityPulse.stop(identityLabel)
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
        leaveChat()
        showPlaceholder(placeholder)
        refreshPills()
        refreshIdentity()
    }

    /// Lets go of the conversation the pane holds — its stream, its fetches, its clocks and the
    /// state it was drawing — without deciding what the pane shows next. A turn still in flight is
    /// handed to the window's watch, so its row keeps LIVE NOW until it settles.
    func leaveChat() {
        stashDraft()
        if let entry, presence.isInFlight { host?.keepWatching(entry) }
        leaveFreshCanvas()
        releaseStream()
        chatLife.cancelAll()
        streamGeneration &+= 1
        brains.sessionKey = "none"
        agentStreamTask?.cancel()
        agentStreamTask = nil
        agentStreamSessionID = nil
        catalogWatchTask?.cancel()
        catalogWatchTask = nil
        resumeTask?.cancel()
        resumeTask = nil
        entry = nil
        call.chatChanged()
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
        bandState.resetSlots()
        lastNetworkFactsAt = nil
        lastGitFactsAt = nil
        Gtk.removeChildren(of: pendingBox)
        gtk_widget_set_visible(authBanner, 0)
    }

    /// A closing pane stops talking to the world before its widgets go: a cancelled stream is
    /// the difference between a closed pane and a leak that keeps rendering into nothing. A turn
    /// still in flight is handed to the background watcher first, so the row keeps its LIVE NOW
    /// seat until the turn settles.
    func shutdown() {
        stashDraft()
        call.shutdown()
        if let entry, presence.isInFlight { host?.keepWatching(entry) }
        leaveFreshCanvas()
        releaseStream()
        FillTurns.cancel(owner: self)
        chatLife.cancelAll()
        lifetime.cancelAll()
        cascade.release()
        repairingTail = false
        preview?.shutdown()
        preview = nil
        draw?.shutdown()
        draw = nil
        video?.shutdown()
        video = nil
        page?.shutdown()
        page = nil
        agentStreamTask?.cancel()
        catalogWatchTask?.cancel()
        resumeTask?.cancel()
        editor.stopAura()
        agentStreamTask = nil
        catalogWatchTask = nil
        resumeTask = nil
        conversation = nil
        backend = nil
        isShutDown = true
    }

    /// What a window closing takes off a pane without touching its widgets: the once-a-second
    /// clock and any backfill hops still queued. Safe to repeat.
    func quiesce() {
        updateTicker(running: false, quietly: true)
        FillTurns.cancel(owner: self)
    }

    /// Everything worth knowing about the session besides its transcript, fetched once per open:
    /// the models the server offers, the commands it resolves, and whether its Claude is signed in.
    /// The catalog is watched rather than asked once — a server asked while it restarts must not be
    /// remembered as having no models, so the ask retries and every answer re-paints the pills and
    /// an open chooser window.
    func loadSessionExtras(
        backend: any CodingAgentBackend, directory: String?, sessionID: String
    ) {
        catalogWatchTask?.cancel()
        // Spend, agents and git are facts about the open chat — asked once the backend is known,
        // not held until a model catalog or command list happens to land. The backend pointer is
        // the one just resolved; the property may not have landed on the main context yet.
        track(Task { [weak self] in
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
        })
        if let profileID = entry?.profileID {
            catalogWatchTask = track(Task { [weak self] in
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
            })
        }
        track(Task { [weak self] in
            let commands = (try? await backend.availableCommands(directory: directory)) ?? []
            Gtk.onMain { [weak self] in
                guard let self, self.sessionID == sessionID else { return }
                self.commands = commands
                self.refreshPills()
            }
        })
        if let authenticating = backend as? any AuthenticatingBackend {
            track(Task { [weak self] in
                guard let auth = try? await authenticating.authStatus() else { return }
                Gtk.onMain { [weak self] in
                    guard let self, self.sessionID == sessionID else { return }
                    self.renderAuthBanner(auth, backend: authenticating)
                }
            })
        }
    }

    func renderAuthBanner(_ auth: ServerAuth, backend: any AuthenticatingBackend) {
        Gtk.removeChildren(of: authBanner)
        guard !auth.loggedIn else {
            gtk_widget_set_visible(authBanner, 0)
            return
        }
        let name = entry.map { ServerLabel.display(name: $0.profileName, backend: $0.backendType) } ?? "server"
        let rootBits = host?.windowWidget.map { UInt(bitPattern: $0) } ?? 0
        showAuthBanner(serverName: name) { [weak self] in
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
        }
    }

    /// The signed-out banner itself: what happened, and the one button that mends it.
    func showAuthBanner(serverName: String, signIn: @escaping @Sendable () -> Void) {
        Gtk.removeChildren(of: authBanner)
        let label = Gtk.label(
            Localized.text(
                "⚠ Claude is signed out on %@ — every turn will refuse until it signs in.",
                serverName),
            css: "banner-auth-text", wrap: true, selectable: false)
        gtk_widget_set_hexpand(label, 1)
        gtk_widget_set_valign(label, GTK_ALIGN_CENTER)
        gtk_box_append(ptr(authBanner), label)
        let button = Gtk.button(Localized.text("Sign in"), css: ["btn-primary"]) { signIn() }
        gtk_widget_set_valign(button, GTK_ALIGN_CENTER)
        tailscode_set_accessible_label(button, Localized.text("Sign in"))
        gtk_box_append(ptr(authBanner), button)
        gtk_widget_set_visible(authBanner, 1)
    }
}
