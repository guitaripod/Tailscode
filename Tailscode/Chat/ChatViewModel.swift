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

    var isBound = true
    var onState: ((ConversationState) -> Void)?
    var onSendFailed: ((String) -> Void)?
    var onModelChange: (() -> Void)?
    var onError: ((String) -> Void)?
    var onQuestionFailed: ((String) -> Void)?

    init(
        backend: any CodingAgentBackend, session: AgentSession, contextID: String = "default",
        serverName: String = "", reportsActivity: Bool = true
    ) {
        self.backend = backend
        self.session = session
        self.contextID = contextID
        self.persistKey = "\(contextID)/\(session.id)"
        self.conversation = AgentConversation(
            backend: backend, sessionID: session.id, cache: AppCache.sessionCache)
        self.serverName = serverName
        self.reportsActivity = reportsActivity
    }

    /// Read-only transcript observers (subagent views) must not feed
    /// SessionActivity — they would fire phantom "finished" notifications
    /// with deep links that resolve to no session.
    let reportsActivity: Bool

    let serverName: String

    private(set) lazy var displayTitle: String = session.title
    var title: String { displayTitle }
    var canRename: Bool { backend.capabilities.supportsRenaming }

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
        guard reportsActivity, !manuallyRenamed else { return }
        Task {
            if delay > .zero { try? await Task.sleep(for: delay) }
            guard !manuallyRenamed,
                let fresh = try? await backend.listSessions()
                    .first(where: { $0.id == session.id }),
                !fresh.hasPlaceholderTitle, fresh.title != displayTitle
            else { return }
            displayTitle = fresh.title
            if activityLive {
                let live = Self.liveStatus(for: state)
                AppActivityController.shared.update(
                    sessionID: session.id, phase: live.phase, statusText: live.text,
                    lastTool: live.tool, toolCount: live.toolCount, title: fresh.title)
            }
            onTitleChange?()
        }
    }

    var supportsModelSelection: Bool { backend.capabilities.supportsModelSelection }
    var supportsReasoningEffort: Bool { backend.capabilities.supportsReasoningEffort }
    var reasoningEffortOptions: [String] { backend.reasoningEffortOptions }
    var supportsAttachments: Bool { backend.capabilities.supportsAttachments }
    var canClear: Bool { backend.capabilities.supportsClearing }
    var canFork: Bool { backend.capabilities.supportsForking }
    var canAbort: Bool { backend.capabilities.supportsAbort }
    var supportsUsage: Bool { backend.capabilities.supportsSessionUsage }
    var supportsFileBrowsing: Bool { backend.capabilities.supportsFileBrowsing }
    var isBusy: Bool { state.status == .running || optimisticThinking }

    func fork() async throws -> AgentSession {
        try await backend.forkSession(session.id)
    }

    var supportsSubagents: Bool { backend.capabilities.supportsSubagents }

    func subagents() async -> [SubagentSummary] {
        (try? await backend.subagents(for: session.id)) ?? []
    }

    private var isClaude: Bool { backend.agentType == .claudeCode }

    func start() {
        streamTask = Task { [weak self] in
            guard let self else { return }
            for await state in await self.conversation.states() {
                self.reconcileOptimisticState(with: state)
                if self.state.status == .running, state.status != .running {
                    self.cachedUsage = nil
                    self.refreshTitleFromServer()
                    self.refreshTitleFromServer(delay: .seconds(12))
                }
                self.state = state
                self.onState?(state)
                let awaiting =
                    state.pendingPermissions.first != nil || state.pendingQuestions.first != nil
                if self.reportsActivity {
                    SessionActivity.shared.update(
                        sessionID: self.session.id, title: self.displayTitle,
                        status: awaiting ? .awaitingApproval : (self.isBusy ? .running : .idle),
                        keepAlive: self)
                }
                self.syncLiveActivity(with: state)
                if state.status != .running { self.flushQueue() }
                if !self.isBusy, !awaiting, !self.isBound, self.queued.isEmpty {
                    self.stop()
                }
            }
        }
        Task { await loadDefaultModelIfNeeded() }
    }

    /// A locally-echoed prompt, shown instantly while the server round-trip
    /// is in flight; dropped once the server transcript grows a new user
    /// message (count-based, so re-sending "ok" can't match an old message,
    /// and server-side prompt rewrites can't strand a duplicate).
    struct LocalEcho {
        let id = UUID()
        let text: String
        let baselineUserCount: Int
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
                lastTool: live.tool, toolCount: live.toolCount,
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
        guard !isBusy, !queued.isEmpty else { return }
        let next = queued.removeFirst()
        onState?(state)
        deliver(next.text, model: next.model, effort: next.effort, attachments: next.attachments)
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
    }

    /// Tears down and re-establishes the event stream, then re-fetches the
    /// transcript. Called on foregrounding: the socket may be half-open after
    /// suspension (reads hang, no error), so waiting for it to fail isn't
    /// enough — the reconnect has to be forced.
    private var lastResync: Date = .distantPast

    func resync() {
        guard streamTask != nil, Date().timeIntervalSince(lastResync) > 1 else { return }
        lastResync = Date()
        stop()
        start()
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
        var errorDescription: String? { "The server didn't respond — check your connection." }
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
        sendTask?.cancel()
        sendGeneration += 1
        let generation = sendGeneration
        dismissedFailure = nil
        lastSent = QueuedMessage(text: text, model: model, effort: effort, attachments: attachments)
        let echo = LocalEcho(
            text: text, baselineUserCount: state.messages.count { $0.role == .user })
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
                            sessionID: session.id, outcome: .error, statusText: "No response")
                        activityLive = false
                    }
                    onState?(state)
                    onSendFailed?(text)
                    flushQueue()
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
                        statusText: cancelled ? "Cancelled" : "Couldn't send")
                    activityLive = false
                }
                onState?(state)
                if !cancelled {
                    AppLogger.chat.error("send failed: \(error)")
                    onSendFailed?(text)
                    onError?(Self.readable(error))
                    flushQueue()
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
                    sessionID: session.id, outcome: .done, statusText: "Cancelled")
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

    func answerQuestion(_ question: QuestionRequest, answers: [[String]]) {
        AppLogger.chat.info("question \(question.id) answered")
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

    func availableModels() async -> [ModelInfo] {
        (try? await backend.availableModels()) ?? []
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

    func selectModel(_ model: ModelSelection) {
        selectedModel = model
        RecentModelsStore.record(model)
        ModelPreferenceStore.setModel(model, forKey: persistKey)
        ModelPreferenceStore.setGlobalModel(model, forContextID: contextID)
        onModelChange?()
    }

    func setEffort(_ level: String) {
        currentEffort = level
        EffortPreferenceStore.setEffort(level, forKey: persistKey)
        onModelChange?()
    }

    func clearConversation() {
        Task {
            try? await backend.clearConversation(session.id)
            try? await conversation.refresh()
        }
    }

    private func loadDefaultModelIfNeeded() async {
        guard supportsModelSelection, selectedModel == nil else { return }
        if let saved = ModelPreferenceStore.model(forKey: persistKey)
            ?? ModelPreferenceStore.globalModel(forContextID: contextID)
        {
            selectedModel = saved
        } else if !isClaude, let fallback = try? await backend.defaultModel() {
            selectedModel = fallback
        }
        if isClaude, currentEffort == nil {
            currentEffort = EffortPreferenceStore.effort(forKey: persistKey)
        }
        onModelChange?()
    }

    static func liveStatus(for state: ConversationState) -> (
        phase: AppActivityController.Phase, text: String, tool: String?, toolCount: Int
    ) {
        let last = state.messages.last
        let tools = (last?.parts ?? []).compactMap { part -> ToolCall? in
            if case .tool(let call) = part.kind { return call }
            return nil
        }
        let runningTool = tools.last { $0.status == .running }
        let lastTool = (runningTool ?? tools.last).map(\.name)
        if state.pendingQuestions.first != nil {
            return (.approval, "Waiting for your answer", lastTool, tools.count)
        }
        if state.pendingPermissions.first != nil {
            return (.approval, "Awaiting your approval", lastTool, tools.count)
        }
        if let runningTool {
            return (.tool, "Running \(runningTool.name)", lastTool, tools.count)
        }
        if let last, last.role == .assistant, last.completedAt == nil,
            case .text(let text)? = last.parts.last?.kind, !text.isEmpty
        {
            return (.responding, "Writing\u{2026}", lastTool, tools.count)
        }
        return (.thinking, "Thinking\u{2026}", lastTool, tools.count)
    }

    static func readable(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
