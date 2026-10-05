import AppKit
import CodingAgentKit
import TailscodeCore

/// The live pipeline checked against the soak server, with no network: a frame applies the newest
/// of every state that arrived since the last one, two panes on one chat share one conversation
/// and one run of the edge services, a parked pane owns nothing and comes back, a closed pane is
/// freed, and a split with no room is refused.
///
/// A transcript pane cannot be built under `--selftest`: that path services the main queue from a
/// worker thread with the real main thread parked, and AppKit's controls lay themselves out by
/// waiting for the real main thread. So the selftest runs these in a child process of its own
/// binary (`--bench tiles-check`), where AppKit runs, and reads back what it printed.
@MainActor
enum TileChecks {
    nonisolated static let spec = "tiles-check"
    /// The numbers behind the verdict, printed by the child beside it.
    private static var notes: [String] = []

    /// The child's side: run the checks under a running application and print the verdict.
    static func runAsChild() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        Task { @MainActor in
            let failures = await run()
            print("TILES_NOTES \(notes.joined(separator: " · "))")
            print(failures.isEmpty ? "TILES_OK" : "TILES_FAILED \(failures.joined(separator: " · "))")
            exit(failures.isEmpty ? 0 : 1)
        }
        app.run()
        exit(1)
    }

    /// The selftest's side, begun at once so the child runs beside the rest of the selftest. The
    /// verdict is read with a blocking wait rather than an `await`: under `--selftest` a suspension
    /// can resume the main queue on another thread, and AppKit refuses a layout engine touched from
    /// two threads.
    final class Child {
        private let process = Process()
        private let pipe = Pipe()
        private var startFailure: String?

        init() {
            guard let executable = Bundle.main.executablePath else {
                startFailure = "no executable path"
                return
            }
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = ["--bench", TileChecks.spec]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                startFailure = "could not start the check: \(error)"
            }
        }

        func verdict(timeout: TimeInterval = 45) -> (failures: [String], notes: String) {
            if let startFailure { return ([startFailure], "") }
            let deadline = Date().addingTimeInterval(timeout)
            let pid = process.processIdentifier
            var exited = false
            while !exited, Date() < deadline {
                var status: Int32 = 0
                let reaped = waitpid(pid, &status, WNOHANG)
                exited = reaped == pid || reaped == -1
                if !exited { usleep(50_000) }
            }
            if !exited {
                kill(pid, SIGKILL)
                return (["the check did not finish in \(Int(timeout)) s"], "")
            }
            let lines = String(
                decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self
            ).split(separator: "\n")
            let notes = lines.last { $0.hasPrefix("TILES_NOTES ") }
                .map { String($0.dropFirst("TILES_NOTES ".count)) } ?? ""
            guard
                let verdict = lines.last(where: { $0 == "TILES_OK" || $0.hasPrefix("TILES_FAILED") })
            else { return (["the check printed no verdict"], notes) }
            return (
                verdict == "TILES_OK" ? [] : [String(verdict.dropFirst("TILES_FAILED ".count))],
                notes
            )
        }
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func run() async -> [String] {
        _ = NSApplication.shared
        var failures: [String] = []
        let configuration = SoakWorld.Configuration(
            panes: 3, tokensPerSecond: 400, rows: 60, turnSeconds: 90, listedSessions: 3)
        let backend = SoakWorld.install(configuration)
        guard let sessions = try? await backend.listSessions(), sessions.count >= 3 else {
            return ["soak server listed no sessions"]
        }
        let entries = sessions.prefix(3).map {
            SessionEntry(
                profileID: SoakWorld.profile.id, profileName: "soak", host: "soak",
                backendType: .claudeCode, session: $0)
        }
        let runtime = TileRuntime.shared
        let first = TranscriptViewController()
        let second = TranscriptViewController()
        _ = first.view
        _ = second.view
        do {
            try await checkCoalescing(first, entry: entries[0], backend: backend)
        } catch {
            failures.append("coalescing: \(error)")
        }
        do {
            try await checkSharing(first, second, entry: entries[0], backend: backend)
        } catch {
            failures.append("sharing: \(error)")
        }
        do {
            try await checkParking(first, second, key: TileRuntime.key(entries[0]))
        } catch {
            failures.append("parking: \(error)")
        }
        do {
            try await checkRelease(entry: entries[1], backend: backend)
        } catch {
            failures.append("pane lifetime: \(error)")
        }
        do {
            try checkRoom()
        } catch {
            failures.append("room: \(error)")
        }
        first.shutdownPane()
        second.shutdownPane()
        runtime.stopWatching(TileRuntime.key(entries[0]))
        return failures
    }

    private static func expect(_ condition: Bool, _ message: @autoclosure () -> String) throws {
        guard condition else { throw Failure(description: message()) }
    }

    private static func wait(
        _ seconds: Double, until condition: () -> Bool = { false }
    ) async {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !condition() {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Holds the main thread the way a long frame does.
    private static func blockMain(_ seconds: Double) {
        usleep(useconds_t(seconds * 1_000_000))
    }

    /// States pile up while the main thread is busy; the next frame applies one, the newest.
    private static func checkCoalescing(
        _ pane: TranscriptViewController, entry: SessionEntry, backend: any CodingAgentBackend
    ) async throws {
        pane.open(entry, backend: backend)
        await wait(8) { pane.appliedFrames > 0 && pane.currentState?.hasLoadedTranscript == true }
        try expect(pane.appliedFrames > 0, "the transcript never arrived")
        let conversation = TileRuntime.shared.conversation(for: entry, backend: backend)
        try await conversation.send(
            "stream", model: nil, reasoningEffort: nil, attachments: [])
        await wait(5) { pane.currentState?.status == .running }
        try expect(pane.currentState?.status == .running, "the reply never started")
        await wait(0.4)
        let applied = pane.appliedFrames
        let skipped = pane.skippedFrames
        blockMain(0.3)
        TileRuntime.shared.clock.drainNow()
        notes.append(
            "one frame after a 300 ms stall applied \(pane.appliedFrames - applied), folding \(pane.skippedFrames - skipped)")
        try expect(
            pane.appliedFrames == applied + 1,
            "one frame applied \(pane.appliedFrames - applied) states")
        try expect(
            pane.skippedFrames - skipped >= 5,
            "only \(pane.skippedFrames - skipped) states were folded into the frame")
    }

    /// Two panes on one chat: one conversation, one stream, one edge run per state, one drainer.
    private static func checkSharing(
        _ first: TranscriptViewController, _ second: TranscriptViewController,
        entry: SessionEntry, backend: any CodingAgentBackend
    ) async throws {
        let runtime = TileRuntime.shared
        let key = TileRuntime.key(entry)
        second.open(entry, backend: backend)
        await wait(2) { second.appliedFrames > 0 }
        try expect(second.appliedFrames > 0, "the second pane never drew")
        try expect(runtime.hub.leaseCount(key) == 2, "\(runtime.hub.leaseCount(key)) leases, not 2")
        try expect(runtime.paneCount(key) == 2, "\(runtime.paneCount(key)) panes hold the chat")
        try expect(
            runtime.ownsQueue(first, of: key) && !runtime.ownsQueue(second, of: key),
            "the queue does not have exactly one drainer")
        let edgesBefore = runtime.edgeStates[key] ?? 0
        let sequenceBefore = runtime.hub.latest(key)?.sequence ?? 0
        await wait(1)
        let edges = (runtime.edgeStates[key] ?? 0) - edgesBefore
        let states = Int((runtime.hub.latest(key)?.sequence ?? 0) - sequenceBefore)
        notes.append("two panes: \(edges) edge runs for \(states) states")
        try expect(edges > 0, "the edge services saw nothing")
        try expect(edges <= states, "\(edges) edge runs for \(states) states")
    }

    /// A parked pane gives up its lease and every clock and stops drawing while its twin goes on;
    /// unparked, it draws again.
    private static func checkParking(
        _ first: TranscriptViewController, _ second: TranscriptViewController, key: LiveKey
    ) async throws {
        let runtime = TileRuntime.shared
        second.setParked(true)
        try expect(!second.ownsClocks, "a parked pane still owns a clock or a lease")
        try expect(runtime.paneCount(key) == 1, "a parked pane still holds the chat")
        let frozen = second.appliedFrames
        let moving = first.appliedFrames
        await wait(0.6)
        try expect(second.appliedFrames == frozen, "a parked pane went on drawing")
        try expect(first.appliedFrames > moving, "the pane beside it stopped drawing")
        second.setParked(false)
        try expect(second.lease != nil, "an unparked pane took no lease")
        await wait(1) { second.appliedFrames > frozen }
        try expect(second.appliedFrames > frozen, "an unparked pane never drew again")
    }

    /// Shut down, a pane lets go of everything and is freed.
    private static func checkRelease(entry: SessionEntry, backend: any CodingAgentBackend) async throws {
        weak var released: TranscriptViewController?
        do {
            let pane = TranscriptViewController()
            _ = pane.view
            pane.open(entry, backend: backend)
            await wait(3) { pane.appliedFrames > 0 }
            try expect(pane.appliedFrames > 0, "the pane never drew")
            pane.shutdownPane()
            try expect(!pane.ownsClocks, "a shut-down pane still owns a clock or a lease")
            released = pane
        }
        await wait(2) { released == nil }
        try expect(released == nil, "a shut-down pane was never freed")
    }

    /// A pane too small to halve refuses with a reason; a roomy one may split.
    private static func checkRoom() throws {
        let host = SplitPaneHost()
        host.makePane = { TranscriptViewController() }
        host.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        host.bootstrap()
        let id = host.layout.focusedPane
        try expect(host.canSplit(id, axis: .horizontal), "a 1200-point pane may not split")
        var refusals: [String] = []
        host.onRefused = { refusals.append($0) }
        host.view.frame = NSRect(x: 0, y: 0, width: 300, height: 300)
        host.splitActive(axis: .horizontal)
        try expect(host.paneCount == 1, "a 300-point pane split")
        try expect(refusals.count == 1, "the refusal was not said")
        try expect(host.ratioCaptures == 0, "a programmatic layout wrote a ratio")
        host.eachPane { $0.shutdownPane() }
    }
}
