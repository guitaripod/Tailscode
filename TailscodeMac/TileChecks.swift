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
        do {
            try await checkCanvas(entries: Array(entries), backend: backend)
        } catch {
            failures.append("tile canvas: \(error)")
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

    /// A pane too small to halve refuses with a reason; a roomy one may split — in the canvas and
    /// in the legacy host alike.
    private static func checkRoom() throws {
        let legacy = SplitPaneHost()
        legacy.makePane = { TranscriptViewController() }
        legacy.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        legacy.bootstrap()
        try expect(legacy.canSplit(legacy.layout.focusedPane, axis: .horizontal), "a 1200-point pane may not split")
        let canvas = TileHost()
        canvas.makePane = { TranscriptViewController() }
        canvas.view.frame = NSRect(x: 0, y: 0, width: 1200, height: 800)
        canvas.bootstrap()
        try expect(canvas.canSplit(canvas.layout.focusedPane, axis: .horizontal), "a 1200-point canvas pane may not split")
        for host in [legacy, canvas] as [any PaneTiling] {
            var refusals: [String] = []
            host.onRefused = { refusals.append($0) }
            host.view.frame = NSRect(x: 0, y: 0, width: 300, height: 300)
            host.view.layoutSubtreeIfNeeded()
            host.splitActive(axis: .horizontal)
            try expect(host.paneCount == 1, "a 300-point pane split")
            try expect(refusals.count == 1, "the refusal was not said")
            host.eachPane { $0.shutdownPane() }
        }
        try expect(legacy.ratioCaptures == 0, "a programmatic layout wrote a ratio")
        try expect(canvas.ratioCaptures == 0, "a programmatic layout wrote a ratio in the canvas")
    }

    /// The frame-placed canvas: every shell sits exactly where Core's placement puts it for a run
    /// of trees; a pane the placement hides is hidden and never takes a press; no pane view changes
    /// superview across a hammer of verbs; first responder survives a split; a divider drag moves
    /// the rectangles and writes one ratio when it ends; a pane squeezed below the full minimum, or
    /// over the governor's budget, becomes a glance that owns no clock of its own and lets go of
    /// its rows; a closed pane is freed.
    private static func checkCanvas(
        entries: [SessionEntry], backend: any CodingAgentBackend
    ) async throws {
        let host = TileHost()
        host.makePane = { TranscriptViewController() }
        host.demotedKeep = 0.4
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800), styleMask: [.borderless],
            backing: .buffered, defer: false)
        window.contentView = host.view
        host.bootstrap()
        host.view.layoutSubtreeIfNeeded()

        func framesMatch(_ label: String) throws {
            host.view.layoutSubtreeIfNeeded()
            let size = host.view.bounds.size
            let expected = host.layout.placement(
                in: SplitSize(width: Double(size.width), height: Double(size.height)),
                scale: Double(window.backingScaleFactor)
            ) { id in
                PaneSizing.layoutMinimum(kind: host.panes[id]?.paneKind(held: false) ?? .empty)
            }
            for id in host.layout.paneIDs {
                guard let shell = host.shells[id] else { throw Failure(description: "\(label): a pane has no shell") }
                if let rect = expected.frames[id] {
                    let frame = NSRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
                    try expect(shell.frame == frame, "\(label): a shell sits at \(shell.frame), not \(frame)")
                    try expect(!shell.isHidden, "\(label): a placed pane is hidden")
                } else {
                    try expect(shell.isHidden, "\(label): a pane the placement hides is shown")
                }
            }
            try expect(
                host.dividerViews.count == expected.dividers.count,
                "\(label): \(host.dividerViews.count) dividers for \(expected.dividers.count) seams")
        }

        try framesMatch("one pane")
        host.splitActive(axis: .horizontal)
        try framesMatch("two columns")
        host.splitActive(axis: .vertical)
        try framesMatch("a column and a stack")
        host.splitActive(axis: .horizontal)
        try framesMatch("four panes")
        for arrangement in SplitArrangement.cycle {
            host.arrange(arrangement)
            try framesMatch(arrangement.rawValue)
        }
        try expect(host.paneCount == 4, "\(host.paneCount) panes after the splits")

        let superviews = host.layout.paneIDs.map { id in
            (ObjectIdentifier(host.shells[id]!.superview!), ObjectIdentifier(host.panes[id]!.view.superview!))
        }
        let adds = host.canvas.paneAdds
        host.exchangeActive()
        host.rotate(forward: true)
        host.promoteActive()
        host.arrange(nil)
        host.zoomActive()
        try framesMatch("zoomed")
        let zoomed = host.layout.focusedPane
        for id in host.layout.paneIDs where id != zoomed {
            let shell = host.shells[id]!
            try expect(shell.isHidden, "a pane the zoom hides is shown")
            try expect(host.panes[id]!.isParked, "a pane the zoom hides is not parked")
        }
        try expect(!host.stripView.isHidden, "a zoom shows no strip")
        try expect(
            host.stripView.chips.count == host.paneCount - 1,
            "the strip names \(host.stripView.chips.count) of \(host.paneCount - 1) hidden panes")
        host.zoomActive()
        host.equalize()
        host.cycleFocus(forward: true)
        host.moveActiveToEdge(.left)
        host.resizeActive(.right, large: false)
        host.arrange(.mainStack)
        let after = host.layout.paneIDs.map { id in
            (ObjectIdentifier(host.shells[id]!.superview!), ObjectIdentifier(host.panes[id]!.view.superview!))
        }
        try expect(
            Set(superviews.map(\.0)) == Set(after.map(\.0)) && Set(superviews.map(\.1)) == Set(after.map(\.1)),
            "a pane changed superview across the verbs")
        try expect(host.canvas.reparents == 0, "\(host.canvas.reparents) panes were re-parented")
        try expect(host.canvas.paneAdds == adds, "the verbs added \(host.canvas.paneAdds - adds) pane views")
        try expect(host.canvas.paneRemovals == 0, "the verbs removed \(host.canvas.paneRemovals) pane views")
        try framesMatch("main and stack")
        notes.append("canvas: 4 panes, \(SplitArrangement.cycle.count) arrangements and 11 verbs, 0 re-parents")

        host.view.setFrameSize(NSSize(width: 320, height: 800))
        try framesMatch("narrow")
        let placement = host.placement
        try expect(placement?.hiddenReason == .noRoom, "a narrow window hid nothing")
        for id in placement?.hidden ?? [] {
            guard let pane = host.panes[id], let shell = host.shells[id] else { continue }
            try expect(shell.isHidden, "a pane with no room is shown")
            let center = NSPoint(x: shell.frame.midX, y: shell.frame.midY)
            let inWindow = host.view.convert(center, to: nil)
            try expect(host.pane(atWindowPoint: inWindow) !== pane, "a hidden pane took a press")
        }
        if let hidden = placement?.hidden.first {
            host.reveal(hidden)
            try expect(host.placement?.isPlaced(hidden) == true, "a chip pressed did not bring its pane in")
        }
        host.view.setFrameSize(NSSize(width: 1200, height: 800))
        try framesMatch("grown back")
        try expect(host.placement?.hidden.isEmpty == true, "growing the window back left a pane hidden")

        let field = NSTextField(frame: NSRect(x: 20, y: 20, width: 200, height: 22))
        host.active.view.addSubview(field)
        try expect(window.makeFirstResponder(field), "a field in a pane could not take the keyboard")
        let responder = window.firstResponder
        host.splitActive(axis: .vertical)
        try expect(window.firstResponder === responder, "a split took the first responder")
        field.removeFromSuperview()
        try framesMatch("five panes")

        let captures = host.ratioCaptures
        if let divider = host.placement?.dividers.first {
            let before = host.shells.values.map(\.frame)
            host.drag(divider.id, to: divider.position + 40)
            try expect(host.shells.values.map(\.frame) != before, "a divider drag moved nothing")
            try framesMatch("dragged")
            try expect(host.ratioCaptures == captures, "a drag step wrote a ratio before it ended")
        }

        let chat = host.active
        chat.open(entries[2], backend: backend)
        await wait(3) { chat.appliedFrames > 0 }
        try expect(chat.appliedFrames > 0, "the chat in the canvas never drew")
        host.collapse(to: chat)
        host.splitActive(axis: .horizontal)
        let chatID = host.id(of: chat)!
        let peer = host.active
        try expect(peer !== chat, "the split did not focus the new pane")
        peer.open(entries[1], backend: backend)
        await wait(3) { peer.appliedFrames > 0 }
        var governor = TileGovernor(cores: 8)
        let decision = governor.evaluate(
            now: 100, sample: GovernorSample(), panes: host.seatbeltPanes(held: [:]).facts,
            setting: .count(1))
        host.applyGovernor(decision)
        try expect(host.face(of: chatID) == .glance, "a peer over the budget is \(String(describing: host.face(of: chatID)))")
        try expect(!chat.ownsClocks, "a glance's conversation still owns a clock or a lease")
        try expect(host.feedCount() == 1, "the glance holds \(host.feedCount()) feeds")
        await wait(1.5) { !chat.holdsRows }
        try expect(!chat.holdsRows, "a demoted pane kept its rows past its keep")
        host.focus(chat, grabKeyboard: false)
        try expect(host.face(of: chatID) == .full, "a focused glance did not become whole")
        await wait(3) { chat.holdsRows }
        try expect(chat.holdsRows, "a pane made whole again never rebuilt its rows")
        host.view.setFrameSize(NSSize(width: 460, height: 800))
        host.view.layoutSubtreeIfNeeded()
        await wait(0.3)
        let squeezed = host.layout.paneIDs.filter { host.face(of: $0) == .glance }.count
        try expect(squeezed >= 1, "a pane under the full minimum stayed whole")
        host.view.setFrameSize(NSSize(width: 1200, height: 800))
        host.view.layoutSubtreeIfNeeded()

        weak var closed: TranscriptViewController?
        weak var closedShell: TileShellView?
        host.splitActive(axis: .vertical)
        host.active.open(entries[0], backend: backend)
        closed = host.active
        closedShell = host.shells[host.layout.focusedPane]
        host.closeActive()
        await wait(3) { closed == nil && closedShell == nil }
        try expect(closed == nil, "a closed pane was never freed")
        try expect(closedShell == nil, "a closed pane's shell was never freed")
        host.eachPane { $0.shutdownPane() }
        notes.append("canvas glance: demoted, released rows, came back whole")
    }
}
