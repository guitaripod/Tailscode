import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

enum BrainFixtures {
    typealias Fixtures = NeuralTurnFixtures

    static func turn(running: Bool = false, awaiting: NeuralAwaiting = .none) -> NeuralTurn {
        NeuralTurns.partition(messages: Fixtures.turn(answer: !running), running: running, awaiting: awaiting)[0]
    }

    static func buildFix() -> NeuralTurn {
        NeuralTurns.partition(messages: Fixtures.buildFix(), running: false)[0]
    }

    static func model(
        _ turn: NeuralTurn? = nil, context: NeuralBrainContext = .none
    ) -> NeuralBrainModel {
        NeuralBrainModel(turn: turn ?? self.turn(), context: context)
    }

    static func working(_ kind: ToolCallSummary.Kind = .shell) -> NeuralBrainContext {
        NeuralBrainContext(activity: .usingTool(name: "Bash", kind: kind))
    }

    static func steps(_ zones: [NeuralZone]) -> [NeuralStep] {
        zones.enumerated().map { index, zone in
            ReadingFixtures.step(index, zone, zone == .think ? "Thinking" : "Tool", text: zone == .think ? "t" : "")
        }
    }
}

@Suite("Neural brain model")
struct NeuralBrainModelTests {
    typealias Fixtures = NeuralTurnFixtures

    @Test("a node is hit at its centre and within its radius plus the slop")
    func hitsNodes() throws {
        let model = BrainFixtures.model(BrainFixtures.buildFix())
        let step = try #require(model.steps.first { $0.zone == .delegate })
        let point = try #require(model.point(of: step.id))
        #expect(model.hit(at: point, slop: 0) == step.id)
        let near = NeuralPoint(point.x + NeuralDesign.nodeRadius + 3, point.y)
        #expect(model.hit(at: near, slop: 4) == step.id)
        #expect(model.hit(at: near, slop: 0) == nil)
        let far = NeuralPoint(point.x + NeuralDesign.nodeRadius + 6, point.y)
        #expect(model.hit(at: far, slop: 4) == nil)
    }

    @Test("the nearest of two nodes wins")
    func nearestWins() throws {
        let model = BrainFixtures.model(BrainFixtures.buildFix())
        let shell = model.steps.filter { $0.zone == .shell }
        let a = try #require(model.point(of: shell[0].id))
        let b = try #require(model.point(of: shell[1].id))
        let nearA = NeuralPoint(a.x + (b.x - a.x) * 0.4, a.y + (b.y - a.y) * 0.4)
        let nearB = NeuralPoint(a.x + (b.x - a.x) * 0.6, a.y + (b.y - a.y) * 0.6)
        #expect(model.hit(at: nearA, slop: 12) == shell[0].id)
        #expect(model.hit(at: nearB, slop: 12) == shell[1].id)
    }

    @Test("a member of a ganglion resolves to its leader")
    func ganglionHit() throws {
        let model = BrainFixtures.model()
        let ganglion = try #require(model.layout.ganglia.first { $0.zone == .shell })
        #expect(ganglion.members.count == 7)
        for member in ganglion.members {
            let point = try #require(model.point(of: member))
            #expect(model.hit(at: point, slop: 0) == ganglion.leader)
        }
        let leader = try #require(model.point(of: ganglion.leader))
        let rim = NeuralPoint(leader.x + NeuralDesign.nodeRadius * 1.4, leader.y)
        #expect(model.hit(at: rim, slop: 0) == ganglion.leader)
        let beyond = NeuralPoint(leader.x + NeuralDesign.nodeRadius * 1.5, leader.y)
        #expect(model.hit(at: beyond, slop: 0) == nil)
    }

    @Test("a point no node reaches is a miss")
    func misses() {
        let model = BrainFixtures.model()
        #expect(model.hit(at: NeuralPoint(2, 2), slop: 6) == nil)
        #expect(model.hit(at: NeuralPoint(-300, -300), slop: 6) == nil)
        #expect(model.hit(at: NeuralPoint(900, 700), slop: 6) == nil)
        let empty = BrainFixtures.model(NeuralTurn(id: "x"))
        #expect(empty.hit(at: NeuralPoint(300, 200), slop: 20) == nil)
    }

