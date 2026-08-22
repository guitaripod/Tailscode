import TailscodeCore
import CodingAgentKit
import Foundation
#if canImport(ActivityKit)
import ActivityKit
#endif

@MainActor
final class ChatViewModel {
    let backend: any CodingAgentBackend
    let session: AgentSession

    let contextID: String
    private let conversation: AgentConversation
    private let persistKey: String
    private var streamTask: Task<Void, Never>?

    private(set) var state = ConversationState()
    private(set) var selectedModel: ModelSelection?
    private(set) var currentEffort: String?
    /// A summoned turn is still running: the aura stays lit after the draft
    /// that lit it has been sent.
    private(set) var ultracodeInFlight = false

    var isBound = true
    var onState: ((ConversationState) -> Void)?
    /// A change to what this device is holding — a message sent, taken, failed or queued — and
    /// nothing at all to the server's account of the conversation.
    ///
    /// It is a separate signal because it has a separate cost. Redrawing from a state means
    /// rebuilding every row of the transcript from every message in it, which in a conversation
    /// of a few thousand rows is most of a second of main thread — and the one moment that must
    /// never cost most of a second is the one right after somebody presses Send. A client
    /// answering this redraws only what it is itself holding.
    var onPending: (() -> Void)?
    var onModelChange: (() -> Void)?
    var onError: ((String) -> Void)?
    var onQuestionFailed: ((String) -> Void)?

    init(
        backend: any CodingAgentBackend, session: AgentSession, contextID: String = "default",
        serverName: String = ""
    ) {
        self.backend = backend
        self.session = session
        self.contextID = contextID
        self.persistKey = "\(contextID)/\(session.id)"
        self.conversation = AgentConversation(
            backend: backend, sessionID: session.id, cache: AppCache.sessionCache)
        self.serverName = serverName
    }

    let serverName: String

    private(set) lazy var displayTitle: String = session.title
    var title: String { displayTitle }

    /// What a notice about this chat calls it. A turn that ends is news before the server has
    /// named the conversation it happened in, so the notification and the row it leaves behind
    /// would both read "New chat" — the words that started it are the name a person recognises.
    var alertTitle: String {
        MissedActivity.name(
            title: displayTitle,
            latestPrompt: state.messages.last { $0.role == .user }?
                .parts.compactMap(\.text).joined(separator: "\n"))
    }

    /// The session as this chat now understands it: the server usually auto-titles
    /// a conversation after its first turn, long after the list that opened it.
    var sessionSnapshot: AgentSession {
        var snapshot = session
        snapshot.title = displayTitle
        snapshot.updatedAt = max(session.updatedAt, state.messages.last?.createdAt ?? .distantPast)
        return snapshot
    }
    var canRename: Bool { backend.capabilities.supportsRenaming }

    /// Whether the machine's Claude is signed out.
    ///
    /// A signed-out CLI does not fail a turn — it answers it, with "Not logged in · Please run
    /// /login" — so the reply is the only hint, and the server's own account state is the proof.
    /// The hint is cheap and wrong sometimes; the proof costs a round trip, so it is only asked for
    /// when the hint appears, and at most twice a minute.
    private(set) var isSignedOut = false
    var onSignInStateChanged: (() -> Void)?
    private var lastAuthCheck = Date.distantPast

    var authenticator: (any AuthenticatingBackend)? { backend as? any AuthenticatingBackend }

    func noteSignedOutIfHinted(_ state: ConversationState) {
        guard authenticator != nil, state.status != .running else { return }
        guard Self.looksSignedOut(state) else { return }
        guard Date().timeIntervalSince(lastAuthCheck) > 30 else { return }
        lastAuthCheck = Date()
        Task { await checkSignIn() }
    }

    func checkSignIn() async {
        guard let authenticator else { return }
        guard let status = try? await authenticator.authStatus() else { return }
        guard isSignedOut != !status.loggedIn else { return }
        isSignedOut = !status.loggedIn
        AppLogger.connection.info("server signed \(self.isSignedOut ? "out" : "in")")
        onSignInStateChanged?()
    }

    func clearSignedOut() {
        guard isSignedOut else { return }
        isSignedOut = false
        onSignInStateChanged?()
    }

    private static func looksSignedOut(_ state: ConversationState) -> Bool {
        if let failure = state.lastFailure, failure.message.contains("/login") { return true }
        guard let last = state.messages.last, last.role == .assistant else { return false }
        return last.parts.contains { part in
            guard case .text(let text) = part.kind else { return false }
            return text.contains("Please run /login") || text.contains("Not logged in")
        }
    }

    private var manuallyRenamed = false

    func rename(to title: String) async throws {
        try await backend.renameSession(session.id, title: title)
        displayTitle = title
        manuallyRenamed = true
    }

    var onTitleChange: (() -> Void)?

    /// Servers auto-title a conversation after its first turn (the bridge
    /// writes an LLM title shortly after); pick the new name up when the turn
    /// settles so the list, nav bar, and Live Activity all read well.
    private func refreshTitleFromServer(delay: Duration = .zero) {
        guard !manuallyRenamed else { return }
        Task {
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !manuallyRenamed,
                let fresh = try? await backend.listAllSessions(
                    knownDirectories: session.directory.map { [$0] } ?? []
                ).first(where: { $0.id == session.id }),
                !fresh.hasPlaceholderTitle, fresh.title != displayTitle
            else { return }
            displayTitle = fresh.title
            if activityLive {
                let live = Self.liveStatus(for: state)
                AppActivityController.shared.update(
                    sessionID: session.id, phase: live.phase, statusText: live.text,
                    lastTool: live.tool, toolCount: live.toolCount, icon: live.icon,
                    title: fresh.title)
            }
            onTitleChange?()
        }
    }

    var supportsModelSelection: Bool { backend.capabilities.supportsModelSelection }
    var supportsReasoningEffort: Bool { backend.capabilities.supportsReasoningEffort }

    /// The model in play, in the shape a catalog lookup wants: the explicit pick, else the model
    /// the transcript or the session record names, wearing a "server" door when no real one is
    /// known. `ModelEffort`/`ModelAbilities` resolve a doorless pick by id.
    private var effectiveSelection: ModelSelection? {
        selectedModel ?? activeModelID.map { ModelSelection(providerID: "server", modelID: $0) }
    }

