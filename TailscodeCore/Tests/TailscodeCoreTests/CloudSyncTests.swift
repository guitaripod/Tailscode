import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@MainActor
private final class Phone: CloudDevice {
    var knownServers: [CloudServer]
    var seen: [String: CloudSeen] = [:]
    var saved: [SavedChat] = []
    var pins: [String] = []
    var archive: Set<String> = []
    let sync: CloudSync
    var clock: Double

    init(
        servers: [CloudServer], cloud: InMemoryCloudStore, startingAt clock: Double
    ) {
        knownServers = servers
        self.clock = clock
        let suite = UserDefaults(suiteName: "cloud-test-\(UUID().uuidString)")!
        let tick = ClockBox(clock)
        box = tick
        sync = CloudSync(
            store: cloud, stateStore: MemoryCloudSyncStateStore(), defaults: suite,
            now: { Date(timeIntervalSince1970: tick.value) })
        sync.attach(self)
    }

    private let box: ClockBox

    func advance(to time: Double) {
        clock = time
        box.value = time
    }

    func settle() { sync.pass() }

    func servers() -> [CloudServer] { knownServers }
    func seenMarks() -> [String: CloudSeen] { seen }
    func savedChats() -> [SavedChat] { saved }
    func pinnedKeys() -> [String] { pins }
    func archivedKeys() -> Set<String> { archive }
    func adoptSeen(_ marks: [String: CloudSeen]) { for (id, mark) in marks { seen[id] = mark } }

    func adoptSaved(add: [SavedChat], remove: [(profileID: String, sessionID: String)]) {
        for chat in add where !saved.contains(chat) { saved.append(chat) }
        for gone in remove {
            saved.removeAll { $0.profileID == gone.profileID && $0.sessionID == gone.sessionID }
        }
    }

    func adoptPins(order: [String]) { pins = order }

    func adoptArchived(add: Set<String>, remove: Set<String>) {
        archive = archive.union(add).subtracting(remove)
    }

    func markSeen(_ id: String, value: Double) {
        seen[id] = CloudSeen(value: value, decidedAt: clock)
    }

    func save(_ session: String, on profile: String, title: String = "A chat") {
        saved.append(
            SavedChat(
                profileID: profile, sessionID: session, title: title, profileName: "studio",
                backend: .claudeCode, directory: "/work/app",
                updatedAt: Date(timeIntervalSince1970: clock),
                savedAt: Date(timeIntervalSince1970: clock)))
    }
}

private final class ClockBox: @unchecked Sendable {
    var value: Double
    init(_ value: Double) { self.value = value }
}

@MainActor
private func server(_ profile: String, endpoint: String = "studio:4098", name: String = "studio")
    -> CloudServer
{
    CloudServer(profileID: profile, name: name, backend: .claudeCode, endpoint: endpoint)
}

