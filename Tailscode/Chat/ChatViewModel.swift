import CodingAgentKit
import Foundation

@MainActor
final class ChatViewModel {
    let backend: any CodingAgentBackend
    let session: AgentSession

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
    var isBusy: Bool { state.status == .running }

    private var isClaude: Bool { backend.agentType == .claudeCode }

    func start() {
        streamTask = Task { [weak self] in
            guard let self else { return }
            for await state in await self.conversation.states() {
                self.state = state
                self.onState?(state)
            }
        }
        Task { await loadDefaultModelIfNeeded() }
    }

    func stop() {
        streamTask?.cancel()
        streamTask = nil
    }

    func send(
        _ text: String, model: ModelSelection? = nil, effort: String? = nil,
        attachments: [PromptAttachment] = []
    ) {
        AppLogger.chat.info("send (\(text.count) chars, \(attachments.count) attachments)")
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
