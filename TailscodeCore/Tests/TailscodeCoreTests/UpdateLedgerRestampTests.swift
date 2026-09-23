import Foundation
import Testing

@testable import TailscodeCore

/// A machine being followed answers the same thing every few seconds with a new time on it. Those
/// answers must not count as news: each one used to rewrite the ledger, wake every update surface,
/// and on the desktop that keeps its settings in a file, rewrite the whole file.
@Suite struct UpdateLedgerRestampTests {
    private let now = Date(timeIntervalSince1970: 1_790_000_000)

    private func reading(
        checkedAt: Date, installed: String = "1.10.1", available: String = "1.11.0",
        holding: String? = nil, nextLook: Date? = nil
    ) -> UpdateReading {
        UpdateReading(
            component: .server(profileID: "arch"), title: "Claude Code",
            installed: VersionFact(text: installed, provenance: .serverBuild, readAt: checkedAt),
            available: VersionFact(text: available, provenance: .gitHubRelease, readAt: checkedAt),
            verdict: .blocked("3 turns are running on that machine."), checkedAt: checkedAt,
            automation: UpdateAutomation(
                enabled: true, nextLookAt: nextLook, holdingOff: holding, readAt: checkedAt))
    }

    @Test func theSameAnswerReadAgainSoonIsNotRecorded() {
        let before = [reading(checkedAt: now)]
        let after = [
            reading(checkedAt: now.addingTimeInterval(10), nextLook: now.addingTimeInterval(1800))
        ]
        #expect(!UpdateLedger.worthRecording(after, over: before, now: now.addingTimeInterval(10)))
    }

    @Test func theTimesStillReachTheLedgerEveryFewMinutes() {
        let before = [reading(checkedAt: now)]
        let later = now.addingTimeInterval(UpdateLedger.restampAfter + 1)
        #expect(UpdateLedger.worthRecording([reading(checkedAt: later)], over: before, now: later))
    }

    @Test func anythingElseThatMovedIsRecordedAtOnce() {
        let before = [reading(checkedAt: now)]
        let soon = now.addingTimeInterval(10)
        #expect(
            UpdateLedger.worthRecording(
                [reading(checkedAt: soon, installed: "1.11.0")], over: before, now: soon))
        #expect(
            UpdateLedger.worthRecording(
                [reading(checkedAt: soon, holding: "waiting for a turn")], over: before, now: soon))
        #expect(UpdateLedger.worthRecording([], over: before, now: soon))
    }

    /// A clock that ran backwards makes every stored time look like the future; that is no reason
    /// to trust the stored one.
    @Test func aStampFromTheFutureIsReplaced() {
        let before = [reading(checkedAt: now.addingTimeInterval(3600))]
        #expect(UpdateLedger.worthRecording([reading(checkedAt: now)], over: before, now: now))
    }

    @Test func theOrderTheRowsAreKeptInIsNotNews() {
        let arch = reading(checkedAt: now)
        let mac = UpdateReading(
            component: .server(profileID: "mac"), title: "Claude Code",
            installed: VersionFact(text: "1.10.1", provenance: .serverBuild),
            verdict: .blocked("idle"), checkedAt: now)
        #expect(!UpdateLedger.worthRecording([mac, arch], over: [arch, mac], now: now))
    }
}