    /// Effort is a property of the model where the catalog says so (opencode's variants differ
    /// per model); the backend-wide list serves agents whose models all take the same levels. The
    /// rule is Core's, so what this chat offers and what the desktops offer for the same model can
    /// never differ.
    var reasoningEffortOptions: [String] {
        ModelEffort.options(
            models: knownModels, selection: effectiveSelection,
            agentOptions: backend.reasoningEffortOptions)
    }

    private var activeModelID: String? {
        selectedModel?.modelID ?? lastAssistantModelID ?? session.model
    }

    private var lastAssistantModelID: String? {
        for message in state.messages.reversed() where message.role == .assistant {
            if let id = message.modelID, !id.isEmpty { return id }
        }
        return nil
    }

    private var lastAssistantEffort: String? {
        for message in state.messages.reversed() where message.role == .assistant {
            if let effort = message.reasoningEffort, !effort.isEmpty { return effort }
        }
        return nil
    }

    /// What the chat is actually being answered by, which is not always what
    /// the session record says: a `/model` typed into the CLI changes the model
    /// for every later turn without the server's stored session ever hearing
    /// about it. An explicit pick wins, then the transcript — the last
    /// assistant message names the model that wrote it — and the session record
    /// is the fallback for a chat that has no answer in it yet.
    var displayedModel: ModelSelection? {
        if let selectedModel { return selectedModel }
        if let observed = lastAssistantModelID {
            return ModelSelection(providerID: "server", modelID: observed)
        }
        if let stored = session.model, !stored.isEmpty {
            return ModelSelection(providerID: "server", modelID: stored)
        }
        return nil
    }

    /// The effort the chip names, and nothing at all where the model takes no effort: a word left
    /// over from the model that answered last is a claim about a control this model does not have.
    var displayedEffort: String? {
        let options = reasoningEffortOptions
        guard !options.isEmpty else { return nil }
        if let kept = ModelEffort.surviving(currentEffort, options: options) { return kept }
        if let stored = ModelEffort.surviving(session.reasoningEffort, options: options) {
            return stored
        }
        return ModelEffort.surviving(lastAssistantEffort, options: options)
    }
    var supportsAttachments: Bool { backend.capabilities.supportsAttachments }

    /// What the model answering this chat can be handed. Resolved against the model actually in
    /// play rather than only an explicit pick, so a conversation reopened on another device — where
    /// the model comes from the server's own record — narrows its composer the same way.
    var abilities: ModelAbilities {
        ModelAbilities.resolve(
            supportsAttachments: supportsAttachments, models: knownModels,
            selection: effectiveSelection, camera: true)
    }

    /// Whether the current model can receive an image attachment.
    var canAttachImages: Bool { abilities.vision }

    /// Whether the current model can receive non-image file attachments
    /// (e.g. a large paste converted to a text file).
    var canAttachFiles: Bool { abilities.attachments }
    var canClear: Bool { backend.capabilities.supportsClearing }
    var canFork: Bool { backend.capabilities.supportsForking }
    var canAbort: Bool { backend.capabilities.supportsAbort }
    var supportsUsage: Bool { backend.capabilities.supportsSessionUsage }
    var supportsFileBrowsing: Bool { backend.capabilities.supportsFileBrowsing }
    /// A dead stream can't clear a stale `.running`, so busy requires a live
    /// subscription — once the stream terminates, the spinner never outlives it.
    var isBusy: Bool { (streamTask != nil && state.status == .running) || optimisticThinking }

    func fork() async throws -> AgentSession {
        try await backend.forkSession(session.id)
    }

    var supportsSubagents: Bool { backend.capabilities.supportsSubagents }

    func subagents() async -> [SubagentSummary] {
        (try? await backend.subagents(for: session.id)) ?? []
    }

    private(set) var trackedSubagents: [SubagentSummary] = []
    private(set) var subagentTranscripts: [String: [ChatMessage]] = [:]
    private(set) var expandedSubagents: Set<String> = []
    private(set) var loadingSubagents: Set<String> = []
    var onSubagentsChange: (() -> Void)?
    private var subagentTask: Task<Void, Never>?

    var liveSubagentCount: Int { trackedSubagents.count(where: \.isActive) }

