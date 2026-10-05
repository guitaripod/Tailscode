import Foundation
import Testing
@testable import TailscodeCore

@Suite("Flight recorder")
struct FlightRecorderTests {
    private static func scratch() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("flight-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("flight.ring")
    }

    private static func full(_ t: Int64, ev: String? = nil) -> FlightRecord {
        FlightRecord(
            t: t, n: 9_999_999, rss: 99_999_999, thr: 9999, fds: 99_999,
            panes: FlightPanes(full: 12, glance: 12, parked: 12), lv: 4, busy: 0.999, stall: 999_999,
            mb: 999, dr: 9999.94, ps: "99.99/99.99", av: 9_999_999, own: 0.999, rl: 9999.9, ev: ev)
    }

    @Test("Every slot is 192 bytes of space-padded ASCII JSON ending in a newline")
    func slotShape() {
        for record in [
            FlightRecord(t: 1),
            Self.full(1_759_700_000_000),
            Self.full(1_759_700_000_000, ev: String(repeating: "x", count: 400)),
            FlightRecord(t: 1, ev: "shed 1→2 busy ünïcode \"quoted\" \\ back"),
            FlightRecord.launch(
                FlightHeader(
                    version: String(repeating: "9", count: 80), toolkit: String(repeating: "g", count: 80),
                    renderer: String(repeating: "r", count: 80), glVendor: String(repeating: "v", count: 80)),
                t: 1_759_700_000_000),
        ] {
            let slot = record.slot()
            #expect(slot.count == FlightRecord.slotSize)
            #expect(slot.last == 0x0A)
            #expect(slot.allSatisfy { $0 == 0x0A || ($0 >= 0x20 && $0 < 0x7F) })
            #expect(FlightRecord.decode(slot: slot) != nil)
        }
    }

    @Test("A record round-trips through its slot, the arrow spelled in ASCII")
    func roundTrip() throws {
        let record = FlightRecord(
            t: 1_759_700_000_123, n: 42, rss: 512_000, thr: 31, fds: 88,
            panes: FlightPanes(full: 2, glance: 3, parked: 1), lv: 2, busy: 0.42, stall: 320, mb: 1,
            dr: 3.2, ps: "21.5/1.0", av: 12_345, own: 0.37, rl: 12.5, ev: "shed 1→2 busy")
        let back = try #require(FlightRecord.decode(slot: record.slot()))
        var expected = record
        expected.ev = "shed 1->2 busy"
        #expect(back == expected)
    }

    @Test("A full record keeps every measurement and still has room for an event")
    func fullRecordRoom() throws {
        let back = try #require(FlightRecord.decode(slot: Self.full(1_759_700_000_000, ev: "stall 3200ms D").slot()))
        #expect(back.ev == "stall 3200ms D")
        #expect(back.lv == 4)
        #expect(back.stall == 999_999)
        #expect(back.panes == FlightPanes(full: 12, glance: 12, parked: 12))
        #expect(back.rss == 99_999_999)
        let measured = try #require(FlightRecord.decode(slot: Self.full(1_759_700_000_000).slot()))
        #expect(measured.rl != nil || measured.dr != nil || measured.fds != nil)
    }

    @Test("An event too long for the slot is shortened, never the record torn")
    func longEvent() throws {
        let back = try #require(FlightRecord.decode(slot: FlightRecord(t: 5, lv: 1, ev: String(repeating: "e", count: 500)).slot()))
        #expect(back.lv == 1)
        #expect((back.ev?.count ?? 0) > 100)
        #expect(back.ev?.allSatisfy { $0 == "e" } == true)
    }

    @Test("The launch header keeps the limits code, and a header at every ceiling still fits its slot")
    func launchHeaderLimits() throws {
        let header = FlightHeader(
            version: "1.68", toolkit: "gtk 4.22.1 adw 1.8.0", renderer: "GskNglRenderer",
            glVendor: "NVIDIA Corporation", limits: "dbus")
        let back = try #require(FlightRecord.decode(slot: FlightRecord.launch(header, t: 7).slot()))
        #expect(back.header == header)
        #expect(FlightFormatter.format([back]).contains("limits dbus"))
        let widest = String(repeating: "w", count: 40)
        let full = FlightHeader(
            version: widest, toolkit: widest, renderer: widest, glVendor: widest, limits: widest)
        let slot = FlightRecord.launch(full, t: 1_759_999_999_999).slot()
        #expect(slot.count == FlightRecord.slotSize)
        let decoded = try #require(FlightRecord.decode(slot: slot))
        #expect(decoded.header?.limits?.count == FlightHeader.limitsWidth)
    }

    @Test("The launch header carries version, toolkit, renderer and GL vendor")
    func launchHeader() throws {
        let header = FlightHeader(version: "1.68", toolkit: "GTK 4.22.1", renderer: "GskGLRenderer", glVendor: "NVIDIA Corporation")
        let back = try #require(FlightRecord.decode(slot: FlightRecord.launch(header, t: 7).slot()))
        #expect(back.header == header)
        #expect(back.ev == "launch")
    }

    @Test("Empty, torn and foreign slots read as nothing")
    func tornSlots() {
        #expect(FlightRecord.decode(slot: [UInt8](repeating: 0, count: 192)) == nil)
        #expect(FlightRecord.decode(slot: [UInt8](repeating: 0x20, count: 191) + [0x0A]) == nil)
        var torn = FlightRecord(t: 1, n: 3, lv: 2).slot()
        torn.replaceSubrange(10..<192, with: [UInt8](repeating: 0, count: 182))
        #expect(FlightRecord.decode(slot: torn) == nil)
        #expect(FlightRecord.decode(slot: Array("{\"x\":1}".utf8)) == nil)
    }