    @Test("a pinned node outranks a hovered one, and letting go falls back to the hover")
    func selectionPrecedence() throws {
        var model = BrainFixtures.model(BrainFixtures.buildFix())
        let a = model.steps[0].id
        let b = model.steps[3].id
        let c = model.steps[5].id
        #expect(model.selected == nil)
        model.setHover(a)
        #expect(model.selected == a)
        model.togglePin(b)
        #expect(model.pinned == b)
        #expect(model.selected == b)
        model.setHover(c)
        #expect(model.hovered == c)
        #expect(model.selected == b)
        model.togglePin(b)
        #expect(model.pinned == nil)
        #expect(model.selected == c)
        model.togglePin(c)
        #expect(model.selected == c)
        model.clearSelection()
        #expect(model.selected == nil)
        #expect(model.hotSteps.isEmpty)
    }

    @Test("an unknown id selects nothing and a ganglion member selects its leader")
    func selectionIDs() throws {
        var model = BrainFixtures.model()
        model.setHover("nowhere:p9")
        #expect(model.selected == nil)
        model.togglePin("nowhere:p9")
        #expect(model.pinned == nil)
        let ganglion = try #require(model.layout.ganglia.first)
        model.setHover(ganglion.members[4])
        #expect(model.selected == ganglion.leader)
        #expect(model.members(of: ganglion.members[2]) == ganglion.members)
    }

    @Test("the selection lights the layout's hot set and hot routes, and nothing without one")
    func hotSets() throws {
        var model = BrainFixtures.model(BrainFixtures.buildFix())
        #expect(model.hotSteps.isEmpty)
        #expect(model.hotRoutes.isEmpty)
        let step = model.steps[6]
        model.setHover(step.id)
        #expect(model.hotSteps == model.layout.hotSet(for: step.id))
        #expect(model.hotRoutes == model.layout.hotRoutes(for: step.id))
        #expect(model.hotSteps.contains(step.id))
        #expect(!model.hotRoutes.isEmpty)
        model.setHover(nil)
        #expect(model.hotSteps.isEmpty)
        #expect(model.hotRoutes.isEmpty)
    }

