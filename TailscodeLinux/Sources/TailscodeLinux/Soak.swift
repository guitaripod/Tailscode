import CAdw
import CGtkShim
import Foundation
import Synchronization
import TailscodeCore

/// The tiling soak's instruments. `TAILSCODE_SOAK="N:R:K[:T[:P]]"` with `--demo` installs the soak
/// world and turns them on; nothing here runs otherwise. Every five seconds, from a thread of its
/// own so a wedged main loop still reports, one line goes to stdout:
///
/// `SOAK t= dt= rss= anon= thr= fds= pending= maxPending= lag50= lag95= lagMax= lagN= ticks= tickRuns=
/// frames= parses= parseHits= listSaves= listSaveMs= applies= applyMs= cpu= mainCpu=`
///
/// `lagN` is how many times the 100 ms lag timer fired in the window (zero means the main loop
/// never reached it, and `lagMax` is then the time since it last did); `ticks` is the number of
/// live frame-clock callbacks; `tickRuns`, `frames`, `parses`, `parseHits`, `listSaves`,
/// `listSaveMs`, `applies`, `applyMs`, `paints` and `paintMs` are totals over the last `dt` seconds; `cpu` and
/// `mainCpu` are the process's and the main thread's share of one core over the same window.
enum Soak {
    static let requested = ProcessInfo.processInfo.environment["TAILSCODE_SOAK"].flatMap {
        SoakWorld.Configuration(parsing: $0)
    }

    private static let running = Atomic<Bool>(false)
    private static let saves = Mutex((count: 0, nanoseconds: UInt64(0)))
    private static let applies = Mutex((count: 0, nanoseconds: UInt64(0)))
    private static let paints = Mutex((count: 0, nanoseconds: UInt64(0)))
    private static let window = Mutex(Window())

    private struct Window {
        var started = ContinuousClock.now
        var at = ContinuousClock.now
        var tickRuns = 0
        var frames = 0
        var parses = 0
        var parseHits = 0
        var cpuTicks = 0
        var mainTicks = 0
    }

    static var isOn: Bool { running.load(ordering: .relaxed) }

    static func installIfRequested() {
        guard let requested, DemoMode.isActive else { return }
        SoakWorld.install(requested)
        start()
    }

    static func start() {
        guard !running.exchange(true, ordering: .relaxed) else { return }
        tailscode_soak_enable()
        window.withLock { state in
            state = Window()
            state.cpuTicks = cpuTicks(of: "/proc/self/stat")
            state.mainTicks = cpuTicks(of: "/proc/self/task/\(getpid())/stat")
        }
        let sampler = Thread {
            while true {
                Thread.sleep(forTimeInterval: 5)
                report()
            }
        }
        sampler.name = "soak-sampler"
        sampler.start()
    }

    /// Frames are counted on the window's own clock, which exists only once it is realized.
    static func watchFrames(of widget: UnsafeMutablePointer<GtkWidget>?, attempts: Int = 20) {
        guard isOn, let widget else { return }
        if tailscode_soak_watch_frames(widget) != 0 { return }
        guard attempts > 0 else { return }
        let address = UInt(bitPattern: widget)
        Gtk.after(250) {
            watchFrames(of: UnsafeMutablePointer(bitPattern: address), attempts: attempts - 1)
        }
    }

    static func timeListSave(_ save: () -> Void) { time(save, into: saves) }

    /// A pane taking one conversation state on the main thread: the row diff, the widgets and the
    /// live row's re-render.
    static func timeApply(_ apply: () -> Void) { time(apply, into: applies) }

    /// One frame of the written-not-pasted reveal: the attributes and the row's re-layout. The
    /// count over the window is the rate the text is actually moving at, which is the number to
    /// compare with the display's refresh when text is said not to stream at it.
    static func timePaint(_ paint: () -> Void) { time(paint, into: paints) }

    private static func time(
        _ work: () -> Void, into total: borrowing Mutex<(count: Int, nanoseconds: UInt64)>
    ) {
        guard isOn else { return work() }
        let began = DispatchTime.now().uptimeNanoseconds
        work()
        let spent = DispatchTime.now().uptimeNanoseconds - began
        total.withLock {
            $0.count += 1
            $0.nanoseconds += spent
        }
    }

    private static func drain(_ total: borrowing Mutex<(count: Int, nanoseconds: UInt64)>)
        -> (Int, UInt64)
    {
        total.withLock { state -> (Int, UInt64) in
            defer { state = (0, 0) }
            return (state.count, state.nanoseconds)
        }
    }

