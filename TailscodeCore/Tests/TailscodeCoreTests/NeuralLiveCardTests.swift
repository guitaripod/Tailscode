import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

enum LiveFixtures {
    typealias V = VerdictFixtures
    typealias NF = NeuralTurnFixtures

    static func running(
        _ kinds: [[MessagePart.Kind]], awaiting: NeuralAwaiting = .none
    ) -> NeuralBrainModel {
        BrainFixtures.model(V.turn(kinds, running: true, awaiting: awaiting))
    }

    static func withLastStep(_ status: NeuralStatus, _ kinds: [[MessagePart.Kind]]) -> NeuralBrainModel {
        var turn = V.turn(kinds, running: true)
        turn.steps[turn.steps.count - 1].status = status
        return BrainFixtures.model(turn)
    }

    static func working() -> NeuralBrainModel {
        running([
            [.text("Checking the build first.")],
            [V.bash("ls"), V.bash("pwd")],
            [V.bash("swift test", running: true)],
        ])
    }
}

@Suite("Neural live card")
struct NeuralLiveCardTests {
    typealias L = LiveFixtures
    typealias V = VerdictFixtures
    typealias NF = NeuralTurnFixtures

    private var start: Date { NF.date(1) }

    @Test("only a running turn has a live card, and a settled one is exactly what it was")
    func onlyRunning() {
        #expect(L.working().liveCard != nil)
        let settled = BrainFixtures.model(V.turn([[V.bash("ls")], [.text("done")]]))
        #expect(settled.liveCard == nil)
        #expect(settled.brainCard.live == nil)
        #expect(L.working().brainCard.live == L.working().liveCard)
        #expect(!settled.needsLiveCardClock)
        #expect(settled.liveCardTempo == .stopped)
    }

