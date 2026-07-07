import CodingAgentKit
import Foundation

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

    var onState: ((ConversationState) -> Void)?
    var onModelChange: (() -> Void)?
    var onError: ((String) -> Void)?

    init(backend: any CodingAgentBackend, session: AgentSession, contextID: String = "default") {
        self.backend = backend
        self.session = session
        self.contextID = contextID
        self.persistKey = "\(contextID)/\(session.id)"
        self.conversation = AgentConversation(
            backend: backend, sessionID: session.id, cache: AppCache.sessionCache)
    }

    var title: String { session.title }
    var supportsModelSelection: Bool { backend.capabilities.supportsModelSelection }
    var supportsReasoningEffort: Bool { backend.capabilities.supportsReasoningEffort }
    var reasoningEffortOptions: [String] { backend.reasoningEffortOptions }
    var supportsAttachments: Bool { backend.capabilities.supportsAttachments }
    var canClear: Bool { backend.capabilities.supportsClearing }
    var canFork: Bool { backend.capabilities.supportsForking }
    var isBusy: Bool { state.status == .running }

    func fork() async throws -> AgentSession {
        try await backend.forkSession(session.id)
    }

    private var isClaude: Bool { backend.agentType == .claudeCode }

    func start() {
        streamTask = Task { [weak self] in
            guard let self else { return }
            for await state in await self.conversation.states() {
                self.state = state
                self.onState?(state)
                let activity: SessionActivity.Status =
                    state.pendingPermissions.first != nil
                    ? .awaitingApproval : (state.status == .running ? .running : .idle)
                SessionActivity.shared.update(
                    sessionID: self.session.id, title: self.session.title, status: activity,
                    keepAlive: self)
                if state.status != .running { self.flushQueue() }
            }
        }
        Task { await loadDefaultModelIfNeeded() }
    }

    private(set) var queued: [String] = []
    private var lastSentText: String?

    private func flushQueue() {
        guard state.status != .running, !queued.isEmpty else { return }
        let next = queued.removeFirst()
        onState?(state)
        deliver(next, model: nil, effort: nil, attachments: [])
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
    }

    func send(
        _ text: String, model: ModelSelection? = nil, effort: String? = nil,
        attachments: [PromptAttachment] = []
    ) {
        if isBusy {
            queued.append(text)
            onState?(state)
            return
        }
        deliver(text, model: model, effort: effort, attachments: attachments)
    }

    /// Re-sends the most recent user prompt (regenerate).
    func regenerate() {
        guard let last = lastSentText, !isBusy else { return }
        deliver(last, model: nil, effort: nil, attachments: [])
    }

    var canRegenerate: Bool { lastSentText != nil && !isBusy }

    private func deliver(
        _ text: String, model: ModelSelection?, effort: String?, attachments: [PromptAttachment]
    ) {
        AppLogger.chat.info("send (\(text.count) chars, \(attachments.count) attachments)")
        lastSentText = text
        Task {
            do {
                try await conversation.send(
                    text, model: model ?? selectedModel, reasoningEffort: effort ?? currentEffort,
                    attachments: attachments)
            } catch {
                onError?(Self.readable(error))
            }
        }
    }

    func abort() {
        Task { try? await conversation.cancelCurrentTurn() }
    }

    func respond(to permission: PermissionRequest, decision: PermissionDecision) {
        AppLogger.chat.info("permission \(permission.toolName ?? "?") -> \(decision.rawValue)")
        Task { try? await conversation.respond(to: permission, decision: decision) }
    }

    func availableModels() async -> [ModelInfo] {
        (try? await backend.availableModels()) ?? []
    }

    func usage() async -> AgentUsage? {
        try? await backend.sessionUsage(session.id)
    }

    func selectModel(_ model: ModelSelection) {
        selectedModel = model
        ModelPreferenceStore.setModel(model, forKey: persistKey)
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
        if let saved = ModelPreferenceStore.model(forKey: persistKey) {
            selectedModel = saved
        } else if !isClaude, let fallback = try? await backend.defaultModel() {
            selectedModel = fallback
        }
        if isClaude, currentEffort == nil {
            currentEffort = EffortPreferenceStore.effort(forKey: persistKey)
        }
        onModelChange?()
    }

    static func readable(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
