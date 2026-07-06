import CodingAgentKit
import Foundation

@MainActor
final class SessionListViewModel {
    let backend: any CodingAgentBackend
    private(set) var sessions: [AgentSession] = []

    var onChange: (() -> Void)?
    var onError: ((String) -> Void)?

    init(backend: any CodingAgentBackend) {
        self.backend = backend
    }

    var supportsMultipleSessions: Bool { backend.capabilities.supportsMultipleSessions }

    func load() async {
        do {
            let all = try await backend.listSessions()
            sessions = all.filter { $0.parentID == nil }.sorted { $0.updatedAt > $1.updatedAt }
            AppLogger.session.info("loaded \(sessions.count)/\(all.count) sessions via \(String(describing: type(of: backend)))")
            onChange?()
        } catch {
            onError?(Self.readable(error))
        }
    }

    func newSession() async -> AgentSession? {
        do {
            let session = try await backend.createSession(title: nil)
            await load()
            return session
        } catch {
            onError?(Self.readable(error))
            return nil
        }
    }

    func delete(_ session: AgentSession) async {
        do {
            try await backend.deleteSession(session.id)
            sessions.removeAll { $0.id == session.id }
            onChange?()
        } catch {
            onError?(Self.readable(error))
            await load()
        }
    }

    static func readable(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
