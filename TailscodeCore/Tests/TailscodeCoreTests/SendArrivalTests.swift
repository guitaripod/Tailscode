import Foundation
import Testing

@testable import TailscodeCore

/// A send that errored may still have arrived, and the transcript is the only witness. These hold
/// the comparison to the two ways it can go wrong: offering a message the server already has, and
/// retiring one it never saw because the same words were sent earlier.
@Suite("Send arrival")
struct SendArrivalTests {
    private let epoch = Date(timeIntervalSince1970: 1_760_000_000)

    @Test("Words written after the baseline are the send's own")
    func arrivesAfterBaseline() {
        #expect(
            SendArrival.arrived(
                "ship it", baselineUserCount: 1, userTexts: ["first", "ship it"]))
    }

    @Test("An earlier copy of the same words is not the send")
    func earlierCopyDoesNotCount() {
        #expect(
            !SendArrival.arrived(
                "continue", baselineUserCount: 1, userTexts: ["continue", "other"]))
        #expect(
            SendArrival.arrived(
                "continue", baselineUserCount: 1, userTexts: ["continue", "continue"]))
    }

    @Test("Whitespace around the words does not make them different words")
    func ignoresPadding() {
        #expect(
            SendArrival.arrived(
                "  lyrics are up to date \n", baselineUserCount: 0,
                userTexts: ["lyrics are up to date"]))
    }

    @Test("Empty words and an oversized baseline arrive nowhere")
    func degenerate() {
        #expect(!SendArrival.arrived("  ", baselineUserCount: 0, userTexts: ["", "  "]))
        #expect(!SendArrival.arrived("a", baselineUserCount: 9, userTexts: ["a"]))
        #expect(SendArrival.arrived("a", baselineUserCount: -3, userTexts: ["a"]))
    }

    @Test("A failed row whose words arrived is retired and its neighbours stay")
    func retiresOnlyArrivedFailures() {
        var ledger = PendingSendLedger()
        let arrived = ledger.begin(text: "ship it", userMessages: 1, now: epoch)
        let missing = ledger.begin(text: "never reached", userMessages: 1, now: epoch)
        let inFlight = ledger.begin(text: "ship it", userMessages: 1, now: epoch)
        _ = ledger.mark(id: arrived.id, .failed(reason: "offline"))
        _ = ledger.mark(id: missing.id, .failed(reason: "offline"))

        let retired = ledger.retireArrived(userTexts: ["first", "ship it"])

        #expect(retired.map(\.id) == [arrived.id])
        #expect(ledger.send(id: missing.id) != nil)
        #expect(ledger.send(id: inFlight.id) != nil)
        #expect(ledger.count == 2)
    }
}
