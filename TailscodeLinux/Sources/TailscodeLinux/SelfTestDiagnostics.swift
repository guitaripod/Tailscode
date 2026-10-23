import CAdw
import CGtkShim
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension SelfTest {
    /// The recorder's Linux half: the writer's records built from this process's real counts and a
    /// real pressure sample, written to a scratch ring, read back across a reopen, and printed.
    static func checkFlight() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("flight: \(label)") }
            checks += 1
        }
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tailscode-flight-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("flight.ring")
        let counts = ProcessCounts.read()
        try expect((counts.rssKiB ?? 0) > 0, "resident memory is read")
        try expect((counts.threads ?? 0) > 0, "threads are counted")
        try expect((counts.fds ?? 0) > 2, "descriptors are counted")
        try expect(
            ProcessCounts.threads(stat: "42 (a b) c) S 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 7 0") == 7,
            "a command name with spaces and parentheses does not shift the fields")
        let pressure = PressureSensor().sample()
        try expect(pressure.availableMB.map { $0 > 0 } ?? true, "available memory is in MB")
        let main = MainThreadState.parse(
            stat: "42 (tail scode) R 1 2 3 4 5 6 7 8 9 10 300 12 0 0", wchan: "0\n")
        try expect(main == MainThreadState(state: "R", ticks: 312, wchan: "0"), "main thread state")
        try expect(main?.line == "R 0 cpu=312", "the kernel function leads the event's tail")
        try expect(MainThreadState.read() != nil, "this process's main thread reads")

        let writer = try FlightWriter(url: url)
        writer.writeHeader(
            FlightHeader(
                version: TailscodeVersion.current, toolkit: "gtk 4.22.1 adw 1.8",
                renderer: "GskNglRenderer", glVendor: "Mesa", limits: "skip-foreign"))
        let calm = LoopPublication(
            busy: 0.21, worstMs: 37, level: 1, panes: FlightPanes(full: 2, glance: 0, parked: 1))
        writer.write(
            FlightWriter.record(
                loop: calm, silence: 0.2, pressure: pressure, counts: counts, event: nil))
        writer.write(
            FlightWriter.record(
                loop: calm, silence: 3.4, pressure: pressure, counts: counts,
                event: "stall 3400ms R 0 cpu=812"))
        let reopened = try FlightWriter(url: url)
        reopened.write(
            FlightWriter.record(
                loop: calm, silence: 0, pressure: pressure, counts: counts, event: "exit clean"))
        let records = FlightRing.read(url: url)
        try expect(records.map(\.n) == [1, 2, 3, 4], "numbers carry on across a reopen")
        try expect(records.first?.header?.limits == "skip-foreign", "the header keeps the limits code")
        try expect(records.first?.header?.renderer == "GskNglRenderer", "the header names the renderer")
        try expect(
            records[1].busy == 0.21 && records[1].stall == 37 && records[1].lv == 1
                && records[1].panes == FlightPanes(full: 2, glance: 0, parked: 1),
            "a calm second carries the loop's own numbers")
        try expect(
            records[2].busy == 1 && records[2].stall == 3400,
            "a silent loop is written as the silence, not its stale numbers")
        try expect(records[1].mb == 0 && records[1].rl == 0, "mailbox and relayout read zero until built")
        try expect(records.last?.ev == "exit clean", "a clean exit is the last word")
        let text = FlightFormatter.format(records)
        try expect(text.contains("limits skip-foreign") && text.contains("exit clean"), "--flight prints it")
        let raw = try Data(contentsOf: url)
        try expect(raw.count == FlightRing.slotCount * FlightRecord.slotSize, "the ring is its fixed size")
        return checks
    }

    /// The guard's decision for the units a launch can land in, from the files as text.
    static func checkResourceGuard() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("resource guard: \(label)") }
            checks += 1
        }
        let slice = "0::/user.slice/user-1000.slice/user@1000.service/app.slice/"
        let total: UInt64 = 62 * ResourceLimits.gib
        let plan = ResourceLimits.plan(memTotalBytes: total)
        func decide(
            _ unit: String?, max: String? = "max", env: [String: String] = [:], procs: String? = nil,
            pid: Int32 = getpid()
        ) -> ResourceGuardDecision {
            ResourceGuard.decide(
                procSelfCgroup: unit.map { $0.hasPrefix("0::") ? $0 : slice + $0 + "\n" },
                memoryMax: max, memTotalBytes: total, environment: env, procs: procs, pid: pid)
        }
        let scope = "app-io.github.guitaripod.Tailscode-1234.scope"
        try expect(decide(scope) == .apply(unit: scope, plan: plan), "the launcher's scope is limited")
        let service = "app-io.github.guitaripod.Tailscode-77.service"
        try expect(decide(service) == .apply(unit: service, plan: plan), "a service is limited")
        let instance = "app-io.github.guitaripod.Tailscode@c3bde4b1845c46d69b6bcec0aaba9e0c.service"
        try expect(
            decide(instance) == .apply(unit: instance, plan: plan), "the launcher's instance service is limited")
        try expect(
            decide(instance, procs: "4242\n4243\n", pid: 4242) == .apply(unit: instance, plan: plan),
            "an instance service that lists this process is limited")
        try expect(
            decide(instance, procs: "4243\n", pid: 4242) == .skipForeignScope(unit: instance),
            "an instance service that does not list this process is foreign")
        try expect(
            decide("app-io.github.guitaripod.Tailscode@zz.service")
                == .skipForeignScope(unit: "app-io.github.guitaripod.Tailscode@zz.service"),
            "an instance whose name is not a hash is foreign")
        try expect(
            ResourceGuard.holds(procs: nil, pid: 7) && !ResourceGuard.holds(procs: "", pid: 7),
            "an unreadable list is no evidence, an empty one is")
        try expect(
            decide("app-ghostty-surface-transient-14171.scope")
                == .skipForeignScope(unit: "app-ghostty-surface-transient-14171.scope"),
            "a terminal's scope is never touched")
        try expect(
            decide("app-io.github.guitaripod.Tailscode-abc.scope")
                == .skipForeignScope(unit: "app-io.github.guitaripod.Tailscode-abc.scope"),
            "a scope that only looks like the app's is foreign")
        try expect(
            decide("run-r3f2.scope") == .skipForeignScope(unit: "run-r3f2.scope"),
            "a systemd-run scope is foreign")
        try expect(
            decide(scope, max: "4294967296\n") == .skipAdminLimited(unit: scope, memoryMax: 4_294_967_296),
            "an administrator's MemoryMax is left alone")
        try expect(
            decide(scope, max: "\(plan.memoryMax)") == .apply(unit: scope, plan: plan),
            "this app's own earlier limit is applied again")
        try expect(decide(scope, max: nil) == .apply(unit: scope, plan: plan), "an unreadable limit is unset")
        try expect(
            decide(scope, env: ["TAILSCODE_NO_LIMITS": "1"]) == .skipOptOut, "TAILSCODE_NO_LIMITS opts out")
        try expect(
            decide(scope, env: ["TAILSCODE_NO_LIMITS": "0"]) == .apply(unit: scope, plan: plan),
            "TAILSCODE_NO_LIMITS=0 does not opt out")
        try expect(
            decide(scope, env: ["FLATPAK_ID": "io.github.guitaripod.Tailscode"])
                == .skipUnavailable(reason: "flatpak"), "Flatpak cannot reach the user manager")
        try expect(
            decide(nil) == .skipUnavailable(reason: "no unified cgroup"), "no cgroup file")
        try expect(
            decide("0::/\n") == .skipUnavailable(reason: "no unified cgroup"), "the root cgroup")
        try expect(ResourceGuard.parseMax("max\n") == UInt64.max, "max reads as no limit")
        try expect(ResourceGuard.parseMax("12") == 12 && ResourceGuard.parseMax("x") == nil, "bytes or unknown")
        let codes = [
            ResourceGuard.Outcome(
                decision: .apply(unit: scope, plan: plan), method: .dbus, failure: nil,
                memoryMaxAfter: nil),
            ResourceGuard.Outcome(
                decision: .apply(unit: scope, plan: plan), method: nil, failure: "denied",
                memoryMaxAfter: nil),
            ResourceGuard.Outcome(
                decision: .skipForeignScope(unit: "x"), method: nil, failure: nil, memoryMaxAfter: nil),
        ].map(\.code)
        try expect(codes == ["dbus", "failed", "skip-foreign"], "the header's codes")
        try expect(codes.allSatisfy { $0.count <= FlightHeader.limitsWidth }, "every code fits the header")
        return checks
    }

    /// The watchdog's stack sample of a thread that is busy, and the gate the background polls wait
    /// at: a spinning thread answers with frames inside this binary, and a poll parked on a hidden
    /// window is released by the window becoming visible and by its own cancellation.
    static func checkSelfDiagnosis() async throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("self-diagnosis: \(label)") }
            checks += 1
        }
        let spin = SpinningThread()
        spin.start()
        defer { spin.stop() }
        try expect(spin.waitUntilInstalled(), "the sampler installs on the thread to sample")
        var frames: [String] = []
        for _ in 0..<5 where frames.isEmpty {
            var addresses = [UInt](repeating: 0, count: Int(TAILSCODE_STACK_DEPTH))
            let count = addresses.withUnsafeMutableBufferPointer {
                tailscode_stack_sample_main(500, $0.baseAddress, Int32($0.count))
            }
            for index in 0..<max(0, Int(count)) {
                var module = [CChar](repeating: 0, count: 96)
                var offset: UInt64 = 0
                _ = tailscode_stack_resolve(addresses[index], &module, module.count, &offset)
                frames.append(StackReport.frame(module: String(cString: module), offset: offset))
            }
        }
        try expect(frames.count >= 3, "a spinning thread answers with its stack")
        try expect(
            frames.allSatisfy { StackReport.parseFrame(Substring($0)) != nil }, "every frame reads back")
        try expect(!frames.contains { $0.hasPrefix("?+") }, "every frame names its module")

        let gate = BackgroundGate()
        gate.setVisible(false)
        try expect(!gate.isVisible, "the gate closes with the window")
        let released = Task { await gate.untilVisible() }
        try await Task.sleep(for: .milliseconds(50))
        gate.setVisible(true)
        await released.value
        try expect(gate.isVisible, "the window becoming visible releases a parked poll")
        gate.setVisible(false)
        let cancelled = Task { await gate.untilVisible() }
        try await Task.sleep(for: .milliseconds(50))
        cancelled.cancel()
        await cancelled.value
        try expect(!gate.isVisible, "a cancelled poll is released while the window is hidden")
        var owed = 0
        gate.onShown { owed += 1 }
        gate.setVisible(true)
        gate.setVisible(true)
        try expect(owed == 1, "the redraw owed to a hidden window runs once when it is seen")
        gate.setLevel(.strained)
        try expect(gate.shedLevel == .strained, "the gate holds the level it is told")
        return checks
    }

    /// The launch ledger through four launches in a scratch directory, and the staggered wake.
    static func checkRestorePlan() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("safe restore: \(label)") }
            checks += 1
        }
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tailscode-ledger-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("launch.json")

        let first = LaunchLedger.begin(url: url, panes: 5)
        let firstPlan = RestorePlan.decide(ledger: first.previous, paneCount: 5)
        try expect(firstPlan.mode == .staggered && !firstPlan.unclean, "a first launch restores staggered")
        let second = LaunchLedger.begin(url: url, panes: 5)
        let secondPlan = RestorePlan.decide(ledger: second.previous, paneCount: 5)
        try expect(secondPlan.mode == .parked(bannerCount: 5), "an unclean exit with five panes parks them")
        try expect(secondPlan.floor == nil, "one unclean exit sets no floor")
        try expect(
            secondPlan.bannerText == Localized.text(
                "Tailscode didn't close normally last time. %@ chats are paused.", "5"),
            "the banner counts the paused chats")
        let third = LaunchLedger.begin(url: url, panes: 2)
        let thirdPlan = RestorePlan.decide(ledger: third.previous, paneCount: 2)
        try expect(thirdPlan.mode == .staggered && thirdPlan.unclean, "two panes restore staggered even unclean")
        try expect(
            thirdPlan.floor == .loaded && thirdPlan.floorDuration == 600,
            "a second unclean exit in a row floors the level at 2 for ten minutes")
        LaunchLedger.markClean(url: url, launchID: third.current.launchID, panes: 4, level: 1)
        try expect(LaunchLedger.read(url: url)?.cleanExit == true, "a clean exit flips the ledger")
        LaunchLedger.markClean(url: url, launchID: "someone else", panes: 9)
        try expect(LaunchLedger.read(url: url)?.panes == 4, "another launch's id leaves the ledger alone")
        let fourth = LaunchLedger.begin(url: url, panes: 6)
        let fourthPlan = RestorePlan.decide(ledger: fourth.previous, paneCount: 6)
        try expect(fourthPlan.mode == .staggered && fourthPlan.floor == nil, "after a clean exit, staggered")

        var layout = SplitLayout()
        let a = layout.focusedPane
        guard let b = layout.split(a, axis: .horizontal), let c = layout.split(b, axis: .vertical) else {
            throw SelfTestFailure("safe restore: the layout would not split")
        }
        layout.focus(a)
        layout.focus(b)
        var wake = RestoreWake(layout: layout)
        try expect(wake.take(now: 0) == .idle, "nothing ready, nothing wakes")
        wake.markReady(c)
        wake.markReady(a)
        wake.markReady(b)
        try expect(wake.take(now: 10) == .wake(b), "the focused pane wakes first")
        if case .wait(let delay) = wake.take(now: 10.1) {
            try expect(abs(delay - 0.2) < 1e-6, "the next waits out the spacing")
        } else {
            try expect(false, "the next waits out the spacing")
        }
        try expect(wake.take(now: 10.3) == .wake(a), "then the most recently focused")
        try expect(wake.take(now: 10.65) == .wake(c), "then the rest")
        try expect(wake.take(now: 20) == .idle && !wake.isWaiting, "and then nothing")
        var late = RestoreWake(layout: layout)
        late.markReady(c)
        try expect(late.take(now: 0) == .wake(c), "a ready pane never waits on one that is not")
        return checks
    }

    static func checkParity() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("parity: \(label)") }
            checks += 1
        }
        try expect(
            CapabilityRegistry.missingDefinitions.isEmpty, "every capability has a spec")
        for capability in AppCapability.allCases {
            switch ParityManifest.evidence(for: capability) {
            case .implemented(let anchor):
                try expect(!anchor.isEmpty, "\(capability.rawValue) names its anchor")
            case .partial(let anchor, let missing):
                try expect(
                    !anchor.isEmpty && !missing.isEmpty,
                    "\(capability.rawValue) names its anchor and its debt")
            case .gap(let reason), .notApplicable(let reason):
                try expect(!reason.isEmpty, "\(capability.rawValue) states its reason")
            case .varies:
                try expect(false, "\(capability.rawValue) resolves to one answer for this copy")
            }
        }
        return checks
    }

    /// The prepaid balance's own claims, proved without a network: the snapshot carries money and
    /// no cap, an empty account reads as the wall it is, and the renderer's recognition — `usedUSD`
    /// with no `limitUSD` — is what the quota surfaces skip bars for.
    static func checkDeepSeekBalance() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("deepseek balance: \(label)") }
            checks += 1
        }
        let topped = DeepSeekBalance.snapshot(
            for: DeepSeekBalance.Reading(
                total: 13.42, toppedUp: 11.0, granted: 2.42, currency: "CNY",
                isAvailable: true))
        let gauge = try requireOne(topped.gauges)
        try expect(gauge.usedUSD == 13.42 && gauge.limitUSD == nil, "money without a cap")
        try expect(gauge.fraction == 0 && gauge.resetsAt == nil, "no invented wall or reset")
        try expect(
            DeepSeekBalance.amount(for: gauge) == "¥13.42", "CNY reads with its own symbol")
        try expect(
            topped.details.contains { $0.key == "Topped up" && $0.value == "¥11.00" },
            "the top-up split is a fact")
        try expect(
            topped.details.contains { $0.key == "Granted" && $0.value == "¥2.42" },
            "the granted split is a fact")

        let empty = DeepSeekBalance.snapshot(
            for: DeepSeekBalance.Reading(
                total: 0, toppedUp: 0, granted: 0, currency: "CNY", isAvailable: false))
        let emptyGauge = try requireOne(empty.gauges)
        try expect(emptyGauge.fraction >= 1, "an empty balance is a wall")
        try expect(
            DeepSeekBalance.amount(for: emptyGauge) == "Empty",
            "the wall reads as empty, not as a number")

        let usd = DeepSeekBalance.money(4.5, nil)
        try expect(usd == "$4.50", "USD reads with its own symbol")
        return checks
    }

    static func requireOne<T>(_ items: [T]) throws -> T {
        guard items.count == 1, let only = items.first else {
            throw SelfTestFailure("deepseek balance: expected exactly one gauge")
        }
        return only
    }

    /// The footer strip's states, proved as data: a wall owns the strip and is answered by what is
    /// still open, warm windows read one line each only while nothing is at the wall, a quiet
    /// account still says which window is closest to mattering, and every line the client draws
    /// with a bar carries the fraction to draw it from.
    static func checkUsageGlance() throws -> Int {
        var checks = 0
        let now = Date()
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("usage glance: \(label)") }
            checks += 1
        }
        func quota(
            _ provider: String, _ windows: [(String, Double)], live: Bool = true,
            accountID: String? = nil
        ) -> UsageQuota {
            UsageQuota(
                providerName: provider, subtitle: "", source: "test", live: live,
                gauges: windows.map {
                    UsageQuota.Gauge(
                        key: $0.0.lowercased(), label: $0.0, fraction: $0.1,
                        resetsAt: now.addingTimeInterval(7_200), trustedReset: true)
                },
                details: [], accountID: accountID)
        }
        func balance(_ total: Double, _ fraction: Double) -> UsageQuota {
            UsageQuota(
                providerName: "DeepSeek", subtitle: "", source: "api.deepseek.com", live: true,
                gauges: [
                    UsageQuota.Gauge(
                        key: "balance", label: "Balance", fraction: fraction, resetsAt: nil,
                        trustedReset: false, usedUSD: total, limitUSD: nil, currency: "USD")
                ],
                details: [])
        }
        func glance(_ reports: [(String, UsageQuota)], answeredAt: Date? = nil) -> QuotaGlance {
            QuotaGlance.make(from: reports, answeredAt: answeredAt ?? now, now: now)
        }

        let quiet = glance([("", quota("Claude", [("Weekly", 0.3), ("5-hour session", 0.1)]))])
        try expect(quiet.lines.count == 1, "a quiet account is one line")
        try expect(
            quiet.lines[0].tone == .ok && quiet.lines[0].text.contains("Claude"),
            "the quiet line names the provider")
        try expect(
            quiet.lines[0].text.contains("Weekly") && quiet.lines[0].trailing == "30%"
                && quiet.lines[0].fraction == 0.3,
            "and names the window closest to mattering, with the bar to draw it")

        let warm = glance([
            ("", quota("Claude", [("5-hour session", 0.85), ("Weekly", 0.3)])),
            ("", quota("Grok", [("Weekly credits", 0.7)])),
        ])
        try expect(warm.lines.count == 2, "every provider on the board reads one line")
        try expect(
            warm.lines[0].tone == .warn && warm.lines[0].trailing == "85%", "the tightest leads")
        try expect(!warm.lines[0].text.contains("Weekly"), "a quiet window is not news")

        let wall = glance([
            ("", quota("Claude", [("Weekly", 1.0), ("5-hour session", 0.2)])),
            ("", quota("Grok", [("Weekly credits", 0.9)])),
        ])
        try expect(wall.lines.count == 2, "a wall, and the one line that makes it actionable")
        try expect(
            wall.lines[0].tone == .danger && wall.lines[0].trailing == Localized.text("Used up")
                && wall.lines[0].text.contains("Weekly"),
            "the wall names what ran out")
        try expect(
            wall.lines[1].tone == .ok && wall.lines[1].text.contains("Grok"),
            "and the strip says where there is still room")

        let crowded = glance([
            ("", quota("opencode go", [("Weekly", 1.0)])),
            ("", quota("Claude", [("5-hour session", 0.63), ("Weekly", 0.42)])),
            ("", quota("Grok", [("Monthly spend", 0.14)])),
        ])
        try expect(
            crowded.lines.contains { $0.text.contains("Claude") && $0.trailing == "63%" },
            "a wall names every provider still open, never only the roomiest")

        let shut = glance([
            ("", quota("Claude", [("Weekly", 1.0)])),
            ("", quota("Grok", [("Weekly credits", 1.0)])),
        ])
        try expect(
            shut.lines.last?.tone == .danger
                && shut.lines.last?.text == Localized.text("Nothing left to send with"),
            "nowhere to go is a state, not a missing line")

        let manyWalls = glance([
            ("", quota("Claude", [("Weekly", 1.0), ("5-hour session", 1.0), ("Opus weekly", 1.0)])),
            ("", quota("Grok", [("Weekly credits", 1.0)])),
        ])
        try expect(
            manyWalls.lines.contains {
                $0.kind == .notice && $0.text.contains("1")
            },
            "a wall past the strip's room is counted, never dropped")

        let emptyBalance = glance([("", balance(0, 1.0))])
        try expect(
            emptyBalance.lines.count == 1 && emptyBalance.lines[0].tone == .danger
                && emptyBalance.lines[0].trailing == Localized.text("Empty"),
            "an empty balance reads as the wall it is")

        let wallWithBalance = glance([
            ("", quota("Claude", [("Weekly", 1.0)])),
            ("", balance(13.42, 0)),
        ])
        try expect(
            wallWithBalance.lines.last?.kind == .balance
                && wallWithBalance.lines.last?.trailing == "$13.42",
            "the balance keeps its own line whatever the walls are doing")
        try expect(
            wallWithBalance.lines.allSatisfy { $0.kind != .balance || $0.fraction == nil },
            "money has no ceiling, so it draws no bar")

        let cached = glance(
            [("", quota("opencode go", [("Weekly", 0.4)], live: false))],
            answeredAt: now.addingTimeInterval(-900))
        try expect(
            cached.lines.first?.kind == .notice && cached.lines.first?.tone == .warn,
            "a reading nobody could refresh says so before it says anything else")

        let checking = QuotaGlance.make(from: [], answeredAt: nil, now: now)
        try expect(
            checking.lines.count == 1 && checking.lines[0].tone == .quiet,
            "a first poll still out is a state, not an empty strip")
        try expect(
            QuotaGlance.make(from: [], answeredAt: now, now: now).isEmpty,
            "nothing reported is nothing shown")
        try expect(!quiet.tooltip.isEmpty, "the whole picture is one hover away")

        let twoAccounts = glance([
            ("arch", quota("Claude", [("Weekly", 0.2)], accountID: "a")),
            ("mini", quota("Claude", [("Weekly", 0.7)], accountID: "b")),
        ])
        try expect(
            twoAccounts.lines.filter { $0.kind == .window }.count == 2,
            "two accounts of one provider are two lines on the strip")
        let estimate = QuotaReports.admitted(
            UsageQuota(
                providerName: "opencode go", subtitle: "", source: "estimated", live: false,
                gauges: [
                    UsageQuota.Gauge(
                        key: "weekly", label: "Weekly", fraction: 0.4, resetsAt: nil,
                        trustedReset: false)
                ], details: []))
        try expect(
            glance([("arch", estimate)]).lines.contains { $0.text.contains("No measured reading") },
            "a provider with only an estimate stays as a line instead of vanishing")
        return checks
    }
}
