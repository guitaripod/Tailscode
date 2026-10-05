import Foundation

#if canImport(Darwin)
    import Darwin
#elseif canImport(Glibc)
    import Glibc
#elseif canImport(Musl)
    import Musl
#endif

/// How many panes sit at each density, the recorder's `p` field: `full/glance/parked`.
public struct FlightPanes: Sendable, Equatable {
    public var full: Int
    public var glance: Int
    public var parked: Int

    public init(full: Int, glance: Int, parked: Int) {
        self.full = full
        self.glance = glance
        self.parked = parked
    }
}

/// What the launch header says about the build and the renderer it actually ran.
public struct FlightHeader: Sendable, Equatable {
    public var version: String
    public var toolkit: String
    public var renderer: String?
    public var glVendor: String?
    /// What the launch did about its own resource limits, as a short code (`dbus`, `systemctl`,
    /// `skip-foreign`, …), so a freeze read from the ring says whether the app was fenced in.
    public var limits: String?

    public init(
        version: String, toolkit: String, renderer: String? = nil, glVendor: String? = nil,
        limits: String? = nil
    ) {
        self.version = version
        self.toolkit = toolkit
        self.renderer = renderer
        self.glVendor = glVendor
        self.limits = limits
    }

    /// The longest limits code a header keeps: with every other header field at its own ceiling
    /// the slot still fits.
    public static let limitsWidth = 12
}

/// One second of the black box. Counts and durations only: there is no field that could hold a
/// title, an id, a path or a word of a conversation, so a ring copied into a bug report carries
/// nothing anybody wrote.
public struct FlightRecord: Sendable, Equatable {
    public static let slotSize = 192

    /// Epoch milliseconds.
    public var t: Int64
    /// Monotonic record number; the ring sets it on write.
    public var n: UInt64
    /// Resident set, KiB.
    public var rss: UInt64?
    public var thr: Int?
    public var fds: Int?
    public var panes: FlightPanes?
    public var lv: Int?
    /// Loop busy share, 0…1.
    public var busy: Double?
    /// Worst stall, ms.
    public var stall: Int?
    /// Deepest mailbox.
    public var mb: Int?
    /// Drain p95, ms.
    public var dr: Double?
    /// PSI `some/full` avg10 on Linux, the pressure word on the Mac.
    public var ps: String?
    /// Available memory, MB.
    public var av: Int?
    /// Own memory as a share of its limit.
    public var own: Double?
    /// Relayout during a drag, ms.
    public var rl: Double?
    /// An event: `shed 1->2 busy`, `stall 3200ms D`, `relief`, `restore unclean`, `exit clean`.
    public var ev: String?
    public var header: FlightHeader?

    public init(
        t: Int64, n: UInt64 = 0, rss: UInt64? = nil, thr: Int? = nil, fds: Int? = nil,
        panes: FlightPanes? = nil, lv: Int? = nil, busy: Double? = nil, stall: Int? = nil,
        mb: Int? = nil, dr: Double? = nil, ps: String? = nil, av: Int? = nil, own: Double? = nil,
        rl: Double? = nil, ev: String? = nil, header: FlightHeader? = nil
    ) {
        self.t = t
        self.n = n
        self.rss = rss
        self.thr = thr
        self.fds = fds
        self.panes = panes
        self.lv = lv
        self.busy = busy
        self.stall = stall
        self.mb = mb
        self.dr = dr
        self.ps = ps
        self.av = av
        self.own = own
        self.rl = rl
        self.ev = ev
        self.header = header
    }

    /// The launch header: what ran, recorded once at start.
    public static func launch(_ header: FlightHeader, t: Int64) -> FlightRecord {
        FlightRecord(t: t, ev: "launch", header: header)
    }

    public static func epochMilliseconds(_ date: Date = Date()) -> Int64 {
        Int64((date.timeIntervalSince1970 * 1000).rounded())
    }

    /// The fixed slot: compact ASCII JSON, space-padded, ending in a newline, exactly `slotSize`
    /// bytes. When everything will not fit, the event is shortened first and then the least
    /// telling fields are left out, so a slot is never torn by its own record.
    public func slot() -> [UInt8] {
        let limit = Self.slotSize - 1
        let event = ev.map(Self.ascii).flatMap { $0.isEmpty ? nil : $0 }
        let kept = event.map { String($0.prefix(Self.eventFloor)) }
        var dropped = 0
        while encode(event: kept, dropping: dropped).utf8.count > limit, dropped < Self.droppable {
            dropped += 1
        }
        var body = encode(event: event, dropping: dropped)
        if let event, body.utf8.count > limit {
            let over = body.utf8.count - limit
            let shortened = String(event.prefix(max(0, event.count - over)))
            body = encode(event: shortened.isEmpty ? nil : shortened, dropping: dropped)
        }
        var bytes = Array(body.utf8.prefix(limit))
        bytes.append(contentsOf: [UInt8](repeating: 0x20, count: limit - bytes.count))
        bytes.append(0x0A)
        return bytes
    }

