import Foundation
import Testing
import TailscodeCore

@testable import Tailscode

/// The Pro week as the gates read it: what it opens, who may start it, what it lends and what rests after it.
@MainActor
struct ProWeekAccessTests {
    private final class Clock {
        var now = Date(timeIntervalSince1970: 1_800_000_000)
    }

    private let day: TimeInterval = 86_400

    private func access(clock: Clock, sellsPro: Bool = true, cachedPro: Bool = false) throws -> ProAccess {
        let defaults = try #require(UserDefaults(suiteName: "tailscode-week-tests-" + UUID().uuidString))
        defaults.set(cachedPro, forKey: "tailscode.isPro")
        return ProAccess(store: nil, sellsPro: sellsPro, defaults: defaults, now: { clock.now })
    }

    @Test func theWeekOpensEveryGateWithoutMakingTheCopyABuyer() throws {
        let clock = Clock()
        let access = try access(clock: clock)
        #expect(access.canStartProWeek)
        #expect(!access.hasProAccess)
        #expect(access.startProWeek(servers: 1))
        #expect(access.hasProAccess)
        #expect(!access.isPro)
        #expect(access.proWeekEndsAt == clock.now.addingTimeInterval(7 * day))
        #expect(!access.canStartProWeek)
        #expect(!access.startProWeek(servers: 1))
    }

    @Test func aBuyerAndACopyThatSellsNothingAreNeverOfferedAWeek() throws {
        let clock = Clock()
        #expect(!(try access(clock: clock, cachedPro: true)).canStartProWeek)
        #expect(!(try access(clock: clock, sellsPro: false)).canStartProWeek)
    }

    @Test func aServerAddedDuringTheWeekRestsAfterItAndTheOnesBeforeItStay() throws {
        let clock = Clock()
        let access = try access(clock: clock)
        access.startProWeek(servers: 1)
        access.noteServerAdded("laptop")
        #expect(access.restingServerIDs(saved: ["desktop", "laptop"]).isEmpty)

        clock.now = clock.now.addingTimeInterval(7 * day)
        access.refreshProWeek()
        #expect(!access.hasProAccess)
        #expect(access.isProWeekEndNoticeDue)
        #expect(access.restingServerIDs(saved: ["desktop", "laptop"]) == ["laptop"])

        access.keepServer("laptop", replacing: "desktop", connected: ["desktop"])
        #expect(access.restingServerIDs(saved: ["desktop", "laptop"]) == ["desktop"])

        access.forgetServer("laptop")
        #expect(access.restingServerIDs(saved: ["desktop"]).isEmpty)
    }

    @Test func aServerAddedOutsideTheWeekIsNeverLent() throws {
        let clock = Clock()
        let access = try access(clock: clock)
        access.noteServerAdded("desktop")
        access.startProWeek(servers: 1)
        clock.now = clock.now.addingTimeInterval(8 * day)
        access.refreshProWeek()
        access.noteServerAdded("late")
        #expect(access.restingServerIDs(saved: ["desktop", "late"]).isEmpty)
    }

    @Test func theEndNoteIsShownOnce() throws {
        let clock = Clock()
        let access = try access(clock: clock)
        access.startProWeek(servers: 1)
        clock.now = clock.now.addingTimeInterval(8 * day)
        access.refreshProWeek()
        #expect(access.isProWeekEndNoticeDue)
        access.markProWeekEndNoticeShown()
        #expect(!access.isProWeekEndNoticeDue)
    }
}
