import AppKit
import CodingAgentKit
import QuartzCore
import TailscodeCore

/// `TailscodeMac --bench tiles=N[:R:K:S]` — N panes streaming the soak server's firehose at R
/// tokens a second into K-message transcripts for S seconds, in a window ordered front so the
/// display link and the layout engine run as they do for a person, measured from inside: the main
/// run loop's busy share and worst slice (`LoopMeter`), how late a 100 ms main-queue timer fires
/// (the depth of anything queued on the main thread), the footprint's slope, and frames applied
/// against states received. Then every pane but one is hidden for a few seconds, as a zoom does,
/// and the same numbers are taken again.
@MainActor
enum TileBench {
    static func isRequested(_ paths: ArraySlice<String>) -> Bool {
        paths.first?.hasPrefix("tiles") == true || paths.first == ChatChecks.spec
    }

    static func run(_ spec: String) -> Never {
        if spec == TileChecks.spec { TileChecks.runAsChild() }
        if spec == ChatChecks.spec { ChatChecks.runAsChild() }
        let fields = spec.split(separator: "=", maxSplits: 1).dropFirst().first.map(String.init)
        let parts = (fields ?? "4").split(separator: ":").compactMap { Double($0) }
        let panes = Int(parts.first ?? 4)
        let rate = parts.count > 1 ? parts[1] : 80
        let rows = Int(parts.count > 2 ? parts[2] : 600)
        let seconds = parts.count > 3 ? parts[3] : 20
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            await bench(panes: panes, rate: rate, rows: rows, seconds: seconds)
            exit(0)
        }
        app.run()
        exit(0)
    }

    private struct Window {
        var busy: [Double] = []
        var worst: TimeInterval = 0
        var lags: [Double] = []
        var footprints: [(TimeInterval, Double)] = []
        var applied = 0
        var skipped = 0
        var mainCPU: Double = 0
        var applyShare: Double = 0
    }

    /// The main thread's port, for its CPU time: a second reading of how busy it is that does not
    /// depend on where the run loop says it slept.
    private static let mainThread = pthread_mach_thread_np(pthread_self())

    private static var lagStart: CFTimeInterval = 0
    private static var lags: [Double] = []
    private static var lagRunning = false

    private static func lagTick() {
        let now = CACurrentMediaTime()
        if lagStart > 0 { lags.append(max(0, (now - lagStart - 0.1) * 1000)) }
        guard lagRunning else { return }
        lagStart = now
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            MainActor.assumeIsolated { lagTick() }
        }
    }

    private static func processCPU() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }

    private static func pct(_ values: [Double], _ q: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        return sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))]
    }

    private static func slope(_ points: [(TimeInterval, Double)]) -> Double {
        guard points.count > 2 else { return 0 }
        let n = Double(points.count)
        let mx = points.map(\.0).reduce(0, +) / n
        let my = points.map(\.1).reduce(0, +) / n
        let num = points.map { ($0.0 - mx) * ($0.1 - my) }.reduce(0, +)
        let den = points.map { ($0.0 - mx) * ($0.0 - mx) }.reduce(0, +)
        return den == 0 ? 0 : num / den * 60
    }

    private static func measure(
        _ seconds: Double, meter: LoopMeter, panes: [TranscriptViewController]
    ) async -> Window {
        var window = Window()
        let before = panes.map(\.benchFrames)
        let applyBefore = panes.map(\.benchApplySeconds).reduce(0, +)
        let cpuBefore = Watchdog.cpuState(of: mainThread)?.cpu ?? 0
        lags = []
        lagStart = 0
        lagRunning = true
        lagTick()
        let start = CACurrentMediaTime()
        while CACurrentMediaTime() - start < seconds {
            try? await Task.sleep(for: .seconds(1))
            let reading = meter.reading()
            window.busy.append(reading.busy1)
            window.worst = max(window.worst, reading.worst1)
            if let bytes = MemoryPressure.footprintBytes() {
                window.footprints.append(
                    (CACurrentMediaTime() - start, Double(bytes) / 1_048_576))
            }
        }
        lagRunning = false
        window.lags = lags
        let elapsed = CACurrentMediaTime() - start
        window.mainCPU = ((Watchdog.cpuState(of: mainThread)?.cpu ?? 0) - cpuBefore) / elapsed
        window.applyShare =
            (panes.map(\.benchApplySeconds).reduce(0, +) - applyBefore) / elapsed
        for (pane, was) in zip(panes, before) {
            window.applied += pane.benchFrames.applied - was.applied
            window.skipped += pane.benchFrames.skipped - was.skipped
        }
        return window
    }

    private static func report(_ label: String, _ window: Window, seconds: Double, panes: Int) {
        let mean = window.busy.isEmpty ? 0 : window.busy.reduce(0, +) / Double(window.busy.count)
        print(
            String(
                format:
                    "%@: busy mean %.2f p95 %.2f · main cpu %.2f, applying %.2f · worst slice %.0f ms · lag p50 %.1f p95 %.1f worst %.0f ms · footprint %.0f MiB, slope %.1f MiB/min · applied %.1f/s/pane, skipped %.1f/s/pane",
                label, mean, pct(window.busy, 0.95), window.mainCPU, window.applyShare,
                window.worst * 1000, pct(window.lags, 0.5),
                pct(window.lags, 0.95), window.lags.max() ?? 0, window.footprints.last?.1 ?? 0,
                slope(window.footprints), Double(window.applied) / seconds / Double(panes),
                Double(window.skipped) / seconds / Double(panes)))
        print("  busy each second: " + window.busy.map { String(format: "%.2f", $0) }.joined(separator: " "))
    }

    private static func bench(panes count: Int, rate: Double, rows: Int, seconds: Double) async {
        let configuration = SoakWorld.Configuration(
            panes: count, tokensPerSecond: rate, rows: rows, turnSeconds: Int(seconds) + 60,
            listedSessions: count)
        let backend = SoakWorld.install(configuration)
        guard let sessions = try? await backend.listSessions(), sessions.count >= count else {
            print("tiles: the soak server listed no sessions")
            return
        }
        let size = NSSize(width: 1600, height: 1000)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(origin: .zero, size: size))
        window.contentView = root
        window.orderFrontRegardless()
        let columns = Int(ceil(sqrt(Double(count))))
        let lines = Int(ceil(Double(count) / Double(columns)))
        let width = size.width / CGFloat(columns)
        let height = size.height / CGFloat(lines)
        var panes: [TranscriptViewController] = []
        let meter = LoopMeter()
        meter.install()
        let opening = CACurrentMediaTime()
        for index in 0..<count {
            let pane = TranscriptViewController()
            pane.view.frame = NSRect(
                x: CGFloat(index % columns) * width, y: CGFloat(index / columns) * height,
                width: width - 1, height: height - 1)
            pane.view.autoresizingMask = []
            root.addSubview(pane.view)
            let entry = SessionEntry(
                profileID: SoakWorld.profile.id, profileName: "soak", host: "soak",
                backendType: .claudeCode, session: sessions[index])
            pane.open(entry, backend: backend)
            pane.benchFocus(index == 0)
            panes.append(pane)
        }
        let openCost = (CACurrentMediaTime() - opening) * 1000
        let loadStart = CACurrentMediaTime()
        while CACurrentMediaTime() - loadStart < 20,
            !panes.allSatisfy({ $0.currentState?.hasLoadedTranscript == true })
        {
            try? await Task.sleep(for: .milliseconds(50))
        }
        let loaded = (CACurrentMediaTime() - loadStart) * 1000
        print(
            String(
                format: "tiles: %d panes, %.0f tok/s, %d messages, %.0f s · open %.0f ms, loaded in %.0f ms",
                count, rate, rows, seconds, openCost, loaded))
        try? await Task.sleep(for: .seconds(2))
        let idle = await measure(3, meter: meter, panes: panes)
        report("idle", idle, seconds: 3, panes: count)
        let cpuBefore = processCPU()
        for pane in panes { pane.benchSend("stream") }
        try? await Task.sleep(for: .seconds(2))
        let streaming = await measure(seconds, meter: meter, panes: panes)
        report("streaming", streaming, seconds: seconds, panes: count)
        print(
            String(
                format: "process cpu %.0f%% of one core",
                (processCPU() - cpuBefore) / (seconds + 2) * 100))
        print("clock: \(TranscriptViewController.benchClock)")
        print(
            "cascade frames per s, ms each: "
                + panes.map {
                    String(
                        format: "%.0f×%.2f", Double($0.cascadeFrames) / (seconds + 2),
                        $0.cascadeFrames == 0 ? 0 : $0.cascadeTime / Double($0.cascadeFrames) * 1000)
                }.joined(separator: " "))
        print(
            "apply cost per frame (ms): "
                + panes.map { String(format: "%.1f", $0.benchApplyCost) }.joined(separator: " "))
        for pane in panes.dropFirst() { pane.benchHide(true) }
        let zoomed = await measure(5, meter: meter, panes: Array(panes.prefix(1)))
        report("zoomed onto one", zoomed, seconds: 5, panes: 1)
        let hiddenDrawn = panes.dropFirst().map(\.benchFrames.applied)
        try? await Task.sleep(for: .seconds(1))
        let stillDrawing = zip(panes.dropFirst(), hiddenDrawn).filter {
            $0.0.benchFrames.applied != $0.1
        }.count
        print("hidden panes still applying states: \(stillDrawing) of \(count - 1)")
        for pane in panes.dropFirst() { pane.benchHide(false) }
        for pane in panes { pane.shutdownPane() }
        meter.uninstall()
        window.orderOut(nil)
    }
}

