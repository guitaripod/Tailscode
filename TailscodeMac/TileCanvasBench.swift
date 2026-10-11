import AgentTestSupport
import AppKit
import CodingAgentKit
import QuartzCore
import TailscodeCore

/// `TailscodeMac --bench tiles <transcript.json …> [--legacy | --canvas] [--counts 1,2,4,6]`
/// (`--bench-tiles` is the older spelling and still works) —
/// what a window of panes costs to open, to drag a divider in and to resize, for the frame-placed
/// canvas and for the nested split controllers it replaces, from transcripts this Mac has cached
/// (`~/Library/Caches/Sessions/messages-*.json`; the soak server's transcripts when none is given).
///
/// Like `--bench`, every pass is timed on the main thread in a window that is never ordered
/// front: a window with no screen still keeps one layout engine, while a view with no window
/// builds a fresh one each pass and prices every layout ten to a hundred times over. Every pane is
/// full — no governor runs here — so the two hosts lay out exactly the same rows. A last pass
/// is `TileBench` with four panes for each host asked for: the soak firehose in a window ordered
/// front, under the governor, with the main thread's busy share, its CPU and its apply share.
@MainActor
enum TileCanvasBench {
    static var isRequested: Bool { CommandLine.arguments.contains("--bench-tiles") }

    private static let flags = ["--bench-tiles", "--bench"]

