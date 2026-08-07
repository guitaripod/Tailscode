import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("What a conversation cost")
struct SessionSpendTests {
    private static func tokens(
        input: Int = 0, output: Int = 0, cacheRead: Int = 0, write5m: Int = 0, write1h: Int = 0
    ) -> SessionSpendReport.Tokens {
        SessionSpendReport.Tokens(
            input: input, output: output, cacheRead: cacheRead, cacheWrite5m: write5m,
            cacheWrite1h: write1h)
    }

    private static func report(
        turns: [SessionSpendReport.Turn], byModel: [SessionSpendReport.ModelShare] = []
    ) -> SessionSpendReport {
        var total = SessionSpendReport.Tokens()
        for turn in turns {
            total.input += turn.tokens.input
            total.output += turn.tokens.output
            total.cacheRead += turn.tokens.cacheRead
            total.cacheWrite5m += turn.tokens.cacheWrite5m
            total.cacheWrite1h += turn.tokens.cacheWrite1h
        }
        return SessionSpendReport(
            costUSD: turns.reduce(0) { $0 + $1.costUSD }, tokens: total, turns: turns,
            byModel: byModel, startedAt: turns.first?.at, endedAt: turns.last?.at)
    }

    private static let start = Date(timeIntervalSince1970: 1_780_000_000)

    private static func turn(
        minute: Int, cost: Double, output: Int = 1000, prompt: String? = nil,
        model: String = "claude-opus-5", seconds: Double? = 30
    ) -> SessionSpendReport.Turn {
        SessionSpendReport.Turn(
            at: start.addingTimeInterval(Double(minute) * 60), seconds: seconds, model: model,
            calls: 2, tokens: tokens(output: output), costUSD: cost, prompt: prompt)
    }

    @Test("A turn's bar is its cost against the biggest one, so the tallest is always full")
    func barsAreRelativeToThePeak() {
        let spend = SessionSpend(
            report: Self.report(turns: [
                Self.turn(minute: 0, cost: 0.5), Self.turn(minute: 1, cost: 2),
                Self.turn(minute: 2, cost: 1),
            ]))

        #expect(spend.turns.map(\.share) == [0.25, 1, 0.5])
        #expect(spend.priciest?.costUSD == 2)
        #expect(spend.turnCount == 3)
        #expect(abs(spend.costUSD - 3.5) < 0.0001)
    }

    @Test("The money is spread across tiers by what each tier is worth, not by token count")
    func tiersAreWeightedNotCounted() {
        let spend = SessionSpend(
            report: Self.report(turns: [
                SessionSpendReport.Turn(
                    at: Self.start, seconds: 10, model: "claude-opus-5", calls: 1,
                    tokens: Self.tokens(output: 100_000, cacheRead: 10_000_000),
                    costUSD: 10)
            ]))

        let ids = spend.tiers.map(\.id)
        #expect(ids.contains("output"))
        #expect(ids.contains("cacheRead"))
        #expect(!ids.contains("input"), "a tier nobody used must not take a legend row")
        let shares = spend.tiers.reduce(0) { $0 + $1.share }
        #expect(abs(shares - 1) < 0.0001)
        let money = spend.tiers.reduce(0) { $0 + $1.costUSD }
        #expect(abs(money - spend.costUSD) < 0.0001)
        let output = spend.tiers.first { $0.id == "output" }
        let read = spend.tiers.first { $0.id == "cacheRead" }
        #expect(
            abs((read?.costUSD ?? 0) - (output?.costUSD ?? 0) * 2) < 0.0001,
            "a hundred thousand answer tokens and ten million cache reads price 1:2")
        #expect(spend.tiers.first?.id == "cacheRead", "the biggest slice leads the legend")
    }

    @Test("Every headline number is derived once, and a rate needs a real span to exist")
    func headlineFacts() {
        let hour = SessionSpend(
            report: Self.report(turns: [
                Self.turn(minute: 0, cost: 1), Self.turn(minute: 60, cost: 1),
            ]))
        #expect(hour.averageUSD == 1)
        #expect(hour.span == 3600)
        #expect(abs((hour.perHourUSD ?? 0) - 2) < 0.0001)

        let instant = SessionSpend(report: Self.report(turns: [Self.turn(minute: 0, cost: 1)]))
        #expect(instant.perHourUSD == nil, "a session with no span has no hourly rate")
        #expect(hour.headline.contains { $0.0 == Localized.text("Turns") && $0.1 == "2" })
    }

    @Test("The badge warns that an estimate is an estimate, and falls back to tokens")
    func badgeSaysWhatItIs() {
        let priced = SessionSpend(report: Self.report(turns: [Self.turn(minute: 0, cost: 4.2)]))
        #expect(priced.badge == "~$4.20")

        var free = Self.report(turns: [Self.turn(minute: 0, cost: 0, output: 12_345)])
        free.estimated = false
        #expect(SessionSpend(report: free).badge == "12.3k")
        #expect(SessionSpend.money(0.004) == "<$0.01")
        #expect(SessionSpend.money(0) == "$0")
        #expect(SessionSpend.money(123.4) == "$123")
    }

    @Test("A backend that prices its own messages needs no server route")
    func derivesFromTheTranscript() {
        let start = Self.start
        let messages = [
            ChatMessage(
                id: "u1", role: .user, agentType: .openCode,
                parts: [MessagePart(id: "t", kind: .text("port the renderer"))], createdAt: start),
            ChatMessage(
                id: "a1", role: .assistant, agentType: .openCode,
                parts: [MessagePart(id: "t", kind: .text("done"))], createdAt: start,
                completedAt: start.addingTimeInterval(12), costUSD: 0.4,
                modelID: "claude-sonnet-5", totalTokens: 900),
            ChatMessage(
                id: "u2", role: .user, agentType: .openCode,
                parts: [MessagePart(id: "t", kind: .text("now the tests"))],
                createdAt: start.addingTimeInterval(60)),
            ChatMessage(
                id: "a2", role: .assistant, agentType: .openCode,
                parts: [MessagePart(id: "t", kind: .text("done"))],
                createdAt: start.addingTimeInterval(60), costUSD: 0.1,
                modelID: "claude-sonnet-5", totalTokens: 100),
        ]

        let spend = try? #require(SessionSpend(messages: messages))
        #expect(spend?.turnCount == 2)
        #expect(abs((spend?.costUSD ?? 0) - 0.5) < 0.0001)
        #expect(spend?.estimated == false)
        #expect(spend?.badge == "$0.50")
        #expect(spend?.turns.first?.prompt == "port the renderer")
        #expect(spend?.turns.first?.seconds == 12)
        #expect(spend?.models.first?.label == "Sonnet")
        #expect(spend?.models.first?.turns == 2)
    }

    @Test("A transcript with no priced answer in it produces nothing to show")
    func nothingToShowIsNil() {
        #expect(SessionSpend(messages: []) == nil)
        let unpriced = [
            ChatMessage(
                id: "a", role: .assistant, agentType: .claudeCode, createdAt: Date())
        ]
        #expect(SessionSpend(messages: unpriced) == nil)
    }

    @Test("The band trades the last turn's price for the session's, and clicking opens it")
    func bandShowsTheSession() {
        var facts = StatusFacts()
        facts.lastCostUSD = 0.12
        #expect(facts.segments.first { $0.id == "cost" }?.text == "$0.12")

        facts.spend = SessionSpend(report: Self.report(turns: [Self.turn(minute: 0, cost: 4.2)]))
        let segment = facts.segments.first { $0.id == "cost" }
        #expect(segment?.text == "~$4.20")
        #expect(segment?.action == .spend)
    }
}