    /// Subagents belong to this conversation, so the chat owns their polling for
    /// as long as it is on screen. The cadence follows the work: quick while an
    /// agent is running or a card is open, slow once they have settled, and
    /// slower still for the ordinary chat that never spawned one — opencode
    /// answers this by listing every session, which is too costly to ask often.
    func startSubagentTracking() {
        guard supportsSubagents, subagentTask == nil else { return }
        subagentTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshSubagents()
                try? await Task.sleep(for: .seconds(self.subagentPollInterval))
            }
        }
    }

    private var subagentPollInterval: Int {
        if liveSubagentCount > 0 || !expandedSubagents.isEmpty { return 4 }
        if state.status == .running { return 8 }
        return trackedSubagents.isEmpty ? 30 : 12
    }

    func stopSubagentTracking() {
        subagentTask?.cancel()
        subagentTask = nil
    }

    func isSubagentExpanded(_ agentID: String) -> Bool { expandedSubagents.contains(agentID) }

    func toggleSubagent(_ agentID: String) {
        if expandedSubagents.remove(agentID) == nil {
            expandedSubagents.insert(agentID)
            if subagentTranscripts[agentID] == nil { loadingSubagents.insert(agentID) }
            Task { [weak self] in await self?.loadSubagentTranscript(agentID) }
        }
        onSubagentsChange?()
    }

    private func refreshSubagents() async {
        let fresh = await subagents()
        let changed = fresh != trackedSubagents
        trackedSubagents = fresh
        let stale = fresh.filter { expandedSubagents.contains($0.id) && $0.isActive }.map(\.id)
        for agentID in stale { await loadSubagentTranscript(agentID) }
        if changed || !stale.isEmpty { onSubagentsChange?() }
    }

    private func loadSubagentTranscript(_ agentID: String) async {
        let messages = try? await backend.subagentMessages(
            sessionID: session.id, agentID: agentID)
        loadingSubagents.remove(agentID)
        guard let messages else {
            onSubagentsChange?()
            return
        }
        let changed = subagentTranscripts[agentID] != messages
        subagentTranscripts[agentID] = messages
        if changed { onSubagentsChange?() }
    }

    var supportsServerCommands: Bool { backend.capabilities.supportsCommands }
    /// Whether the agent reads its own slash grammar out of the prompt text. A CLI-backed agent
    /// does, so a typed command must go out untouched rather than through the command route.
    var resolvesCommandsFromPromptText: Bool { backend.resolvesCommandsFromPromptText }
    var supportsGoals: Bool { backend.capabilities.supportsGoals }
    var goal: SessionGoal? { state.goal }

    private(set) var serverCommands: [AgentCommand] = []
    var onCommandsChange: (() -> Void)?

    /// Whether a design board could be read back at all. The brief is only worth spending a turn
    /// on where this server hands files over — otherwise the mocks would be written somewhere no
    /// client could ever open them.
    var supportsDesign: Bool { backend.capabilities.supportsFileBrowsing }

    /// What the composer offers: the server's catalog, plus the one word this app answers itself.
    var composerCommands: [AgentCommand] {
        CommandCatalogStore.forComposer(serverCommands, supportsDesign: supportsDesign)
    }

    /// The server's command catalog, fetched once per chat. A server that can't answer leaves the
    /// list empty and the palette shows only the app's own actions.
    func loadServerCommands() {
        guard supportsServerCommands, serverCommands.isEmpty else { return }
        Task { [weak self] in
            guard let self,
                let commands = try? await backend.availableCommands(
                    directory: session.directory), !commands.isEmpty
            else { return }
            self.serverCommands = commands
            self.onCommandsChange?()
        }
    }

    /// Runs a server-side command. Where a command is just prompt text (any CLI-backed agent) it
    /// goes through the ordinary send path, so it echoes into the transcript, engages the thinking
    /// state, and starts a Live Activity exactly like a typed message — anything else would make
    /// the app look frozen until the server streamed something back. A command is a turn either
    /// way, so it leaves carrying the model and effort the composer is wearing: a run that carried
    /// nothing let the server answer on its own default, and the chat then renamed itself after a
    /// model nobody picked.
    func run(_ command: AgentCommand, arguments: String? = nil) {
        if backend.resolvesCommandsFromPromptText {
            send(command.invocation(arguments: arguments))
            return
        }
        let model = selectedModel
        let effort = currentEffort
        Task { [weak self] in
            guard let self else { return }
            do {
                try await conversation.run(
                    command, arguments: arguments, model: model, reasoningEffort: effort)
            } catch {
                self.onError?(String(localized: "Couldn't run /\(command.name)."))
            }
        }
    }

    var supportsCompaction: Bool { backend.capabilities.supportsCompaction }

    /// A compaction in flight, or the one that was just refused. The transcript records finished
    /// ones itself — this is only the part of the story that has no row of its own yet.
    var compactionActivity: CompactionActivity? { state.compaction }

    /// The most recent finished compaction, so the app can say what the last one cost before
    /// asking for another.
    var lastCompaction: Compaction? {
        state.messages.reversed()
            .lazy
            .flatMap { $0.parts }
            .compactMap { part -> Compaction? in
                guard case .compaction(let value) = part.kind else { return nil }
                return value
            }
            .first
    }

    /// Compaction is a turn like any other — it echoes, engages the thinking state, and queues
    /// behind a running one — so it goes out through the ordinary send path.
    func compact(instructions: String?) {
        let command = AgentCommand(name: "compact", details: "", source: .builtin)
        run(command, arguments: instructions)
    }

    func setGoal(_ condition: String) {
        run(AgentCommand(name: "goal", details: "", source: .builtin), arguments: condition)
    }

    func clearGoal() {
        run(AgentCommand(name: "goal", details: "", source: .builtin), arguments: "clear")
    }

    /// Reusing a still-running view model (reopened while a turn is in flight)
    /// must not spawn a second `states()` loop — it would double every render
    /// and leak the old task. Re-emit the current state so the freshly bound
    /// view controller paints immediately, including any queued messages.
    func start() {
        let vmTag = String(UInt(bitPattern: ObjectIdentifier(self).hashValue) & 0xffff, radix: 16)
        guard streamTask == nil else {
            AppLogger.chat.info(
                "start reuse vm=\(vmTag) session=\(session.id) queued=\(queue.count) echoes=\(pending.count)")
            onState?(state)
            return
        }
        AppLogger.chat.info(
            "start fresh vm=\(vmTag) session=\(session.id) queued=\(queue.count) echoes=\(pending.count)")
        streamGeneration += 1
        let generation = streamGeneration
        streamTask = Task { [weak self] in
            guard let self else { return }
            for await state in await self.conversation.states() {
                if state.connection == .live { self.streamRestarts = 0 }
                self.reconcileOptimisticState(with: state)
                if self.state.status == .running, state.status != .running {
                    self.cachedUsage = nil
                    self.refreshTitleFromServer()
                    self.refreshTitleFromServer(delay: .seconds(12))
                    if self.ultracodeInFlight {
                        self.ultracodeInFlight = false
                        self.onModelChange?()
                    }
                }
                if Ultracode.turnInvoked(state), !self.ultracodeInFlight {
                    self.ultracodeInFlight = true
                    self.onModelChange?()
                }
                let displayedBefore = (self.displayedModel, self.displayedEffort)
                self.state = state
                if (self.displayedModel, self.displayedEffort) != displayedBefore {
                    self.onModelChange?()
                }
                if state.status == .running {
                    self.queueHeldAfterFailure = false
                    self.queueHold = nil
                }
                self.onState?(state)
                let awaiting =
                    state.pendingPermissions.first != nil || state.pendingQuestions.first != nil
                SessionActivity.shared.update(
                    sessionID: self.session.id, profileID: self.contextID,
                    title: self.alertTitle,
                    presence: self.presence(for: state),
                    keepAlive: self)
                self.syncLiveActivity(with: state)
                if state.status != .running { self.flushQueue() }
                if !self.isBusy, !awaiting, !self.isBound, self.queue.isEmpty,
                    self.resume.isEmpty
                {
                    self.stop()
                }
            }
            self.handleStreamTermination(generation: generation)
        }
        Task { await loadDefaultModelIfNeeded() }
    }

    private var streamGeneration = 0

    /// What this device can honestly say about the turn: the reading every client shares, raised
    /// only by a send whose echo is still local. A conversation that has just been handed over
    /// reads as unsettled and settles nothing; one this device has just sent to is running here
    /// whatever the server has got around to saying.
    private func presence(for state: ConversationState) -> SessionPresence {
        let reading = SessionPresence.reading(state, step: nil)
        let sending = SessionPresence.running(nil)
        guard optimisticThinking, reading.rank < sending.rank else { return reading }
        return sending
    }

    /// Runs when the states() stream ends on its own — a terminal failure or
    /// reconnect exhaustion, not a `stop()`/`resync()` (those bump the
    /// generation first). The dead task must not masquerade as a live
    /// subscription: clearing it lets `resync`/reopen build a fresh stream,
    /// and releasing the activity entry stops Home showing a phantom live
    /// session for a turn nothing on this device can observe anymore.
    private func handleStreamTermination(generation: Int) {
        guard generation == streamGeneration, streamTask != nil else { return }
        AppLogger.chat.info("stream terminated for \(session.id); releasing busy state")
        streamTask = nil
        SessionActivity.shared.markUnobserved(sessionID: session.id)
        onState?(state)
        scheduleStreamRestart()
    }

    /// A stream that ended while someone is still looking at the chat is a terminal failure, not
    /// a request to stop watching — left alone, the transcript freezes on whatever rendered last
    /// until the screen is reopened, which reads as an answer that just stopped arriving. So a
    /// bound chat dials again after a beat; an unbound one stays released, exactly as before.
    private var streamRestarts = 0

    private func scheduleStreamRestart() {
        guard isBound else { return }
        streamRestarts += 1
        let delay = min(30.0, pow(2.0, Double(min(streamRestarts, 5))))
        let generation = streamGeneration
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, self.isBound, self.streamTask == nil,
                generation == self.streamGeneration
            else { return }
            self.start()
        }
    }

    /// What this device has written and the server has not echoed back yet, with what became of
    /// each — the row a person sees the instant they press Send, and the only place a send that
    /// never went still holds its words. The ledger and its wording are Core's; this owns the
    /// clock and the network.
    private(set) var pending = PendingSendLedger()

    var pendingSends: [PendingSend] { pending.sends }

    /// Messages a spent provider window stopped, and the moment each goes again. The policy and
    /// every word are Core's; this owns the one clock that fires them and the copy on disk, so a
    /// window that opens while the phone is in a pocket is still explained rather than lost.
    private(set) var resume = ResumeLedger()
    private var resumeClock: Task<Void, Never>?
    /// How many times this conversation has already been sent into the wall and bounced. A plan
    /// that fires and dies produces a *fresh* failure, and reading each fresh failure as a first
    /// attempt is how a bounded retry becomes an unbounded one — so the count lives here, beside
    /// the conversation, and only a turn that is not in a failed state clears it.
    private var resumeAttempts = 0

    func resumePlan(for row: UUID) -> ResumePlan? { resume.plan(for: row) }

    /// The wait a client puts in the chat's own chrome: the soonest one, because that is the
    /// clock that decides when this conversation moves again.
    var soonestResume: ResumePlan? {
        resume.plans.values.filter { !$0.isStale() }.min { $0.resumesAt < $1.resumesAt }
    }

    private var resumeEnabled: Bool { AppPreferences.autoResume }

    private func resumeQuotas() -> [UsageQuota] {
        QuotaSurface.relevantQuotas(
            for: backend.agentType, among: UsageWidgetStore.cachedQuotas())
    }

    /// A send a wall stopped is held rather than left as a failure nobody will come back to.
    /// Anything that is not a wall keeps its own sentence and never reaches this.
    private func armResume(row: UUID, reason: String) {
        guard let send = pending.send(id: row) else { return }
        adopt(
            AutoResume.decide(
                row: row, profileID: contextID, sessionID: session.id, trigger: .refused,
                failure: reason, quotas: resumeQuotas(), model: displayedModel?.modelID,
                selection: displayedModel, enabled: resumeEnabled, attempt: resumeAttempts),
            text: send.text, attachments: send.attachments, model: send.model,
            effort: send.effort)
    }

    /// A turn that reached the server, ran into the wall and produced nothing is the commonest
    /// shape of this on a Claude machine: the prompt is already in the transcript, so the words
    /// come from there rather than from a send this device happens to remember.
    private func armResumeForWalledTurn(_ state: ConversationState) {
        guard let failure = state.lastFailure, state.status != .running else {
            if state.lastFailure == nil { resumeAttempts = 0 }
            return
        }
        guard !resume.plans.values.contains(where: { $0.trigger == .answerless }) else { return }
        guard let asked = state.messages.last(where: { $0.role == .user }) else { return }
        let words = asked.parts.compactMap(\.text).joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        let answer = state.messages.last {
            $0.role == .assistant && $0.createdAt >= asked.createdAt
        }
        guard answer == nil || AutoResume.mayAskAgain(answer) else {
            if QuotaSurface.isQuotaFailure(failure.message) {
                onError?(ResumeReading.obstacle(.turnHadStarted))
            }
            return
        }
        adopt(
            AutoResume.decide(
                row: UUID(), profileID: contextID, sessionID: session.id, trigger: .answerless,
                failure: failure.message, quotas: resumeQuotas(),
                model: displayedModel?.modelID, selection: displayedModel,
                enabled: resumeEnabled, attempt: resumeAttempts),
            text: words, attachments: [], model: selectedModel, effort: currentEffort)
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
            AppLogger.chat.info("resume declined: \(String(describing: obstacle))")
        case .resume(let plan):
            AppLogger.chat.info(
                "resume armed session=\(self.session.id) in=\(Int(plan.remaining()))s")
            resume.hold(plan)
            ResumeStore.hold(
                ResumeRecord(
                    plan: plan, text: text, attachments: attachments, model: model,
                    effort: effort))
            onResumeChange?(plan)
            startResumeClock()
            onPending?()
        }
    }

    /// A plan taken up or laid down, so the app around the chat can put a notification on the
    /// window's reopening and take it off again.
    var onResumeChange: ((ResumePlan?) -> Void)?

    /// One clock for the whole conversation. A countdown written in minutes needs nothing finer,
    /// and the grace this policy adds to every reset is four times the slop.
    private func startResumeClock() {
        guard resumeClock == nil, !resume.isEmpty else { return }
        resumeClock = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { break }
                await self?.serviceResume()
            }
        }
    }

    private func stopResumeClockIfIdle() {
        guard resume.isEmpty else { return }
        resumeClock?.cancel()
        resumeClock = nil
    }

    /// The moment a plan is due: look at the gauges rather than assume, then send, wait again, or
    /// stop and say why. Also called on foregrounding, because a phone that was asleep through
    /// the window opening is the ordinary case rather than the exception.
    func serviceResume() {
        guard !resume.isEmpty else {
            stopResumeClockIfIdle()
            return
        }
        for plan in resume.stale() {
            resume.drop(plan.id)
            ResumeStore.release(plan.id)
            onError?(ResumeReading.missed(plan))
            onResumeChange?(nil)
        }
        for plan in resume.due() {
            switch AutoResume.recheck(
                plan, quotas: resumeQuotas(), model: displayedModel?.modelID,
                selection: displayedModel, enabled: resumeEnabled)
            {
            case .send:
                fireResume(plan)
            case .wait(let next):
                resume.hold(next)
                ResumeStore.replan(next)
                onResumeChange?(next)
            case .cancel(let obstacle):
                resume.drop(plan.id)
                ResumeStore.release(plan.id)
                onError?(ResumeReading.obstacle(obstacle))
                onResumeChange?(nil)
            }
        }
        stopResumeClockIfIdle()
        onPending?()
    }

    /// Sends what a plan was holding, through the composer's own path so a resumed message is a
    /// message like any other rather than a second road into the backend.
    private func fireResume(_ plan: ResumePlan) {
        resumeAttempts = plan.attempt + 1
        let record = ResumeStore.release(plan.id)
        resume.drop(plan.id)
        onResumeChange?(nil)
        let held = pending.send(id: plan.id)
        let text = held?.text ?? record?.text ?? ""
        guard !text.isEmpty else { return }
        AppLogger.chat.info("resume firing session=\(self.session.id)")
        let attachments = held?.attachments ?? record?.attachments ?? []
        let model = held?.model ?? record?.model ?? selectedModel
        let effort = held?.effort ?? record?.effort ?? currentEffort
        if held != nil, !isBusy {
            deliver(
                text, model: model, effort: effort, attachments: attachments, reusing: plan.id)
        } else {
            pending.remove(id: plan.id)
            send(text, model: model, effort: effort, attachments: attachments)
        }
    }

    func actOnResume(_ id: UUID, _ act: ResumeReading.Act) -> PendingSend? {
        guard let plan = resume.plan(for: id) else { return nil }
        switch act {
        case .sendNow:
            fireResume(plan)
            return nil
        case .edit:
            resume.drop(id)
            ResumeStore.release(id)
            onResumeChange?(nil)
            stopResumeClockIfIdle()
            return takeBackPending(id: id)
        case .stopWaiting:
            resume.drop(id)
            ResumeStore.release(id)
            onResumeChange?(nil)
            stopResumeClockIfIdle()
            onPending?()
            return nil
        }
    }

    /// Picks back up what this device was holding for this conversation when it was last running.
    /// A plan whose window opened while nothing was awake is reported rather than fired.
    func restoreHeldMessages() {
        let records = ResumeStore.records(profileID: contextID, sessionID: session.id)
        guard !records.isEmpty else { return }
        let userMessages = state.messages.count { $0.role == .user }
        for record in records {
            if record.plan.isStale() {
                ResumeStore.release(record.id)
                onError?(ResumeReading.missed(record.plan))
                continue
            }
            let restored = pending.begin(
                text: record.text, attachments: record.attachments, model: record.model,
                effort: record.effort, userMessages: userMessages, now: record.plan.plannedAt,
                id: record.id)
            pending.mark(
                id: restored.id,
                .failed(
                    reason: String(
                        format: String(localized: "%@ %@ is used up"), record.plan.provider,
                        record.plan.window)))
            resume.hold(record.plan)
        }
        startResumeClock()
        onPending?()
    }

    private(set) var optimisticThinking = false
    private var activityLive = false
    private var turnSawRunning = false

    private func reconcileOptimisticState(with state: ConversationState) {
        if state.status == .running { optimisticThinking = false }
        pending.reconcile(userMessages: state.messages.count { $0.role == .user })
        armResumeForWalledTurn(state)
        if optimisticThinking, !pending.hasInFlight,
            let last = state.messages.last, last.role == .assistant, !last.text.isEmpty
        {
            optimisticThinking = false
        }
    }

    /// Drives the Live Activity for turns this device initiated (`deliver`
    /// starts it). Merely observing a session that is live on the server must
    /// not start one: such sessions can run for hours, leaving an activity
    /// that never reaches its done state.
    private func syncLiveActivity(with state: ConversationState) {
        if state.status == .running {
            turnSawRunning = true
            guard activityLive else { return }
            let live = Self.liveStatus(for: state)
            AppActivityController.shared.update(
                sessionID: session.id, phase: live.phase, statusText: live.text,
                lastTool: live.tool, toolCount: live.toolCount, icon: live.icon,
                title: AgentSession.isPlaceholderTitle(displayTitle) ? nil : displayTitle)
        } else if (state.status == .idle || state.status == .stable), activityLive, turnSawRunning {
            AppActivityController.shared.end(
                sessionID: session.id, outcome: state.lastFailure == nil ? .done : .error)
            activityLive = false
            turnSawRunning = false
        }
    }

    /// The messages written while a turn was running. Held here rather than handed to the server
    /// precisely so they can still be changed: the next thing you type is the thing you most often
    /// want to reword once you have read another paragraph of the answer.
    private(set) var queue = SendQueue()
    private var lastSent: QueuedSend?

    var queued: [QueuedSend] { queue.items }

    @discardableResult
    func removeQueued(id: UUID) -> QueuedSend? {
        let removed = queue.remove(id: id)
        if removed != nil { onPending?() }
        return removed
    }

    /// The last thing written, taken back into the composer — what ↑ from an empty box means.
    @discardableResult
    func takeBackLastQueued() -> QueuedSend? {
        let taken = queue.takeLast()
        if taken != nil { onPending?() }
        return taken
    }

    /// Rewrites a waiting message in place, keeping its turn in the order.
    func replaceQueued(id: UUID, text: String, attachments: [PromptAttachment]) {
        guard queue.replace(id: id, text: text, attachments: attachments) else { return }
        onPending?()
    }

    private func flushQueue() {
        guard !isBusy, !queue.isEmpty, !queueHeldAfterFailure else { return }
        guard let next = queue.takeFirst() else { return }
        deliver(next.text, model: next.model, effort: next.effort, attachments: next.attachments)
    }

    /// A failed send must never drain the queue into the same dead connection.
    /// Flushing on failure sent the next message straight back into the fault,
    /// and each successive failure overwrote the previous one's recovery slot —
    /// message 1 to the composer, message 2 to the pasteboard, message 3 over
    /// that — so one tailnet blip silently destroyed everything the user had
    /// queued. The queue is preserved and drains from the state loop once the
    /// server answers again.
    ///
    /// Where the words end up follows from what else is waiting. With nothing behind it the
    /// message stays exactly where it was written, as its own row, now saying it did not go and
    /// offering to send it again — the words are never moved out from under the reader into a
    /// composer or a pasteboard they have to go looking in. With messages already queued behind
    /// it, it returns to the head of the queue instead, because the order somebody wrote things
    /// in outranks the row they were written on.
    private func recoverFailedSend(_ send: QueuedSend, row: UUID, reason: String) {
        if queue.isEmpty {
            pending.mark(id: row, .failed(reason: reason))
            queueHold = nil
        } else {
            pending.remove(id: row)
            queue.requeueAtHead(send)
            queueHeldAfterFailure = true
            queueHold = reason
        }
        onPending?()
    }

    /// Why the queue stopped draining, when it has. A queue that quietly stopped looks exactly
    /// like one waiting its turn, and the difference is the only thing worth knowing.
    private(set) var queueHold: String?

    /// Sends a failed row again, keeping its place and its identity — with a turn now running it
    /// joins the queue like anything else written during one.
    func retryPending(id: UUID) {
        guard let send = pending.send(id: id), send.isFailed else { return }
        let attachments = send.attachments
        let text = send.text
        guard !isBusy else {
            pending.remove(id: id)
            queue.append(QueuedSend(text: text, attachments: attachments))
            onPending?()
            return
        }
        deliver(
            text, model: send.model ?? selectedModel, effort: send.effort ?? currentEffort,
            attachments: attachments, reusing: id)
    }

    /// Takes a failed row back to be rewritten. The row goes; its words are the caller's now.
    @discardableResult
    func takeBackPending(id: UUID) -> PendingSend? {
        let taken = pending.remove(id: id)
        if taken != nil { onPending?() }
        return taken
    }

    @discardableResult
    func discardPending(id: UUID) -> PendingSend? {
        let dropped = pending.remove(id: id)
        if dropped != nil { onPending?() }
        return dropped
    }

    /// Gates auto-flush after a failure without depending on
    /// `ConversationState.lastFailure`, which the Kit only clears on a new
    /// send, a `.live` transition, or a successful refresh — a failure while
    /// the connection never left `.live` would leave it set and wedge the
    /// queue forever. This clears the moment a turn is genuinely running
    /// again, and any explicit user send clears it outright.
    private var queueHeldAfterFailure = false

    func stop() {
        streamGeneration += 1
        streamTask?.cancel()
        streamTask = nil
        resumeClock?.cancel()
        resumeClock = nil
    }

    /// Re-dials the event stream and re-fetches the transcript. Called on foregrounding: the
    /// socket may be half-open after suspension (reads hang, no error), so waiting for it to fail
    /// isn't enough — the reconnect has to be forced. The conversation reconnects underneath us
    /// rather than the stream being torn down and rebuilt, so no snapshot is lost in the gap and
    /// a second observer (another window, the session list) is not disturbed. A stream that ended
    /// on its own is started rather than reconnected — there is nothing to re-dial.
    private var lastResync: Date = .distantPast

    func resync() {
        guard streamTask != nil || isBound, Date().timeIntervalSince(lastResync) > 1 else { return }
        lastResync = Date()
        guard streamTask != nil else {
            start()
            return
        }
        let conversation = self.conversation
        Task { await conversation.reconnect() }
    }

    func send(
        _ text: String, model: ModelSelection? = nil, effort: String? = nil,
        attachments: [PromptAttachment] = []
    ) {
        if isBusy {
            AppLogger.chat.info(
                "send queued session=\(session.id) queue=\(queue.count + 1)")
            queue.append(
                QueuedSend(text: text, model: model, effort: effort, attachments: attachments))
            onPending?()
            return
        }
        deliver(text, model: model, effort: effort, attachments: attachments)
    }

    /// Re-sends the most recent user prompt (regenerate).
    func regenerate() {
        guard let last = lastSent, !isBusy else { return }
        deliver(last.text, model: last.model, effort: last.effort, attachments: last.attachments)
    }

    var canRegenerate: Bool { lastSent != nil && !isBusy }

    private var sendTask: Task<Void, Never>?

    /// Holds a send on the wire for as long as `TAILSCODE_HOLD_SEND` says, so the states a fast
    /// server passes through in a frame can be seen and photographed. A screenshot that has to
    /// win a race is a screenshot nobody takes twice.
    nonisolated private static func harnessDelay() async throws {
        #if DEBUG
            guard
                let seconds = ProcessInfo.processInfo.environment["TAILSCODE_HOLD_SEND"]
                    .flatMap(Double.init)
            else { return }
            try await Task.sleep(for: .seconds(seconds))
        #endif
    }

    /// Makes the send fail, which is the one state a working server will not show you.
    nonisolated private static var harnessFault: (any Error)? {
        #if DEBUG
            guard let reason = ProcessInfo.processInfo.environment["TAILSCODE_FAIL_SEND"] else {
                return nil
            }
            return HarnessFault(reason: reason)
        #else
            return nil
        #endif
    }

    private struct HarnessFault: LocalizedError {
        let reason: String
        var errorDescription: String? { reason }
    }

    private struct SendTimeout: LocalizedError {
        var errorDescription: String? {
            String(localized: "The server didn't respond — check your connection.")
        }
    }

    /// Sends optimistically: the prompt echoes into the transcript, the
    /// thinking state engages, and the Live Activity starts immediately —
    /// ActivityKit only allows starting one while foregrounded, so waiting
    /// for the server's `.running` event breaks the send-and-background flow.
    /// The delivery itself is bounded to 15s (`prompt_async` returns
    /// immediately when reachable), so a dead tunnel fails fast instead of
    /// hanging in the thinking state for minutes.
    private var sendGeneration = 0

    private func deliver(
        _ text: String, model: ModelSelection?, effort: String?, attachments: [PromptAttachment],
        reusing row: UUID? = nil
    ) {
        AppLogger.chat.info(
            "send session=\(session.id) chars=\(text.count) attachments=\(attachments.count)")
        queueHeldAfterFailure = false
        queueHold = nil
        sendTask?.cancel()
        sendGeneration += 1
        let generation = sendGeneration
        dismissedFailure = nil
        let outgoing = QueuedSend(
            text: text, model: model, effort: effort, attachments: attachments)
        lastSent = outgoing
        let userCount = state.messages.count { $0.role == .user }
        let echoID: UUID
        if let row, pending.restart(id: row, userMessages: userCount) != nil {
            echoID = row
        } else {
            echoID = pending.begin(
                text: text, attachments: attachments, model: model ?? selectedModel,
                effort: effort ?? currentEffort, userMessages: userCount).id
        }
        optimisticThinking = true
        onPending?()
        if !activityLive {
            let activityTitle = AgentSession.isPlaceholderTitle(displayTitle)
                ? AgentSession.provisionalTitle(fromPrompt: text) : displayTitle
            let backend = self.backend
            let sessionID = session.id
            activityLive = AppActivityController.shared.start(
                sessionID: sessionID, sessionTitle: activityTitle, serverName: serverName,
                onPushToken: { token, startedAt in
                    #if DEBUG
                        let environment = "development"
                    #else
                        let environment = "production"
                    #endif
                    try? await backend.registerLiveActivity(
                        LiveActivityRegistration(
                            token: token, environment: environment,
                            startedAt: startedAt, title: activityTitle),
                        for: sessionID)
                })
            turnSawRunning = false
        }
        let resolvedModel = model ?? selectedModel
        let resolvedEffort = ModelEffort.surviving(
            effort ?? currentEffort, options: reasoningEffortOptions)
        if Ultracode.invokes(text) || resolvedEffort == Ultracode.effortLevel {
            ultracodeInFlight = true
            onModelChange?()
        }
        let payloadBytes = attachments.reduce(0) { $0 + ($1.data?.count ?? 0) }
        let sendBound = 15 + payloadBytes / 50_000
        sendTask = Task {
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { [conversation] in
                        try await Self.harnessDelay()
                        if let fault = Self.harnessFault { throw fault }
                        try await conversation.send(
                            text, model: resolvedModel, reasoningEffort: resolvedEffort,
                            attachments: attachments)
                    }
                    group.addTask {
                        try await Task.sleep(for: .seconds(sendBound))
                        throw SendTimeout()
                    }
                    try await group.next()
                    group.cancelAll()
                }
                // The server has it. Which is a different fact from the turn having started, and
                // the row says so rather than sitting on "sending" until the transcript catches up.
                if generation == sendGeneration, pending.mark(id: echoID, .accepted) {
                    onPending?()
                }
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, generation == sendGeneration else { return }
                if optimisticThinking, !turnSawRunning {
                    optimisticThinking = false
                    if activityLive {
                        AppActivityController.shared.end(
                            sessionID: session.id, outcome: .error,
                            statusText: String(localized: "No response"))
                        activityLive = false
                    }
                    recoverFailedSend(
                        outgoing, row: echoID,
                        reason: String(localized: "the machine never picked it up"))
                }
            } catch {
                let cancelled = error is CancellationError
                guard generation == sendGeneration else {
                    pending.remove(id: echoID)
                    onPending?()
                    return
                }
                optimisticThinking = false
                if activityLive, !turnSawRunning {
                    AppActivityController.shared.end(
                        sessionID: session.id, outcome: cancelled ? .done : .error,
                        statusText: cancelled
                            ? String(localized: "Cancelled")
                            : String(localized: "Couldn't send"))
                    activityLive = false
                }
                if cancelled {
                    pending.remove(id: echoID)
                    onPending?()
                } else {
                    AppLogger.chat.error("send failed: \(Self.readable(error))")
                    let reason = Self.readable(error)
                    recoverFailedSend(outgoing, row: echoID, reason: reason)
                    armResume(row: echoID, reason: reason)
                }
            }
        }
    }

    /// Stop always does something: a send still in flight is cancelled
    /// locally, AND the server is asked to abort in case the prompt already
    /// landed; a running turn is aborted server-side.
    func abort() {
        if optimisticThinking, !turnSawRunning {
            sendTask?.cancel()
            optimisticThinking = false
            pending.removeAll()
            if activityLive {
                AppActivityController.shared.end(
                    sessionID: session.id, outcome: .done, statusText: String(localized: "Cancelled"))
                activityLive = false
            }
            onPending?()
            if canAbort { Task { try? await conversation.cancelCurrentTurn() } }
            return
        }
        guard canAbort else { return }
        Task {
            do {
                try await conversation.cancelCurrentTurn()
            } catch {
                onError?(Self.readable(error))
            }
        }
    }

    func refresh() {
        Task { try? await conversation.refresh() }
    }

    func respond(to permission: PermissionRequest, decision: PermissionDecision) {
        AppLogger.chat.info("permission \(permission.toolName ?? "?") -> \(decision.rawValue)")
        Task {
            do {
                try await conversation.respond(to: permission, decision: decision)
            } catch {
                onError?(Self.readable(error))
            }
        }
    }

    /// An agent that takes its answer as an ordinary message is answered through
    /// the composer's own path: the reply queues behind a turn already running
    /// (which a direct call would be refused for), echoes locally, and reads back
    /// as what the user actually said.
    func answerQuestion(_ question: QuestionRequest, answers: [[String]]) {
        AppLogger.chat.info("question \(question.id) answered")
        if backend.capabilities.answersQuestionsByMessage {
            let text = question.answerMessage(answers)
            guard !text.isEmpty else { return }
            send(text, model: selectedModel, effort: currentEffort)
            Task { await conversation.markAnswered(question) }
            return
        }
        Task {
            do {
                try await conversation.answer(question, answers: answers)
            } catch {
                onQuestionFailed?(question.id)
                onError?(Self.readable(error))
            }
        }
    }

    /// Continues a turn the server's machine cut off. The work happens on that machine — this is
    /// not a resend — so the card comes down when the server says it took it, not on the press.
    func resumeInterruptedTurn() {
        AppLogger.chat.info("interrupted turn resumed")
        Task {
            do {
                try await conversation.resumeInterruptedTurn()
            } catch {
                onError?(Self.readable(error))
            }
        }
    }

    /// Lets the interrupted turn go. Nothing in the transcript changes; only the offer stops.
    func dismissInterruptedTurn() {
        AppLogger.chat.info("interrupted turn dismissed")
        Task {
            do {
                try await conversation.dismissInterruptedTurn()
            } catch {
                onError?(Self.readable(error))
            }
        }
    }

    func rejectQuestion(_ question: QuestionRequest) {
        AppLogger.chat.info("question \(question.id) skipped")
        Task {
            do {
                try await conversation.reject(question)
            } catch {
                onQuestionFailed?(question.id)
                onError?(Self.readable(error))
            }
        }
    }

    private var knownModels: [ModelInfo] = []

    func availableModels() async -> [ModelInfo] {
        let models = await ModelCatalog.models(for: contextID, backend: backend)
        if !models.isEmpty { knownModels = models }
        return models
    }

    private var cachedUsage: (value: AgentUsage?, at: Date)?

    func usage() async -> AgentUsage? {
        if let cached = cachedUsage, Date().timeIntervalSince(cached.at) < 30 {
            return cached.value
        }
        let value = try? await backend.sessionUsage(session.id)
        cachedUsage = (value, Date())
        return value
    }

    /// One failed turn otherwise poisons the session: the Kit keeps
    /// `lastFailure` until reconnect, so the banner would resurface the old
    /// error after every later successful turn. A new send or an explicit
    /// banner tap acknowledges the current failure.
    private(set) var dismissedFailure: BackendFailure?

    func acknowledgeFailure() {
        dismissedFailure = state.lastFailure
    }

    func selectModel(_ model: ModelSelection?) {
        selectedModel = model
        ModelPreferenceStore.recordPick(model, sessionKey: persistKey, contextID: contextID)
        let kept = ModelEffort.adopt(
            currentEffort, for: model, models: knownModels,
            agentOptions: backend.reasoningEffortOptions)
        if kept != currentEffort {
            currentEffort = kept
            EffortPreferenceStore.recordPick(kept, sessionKey: persistKey, contextID: contextID)
        }
        onModelChange?()
    }

    func setEffort(_ level: String?) {
        currentEffort = level
        EffortPreferenceStore.recordPick(level, sessionKey: persistKey, contextID: contextID)
        onModelChange?()
    }

    /// Applies the model and effort chosen before this session existed — Home's
    /// composer picks them, then creates the session on send — so the first turn
    /// runs on the intended model instead of racing the async default lookup.
    func seed(_ choice: ModelChoice) {
        if let model = choice.model {
            selectedModel = model
            ModelPreferenceStore.setModel(model, forKey: persistKey)
        }
        if let effort = choice.effort {
            currentEffort = effort
            EffortPreferenceStore.setEffort(effort, forKey: persistKey)
        }
    }

    func clearConversation() {
        Task {
            try? await backend.clearConversation(session.id)
            try? await conversation.refresh()
        }
    }

    private func loadDefaultModelIfNeeded() async {
        if supportsReasoningEffort, currentEffort == nil {
            currentEffort = ChatModelResolver.effort(
                profileID: contextID, backend: backend, sessionKey: persistKey,
                sessionEffort: session.reasoningEffort)
        }
        guard supportsModelSelection, selectedModel == nil else {
            onModelChange?()
            return
        }
        selectedModel = await ChatModelResolver.model(
            profileID: contextID, backend: backend, sessionKey: persistKey,
            sessionModel: session.model, sessionModelProviderID: session.modelProviderID)
        onModelChange?()
    }

    /// What the turn is doing, in the Live Activity's own vocabulary. What it *is* is decided once
    /// in `ActivityKind.inFlight`, so the badge in the navigation bar, the row in the list and the
    /// card on the lock screen can never disagree about the same second; the wording stays here,
    /// because a lock screen has room for a sentence where a band has room for a word.
    static func liveStatus(for state: ConversationState) -> (
        phase: AppActivityController.Phase, text: String, tool: String?, toolCount: Int,
        icon: ActivityIcon
    ) {
        let last = state.messages.last
        let tools = (last?.parts ?? []).compactMap { part -> ToolCall? in
            if case .tool(let call) = part.kind { return call }
            return nil
        }
        let lastTool = (tools.last { $0.status == .running } ?? tools.last).map(\.name)
        let activity = ActivityKind.inFlight(in: state) ?? .thinking
        switch activity {
        case .needsAnswer:
            return (
                .approval, String(localized: "Waiting for your answer"), lastTool, tools.count,
                activity.icon
            )
        case .needsApproval:
            return (
                .approval, String(localized: "Awaiting your approval"), lastTool, tools.count,
                activity.icon
            )
        case .usingTool(let name, _):
            return (
                .tool, String(localized: "Running \(name)"), lastTool, tools.count, activity.icon
            )
        case .compacting:
            return (.tool, String(localized: "Compacting…"), lastTool, tools.count, activity.icon)
        case .writing:
            return (
                .responding, String(localized: "Writing…"), lastTool, tools.count, activity.icon
            )
        default:
            return (
                .thinking, String(localized: "Thinking…"), lastTool, tools.count,
                ActivityKind.thinking.icon
            )
        }
    }

    static func readable(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