    static func report() {
        guard isOn else { return }
        FileHandle.standardOutput.write(Data((line() + "\n").utf8))
    }

    private static func line() -> String {
        var sample = TailscodeSoakSample()
        tailscode_soak_read(&sample)
        let (saveCount, saveNanoseconds) = drain(saves)
        let (applyCount, applyNanoseconds) = drain(applies)
        let (paintCount, paintNanoseconds) = drain(paints)
        let status = procStatus()
        let fds = ((try? FileManager.default.contentsOfDirectory(atPath: "/proc/self/fd"))?.count ?? 1) - 1
        let cpuNow = cpuTicks(of: "/proc/self/stat")
        let mainNow = cpuTicks(of: "/proc/self/task/\(getpid())/stat")
        let now = ContinuousClock.now
        return window.withLock { state -> String in
            let seconds = max(0.001, (now - state.at).seconds)
            let hertz = Double(sysconf(Int32(_SC_CLK_TCK)))
            let cpu = Double(cpuNow - state.cpuTicks) / hertz / seconds * 100
            let mainCpu = Double(mainNow - state.mainTicks) / hertz / seconds * 100
            let fields: [String] = [
                "t=\(String(format: "%.1f", (now - state.started).seconds))",
                "dt=\(String(format: "%.2f", seconds))",
                "rss=\(status["VmRSS"] ?? 0)",
                "anon=\(status["RssAnon"] ?? 0)",
                "thr=\(status["Threads"] ?? 0)",
                "fds=\(fds)",
                "pending=\(sample.pending)",
                "maxPending=\(sample.pending_max)",
                "lag50=\(String(format: "%.1f", sample.lag50_ms))",
                "lag95=\(String(format: "%.1f", sample.lag95_ms))",
                "lagMax=\(String(format: "%.1f", sample.lag_max_ms))",
                "lagN=\(sample.lag_samples)",
                "ticks=\(tailscode_live_ticks())",
                "tickRuns=\(sample.tick_runs - state.tickRuns)",
                "frames=\(sample.frames - state.frames)",
                "parses=\(sample.parses - state.parses)",
                "parseHits=\(sample.parse_hits - state.parseHits)",
                "listSaves=\(saveCount)",
                "listSaveMs=\(String(format: "%.1f", Double(saveNanoseconds) / 1e6))",
                "applies=\(applyCount)",
                "applyMs=\(String(format: "%.1f", Double(applyNanoseconds) / 1e6))",
                "paints=\(paintCount)",
                "paintMs=\(String(format: "%.1f", Double(paintNanoseconds) / 1e6))",
                "cpu=\(String(format: "%.1f", cpu))",
                "mainCpu=\(String(format: "%.1f", mainCpu))",
            ]
            state.at = now
            state.tickRuns = sample.tick_runs
            state.frames = sample.frames
            state.parses = sample.parses
            state.parseHits = sample.parse_hits
            state.cpuTicks = cpuNow
            state.mainTicks = mainNow
            return "SOAK " + fields.joined(separator: " ")
        }
    }

    /// The numeric fields of `/proc/self/status` the line reports, in the kernel's own units
    /// (KiB for memory).
    private static func procStatus() -> [String: Int] {
        guard let text = try? String(contentsOfFile: "/proc/self/status", encoding: .utf8) else {
            return [:]
        }
        var fields: [String: Int] = [:]
        for line in text.split(separator: "\n") {
            let pair = line.split(separator: ":", maxSplits: 1)
            guard pair.count == 2, ["VmRSS", "RssAnon", "Threads"].contains(String(pair[0])) else {
                continue
            }
            fields[String(pair[0])] = Int(pair[1].split(whereSeparator: \.isWhitespace).first ?? "")
        }
        return fields
    }

    /// User plus system clock ticks from a `stat` file; the command name can hold spaces, so the
    /// fields are counted from the last parenthesis.
    private static func cpuTicks(of path: String) -> Int {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8),
            let close = text.lastIndex(of: ")")
        else { return 0 }
        let fields = text[text.index(after: close)...].split(separator: " ")
        guard fields.count > 12 else { return 0 }
        return (Int(fields[11]) ?? 0) + (Int(fields[12]) ?? 0)
    }
}

extension Duration {
    fileprivate var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