    /// How much of an event survives before any measurement is left out for it.
    static let eventFloor = 32
    private static let droppable = 13

    /// Fields in the order they are written; the tail of this list is what goes first when a
    /// record will not fit.
    private func encode(event: String?, dropping: Int) -> String {
        var fields: [(String, String)] = [("t", String(t)), ("n", String(n))]
        if let header {
            fields.append(("ver", Self.quoted(Self.ascii(header.version).prefix(24))))
            fields.append(("tk", Self.quoted(Self.ascii(header.toolkit).prefix(24))))
            if let renderer = header.renderer {
                fields.append(("gsk", Self.quoted(Self.ascii(renderer).prefix(24))))
            }
            if let vendor = header.glVendor {
                fields.append(("gl", Self.quoted(Self.ascii(vendor).prefix(24))))
            }
            if let limits = header.limits {
                fields.append(("lim", Self.quoted(Self.ascii(limits).prefix(FlightHeader.limitsWidth))))
            }
        }
        var optional: [(String, String)] = []
        if let lv { optional.append(("lv", String(lv))) }
        if let busy { optional.append(("busy", Self.number(busy, places: 2))) }
        if let stall { optional.append(("stall", String(stall))) }
        if let rss { optional.append(("rss", String(rss))) }
        if let panes { optional.append(("p", Self.quoted("\(panes.full)/\(panes.glance)/\(panes.parked)"))) }
        if let ps { optional.append(("ps", Self.quoted(Self.ascii(ps).prefix(16)))) }
        if let av { optional.append(("av", String(av))) }
        if let own { optional.append(("own", Self.number(own, places: 2))) }
        if let mb { optional.append(("mb", String(mb))) }
        if let thr { optional.append(("thr", String(thr))) }
        if let fds { optional.append(("fds", String(fds))) }
        if let dr { optional.append(("dr", Self.number(dr, places: 1))) }
        if let rl { optional.append(("rl", Self.number(rl, places: 1))) }
        fields += optional.dropLast(min(dropping, optional.count))
        if let event { fields.append(("ev", Self.quoted(event))) }
        return "{" + fields.map { "\"\($0.0)\":\($0.1)" }.joined(separator: ",") + "}"
    }

    /// Reads one slot back; nil for an empty, torn or foreign slot.
    public static func decode(slot bytes: some Collection<UInt8>) -> FlightRecord? {
        let trimmed = bytes.prefix { $0 != 0x0A && $0 != 0 }
        guard let text = String(bytes: trimmed, encoding: .ascii)?
            .trimmingCharacters(in: .whitespaces), text.hasPrefix("{"), text.hasSuffix("}"),
            let data = text.data(using: .ascii),
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let t = (object["t"] as? NSNumber)?.int64Value,
            let n = (object["n"] as? NSNumber)?.uint64Value
        else { return nil }
        func int(_ key: String) -> Int? { (object[key] as? NSNumber)?.intValue }
        func double(_ key: String) -> Double? { (object[key] as? NSNumber)?.doubleValue }
        var record = FlightRecord(
            t: t, n: n, rss: (object["rss"] as? NSNumber)?.uint64Value, thr: int("thr"),
            fds: int("fds"), lv: int("lv"), busy: double("busy"), stall: int("stall"),
            mb: int("mb"), dr: double("dr"), ps: object["ps"] as? String, av: int("av"),
            own: double("own"), rl: double("rl"), ev: object["ev"] as? String)
        if let panes = object["p"] as? String {
            let parts = panes.split(separator: "/").compactMap { Int($0) }
            if parts.count == 3 {
                record.panes = FlightPanes(full: parts[0], glance: parts[1], parked: parts[2])
            }
        }
        if let version = object["ver"] as? String, let toolkit = object["tk"] as? String {
            record.header = FlightHeader(
                version: version, toolkit: toolkit, renderer: object["gsk"] as? String,
                glVendor: object["gl"] as? String, limits: object["lim"] as? String)
        }
        return record
    }

