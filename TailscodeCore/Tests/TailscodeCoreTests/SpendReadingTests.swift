import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

/// A per-turn account is a fact about the conversation, not about the device that ran it.
@Suite("What a device believes a conversation cost")
struct SpendReadingTests {
    private static let start = Date(timeIntervalSince1970: 1_780_000_000)

    private static func report(_ cost: Double) -> SessionSpendReport {
        let turn = SessionSpendReport.Turn(
            at: start, seconds: 30, model: "claude-opus-5", calls: 1,
            tokens: SessionSpendReport.Tokens(output: 1000), costUSD: cost, prompt: "ship it")
        return SessionSpendReport(
            costUSD: cost, tokens: SessionSpendReport.Tokens(output: 1000), turns: [turn],
            byModel: [], startedAt: start, endedAt: start)
    }

    private static func priced(_ cost: Double) -> [ChatMessage] {
        [
            ChatMessage(
                id: "u1", role: .user, agentType: .openCode,
                parts: [MessagePart(id: "p", kind: .text("ship it"))], createdAt: start),
            ChatMessage(
                id: "a1", role: .assistant, agentType: .openCode, parts: [], createdAt: start,
                completedAt: start.addingTimeInterval(30), costUSD: cost, totalTokens: 1000),
        ]
    }

    @Test("A poll that came back with nothing is not news that the money is gone")
    func aFailedPollLeavesTheReadingAlone() {
        var reading = SpendReading()
        reading.note(report: Self.report(5), for: "chat")
        let changed = reading.note(report: nil, for: "chat")

        #expect(!changed)
        #expect(reading.value?.costUSD == 5)
    }

    @Test("A transcript that arrives after the panel opened still produces the chart")
    func aTranscriptArrivingLaterIsRead() {
        var reading = SpendReading()
        reading.note(report: nil, for: "chat")
        let empty = reading.note(messages: [], for: "chat")
        #expect(!empty)
        #expect(reading.value == nil)

        let arrived = reading.note(messages: Self.priced(0.25), for: "chat")
        #expect(arrived)
        #expect(reading.value?.turns.count == 1)
    }

    @Test("The server's own account outranks anything this device worked out")
    func aReportOutranksADerivation() {
        var reading = SpendReading()
        reading.note(messages: Self.priced(0.25), for: "chat")
        reading.note(report: Self.report(5), for: "chat")

        #expect(reading.value?.costUSD == 5)
    }

    @Test("An unchanged transcript is not recomputed on every state emission")
    func anUnchangedTranscriptCostsNothing() {
        var reading = SpendReading()
        let first = reading.note(messages: Self.priced(0.25), for: "chat")
        let again = reading.note(messages: Self.priced(0.25), for: "chat")
        #expect(first)
        #expect(!again)
    }

    /// Panes are reused across chats, and one chat's money under another's name is worse than the
    /// silence it replaced.
    @Test("A reading belongs to one conversation")
    func anotherConversationStartsFromNothing() {
        var reading = SpendReading()
        reading.note(report: Self.report(5), for: "chat")
        reading.note(report: nil, for: "other")

        #expect(reading.value == nil)
    }
}
