import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

extension SelfTest {
    /// Everything the brain promises that a screenshot cannot say: where each turn's brain goes among
    /// the rows and what it takes with it, that the Lines style and a machine without the layers
    /// keep today's rows exactly, that a streamed token reads one turn and not the conversation, and
    /// — on a real widget in a real window — the stage's layout, hit test, hover card, pin, replay,
    /// scrub and dive, that a settled head owns no clock, that reduced motion holds every state
    /// still, that a hidden pane owns no picture, and that closing the last head frees the layers.
    static func checkBrain() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("brain: \(label)") }
            checks += 1
        }

        try checkBrainRows(expect)
        try checkBrainFallbacks(expect)
        try checkBrainWidget(expect)
        return checks
    }

    private static func brainMessages() -> [ChatMessage] { NeuralDemo.conversation() }

    private static func brainState(_ messages: [ChatMessage], running: Bool = false) -> ConversationState {
        ConversationState(
            messages: messages, status: running ? .running : .idle, connection: .live,
            hasLoadedTranscript: true)
    }

    private static func brainBuilder(
        style: ActivityStyle, rowsShown: Set<String> = []
    ) -> TranscriptRowBuilder {
        let builder = TranscriptRowBuilder()
        builder.setBrains(
            BrainBuildSettings(
                style: style, choices: [:], rowsShown: rowsShown, look: MatrixTheme.palette.name))
        return builder
    }

    private static func isBrain(_ row: TranscriptRow) -> Bool {
        if case .brain = row.kind { return true }
        return false
    }

    private static func isStepRow(_ row: TranscriptRow) -> Bool {
        switch row.kind {
        case .tool, .reasoning, .run: return true
        default: return false
        }
    }

    private static func checkBrainRows(_ expect: (Bool, String) throws -> Void) throws {
        let messages = brainMessages()
        let state = brainState(messages)
        let rows = brainBuilder(style: .brain).rows(state: state)
        let brains = rows.compactMap { row -> BrainRow? in
            if case .brain(let brain) = row.kind { return brain }
            return nil
        }
        try expect(brains.count == 2, "one brain per turn, two turns, two brains (got \(brains.count))")
        try expect(
            rows.filter(isBrain).map(\.key) == ["brain:a-m1", "brain:b-m1"],
            "a brain row is named for its turn, in the order of the turns")
        try expect(
            brains.map(\.open) == [false, true],
            "the latest turn is open by default and the earlier one is closed")
        try expect(
            !rows.contains(where: isStepRow),
            "the parts a brain consumes build no rows of their own")
        let cards = rows.filter {
            if case .subagent = $0.kind { return true }
            return false
        }
        try expect(cards.count == 2, "a Task keeps its card beside the brain (\(cards.count) cards, want 2)")
        let prose = rows.compactMap { row -> String? in
            if case .agentProse(let text, _) = row.kind { return text }
            return nil
        }
        try expect(
            !prose.contains { $0.contains("Building it from the existing film rig") || $0.contains("Song mapped") },
            "a note the agent wrote on the way is a node, not a paragraph")
        try expect(
            prose.contains { $0.contains("Fixed. Both switches answer the new cases.") }
                && prose.contains { $0.contains("Done. The demo is at") },
            "the answer after the last tool stays a paragraph under its brain")
        let firstBrain = rows.firstIndex(where: isBrain) ?? -1
        let firstCard = rows.firstIndex(where: {
            if case .subagent = $0.kind { return true }
            return false
        }) ?? -1
        try expect(
            firstBrain >= 0 && firstBrain < firstCard,
            "the brain stands where the turn's first step was, above the cards")
        try expect(
            rows.map(\.key).count == Set(rows.map(\.key)).count, "every row key is unique")

        let lines = brainBuilder(style: .lines).rows(state: state)
        let today = TranscriptRowBuilder().rows(state: state)
        try expect(!lines.contains(where: isBrain), "the Lines style draws no brain")
        try expect(lines == today, "the Lines style gives today's rows exactly")
        try expect(lines.contains(where: isStepRow), "and those rows are the step rows")

        let listed = brainBuilder(style: .brain, rowsShown: ["b-m1"]).rows(state: state)
        let listedBrains = listed.filter(isBrain)
        try expect(listedBrains.count == 2, "Rows keeps the brain beside the rows it lists")
        try expect(
            listed.contains(where: isStepRow) && listed.count > rows.count,
            "Rows lists the old step rows for that turn")
        let firstOfB = listed.firstIndex { $0.key == "brain:b-m1" } ?? -1
        let rowsOfA = listed[..<firstOfB].filter(isStepRow)
        try expect(rowsOfA.isEmpty, "and only for the turn that asked")

        let search = brains[1].turn.steps.map { "\($0.title) \($0.detail)" }.joined(separator: " ")
        try expect(
            rows.first { $0.key == "brain:b-m1" }?.searchText.contains("ffprobe") == true
                && search.contains("ffprobe"),
            "in-conversation find reads a brain's step titles and details")

        let builder = brainBuilder(style: .brain)
        _ = builder.rows(state: state)
        let first = builder.brainReadings
        var growing = messages
        guard var answer = growing.popLast() else { throw SelfTestFailure("brain: no answer") }
        for length in stride(from: 10, through: 60, by: 10) {
            answer.parts = [MessagePart(id: "p0", kind: .text(String(repeating: "x", count: length)))]
            answer.isStreaming = true
            _ = builder.rows(state: brainState(growing + [answer], running: true))
        }
        let after = builder.brainReadings
        let streamed = after.partitions - first.partitions
        try expect(
            streamed <= 6 + 2,
            "six streamed tokens read the turn being written and not the conversation (read \(streamed))")
        try expect(
            after.reuses - first.reuses >= 6,
            "and the turn that finished is handed back from the cache each time")
    }

    private static func checkBrainFallbacks(_ expect: (Bool, String) throws -> Void) throws {
        let empty = FileManager.default.temporaryDirectory
            .appendingPathComponent("tailscode-neural-empty-\(getpid())")
        try? FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        let saved = ProcessInfo.processInfo.environment[NeuralAssetFiles.variable]
        setenv(NeuralAssetFiles.variable, empty.path, 1)
        NeuralAssetFiles.forget()
        defer {
            if let saved { setenv(NeuralAssetFiles.variable, saved, 1) } else { unsetenv(NeuralAssetFiles.variable) }
            NeuralAssetFiles.forget()
            try? FileManager.default.removeItem(at: empty)
        }
        let candidates = NeuralAssetFiles.candidates()
        try expect(
            candidates.first?.path == empty.path,
            "an explicit folder is the first place the layers are looked for")
        let stillFound = NeuralAssetFiles.isAvailable
        if !stillFound {
            let before = AppLog.tail(lines: 400).components(separatedBy: "no layer set found").count - 1
            let style = Preferences.effectiveActivityStyle
            _ = Preferences.effectiveActivityStyle
            Thread.sleep(forTimeInterval: 0.3)
            let after = AppLog.tail(lines: 400).components(separatedBy: "no layer set found").count - 1
            try expect(style == .lines, "layers that are not on the machine keep the Lines style")
            try expect(after - before <= 1, "and say so once in the log, however often it is asked")
        } else {
            try expect(
                NeuralAssetFiles.directory?.path != empty.path,
                "an empty folder is not taken for a layer set")
        }
        NeuralAssetFiles.forget()
        unsetenv(NeuralAssetFiles.variable)
        if let saved { setenv(NeuralAssetFiles.variable, saved, 1) }
        NeuralAssetFiles.forget()
        try expect(
            NeuralAssetFiles.decode("/nonexistent/chassis.png") == nil,
            "a layer that cannot be read is nothing, not a trap")
    }

    private static func checkBrainWidget(_ expect: (Bool, String) throws -> Void) throws {
        guard gtk_init_check() != 0, NeuralAssetFiles.isAvailable else { return }
        Gtk.installStyle()
        func pump(_ seconds: Double, until done: () -> Bool = { false }) -> Bool {
            let end = Date().addingTimeInterval(seconds)
            while Date() < end {
                while Date() < end, g_main_context_iteration(nil, 0) != 0 {}
                if done() { return true }
                Thread.sleep(forTimeInterval: 0.01)
            }
            return done()
        }

        let messages = NeuralDemo.turn(prefix: "w-", origin: Date().timeIntervalSince1970 - 600)
        let state = brainState(messages)
        let builder = brainBuilder(style: .brain)
        let rows = builder.rows(state: state)
        guard let row = rows.first(where: isBrain), case .brain(let brain) = row.kind else {
            throw SelfTestFailure("brain: the scripted turn made no brain row")
        }

        let host = BrainHost()
        host.sessionKey = "selftest"
        host.policy = { builder.brainPolicy }
        let context = TranscriptContext()
        context.brains = host
        let window = gtk_window_new()!
        gtk_window_set_default_size(ptr(window), 1000, 800)
        let widget = BrainView.make(brain, context: context)
        let holder = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        gtk_box_append(ptr(holder), widget)
        gtk_window_set_child(ptr(window), holder)
        gtk_window_present(ptr(window))
        guard let view = BrainView.current(of: widget) else {
            throw SelfTestFailure("brain: the row's widget carries no view")
        }
        try expect(view.isOpen && view.hasStage, "the open latest turn builds its stage")
        let ready = pump(15) { view.stage?.hasRenderer == true && view.stage?.hasPicture == true }
        try expect(ready, "the compositor is built off the main loop and the first picture is drawn")
        guard let stage = view.stage else { throw SelfTestFailure("brain: no stage") }

        let size = stage.size
        try expect(
            size.width > 0 && size.width <= 760
                && abs(Double(size.height) - Double(size.width) * 420 / 640) <= 1.5,
            "the stage keeps the head's proportions at the width it is given (\(size.width)x\(size.height))")
        try expect(
            stage.footprint > 0 && BrainCompositors.resident.compositors == 1,
            "an open head holds one compositor and two surfaces")

        let id = view.model.steps[0].id
        let node = view.model.layout.placements[id] ?? NeuralPoint(0, 0)
        try expect(
            view.model.hit(at: node, slop: 0) == id,
            "a point on a node finds that node")
        try expect(
            view.model.hit(at: NeuralPoint(node.x + 45, node.y + 45), slop: 0) != id,
            "and a point well off it does not")

        view.hover(id)
        try expect(view.model.card != nil && stage.cardSummary != nil, "hovering a node shows its card")
        try expect(!view.model.hotSteps.isEmpty, "and lights the steps wired to it")
        view.hover(nil)
        try expect(view.model.card == nil, "leaving it takes the card away")
        view.pin(id)
        view.hover(nil)
        try expect(view.model.pinned == id && view.model.card != nil, "a pinned node keeps its card")
        view.clearSelection()
        try expect(view.model.pinned == nil, "Esc or an empty click lets go of it")

        _ = pump(1.0)
        let settledTicks = tailscode_live_ticks()
        _ = pump(0.6)
        try expect(
            !view.isClockRunning && tailscode_live_ticks() == settledTicks,
            "a settled head runs no clock")

        view.toggleReplay()
        try expect(
            view.model.isReplaying && view.isClockRunning,
            "Replay starts the turn again on a clock of its own")
        _ = pump(0.8)
        try expect(
            (view.model.replayFraction(now: BrainClock.now) ?? 0) > 0.01,
            "and the playhead moves")
        view.scrub(to: 0.5)
        try expect(
            view.model.tempo(reduceMotion: false) == .display,
            "scrubbing asks for the display's own rate")
        view.endScrub()
        view.toggleReplay()
        _ = pump(0.3)
        try expect(!view.model.isReplaying && !view.isClockRunning, "stopping the replay stops the clock")

        stage.dive(into: .shell)
        try expect(stage.isDiving, "pressing a zone's name dives into it")
        _ = pump(0.9)
        try expect(!stage.isDiving && stage.diveZone == .shell, "the dive lands on the zone")
        view.escape()
        _ = pump(0.7)
        try expect(stage.diveZone == nil, "Esc surfaces")

        host.suspend()
        _ = pump(0.2)
        try expect(
            !stage.hasRenderer && stage.footprint == 0 && !view.isClockRunning,
            "a hidden pane owns no compositor, no surface and no clock")
        host.resume()
        try expect(
            pump(10) { stage.hasRenderer && stage.footprint > 0 },
            "and takes them again when it is shown")

        let running = brainBuilder(style: .brain)
        let runningMessages = NeuralDemo.turn(
            prefix: "r-", origin: Date().timeIntervalSince1970 - 90, answer: false)
        var live = runningMessages
        if var last = live.popLast() {
            last.isStreaming = true
            last.completedAt = nil
            live.append(last)
        }
        let liveRows = running.rows(state: brainState(live, running: true))
        guard let liveRow = liveRows.first(where: isBrain), case .brain(let liveBrain) = liveRow.kind
        else { throw SelfTestFailure("brain: no brain for a running turn") }
        tailscode_set_animations_enabled(1)
        tailscode_notify_animations()
        let working = BrainView.make(liveBrain, context: context)
        gtk_box_append(ptr(holder), working)
        guard let workingView = BrainView.current(of: working) else {
            throw SelfTestFailure("brain: no view for the running turn")
        }
        _ = pump(0.5)
        try expect(
            workingView.isClockRunning && workingView.model.tempo(reduceMotion: false) == .activity,
            "a turn that is working breathes on the activity clock")
        let ticksBefore = tailscode_live_ticks()
        tailscode_set_animations_enabled(0)
        tailscode_notify_animations()
        _ = pump(0.4)
        try expect(
            !workingView.isClockRunning && tailscode_live_ticks() < ticksBefore,
            "reduced motion holds every state still and takes the clock off")
        tailscode_set_animations_enabled(1)
        tailscode_notify_animations()
        _ = pump(0.4)
        try expect(workingView.isClockRunning, "and the clock comes back when movement is allowed")

        let calm = TileGovernor.animation(level: .calm, reducedMotion: false)
        let critical = TileGovernor.animation(level: .critical, reducedMotion: false)
        CascadeBudget.apply(critical, level: .critical)
        try expect(
            !BrainBudget.stageAllowed, "at the critical level the head is a glyph and builds no stage")
        CascadeBudget.apply(calm, level: .calm)
        try expect(BrainBudget.stageAllowed, "and builds one again once the window recovers")

        gtk_box_remove(ptr(holder), working)
        gtk_window_set_child(ptr(window), nil)
        gtk_window_destroy(ptr(window))
        _ = pump(0.6)
        try expect(
            BrainCompositors.resident.compositors == 1,
            "the last compositor is kept a moment for the next head to take")
        BrainCompositors.dropIdle(olderThan: 0)
        try expect(
            BrainCompositors.resident.compositors == 0 && NeuralAssetStore.shared.retainCount == 0,
            "closing the last head frees the compositor and the decoded layers")
    }
}