    @Test("hovering a ganglion lights every member")
    func hotGanglion() throws {
        var model = BrainFixtures.model()
        let ganglion = try #require(model.layout.ganglia.first)
        model.setHover(ganglion.members[3])
        for member in ganglion.members { #expect(model.hotSteps.contains(member)) }
    }

    @Test("the card is the step's, and a ganglion has its own")
    func cards() throws {
        var model = BrainFixtures.model()
        #expect(model.card == nil)
        let ganglion = try #require(model.layout.ganglia.first)
        model.setHover(ganglion.leader)
        let members = ganglion.members.compactMap { model.step(id: $0) }
        #expect(model.card == NeuralReading.ganglion(zone: .shell, members: members))
        #expect(model.card?.statusWord == "7 steps gathered here")
        let step = model.steps[2]
        model.setHover(step.id)
        #expect(model.card == NeuralReading.card(for: step, in: model.steps))
    }

    @Test("a word of the answer lights the steps that carry it, and the zones they sit in")
    func provenance() throws {
        var model = BrainFixtures.model()
        #expect(model.provenanceZones == nil)
        #expect(!model.isProvenanceActive)
        model.setProvenance(token: Fixtures.flac)
        let expected = NeuralProvenance.steps(touching: Fixtures.flac, in: model.steps)
        #expect(!expected.isEmpty)
        #expect(model.provenanceSteps == Set(expected))
        let zones = Set(expected.compactMap { model.step(id: $0)?.zone })
        #expect(model.provenanceZones == zones)
        #expect(model.isProvenanceActive)

        model.setProvenance(token: "no/step/carries/this.swift")
        #expect(model.provenanceSteps.isEmpty)
        #expect(model.provenanceZones == nil)
        #expect(!model.isProvenanceActive)

        model.setProvenance(token: Fixtures.flac)
        model.setProvenance(token: nil)
        #expect(model.provenanceSteps.isEmpty)
        #expect(model.provenanceZones == nil)
    }

    @Test("only words some step carries are answer tokens")
    func answerTokens() {
        let model = BrainFixtures.model()
        let text = "Done: out/demo/tailscode-demo.mp4 and nowhere/at/all.swift were made."
        let tokens = model.answerTokens(in: text).map(\.text)
        #expect(tokens == ["out/demo/tailscode-demo.mp4"])
        #expect(NeuralProvenance.tokens(in: text).count == 2)
    }

    @Test("a replay plays on the timeline, and the playhead is a fraction of it")
    func replayClock() throws {
        var model = BrainFixtures.model()
        #expect(model.replayTime(now: 5) == nil)
        #expect(model.replayFraction(now: 5) == nil)
        #expect(!model.replayDone(now: 1_000))
        let timeline = model.timeline
        #expect(timeline.duration > 11 && timeline.duration < 13)

        model.startReplay(now: 100)
        #expect(model.isReplaying)
        #expect(model.replayTime(now: 100) == 0)
        #expect(model.replayTime(now: 103) == 3)
        #expect(model.replayTime(now: 100 + timeline.duration + 50) == timeline.duration)
        let half = try #require(model.replayFraction(now: 100 + timeline.duration / 2))
        #expect(abs(half - 0.5) < 1e-9)
        #expect(!model.replayDone(now: 100 + timeline.duration - 0.01))
        #expect(model.replayDone(now: 100 + timeline.duration))

        model.stopReplay()
        #expect(!model.isReplaying)
        #expect(model.replayTime(now: 101) == nil)
        #expect(!model.replayDone(now: 1_000))
    }

    @Test("scrubbing sets the playhead by fraction, clamped, and the end hands back to the turn")
    func scrubbing() throws {
        var model = BrainFixtures.model()
        for fraction in [0.0, 0.25, 0.5, 0.999, 1.0] {
            model.scrub(to: fraction)
            let read = try #require(model.replayFraction(now: 0))
            #expect(abs(read - fraction) < 1e-9)
        }
        model.scrub(to: 7)
        #expect(model.replayFraction(now: 0) == 1)
        model.scrub(to: -3)
        #expect(model.replayFraction(now: 0) == 0)
        model.scrub(to: 0.4)
        model.endScrub()
        #expect(model.isReplaying)
        model.scrub(to: 0.999)
        model.endScrub()
        #expect(!model.isReplaying)
        #expect(!model.replayDone(now: 0))
    }

    @Test("a step is the active one from its fire time")
    func replayActiveStep() throws {
        var model = BrainFixtures.model()
        let timeline = model.timeline
        model.startReplay(now: 50)
        let opening = try #require(model.ticker(now: 50))
        #expect(opening.number == 1)
        for index in [4, 10, 25] {
            let before = model.ticker(now: 50 + timeline.fireTimes[index] - 0.001)
            let at = try #require(model.ticker(now: 50 + timeline.fireTimes[index] + 0.001))
            #expect((before?.number ?? 0) <= index)
            #expect(at.number >= index + 1)
            #expect(at.number == (timeline.activeStep(at: timeline.fireTimes[index] + 0.001) ?? -1) + 1)
            #expect(at.stepID == model.steps[at.number - 1].id)
        }
        let end = try #require(model.ticker(now: 50 + timeline.duration))
        #expect(end.number == model.steps.count)
    }

    @Test("the replay's state is the head working in the zone of the step at the playhead")
    func replayState() throws {
        var model = BrainFixtures.model()
        let fire = model.timeline.fireTimes
        let shell = try #require(model.steps.firstIndex { $0.zone == .shell })
        model.startReplay(now: 0)
        let during = model.shownState(now: fire[shell] + 0.001)
        #expect(during.zone == model.steps[model.timeline.activeStep(at: fire[shell] + 0.001) ?? 0].zone)
        #expect(during.tone == .live)
        #expect(during.motion == .breath)
        let before = model.shownState(now: -1)
        #expect(before.zone == .think)
        model.stopReplay()
        #expect(model.shownState(now: 3) == model.state)
    }

    @Test("a running turn's ticker is its latest step, and a settled turn has none")
    func tickerLive() throws {
        let running = BrainFixtures.turn(running: true)
        let model = BrainFixtures.model(running, context: BrainFixtures.working())
        let ticker = try #require(model.ticker)
        let last = try #require(running.steps.last)
        #expect(ticker.stepID == last.id)
        #expect(ticker.number == running.steps.count)
        #expect(ticker.total == running.steps.count)
        #expect(ticker.counter == "step \(running.steps.count) of \(running.steps.count)")
        #expect(ticker.zone == last.zone)
        #expect(ticker.rawTitle == NeuralReading.title(of: last))
        #expect(ticker.title == NeuralHuman.title(at: running.steps.count - 1, in: running.steps).text)
        #expect(ticker.text == "\(ticker.title) \(ticker.detail)")
        #expect(ticker.statusWord == NeuralReading.statusWord(last.status))
        #expect(BrainFixtures.model().ticker == nil)
    }

    @Test("a ticker's words fold onto one line and are cut")
    func tickerWords() throws {
        let long = String(repeating: "word ", count: 80)
        let thought = ReadingFixtures.step(0, .think, "Thinking", text: "first line\nsecond   line")
        let note = ReadingFixtures.step(1, .say, "Said", text: long)
        var turn = NeuralTurn(id: "x", steps: [thought, note], outcome: .running)
        turn.startedAt = ReadingFixtures.start
        var model = BrainFixtures.model(turn)
        #expect(model.ticker?.detail.count ?? 0 <= NeuralBrainModel.tickerLimit)
        #expect(model.ticker?.detail.contains("\n") == false)
        model.startReplay(now: 0)
        let first = try #require(model.ticker(now: 0))
        #expect(first.detail == "first line second line")
        #expect(first.text == "Thinking first line second line")
    }

    @Test("the frame is NeuralFrame.at for the model's own inputs")
    func frameComposition() throws {
        for (running, context) in [
            (false, NeuralBrainContext.none), (true, BrainFixtures.working()),
            (true, NeuralBrainContext(activity: .needsApproval)),
        ] {
            let model = BrainFixtures.model(BrainFixtures.turn(running: running), context: context)
            for time in [0.0, 0.7, 12.3] {
                for reduce in [false, true] {
                    let expected = NeuralFrame.at(
                        time: time, state: model.state, face: model.face, meters: model.meters,
                        reduceMotion: reduce, hover: nil, provenance: nil)
                    #expect(model.frame(time: time, reduceMotion: reduce) == expected)
                }
            }
        }
    }

    @Test("a settled head carries the selected node's zone as its hover and the answer's zones")
    func frameHoverAndProvenance() throws {
        var model = BrainFixtures.model()
        let sense = try #require(model.steps.first { $0.zone == .sense })
        model.setHover(sense.id)
        var expected = NeuralFrame.at(
            time: 1, state: model.state, face: model.face, meters: model.meters, reduceMotion: false,
            hover: .sense, provenance: nil)
        #expect(model.frame(time: 1, reduceMotion: false) == expected)
        #expect(model.frame(time: 1, reduceMotion: false).intensity[NeuralZone.sense.rawValue] > 1)

        model.clearSelection()
        model.setProvenance(token: Fixtures.flac)
        expected = NeuralFrame.at(
            time: 1, state: model.state, face: model.face, meters: model.meters, reduceMotion: false,
            hover: nil, provenance: model.provenanceZones)
        #expect(model.frame(time: 1, reduceMotion: false) == expected)
    }

    @Test("a settled turn needs no clock and a working one does")
    func clock() throws {
        let settled = BrainFixtures.model()
        #expect(!settled.needsClock)
        #expect(settled.tempo == .stopped)
        #expect(settled.frame(time: 3, reduceMotion: false).settled)

        let running = BrainFixtures.model(BrainFixtures.turn(running: true), context: BrainFixtures.working())
        #expect(running.needsClock)
        #expect(running.tempo == .activity)
        #expect(!running.needsClock(reduceMotion: true))
        #expect(running.tempo(reduceMotion: true) == .stopped)

        let stopped = BrainFixtures.model(
            BrainFixtures.turn(), context: NeuralBrainContext(activity: .failed))
        #expect(!stopped.needsClock)
    }

    @Test("a step that is running or waiting keeps the clock for its node while the head is at rest")
    func clockForNodes() {
        let steps = [ReadingFixtures.step(0, .shell, "Bash", status: .running)]
        let model = BrainFixtures.model(NeuralTurn(id: "x", steps: steps, outcome: .settled))
        #expect(model.state == .settled)
        #expect(model.needsClock)
        #expect(!model.needsClock(reduceMotion: true))
    }

    @Test("a replay, a scrub and a dive are the display's business")
    func clockReplayScrubDive() {
        var model = BrainFixtures.model()
        model.startReplay(now: 0)
        #expect(model.needsClock)
        #expect(model.needsClock(reduceMotion: true))
        #expect(model.tempo == .activity)
        model.scrub(to: 0.3)
        #expect(model.needsClock)
        #expect(model.tempo == .display)
        #expect(model.tempo(reduceMotion: true) == .stopped)
        model.stopReplay()
        #expect(model.tempo == .stopped)
        model.setDiving(true)
        #expect(model.needsClock)
        #expect(model.tempo == .display)
        model.setDiving(false)
        #expect(!model.needsClock)
    }

    @Test("a call's animated ear keeps the clock of a settled head")
    func clockForCall() {
        let listening = BrainFixtures.model(context: NeuralBrainContext(call: .listening))
        #expect(listening.needsClock)
        let ended = BrainFixtures.model(context: NeuralBrainContext(call: .ended))
        #expect(!ended.needsClock)
    }

    @Test("a streamed word changes nothing a layout reads, a new step or a new status does")
    func updateOnlyWhenStructural() throws {
        var messages: [ChatMessage] = [
            Fixtures.user(0),
            Fixtures.message(1, [Fixtures.read("a/b/c.swift", out: ["10 lines"])]),
            Fixtures.message(2, [.reasoning("Looking")], streaming: true),
        ]
        func turn() -> NeuralTurn { NeuralTurns.partition(messages: messages, running: true)[0] }
        var model = BrainFixtures.model(turn(), context: BrainFixtures.working(.fileRead))
        let start = model.revision
        for words in ["Looking at", "Looking at the whole", "Looking at the whole file now"] {
            messages[2] = Fixtures.message(2, [.reasoning(words)], streaming: true)
            model.update(turn: turn(), context: BrainFixtures.working(.fileRead))
            #expect(model.revision == start)
            #expect(model.steps.last?.text == words)
        }

        messages[2] = Fixtures.message(
            2, [.reasoning("Looking at the whole file now"), Fixtures.bash("ls", status: .running)],
            streaming: true)
        model.update(turn: turn(), context: BrainFixtures.working(.shell))
        #expect(model.revision == start + 1)
        #expect(model.steps.count == 3)
        #expect(model.layout.stepCount == 3)

        messages[2] = Fixtures.message(
            2, [.reasoning("Looking at the whole file now"), Fixtures.bash("ls", out: ["x"])],
            streaming: true)
        model.update(turn: turn(), context: BrainFixtures.working(.shell))
        #expect(model.revision == start + 2)
        #expect(model.steps.last?.status == .ok)
    }

    @Test("updating with the turn it has changes nothing and keeps the selection")
    func updateKeepsSelection() throws {
        let turn = BrainFixtures.turn()
        var model = BrainFixtures.model(turn)
        let id = model.steps[3].id
        model.togglePin(id)
        let hot = model.hotSteps
        let revision = model.revision
        model.update(turn: turn, context: .none)
        #expect(model.revision == revision)
        #expect(model.pinned == id)
        #expect(model.hotSteps == hot)
    }

    @Test("a selection the turn no longer holds is dropped")
    func updateDropsSelection() {
        var model = BrainFixtures.model()
        model.togglePin(model.steps[20].id)
        model.update(turn: BrainFixtures.buildFix(), context: .none)
        #expect(model.pinned == nil)
        #expect(model.hotSteps.isEmpty)
    }

    @Test("a waiting step names the zone the head waits in")
    func waitingZone() throws {
        let messages = [
            Fixtures.user(0),
            Fixtures.message(1, [Fixtures.read("a/b/c.swift")]),
            Fixtures.message(
                2, [Fixtures.tool("Task", ["description": .string("review")], status: .running)],
                streaming: true),
        ]
        let awaiting = NeuralAwaiting(approvals: ["m2:p0"])
        let turn = NeuralTurns.partition(messages: messages, running: true, awaiting: awaiting)[0]
        #expect(turn.steps.last?.status == .waitingApproval)
        let model = BrainFixtures.model(turn, context: NeuralBrainContext(activity: .needsApproval))
        #expect(model.state.label == "approval")
        #expect(model.state.zone == .delegate)
        #expect(model.state.tone == .attention)
        #expect(model.state.motion == .heartbeat)

        let answer = BrainFixtures.model(turn, context: NeuralBrainContext(activity: .needsAnswer))
        #expect(answer.state.zone == .think)
    }

    @Test("a stalled step holds its zone and a failed turn holds the zone of its wound")
    func stalledAndFailed() throws {
        let messages = [
            Fixtures.user(0),
            Fixtures.message(1, [Fixtures.bash("make", status: .running)]),
        ]
        let stalled = NeuralTurns.partition(
            messages: messages, running: false, awaiting: NeuralAwaiting(stalled: ["m1:p0"]))[0]
        let model = BrainFixtures.model(stalled, context: NeuralBrainContext(activity: .stalled(tasks: 1)))
        #expect(model.state.label == "stalled")
        #expect(model.state.zone == .shell)

        let failed = [
            Fixtures.user(0),
            Fixtures.message(1, [Fixtures.edit("a.swift", added: 1, removed: 0)]),
            Fixtures.message(2, [Fixtures.bash("make", out: ["error"], status: .error), Fixtures.read("b.swift")], error: "boom"),
        ]
        let turn = NeuralTurns.partition(messages: failed, running: false)[0]
        #expect(turn.outcome == .failed)
        let wound = BrainFixtures.model(turn)
        #expect(wound.state.failure)
        #expect(wound.state.zone == .shell)
    }

    @Test("a settled turn wears who answered, and the context's own face wins when given")
    func faceAndMeters() {
        var turn = BrainFixtures.turn()
        turn.modelID = "claude-opus-4-8"
        turn.effort = "high"
        let model = BrainFixtures.model(turn)
        #expect(model.face == NeuralFace(model: "claude-opus-4-8", providerID: nil, effort: "high"))
        #expect(model.state == .settled)

        let given = NeuralFace(family: nil, bucket: 3, effort: 2)
        let context = NeuralBrainContext(face: given)
        #expect(BrainFixtures.model(turn, context: context).face == given)

        var tracked = BrainFixtures.model(turn)
        tracked.update(turn: turn, context: NeuralBrainContext(call: .hearing))
        #expect(tracked.meters.call == .hearing)
        tracked.update(turn: turn, context: .none)
        #expect(tracked.meters.call == nil)
    }

    @Test("the glyph wears the state's tone and rings the lit zone")
    func glyph() throws {
        let settled = BrainFixtures.model()
        #expect(settled.glyph.eyeTone == .identity)
        #expect(settled.glyph.dots.allSatisfy { $0.activeRing == nil })
        #expect(settled.glyph == NeuralGlyph(steps: settled.steps, eyeTone: .identity))

        let running = BrainFixtures.model(BrainFixtures.turn(running: true), context: BrainFixtures.working())
        #expect(running.glyph.eyeTone == .live)
        let shell = try #require(running.glyph.dots.first { $0.zone == .shell })
        #expect(shell.activeRing != nil)
        #expect(shell.isLive || running.steps.last?.zone != .shell)
        #expect(settled.glyph(dim: true).dots.allSatisfy { $0.opacity < settled.glyph.dots[0].opacity })
    }

    @Test("the line and the spoken sentence are the reading's own")
    func words() {
        let model = BrainFixtures.model()
        let now = ReadingFixtures.start
        #expect(model.line(now: now) == NeuralReading.line(for: model.turn, now: now))
        #expect(model.spoken(now: now) == NeuralReading.spoken(model.turn, now: now))
        #expect(model.line.tools == 25)
    }

    @Test("the context reads a status line's own facts")
    func contextFromFacts() {
        var facts = StatusFacts()
        facts.activity = .thinking
        facts.context = ContextFill(used: 80_000, window: 100_000, model: nil, basis: .reported)
        let context = NeuralBrainContext(facts: facts, call: .listening)
        #expect(context.activity == .thinking)
        #expect(context.fill == facts.context)
        #expect(context.call == .listening)
        let model = BrainFixtures.model(context: context)
        #expect(model.meters.contextTone == .danger)
        #expect(model.state.zone == .think)
    }

    @Test("a turn without steps is not a brain")
    func notABrain() {
        let model = BrainFixtures.model(NeuralTurn(id: "empty"))
        #expect(!model.isBrain)
        #expect(model.ticker == nil)
        #expect(model.nodeCount == 0)
        #expect(BrainFixtures.model().isBrain)
    }
}
