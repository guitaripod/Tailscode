import AgentTestSupport
import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite("Quiet at the desk: the rules, the computer's reports and the phone's look")
struct DeskBeatTests {
    private static func desk(_ id: String, idle: Int?, locked: Bool = false) -> DeskPresence.Desk {
        DeskPresence.Desk(desk: id, name: id, idle: idle, locked: locked, heard: 2)
    }

    @Test("A phone is quiet at the desk by default, with two minutes of patience, and says so to a bridge")
    func defaults() {
        let rules = NoticeRulesKeys.read { _ in nil }
        #expect(rules.quietAtDesk)
        #expect(rules.awayAfter == 120)
        let wire = rules.wire()
        #expect(wire.quietAtDesk == true)
        #expect(wire.awayAfter == 120)
    }

    @Test("The desk choices and muted names round-trip, and a name outlives nothing it labels")
    func storage() {
        var store: [String: Any] = [:]
        let rules = NoticeRules(
            muted: ["a", "b"], mutedNames: ["a": "Fix the queue", "gone": "Old"],
            quietAtDesk: false, awayAfter: 300)
        NoticeRulesKeys.write(rules) { store[$0] = $1 }
        #expect(store[NoticeRulesKeys.mutedNames] as? [String: String] == ["a": "Fix the queue"])
        let read = NoticeRulesKeys.read { store[$0] }
        #expect(read.quietAtDesk == false)
        #expect(read.awayAfter == 300)
        #expect(read.mutedNames == ["a": "Fix the queue"])
        store[NoticeRulesKeys.awayAfter] = 5
        #expect(NoticeRulesKeys.read { store[$0] }.awayAfter == 30, "a patience too short to mean anything is floored")
    }

    @Test("Muting keeps the chat's name until it is unmuted; the list reads by name")
    func mutedNames() {
        let rules = NoticeRules()
            .togglingMute("z", name: "  Zebra  ")
            .togglingMute("a", name: "apple")
            .togglingMute("n")
        #expect(rules.mutedNames == ["z": "Zebra", "a": "apple"])
        #expect(rules.mutedChats.map(\.id) == ["a", "z", "n"])
        let unmuted = rules.togglingMute("z")
        #expect(!unmuted.isMuted("z"))
        #expect(unmuted.mutedNames["z"] == nil)
        #expect(rules.unmuting("a").mutedChats.map(\.id) == ["z", "n"])
    }

    @Test("The summary reads the choices in the page's order")
    func summary() {
        let rules = NoticeRules(finish: .settled, minimumWork: 120, muted: ["a"])
        let line = NoticeRulesWords.summary(rules, desk: true)
        #expect(line.hasPrefix("Finished work over 2 minutes · Approvals and questions"))
        #expect(line.contains("Quiet at your computer"))
        #expect(line.hasSuffix("1 chat muted"))
        #expect(!NoticeRulesWords.summary(rules, desk: false).contains("computer"))
        #expect(NoticeRulesWords.summary(NoticeRules(finish: .never, needsYou: false), desk: true) == "Nothing notifies you")
    }

    @Test("A phone's status line names the desk the person is at, or why it cannot tell")
    func status() {
        #expect(NoticeRulesWords.deskStatus(nil, awayAfter: 120, quiet: true).contains("claude-bridge"))
        let here = DeskPresence(desks: [Self.desk("arch", idle: 4)])
        #expect(NoticeRulesWords.deskStatus(here, awayAfter: 120, quiet: true) == "You’re at arch now, so this device is quiet")
        let locked = DeskPresence(desks: [Self.desk("arch", idle: 4, locked: true)])
        #expect(NoticeRulesWords.deskStatus(locked, awayAfter: 120, quiet: true) == "arch is locked, so you’re away")
        let idle = DeskPresence(desks: [Self.desk("arch", idle: 400)])
        #expect(NoticeRulesWords.deskStatus(idle, awayAfter: 120, quiet: true) == "Away from arch")
        #expect(NoticeRulesWords.deskStatus(DeskPresence(), awayAfter: 120, quiet: true).hasPrefix("No computer"))
    }

    private static func beat(
        servers: [DeskServer], reading: DeskReading = DeskReading(idle: 3), enabled: Bool = true
    ) -> DeskBeat {
        DeskBeat(
            desk: "desk-1", name: "arch", enabled: enabled, interval: 3600,
            sense: { reading }, servers: { servers })
    }

    @Test("A report reaches every server that keeps desks, carries the looks once, and a server without desks rests")
    func reports() async {
        let keeper = MockBackend(deskPresence: DeskPresence())
        let older = MockBackend()
        let beat = Self.beat(servers: [
            DeskServer(key: "keeper", backend: keeper), DeskServer(key: "older", backend: older),
        ])
        await beat.look("s1")
        await beat.report(now: Date(timeIntervalSince1970: 1_000))
        var status = await beat.status
        #expect(status.asked == 2)
        #expect(status.heard == 1)
        #expect(keeper.reportedDesks.map(\.looked) == [["s1"]])
        #expect(keeper.reportedDesks.first?.lookedAgo?["s1"].map { $0 >= 0 } == true, "each look says when it was")
        #expect(keeper.reportedDesks.first?.idle == 3)
        #expect(keeper.reportedDesks.first?.name == "arch")
        await beat.report(now: Date(timeIntervalSince1970: 1_030))
        status = await beat.status
        #expect(status.asked == 1, "the server without desks is not asked again at once")
        #expect(keeper.reportedDesks.last?.looked == [])
        await beat.report(now: Date(timeIntervalSince1970: 1_000 + DeskBeat.refusalPause))
        #expect(await beat.status.asked == 2, "and is asked again once the pause is over")
    }

