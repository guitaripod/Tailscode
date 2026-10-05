import Foundation
import Glibc
import TailscodeCore

/// Reads a small kernel file whole. `/proc` and `/sys` files report a size of zero, so they are read
/// until the end rather than to a length asked of `stat`; anything missing or unreadable is nil.
enum ProcFile {
    static func read(_ path: String, limit: Int = 64 * 1024) -> String? {
        let descriptor = open(path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { return nil }
        defer { close(descriptor) }
        var bytes: [UInt8] = []
        var chunk = [UInt8](repeating: 0, count: 4096)
        while bytes.count < limit {
            let count = chunk.withUnsafeMutableBytes { Glibc.read(descriptor, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { break }
            bytes.append(contentsOf: chunk[0..<count])
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// How many entries a directory holds, without building a name for any of them.
    static func entryCount(_ path: String) -> Int? {
        guard let directory = opendir(path) else { return nil }
        defer { closedir(directory) }
        var count = 0
        while let entry = readdir(directory) {
            let name = entry.pointee.d_name
            let dot = withUnsafeBytes(of: name) { raw -> Bool in
                raw[0] == 0x2E && (raw[1] == 0 || (raw[1] == 0x2E && raw[2] == 0))
            }
            if !dot { count += 1 }
        }
        return count
    }
}

/// What the machine's memory looks like this second, and the app's own share of its limit.
struct PressureSnapshot: Sendable, Equatable {
    var host: HostPressure = .nominal
    /// PSI `some/full` avg10 as the recorder writes it; nil without `/proc/pressure`.
    var psi: String?
    var availableMB: Int?
    var ownMemory: Double?
    /// The host pressure came from the `pressure=` drive verb, not the kernel.
    var injected = false

    /// The recorder's `ps` field: the kernel's numbers, or the injected word.
    var recorded: String? {
        injected ? "inj \(host.code)" : psi
    }
}

/// The host-pressure and own-memory sensor, sampled once a second on the watchdog thread and read
/// by the governor on the main loop. A file that is missing — a kernel without PSI, a Flatpak
/// sandbox, a cgroup v1 box — reads as nominal, because a sensor that cannot see must never be the
/// reason the app sheds.
final class PressureSensor: @unchecked Sendable {
    private let lock = NSLock()
    private var latest = PressureSnapshot()
    private var injected: HostPressure?
    private let cgroupDirectory: String?
    private let pageSize = UInt64(sysconf(Int32(_SC_PAGESIZE)))

    init(procSelfCgroup: String? = ProcFile.read("/proc/self/cgroup")) {
        cgroupDirectory = procSelfCgroup.flatMap { CgroupUnit.parse(procSelfCgroup: $0) }
            .map { "/sys/fs/cgroup" + $0.path }
    }

    var snapshot: PressureSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return latest
    }

    /// Overrides the kernel's verdict until cleared; `nominal` clears it, so the drive verb that set
    /// a pressure is also the one that takes it away.
    func inject(_ pressure: HostPressure) {
        lock.lock()
        injected = pressure == .nominal ? nil : pressure
        if let injected {
            latest.host = injected
            latest.injected = true
        } else {
            latest.injected = false
        }
        lock.unlock()
    }

    /// Reads every file once and publishes the result. Watchdog thread.
    @discardableResult
    func sample() -> PressureSnapshot {
        let psiText = ProcFile.read("/proc/pressure/memory")
        let meminfoText = ProcFile.read("/proc/meminfo")
        let psi = psiText.flatMap { HostPressureReading.parse(psi: $0) }
        let meminfo = meminfoText.flatMap { HostPressureReading.parse(meminfo: $0) }
        var next = PressureSnapshot()
        next.host = HostPressureReading.classify(psi: psi, meminfo: meminfo)
        next.psi = psi.map { String(format: "%.1f/%.1f", $0.someAvg10, $0.fullAvg10) }
        next.availableMB = meminfo.map { Int($0.availableKiB / 1024) }
        next.ownMemory = ownMemory(memTotalKiB: meminfo?.totalKiB)
        lock.lock()
        if let injected {
            next.host = injected
            next.injected = true
        }
        latest = next
        lock.unlock()
        return next
    }

    /// The cgroup's `memory.current` over its `memory.high` when the unit has a high limit; else
    /// this process's resident set over the high limit it would have been given, so the governor's
    /// floors mean the same thing with and without systemd.
    private func ownMemory(memTotalKiB: UInt64?) -> Double? {
        if let directory = cgroupDirectory,
            let high = ProcFile.read(directory + "/memory.high").flatMap(OwnMemory.parse(cgroupValue:)),
            let current = ProcFile.read(directory + "/memory.current").flatMap(OwnMemory.parse(cgroupValue:))
        {
            return OwnMemory.ratio(current: current, high: high)
        }
        guard let memTotalKiB,
            let resident = ProcFile.read("/proc/self/statm").flatMap({ OwnMemory.parse(statm: $0, pageSize: pageSize) })
        else { return nil }
        return OwnMemory.ratio(current: resident, high: OwnMemory.fallbackHigh(memTotalBytes: memTotalKiB * 1024))
    }
}