    /// Printable ASCII only, with the arrow the shed events use spelled `->`.
    static func ascii(_ text: String) -> String {
        var out = ""
        for scalar in text.replacingOccurrences(of: "→", with: "->").unicodeScalars {
            if scalar.value >= 0x20, scalar.value < 0x7F {
                out.unicodeScalars.append(scalar)
            } else {
                out.append("?")
            }
        }
        return out
    }

    private static func quoted(_ text: some StringProtocol) -> String {
        var out = "\""
        for char in text {
            if char == "\"" || char == "\\" { out.append("\\") }
            out.append(char)
        }
        return out + "\""
    }

    private static func number(_ value: Double, places: Int) -> String {
        guard value.isFinite else { return "0" }
        let scale = pow(10, Double(places))
        let rounded = (value * scale).rounded() / scale
        if rounded == rounded.rounded() { return String(Int64(rounded)) }
        return String(format: "%.\(places)f", rounded)
    }
}

/// The black box on disk: a fixed ring of `slotCount` slots, each record written to slot
/// `n % slotCount` and synced, with no index to corrupt. Opening finds the highest `n` and carries
/// on from it; a slot torn by a hard freeze simply fails to decode and is skipped.
public final class FlightRing: @unchecked Sendable {
    public static let slotCount = 3600

    public let url: URL
    public let slots: Int
    private let lock = NSLock()
    private var descriptor: Int32
    private var next: UInt64

    /// Opens or creates the ring. Throws when the file cannot be opened for writing.
    public init(url: URL, slots: Int = FlightRing.slotCount) throws {
        self.url = url
        self.slots = max(1, slots)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = open(url.path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { throw FlightRingError.open(errno) }
        descriptor = fd
        let size = off_t(self.slots * FlightRecord.slotSize)
        var info = stat()
        if fstat(fd, &info) == 0, info.st_size < size { _ = ftruncate(fd, size) }
        let newest = Self.records(in: (try? Data(contentsOf: url)) ?? Data(), slots: self.slots)
            .map(\.n).max()
        next = newest.map { $0 + 1 } ?? 1
    }

    deinit {
        close(descriptor)
    }

    /// The number the next record will carry.
    public var nextNumber: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return next
    }

    /// Writes a record into its slot and, by default, syncs it to the disk before returning. The
    /// ring numbers the record; the number written is returned.
    @discardableResult
    public func write(_ record: FlightRecord, sync: Bool = true) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        var record = record
        record.n = next
        next += 1
        let bytes = record.slot()
        let offset = off_t(Int(record.n % UInt64(slots)) * FlightRecord.slotSize)
        _ = bytes.withUnsafeBytes { pwrite(descriptor, $0.baseAddress, $0.count, offset) }
        if sync { Self.dataSync(descriptor) }
        return record.n
    }

    /// Forces everything written so far to the disk.
    public func sync() {
        lock.lock()
        defer { lock.unlock() }
        Self.dataSync(descriptor)
    }

    /// The newest `last` records, oldest first.
    public func read(last: Int = FlightRing.slotCount) -> [FlightRecord] {
        Self.read(url: url, last: last, slots: slots)
    }

    /// Reads a ring another process may be writing, oldest first.
    public static func read(url: URL, last: Int = slotCount, slots: Int = slotCount) -> [FlightRecord] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return Array(records(in: data, slots: slots).suffix(max(0, last)))
    }

    /// Every slot that decodes, ordered by record number. A slot whose number does not belong in
    /// it is a foreign or torn write and is left out.
    static func records(in data: Data, slots: Int) -> [FlightRecord] {
        let size = FlightRecord.slotSize
        var found: [FlightRecord] = []
        let bytes = [UInt8](data)
        var index = 0
        while (index + 1) * size <= bytes.count, index < slots {
            let slice = bytes[(index * size)..<((index + 1) * size)]
            if let record = FlightRecord.decode(slot: slice), Int(record.n % UInt64(slots)) == index {
                found.append(record)
            }
            index += 1
        }
        return found.sorted { $0.n < $1.n }
    }

    /// `fdatasync` where the platform has it; on Apple `F_FULLFSYNC`, which is what actually
    /// reaches the platter, with `fsync` behind it.
    private static func dataSync(_ fd: Int32) {
        #if canImport(Darwin)
            if fcntl(fd, F_FULLFSYNC) == -1 { _ = fsync(fd) }
        #else
            _ = fdatasync(fd)
        #endif
    }

    /// Where the ring lives: `$XDG_STATE_HOME/tailscode/flight.ring` on Linux,
    /// `~/Library/Logs/Tailscode/flight.ring` on Apple platforms (inside the container when
    /// sandboxed).
    public static func defaultURL(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        directory(environment: environment).appendingPathComponent("flight.ring")
    }

    /// The directory the ring and the launch ledger share.
    public static func directory(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        #if canImport(Darwin)
            return FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Logs", isDirectory: true)
                .appendingPathComponent("Tailscode", isDirectory: true)
        #else
            let state = environment["XDG_STATE_HOME"].flatMap { $0.isEmpty ? nil : $0 }
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
                ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".local/state", isDirectory: true)
            return state.appendingPathComponent("tailscode", isDirectory: true)
        #endif
    }
}

