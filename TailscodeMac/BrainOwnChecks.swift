import AppKit
import CodingAgentKit
import TailscodeCore

/// The checks of the parts the hub, the card, the stage, the move, the footer and the keys own.
@MainActor
enum BrainOwnChecks {
    typealias Expect = (Bool, String) throws -> Void

    static func run(_ expect: Expect) throws {
        let checks = [
            cards, liveCard, picture, layouts, moves, reduced, keys, leader, replyAndAsk, clocks,
            lifetime, accessibility, streaming,
        ]
        for check in checks { try check(expect) }
    }

    private static func fixture(
        width: CGFloat = 1300, messages: [ChatMessage] = NeuralDemo.conversation(),
        running: Bool = false
    ) -> BrainFixture {
        BrainFixture(messages: messages, running: running, width: width)
    }

    private static var reducedForTests: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private static func spin(_ seconds: TimeInterval) {
        RunLoop.current.run(until: Date().addingTimeInterval(seconds))
    }

    private static func spin(until condition: () -> Bool, timeout: TimeInterval = 25) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline { spin(0.05) }
    }

    private static func runningMessages() -> [ChatMessage] {
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
        return live
    }

    private static func keyEvent(_ characters: String, code: UInt16, in window: NSWindow) -> NSEvent? {
        NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
            context: nil, characters: characters, charactersIgnoringModifiers: characters,
            isARepeat: false, keyCode: code)
    }

    private static func cards(_ expect: Expect) throws {
        let fixture = fixture()
        defer { fixture.tearDown() }
        guard let first = fixture.view(0), let second = fixture.view(1) else {
            try expect(false, "two cards")
            return
        }
        try expect(
            fixture.store.openTurnID == nil && !first.isOpenShown && !second.isOpenShown,
            "every turn is a card until the person opens one")
        let metrics = first.currentMetrics
        try expect(
            abs(first.frame.height - CGFloat(metrics.card.height)) < 0.5,
            "a card is Core's height for its density (\(first.frame.height) against \(metrics.card.height))")
        let reading = second.card.reading
        try expect(reading.chips > 0 && reading.buttons == 2, "a card holds its zone chips, Replay and Rows")
        try expect(
            reading.headline.contains("fixed 1 error") && !reading.headline.lowercased().contains("failed"),
            "a fixed error is words of repair on the card and the word failed is not among them: \(reading.headline)")
        let spoken = second.card.content?.card.spoken ?? ""
        try expect(!spoken.lowercased().contains("failed"), "and the card reads the same to a screen reader")
        try expect(
            second.card.content?.card.quote != nil
                && second.card.content?.card.edge == .settled,
            "the card carries the agent's first words and a settled edge")
        var asked: NeuralZone?
        second.card.onZone = { asked = $0 }
        if let chip = second.card.chipCenters.first {
            let window = fixture.window
            let point = second.card.convert(chip.point, to: nil)
            let down = NSEvent.mouseEvent(
                with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: 1)
            let up = NSEvent.mouseEvent(
                with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                pressure: 0)
            if let down, let up {
                second.card.mouseDown(with: down)
                second.card.mouseUp(with: up)
            }
            try expect(asked == chip.zone, "pressing a zone chip asks for that zone's dive")
        }
        second.openDiving(into: .shell)
        fixture.finishMoves()
        try expect(
            fixture.store.isOpen(second.turnID) && second.stage?.divedZone == .shell
                || second.stage?.isDiving == true,
            "a chip opens the brain already diving into its zone")
        second.stage?.completeDive()
        try expect(
            second.model.stepList.filter.zones == [.shell],
            "and the dive solos that zone in the list")
    }

    private static func liveCard(_ expect: Expect) throws {
        let still = fixture()
        defer { still.tearDown() }
        try expect(
            still.store.order.compactMap { still.store.view(forTurn: $0) }.allSatisfy {
                !$0.card.reading.hasLive
            },
            "a settled card has no live face")
        let ticks = BrainLiveTick.shared.cardCount
        let live = fixture(messages: runningMessages(), running: true)
        defer { live.tearDown() }
        guard let newest = live.view(1) else {
            try expect(false, "a running turn is a card")
            return
        }
        try expect(newest.card.reading.hasLive, "a running turn's card is the live card")
        try expect(
            newest.card.content?.card.live?.verdict == .working
                && newest.card.reading.buttons == 2,
            "it says Working, and offers Open and a Replay that waits")
        try expect(
            BrainLiveTick.shared.cardCount == ticks + 1 && BrainLiveTick.shared.isRunning,
            "one shared second runs while a live card is up")
        try expect(
            newest.card.content.map { $0.card.live?.motion.isAnimated == true } == true
                || !ActivityPulse.motionAllowed,
            "the live card's active zone breathes on the render server")
        try expect(
            newest.frame.height == CGFloat(newest.currentMetrics.card.height),
            "a live card keeps the settled card's size")
        live.replace(messages: NeuralDemo.buildFix(prefix: "a-") + NeuralDemo.turn(prefix: "b-"), running: false)
        spin(0.05)
        try expect(newest.card.isSettling || !ActivityPulse.motionAllowed, "the turn ending settles the card in one move")
        spin(0.55)
        try expect(!newest.card.isSettling, "and the move is over in 400 ms")
        try expect(
            !newest.card.reading.hasLive && BrainLiveTick.shared.cardCount == ticks,
            "a settled card registers no tick")
    }

    private static func picture(_ expect: Expect) throws {
        let fixture = fixture()
        defer { fixture.tearDown() }
        let before = BrainPictures.rendered
        let first = fixture.view(0)
        let second = fixture.view(1)
        try expect(
            first?.picture.hasImage == true && second?.picture.hasImage == true,
            "every card of a look has the head's picture (\(first?.picture.hasImage ?? false), \(second?.picture.hasImage ?? false), rendered \(BrainPictures.rendered), supported \(NeuralHeadView.isSupported))")
        try expect(
            BrainPictures.rendered - before <= 2,
            "two cards share the pictures of their look instead of rendering one each (\(BrainPictures.rendered - before))")
        try expect(
            (first?.picture.lightCount ?? 0) > 0 && (second?.picture.ringCount ?? 0) >= 1,
            "a card is lit where the turn worked and rings a zone that had an error")
    }

    private static func layouts(_ expect: Expect) throws {
        for width in [1300.0, 1000.0, 860.0, 700.0, 520.0] {
            let fixture = fixture(width: CGFloat(width))
            defer { fixture.tearDown() }
            guard let view = fixture.open(1) else {
                try expect(false, "a brain opens at \(width)")
                continue
            }
            fixture.root.layoutSubtreeIfNeeded()
            let m = view.currentMetrics
            try expect(
                view.phase == .open && view.stage != nil && view.footer != nil,
                "at \(Int(width)) the brain is open with its stage and footer")
            try expect(
                m.arrangement == (view.bounds.width >= 860 ? .split : .accordion),
                "at \(Int(width)) the arrangement is Core's (\(m.arrangement))")
            let stage = view.stage?.frame ?? .zero
            try expect(
                abs(stage.width - CGFloat(m.stage.width)) < 1 && abs(stage.height - CGFloat(m.stage.height)) < 1
                    && abs(stage.height - stage.width * CGFloat(NeuralStageMetrics.aspect)) < 1.5,
                "the stage is Core's rectangle and the head's own shape at \(Int(width))")
            let expected = CGFloat(m.rowHeight + view.narrowExtra(m))
            try expect(
                abs(view.frame.height - expected) < 1,
                "the open row is Core's height at \(Int(width)): \(view.frame.height) against \(expected)")
            try expect(view.card.isHidden, "the card gives way to the stage at \(Int(width))")
            if m.arrangement == .split {
                try expect(
                    view.list?.isHidden == false && abs((view.list?.frame.width ?? 0) - CGFloat(m.list.width)) < 1
                        && abs((view.account?.frame.minX ?? 0) - CGFloat(m.readout.x)) < 1,
                    "the list sits under the head and the account beside it at \(Int(width))")
            } else {
                try expect(
                    view.list?.isHidden == true && abs((view.account?.frame.width ?? 0) - CGFloat(m.width)) < 1,
                    "in an accordion the account is the list at \(Int(width))")
            }
            let parts = NeuralStageMetrics.footerParts(width: Double(view.bounds.width)).map(\.kind)
            try expect(
                view.footer?.shown.allSatisfy { parts.contains($0) } == true,
                "the footer shows only what Core allows at \(Int(width))")
            fixture.store.setOpen(false, turnID: view.turnID)
            fixture.finishMoves()
            try expect(
                !view.isOpenShown && abs(view.frame.height - CGFloat(m.card.height)) < 1,
                "closing gives the card its height back at \(Int(width))")
        }
    }

    private static func moves(_ expect: Expect) throws {
        let fixture = fixture()
        defer { fixture.tearDown() }
        guard let view = fixture.view(1) else { return }
        let m = view.currentMetrics
        let open = NeuralTransition.make(.open, metrics: m, nodeCount: 23)
        try expect(
            open.frame(at: 0).rowHeight == m.card.height && open.frame(at: 1).rowHeight == m.rowHeight,
            "an opening starts at the card's height and lands on the stage's")
        let start = open.frame(at: 0).traveller
        try expect(
            abs(start.width - m.card.picture.width) < 0.01
                && abs(open.frame(at: 1).traveller.width - m.stage.width) < 0.01,
            "the head travels from the card's picture to the stage")
        let mover = BrainMover(transition: open, now: 0, metricsWidth: m.width)
        _ = mover.step(at: 0.1)
        let height = mover.rowHeight
        mover.reverse(at: 0.1)
        try expect(
            abs(mover.rowHeight - height) < 0.01 && !mover.isOpening,
            "a press mid-move reverses from the frame it is on and never restarts")
        var done = false
        var now = 0.1
        while !done && now < 1 {
            now += 1.0 / 60
            done = mover.step(at: now)
        }
        try expect(
            done && abs(mover.rowHeight - m.card.height) < 0.01,
            "the reversed move lands exactly on the card")
        fixture.store.setOpen(true, turnID: view.turnID)
        try expect(
            view.mover != nil && view.phase == .moving && view.movesRun >= 1,
            "opening from a press runs a move")
        let began = view.mover?.transition.duration ?? 0
        try expect(
            began > 0.3 && began < 0.35 || reducedForTests,
            "an opening takes Core's 320 ms (\(began) s)")
        view.finishMove(snapOpen: true)
        try expect(view.mover == nil && view.phase == .open, "the move ends in the open brain")
        fixture.store.setOpen(false, turnID: view.turnID)
        try expect(
            view.mover != nil && view.mover?.isOpening == false, "closing runs the move the other way")
        view.finishMove(snapOpen: false)
        try expect(!view.isOpenShown && view.stage == nil, "closing lands on the card and lets the stage go")
        let other = fixture.view(0)
        other.map { fixture.store.setOpen(true, turnID: $0.turnID) }
        fixture.finishMoves()
        fixture.store.setOpen(true, turnID: view.turnID)
        try expect(
            fixture.store.openTurnID == view.turnID && !(other?.row.isOpen ?? true),
            "opening one while another is open closes the other, the two moves crossing")
        fixture.finishMoves()
    }

    private static func reduced(_ expect: Expect) throws {
        let fixture = fixture()
        defer { fixture.tearDown() }
        guard let view = fixture.view(1) else { return }
        let m = view.currentMetrics
        let move = NeuralTransition.make(.open, metrics: m, nodeCount: 23, reduceMotion: true)
        try expect(
            move.fullDuration == NeuralTransition.crossfadeDuration
                && move.frame(at: 0.5).sweepAmount == 0,
            "reduced motion is a 120 ms crossfade with no travel and no sweep")
        let strained = NeuralTransition.make(.open, metrics: m, nodeCount: 23, level: .strained)
        try expect(
            strained.fullDuration == NeuralTransition.strainedDuration
                && strained.frame(at: 0.5).sweepAmount == 0,
            "a strained window shortens the move and drops the sweep")
    }

    private static func keys(_ expect: Expect) throws {
        let fixture = fixture()
        defer { fixture.tearDown() }
        guard let view = fixture.open(1), let stage = view.stage else {
            try expect(false, "an open brain")
            return
        }
        fixture.window.makeFirstResponder(stage)
        try expect(
            view.hasBrainFocus && stage.takesBrainKey(
                keyEvent("j", code: 38, in: fixture.window) ?? NSEvent()),
            "the brain takes its keys while it holds the keyboard")
        if let down = keyEvent("\u{F701}", code: 125, in: fixture.window) {
            _ = view.handleBrainKey(down, from: stage)
        }
        let first = view.model.pinnedStep
        try expect(first != nil, "Down puts the cursor on the first step")
        if let down = keyEvent("j", code: 38, in: fixture.window) {
            _ = view.handleBrainKey(down, from: stage)
        }
        try expect(
            view.model.pinnedStep != first && view.stage?.hasCursorRing == true,
            "j walks on and the head rings the step")
        if let digit = keyEvent("4", code: 21, in: fixture.window) {
            _ = view.handleBrainKey(digit, from: stage)
        }
        try expect(view.model.stepList.filter.zones == [.act], "4 filters the list to a zone")
        if let escape = keyEvent("\u{1B}", code: 53, in: fixture.window) {
            _ = view.handleBrainKey(escape, from: stage)
            try expect(
                view.model.stepList.filter.zones.isEmpty || view.model.pinnedStep == nil,
                "Esc undoes one thing")
            for _ in 0..<4 { _ = view.handleBrainKey(escape, from: stage) }
        }
        fixture.finishMoves()
        spin(0.4)
        try expect(!fixture.store.isOpen(view.turnID), "and the last Esc puts the brain away")
        let outside = NSView()
        fixture.root.addSubview(outside)
        fixture.window.makeFirstResponder(nil)
        try expect(
            !(fixture.view(1)?.brainKeyApplies(keyEvent("j", code: 38, in: fixture.window) ?? NSEvent()) ?? true),
            "keys are never taken while the keyboard is elsewhere")
        outside.removeFromSuperview()
    }

    private static func leader(_ expect: Expect) throws {
        let wide = fixture(width: 1300)
        defer { wide.tearDown() }
        guard let view = wide.open(1), let id = view.model.steps.first(where: { $0.zone == .shell })?.id else {
            try expect(false, "an open brain to point the leader from")
            return
        }
        try expect(!view.leader.isShown, "with nothing to read the leader is not there")
        view.browse(.click(id, double: false), grabFocus: false)
        view.updateLeader()
        try expect(
            view.leader.stepID == id && view.leader.routePoints >= 2,
            "the cursor's node is tied to the account by a leader")
        let before = view.leader.searches
        view.updateLeader()
        try expect(view.leader.searches == before, "a leader already drawn is not searched for again")
        let narrow = fixture(width: 700)
        defer { narrow.tearDown() }
        if let view = narrow.open(1), let id = view.model.steps.first?.id {
            view.browse(.click(id, double: false), grabFocus: false)
            view.updateLeader()
            try expect(!view.leader.isShown, "an accordion row has no leader")
        }
    }

    private static func replyAndAsk(_ expect: Expect) throws {
        let fixture = fixture()
        defer { fixture.tearDown() }
        guard let view = fixture.open(1), let said = view.model.steps.first(where: { NeuralReading.isNote($0) }) else {
            try expect(false, "an open brain with something said")
            return
        }
        var quote: String?
        fixture.store.replyQuote = { quote = $0 }
        view.browse(.reply(said.id), grabFocus: false)
        try expect(
            quote?.hasPrefix("> ") == true && quote?.hasSuffix("\n\n") == true,
            "Reply offers the composer a quote of what was said")
        var asked = 0
        fixture.store.revealApproval = { asked += 1 }
        view.goToApproval()
        try expect(asked == 1, "going to the approval scrolls the transcript's own card")
        var answered: (String, String)?
        fixture.store.revealAnswerPart = { answered = ($0, $1) }
        view.revealAnswer()
        try expect(answered != nil, "the answer item scrolls to the answer under the brain")
        NSPasteboard.general.clearContents()
        if let shell = view.model.steps.first(where: { $0.zone == .shell }) {
            view.browse(.click(shell.id, double: false), grabFocus: false)
        }
        view.browse(.key(.character("c")), grabFocus: false)
        try expect(
            NSPasteboard.general.string(forType: .string)?.isEmpty == false,
            "c copies the step's words to the pasteboard")
        var shown = false
        fixture.store.revealStepRow = { _ in shown = true }
        view.showInRows(said.id)
        try expect(shown && fixture.store.showsRows(view.turnID), "Show in Rows lists the old rows and finds the step")
    }

    private static func clocks(_ expect: Expect) throws {
        let fixture = fixture()
        defer { fixture.tearDown() }
        guard let view = fixture.open(1), let stage = view.stage else { return }
        try expect(
            !view.model.needsClock && !stage.head.isClockRunning,
            "a settled open brain runs no clock at all")
        let live = self.fixture(messages: runningMessages(), running: true)
        defer { live.tearDown() }
        let was = DisplayGate.assumesVisible
        DisplayGate.assumesVisible = false
        let hidden = BrainClock(view: live.root) { _ in }
        hidden.run()
        try expect(!hidden.isRunning, "a clock in a window nobody can see does not start")
        DisplayGate.assumesVisible = was
        hidden.run()
        try expect(hidden.isRunning, "and starts when it can be seen")
        hidden.stop()
        try expect(!hidden.isRunning, "and stops")
    }

    private static func lifetime(_ expect: Expect) throws {
        guard let context = NeuralMetalContext.shared else { return }
        let base = context.retainCount
        let fixture = fixture()
        guard let view = fixture.open(1), let stage = view.stage else {
            try expect(false, "an open head")
            return
        }
        try expect(
            context.retainCount >= base + 1 && stage.holdsHead,
            "an open head holds the process's textures (\(context.retainCount) holds)")
        view.setParked(true)
        try expect(!stage.holdsHead, "a pane that parks gives the head up")
        view.setParked(true, reason: "idle")
        view.setParked(false)
        try expect(!stage.holdsHead, "a head parked for another reason stays parked")
        view.setParked(false, reason: "idle")
        try expect(stage.holdsHead, "and comes back when nobody wants it gone")
        fixture.store.setOpen(false, turnID: view.turnID)
        fixture.finishMoves()
        spin(0.4)
        try expect(view.stage == nil, "closing takes the stage away")
        fixture.tearDown()
    }

    private static func streaming(_ expect: Expect) throws {
        var messages = runningMessages()
        if let index = messages.indices.last(where: { messages[$0].role == .assistant }) {
            messages[index].parts.append(MessagePart(id: "stream-note", kind: .text("Streaming")))
        }
        let fixture = fixture(messages: messages, running: true)
        defer { fixture.tearDown() }
        guard let index = messages.indices.last(where: { messages[$0].role == .assistant }),
            let at = messages[index].parts.firstIndex(where: { $0.id == "stream-note" })
        else { return }
        fixture.replace(messages: messages)
        let before = fixture.store.tailReads
        let revision = fixture.store.entry(fixture.store.order[1])?.revision
        for step in 0..<30 {
            if case .text(let words) = messages[index].parts[at].kind {
                messages[index].parts[at].kind = .text(words + " token\(step)")
            }
            fixture.replace(messages: messages)
        }
        try expect(
            fixture.store.tailReads - before <= 2,
            "thirty tokens of words read the turn at most twice (\(fixture.store.tailReads - before))")
        let reads = fixture.store.tailReads
        messages[index].parts.append(
            MessagePart(
                id: "new-tool",
                kind: .tool(
                    ToolCall(
                        id: "new-tool", name: "Read", status: .running,
                        input: .object(["file_path": .string("/src/new.swift")]), output: nil))))
        fixture.replace(messages: messages)
        try expect(
            fixture.store.tailReads == reads + 1
                && fixture.store.entry(fixture.store.order[1])?.revision != revision,
            "a step arriving is read at once, whatever the last reading was")
        fixture.replace(messages: messages, running: false)
        try expect(
            fixture.store.tailReads == reads + 2 && fixture.store.model(fixture.store.order[1])?.turn.outcome != .running,
            "and a turn ending is read at once too")
    }

    private static func accessibility(_ expect: Expect) throws {
        let fixture = fixture()
        defer { fixture.tearDown() }
        guard let card = fixture.view(1) else { return }
        try expect(
            card.card.accessibilityRole() == .button && (card.card.accessibilityChildren()?.count ?? 0) >= 2,
            "a card is a button with Replay, Rows and its zone chips inside it")
        guard let open = fixture.open(0), let stage = open.stage else { return }
        spin(0.1)
        try expect(
            stage.accessibilitySteps == stage.drawnNodeCount || stage.accessibilitySteps > 0,
            "the open head is a tree of buttons, one per step it shows")
    }
}
