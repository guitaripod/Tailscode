import Foundation
import Testing
@testable import TailscodeCore

@Suite("Chat open read")
struct ChatOpenReadTests {
    private let now: TimeInterval = 1_800_000_000

    @Test func aChatWithNothingLoadedHasNothingToAskAbout() {
        #expect(!ChatOpenRead.needed(hasTranscript: false, changedAt: nil, lastAsked: nil, now: now))
        #expect(
            !ChatOpenRead.needed(
                hasTranscript: false, changedAt: now - 60, lastAsked: nil, now: now))
    }

    @Test func aHeldTranscriptThatNeverMovedIsAskedAgain() {
        #expect(ChatOpenRead.needed(hasTranscript: true, changedAt: nil, lastAsked: nil, now: now))
    }

    @Test func whatMovedAMomentAgoIsCurrent() {
        #expect(
            !ChatOpenRead.needed(
                hasTranscript: true, changedAt: now - 2, lastAsked: nil, now: now))
    }

    @Test func whatHasBeenStillLongerThanTheFreshnessIsAskedAgain() {
        #expect(
            ChatOpenRead.needed(hasTranscript: true, changedAt: now - 4, lastAsked: nil, now: now))
    }

    @Test func aChatJustAskedIsNotAskedTwice() {
        #expect(
            !ChatOpenRead.needed(
                hasTranscript: true, changedAt: now - 60, lastAsked: now - 1, now: now))
    }

    @Test func aChatAskedBeforeTheFreshnessIsAskedAgain() {
        #expect(
            ChatOpenRead.needed(
                hasTranscript: true, changedAt: now - 60, lastAsked: now - 4, now: now))
    }

    @Test func aStampFromEarlierThanTheClockReadsAsCurrent() {
        #expect(
            !ChatOpenRead.needed(
                hasTranscript: true, changedAt: now + 30, lastAsked: nil, now: now))
    }
}
