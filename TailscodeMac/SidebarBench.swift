import AppKit
import CodingAgentKit
import TailscodeCore

/// `--bench sidebar[=<chats>:<seconds>]` puts the chat list alone in a borderless window parked
/// off every screen, lists the server `TAILSCODE_HOST` names, pads the listing with idle copies of
/// its own chats until it holds `<chats>` (2,100 by default, the size of a fleet used for months),
/// keeps the server's pushes coming while its turns stream, and after a few seconds' settling
/// measures `<seconds>` (40 by default): how many times the list was drawn, what each draw cost the
/// main thread in its own CPU time, and what share of the main thread the whole stretch took. Live
/// turns on that server are what make it move; the window never reaches a screen anybody sees.
@MainActor
enum SidebarBench {
    static var isRunning = false
    /// How many chats the listing is padded to while the bench runs.
    static var padding = 0
    private static var draws: [Double] = []

    static func run(_ spec: String) -> Never {
        let fields = spec.split(separator: "=", maxSplits: 1).dropFirst().first.map(String.init)
        let parts = (fields ?? "").split(separator: ":").compactMap { Int($0) }
        let chats = parts.first ?? 2_100
        let seconds = parts.count > 1 ? parts[1] : 40
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            await bench(chats: chats, seconds: seconds)
            exit(0)
        }
        app.run()
        exit(0)
    }

    /// A draw of the list, in seconds of the main thread's own CPU time, and what its walk cost
    /// another thread when it went away from the main one.
    static func note(draw seconds: Double, away: Double = 0) {
        guard isRunning else { return }
        draws.append(seconds * 1000)
        if away > 0 { walks.append(away * 1000) }
        stageMark = nil
    }

    private static var walks: [Double] = []

    private static var stageMark: Double?
    private static var stages: [String: [Double]] = [:]
    private static var stageOrder: [String] = []

    /// Closes the stage of the draw in progress that ends here, so a slow draw says which part of
    /// it is slow.
    static func stage(_ name: String) {
        guard isRunning else { return }
        let now = clock()
        if let began = stageMark {
            if stages[name] == nil { stageOrder.append(name) }
            stages[name, default: []].append((now - began) * 1000)
        }
        stageMark = now
    }

    /// Opens a draw's first stage.
    static func beginStages() {
        guard isRunning else { return }
        stageMark = clock()
    }

    private static func stageSummary() -> String {
        stageOrder.map { name in
            let values = (stages[name] ?? []).sorted()
            let median = values.isEmpty ? 0 : values[values.count / 2]
            return String(format: "%@ %.1f", name, median)
        }.joined(separator: " ")
    }

    /// The listing with idle copies of its oldest chats behind it, each a day older than the last
    /// real one, until it holds `padding` chats. The copies never move, so they cost what a quiet
    /// part of a real fleet costs a draw.
    static func padded(_ entries: [SessionEntry]) -> [SessionEntry] {
        guard isRunning, padding > entries.count, let oldest = entries.last else { return entries }
        var grown = entries
        grown.reserveCapacity(padding)
        var index = 0
        while grown.count < padding {
            let source = entries[entries.count - 1 - index % entries.count]
            let session = AgentSession(
                id: "\(source.session.id)-pad\(index)", agentType: source.session.agentType,
                title: source.session.title, directory: source.session.directory,
                createdAt: source.session.createdAt,
                updatedAt: oldest.session.updatedAt.addingTimeInterval(-86_400 * Double(index + 1)),
                isActive: false, model: source.session.model)
            grown.append(
                SessionEntry(
                    profileID: source.profileID, profileName: source.profileName, host: source.host,
                    backendType: source.backendType, session: session))
            index += 1
        }
        return grown
    }

    /// The calling thread's own CPU time.
    static func clock() -> Double {
        var time = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &time)
        return Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000
    }

    private static func bench(chats: Int, seconds: Int) async {
        guard ProcessInfo.processInfo.environment["TAILSCODE_HOST"] != nil else {
            print("sidebar: set TAILSCODE_HOST (and TAILSCODE_PASSWORD) to the server to list")
            return
        }
        isRunning = true
        padding = chats
        let sidebar = SidebarViewController()
        let window = NSWindow(
            contentRect: NSRect(x: -30_000, y: -30_000, width: 320, height: 1_000),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = sidebar
        window.setFrame(NSRect(x: -30_000, y: -30_000, width: 320, height: 1_000), display: false)
        window.orderFrontRegardless()
        await sidebar.refresh()
        print("sidebar: \(sidebar.entries.count) chats listed, \(sidebar.rows.count) rows drawn")
        try? await Task.sleep(for: .seconds(5))
        let thread = pthread_mach_thread_np(pthread_self())
        draws = []
        walks = []
        stages = [:]
        stageOrder = []
        let mainBefore = Watchdog.cpuState(of: thread)?.cpu ?? 0
        let start = CACurrentMediaTime()
        var polls = 0
        while CACurrentMediaTime() - start < Double(seconds) {
            try? await Task.sleep(for: .seconds(10))
            await sidebar.refresh()
            polls += 1
        }
        let wall = CACurrentMediaTime() - start
        let main = (Watchdog.cpuState(of: thread)?.cpu ?? 0) - mainBefore
        let sorted = draws.sorted()
        func pct(_ q: Double) -> Double {
            sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * q))]
        }
        print(
            String(
                format:
                    "sidebar: %d chats, %d draws in %.0f s (%.1f a second, %d polls), a draw median %.1f p90 %.1f worst %.1f ms, draws %.0f ms of %.0f ms main thread CPU (%.1f%% of the stretch)",
                sidebar.entries.count, sorted.count, wall, Double(sorted.count) / wall, polls, pct(0.5),
                pct(0.9), sorted.last ?? 0, sorted.reduce(0, +), main * 1000, main / wall * 100))
        print("sidebar: median by stage (ms): \(stageSummary())")
        if !walks.isEmpty {
            let away = walks.sorted()
            print(
                String(
                    format: "sidebar: %d walks off the main thread, median %.1f worst %.1f ms",
                    away.count, away[away.count / 2], away.last ?? 0))
        }
        isRunning = false
        window.orderOut(nil)
    }
}
