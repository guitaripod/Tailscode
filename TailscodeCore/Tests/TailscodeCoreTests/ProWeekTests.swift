import Foundation
import Testing

@testable import TailscodeCore

@Suite("Pro week")
struct ProWeekTests {
    private let start = Date(timeIntervalSince1970: 1_800_000_000)
    private let day: TimeInterval = 86_400

    @Test("The week runs seven days from its start, and a clock wound back reads as its first moment")
    func calendar() {
        #expect(ProWeek.phase(start: nil, now: start) == .notStarted)
        #expect(ProWeek.phase(start: start, now: start) == .active(endsAt: start.addingTimeInterval(7 * day)))
        #expect(ProWeek.phase(start: start, now: start.addingTimeInterval(7 * day - 1)).isActive)
        #expect(ProWeek.phase(start: start, now: start.addingTimeInterval(7 * day)) == .ended(at: start.addingTimeInterval(7 * day)))
        #expect(ProWeek.phase(start: start, now: start.addingTimeInterval(-2 * day)).isActive)
    }

    @Test("A part day counts as a day, and the last day says so")
    func daysLeft() {
        let end = start.addingTimeInterval(7 * day)
        #expect(ProWeek.daysLeft(until: end, now: start) == 7)
        #expect(ProWeek.daysLeft(until: end, now: end.addingTimeInterval(-60)) == 1)
        #expect(ProWeek.daysLeftText(until: end, now: start) == "Pro week · 7 days left")
        #expect(ProWeek.daysLeftText(until: end, now: end.addingTimeInterval(-60)) == "Pro week · last day")
    }

    @Test("The note after the week names what stays and what rests, or what went back when nothing rests")
    func endNote() {
        #expect(ProWeek.endedBody(kept: ["mac"], resting: ["box"]).contains("mac"))
        #expect(ProWeek.endedBody(kept: ["mac"], resting: ["box"]).contains("box"))
        #expect(ProWeek.endedBody(kept: ["mac"], resting: []).contains("Delegate"))
    }
}

@Suite("Server allowance")
struct ServerAllowanceTests {
    private let ended = ProWeek.Phase.ended(at: Date(timeIntervalSince1970: 0))
    private let running = ProWeek.Phase.active(endsAt: Date(timeIntervalSince1970: 0))

    @Test("Nothing rests while the week runs, before it, for a buyer, or when the week lent nothing")
    func nothingRests() {
        let saved = ["a", "b", "c"]
        #expect(ServerAllowance.resting(saved: saved, lent: ["b"], picks: [], keeps: 1, isPro: false, phase: running).isEmpty)
        #expect(ServerAllowance.resting(saved: saved, lent: ["b"], picks: [], keeps: 1, isPro: false, phase: .notStarted).isEmpty)
        #expect(ServerAllowance.resting(saved: saved, lent: ["b"], picks: [], keeps: 1, isPro: true, phase: ended).isEmpty)
        #expect(ServerAllowance.resting(saved: saved, lent: [], picks: [], keeps: 1, isPro: false, phase: ended).isEmpty)
        #expect(ServerAllowance.resting(saved: saved, lent: ["gone"], picks: [], keeps: 1, isPro: false, phase: ended).isEmpty)
    }

    @Test("After the week the servers that were there stay and the lent ones rest")
    func lentServersRest() {
        #expect(ServerAllowance.resting(saved: ["a", "b", "c"], lent: ["b", "c"], picks: [], keeps: 1, isPro: false, phase: ended) == ["b", "c"])
        #expect(ServerAllowance.resting(saved: ["a", "b", "c"], lent: ["c"], picks: [], keeps: 2, isPro: false, phase: ended) == ["c"])
    }

    @Test("Servers configured before the week never rest, even past the free limit")
    func neverTakesWhatWasThere() {
        #expect(ServerAllowance.resting(saved: ["a", "b", "c"], lent: ["c"], picks: [], keeps: 2, isPro: false, phase: ended) == ["c"])
    }

    @Test("A pick keeps a lent server connected in place of the one it replaces")
    func picks() {
        let connected = ["a"]
        let picks = ServerAllowance.keep("b", replacing: "a", connected: connected)
        #expect(picks == ["b"])
        #expect(ServerAllowance.resting(saved: ["a", "b"], lent: ["b"], picks: picks, keeps: 1, isPro: false, phase: ended) == ["a"])
    }

    @Test("With two kept, a pick sends exactly the replaced server to rest")
    func pickReplacesTheNamedOne() {
        let picks = ServerAllowance.keep("c", replacing: "a", connected: ["a", "b"])
        #expect(ServerAllowance.resting(saved: ["a", "b", "c"], lent: ["c"], picks: picks, keeps: 2, isPro: false, phase: ended) == ["a"])
    }

    @Test("Deleting the connected server wakes the next one")
    func deletionWakes() {
        #expect(ServerAllowance.resting(saved: ["b", "c"], lent: ["b", "c"], picks: ["a"], keeps: 1, isPro: false, phase: ended) == ["c"])
    }

    @Test("The free copy keeps at least one server")
    func keepsAtLeastOne() {
        #expect(ServerAllowance.resting(saved: ["b"], lent: ["b"], picks: [], keeps: 0, isPro: false, phase: ended).isEmpty)
    }
}

@Suite("Resting servers file")
struct RestingServersFileTests {
    @Test("The set round-trips and an empty set removes the file")
    func roundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(RestingServersFile.read(in: directory).isEmpty)
        RestingServersFile.write(["b", "a"], in: directory)
        #expect(RestingServersFile.read(in: directory) == ["a", "b"])
        RestingServersFile.write([], in: directory)
        #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent(RestingServersFile.name).path))
    }
}
