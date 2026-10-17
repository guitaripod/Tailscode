import Foundation

/// The limits the Linux app puts on its own systemd unit at launch, so a runaway is throttled and
/// then killed as one app rather than taking the desktop with it.
public struct ResourceLimitsPlan: Sendable, Equatable {
    public var memoryHigh: UInt64
    public var memoryMax: UInt64
    public var memorySwapMax: UInt64
    public var cpuWeight: UInt64
    public var tasksMax: UInt64

    /// The `(name, u64)` pairs `SetUnitProperties(unit, runtime, a(sv))` takes, every value a `t`.
    public var properties: [(name: String, value: UInt64)] {
        [
            ("MemoryHigh", memoryHigh), ("MemoryMax", memoryMax), ("MemorySwapMax", memorySwapMax),
            ("CPUWeight", cpuWeight), ("TasksMax", tasksMax),
        ]
    }

    /// The same limits as `systemctl --user set-property --runtime` arguments, the fallback when
    /// the D-Bus call cannot be made.
    public func systemctlArguments(unit: String) -> [String] {
        ["--user", "set-property", "--runtime", unit]
            + properties.map { "\($0.name)=\($0.value)" }
    }
}

public enum ResourceLimits {
    public static let gib: UInt64 = 1 << 30

    /// `MemoryHigh = clamp(10 % of RAM, 2…8 GiB)`, `MemoryMax = clamp(16 %, 3…12 GiB)`, no swap,
    /// CPU weight 60, 4096 tasks. High throttles instead of killing; max kills the app's cgroup,
    /// never the desktop; no swap stops a leak turning into swap thrash.
    public static func plan(memTotalBytes: UInt64) -> ResourceLimitsPlan {
        ResourceLimitsPlan(
            memoryHigh: clamp(fraction(memTotalBytes, 0.10), 2 * gib, 8 * gib),
            memoryMax: clamp(fraction(memTotalBytes, 0.16), 3 * gib, 12 * gib),
            memorySwapMax: 0,
            cpuWeight: 60,
            tasksMax: 4096)
    }

    private static func fraction(_ total: UInt64, _ share: Double) -> UInt64 {
        UInt64((Double(total) * share).rounded(.down))
    }

    private static func clamp(_ value: UInt64, _ low: UInt64, _ high: UInt64) -> UInt64 {
        min(max(value, low), high)
    }
}

/// The unit this process runs in, read from `/proc/self/cgroup`.
public struct CgroupUnit: Sendable, Equatable {
    public static let appID = "io.github.guitaripod.Tailscode"

    /// The cgroup path, as `/sys/fs/cgroup` + path finds the app's memory files.
    public var path: String
    /// The last path component: `app-io.github.guitaripod.Tailscode-1234.scope`.
    public var name: String

    /// Whether the unit is named the way the app's own are: `app-<appID>-<n>.scope` or `.service`
    /// (KDE's launcher scopes and the install script's relaunch) and `app-<appID>@<hash>.service`
    /// or `.scope` (the instance units a desktop launcher starts for a D-Bus activated app). A
    /// terminal launch lands in the terminal's scope, which must never be touched, so the name is
    /// the first gate and ``ResourceGuardDecision/decide`` adds the unit's membership as the second.
    public var isOwn: Bool {
        for suffix in [".scope", ".service"] where name.hasSuffix(suffix) {
            let prefix = "app-\(Self.appID)"
            guard name.hasPrefix(prefix) else { continue }
            let rest = name.dropFirst(prefix.count).dropLast(suffix.count)
            guard let separator = rest.first else { return suffix == ".service" }
            let tail = rest.dropFirst()
            guard !tail.isEmpty, tail.allSatisfy(\.isASCII) else { return false }
            switch separator {
            case "-": return tail.allSatisfy(\.isNumber)
            case "@": return tail.allSatisfy(\.isHexDigit)
            default: return false
            }
        }
        return false
    }

    public init(path: String, name: String) {
        self.path = path
        self.name = name
    }

    /// The unified-hierarchy line (`0::/…`), nil on a v1-only system or for a root cgroup.
    public static func parse(procSelfCgroup text: String) -> CgroupUnit? {
        for line in text.split(separator: "\n") where line.hasPrefix("0::") {
            let path = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            guard path != "/", let last = path.split(separator: "/").last else { return nil }
            return CgroupUnit(path: path, name: String(last))
        }
        return nil
    }
}

/// What the resource guard does at launch, decided before anything is called.
public enum ResourceGuardDecision: Sendable, Equatable {
    case apply(unit: String, plan: ResourceLimitsPlan)
    /// The process lives in somebody else's unit (a terminal's scope); the governor alone applies.
    case skipForeignScope(unit: String)
    /// An administrator already set `MemoryMax` on the unit; leave everything alone.
    case skipAdminLimited(unit: String, memoryMax: UInt64)
    /// `TAILSCODE_NO_LIMITS=1`.
    case skipOptOut
    /// No user manager to ask: no unified cgroup, or a Flatpak sandbox.
    case skipUnavailable(reason: String)

    public static let optOutVariable = "TAILSCODE_NO_LIMITS"

    /// - Parameter currentMemoryMax: the unit's `MemoryMax` as systemd reports it, `UInt64.max`
    ///   for infinity, nil when it could not be read (treated as unset). A value equal to the plan's
    ///   own is this app's earlier launch in the same unit and is applied again.
    /// - Parameter holdsProcess: whether the unit's own `cgroup.procs` lists this process. A name
    ///   alone can be borrowed by anything started in a directory that looks like the app's, and a
    ///   limit set on a unit that does not hold the process throttles somebody else; the caller
    ///   passes false when the list was read and did not name this process.
    public static func decide(
        unit: CgroupUnit?, currentMemoryMax: UInt64?, environment: [String: String],
        plan: ResourceLimitsPlan, holdsProcess: Bool = true
    ) -> ResourceGuardDecision {
        if let flag = environment[optOutVariable], !flag.isEmpty, flag != "0" { return .skipOptOut }
        if environment["FLATPAK_ID"] != nil { return .skipUnavailable(reason: "flatpak") }
        guard let unit else { return .skipUnavailable(reason: "no unified cgroup") }
        guard unit.isOwn, holdsProcess else { return .skipForeignScope(unit: unit.name) }
        if let current = currentMemoryMax, current != UInt64.max, current != plan.memoryMax {
            return .skipAdminLimited(unit: unit.name, memoryMax: current)
        }
        return .apply(unit: unit.name, plan: plan)
    }

    /// One line for `--limits` and the log.
    public var summary: String {
        switch self {
        case .apply(let unit, let plan):
            return "apply \(unit): "
                + plan.properties.map { "\($0.name)=\($0.value)" }.joined(separator: " ")
        case .skipForeignScope(let unit): return "skip: \(unit) is not this app's own unit"
        case .skipAdminLimited(let unit, let max):
            return "skip: \(unit) already has MemoryMax=\(max)"
        case .skipOptOut: return "skip: \(Self.optOutVariable)=1"
        case .skipUnavailable(let reason): return "skip: \(reason)"
        }
    }
}