@Suite("Cloud sync")
@MainActor
struct CloudSyncTests {
    @Test("A server is named the same by every device whatever it was typed as")
    func endpointSpelling() {
        #expect(CloudKeys.endpoint(host: "ARCH.tail1234.ts.net.", port: 4098) == "arch:4098")
        #expect(CloudKeys.endpoint(host: "arch", port: 4098) == "arch:4098")
        #expect(CloudKeys.endpoint(host: "100.64.0.9", port: 4098) == "100.64.0.9:4098")
        #expect(
            CloudKeys.endpoint(of: URL(string: "http://Studio.ts.net:4098")!) == "studio:4098")
    }

    @Test("A chat saved on one device is saved on the other, under the other's own profile")
    func savedFollowsAcrossProfiles() {
        let cloud = InMemoryCloudStore()
        let phone = Phone(servers: [server("phone-p")], cloud: cloud, startingAt: 1_000)
        let pad = Phone(servers: [server("pad-p")], cloud: cloud, startingAt: 1_000)
        phone.settle()
        pad.settle()
        phone.advance(to: 2_000)
        phone.save("s1", on: "phone-p", title: "Fix the build")
        phone.settle()
        pad.advance(to: 2_100)
        pad.settle()
        #expect(pad.saved.map(\.sessionID) == ["s1"])
        #expect(pad.saved.first?.profileID == "pad-p")
        #expect(pad.saved.first?.title == "Fix the build")
    }

    @Test("Dropping a bookmark on one device drops it on the other")
    func removalTravels() {
        let cloud = InMemoryCloudStore()
        let phone = Phone(servers: [server("a")], cloud: cloud, startingAt: 1_000)
        let pad = Phone(servers: [server("b")], cloud: cloud, startingAt: 1_000)
        phone.save("s1", on: "a")
        phone.settle()
        pad.settle()
        #expect(pad.saved.count == 1)
        pad.advance(to: 5_000)
        pad.saved = []
        pad.settle()
        phone.advance(to: 5_100)
        phone.settle()
        #expect(phone.saved.isEmpty)
    }

    @Test("A chat read on one device is read on the other, and unread again when marked so")
    func readFollows() {
        let cloud = InMemoryCloudStore()
        let phone = Phone(servers: [server("a")], cloud: cloud, startingAt: 1_000)
        let pad = Phone(servers: [server("b")], cloud: cloud, startingAt: 1_000)
        phone.settle()
        pad.settle()
        phone.advance(to: 2_000)
        phone.markSeen("s1", value: 2_000)
        phone.settle()
        pad.advance(to: 2_010)
        pad.settle()
        #expect(pad.seen["s1"]?.value == 2_000)
        pad.advance(to: 3_000)
        pad.markSeen("s1", value: 1_500)
        pad.settle()
        phone.advance(to: 3_010)
        phone.settle()
        #expect(phone.seen["s1"]?.value == 1_500)
    }

    @Test("The later decision wins when two devices disagree about one chat")
    func laterDecisionWins() {
        let cloud = InMemoryCloudStore()
        let phone = Phone(servers: [server("a")], cloud: cloud, startingAt: 1_000)
        let pad = Phone(servers: [server("b")], cloud: cloud, startingAt: 1_000)
        phone.settle()
        pad.settle()
        phone.advance(to: 2_000)
        phone.markSeen("s1", value: 2_000)
        pad.advance(to: 2_500)
        pad.markSeen("s1", value: 2_500)
        phone.settle()
        pad.settle()
        phone.advance(to: 2_600)
        phone.settle()
        #expect(phone.seen["s1"]?.value == 2_500)
        #expect(pad.seen["s1"]?.value == 2_500)
    }

    @Test("Pins keep the order they were made in across devices")
    func pinOrder() {
        let cloud = InMemoryCloudStore()
        let phone = Phone(servers: [server("a")], cloud: cloud, startingAt: 1_000)
        let pad = Phone(servers: [server("b")], cloud: cloud, startingAt: 1_000)
        phone.settle()
        pad.settle()
        phone.advance(to: 2_000)
        phone.pins = ["a/s1"]
        phone.settle()
        phone.advance(to: 2_100)
        phone.pins = ["a/s1", "a/s2"]
        phone.settle()
        pad.advance(to: 2_200)
        pad.settle()
        #expect(pad.pins == ["b/s1", "b/s2"])
        pad.advance(to: 2_300)
        pad.pins = ["b/s2"]
        pad.settle()
        phone.advance(to: 2_400)
        phone.settle()
        #expect(phone.pins == ["a/s2"])
    }

    @Test("Archiving travels, and unarchiving travels back")
    func archiveTravels() {
        let cloud = InMemoryCloudStore()
        let phone = Phone(servers: [server("a")], cloud: cloud, startingAt: 1_000)
        let pad = Phone(servers: [server("b")], cloud: cloud, startingAt: 1_000)
        phone.settle()
        pad.settle()
        phone.advance(to: 2_000)
        phone.archive = ["a/s1"]
        phone.settle()
        pad.advance(to: 2_100)
        pad.settle()
        #expect(pad.archive == ["b/s1"])
        pad.advance(to: 2_200)
        pad.archive = []
        pad.settle()
        phone.advance(to: 2_300)
        phone.settle()
        #expect(phone.archive.isEmpty)
    }

    @Test("A server added later is not read as a year of deletions")
    func laterServerIsNotDeletions() {
        let cloud = InMemoryCloudStore()
        let phone = Phone(servers: [server("a")], cloud: cloud, startingAt: 1_000)
        let pad = Phone(servers: [server("b", endpoint: "other:4098", name: "other")], cloud: cloud, startingAt: 1_000)
        phone.save("s1", on: "a")
        phone.pins = ["a/s1"]
        phone.settle()
        pad.settle()
        #expect(pad.saved.isEmpty)
        pad.advance(to: 9_000)
        pad.knownServers.append(server("b2"))
        pad.settle()
        #expect(pad.saved.map(\.sessionID) == ["s1"])
        #expect(pad.pins == ["b2/s1"])
        phone.advance(to: 9_100)
        phone.settle()
        #expect(phone.saved.map(\.sessionID) == ["s1"])
        #expect(phone.pins == ["a/s1"])
    }

    @Test("Devices that spell a server differently still agree on its chats")
    func aliasedServer() {
        let cloud = InMemoryCloudStore()
        let phone = Phone(
            servers: [server("a", endpoint: "studio:4098")], cloud: cloud, startingAt: 1_000)
        let pad = Phone(
            servers: [server("b", endpoint: "100.64.0.5:4098")], cloud: cloud, startingAt: 1_000)
        phone.save("s1", on: "a")
        phone.pins = ["a/s1"]
        phone.settle()
        pad.settle()
        #expect(pad.saved.map(\.sessionID) == ["s1"])
        pad.advance(to: 4_000)
        pad.saved = []
        pad.pins = []
        pad.settle()
        phone.advance(to: 4_100)
        phone.settle()
        #expect(phone.saved.isEmpty)
        #expect(phone.pins.isEmpty)
        pad.advance(to: 4_200)
        pad.settle()
        #expect(pad.saved.isEmpty)
    }

    @Test("What a device held before it ever synced is outranked by what was decided elsewhere")
    func legacyYields() {
        let cloud = InMemoryCloudStore()
        let phone = Phone(servers: [server("a")], cloud: cloud, startingAt: 1_000)
        phone.pins = ["a/s1"]
        phone.settle()
        phone.advance(to: 2_000)
        phone.pins = []
        phone.settle()
        let fresh = Phone(servers: [server("c")], cloud: cloud, startingAt: 3_000)
        fresh.pins = ["c/s1"]
        fresh.settle()
        #expect(fresh.pins.isEmpty)
    }

    @Test("Passes with nothing new write nothing")
    func quietPassIsQuiet() {
        let cloud = InMemoryCloudStore()
        let phone = Phone(servers: [server("a")], cloud: cloud, startingAt: 1_000)
        phone.pins = ["a/s1"]
        phone.settle()
        let before = cloud.data(forKey: "tailscode.cloud.pinned")
        phone.advance(to: 1_100)
        phone.settle()
        phone.settle()
        #expect(cloud.data(forKey: "tailscode.cloud.pinned") == before)
    }

    @Test("A server taken off one device does not empty the others")
    func disconnectingIsLocal() {
        let cloud = InMemoryCloudStore()
        let phone = Phone(servers: [server("a")], cloud: cloud, startingAt: 1_000)
        let pad = Phone(servers: [server("b")], cloud: cloud, startingAt: 1_000)
        phone.save("s1", on: "a")
        phone.pins = ["a/s1"]
        phone.settle()
        pad.settle()
        #expect(pad.saved.count == 1)
        pad.advance(to: 3_000)
        pad.knownServers = []
        pad.saved = []
        pad.pins = []
        pad.settle()
        phone.advance(to: 3_100)
        phone.settle()
        #expect(phone.saved.map(\.sessionID) == ["s1"])
        #expect(phone.pins == ["a/s1"])
        pad.advance(to: 4_000)
        pad.knownServers = [server("b2")]
        pad.settle()
        #expect(pad.saved.map(\.sessionID) == ["s1"])
        #expect(pad.pins == ["b2/s1"])
    }

    @Test("A signed-out cloud holds the device as it is and says so")
    func unavailable() {
        let cloud = InMemoryCloudStore()
        cloud.isAvailable = false
        let phone = Phone(servers: [server("a")], cloud: cloud, startingAt: 1_000)
        phone.pins = ["a/s1"]
        phone.settle()
        #expect(phone.sync.status == .unavailable)
        #expect(phone.pins == ["a/s1"])
        #expect(cloud.data(forKey: "tailscode.cloud.pinned") == nil)
    }

    @Test("A different account's state is never merged into this one's")
    func accountChange() {
        let cloud = InMemoryCloudStore()
        let phone = Phone(servers: [server("a")], cloud: cloud, startingAt: 1_000)
        phone.pins = ["a/s1"]
        phone.settle()
        let first = cloud.data(forKey: "tailscode.cloud.pinned")
        #expect(first != nil)
        cloud.accountFingerprint = "someone-else"
        phone.advance(to: 2_000)
        phone.settle()
        #expect(phone.pins == ["a/s1"])
    }
}

