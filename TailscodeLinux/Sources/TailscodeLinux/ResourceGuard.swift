import CGtkShim
import Foundation
import TailscodeCore

/// The limits the app puts on its own systemd unit at launch, so a runaway is throttled and then
/// killed as one app instead of freezing the desktop it runs on.
///
/// Only a unit the app owns is touched — `app-io.github.guitaripod.Tailscode-<n>.scope` or
/// `.service`, which is what KDE's launcher and the install script start it in. A terminal launch
/// lives in the terminal's scope and is left alone, as is a unit an administrator already capped;
/// the in-process governor still applies to both. The decision is Core's; this reads the files it
/// needs and makes the call.
enum ResourceGuard {
    enum Method: String, Sendable {
        case dbus
        case systemctl
    }

    struct Outcome: Sendable {
        let decision: ResourceGuardDecision
        let method: Method?
        let failure: String?
        /// `memory.max` read back after applying, so a call that answered but changed nothing is
        /// not mistaken for one that worked.
        let memoryMaxAfter: String?

        /// The flight header's short code.
        var code: String {
            switch decision {
            case .apply: return method?.rawValue ?? "failed"
            case .skipForeignScope: return "skip-foreign"
            case .skipAdminLimited: return "skip-admin"
            case .skipOptOut: return "skip-optout"
            case .skipUnavailable(let reason): return reason == "flatpak" ? "skip-flatpak" : "skip-none"
            }
        }

        var line: String {
            var text = decision.summary
            if case .apply = decision {
                if let method { text += " · applied via \(method.rawValue)" }
                if let failure { text += " · failed: \(failure)" }
                if let memoryMaxAfter { text += " · memory.max now \(memoryMaxAfter)" }
            }
            return text
        }
    }

    /// What this launch did, once ``apply()`` has run.
    nonisolated(unsafe) static var outcome: Outcome?

    /// The decision from the files as text, so the selftest can put any cgroup name through it.
    static func decide(
        procSelfCgroup: String?, memoryMax: String?, memTotalBytes: UInt64,
        environment: [String: String]
    ) -> ResourceGuardDecision {
        ResourceGuardDecision.decide(
            unit: procSelfCgroup.flatMap { CgroupUnit.parse(procSelfCgroup: $0) },
            currentMemoryMax: memoryMax.flatMap(parseMax), environment: environment,
            plan: ResourceLimits.plan(memTotalBytes: memTotalBytes))
    }

    /// A cgroup limit file: `max` is no limit at all, a number is bytes, anything else unknown.
    static func parseMax(_ text: String) -> UInt64? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed == "max" ? UInt64.max : UInt64(trimmed)
    }

    /// Decides and applies, once per process, and logs what happened.
    @discardableResult
    static func apply(environment: [String: String] = ProcessInfo.processInfo.environment) -> Outcome {
        if let outcome { return outcome }
        let cgroup = ProcFile.read("/proc/self/cgroup")
        let unit = cgroup.flatMap { CgroupUnit.parse(procSelfCgroup: $0) }
        let directory = unit.map { "/sys/fs/cgroup" + $0.path }
        let memTotal =
            ProcFile.read("/proc/meminfo").flatMap { HostPressureReading.parse(meminfo: $0) }
            .map { $0.totalKiB * 1024 } ?? 0
        let decision = decide(
            procSelfCgroup: cgroup, memoryMax: directory.flatMap { ProcFile.read($0 + "/memory.max") },
            memTotalBytes: memTotal, environment: environment)
        var method: Method?
        var failure: String?
        if case .apply(let unitName, let plan) = decision {
            switch setOverBus(unit: unitName, plan: plan) {
            case nil: method = .dbus
            case let busFailure?:
                if let spawnFailure = setWithSystemctl(unit: unitName, plan: plan) {
                    failure = "\(busFailure); \(spawnFailure)"
                } else {
                    method = .systemctl
                }
            }
        }
        let after = directory.flatMap { ProcFile.read($0 + "/memory.max") }?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let result = Outcome(
            decision: decision, method: method, failure: failure,
            memoryMaxAfter: method == nil ? nil : after)
        outcome = result
        AppLog.write(.lifecycle, "resource guard: \(result.line)")
        return result
    }

    /// `SetUnitProperties` over the session bus; nil when it answered.
    private static func setOverBus(unit: String, plan: ResourceLimitsPlan) -> String? {
        let properties = plan.properties
        let names = properties.map { strdup($0.name) }
        defer { names.forEach { free($0) } }
        let values = properties.map { guint64($0.value) }
        var error: UnsafeMutablePointer<CChar>?
        let pointers = names.map { UnsafePointer<CChar>($0) }
        let ok = pointers.withUnsafeBufferPointer { namesBuffer in
            values.withUnsafeBufferPointer { valuesBuffer in
                tailscode_systemd_set_unit_properties(
                    unit, namesBuffer.baseAddress, valuesBuffer.baseAddress, Int32(properties.count),
                    &error)
            }
        }
        if ok != 0 { return nil }
        let message = error.map { String(cString: $0) } ?? "D-Bus call failed"
        g_free(error)
        return message
    }

    /// The fallback the user manager also answers: `systemctl --user set-property --runtime`.
    private static func setWithSystemctl(unit: String, plan: ResourceLimitsPlan) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["systemctl"] + plan.systemctlArguments(unit: unit)
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        do {
            try process.run()
        } catch {
            return "systemctl: \(error.localizedDescription)"
        }
        process.waitUntilExit()
        guard process.terminationStatus != 0 else { return nil }
        let text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return "systemctl exited \(process.terminationStatus): "
            + text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(160)
    }

    /// `tailscode --limits`: applies, then says what was applied and why.
    static func printLimits() -> Int32 {
        let result = apply()
        print("resource guard: \(result.line)")
        if let directory = ProcFile.read("/proc/self/cgroup")
            .flatMap({ CgroupUnit.parse(procSelfCgroup: $0) }).map({ "/sys/fs/cgroup" + $0.path })
        {
            for file in ["memory.high", "memory.max", "memory.swap.max", "cpu.weight", "pids.max"] {
                let value = ProcFile.read(directory + "/" + file)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unreadable"
                print("  \(file) = \(value)")
            }
        }
        return result.failure == nil ? 0 : 1
    }
}
