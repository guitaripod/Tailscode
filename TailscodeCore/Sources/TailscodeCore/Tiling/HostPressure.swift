import Foundation

/// How hard the whole machine is pressed for memory, not just this app.
public enum HostPressure: Int, Sendable, Comparable, Codable, CaseIterable {
    case nominal = 0
    case strained = 1
    case critical = 2

    public static func < (lhs: HostPressure, rhs: HostPressure) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// The recorder's spelling.
    public var code: String {
        switch self {
        case .nominal: return "nom"
        case .strained: return "str"
        case .critical: return "crit"
        }
    }
}

/// The machine's thermal state, in the platform's four steps. Linux reads none and reports nominal.
public enum ThermalState: Int, Sendable, Comparable, Codable, CaseIterable {
    case nominal = 0
    case fair = 1
    case serious = 2
    case critical = 3

    public static func < (lhs: ThermalState, rhs: ThermalState) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// Linux's memory pressure files, read and judged. A file that is missing or unreadable — inside a
/// Flatpak, on a kernel without PSI — reads as nothing and judges as nominal, because a sensor that
/// cannot see must never be the reason the app sheds.
public enum HostPressureReading {
    /// `/proc/pressure/memory`: the share of time some task, and every task, stalled on memory.
    public struct PSI: Sendable, Equatable {
        public var someAvg10: Double
        public var fullAvg10: Double

        public init(someAvg10: Double, fullAvg10: Double) {
            self.someAvg10 = someAvg10
            self.fullAvg10 = fullAvg10
        }
    }

    /// The two `/proc/meminfo` lines the judgement needs, in KiB.
    public struct MemInfo: Sendable, Equatable {
        public var totalKiB: UInt64
        public var availableKiB: UInt64

        public init(totalKiB: UInt64, availableKiB: UInt64) {
            self.totalKiB = totalKiB
            self.availableKiB = availableKiB
        }

        public var availableFraction: Double {
            guard totalKiB > 0 else { return 1 }
            return Double(availableKiB) / Double(totalKiB)
        }
    }

    public static let psiSomeStrained = 20.0
    public static let psiFullCritical = 5.0
    public static let availableStrained = 0.12
    public static let availableCritical = 0.06

    /// Parses `some avg10=… avg60=… avg300=… total=…` and the matching `full` line.
    public static func parse(psi text: String) -> PSI? {
        var some: Double?
        var full: Double?
        for line in text.split(separator: "\n") {
            let fields = line.split(separator: " ")
            guard let kind = fields.first else { continue }
            let avg10 = fields.dropFirst().first { $0.hasPrefix("avg10=") }
                .flatMap { Double($0.dropFirst("avg10=".count)) }
            if kind == "some" { some = avg10 }
            if kind == "full" { full = avg10 }
        }
        guard let some else { return nil }
        return PSI(someAvg10: some, fullAvg10: full ?? 0)
    }

    /// Parses `MemTotal:` and `MemAvailable:` from `/proc/meminfo`.
    public static func parse(meminfo text: String) -> MemInfo? {
        var total: UInt64?
        var available: UInt64?
        for line in text.split(separator: "\n") {
            if line.hasPrefix("MemTotal:") { total = kib(line) }
            if line.hasPrefix("MemAvailable:") { available = kib(line) }
            if total != nil, available != nil { break }
        }
        guard let total, let available else { return nil }
        return MemInfo(totalKiB: total, availableKiB: available)
    }

    /// The worse of the two judgements: PSI `some avg10 ≥ 20` strained, `full avg10 ≥ 5`
    /// critical; available memory under 12 % strained, under 6 % critical.
    public static func classify(psi: PSI?, meminfo: MemInfo?) -> HostPressure {
        var pressure = HostPressure.nominal
        if let psi {
            if psi.fullAvg10 >= psiFullCritical {
                pressure = .critical
            } else if psi.someAvg10 >= psiSomeStrained {
                pressure = .strained
            }
        }
        if let meminfo, meminfo.totalKiB > 0 {
            let fraction = meminfo.availableFraction
            if fraction < availableCritical {
                pressure = max(pressure, .critical)
            } else if fraction < availableStrained {
                pressure = max(pressure, .strained)
            }
        }
        return pressure
    }

    /// Both files as text, either missing.
    public static func classify(psiText: String?, meminfoText: String?) -> HostPressure {
        classify(psi: psiText.flatMap { parse(psi: $0) }, meminfo: meminfoText.flatMap { parse(meminfo: $0) })
    }

    private static func kib(_ line: Substring) -> UInt64? {
        line.split(separator: " ").dropFirst().first.flatMap { UInt64($0) }
    }
}

/// The app's own memory as a share of the limit it lives under.
public enum OwnMemory {
    /// `current / high`, nil when either is unknown or the limit is unset.
    public static func ratio(current: UInt64?, high: UInt64?) -> Double? {
        guard let current, let high, high > 0 else { return nil }
        return Double(current) / Double(high)
    }

    /// A cgroup memory file's value: a byte count, or nil for `max` and anything unreadable.
    public static func parse(cgroupValue text: String) -> UInt64? {
        UInt64(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Resident bytes from `/proc/self/statm` (its second field, in pages).
    public static func parse(statm text: String, pageSize: UInt64) -> UInt64? {
        let fields = text.split(separator: " ")
        guard fields.count >= 2, let pages = UInt64(fields[1]) else { return nil }
        return pages * pageSize
    }

    /// The limit a process without a cgroup limit is measured against: the `MemoryHigh` it would
    /// have been given, so the floors mean the same thing with and without systemd.
    public static func fallbackHigh(memTotalBytes: UInt64) -> UInt64 {
        ResourceLimits.plan(memTotalBytes: memTotalBytes).memoryHigh
    }

    /// The Mac's limit: `min(8 GiB, 0.15 × physical)`.
    public static func appleHigh(physicalBytes: UInt64) -> UInt64 {
        min(8 * ResourceLimits.gib, UInt64(Double(physicalBytes) * 0.15))
    }
}
