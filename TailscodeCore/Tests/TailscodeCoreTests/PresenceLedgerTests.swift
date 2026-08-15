import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

/// Handing a chat from the background watcher to the pane that just opened it replaces one witness
/// with another, and the new one starts knowing nothing. What must not happen in that gap is a row
/// settling: LIVE NOW, RECENT, LIVE NOW again is the app claiming a turn ended and then unclaiming
/// it, inside one round trip.
@Suite struct PresenceLedgerTests {
    private let key = "server/chat"

    @Test func aWatcherWithNothingToSayYetLeavesTheMemoryStanding() {
        var ledger = PresenceLedger()
        ledger.absorb([key: .running(nil)])
        ledger.absorb([:])

        #expect(ledger.presence(for: key) == .running(nil))
    }

    @Test func aWitnessThatHeardTheServerSettlesTheRow() {
        var ledger = PresenceLedger()
        ledger.absorb([key: .running(nil)])
        ledger.absorb([key: .unobserved])

        #expect(ledger.presence(for: key) == .unobserved)
    }

    /// A watcher that never arrives must not pin a row live all afternoon.
    @Test func aTurnRememberedOnSilenceAloneIsGivenUp() {
        let start = Date()
        var ledger = PresenceLedger()
        ledger.absorb([key: .running(nil)], at: start)
        ledger.absorb([:], at: start)

        #expect(ledger.presence(for: key, at: start.addingTimeInterval(5)) == .running(nil))
        #expect(
            ledger.presence(for: key, at: start.addingTimeInterval(PresenceLedger.patience + 1))
                == .unobserved)
    }

    /// A first fetch that failed on a blip knows less about the server than the watcher it
    /// replaced, not more.
    @Test func aFailureDoesNotEraseARememberedTurn() {
        var ledger = PresenceLedger()
        ledger.absorb([key: .running(nil)])
        ledger.absorb([key: .failed])

        #expect(ledger.presence(for: key) == .running(nil))
    }

    @Test func aFailureIsRememberedWhenNothingWasRunning() {
        var ledger = PresenceLedger()
        ledger.absorb([key: .failed])

        #expect(ledger.presence(for: key) == .failed)
    }

    @Test func aSettledReadingOutranksOneWithNothingToSay() {
        #expect(SessionPresence.unobserved.rank > SessionPresence.unsettled.rank)
        #expect(SessionPresence.running(nil).rank > SessionPresence.unobserved.rank)
        #expect(SessionPresence.awaitingApproval.rank > SessionPresence.running(nil).rank)
        #expect(!SessionPresence.unsettled.isInFlight)
    }

    @Test func aConversationNobodyHasToldAnythingReadsUnsettled() {
        #expect(
            SessionPresence.reading(ConversationState(status: .unknown), step: nil) == .unsettled)
        #expect(
            SessionPresence.reading(ConversationState(status: .idle), step: nil) == .unobserved)
    }
}
