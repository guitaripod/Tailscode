import Foundation
import Testing
@testable import TailscodeCore

@Suite("Resource limits plan")
struct TileResourceLimitsTests {
    private let gib = ResourceLimits.gib

    @Test("The clamp arithmetic for 8, 16, 62 and 256 GiB", arguments: [
        (UInt64(8), UInt64(2 << 30), UInt64(3 << 30)),
        (16, 2 << 30, 3 << 30),
        (62, 6_657_199_308, 10_651_518_894),
        (256, 8 << 30, 12 << 30),
    ])
    func clamp(totalGiB: UInt64, high: UInt64, max: UInt64) {
        let plan = ResourceLimits.plan(memTotalBytes: totalGiB * gib)
        #expect(plan.memoryHigh == high)
        #expect(plan.memoryMax == max)
        #expect(plan.memorySwapMax == 0)
        #expect(plan.cpuWeight == 60)
        #expect(plan.tasksMax == 4096)
    }

    @Test("The property list is what SetUnitProperties takes, every value a u64")
    func properties() {
        let plan = ResourceLimits.plan(memTotalBytes: 62 * gib)
        #expect(plan.properties.map(\.name) == ["MemoryHigh", "MemoryMax", "MemorySwapMax", "CPUWeight", "TasksMax"])
        #expect(plan.properties.map(\.value) == [plan.memoryHigh, plan.memoryMax, 0, 60, 4096])
        #expect(
            plan.systemctlArguments(unit: "u.scope")
                == ["--user", "set-property", "--runtime", "u.scope", "MemoryHigh=\(plan.memoryHigh)",
                    "MemoryMax=\(plan.memoryMax)", "MemorySwapMax=0", "CPUWeight=60", "TasksMax=4096"])
    }

    @Test("The unit is read from the unified line and recognised only when it is the app's own")
    func unitParse() throws {
        let own = try #require(CgroupUnit.parse(procSelfCgroup: """
            0::/user.slice/user-1000.slice/user@1000.service/app.slice/app-io.github.guitaripod.Tailscode-48211.scope

            """))
        #expect(own.name == "app-io.github.guitaripod.Tailscode-48211.scope")
        #expect(own.path.hasPrefix("/user.slice/"))
        #expect(own.isOwn)
        #expect(CgroupUnit(path: "/", name: "app-io.github.guitaripod.Tailscode-7.service").isOwn)
        for foreign in [
            "app-org.kde.konsole-1234.scope", "app-io.github.guitaripod.Tailscode-.scope",
            "app-io.github.guitaripod.Tailscode-12a.scope", "app-io.github.guitaripod.Tailscode-12.slice",
            "vte-spawn-1234.scope", "app-flatpak-io.github.guitaripod.Tailscode-99.scope",
        ] {
            #expect(!CgroupUnit(path: "/x/" + foreign, name: foreign).isOwn, "\(foreign)")
        }
        #expect(CgroupUnit.parse(procSelfCgroup: "12:memory:/foo\n") == nil)
        #expect(CgroupUnit.parse(procSelfCgroup: "0::/\n") == nil)
    }

    @Test("The guard's decision table")
    func decisions() {
        let plan = ResourceLimits.plan(memTotalBytes: 62 * gib)
        let own = CgroupUnit(path: "/a/app-io.github.guitaripod.Tailscode-1.scope", name: "app-io.github.guitaripod.Tailscode-1.scope")
        let terminal = CgroupUnit(path: "/a/vte-spawn-1.scope", name: "vte-spawn-1.scope")
        #expect(
            ResourceGuardDecision.decide(unit: own, currentMemoryMax: .max, environment: [:], plan: plan)
                == .apply(unit: own.name, plan: plan))
        #expect(
            ResourceGuardDecision.decide(unit: own, currentMemoryMax: nil, environment: [:], plan: plan)
                == .apply(unit: own.name, plan: plan))
        #expect(
            ResourceGuardDecision.decide(unit: own, currentMemoryMax: plan.memoryMax, environment: [:], plan: plan)
                == .apply(unit: own.name, plan: plan))
        #expect(
            ResourceGuardDecision.decide(unit: own, currentMemoryMax: 4 * gib, environment: [:], plan: plan)
                == .skipAdminLimited(unit: own.name, memoryMax: 4 * gib))
        #expect(
            ResourceGuardDecision.decide(unit: terminal, currentMemoryMax: .max, environment: [:], plan: plan)
                == .skipForeignScope(unit: terminal.name))
        #expect(
            ResourceGuardDecision.decide(unit: own, currentMemoryMax: .max, environment: ["TAILSCODE_NO_LIMITS": "1"], plan: plan)
                == .skipOptOut)
        #expect(
            ResourceGuardDecision.decide(unit: own, currentMemoryMax: .max, environment: ["TAILSCODE_NO_LIMITS": "0"], plan: plan)
                == .apply(unit: own.name, plan: plan))
        #expect(
            ResourceGuardDecision.decide(unit: own, currentMemoryMax: .max, environment: ["FLATPAK_ID": "x"], plan: plan)
                == .skipUnavailable(reason: "flatpak"))
        #expect(
            ResourceGuardDecision.decide(unit: nil, currentMemoryMax: nil, environment: [:], plan: plan)
                == .skipUnavailable(reason: "no unified cgroup"))
        #expect(ResourceGuardDecision.skipOptOut.summary.contains("TAILSCODE_NO_LIMITS"))
        #expect(ResourceGuardDecision.apply(unit: "u", plan: plan).summary.contains("MemorySwapMax=0"))
    }
}

extension ResourceLimitsPlan: CustomTestStringConvertible {
    public var testDescription: String { "high \(memoryHigh) max \(memoryMax)" }
}
