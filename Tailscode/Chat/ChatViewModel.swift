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
    var onSendFailed: ((String) -> Void)?
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

    /// Effort is a property of the model where the catalog says so (opencode's variants differ
    /// per model); the backend-wide list serves agents whose models all take the same levels.
    var reasoningEffortOptions: [String] {
        if let variants = activeModelVariants, !variants.isEmpty { return variants }
        return backend.reasoningEffortOptions
    }

    private var activeModelVariants: [String]? {
        let active = selectedModel?.modelID ?? lastAssistantModelID ?? session.model
        guard let active else { return nil }
        return knownModels.first { $0.id == active }?.variants
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

    var displayedEffort: String? {
        if let currentEffort { return currentEffort }
        if let stored = session.reasoningEffort, !stored.isEmpty { return stored }
        return lastAssistantEffort
    }
    var supportsAttachments: Bool { backend.capabilities.supportsAttachments }

    /// Whether the current model can receive an image attachment. Falls back
    /// to the backend-level capability when the server didn't advertise
    /// per-model capabilities (or no model is selected yet).
    var canAttachImages: Bool {
        guard supportsAttachments else { return false }
        guard let caps = selectedModelCapabilities else { return true }
        return caps.attachment && caps.imageInput
    }

    /// Whether the current model can receive non-image file attachments
    /// (e.g. a large paste converted to a text file).
    var canAttachFiles: Bool {
        guard supportsAttachments else { return false }
        guard let caps = selectedModelCapabilities else { return true }
        return caps.attachment
    }

    private var selectedModelCapabilities: ModelCapabilities? {
        guard let selected = selectedModel else { return nil }
        return knownModels.first {
            $0.providerID == selected.providerID && $0.id == selected.modelID
        }?.capabilities
    }
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
    /// the app look frozen until the server streamed something back.
    func run(_ command: AgentCommand, arguments: String? = nil) {
        if backend.resolvesCommandsFromPromptText {
            send(command.invocation(arguments: arguments))
            return
        }
        Task { [weak self] in
            guard let self else { return }
            do {
                try await conversation.run(command, arguments: arguments)
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
                "start reuse vm=\(vmTag) queued=\(queued.count) echoes=\(localEchoes.count)")
            onState?(state)
            return
        }
        AppLogger.chat.info(
            "start fresh vm=\(vmTag) queued=\(queued.count) echoes=\(localEchoes.count)")
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
                let displayedBefore = (self.displayedModel, self.displayedEffort)
                self.state = state
                if (self.displayedModel, self.displayedEffort) != displayedBefore {
                    self.onModelChange?()
                }
                if state.status == .running { self.queueHeldAfterFailure = false }
                self.onState?(state)
                let awaiting =
                    state.pendingPermissions.first != nil || state.pendingQuestions.first != nil
                SessionActivity.shared.update(
                    sessionID: self.session.id, profileID: self.contextID,
                    title: self.displayTitle,
                    status: awaiting ? .awaitingApproval : (self.isBusy ? .running : .idle),
                    keepAlive: self)
                self.syncLiveActivity(with: state)
                if state.status != .running { self.flushQueue() }
                if !self.isBusy, !awaiting, !self.isBound, self.queued.isEmpty {
                    self.stop()
                }
            }
            self.handleStreamTermination(generation: generation)
        }
        Task { await loadDefaultModelIfNeeded() }
    }

    private var streamGeneration = 0

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

    /// A locally-echoed prompt, shown instantly while the server round-trip
    /// is in flight; dropped once the server transcript grows a new user
    /// message (count-based, so re-sending "ok" can't match an old message,
    /// and server-side prompt rewrites can't strand a duplicate).
    struct LocalEcho {
        let id = UUID()
        let text: String
        let baselineUserCount: Int
        /// Rendered from the bytes still in memory, so an image the user just
        /// picked is on screen before the server has echoed the message back.
        var attachments: [PromptAttachment] = []
    }

    private(set) var localEchoes: [LocalEcho] = []
    private(set) var optimisticThinking = false
    private var activityLive = false
    private var turnSawRunning = false

    private func reconcileOptimisticState(with state: ConversationState) {
        if state.status == .running { optimisticThinking = false }
        if !localEchoes.isEmpty {
            let userCount = state.messages.count { $0.role == .user }
            localEchoes.removeAll { userCount > $0.baselineUserCount }
        }
        if optimisticThinking, localEchoes.isEmpty,
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

    struct QueuedMessage {
        let id = UUID()
        let text: String
        let model: ModelSelection?
        let effort: String?
        let attachments: [PromptAttachment]
    }

    private(set) var queued: [QueuedMessage] = []
    private var lastSent: QueuedMessage?

    func removeQueued(id: UUID) -> QueuedMessage? {
        guard let index = queued.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = queued.remove(at: index)
        onState?(state)
        return removed
    }

    private func flushQueue() {
        guard !isBusy, !queued.isEmpty, !queueHeldAfterFailure else { return }
        let next = queued.removeFirst()
        onState?(state)
        deliver(next.text, model: next.model, effort: next.effort, attachments: next.attachments)
    }

    /// A failed send must never drain the queue into the same dead connection.
    /// Flushing on failure sent the next message straight back into the fault,
    /// and each successive failure overwrote the previous one's recovery slot —
    /// message 1 to the composer, message 2 to the pasteboard, message 3 over
    /// that — so one tailnet blip silently destroyed everything the user had
    /// queued. The queue is preserved and drains from the state loop once the
    /// server answers again. With messages already waiting behind it, the
    /// failure returns to the head of the queue instead of the composer, so
    /// the user's intended order survives.
    private func recoverFailedSend(_ pending: QueuedMessage) {
        if queued.isEmpty {
            onSendFailed?(pending.text)
        } else {
            queued.insert(pending, at: 0)
            queueHeldAfterFailure = true
            onState?(state)
        }
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
            queued.append(QueuedMessage(text: text, model: model, effort: effort, attachments: attachments))
            onState?(state)
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
        _ text: String, model: ModelSelection?, effort: String?, attachments: [PromptAttachment]
    ) {
        AppLogger.chat.info("send (\(text.count) chars, \(attachments.count) attachments)")
        queueHeldAfterFailure = false
        sendTask?.cancel()
        sendGeneration += 1
        let generation = sendGeneration
        dismissedFailure = nil
        let pending = QueuedMessage(
            text: text, model: model, effort: effort, attachments: attachments)
        lastSent = pending
        let echo = LocalEcho(
            text: text, baselineUserCount: state.messages.count { $0.role == .user },
            attachments: attachments.filter { $0.mime.hasPrefix("image/") && $0.data != nil })
        localEchoes.append(echo)
        optimisticThinking = true
        onState?(state)
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
        let resolvedEffort = effort ?? currentEffort
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
                try? await Task.sleep(for: .seconds(30))
                guard !Task.isCancelled, generation == sendGeneration else { return }
                if optimisticThinking, !turnSawRunning {
                    optimisticThinking = false
                    localEchoes.removeAll { $0.id == echo.id }
                    if activityLive {
                        AppActivityController.shared.end(
                            sessionID: session.id, outcome: .error,
                            statusText: String(localized: "No response"))
                        activityLive = false
                    }
                    onState?(state)
                    recoverFailedSend(pending)
                }
            } catch {
                let cancelled = error is CancellationError
                localEchoes.removeAll { $0.id == echo.id }
                guard generation == sendGeneration else {
                    onState?(state)
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
                onState?(state)
                if !cancelled {
                    AppLogger.chat.error("send failed: \(Self.readable(error))")
                    onError?(Self.readable(error))
                    recoverFailedSend(pending)
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
            localEchoes.removeAll()
            if activityLive {
                AppActivityController.shared.end(
                    sessionID: session.id, outcome: .done, statusText: String(localized: "Cancelled"))
                activityLive = false
            }
            onState?(state)
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
                profileID: contextID, backend: backend, sessionKey: persistKey)
        }
        guard supportsModelSelection, selectedModel == nil else {
            onModelChange?()
            return
        }
        selectedModel = await ChatModelResolver.model(
            profileID: contextID, backend: backend, sessionKey: persistKey)
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