@Suite("Cloud ledger")
struct CloudLedgerTests {
    private func mark(_ at: Double, on: Bool = true, value: Double? = nil) -> CloudMark {
        CloudMark(at: at, on: on, value: value)
    }

    @Test("Merging is commutative and idempotent")
    func merges() {
        var lhs = CloudLedger()
        var rhs = CloudLedger()
        lhs.pinned = ["a": mark(1), "b": mark(5, on: false), "c": mark(3)]
        rhs.pinned = ["a": mark(2, on: false), "b": mark(4), "d": mark(9)]
        lhs.seen = ["s": mark(7, value: 1)]
        rhs.seen = ["s": mark(7, value: 2)]
        let one = CloudLedger.merged(lhs, rhs)
        let two = CloudLedger.merged(rhs, lhs)
        #expect(one == two)
        #expect(CloudLedger.merged(one, one) == one)
        #expect(one.pinned["a"]?.on == false)
        #expect(one.pinned["b"]?.on == false)
        #expect(one.seen["s"]?.value == 2)
    }

    @Test("A removal wins a tie")
    func removalWinsTies() {
        #expect(mark(5, on: false).outranks(mark(5)))
        #expect(!mark(5).outranks(mark(5, on: false)))
    }

    @Test("Old removals are forgotten, the newest decisions are kept")
    func pruning() {
        var ledger = CloudLedger()
        ledger.pinned = ["old": CloudMark(at: 10, on: false), "new": CloudMark(at: 9_999_999, on: false)]
        for index in 0..<350 { ledger.seen["s\(index)"] = mark(Double(index), value: 1) }
        let pruned = ledger.pruned(now: 10_000_000)
        #expect(pruned.pinned["old"] == nil)
        #expect(pruned.pinned["new"] != nil)
        #expect(pruned.seen.count == CloudLedger.readMarkCapacity)
        #expect(pruned.seen["s0"] == nil)
        #expect(pruned.seen["s349"] != nil)
    }

    @Test("A ledger of full size stays far inside what the cloud allows")
    func size() throws {
        var ledger = CloudLedger()
        let chat = CloudChat(
            serverName: "studio", backend: .claudeCode,
            title: String(repeating: "t", count: 120), directory: "/Users/someone/Dev/project",
            updatedAt: 1, savedAt: 1)
        for index in 0..<CloudLedger.keptCapacity {
            let key = CloudKeys.conversation(endpoint: "studio:4098", sessionID: UUID().uuidString)
            ledger.saved[key] = CloudMark(at: Double(index), on: true, chat: chat)
            ledger.pinned[key] = CloudMark(at: Double(index), on: true)
            ledger.archived[key] = CloudMark(at: Double(index), on: true)
        }
        for index in 0..<CloudLedger.readMarkCapacity {
            ledger.seen[UUID().uuidString] = CloudMark(at: Double(index), on: true, value: 1)
        }
        let bytes = try JSONEncoder().encode(ledger).count
        #expect(bytes < 400_000)
    }
}