    static func run() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            await bench()
            exit(0)
        }
        app.run()
        exit(0)
    }

    static let size = NSSize(width: 1600, height: 1000)
    private static var windows: [NSWindow] = []

    private static func ms(_ seconds: Double) -> String { String(format: "%.1f", seconds * 1000) }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    }

    private static func p95(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        return sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
    }

    private static func time(_ block: () -> Void) -> Double {
        let start = CACurrentMediaTime()
        block()
        return CACurrentMediaTime() - start
    }

    private static func wait(_ seconds: Double, until condition: () -> Bool = { false }) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !condition() {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    enum Kind: String {
        case canvas
        case legacy
    }

    private static func bench() async {
        let arguments = CommandLine.arguments
        guard let flag = arguments.firstIndex(where: { flags.contains($0) }) else { return }
        let paths = arguments[(flag + 1)...].prefix { !$0.hasPrefix("-") }.filter { $0 != "tiles" }
        let cached: [[ChatMessage]] = paths.compactMap { path in
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
                let messages = try? JSONDecoder().decode([ChatMessage].self, from: data),
                !messages.isEmpty
            else { return nil }
            return messages
        }
        var datasets: [(String, [[ChatMessage]])] = []
        if !cached.isEmpty { datasets.append(("cached", cached)) }
        datasets.append(("soak", (1...4).map { SoakWorld.transcript(index: $0, rows: 600) }))
        let counts: [Int] =
            arguments.firstIndex(of: "--counts").flatMap { index in
                index + 1 < arguments.count
                    ? arguments[index + 1].split(separator: ",").compactMap { Int($0) } : nil
            } ?? [1, 2, 4, 6]
        let kinds: [Kind] =
            arguments.contains("--legacy")
            ? [.legacy] : arguments.contains("--canvas") ? [.canvas] : [.canvas, .legacy]
        for (name, transcripts) in datasets {
            let backend = backendServing(transcripts)
            guard let sessions = try? await backend.listSessions() else {
                print("bench-tiles: the bench server listed no sessions")
                return
            }
            let entries = sessions.map {
                SessionEntry(
                    profileID: "demo-bench", profileName: "bench", host: "bench",
                    backendType: .claudeCode, session: $0)
            }
            print(
                "bench-tiles \(name): \(transcripts.count) transcripts (\(transcripts.map(\.count).map(String.init).joined(separator: ", ")) messages), "
                    + "window \(Int(size.width))×\(Int(size.height)), never ordered front, every pane full")
            print(
                "host     panes  open ms  divider step ms (median/p95)  resize step ms (median/p95)  "
                    + "resize, peers held ms (median/p95)  peers' catch-up ms")
            for count in counts {
                for kind in kinds {
                    await measure(kind, count: count, entries: entries, backend: backend)
                }
            }
        }
        for kind in kinds {
            await TileBench.bench(panes: 4, rate: 80, rows: 600, seconds: 20, kind: kind)
        }
    }

    /// One scripted server whose sessions are the cached transcripts, cycled to eight chats.
    private static func backendServing(_ transcripts: [[ChatMessage]]) -> MockBackend {
        var scripts: [String: [MockScriptStep]] = [:]
        var sessions: [AgentSession] = []
        let now = Date()
        for index in 0..<8 {
            let id = "bench-\(index)"
            scripts[id] = transcripts[index % transcripts.count].map {
                MockScriptStep(.messageUpserted($0, replaceParts: true), delay: .zero)
            }
            sessions.append(
                AgentSession(
                    id: id, agentType: .claudeCode, title: "Bench \(index + 1)",
                    directory: "/bench/\(index)", createdAt: now, updatedAt: now))
        }
        return MockBackend(
            agentType: .claudeCode, scripts: scripts, interactive: true, sessions: sessions)
    }

    static func makeHost(_ kind: Kind) -> any PaneTiling {
        switch kind {
        case .canvas: return TileHost()
        case .legacy: return SplitPaneHost()
        }
    }

    private static func measure(
        _ kind: Kind, count: Int, entries: [SessionEntry], backend: any CodingAgentBackend
    ) async {
        let host = makeHost(kind)
        host.makePane = { TranscriptViewController() }
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .resizable],
            backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        windows.append(window)
        window.contentView = host.view
        host.bootstrap()
        let started = CACurrentMediaTime()
        var panes: [TranscriptViewController] = []
        if count > 1 {
            let arrangement: SplitArrangement =
                count == 2 ? .sideBySide : count == 4 ? .grid : .mainStack
            if let layout = SplitEven.arrange(ids: (0..<count).map { _ in PaneID() }, as: arrangement) {
                _ = host.restore(SplitSnapshot(layout: layout, sessions: [:]))
            }
        }
        panes = host.orderedPanes
        for (index, pane) in panes.enumerated() {
            pane.open(entries[index % entries.count], backend: backend)
            pane.setFocusedPane(index == 0)
        }
        await wait(30) {
            panes.allSatisfy { $0.currentState?.hasLoadedTranscript == true && $0.holdsRows }
        }
        window.contentView?.layoutSubtreeIfNeeded()
        let open = CACurrentMediaTime() - started
        await wait(1.5)
        window.contentView?.layoutSubtreeIfNeeded()

        var steps: [Double] = []
        for step in 0..<24 {
            let delta: CGFloat = step % 2 == 0 ? 6 : -6
            steps.append(
                time {
                    dividerStep(host, by: delta)
                    window.contentView?.layoutSubtreeIfNeeded()
                })
        }
        var heldSteps: [Double] = []
        var dragCatchUp: Double?
        if let canvas = host as? TileHost, count > 1 {
            canvas.simulateDividerDrag(true)
            for step in 0..<24 {
                let delta: CGFloat = step % 2 == 0 ? 6 : -6
                heldSteps.append(
                    time {
                        dividerStep(host, by: delta)
                        window.contentView?.layoutSubtreeIfNeeded()
                    })
            }
            dividerStep(host, by: 12)
            dragCatchUp = time {
                canvas.simulateDividerDrag(false)
                window.contentView?.layoutSubtreeIfNeeded()
            }
        }
        var resizes: [Double] = []
        for step in 0..<16 {
            let width = size.width - (step % 2 == 0 ? 40 : 0)
            resizes.append(
                time {
                    window.setContentSize(NSSize(width: width, height: size.height))
                    window.contentView?.layoutSubtreeIfNeeded()
                })
        }
        var held: [Double] = []
        var catchUp: Double?
        if let canvas = host as? TileHost {
            canvas.simulateLiveResize(true)
            for step in 0..<16 {
                let width = size.width - (step % 2 == 0 ? 0 : 40)
                held.append(
                    time {
                        window.setContentSize(NSSize(width: width, height: size.height))
                        window.contentView?.layoutSubtreeIfNeeded()
                    })
            }
            catchUp = time {
                canvas.simulateLiveResize(false)
                window.contentView?.layoutSubtreeIfNeeded()
            }
            window.setContentSize(size)
            window.contentView?.layoutSubtreeIfNeeded()
        }
        let heldText =
            held.isEmpty ? "—" : "\(ms(median(held))) / \(ms(p95(held)))"
        print(
            "\(kind.rawValue.padding(toLength: 8, withPad: " ", startingAt: 0)) \(String(count).padding(toLength: 6, withPad: " ", startingAt: 0)) "
                + "\(ms(open).padding(toLength: 8, withPad: " ", startingAt: 0)) "
                + "\("\(ms(median(steps))) / \(ms(p95(steps)))".padding(toLength: 29, withPad: " ", startingAt: 0)) "
                + "\("\(ms(median(resizes))) / \(ms(p95(resizes)))".padding(toLength: 28, withPad: " ", startingAt: 0)) "
                + heldText.padding(toLength: 36, withPad: " ", startingAt: 0)
                + (catchUp.map { "\(ms($0)) for \(max(0, count - 1)) peers" } ?? "—"))
        if !heldSteps.isEmpty {
            print(
                "         divider step with the rows held: \(ms(median(heldSteps))) / \(ms(p95(heldSteps))) ms, "
                    + "every pane catching up once at the end: \(dragCatchUp.map(ms) ?? "—") ms")
        }
        host.eachPane { $0.shutdownPane() }
        window.contentView = nil
        await wait(0.5)
    }

    /// Moves the first divider that changes widths — the costly kind, every row re-measures — by
    /// `delta` points the way a drag step does in each host.
    static func dividerStep(_ host: any PaneTiling, by delta: CGFloat) {
        if let canvas = host as? TileHost {
            guard
                let divider = canvas.placement?.dividers.first(where: { $0.line.height > $0.line.width })
                    ?? canvas.placement?.dividers.first
            else { return }
            canvas.drag(divider.id, to: divider.position + Double(delta))
        } else if let legacy = host as? SplitPaneHost {
            legacy.benchNudgeFirstDivider(by: delta)
        }
    }
}
