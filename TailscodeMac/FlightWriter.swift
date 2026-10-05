import AppKit
import Darwin
import Foundation
import TailscodeCore

/// The Mac's hand on the black box: Core's `FlightRing` written from a serial utility queue, so a
/// record's `F_FULLFSYNC` never lands on the main thread, and read back by `--flight`.
///
/// Records are counts and durations only (the ring has no field that could hold anything else).
/// The ring is `~/Library/Logs/Tailscode/flight.ring`; the store build is sandboxed, so the same
/// call resolves inside its container and needs no entitlement.
final class FlightWriter: @unchecked Sendable {
    let ring: FlightRing
    private let queue = DispatchQueue(label: "tailscode.flight", qos: .utility)

    init(url: URL = FlightRing.defaultURL()) throws {
        ring = try FlightRing(url: url)
    }

    var url: URL { ring.url }

    /// Queues a record for its slot; the ring numbers it and syncs it before the next one.
    func write(_ record: FlightRecord) {
        queue.async { [ring] in ring.write(record) }
    }

    /// Writes a record and waits for it to reach the disk: the last thing a quitting app does.
    func writeNow(_ record: FlightRecord) {
        queue.sync { [ring] in _ = ring.write(record) }
    }

    /// Waits until everything queued is on the disk.
    func drain() {
        queue.sync {}
    }

    /// The launch record: the app's version and build flavour, the macOS version, and `n/a` where
    /// Linux names its GSK renderer — AppKit has one renderer and nothing to tell apart.
    static func header() -> FlightHeader {
        let bundle = Bundle.main
        let short = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        #if TAILSCODE_MAS
            let flavour = "store"
        #else
            let flavour = "direct"
        #endif
        let version = [short, build.map { "(\($0))" }, flavour].compactMap { $0 }.joined(separator: " ")
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let toolkit = "AppKit macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        return FlightHeader(version: version, toolkit: toolkit, renderer: "n/a")
    }

    /// Threads and open descriptors of this process, from `proc_pidinfo` on its own pid, which a
    /// sandbox allows.
    static func processCounts() -> (threads: Int?, fds: Int?) {
        let pid = getpid()
        var task = proc_taskinfo()
        let taskSize = Int32(MemoryLayout<proc_taskinfo>.size)
        let threads =
            proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &task, taskSize) == taskSize
            ? Int(task.pti_threadnum) : nil
        let listed = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        var fds: Int?
        if listed > 0 {
            let capacity = Int(listed) / MemoryLayout<proc_fdinfo>.size + 16
            var buffer = [proc_fdinfo](repeating: proc_fdinfo(), count: capacity)
            let used = buffer.withUnsafeMutableBytes {
                proc_pidinfo(pid, PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
            }
            if used >= 0 { fds = Int(used) / MemoryLayout<proc_fdinfo>.size }
        }
        return (threads, fds)
    }

    /// `TailscodeMac --flight [minutes]`: the ring decoded, newest last.
    static func printRing(arguments: [String] = CommandLine.arguments) -> Never {
        var minutes: Double?
        if let index = arguments.firstIndex(of: "--flight"), index + 1 < arguments.count {
            minutes = Double(arguments[index + 1])
        }
        let url = FlightRing.defaultURL()
        let records = FlightRing.read(url: url)
        if records.isEmpty {
            print("no flight records at \(url.path)")
            exit(0)
        }
        print(FlightFormatter.format(records, minutes: minutes), terminator: "")
        exit(0)
    }
}