    @Test("the headline is the verdict in words, with its glyph and tone")
    func headline() throws {
        let model = L.working()
        let card = try #require(model.liveCard)
        let reading = card.reading(now: NF.date(4), lastActivity: NF.date(3))
        #expect(reading.word == "Working" && reading.tone == .live && reading.glyph == .pulse)
        let waiting = try #require(
            L.withLastStep(.waitingApproval, [[V.bash("ls")], [V.bash("rm -r build", running: true)]]).liveCard)
        let w = waiting.reading(now: NF.date(4))
        #expect(w.word == "Waiting for you" && w.tone == .attention && w.glyph == .pauseBars)
        #expect(waiting.motion == .heartbeat && waiting.edgePulses)
    }

    @Test("an error in flight says Hit an error, and Hit an error: trying again once the retry runs")
    func errorInFlight() throws {
        let hit = try #require(L.running([[V.bash("make", ok: false)]]).liveCard)
        let hitReading = hit.reading(now: NF.date(3))
        #expect(hitReading.word == "Hit an error" && hitReading.glyph == .triangle && hitReading.tone == .attention)
        let retry = try #require(L.running([[V.bash("make", ok: false)], [V.bash("make", running: true)]]).liveCard)
        let retryReading = retry.reading(now: NF.date(4))
        #expect(retryReading.word == "Hit an error: trying again" && retryReading.glyph == .triangle)
        #expect(retry.flight?.title == "Building the project again")
    }

    @Test("the counts read steps, then what it said, then the clock")
    func counts() throws {
        let card = try #require(L.working().liveCard)
        let reading = card.reading(now: start.addingTimeInterval(245))
        #expect(reading.counts == "4 steps \u{00B7} 1 said \u{00B7} 4m 05s")
        #expect(reading.elapsed == 245)
        #expect(NeuralLiveCard.clock(42) == "42s" && NeuralLiveCard.clock(65) == "1m 05s")
        #expect(NeuralLiveCard.clock(3_840) == "1h 04m" && NeuralLiveCard.clock(600) == "10m 00s")
    }

    @Test("the NOW line is the step in flight in plain words, with its argument and its last output line")
    func nowLine() throws {
        let model = L.running([
            [V.bash("ls")],
            [.tool(ToolCall(
                id: "x", name: "Bash", status: .running, input: .object(["command": .string("swift test --parallel")]),
                output: "Compiling Rows.swift\nExecuted 4 tests"))],
        ])
        let card = try #require(model.liveCard)
        let line = card.line(now: NF.date(3), lastActivity: NF.date(3))
        #expect(line.kind == .step && line.title == "Running the tests")
        #expect(line.argument == "swift test --parallel")
        #expect(line.trailing == .output(text: "Executed 4 tests", tone: .quiet))
        let compact = card.line(now: NF.date(3), lastActivity: NF.date(3), compact: true)
        #expect(compact.trailing == .none && compact.title == "Running the tests")
    }

    @Test("an error's output stays amber")
    func errorOutput() throws {
        let model = L.running([[.tool(ToolCall(
            id: "x", name: "Bash", status: .running, input: .object(["command": .string("make")]),
            output: "Rows.swift:1: error: nope"))]])
        let line = try #require(model.liveCard).line(now: NF.date(2), lastActivity: NF.date(2))
        guard case .output(_, let tone) = line.trailing else {
            Issue.record("expected output")
            return
        }
        #expect(tone == .quiet || tone == .attention)
    }

    @Test("forty seconds of nothing replaces the output with the silence, in attention, from the client's clock")
    func silence() throws {
        let card = try #require(L.working().liveCard)
        let seen = NF.date(10)
        let quiet = card.line(now: seen.addingTimeInterval(39), lastActivity: seen)
        #expect(quiet.trailing != .silence("silent for 39s"))
        let silent = card.line(now: seen.addingTimeInterval(40), lastActivity: seen)
        #expect(silent.trailing == .silence("silent for 40s"))
        #expect(card.reading(now: seen.addingTimeInterval(40), lastActivity: seen).isSilent)
        #expect(!card.reading(now: seen.addingTimeInterval(39.9), lastActivity: seen).isSilent)
        #expect(NeuralLiveCard.silenceThreshold == 40)
        let compact = card.line(now: seen.addingTimeInterval(60), lastActivity: seen, compact: true)
        #expect(compact.trailing == .silence("silent for 1m 0s"))
        let fresh = card.line(now: seen.addingTimeInterval(60), lastActivity: seen.addingTimeInterval(59))
        #expect(fresh.trailing != .silence("silent for 1m 0s"))
    }

    @Test("a stuck turn says how long")
    func stuck() throws {
        let model = L.withLastStep(.stalled, [[V.bash("ls")], [V.bash("sleep 99", running: true)]])
        let stuck = try #require(model.liveCard)
        let reading = stuck.reading(now: NF.date(2).addingTimeInterval(42), lastActivity: NF.date(2))
        #expect(stuck.verdict == .stuck)
        #expect(reading.word == "Stuck for 42s" && reading.glyph == .dashedClock && reading.tone == .attention)
        #expect(stuck.motion == .still && !stuck.edgePulses)
    }

    @Test("a note replaces the line for four seconds, from the moment the client saw it")
    func quote() throws {
        let model = L.running([[V.bash("ls")], [.text("Tests pass; moving on to the linter.")], [V.bash("swiftlint", running: true)]])
        let card = try #require(model.liveCard)
        let quote = try #require(card.quote)
        #expect(quote.speaker == "Claude" || !quote.speaker.isEmpty)
        #expect(quote.words == "Tests pass; moving on to the linter.")
        let arrived = NF.date(30)
        let held = card.line(now: arrived.addingTimeInterval(3.9), quoteArrivedAt: arrived)
        #expect(held.kind == .quote && held.quote == quote && held.argument == nil)
        let gone = card.line(now: arrived.addingTimeInterval(4), quoteArrivedAt: arrived)
        #expect(gone.kind == .step)
        #expect(card.holdsQuote(arrivedAt: arrived, now: arrived.addingTimeInterval(3.99)))
        #expect(!card.holdsQuote(arrivedAt: arrived, now: arrived.addingTimeInterval(4)))
        #expect(NeuralLiveCard.quoteHold == 4)
        #expect(quote.line(fittingChars: 30).hasPrefix("\(quote.speaker): "))
        #expect(L.running([[V.bash("ls")]]).liveCard?.quote == nil)
    }

    @Test("the active zone breathes on the shared swell, a wait knocks, and a stuck or reduced card holds still")
    func swell() throws {
        let card = try #require(L.working().liveCard)
        #expect(card.motion == .breath && card.activeZone != nil)
        var low = 1.0
        var high = 0.0
        for ms in stride(from: 0.0, to: 1.9, by: 0.01) {
            let level = card.swell(at: ms)
            low = min(low, level)
            high = max(high, level)
            #expect(abs(level - card.swell(at: ms + ActivityTuning.breathPeriod)) < 1e-9)
        }
        #expect(abs(low - ActivityTuning.breathFloor) < 0.01 && high > 0.99)
        #expect(card.swell(at: 0.4, reduceMotion: true) == 1)
        #expect(card.edgeLevel(at: 0.4) == card.swell(at: 0.4))
        #expect(L.working().needsLiveCardClock && L.working().liveCardTempo == .activity)
        #expect(!L.working().needsLiveCardClock(reduceMotion: true))
        #expect(L.working().liveCardTempo(reduceMotion: true) == .stopped)
    }

    @Test("an unchanged turn is an equal card, so a client redraws on its own clock only")
    func equality() {
        #expect(L.working().liveCard == L.working().liveCard)
        #expect(L.working().liveCard != L.running([[V.bash("ls")]]).liveCard)
    }
}

@Suite("Neural card settle")
struct NeuralCardSettleTests {
    typealias S = NeuralCardSettle

    private func at(_ ms: Double) -> S { S.at(ms / 1000) }

