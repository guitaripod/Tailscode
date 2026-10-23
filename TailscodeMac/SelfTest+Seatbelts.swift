import AgentTestSupport
import AppKit
import CodingAgentKit
import CodingAgentKitApple
import Foundation
import TailscodeCore

extension SelfTest {
    /// The Mac's writer round-trips through Core's ring: a launch record, samples carrying what
    /// this process really measures, a stall and a shed, and the clean exit, each in its own
    /// numbered 192-byte slot of a ring that a second writer — the next launch after a kill —
    /// opens and carries on from.
    static func checkFlight() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("flight case failed: \(label)") }
            checks += 1
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("flight-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("flight.ring")
        let writer = try FlightWriter(url: url)
        let header = FlightWriter.header()
        writer.write(.launch(header, t: FlightRecord.epochMilliseconds()))
        let counts = FlightWriter.processCounts()
        let footprint = MemoryPressure.footprintBytes()
        try expect((counts.threads ?? 0) > 1, "this process counts its threads")
        try expect((counts.fds ?? 0) > 2, "and its open descriptors")
        try expect((footprint ?? 0) > 1_000_000, "and its footprint")
        for second in 0..<3 {
            writer.write(
                FlightRecord(
                    t: FlightRecord.epochMilliseconds(), rss: footprint.map { $0 / 1024 },
                    thr: counts.threads, fds: counts.fds,
                    panes: FlightPanes(full: 2, glance: 0, parked: 1), lv: 0,
                    busy: 0.12 * Double(second), stall: 16, ps: HostPressure.nominal.code,
                    own: 0.04))
        }
        writer.write(
            FlightRecord(
                t: FlightRecord.epochMilliseconds(), stall: 3012,
                ev: Watchdog.event(
                    .stall(3.012), MainThreadState(cpuSinceAnswer: 2.98, running: true))))
        writer.write(FlightRecord(t: FlightRecord.epochMilliseconds(), lv: 4, ev: "shed 0->4 watchdog"))
        writer.writeNow(FlightRecord(t: FlightRecord.epochMilliseconds(), lv: 4, ev: "exit clean"))

        let records = FlightRing.read(url: url)
        try expect(records.count == 7, "every record written is read back (\(records.count))")
        try expect(
            zip(records, records.dropFirst()).allSatisfy { $1.n == $0.n + 1 },
            "numbered one after another")
        #if TAILSCODE_MAS
            let flavour = "store"
        #else
            let flavour = "direct"
        #endif
        try expect(
            records.first?.header?.version.hasSuffix(flavour) == true,
            "the launch record names the build flavour")
        try expect(
            records.first?.header?.toolkit.hasPrefix("AppKit macOS ") == true
                && records.first?.header?.renderer == "n/a",
            "and the toolkit with the macOS version, and no renderer to tell apart")
        let sample = records[1]
        try expect(
            sample.rss == footprint.map { $0 / 1024 } && sample.thr == counts.threads
                && sample.fds == counts.fds,
            "a sample keeps the footprint, threads and descriptors it was given")
        try expect(
            sample.panes == FlightPanes(full: 2, glance: 0, parked: 1) && sample.ps == "nom",
            "and the panes and the pressure word")
        try expect(
            records[4].ev == "stall 3012ms cpu 2.98 R" && records[4].stall == 3012,
            "a stall record says how long and what the main thread was doing")
        try expect(records.last?.ev == "exit clean", "the clean exit is the newest record")
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        try expect(
            size == FlightRing.slotCount * FlightRecord.slotSize,
            "the ring is its fixed size from the first write")
        let bytes = try Data(contentsOf: url)
        let slot = bytes[(Int(records[1].n) * FlightRecord.slotSize)..<(Int(records[1].n + 1) * FlightRecord.slotSize)]
        try expect(slot.last == 0x0A && slot.allSatisfy { $0 >= 0x0A && $0 < 0x7F }, "a slot is printable ASCII ending in a newline")

        let reopened = try FlightWriter(url: url)
        try expect(
            reopened.ring.nextNumber == (records.last?.n ?? 0) + 1,
            "a writer opened after a kill carries on from the newest record")
        let text = FlightFormatter.format(records)
        try expect(
            text.contains("launch: version") && text.hasSuffix("exit clean\n"),
            "--flight prints the launch spelled out and the newest last")
        return checks
    }

    /// The ledger written the way a launch writes it, and Core's decision over it: a first launch
    /// is plain, a launch after an unclean one with three or more chats parks them behind the
    /// banner, two unclean in a row also hold the level at loaded for ten minutes, and a clean exit
    /// clears the streak. A process that never started its seatbelts records no launch at all.
    static func checkRestorePlan() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("restore plan case failed: \(label)") }
            checks += 1
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledger-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("launch.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        func launch(_ panes: Int) -> (RestorePlan, LaunchLedger) {
            let started = LaunchLedger.begin(url: url, panes: panes)
            return (RestorePlan.decide(ledger: started.previous, paneCount: panes), started.current)
        }
        let (first, firstLedger) = launch(5)
        try expect(first.mode == .staggered && !first.unclean, "a first launch restores plainly")
        try expect(
            LaunchLedger.read(url: url)?.cleanExit == false,
            "and is written down as not yet closed")
        let (second, _) = launch(5)
        try expect(
            second.mode == .parked(bannerCount: 5) && second.unclean && second.floor == nil,
            "after a launch that never closed, five chats come back parked")
        let (third, thirdLedger) = launch(5)
        try expect(
            third.floor == .loaded && third.floorDuration == 600,
            "a second unclean exit in a row holds the level at loaded for ten minutes")
        LaunchLedger.markClean(url: url, launchID: firstLedger.launchID, panes: 1, level: 0)
        try expect(
            LaunchLedger.read(url: url)?.cleanExit == false,
            "a stale launch cannot mark the running one clean")
        LaunchLedger.markClean(url: url, launchID: thirdLedger.launchID, panes: 2, level: 0)
        let (fourth, _) = launch(5)
        try expect(fourth.mode == .staggered && !fourth.unclean, "a clean exit clears it")
        _ = launch(2)
        let (fewUnclean, _) = launch(2)
        try expect(
            fewUnclean.unclean && fewUnclean.mode == .staggered,
            "one or two chats restore normally even after an unclean exit")

        try expect(
            !Seatbelts.shared.isRunning
                && Seatbelts.shared.beginLaunch(chatPanes: 5).mode == .staggered,
            "a process whose seatbelts never started records no launch")

        var layout = SplitLayout()
        let a = layout.focusedPane
        let b = layout.split(a, axis: .horizontal)!
        let c = layout.split(b, axis: .vertical)!
        layout.focus(a)
        layout.focus(c)
        let wake = RestorePlan.wakeSchedule(focused: layout.focusedPane, recent: layout.recentlyFocused)
        try expect(
            wake.map(\.pane) == [c, a, b] && abs(wake[2].at - 0.6) < 1e-9,
            "the focused pane wakes first, the rest most recent first, 300 ms apart")

        let banner = RestoreBannerView()
        banner.setCount(5)
        try expect(
            banner.text == second.bannerText && banner.text.contains("5"),
            "the banner says Core's sentence with the count")
        try expect(banner.accessibilityLabel() == banner.text, "and says it to VoiceOver")
        return checks
    }

    /// The real observer on a real run loop: a timer that spins for 200 ms must read as one busy
    /// slice of about that length, and the share must show it.
    static func checkLoopMeter() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("loop meter case failed: \(label)") }
            checks += 1
        }
        let meter = LoopMeter()
        let loop = CFRunLoopGetCurrent()!
        meter.install(on: loop)
        try expect(meter.isInstalled, "the observers are on the loop")
        RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        let spin = Timer(timeInterval: 0.05, repeats: false) { _ in
            let until = MachClock.now() + 0.2
            while MachClock.now() < until {}
        }
        RunLoop.current.add(spin, forMode: .common)
        RunLoop.current.run(until: Date().addingTimeInterval(0.6))
        let reading = meter.reading()
        try expect(
            reading.worst1 >= 0.19 && reading.worst1 < 0.45,
            "the spin is the worst slice of the last second (\(reading.worst1))")
        try expect(
            reading.busy1 >= 0.15 && reading.busy1 < 0.9,
            "and a share of the second, not all of it (\(reading.busy1))")
        try expect(reading.worst2 >= reading.worst1, "two seconds see at least what one does")
        meter.uninstall()
        try expect(!meter.isInstalled, "and come off when asked")
        return checks
    }

    /// The real watchdog on its own queue, with the thresholds shortened: a main thread blocked
    /// past the stall line is reported from outside, as waiting, with the hint set; one spinning is
    /// reported as running; and each episode ends with a recovery and a resume on the main thread.
    static func checkWatchdog() async throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("watchdog case failed: \(label)") }
            checks += 1
        }
        let log = SelfTestEvents()
        let resumed = SelfTestCounter()
        let watchdog = Watchdog(
            policy: StallPolicy(ping: 0.05, stall: 0.3, deep: 0.8),
            report: { event, state in log.add(event, state) },
            onResume: { resumed.bump() })
        watchdog.start()
        defer { watchdog.stop() }
        try await Task.sleep(for: .milliseconds(200))
        try expect(log.events.isEmpty && !watchdog.isStalled, "a main thread that answers is healthy")
        usleep(500_000)
        try await Task.sleep(for: .milliseconds(300))
        let blocked = log.events
        try expect(
            blocked.contains { if case .stall = $0.0 { return $0.1?.running == false }; return false },
            "a blocked main thread is a stall, and waiting rather than running (\(blocked.map(\.0)))")
        try expect(
            blocked.contains { if case .recovered = $0.0 { return true }; return false },
            "and its answer ends the episode")
        try expect(resumed.value >= 1, "the main thread is told the moment it answers")
        try expect(watchdog.takeHint() && !watchdog.takeHint(), "the level-4 hint is taken once")
        log.clear()
        let thread = pthread_mach_thread_np(pthread_self())
        let before = Watchdog.cpuState(of: thread)
        let until = MachClock.now() + 0.5
        while MachClock.now() < until {}
        let after = Watchdog.cpuState(of: thread)
        try await Task.sleep(for: .milliseconds(300))
        try expect(
            log.events.contains { if case .stall = $0.0 { return true }; return false }
                && log.events.contains { if case .recovered = $0.0 { return true }; return false },
            "a spinning main thread is a stall too, and ends with its answer")
        try expect(
            (after?.cpu ?? 0) - (before?.cpu ?? 0) > 0.4 && after?.running == true,
            "thread_info reads a spinning thread as running and burning its time")
        return checks
    }

    /// The kernel's memory words, the heat and the footprint as the governor reads them, and the
    /// drive hook's injected pressure landing on the governor's floor.
    static func checkMemoryPressureMapping() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("memory pressure case failed: \(label)") }
            checks += 1
        }
        try expect(MemoryPressure.pressure(for: .normal) == .nominal, "normal is nominal")
        try expect(MemoryPressure.pressure(for: .warning) == .strained, "warning is strained")
        try expect(MemoryPressure.pressure(for: .critical) == .critical, "critical is critical")
        try expect(
            MemoryPressure.pressure(for: [.warning, .critical]) == .critical,
            "several flags read as the worst")
        try expect(
            MemoryPressure.thermal(.nominal) == .nominal && MemoryPressure.thermal(.fair) == .fair
                && MemoryPressure.thermal(.serious) == .serious
                && MemoryPressure.thermal(.critical) == .critical,
            "the four thermal steps carry over")
        let physical = ProcessInfo.processInfo.physicalMemory
        try expect(
            MemoryPressure.limitBytes == min(8 << 30, UInt64(Double(physical) * 0.15)),
            "the own-memory limit is min(8 GiB, 0.15 × physical)")
        try expect(
            MemoryPressure.ownShare(footprint: MemoryPressure.limitBytes / 2, limit: MemoryPressure.limitBytes)
                == 0.5,
            "half the limit is half")
        let calls = SelfTestCounter()
        let pressure = MemoryPressure { _ in calls.bump() }
        let reading = pressure.reading()
        try expect(
            reading.host == .nominal && (reading.ownMemory ?? 0) > 0 && (reading.ownMemory ?? 1) < 1,
            "an idle selftest is under no pressure and a sliver of its limit")
        pressure.inject(.critical)
        try expect(
            pressure.host == .critical && calls.value == 1,
            "an injected word replaces the kernel's and says so once")
        pressure.inject(.critical)
        try expect(calls.value == 1, "the same word twice is no news")
        var governor = TileGovernor()
        let decision = governor.evaluate(
            now: 1, sample: GovernorSample(host: pressure.reading().host), panes: [],
            setting: .auto)
        try expect(decision.level == .critical, "critical host memory floors the level at 4")
        pressure.inject(nil)
        try expect(pressure.host == .nominal && calls.value == 2, "and handed back it is nominal")
        return checks
    }

    /// What each level lets the window spend: the reveal until loaded, every other motion until
    /// strained, the cascade's rate held to the tick cap from busy up.
    static func checkShedEffects() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("shed effects case failed: \(label)") }
            checks += 1
        }
        let moving = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        defer { MotionBudget.apply(.calm) }
        MotionBudget.apply(.calm)
        try expect(MotionBudget.cascadeAllowed == moving, "calm reveals")
        try expect(
            MotionBudget.cascadeRange.maximum == 120,
            "at the panel's own rate, as the transcript doctrine asks")
        MotionBudget.apply(.calm, streaming: 1, focusedStreaming: true)
        try expect(MotionBudget.cascadeRange.maximum == 120, "one streaming pane keeps the panel's rate")
        MotionBudget.apply(.calm, streaming: 2, focusedStreaming: true)
        try expect(MotionBudget.cascadeRange.maximum == 60, "two streaming panes share sixty")
        MotionBudget.apply(.calm, streaming: 4, focusedStreaming: true)
        try expect(MotionBudget.cascadeRange.maximum == 30, "four streaming panes share thirty")
        MotionBudget.apply(.calm, streaming: 1, focusedStreaming: false)
        try expect(MotionBudget.cascadeRange.maximum == 30, "a peer streaming alone never exceeds thirty")
        try expect(!MotionBudget.reveals(focused: false), "and only the focused pane reveals")
        MotionBudget.apply(.calm)
        MotionBudget.apply(.busy)
        try expect(MotionBudget.cascadeRange.maximum == 30, "busy holds the reveal to 30 fps")
        MotionBudget.apply(.loaded)
        try expect(!MotionBudget.cascadeAllowed && !CascadePainter.motionAllowed, "loaded shows text as it arrives")
        try expect(MotionBudget.animationAllowed == moving, "and keeps the marks breathing")
        MotionBudget.apply(.strained)
        try expect(
            !MotionBudget.animationAllowed && !ActivityPulse.motionAllowed,
            "strained stops every other motion")
        let layer = CALayer()
        let lap = CABasicAnimation(keyPath: "opacity")
        lap.repeatCount = .infinity
        layer.setRepeatingMotion(lap, forKey: "lap")
        try expect(layer.animation(forKey: "lap") == nil, "a lap laid on now does not move")
        MotionBudget.apply(.critical)
        try expect(!MotionBudget.cascadeAllowed && !MotionBudget.animationAllowed, "critical is still")
        return checks
    }
}
