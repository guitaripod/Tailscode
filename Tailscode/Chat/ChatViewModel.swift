import CodingAgentKit
import Foundation

@MainActor
final class ChatViewModel {
    let backend: any CodingAgentBackend
    let session: AgentSession

    private let conversation: AgentConversation
    private var streamTask: Task<Void, Never>?

    private(set) var state = ConversationState()
    var selectedModel: ModelSelection?

    var onState: ((ConversationState) -> Void)?
    var onError: ((String) -> Void)?

    init(backend: any CodingAgentBackend, session: AgentSession) {
        self.backend = backend
        self.session = session
        self.conversation = AgentConversation(
            backend: backend, sessionID: session.id, cache: AppCache.sessionCache)
    }

    var title: String { session.title }
    var supportsModelSelection: Bool { backend.capabilities.supportsModelSelection }
    var supportsAttachments: Bool { backend.capabilities.supportsAttachments }
    var isBusy: Bool { state.status == .running }

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

    func send(_ text: String, attachments: [PromptAttachment]) {
        AppLogger.chat.info("send (\(text.count) chars, \(attachments.count) attachments)")
        Task {
            do {
                try await conversation.send(text, model: selectedModel, attachments: attachments)
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

    private func loadDefaultModelIfNeeded() async {
        guard supportsModelSelection, selectedModel == nil else { return }
        selectedModel = try? await backend.defaultModel()
        onState?(state)
    }

    static func readable(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
