import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite struct RenderPacerTests {
    @Test func theFirstDrawIsNeverMadeToWait() {
        var pacer = RenderPacer()
        #expect(pacer.offer(at: 10, isGrowth: true) == .now)
    }

    @Test func growthWaitsUntilDrawingIsAQuarterOfTheTime() {
        var pacer = RenderPacer()
        pacer.drew(from: 1.000, to: 1.010)
        guard case .after(let first) = pacer.offer(at: 1.010, isGrowth: true),
            case .after(let second) = pacer.offer(at: 1.020, isGrowth: true)
        else {
            Issue.record("growth right after a draw waits")
            return
        }
        #expect(abs(first - 0.030) < 1e-9)
        #expect(abs(second - 0.020) < 1e-9)
        #expect(pacer.offer(at: 1.041, isGrowth: true) == .now)
    }

    @Test func anythingButGrowthIsDrawnAtOnce() {
        var pacer = RenderPacer()
        pacer.drew(from: 1.000, to: 1.050)
        #expect(pacer.offer(at: 1.051, isGrowth: false) == .now)
    }

    @Test func aCheapDrawBarelyWaits() {
        var pacer = RenderPacer()
        pacer.drew(from: 1.000, to: 1.001)
        guard case .after(let wait) = pacer.offer(at: 1.001, isGrowth: true) else {
            Issue.record("a growth state right after a draw waits a moment")
            return
        }
        #expect(wait <= 0.0031)
    }

    @Test func theWaitIsCappedSoTheWordsNeverTrailFar() {
        var pacer = RenderPacer()
        pacer.drew(from: 1, to: 2)
        guard case .after(let wait) = pacer.offer(at: 2, isGrowth: true) else {
            Issue.record("growth right after a draw waits")
            return
        }
        #expect(abs(wait - RenderPacer.longestWait) < 1e-9)
    }

    @Test func oneCheapDrawBetweenExpensiveOnesDoesNotOpenTheThrottle() {
        var pacer = RenderPacer()
        pacer.drew(from: 1.00, to: 1.04)
        pacer.drew(from: 1.20, to: 1.201)
        #expect(pacer.cost > 0.03)
        for second in 2...12 { pacer.drew(from: Double(second), to: Double(second) + 0.001) }
        #expect(pacer.cost < 0.01)
    }

    private func message(
        _ id: String, _ role: MessageRole, _ words: [String], streaming: Bool = false
    ) -> ChatMessage {
        ChatMessage(
            id: id, role: role, agentType: .claudeCode,
            parts: words.enumerated().map { MessagePart(id: "p\($0.offset)", kind: .text($0.element)) },
            createdAt: Date(timeIntervalSince1970: 1_000), isStreaming: streaming)
    }

    private func state(_ messages: [ChatMessage], status: BackendStatus = .running)
        -> ConversationState
    {
        ConversationState(messages: messages, status: status, connection: .live)
    }

    @Test func longerWordsInTheLastMessageAreGrowth() {
        let old = state([message("u", .user, ["hi"]), message("a", .assistant, ["one"], streaming: true)])
        let new = state([
            message("u", .user, ["hi"]), message("a", .assistant, ["one two"], streaming: true),
        ])
        #expect(RenderPacer.isGrowth(from: old, to: new))
    }

    @Test func aNewMessageIsNotGrowth() {
        let old = state([message("u", .user, ["hi"])])
        let new = state([message("u", .user, ["hi"]), message("a", .assistant, ["one"], streaming: true)])
        #expect(!RenderPacer.isGrowth(from: old, to: new))
    }

    @Test func aNewPartIsNotGrowth() {
        let old = state([message("a", .assistant, ["one"], streaming: true)])
        let new = state([message("a", .assistant, ["one", "tool"], streaming: true)])
        #expect(!RenderPacer.isGrowth(from: old, to: new))
    }

    @Test func theTurnEndingIsNotGrowth() {
        let old = state([message("a", .assistant, ["one"], streaming: true)])
        let new = state([message("a", .assistant, ["one two"], streaming: false)], status: .idle)
        #expect(!RenderPacer.isGrowth(from: old, to: new))
    }

    @Test func aPhaseChangeIsNotGrowth() {
        let old = state([message("a", .assistant, ["one"], streaming: true)])
        var new = old
        new.connection = .reconnecting
        #expect(!RenderPacer.isGrowth(from: old, to: new))
    }

    @Test func anEmptyConversationIsNotGrowth() {
        #expect(!RenderPacer.isGrowth(from: state([]), to: state([])))
    }
}