    @Test("Privacy: a record has no field that could hold a title, an id, a path or text")
    func privacy() {
        let allowed: Set<String> = [
            "t", "n", "rss", "thr", "fds", "panes", "lv", "busy", "stall", "mb", "dr", "ps", "av",
            "own", "rl", "ev", "header",
        ]
        let labels = Set(Mirror(reflecting: Self.full(1)).children.compactMap(\.label))
        #expect(labels == allowed)
        let headerLabels = Set(Mirror(reflecting: FlightHeader(version: "", toolkit: "")).children.compactMap(\.label))
        #expect(headerLabels == ["version", "toolkit", "renderer", "glVendor", "limits"])
        for banned in ["title", "id", "sessionID", "path", "text", "profile", "name", "url"] {
            #expect(!labels.contains(banned))
        }
    }

    @Test("The ring wraps at its slot count and reads newest last")
    func ringWrap() throws {
        let url = Self.scratch()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let ring = try FlightRing(url: url, slots: 10)
        for index in 0..<25 { ring.write(FlightRecord(t: Int64(index), lv: index % 5), sync: index % 7 == 0) }
        ring.sync()
        let size = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int
        #expect(size == 10 * FlightRecord.slotSize)
        let records = ring.read()
        #expect(records.map(\.n) == Array(16...25))
        #expect(records.map(\.t) == Array(15...24).map(Int64.init))
        #expect(ring.read(last: 3).map(\.n) == [23, 24, 25])
    }

    @Test("Reopening carries on from the highest number, even past a torn tail")
    func recovery() throws {
        let url = Self.scratch()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            let ring = try FlightRing(url: url, slots: 8)
            for index in 0..<11 { ring.write(FlightRecord(t: Int64(index))) }
        }
        let handle = try FileHandle(forWritingTo: url)
        try handle.seek(toOffset: UInt64((11 % 8) * FlightRecord.slotSize + 5))
        handle.write(Data([UInt8](repeating: 0, count: 100)))
        try handle.close()
        let reopened = try FlightRing(url: url, slots: 8)
        #expect(reopened.nextNumber == 11)
        #expect(reopened.read().map(\.n) == [4, 5, 6, 7, 8, 9, 10])
        reopened.write(FlightRecord(t: 100, ev: "restore unclean"))
        let after = FlightRing.read(url: url, slots: 8)
        #expect(after.last?.n == 11)
        #expect(after.last?.ev == "restore unclean")
        #expect(after.count == 8)
    }

    @Test("A fresh ring starts at one and a missing file reads as empty")
    func fresh() throws {
        let url = Self.scratch()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        #expect(FlightRing.read(url: url).isEmpty)
        let ring = try FlightRing(url: url)
        #expect(ring.nextNumber == 1)
        #expect(ring.read().isEmpty)
        #expect(FlightRing.slotCount == 3600)
    }

    @Test("The default location follows XDG_STATE_HOME on Linux and Library/Logs on Apple")
    func location() {
        let url = FlightRing.defaultURL(environment: ["XDG_STATE_HOME": "/tmp/state"])
        #expect(url.lastPathComponent == "flight.ring")
        #if canImport(Darwin)
            #expect(url.path.contains("Library/Logs/Tailscode"))
        #else
            #expect(url.path == "/tmp/state/tailscode/flight.ring")
            #expect(FlightRing.defaultURL(environment: [:]).path.hasSuffix(".local/state/tailscode/flight.ring"))
        #endif
    }

    @Test("--flight prints newest last with aligned columns and the launch header spelled out")
    func formatter() {
        var launch = FlightRecord.launch(
            FlightHeader(version: "1.68", toolkit: "GTK 4.22", renderer: "GskNglRenderer", glVendor: "NVIDIA"),
            t: 1_759_700_000_000)
        launch.n = 2
        let records = [
            FlightRecord(
                t: 1_759_700_060_000, n: 3, rss: 512_000, thr: 31, fds: 88,
                panes: FlightPanes(full: 2, glance: 3, parked: 0), lv: 1, busy: 0.42, stall: 120, mb: 1,
                dr: 2.5, ps: "21.5/1.0", av: 9000, own: 0.31, rl: 7.5, ev: "shed 0->1 busy"),
            launch,
            FlightRecord(t: 1_759_699_000_000, n: 1, lv: 0),
        ]
        let text = FlightFormatter.format(records, timeZone: TimeZone(identifier: "UTC")!)
        let lines = text.split(separator: "\n")
        #expect(lines.count == 4)
        #expect(lines[0].hasPrefix("time"))
        #expect(lines[1].hasPrefix("2025-10-05 21:16:40"))
        #expect(lines[2].contains("launch: version 1.68, toolkit GTK 4.22, renderer GskNglRenderer, gl NVIDIA"))
        #expect(lines[3].contains("0.42"))
        #expect(lines[3].contains("120ms"))
        #expect(lines[3].contains("2/3/0"))
        #expect(lines[3].hasSuffix("shed 0->1 busy"))
        let recent = FlightFormatter.format(records, minutes: 5, timeZone: TimeZone(identifier: "UTC")!)
        #expect(recent.split(separator: "\n").count == 3)
    }
}
