import Foundation
import Testing
@testable import TailscodeCore

@Suite("Safe restore")
struct TileSafeRestoreTests {
    private static func scratch() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ledger-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("launch.json")
    }

    @Test("The decision table over clean, unclean, pane count and a repeat", arguments: [
        (nil as Bool?, 5, false, RestorePlan.Mode.staggered, false, nil as ShedLevel?),
        (true, 5, false, .staggered, false, nil),
        (true, 5, true, .staggered, false, nil),
        (false, 1, false, .staggered, true, nil),
        (false, 2, false, .staggered, true, nil),
        (false, 3, false, .parked(bannerCount: 3), true, nil),
        (false, 5, false, .parked(bannerCount: 5), true, nil),
        (false, 2, true, .staggered, true, .loaded),
        (false, 5, true, .parked(bannerCount: 5), true, .loaded),
        (false, 0, true, .staggered, true, .loaded),
    ])
    func table(
        clean: Bool?, panes: Int, previousUnclean: Bool, mode: RestorePlan.Mode, unclean: Bool,
        floor: ShedLevel?
    ) {
        let ledger = clean.map { LaunchLedger(cleanExit: $0, panes: panes) }
        let plan = RestorePlan.decide(ledger: ledger, paneCount: panes, previousUnclean: previousUnclean)
        #expect(plan.mode == mode)
        #expect(plan.unclean == unclean)
        #expect(plan.floor == floor)
        #expect(plan.floorDuration == (floor == nil ? 0 : 600))
    }

    @Test("A parked restore carries the banner sentence; a staggered one none")
    func banner() {
        let parked = RestorePlan.decide(ledger: LaunchLedger(cleanExit: false), paneCount: 5)
        #expect(parked.bannerText == "Tailscode didn't close normally last time. 5 chats are paused.")
        #expect(RestorePlan.decide(ledger: nil, paneCount: 5).bannerText == nil)
    }

    @Test("Panes wake focused first, then most recently focused, 300 ms apart, each once")
    func wakeSchedule() {
        let a = PaneID(raw: "a")
        let b = PaneID(raw: "b")
        let c = PaneID(raw: "c")
        let schedule = RestorePlan.wakeSchedule(focused: b, recent: [c, b, a, c])
        #expect(schedule.map(\.pane) == [b, c, a])
        #expect(schedule.map(\.at) == [0, 0.3, 0.6])
        #expect(RestorePlan.wakeSchedule(focused: nil, recent: []).isEmpty)
        #expect(RestorePlan.wakeSchedule(focused: a, recent: []).map(\.at) == [0])
    }

    @Test("A launch reads the last ledger, writes itself unclean, and a clean exit flips it")
    func ledgerLifecycle() throws {
        let url = Self.scratch()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(LaunchLedger.read(url: url) == nil)
        let first = LaunchLedger.begin(url: url, panes: 4, level: 0)
        #expect(first.previous == nil)
        #expect(LaunchLedger.read(url: url)?.cleanExit == false)
        LaunchLedger.markClean(url: url, launchID: first.current.launchID, panes: 5, level: 1)
        let closed = try #require(LaunchLedger.read(url: url))
        #expect(closed.cleanExit)
        #expect(closed.panes == 5)
        #expect(closed.level == 1)

        let second = LaunchLedger.begin(url: url, panes: 5)
        #expect(second.previous?.cleanExit == true)
        #expect(!second.current.previousUnclean)
        #expect(RestorePlan.decide(ledger: second.previous, paneCount: 5).mode == .staggered)

        let third = LaunchLedger.begin(url: url, panes: 5)
        #expect(third.previous?.cleanExit == false)
        #expect(third.current.previousUnclean)
        let once = RestorePlan.decide(ledger: third.previous, paneCount: 5)
        #expect(once.mode == .parked(bannerCount: 5))
        #expect(once.floor == nil)

        let fourth = LaunchLedger.begin(url: url, panes: 5)
        let twice = RestorePlan.decide(ledger: fourth.previous, paneCount: 5)
        #expect(twice.floor == .loaded)
        LaunchLedger.markClean(url: url, launchID: "someone else")
        #expect(LaunchLedger.read(url: url)?.cleanExit == false)
    }

    @Test("A ledger round-trips, tolerates missing fields and a corrupt file reads as none")
    func ledgerCoding() throws {
        let url = Self.scratch()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let ledger = LaunchLedger(launchID: "x", startedAt: Date(timeIntervalSince1970: 1_759_700_000), cleanExit: true, panes: 3, level: 2, previousUnclean: true)
        try ledger.write(url: url)
        #expect(LaunchLedger.read(url: url) == ledger)
        try Data(#"{"launchID":"y","startedAt":1759700000000,"cleanExit":false}"#.utf8).write(to: url)
        #expect(LaunchLedger.read(url: url) == LaunchLedger(launchID: "y", startedAt: Date(timeIntervalSince1970: 1_759_700_000), cleanExit: false))
        try Data("not json".utf8).write(to: url)
        #expect(LaunchLedger.read(url: url) == nil)
        #expect(LaunchLedger.defaultURL(environment: ["XDG_STATE_HOME": "/s"]).lastPathComponent == "launch.json")
    }
}
