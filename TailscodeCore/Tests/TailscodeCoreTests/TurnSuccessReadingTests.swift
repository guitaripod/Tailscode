import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

/// A settled turn counts toward the rating ask and the supporter card only when it answered and
/// failed at nothing.
@Suite struct TurnSuccessReadingTests {
    private func state(_ message: ChatMessage, status: BackendStatus = .idle) -> ConversationState {
        ConversationState(messages: [message], status: status)
    }

    private func answer(text: String, error: String? = nil) -> ChatMessage {
        ChatMessage(
            id: "a", role: .assistant, agentType: .claudeCode,
            parts: text.isEmpty ? [] : [MessagePart(id: "p", kind: .text(text))],
            createdAt: Date(), completedAt: Date(), error: error)
    }

    @Test func anAnsweredTurnCounts() {
        #expect(TurnSuccessReading.succeeded(state(answer(text: "Done."))))
    }

    @Test func aFailedTurnDoesNot() {
        #expect(!TurnSuccessReading.succeeded(state(answer(text: "", error: "Overloaded"))))
    }

    @Test func aTurnThatSaidNothingDoesNot() {
        #expect(!TurnSuccessReading.succeeded(state(answer(text: ""))))
    }

    @Test func aRunningTurnDoesNot() {
        #expect(!TurnSuccessReading.succeeded(state(answer(text: "Done."), status: .running)))
    }
}
