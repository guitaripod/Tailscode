import AppKit
import CodingAgentKit
import TailscodeCore

/// The brain's claims, checked headlessly from `--selftest` inside the chat checks' child, where
/// AppKit lays out on the real main thread: what the rows are with the brain and without it, what a
/// row measures closed and open, what a hover, a click, a key, a dive, a replay and an answer word
/// do, that a settled head runs nothing, that parking and closing let go of the textures, and that
/// the wave's incremental paint is the same picture as the full one. The looks are checked with
/// `--shot`; these are the claims a picture cannot make.
@MainActor
enum BrainChecks {
    private static var windows: [NSWindow] = []

    static func run() throws -> Int {
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("neural trace: \(label)") }
            checks += 1
        }
        try palette(expect)
        try cascadeTail(expect)
        try gates(expect)
        try incremental(expect)
        try rows(expect)
        guard MacBrain.isEnabled else { return checks }
        try views(expect)
        try interaction(expect)
        try motion(expect)
        try lifetime(expect)
        return checks
    }

    static func runPoster() async throws -> Int {
        guard MacBrain.isEnabled else { return 0 }
        var checks = 0
        func expect(_ condition: Bool, _ label: String) throws {
            guard condition else { throw SelfTestFailure("neural trace: \(label)") }
            checks += 1
        }
        let fixture = Fixture()
        guard let turn = fixture.store.order.last else { return 0 }
        let neural = await BrainPoster.render(
            store: fixture.store, context: fixture.context, turnID: turn, style: .neural,
            dark: true, scale: 1)
        let app = await BrainPoster.render(
            store: fixture.store, context: fixture.context, turnID: turn, style: .app, dark: false,
            scale: 1)
        try expect(neural != nil && app != nil, "a settled turn paints a poster in both looks")
        guard let neural, let app else { return checks }
        try expect(
            Array(neural.data.prefix(4)) == [0x89, 0x50, 0x4E, 0x47],
            "the poster leaves as a PNG")
        try expect(
            neural.image.size == NSSize(width: NeuralShare.Card.width, height: NeuralShare.Card.height),
            "the poster is the card's own size, \(neural.image.size)")
        try expect(neural.data != app.data, "the two looks are two pictures")
        try expect(neural.data.count > 60_000, "the head is drawn into the poster (\(neural.data.count) bytes)")
        return checks
    }

    private static func stage(_ root: NSView) {
        let window = NSWindow(
            contentRect: root.frame, styleMask: [.borderless], backing: .buffered, defer: true)
        window.contentView = root
        windows.append(window)
    }

    @MainActor
    private final class Fixture {
        let store = BrainStore()
        let context = TranscriptContext()
        let builder = TranscriptRowBuilder()
        var messages: [ChatMessage]
        var rows: [TranscriptRow] = []

        init(messages: [ChatMessage] = NeuralDemo.conversation(), running: Bool = false) {
            self.messages = messages
            context.brains = store
            builder.brains = store
            rows = builder.rows(for: messages, turnOpen: running)
        }

        var brainRows: [(row: TranscriptRow, brain: BrainRow)] {
            rows.compactMap {
                guard case .brain(let brain) = $0.kind else { return nil }
                return ($0, brain)
            }
        }

        func rebuild(running: Bool = false) {
            rows = builder.rows(for: messages, turnOpen: running)
        }
    }

    private static func palette(_ expect: (Bool, String) throws -> Void) throws {
        let dark = MacBrainPalette.palette(for: NSAppearance(named: .darkAqua) ?? .currentDrawing())
        let light = MacBrainPalette.palette(for: NSAppearance(named: .aqua) ?? .currentDrawing())
        try expect(dark.isDark && !light.isDark, "each appearance gets its own face of the palette")
        try expect(
            NeuralPalette.spill(palette: dark) && !NeuralPalette.spill(palette: light),
            "a light page gets no spill and a dark one does")
        let inks = BrainInks(palette: light)
        try expect(
            inks.dome(.sense) != inks.page(.sense),
            "inside the dome a light palette's colours are lifted off the page's")
    }

    /// The wave's incremental paint is the same picture as building the whole paint again, at every
    /// step of a reveal, and starts over without a trace when the reveal goes back.
    private static func cascadeTail(_ expect: (Bool, String) throws -> Void) throws {
        let source = MacMarkdown.render(
            "Fixed **the build**. See `Parity.swift` and [the docs](https://example.com) for the rest of it, which keeps going for a good while so the wave has a tail to carry. And a second paragraph with *emphasis* in it.")
        let total = source.length
        let buffer = CascadePaintBuffer(rendered: source, key: "k", revealed: 0)
        var agree = true
        var reveals = Array(stride(from: 0, through: total, by: 7))
        reveals.append(total)
        reveals += [total / 2, 3, total]
        for (index, revealed) in reveals.enumerated() {
            let tail = CascadeTail(
                revealed: revealed, span: StreamCascade.span, phase: Double(index % 11) / 11,
                edge: .systemGreen, spark: .white)
            let whole = tail.paint(source, settled: .labelColor)
            let step = buffer.paint(tail, settled: .labelColor)
            if !whole.isEqual(to: step) { agree = false }
        }
        try expect(agree, "the wave's incremental paint equals the full paint at every step of a reveal")
        try expect(
            buffer.matches(rendered: source, key: "k") && !buffer.matches(rendered: source, key: "j"),
            "a paint buffer belongs to one rendering of one row")
    }

    /// The gate: a window nobody can see owns no clock, and the one that can be seen owns one.
    private static func gates(_ expect: (Bool, String) throws -> Void) throws {
        let was = DisplayGate.assumesVisible
        defer { DisplayGate.assumesVisible = was }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
        stage(root)
        DisplayGate.assumesVisible = false
        try expect(
            !DisplayGate.allows(root),
            "a window that was never on screen is not one anybody can see")
        DisplayGate.assumesVisible = true
        try expect(DisplayGate.allows(root), "and under the harness a view in a window may run")
        try expect(!DisplayGate.allows(NSView()), "a view in no window may not")

        DisplayGate.assumesVisible = false
        let face = CallFaceView(frame: NSRect(x: 0, y: 0, width: 30, height: 30))
        root.addSubview(face)
        face.show(.speaking)
        if ActivityPulse.motionAllowed {
            try expect(!face.isTicking, "a speaking face nobody can see runs no clock")
            DisplayGate.assumesVisible = true
            NotificationCenter.default.post(name: NSApplication.didBecomeActiveNotification, object: nil)
            try expect(face.isTicking, "and starts it the moment it can be seen")
        }
        face.removeFromSuperview()

        let before = MarkClock.shared.count
        let label = ActivityMarkLabel(frame: NSRect(x: 0, y: 0, width: 20, height: 14))
        root.addSubview(label)
        label.mark(ActivityKind.retrying(attempt: 1).icon)
        if ActivityPulse.motionAllowed {
            try expect(
                MarkClock.shared.count == before + 1,
                "a sweeping text mark steps on the one shared clock")
        }
        label.removeFromSuperview()
        try expect(MarkClock.shared.count == before, "and leaves it when it leaves its window")
    }

    private static func message(
        _ id: String, _ role: MessageRole, _ kinds: [MessagePart.Kind], at seconds: Double
    ) -> ChatMessage {
        let date = Date(timeIntervalSince1970: 1_792_100_000 + seconds)
        return ChatMessage(
            id: id, role: role, agentType: .claudeCode,
            parts: kinds.enumerated().map { MessagePart(id: "p\($0.offset)", kind: $0.element) },
            createdAt: date, completedAt: date)
    }

    /// A streamed token lays out the newest turn on a prefix that has not moved, and the rows it
    /// gives are exactly the rows a conversation laid out from nothing has: across words arriving, a
    /// turn opening and closing, a new question, a plan joining the turn and a message that changes
    /// far up the page.
    private static func incremental(_ expect: (Bool, String) throws -> Void) throws {
        var stream = NeuralDemo.conversation()
        let builder = TranscriptRowBuilder()
        var open = true
        var agree = true
        var disagreement = ""
        func check(_ step: String) {
            let got = builder.rows(for: stream, turnOpen: open)
            let want = TranscriptRowBuilder.referenceRows(for: stream, turnOpen: open)
            if got != want, agree {
                agree = false
                disagreement = "\(step): \(got.count) rows against \(want.count)"
            }
        }
        check("first")
        let whole = builder.wholeRebuilds
        func grow(_ words: String) {
            guard let last = stream.indices.last(where: { stream[$0].role == .assistant }),
                let part = stream[last].parts.lastIndex(where: {
                    if case .text = $0.kind { return true } else { return false }
                }),
                case .text(let text) = stream[last].parts[part].kind
            else { return }
            stream[last].parts[part].kind = .text(text + words)
        }
        for step in 0..<12 {
            grow(" word\(step) and a few more of them")
            check("word \(step)")
        }
        try expect(
            builder.tailRebuilds >= 10 && builder.wholeRebuilds <= whole + 1,
            "words arriving lay out the newest turn only (\(builder.tailRebuilds) tail, \(builder.wholeRebuilds - whole) whole)")
        open = false
        check("turn closed")
        open = true
        check("turn open again")

        stream += NeuralDemo.buildFix(prefix: "c-", origin: 1_792_200_000)
        check("a new question")
        for step in 0..<4 {
            grow(" and then \(step)")
            check("second turn word \(step)")
        }

        stream.append(
            message(
                "d-u0", .user, [.text("Plan it")], at: 5_000))
        stream.append(
            message(
                "d-m1", .assistant,
                [
                    .tool(
                        ToolCall(
                            id: "plan-1", name: "TodoWrite", status: .completed,
                            input: .object([
                                "todos": .array([
                                    .object([
                                        "content": .string("Read it"), "status": .string("pending"),
                                        "activeForm": .string("Reading"),
                                    ])
                                ])
                            ]), output: nil)),
                    .text("Planned."),
                ], at: 5_001))
        check("a plan joins the turn")
        grow(" more")
        check("words after a plan")
        stream[3] = message(
            "a-m3", .assistant, [.text("Changed far up the page.")], at: 3)
        check("a message far up changes")
        let heads = TranscriptRowBuilder()
        let store = BrainStore()
        heads.brains = store
        let comparison = TranscriptRowBuilder()
        comparison.brains = BrainStore()
        guard MacBrain.isEnabled else {
            try expect(agree, "tail layout equals full layout: \(disagreement)")
            return
        }
        var mismatch = ""
        for step in 0..<8 {
            if step == 5 { open = false }
            if step == 3 { stream[3] = message("a-m3", .assistant, [.text("Changed again."), .tool(ToolCall(id: "late-\(step)", name: "Read", status: .completed, input: .object(["file_path": .string("/src/late.swift")]), output: "ok"))], at: 3) }
            grow(" token \(step)")
            let incremental = heads.rows(for: stream, turnOpen: open)
            comparison.invalidate()
            comparison.brains = BrainStore()
            let fresh = comparison.rows(for: stream, turnOpen: open)
            if incremental.map(\.key) != fresh.map(\.key), mismatch.isEmpty {
                mismatch = "token \(step): \(incremental.count) rows against \(fresh.count)"
            }
        }
        try expect(agree, "tail layout equals full layout: \(disagreement)")
        try expect(
            mismatch.isEmpty, "with heads the tail layout lists the rows the whole one does: \(mismatch)")
    }

    private static func rows(_ expect: (Bool, String) throws -> Void) throws {
        let messages = NeuralDemo.conversation()
        let plain = TranscriptRowBuilder().rows(for: messages)
        guard MacBrain.isAvailable else {
            let fixture = Fixture()
            try expect(
                fixture.rows.map(\.key) == plain.map(\.key),
                "a Mac that cannot draw the head keeps every row as it was")
            return
        }
        MacBrain.forcedStyle = .lines
        let lines = Fixture()
        MacBrain.forcedStyle = nil
        try expect(
            lines.rows.map(\.key) == plain.map(\.key) && lines.brainRows.isEmpty,
            "the Lines style gives today's rows exactly")

        let fixture = Fixture()
        let rows = fixture.rows
        let turns = NeuralTurns.partition(messages: messages, running: false)
        try expect(
            fixture.store.order == turns.filter { !$0.steps.isEmpty }.map(\.id),
            "every turn with steps is a head, oldest first")
        let heads = fixture.brainRows
        try expect(
            heads.map(\.row.key) == fixture.store.order.map { NeuralOpenPolicy.rowID(turnID: $0) },
            "a brain row is brain:<turn id>")
        try expect(
            !rows.contains { if case .run = $0.kind { return true } else { return false } }
                && !rows.contains { if case .reasoning = $0.kind { return true } else { return false } },
            "the steps' own run and thought rows are gone")
        try expect(
            rows.contains { if case .subagent = $0.kind { return true } else { return false } },
            "an agent keeps its card row beside its node")
        for (position, head) in heads.enumerated() {
            guard let index = rows.firstIndex(where: { $0.key == head.row.key }), index > 0 else {
                try expect(false, "head \(position) is in the rows")
                return
            }
            try expect(
                { if case .userText = rows[index - 1].kind { return true } else { return false } }(),
                "head \(position) stands directly under the question that began its turn")
        }
        try expect(
            heads.last?.brain.isOpen == true && heads.first?.brain.isOpen == false,
            "the newest turn is open and the older one is a line")
        try expect(
            rows.last.map { if case .agentProse = $0.kind { true } else { false } } == true,
            "the answer's prose follows its head")

        let partitions = fixture.store.partitions
        fixture.rebuild()
        try expect(fixture.store.partitions == partitions, "a rebuild with nothing new reads no turn")
        var grown = fixture.messages
        if let last = grown.indices.last(where: { grown[$0].role == .assistant }),
            let part = grown[last].parts.lastIndex(where: {
                if case .text = $0.kind { return true } else { return false }
            }),
            case .text(let words) = grown[last].parts[part].kind
        {
            grown[last].parts[part].kind = .text(words + " And one more sentence.")
        }
        fixture.messages = grown
        fixture.rebuild()
        try expect(
            fixture.store.partitions <= partitions + 1,
            "a streamed token reads one turn, not the conversation (\(fixture.store.partitions - partitions))")

        var changed = 0
        fixture.store.onChange = { changed += 1 }
        let older = fixture.store.order[0]
        fixture.store.toggleRows(older)
        fixture.rebuild()
        try expect(changed == 1, "pressing Rows asks for the rows to be rebuilt")
        try expect(
            fixture.rows.contains { if case .run = $0.kind { return true } else { return false } }
                && fixture.brainRows.count == 2,
            "Rows puts the old rows inline under the head, which stays")
        fixture.store.toggleRows(older)
        fixture.rebuild()
        try expect(
            !fixture.rows.contains { if case .run = $0.kind { return true } else { return false } },
            "and takes them out again")

        fixture.store.toggleOpen(older)
        try expect(
            fixture.store.isOpen(older) && !fixture.store.isOpen(fixture.store.order[1]),
            "opening an older head closes the one that was open")
        fixture.store.toggleOpen(older)
        try expect(fixture.store.openTurnID == nil, "and pressing it again closes it")

        var running = NeuralDemo.buildFix(prefix: "a-") + NeuralDemo.turn(prefix: "b-", answer: false)
        let runningTool = running.indices.reversed().compactMap { index -> (Int, Int)? in
            guard running[index].role == .assistant else { return nil }
            guard
                let part = running[index].parts.lastIndex(where: {
                    if case .tool = $0.kind { return true } else { return false }
                })
            else { return nil }
            return (index, part)
        }.first
        if let (index, part) = runningTool, case .tool(var call) = running[index].parts[part].kind {
            call.status = .running
            running[index].parts[part].kind = .tool(call)
            let builder = TranscriptRowBuilder()
            builder.brains = BrainStore()
            _ = builder.rows(for: running, turnOpen: true)
            call.status = .completed
            running[index].parts[part].kind = .tool(call)
            _ = builder.rows(for: running, turnOpen: true)
            try expect(
                builder.takeCompletions() == 1,
                "a call that finishes while the reader waits counts once as an edge")
            _ = builder.rows(for: running, turnOpen: true)
            try expect(builder.takeCompletions() == 0, "and not again")
        }
    }

    private static func views(_ expect: (Bool, String) throws -> Void) throws {
        let fixture = Fixture()
        let heads = fixture.brainRows
        guard heads.count == 2 else {
            try expect(false, "two heads to lay out")
            return
        }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 1400))
        let column = TranscriptColumn()
        column.spacing = MacTheme.Spacing.m
        column.metrics = ChatLayout.metrics
        column.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: root.topAnchor),
            column.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            column.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
        ])
        stage(root)
        var made: [String: BrainRowView] = [:]
        for head in heads {
            guard let view = head.row.makeView(context: fixture.context) as? BrainRowView else {
                try expect(false, "a brain row makes a BrainRowView")
                return
            }
            made[head.brain.turnID] = view
            column.addArrangedSubview(view, spacing: head.row.spacing)
        }
        root.layoutSubtreeIfNeeded()
        let older = made[heads[0].brain.turnID]
        let newest = made[heads[1].brain.turnID]
        guard let older, let newest, let stage = newest.stage else {
            try expect(false, "the newest head is open with a stage")
            return
        }
        try expect(!older.isOpenShown && newest.isOpenShown, "the row built closed has no stage and the open one has")
        let line = ToolRowView.lineHeight
        try expect(
            older.frame.height >= line - 0.5 && older.frame.height < line * 2,
            "a closed head is one line (\(older.frame.height) against \(line))")
        let first = fixture.store.entry(heads[0].brain.turnID)
        try expect(
            older.linePieces.count == first.map { NeuralReading.line(for: $0.turn).count },
            "the line says how many tools, in Core's words")
        try expect(older.hasReplayChip, "a settled head offers Replay on its line")
        try expect(
            abs(stage.frame.height - stage.frame.width * NeuralDesign.height / NeuralDesign.width) < 1.5
                && stage.frame.width <= BrainStageView.maximumWidth + 1,
            "the stage is the design's shape and never wider than \(BrainStageView.maximumWidth): "
                + "\(stage.frame.width)×\(stage.frame.height)")
        try expect(
            newest.frame.height > stage.frame.height + line,
            "an open head is its line and its stage and what stands under them")
        try expect(
            newest.shareButton.superview != nil && newest.scrubberShown && newest.playButton.superview != nil,
            "a settled open head has its scrubber, Replay and Share")

        let tops = [older.superview?.frame.minY ?? 0, newest.superview?.frame.minY ?? 0]
        try expect(tops[0] < tops[1], "rows stand in order down the page")
        let before = newest.superview?.frame.height ?? 0
        fixture.store.onChange = {
            fixture.rebuild()
            for head in fixture.brainRows { made[head.brain.turnID]?.restate(head.brain) }
        }
        newest.pressLine()
        root.layoutSubtreeIfNeeded()
        try expect(!newest.isOpenShown && older.isOpenShown == false, "pressing the line of the open head closes it")
        try expect(
            (newest.superview?.frame.height ?? 0) < before,
            "closing gives the page its height back")
        older.pressLine()
        root.layoutSubtreeIfNeeded()
        try expect(
            older.isOpenShown && !newest.isOpenShown,
            "opening the older head opens it, and only it")
        newest.pressLine()
        root.layoutSubtreeIfNeeded()
        try expect(
            newest.isOpenShown && !older.isOpenShown,
            "and opening the newer one closes it again: one head is open at a time")
    }

    private static func fixtureWindow(_ fixture: Fixture) -> (BrainRowView, BrainStageView)? {
        guard let head = fixture.brainRows.last,
            let view = head.row.makeView(context: fixture.context) as? BrainRowView
        else { return nil }
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 900))
        view.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: root.topAnchor),
            view.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 24),
            view.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -24),
        ])
        stage(root)
        root.layoutSubtreeIfNeeded()
        guard let stage = view.stage else { return nil }
        stage.refresh(force: true)
        return (view, stage)
    }

    private static func event(
        _ type: NSEvent.EventType, at point: CGPoint, in view: NSView, clicks: Int = 1
    ) -> NSEvent? {
        NSEvent.mouseEvent(
            with: type, location: view.convert(point, to: nil), modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: view.window?.windowNumber ?? 0, context: nil, eventNumber: 0,
            clickCount: clicks, pressure: 1)
    }

    private static func key(_ code: UInt16, in view: NSView) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: view.window?.windowNumber ?? 0, context: nil, characters: "",
            charactersIgnoringModifiers: "", isARepeat: false, keyCode: code)
    }

    private static func interaction(_ expect: (Bool, String) throws -> Void) throws {
        let fixture = Fixture()
        guard let (view, stage) = fixtureWindow(fixture), let turnID = fixture.store.order.last,
            let model = fixture.store.model(turnID)
        else {
            try expect(false, "an open head in a window")
            return
        }
        try expect(
            stage.drawnNodeCount == model.nodeCount,
            "every node of the turn is drawn: \(stage.drawnNodeCount) of \(model.nodeCount)")
        try expect(stage.wireLayerCount > 0, "the wires the layout holds are drawn")
        try expect(
            stage.accessibilityChildren()?.count == model.nodeCount
                && stage.accessibilityLabel() == model.spoken,
            "the stage is one group that says the turn and has an element for every node")

        let draws = NeuralNodes.draws(model: model, time: 0, reduceMotion: true)
        guard let pick = draws.dropFirst(min(6, draws.count - 1)).first,
            let step = model.step(id: pick.id), let center = stage.center(ofStep: step.id)
        else {
            try expect(false, "a node has a place")
            return
        }
        if let move = event(.mouseMoved, at: center, in: stage) { stage.mouseMoved(with: move) }
        try expect(
            fixture.store.model(turnID)?.hovered == step.id,
            "the pointer on a node hovers that node")
        try expect(
            stage.cardIsShown && stage.cardReading?.title == NeuralReading.title(of: step),
            "and raises its card, in Core's words")
        if let click = event(.leftMouseDown, at: center, in: stage) { stage.mouseDown(with: click) }
        try expect(fixture.store.model(turnID)?.pinned == step.id, "a click pins it")
        if let leave = event(.mouseMoved, at: CGPoint(x: 4, y: 4), in: stage) {
            stage.mouseMoved(with: leave)
        }
        try expect(
            fixture.store.model(turnID)?.pinned == step.id && stage.cardIsShown,
            "the pointer leaving does not let go of a pin")
        if let empty = event(.leftMouseDown, at: CGPoint(x: 4, y: 4), in: stage) {
            stage.mouseDown(with: empty)
        }
        try expect(
            fixture.store.model(turnID)?.hasSelection == false && !stage.cardIsShown,
            "a click on nothing lets go of the selection")

        stage.walk(by: 1)
        let first = fixture.store.model(turnID)?.hovered
        stage.walk(by: 1)
        let second = fixture.store.model(turnID)?.hovered
        try expect(first != nil && second != nil && first != second, "the right arrow walks the steps")
        stage.walk(by: -1)
        try expect(fixture.store.model(turnID)?.hovered == first, "and the left arrow walks back")
        if let enter = key(36, in: stage) { stage.keyDown(with: enter) }
        try expect(fixture.store.model(turnID)?.pinned == first, "Return pins the step that is lit")
        if let escape = key(53, in: stage) { stage.keyDown(with: escape) }
        try expect(
            fixture.store.model(turnID)?.hasSelection == false, "Escape lets go of what was lit")

        let inShell = model.steps.filter { $0.zone == .shell }.count
        stage.dive(into: .shell)
        stage.completeDive()
        try expect(
            stage.divedZone == .shell && stage.diveListRows == inShell && inShell > 0,
            "a zone's name dives into it and lists its steps (\(stage.diveListRows) of \(inShell))")
        if let escape = key(53, in: stage) { stage.keyDown(with: escape) }
        stage.completeDive()
        try expect(stage.divedZone == nil && stage.diveListRows == 0, "Escape surfaces")

        view.replayButton.onTap?()
        try expect(
            fixture.store.model(turnID)?.isReplaying == true,
            "Replay plays the turn from its message times")
        view.scrubberView.onScrub?(0.5)
        try expect(
            { if case .scrubbing = fixture.store.model(turnID)?.mode { return true } else { return false } }(),
            "dragging the scrubber holds the playhead")
        try expect(
            view.tickerText != nil && view.scrubFraction > 0.4 && view.scrubFraction < 0.6,
            "the ticker says what is firing at the playhead and the knob stands where it was left")
        view.scrubberView.onEnd?()
        try expect(
            fixture.store.model(turnID)?.isReplaying == true,
            "letting go anywhere but the end leaves it there")
        view.scrubberView.onScrub?(1)
        view.scrubberView.onEnd?()
        try expect(
            fixture.store.model(turnID)?.isReplaying == false,
            "the end of the track is the turn as it stands")

        let chips = view.chipViews
        try expect(!chips.isEmpty, "a path the answer quotes that a step carries is offered as a word")
        if let chip = chips.first {
            chip.onHover?(true)
            try expect(
                fixture.store.model(turnID)?.isProvenanceActive == true,
                "pointing at an answer word lights the steps that carry it")
            chip.onHover?(false)
            try expect(
                fixture.store.model(turnID)?.isProvenanceActive == false, "and letting go dims nothing")
        }
        try expect(
            fixture.store.searchText(turnID: turnID).contains("ffmpeg"),
            "find reads the steps of a head")

        var asked = 0
        fixture.store.onChange = { asked += 1 }
        view.rowsButton.onTap?()
        try expect(asked == 1 && fixture.store.showsRows(turnID), "Rows lists the old rows")
    }

    private static func motion(_ expect: (Bool, String) throws -> Void) throws {
        let fixture = Fixture()
        guard let (view, stage) = fixtureWindow(fixture), let turnID = fixture.store.order.last,
            let settled = fixture.store.model(turnID)
        else {
            try expect(false, "a settled head in a window")
            return
        }
        try expect(
            !settled.needsClock && settled.tempo == .stopped,
            "a settled head asks for no clock at all")
        try expect(
            stage.nodeLayers.allSatisfy { !$0.isMoving } && !view.glyphView.isMoving,
            "and nothing on it moves: not a node's ring, not the glyph")

        var live = NeuralDemo.buildFix(prefix: "a-") + NeuralDemo.turn(prefix: "b-", answer: false)
        if let index = live.indices.last(where: { live[$0].role == .assistant }),
            let part = live[index].parts.lastIndex(where: {
                if case .tool = $0.kind { return true } else { return false }
            }),
            case .tool(var call) = live[index].parts[part].kind
        {
            call.status = .running
            call.output = nil
            live[index].parts[part].kind = .tool(call)
            live[index].isStreaming = true
            live[index].completedAt = nil
        }
        let working = Fixture(messages: live, running: true)
        guard let id = working.store.order.last, let model = working.store.model(id) else {
            try expect(false, "a running turn is a head")
            return
        }
        try expect(
            model.needsClock && model.tempo == .activity,
            "a running head asks for the activity tempo, \(model.tempo)")
        try expect(
            !model.needsClock(reduceMotion: true) && model.tempo(reduceMotion: true) == .stopped,
            "and under Reduce Motion for none")
        let draws = NeuralNodes.draws(model: model, time: 0, reduceMotion: true)
        try expect(
            draws.allSatisfy { $0.motion == .still }, "every node holds still under Reduce Motion")
        let moving = NeuralNodes.draws(model: model, time: 0, reduceMotion: false)
        try expect(
            moving.contains { $0.motion == .breath },
            "the node that is running breathes")
        if ActivityPulse.motionAllowed, let (_, stage) = fixtureWindow(working) {
            try expect(
                stage.nodeLayers.contains { $0.isMoving },
                "and its ring is laid on the render server")
        }
    }

    private static func lifetime(_ expect: (Bool, String) throws -> Void) throws {
        guard let context = NeuralMetalContext.shared else { return }
        for row in BrainRowView.live { row.removeFromSuperview() }
        windows.removeAll()
        let base = context.retainCount
        let fixture = Fixture()
        guard let (view, stage) = fixtureWindow(fixture) else {
            try expect(false, "an open head")
            return
        }
        try expect(
            context.retainCount == base + 1 && stage.holdsHead,
            "an open head holds the process's textures (\(context.retainCount) holds)")
        view.setParked(true)
        try expect(
            context.retainCount == base && !stage.holdsHead,
            "a pane that parks lets go of the textures")
        view.setParked(true, reason: "idle")
        view.setParked(false)
        try expect(
            context.retainCount == base, "a head parked for another reason stays parked")
        view.setParked(false, reason: "idle")
        try expect(context.retainCount == base + 1, "and comes back when nobody wants it gone")
        let turnID = view.row.turnID
        fixture.store.onChange = {
            fixture.rebuild()
            for head in fixture.brainRows { view.restate(head.brain) }
        }
        fixture.store.toggleOpen(turnID)
        try expect(
            context.retainCount == base && !view.isOpenShown,
            "closing the last open head lets go of the textures")
        fixture.store.toggleOpen(turnID)
        try expect(context.retainCount == base + 1, "opening one takes them again")
        view.window?.close()
        try expect(
            context.retainCount == base,
            "a window that closes lets go of them")
    }
}
