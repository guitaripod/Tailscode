import Foundation
import Testing

@testable import TailscodeCore

@Suite("Model speed ledger")
struct ModelSpeedLedgerTests {
    private func fresh() -> ModelSpeedLedger {
        let suite = "ledger-test-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return ModelSpeedLedger(defaults: defaults)
    }

    @Test("The ledger stays quiet until it has a quorum of turns")
    func quorum() {
        let ledger = fresh()
        ledger.record(turnID: "t1", model: "opus", tokens: 100, seconds: 10)
        ledger.record(turnID: "t2", model: "opus", tokens: 100, seconds: 10)
        #expect(ledger.reading(model: "opus") == nil)
        ledger.record(turnID: "t3", model: "opus", tokens: 400, seconds: 20)
        let reading = ledger.reading(model: "opus")
        #expect(reading?.turns == 3)
        #expect(reading?.tokensPerSecond == 15, "600 tokens over 40 seconds")
    }

    @Test("A turn feeds the ledger once, however often the strip is rebuilt")
    func idempotentPerTurn() {
        let ledger = fresh()
        for _ in 0..<5 {
            ledger.record(turnID: "t1", model: "opus", tokens: 100, seconds: 10)
        }
        ledger.record(turnID: "t2", model: "opus", tokens: 100, seconds: 10)
        ledger.record(turnID: "t3", model: "opus", tokens: 100, seconds: 10)
        #expect(ledger.reading(model: "opus")?.turns == 3)
    }

    @Test("A full ledger halves before it takes more, so old speeds age out")
    func decay() {
        let ledger = fresh()
        for index in 0..<ModelSpeedLedger.decayThreshold {
            ledger.record(turnID: "t\(index)", model: "opus", tokens: 100, seconds: 10)
        }
        #expect(ledger.reading(model: "opus")?.turns == ModelSpeedLedger.decayThreshold)
        ledger.record(turnID: "fresh", model: "opus", tokens: 4000, seconds: 10)
        let reading = ledger.reading(model: "opus")
        #expect(reading?.turns == ModelSpeedLedger.decayThreshold / 2 + 1)
        #expect((reading?.tokensPerSecond ?? 0) > 10, "the fast new turn outweighs halved history")
    }

    @Test("Nothing without a model, tokens, or clock is remembered")
    func refusesJunk() {
        let ledger = fresh()
        ledger.record(turnID: "t1", model: "", tokens: 100, seconds: 10)
        ledger.record(turnID: "t2", model: "opus", tokens: 0, seconds: 10)
        ledger.record(turnID: "t3", model: "opus", tokens: 100, seconds: 0)
        #expect(ledger.reading(model: "opus") == nil)
        #expect(ledger.sentence(model: nil) == nil)
    }
}