public enum FlightRingError: Error, Equatable {
    case open(Int32)
}

/// The ring as `--flight` prints it: newest last, one aligned line per record, the launch headers
/// spelled out.
public enum FlightFormatter {
    /// - Parameters:
    ///   - minutes: only records from the last this many minutes of the newest record; nil for all.
    public static func format(
        _ records: [FlightRecord], minutes: Double? = nil, timeZone: TimeZone = .current
    ) -> String {
        var shown = records.sorted { $0.n < $1.n }
        if let minutes, let newest = shown.last?.t {
            let cutoff = newest - Int64(minutes * 60_000)
            shown = shown.filter { $0.t >= cutoff }
        }
        let clock = DateFormatter()
        clock.locale = Locale(identifier: "en_US_POSIX")
        clock.timeZone = timeZone
        clock.dateFormat = "yyyy-MM-dd HH:mm:ss"
        var lines = [
            pad("time", 19) + "  " + pad("n", 7, right: true) + "  lv  " + pad("busy", 4, right: true) + " "
                + pad("stall", 6, right: true) + " " + pad("rss MB", 7, right: true) + " "
                + pad("thr", 4, right: true) + " " + pad("fds", 5, right: true) + "  " + pad("f/g/x", 8) + " "
                + pad("mb", 3, right: true) + " " + pad("dr", 5, right: true) + "  " + pad("ps", 9) + " "
                + pad("av MB", 7, right: true) + " " + pad("own", 4, right: true) + " " + pad("rl", 5, right: true)
                + "  event"
        ]
        for record in shown {
            let time = clock.string(from: Date(timeIntervalSince1970: Double(record.t) / 1000))
            if let header = record.header {
                let parts = [
                    "version \(header.version)", "toolkit \(header.toolkit)",
                    header.renderer.map { "renderer \($0)" }, header.glVendor.map { "gl \($0)" },
                    header.limits.map { "limits \($0)" },
                ].compactMap { $0 }
                lines.append(
                    pad(time, 19) + "  " + pad(String(record.n), 7, right: true) + "  launch: "
                        + parts.joined(separator: ", "))
                continue
            }
            let panes = record.panes.map { "\($0.full)/\($0.glance)/\($0.parked)" } ?? "-"
            let line =
                pad(time, 19) + "  " + pad(String(record.n), 7, right: true) + "  "
                + pad(record.lv.map(String.init) ?? "-", 2) + "  "
                + pad(record.busy.map { String(format: "%.2f", $0) } ?? "-", 4, right: true) + " "
                + pad(record.stall.map { "\($0)ms" } ?? "-", 6, right: true) + " "
                + pad(record.rss.map { String($0 / 1024) } ?? "-", 7, right: true) + " "
                + pad(record.thr.map(String.init) ?? "-", 4, right: true) + " "
                + pad(record.fds.map(String.init) ?? "-", 5, right: true) + "  "
                + pad(panes, 8) + " "
                + pad(record.mb.map(String.init) ?? "-", 3, right: true) + " "
                + pad(record.dr.map { String(format: "%.1f", $0) } ?? "-", 5, right: true) + "  "
                + pad(record.ps ?? "-", 9) + " "
                + pad(record.av.map(String.init) ?? "-", 7, right: true) + " "
                + pad(record.own.map { String(format: "%.2f", $0) } ?? "-", 4, right: true) + " "
                + pad(record.rl.map { String(format: "%.1f", $0) } ?? "-", 5, right: true)
                + (record.ev.map { "  " + $0 } ?? "")
            lines.append(line)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private static func pad(_ text: String, _ width: Int, right: Bool = false) -> String {
        guard text.count < width else { return text }
        let fill = String(repeating: " ", count: width - text.count)
        return right ? fill + text : text + fill
    }
}
