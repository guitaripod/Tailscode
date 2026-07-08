import CodingAgentKit

/// Null-object backend used only if no active connection exists (the app routes to onboarding
/// in that case, so this is a safety fallback that never really runs).
struct UnavailableBackend: CodingAgentBackend {
    let agentType: AgentType = .openCode
    let capabilities = BackendCapabilities(
        supportsFileBrowsing: false, supportsDiffs: false, supportsPermissions: false,
        supportsMultipleSessions: false, supportsModelSelection: false, supportsAttachments: false)

    func health() async throws -> ServerHealth { throw AgentError.connection("No active connection") }
    func listSessions() async throws -> [AgentSession] { [] }
    func createSession(title: String?, directory: String?) async throws -> AgentSession {
        throw AgentError.connection("No active connection")
    }
    func messages(for sessionID: String) async throws -> [ChatMessage] { [] }
    func send(_ prompt: SendPrompt, to sessionID: String) async throws {
        throw AgentError.connection("No active connection")
    }
    func events(for sessionID: String) -> AsyncThrowingStream<BackendEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
