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
        try lazy(expect)
        try rows(expect)
        guard MacBrain.isEnabled else { return checks }
        checks += try BrainViewChecks.run()
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

    private static func lazy(_ expect: (Bool, String) throws -> Void) throws {
        guard MacBrain.isEnabled else { return }
        let messages = (0..<30).flatMap {
            NeuralDemo.buildFix(prefix: "z\($0)-", origin: 1_700_000_000 + Double($0) * 600)
        }
        let store = BrainStore()
        store.read(messages: messages, running: false, awaiting: .none)
        try expect(
            store.order.count == 30 && store.madeCount == 1,
            "reading a conversation makes the newest turn's model and no other (\(store.order.count) brains, \(store.madeCount) made)")
        let older = store.order[10]
        let before = store.row(forTurn: older)
        let found = store.stepHolding("swift build", turnID: store.order[20])
        try expect(
            found != nil && store.madeCount == 2,
            "find lands on a step of a turn nobody looked at (\(String(describing: found)), \(store.madeCount) made)")
        let looked = store.entry(older)
        try expect(
            looked?.turn.id == older && store.madeCount == 3 && store.row(forTurn: older) == before,
            "looking at a turn makes it and leaves its row as it was")
        let eager = NeuralTurns.partition(messages: messages, running: false)
        try expect(
            store.order.allSatisfy { id in
                store.entry(id)?.turn == eager.first { $0.id == id }
            }, "every turn made later is the turn the partition reads")
        var slices = 0
        while !store.indexSearch(budget: 0.000_01) { slices += 1 }
        try expect(slices > 1, "find's words are read in more than one slice (\(slices))")
        try expect(
            store.order.allSatisfy { id in
                let words = store.indexedSearchText(turnID: id)
                return !words.isEmpty && words == store.searchText(turnID: id)
            }, "the words are read for every brain")
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
            heads.allSatisfy { !$0.brain.isOpen } && fixture.store.openTurnID == nil,
            "nothing opens by itself: every turn, the newest included, is a card")
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
}
