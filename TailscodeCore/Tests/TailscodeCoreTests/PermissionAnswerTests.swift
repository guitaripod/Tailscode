import AgentTestSupport
import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("Answering an approval from a notice")
struct PermissionAnswerTests {
    private let request = PermissionRequest(id: "perm-1", sessionID: "s1", toolName: "Bash")

    private func state(pending: [PermissionRequest], loaded: Bool) -> ConversationState {
        var state = ConversationState()
        state.pendingPermissions = pending
        state.hasLoadedTranscript = loaded
        return state
    }

    @Test("A request in the pending list is pending")
    func pending() {
        #expect(
            PermissionAnswer.standing(of: request, in: state(pending: [request], loaded: true))
                == .pending)
    }

    @Test("A request missing from a conversation that has read the server is settled")
    func settled() {
        #expect(
            PermissionAnswer.standing(of: request, in: state(pending: [], loaded: true)) == .settled)
    }

    @Test("A conversation that has read nothing yet cannot say")
    func unknown() {
        #expect(
            PermissionAnswer.standing(of: request, in: state(pending: [], loaded: false)) == .unknown)
    }

    @Test("An open chat that already settled the request is not asked again")
    func notAskedTwice() async throws {
        let backend = MockBackend(agentType: .claudeCode, script: [], interactive: true)
        let conversation = AgentConversation(backend: backend, sessionID: "s1")
        try await conversation.refresh()
        let outcome = try await PermissionAnswer.answer(
            request, decision: .once, through: conversation, backend: backend)
        #expect(outcome == .settled)
    }

    @Test("A chat nobody has read yet is answered through its conversation")
    func freshConversationAnswers() async throws {
        let backend = MockBackend(agentType: .claudeCode, script: [], interactive: true)
        let conversation = AgentConversation(backend: backend, sessionID: "s1")
        let outcome = try await PermissionAnswer.answer(
            request, decision: .reject, through: conversation, backend: nil)
        #expect(outcome == .answered)
    }

    @Test("With no conversation the backend answers alone, and with neither there is no road")
    func backendAlone() async throws {
        let backend = MockBackend(agentType: .claudeCode, script: [], interactive: true)
        let outcome = try await PermissionAnswer.answer(
            request, decision: .once, through: nil, backend: backend)
        #expect(outcome == .answered)
        await #expect(throws: PermissionAnswer.Failure.self) {
            _ = try await PermissionAnswer.answer(
                request, decision: .once, through: nil, backend: nil)
        }
    }
}