    @Test("Turning reporting off says this desk is leaving; off, nothing is reported or looked at")
    func switching() async {
        let keeper = MockBackend(deskPresence: DeskPresence())
        let beat = Self.beat(servers: [DeskServer(key: "keeper", backend: keeper)])
        await beat.report()
        await beat.setEnabled(false)
        #expect(keeper.reportedDesks.last?.leaving == true)
        let count = keeper.reportedDesks.count
        await beat.look("s1")
        await beat.report()
        await beat.poke()
        #expect(keeper.reportedDesks.count == count)
        #expect(await beat.status == DeskBeat.Status(enabled: false))
    }

    @Test("A desktop that cannot measure input reports no idle, which no phone reads as presence")
    func blind() async {
        let keeper = MockBackend(deskPresence: DeskPresence())
        let beat = Self.beat(
            servers: [DeskServer(key: "keeper", backend: keeper)], reading: DeskReading(idle: nil))
        await beat.report()
        #expect(keeper.reportedDesks.first?.idle == nil)
        #expect(NoticeRulesWords.deskReportStatus(await beat.status).contains("doesn’t say"))
    }

    @Test("A phone merges what every server knows and keeps one it can wait on")
    func lookout() async throws {
        let first = MockBackend(deskPresence: DeskPresence(desks: [Self.desk("arch", idle: 3)]))
        let second = MockBackend(
            deskPresence: DeskPresence(desks: [Self.desk("mac", idle: 900)], looked: ["s": Date()]))
        let none = MockBackend()
        let answer = try #require(
            await DeskLookout.ask([
                DeskServer(key: "a-none", backend: none), DeskServer(key: "b-first", backend: first),
                DeskServer(key: "c-second", backend: second),
            ]))
        #expect(answer.presence.desks.map(\.desk) == ["arch", "mac"])
        #expect(answer.presence.occupied(awayAfter: 120)?.desk == "arch")
        #expect(answer.waiter?.key == "b-first", "the wait is held on a server that keeps desks")
        #expect(await DeskLookout.ask([DeskServer(key: "none", backend: none)]) == nil)
    }

    @Test("A computer's own words follow its reports")
    func deskWords() {
        #expect(NoticeRulesWords.deskReportStatus(DeskBeat.Status(enabled: false)).hasPrefix("Off"))
        let telling = DeskBeat.Status(
            enabled: true, reading: DeskReading(idle: 2), heard: 2, asked: 3, reportedAt: Date())
        #expect(NoticeRulesWords.deskReportStatus(telling) == "Telling 2 machines you’re here")
        let nobody = DeskBeat.Status(
            enabled: true, reading: DeskReading(idle: 2), heard: 0, asked: 2, refused: 2)
        #expect(NoticeRulesWords.deskReportStatus(nobody).contains("Update"))
        let unreachable = DeskBeat.Status(
            enabled: true, reading: DeskReading(idle: 2), heard: 0, asked: 2, refused: 1)
        #expect(NoticeRulesWords.deskReportStatus(unreachable).hasPrefix("Can’t reach"))
    }

    @Test("A look that reached no server is kept for the next report, and a quit still reaches a server that went quiet")
    func keptLooks() async {
        let gone = MockBackend()
        let keeper = MockBackend(deskPresence: DeskPresence())
        var servers = [DeskServer(key: "keeper", backend: keeper)]
        let box = ServersBox(servers)
        let beat = DeskBeat(
            desk: "d", name: "n", enabled: true, interval: 3600, sense: { DeskReading(idle: 1) },
            servers: { box.value })
        await beat.report()
        servers = [DeskServer(key: "gone", backend: gone)]
        box.value = servers
        await beat.look("kept")
        await beat.report(now: Date().addingTimeInterval(1))
        box.value = [DeskServer(key: "keeper", backend: keeper)]
        await beat.report(now: Date().addingTimeInterval(2))
        #expect(keeper.reportedDesks.last?.looked == ["kept"], "the look waited for a server that took it")
        await beat.leave()
        #expect(keeper.reportedDesks.last?.leaving == true)
    }

    @Test("A computer keeps one id once made, and reports by default")
    func identity() {
        var store: [String: Any] = [:]
        let made = DeskKeys.id({ store[$0] }, { store[$0] = $1 })
        #expect(!made.isEmpty)
        #expect(DeskKeys.id({ store[$0] }, { store[$0] = $1 }) == made)
        #expect(DeskKeys.reports { store[$0] })
        store[DeskKeys.reports] = false
        #expect(!DeskKeys.reports { store[$0] })
    }
}

private final class ServersBox: @unchecked Sendable {
    private let lock = NSLock()
    private var held: [DeskServer]
    init(_ servers: [DeskServer]) { held = servers }
    var value: [DeskServer] {
        get { lock.withLock { held } }
        set { lock.withLock { held = newValue } }
    }
}