extension TranscriptViewController {
    /// How the drain was paced, for the bench.
    static var benchClock: String {
        let clock = TileRuntime.shared.clock
        return
            "\(clock.linkTicks) link ticks, \(clock.guardRuns) guard runs, \(clock.drainPasses) passes, "
            + String(format: "worst pass %.1f ms", clock.worstPass * 1000)
    }

    /// Frames applied and states skipped, for the bench.
    var benchFrames: (applied: Int, skipped: Int) { (appliedFrames, skippedFrames) }

    /// Main-thread seconds this pane has spent building and applying frames.
    var benchApplySeconds: Double { applyTime }

    /// Mean main-thread cost of one applied frame, in milliseconds.
    var benchApplyCost: Double { appliedFrames == 0 ? 0 : applyTime / Double(appliedFrames) * 1000 }

    /// A prompt into this pane's chat, through the conversation every holder shares.
    func benchSend(_ text: String) {
        guard let entry = currentEntry, let backend = currentBackend else { return }
        let conversation = TileRuntime.shared.conversation(for: entry, backend: backend)
        Task { try? await conversation.send(text, model: nil, reasoningEffort: nil, attachments: []) }
    }

    /// The window's focus, as the tiling host gives it.
    func benchFocus(_ focused: Bool) {
        setFocusedPane(focused)
    }

    /// What a zoom does to a pane it hides.
    func benchHide(_ hidden: Bool) {
        view.isHidden = hidden
        setParked(hidden)
    }
}