    @Test("it takes 400 ms and its endpoints are the live card and the settled one")
    func endpoints() {
        #expect(S.duration == 0.4 && NeuralBrainCard.settleDuration == 0.4)
        let start = at(0)
        #expect(start.progress == 0 && start.lights == 0 && start.liveHeadlineAlpha == 1)
        #expect(start.settledHeadlineAlpha == 0 && start.nowLineAlpha == 1 && start.firstWordsAlpha == 0)
        #expect(!start.edgePulses)
        let end = at(400)
        #expect(end.isDone && end.lights == 1 && end.eye == 1)
        #expect(end.liveHeadlineAlpha == 0 && end.settledHeadlineAlpha == 1)
        #expect(end.nowLineAlpha == 0 && end.firstWordsAlpha == 1 && end.settledHeadlineOffsetY == 0)
        #expect(S.settled.isDone && S.live.edgePulses && !S.settled.edgePulses)
        #expect(at(900) == at(400))
        #expect(at(-5) == at(0))
    }

    @Test("the live headline is out in 170 ms lifting 6 points, the settled one is in from 130 to 360 rising 6")
    func headlines() {
        #expect(at(170).liveHeadlineAlpha == 0 && at(85).liveHeadlineAlpha > 0 && at(85).liveHeadlineAlpha < 1)
        #expect(at(0).liveHeadlineOffsetY == 0 && at(170).liveHeadlineOffsetY == -6)
        #expect(at(130).settledHeadlineAlpha == 0 && at(360).settledHeadlineAlpha == 1)
        #expect(at(129).settledHeadlineOffsetY == 6 && at(360).settledHeadlineOffsetY == 0)
        #expect(at(140).nowLineAlpha == 0 && at(70).nowLineAlpha == 0.5)
        #expect(at(170).firstWordsAlpha == 0 && at(171).firstWordsAlpha > 0 && at(360).firstWordsAlpha == 1)
        #expect(at(200).liveHeadlineAlpha == 0 && at(200).nowLineAlpha == 0)
    }

    @Test("the lights ease out cubic and every value stays inside its range, monotonically")
    func monotone() {
        var lights = 0.0
        var settled = 0.0
        for ms in stride(from: 0.0, through: 400, by: 4) {
            let frame = at(ms)
            #expect(abs(frame.lights - NeuralTransition.easeOutCubic(ms / 400)) < 1e-9)
            #expect(frame.lights >= lights - 1e-12 && frame.settledHeadlineAlpha >= settled - 1e-12)
            lights = frame.lights
            settled = frame.settledHeadlineAlpha
            for value in [frame.lights, frame.eye, frame.liveHeadlineAlpha, frame.settledHeadlineAlpha, frame.nowLineAlpha, frame.firstWordsAlpha] {
                #expect(value >= 0 && value <= 1)
            }
        }
    }

    @Test("reduced motion lands at once")
    func reduced() {
        #expect(S.at(0, reduceMotion: true) == .settled)
        #expect(S.at(0.1, reduceMotion: true).isDone)
    }

    @Test("the clock starts the move when a running turn settles, and a card first seen settled has none")
    func clock() {
        var clock = NeuralCardSettleClock()
        let firstSettled = clock.observe(running: false, now: 1)
        #expect(!firstSettled)
        #expect(!clock.isSettling(now: 1) && clock.settle(now: 1) == .settled)
        let started = clock.observe(running: true, now: 2)
        let still = clock.observe(running: true, now: 3)
        #expect(!started && !still)
        let ended = clock.observe(running: false, now: 5)
        #expect(ended)
        #expect(clock.isSettling(now: 5.2) && !clock.isSettling(now: 5.4))
        #expect(abs(clock.settle(now: 5.2).progress - 0.5) < 1e-9)
        #expect(clock.settle(now: 6).isDone)
        let again = clock.observe(running: false, now: 7)
        #expect(!again)
        let resumed = clock.observe(running: true, now: 8)
        #expect(!resumed && !clock.isSettling(now: 8))
    }
}

@Suite("Neural present titles")
struct NeuralPresentTitleTests {
    typealias NF = NeuralTurnFixtures

    private func title(_ kind: MessagePart.Kind) -> String {
        let turn = NeuralTurns.partition(messages: [NF.user(0), NF.message(1, [kind])], running: true)[0]
        return NeuralHuman.presentTitle(at: 0, in: turn.steps)
    }

    @Test("a step in flight reads in the present tense, and a repeated command says again")
    func present() {
        #expect(title(NF.bash("swift build")) == "Building the project")
        #expect(title(NF.bash("swift test")) == "Running the tests")
        #expect(title(NF.bash("swiftlint")) == "Running the linter")
        #expect(title(NF.bash("git push")) == "Pushing")
        #expect(title(NF.bash("git status")) == "Checking git status")
        #expect(title(NF.bash("ffmpeg -i a b")) == "Running ffmpeg")
        #expect(title(NF.read("a/Rows.swift")) == "Reading Rows.swift")
        #expect(title(NF.grep("case x", in: "src", out: [])) == "Searching for case x")
        #expect(title(NF.skill("design", out: [])) == "Using the design skill")
        #expect(title(NF.task("audit the cache", out: [])) == "Asking an agent: audit the cache")
    }
}
