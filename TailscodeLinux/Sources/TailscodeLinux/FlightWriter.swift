import Foundation
import Glibc
import TailscodeCore

/// The process's own counts, read from `/proc/self` the way a person would with `ps`: resident
/// memory, threads and open descriptors.
struct ProcessCounts: Sendable, Equatable {
    var rssKiB: UInt64?
    var threads: Int?
    var fds: Int?

    static func read() -> ProcessCounts {
        let page = UInt64(sysconf(Int32(_SC_PAGESIZE)))
        let resident = ProcFile.read("/proc/self/statm")
            .flatMap { OwnMemory.parse(statm: $0, pageSize: page) }
        return ProcessCounts(
            rssKiB: resident.map { $0 / 1024 },
            threads: ProcFile.read("/proc/self/stat").flatMap(threads(stat:)),
            fds: ProcFile.entryCount("/proc/self/fd").map { max(0, $0 - 1) })
    }

    /// `num_threads` is field 20, counted after the command name's closing parenthesis.
    static func threads(stat: String) -> Int? {
        guard let close = stat.lastIndex(of: ")") else { return nil }
        let fields = stat[stat.index(after: close)...].split(separator: " ")
        return fields.count > 17 ? Int(fields[17]) : nil
    }
}

/// What the main loop last told the recorder: its own measurements, which only it can take.
struct LoopPublication: Sendable, Equatable {
    var busy: Double = 0
    /// The worst busy slice since the recorder last wrote, ms.
    var worstMs = 0
    var level = 0
    var panes = FlightPanes(full: 0, glance: 0, parked: 0)
    /// The most drain slots that were ready at once in the last second: the deepest the panes'
    /// latest-wins mailboxes got, each of which holds at most one state.
    var mailbox = 0
    /// The 95th percentile of the drain's passes in the last second, ms.
    var drainP95Ms: Double?
    /// The longest divider relayout in the last second, ms; zero when no divider moved.
    var relayoutMs = 0
}

/// The Linux end of the flight recorder: Core's `FlightRing` at `$XDG_STATE_HOME/tailscode/
/// flight.ring`, fed once a second from the watchdog thread so it keeps writing while the main
/// loop is stuck. Each record is one second of counts — never a title, an id, a path or a word.
final class FlightWriter: @unchecked Sendable {
    let ring: FlightRing

    init(url: URL = FlightRing.defaultURL()) throws {
        ring = try FlightRing(url: url)
    }

    /// The launch header, written first.
    func writeHeader(_ header: FlightHeader) {
        ring.write(FlightRecord.launch(header, t: FlightRecord.epochMilliseconds()))
    }

    /// One record from what the main loop published, the pressure sensor's last look and the
    /// process's counts. While the loop is silent its stale numbers would claim a calm second, so
    /// the silence itself is written instead: busy 1 and the stall as long as it has lasted.
    static func record(
        loop: LoopPublication, silence: TimeInterval, pressure: PressureSnapshot,
        counts: ProcessCounts, event: String?, now: Date = Date()
    ) -> FlightRecord {
        let silentMs = silence > 1 ? Int((silence * 1000).rounded()) : 0
        return FlightRecord(
            t: FlightRecord.epochMilliseconds(now), rss: counts.rssKiB, thr: counts.threads,
            fds: counts.fds, panes: loop.panes, lv: loop.level,
            busy: silentMs > 0 ? 1 : loop.busy, stall: max(loop.worstMs, silentMs), mb: loop.mailbox,
            dr: loop.drainP95Ms,
            ps: pressure.recorded, av: pressure.availableMB, own: pressure.ownMemory, rl: Double(loop.relayoutMs),
            ev: event)
    }

    @discardableResult
    func write(_ record: FlightRecord) -> UInt64 {
        ring.write(record)
    }

    /// `tailscode --flight [minutes]`: the ring decoded, newest last.
    static func printRing(minutes: Double?, url: URL = FlightRing.defaultURL()) -> Int32 {
        let records = FlightRing.read(url: url)
        guard !records.isEmpty else {
            print("no flight ring at \(url.path)")
            return 1
        }
        print(FlightFormatter.format(records, minutes: minutes), terminator: "")
        return 0
    }
}
