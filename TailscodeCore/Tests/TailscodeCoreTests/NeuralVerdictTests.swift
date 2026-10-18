import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

enum VerdictFixtures {
    typealias NF = NeuralTurnFixtures

    static func turn(_ kinds: [[MessagePart.Kind]], running: Bool = false, error: String? = nil, awaiting: NeuralAwaiting = .none) -> NeuralTurn {
        var messages = [NF.user(0)]
        for (offset, parts) in kinds.enumerated() {
            let last = offset == kinds.count - 1
            messages.append(NF.message(offset + 1, parts, streaming: running && last, error: last ? error : nil))
        }
        return NeuralTurns.partition(messages: messages, running: running, awaiting: awaiting)[0]
    }

    static func bash(_ command: String, ok: Bool = true, running: Bool = false) -> MessagePart.Kind {
        NF.bash(command, out: ok ? ["fine"] : ["Rows.swift:1: error: switch must be exhaustive"], status: running ? .running : ok ? .completed : .error)
    }

    static func edit(_ path: String, ok: Bool) -> MessagePart.Kind {
        .tool(ToolCall(
            id: UUID().uuidString, name: "Edit", status: ok ? .completed : .error,
            input: .object(["file_path": .string(path), "old_string": .string("a"), "new_string": .string("b")]),
            output: ok ? "updated" : "error: string to replace not found"))
    }

    static let steps = ["Done", "Fixed on retry", "Failed", "Hit an error", "Running", "Waiting for you", "Stuck", "Stopped"]
}

@Suite("Neural verdict: steps")
struct NeuralVerdictStepTests {
    typealias V = VerdictFixtures
    typealias NF = NeuralTurnFixtures

    @Test("BUILD_FIX: the failed build that was run again and passed is fixed, and the turn is done after one retry")
    func buildFix() throws {
        let turn = BrainFixtures.buildFix()
        let reading = NeuralVerdict.read(turn)
        let failed = try #require(turn.steps.firstIndex { $0.status == .failed })
        #expect(failed == 5)
        #expect(reading.steps[failed].verdict == .fixed)
        #expect(reading.steps[failed].fixedBy == turn.steps[10].id)
        #expect(reading.steps[failed].fixedByNumber == 11)
        #expect(reading.steps[failed].error == "switch must be exhaustive")
        #expect(reading.verdict == .doneAfterRetries(1))
        #expect(reading.fixed == 1 && reading.unfixed == 0 && reading.firstUnfixedStepID == nil)
        #expect(reading.steps.filter { $0.verdict != .done }.count == 1)
        #expect(reading.onTheWay == "Fixed 1 error on the way")
    }

    @Test("TURN: the failed mux was fixed at the next run of it")
    func demoTurn() throws {
        let turn = BrainFixtures.turn()
        let reading = NeuralVerdict.read(turn)
        let failed = try #require(turn.steps.firstIndex { $0.status == .failed })
        #expect(reading.steps[failed].verdict == .fixed)
        let by = try #require(reading.steps[failed].fixedByNumber)
        #expect(by > failed + 1)
        #expect(turn.steps[by - 1].title == "Bash" && turn.steps[by - 1].status == .ok)
        #expect(reading.verdict == .doneAfterRetries(1))
    }

    @Test("an error nobody fixed is failed, and the turn that ended on it is failed with 1 step failed")
    func unfixed() {
        let turn = V.turn([[V.bash("make", ok: false)], [V.bash("ls")]])
        let reading = NeuralVerdict.read(turn)
        #expect(reading.steps[0].verdict == .failed)
        #expect(reading.verdict == .failed)
        #expect(reading.unfixed == 1 && reading.fixed == 0 && reading.firstUnfixedStepID == turn.steps[0].id)
        #expect(reading.clause == "1 step failed")
        #expect(reading.tone == .danger && reading.word == "Failed")
        let two = V.turn([[V.bash("a", ok: false)], [V.bash("b", ok: false)]])
        #expect(NeuralVerdict.read(two).clause == "2 steps failed")
    }

    @Test("a running turn's fresh error is Hit an error, and it becomes failed once the agent has moved on")
    func tryingAgain() {
        let fresh = V.turn([[V.bash("make", ok: false)]], running: true)
        let reading = NeuralVerdict.read(fresh)
        #expect(reading.steps[0].verdict == .tryingAgain)
        #expect(reading.steps[0].word == "Hit an error" && reading.steps[0].tone == .attention)
        #expect(reading.verdict == .working)
        let moved = V.turn([
            [V.bash("make", ok: false)], [V.bash("a")], [V.bash("b")], [V.bash("c")], [V.bash("d", running: true)],
        ], running: true)
        #expect(NeuralVerdict.read(moved).steps[0].verdict == .failed)
        let near = V.turn([[V.bash("make", ok: false)], [V.bash("a")], [V.bash("b")]], running: true)
        #expect(NeuralVerdict.read(near).steps[0].verdict == .tryingAgain)
        let retried = V.turn([[V.bash("make", ok: false)], [V.bash("make", running: true)]], running: true)
        #expect(NeuralVerdict.read(retried).steps[0].verdict == .tryingAgain)
        let ended = V.turn([[V.bash("make", ok: false)]])
        #expect(NeuralVerdict.read(ended).steps[0].verdict == .failed)
    }

    @Test("a running turn whose error was fixed in flight reads fixed at once")
    func fixedWhileRunning() {
        let turn = V.turn([[V.bash("make", ok: false)], [V.bash("make")], [V.bash("ls", running: true)]], running: true)
        let reading = NeuralVerdict.read(turn)
        #expect(reading.steps[0].verdict == .fixed && reading.steps[0].fixedByNumber == 2)
        #expect(reading.verdict == .working)
    }

    @Test("a file step is fixed by the same tool passing on the same file, and by nothing else")
    func files() {
        let fixed = V.turn([[V.edit("a.swift", ok: false)], [V.edit("a.swift", ok: true)]])
        #expect(fixed.steps[0].recovered)
        #expect(NeuralVerdict.read(fixed).steps[0].verdict == .fixed)
        #expect(NeuralVerdict.read(fixed).verdict == .doneAfterRetries(1))
        let other = V.turn([[V.edit("a.swift", ok: false)], [V.edit("b.swift", ok: true)]])
        #expect(!other.steps[0].recovered)
        #expect(NeuralVerdict.read(other).steps[0].verdict == .failed)
        let read = V.turn([
            [V.edit("a.swift", ok: false)], [.tool(ToolCall(id: "r", name: "Read", status: .completed, input: .object(["file_path": .string("a.swift")]), output: "x"))],
        ])
        #expect(NeuralVerdict.read(read).steps[0].verdict == .failed)
    }

    @Test("running, waiting, stalled and stopped steps have their verdicts, and done says nothing")
    func others() {
        let (waiting, id) = ReadoutFixtures.waitingTurn()
        let reading = NeuralVerdict.read(waiting)
        #expect(reading.steps.last?.verdict == .waiting && waiting.steps.last?.id == id)
        #expect(reading.verdict == .needsYou)
        let stalled = V.turn([[V.bash("sleep", running: true)]], running: true, awaiting: NeuralAwaiting(stalled: ["m1:p0"]))
        #expect(NeuralVerdict.read(stalled).steps[0].verdict == .stalled)
        #expect(NeuralVerdict.read(stalled).verdict == .stuck)
        let running = V.turn([[V.bash("sleep", running: true)]], running: true)
        #expect(NeuralVerdict.read(running).steps[0].verdict == .running)
        let stopped = NeuralTurns.partition(messages: [
            NF.user(0), NF.message(1, [NF.bash("sleep 9", status: .stopped)], finish: "abort"),
        ], running: false)[0]
        #expect(NeuralVerdict.read(stopped).steps[0].verdict == .stopped)
        #expect(NeuralVerdict.read(stopped).verdict == .stopped)
        #expect(!NeuralVerdict.Step.done.isMarked && NeuralVerdict.Step.fixed.isMarked)
    }

    @Test("the turn's other verdicts: an error on the last message fails it, no words is didn't answer")
    func turnVerdicts() {
        let errored = V.turn([[V.bash("ls")]], error: "provider error")
        #expect(NeuralVerdict.read(errored).verdict == .failed)
        #expect(NeuralVerdict.read(errored).clause == "Failed")
        let silent = NeuralTurns.partition(messages: [
            NF.user(0), NF.message(1, [.reasoning("   ")], finish: "stop"),
        ], running: false)[0]
        let clean = V.turn([[V.bash("ls")]])
        #expect(NeuralVerdict.read(clean).verdict == .done)
        #expect(NeuralVerdict.read(clean).clause == nil)
        _ = silent
    }

    @Test("every step verdict has the words, the tone and the chip the table gives")
    func table() {
        let verdicts = NeuralVerdict.Step.allCases
        #expect(verdicts.map(\.word) == V.steps)
        #expect(verdicts.map(\.tone) == [.quiet, .attention, .danger, .attention, .live, .attention, .attention, .quiet])
        #expect(verdicts.map(\.chipKind) == [.done, .fixed, .failed, .hitError, .running, .waiting, .stalled, .stopped])
        #expect(NeuralVerdict.Turn.done.word == "Done")
        #expect(NeuralVerdict.Turn.doneAfterRetries(1).word == "Done, fixed 1 error")
        #expect(NeuralVerdict.Turn.doneAfterRetries(3).word == "Done, fixed 3 errors")
        #expect(NeuralVerdict.Turn.needsYou.word == "Needs you")
        #expect(NeuralVerdict.Turn.working.word == "Working")
        #expect(NeuralVerdict.Turn.stuck.word == "Stuck")
        #expect(NeuralVerdict.Turn.stopped.word == "Stopped")
        #expect(NeuralVerdict.Turn.didntAnswer.word == "Didn't answer")
        #expect(NeuralVerdict.Turn.failed.word == "Failed")
        #expect(NeuralVerdict.Turn.doneAfterRetries(1).tone == .attention)
        #expect(NeuralVerdict.Turn.failed.tone == .danger)
        #expect(NeuralVerdict.Turn.done.tone == .quiet && NeuralVerdict.Turn.working.tone == .live)
        #expect(NeuralReading.fixedOnTheWay(3) == "Fixed 3 errors on the way")
        #expect(NeuralReading.fixedAtStep(8) == "fixed an error at step 8")
    }

    @Test("the sentence under a fixed chip says where it failed and where it passed")
    func sentence() throws {
        let turn = BrainFixtures.buildFix()
        let reading = NeuralVerdict.step(at: 5, in: turn)
        #expect(reading.sentence == "Fixed on retry. It failed here (switch must be exhaustive) and passed at step 11.")
        #expect(NeuralVerdict.step(at: 0, in: turn).sentence == "Done")
        #expect(NeuralVerdict.step(at: 99, in: turn).verdict == .done)
        #expect(NeuralReading.fixedDetail(error: nil, number: 4) == "It failed here and passed at step 4.")
    }

    @Test("the model reads the verdicts once per change and answers for a step by id")
    func model() {
        let model = BrainFixtures.model(BrainFixtures.buildFix())
        #expect(model.turnVerdict == .doneAfterRetries(1))
        #expect(model.verdict(ofStep: model.steps[5].id)?.verdict == .fixed)
        #expect(model.verdict(ofStep: "nope") == nil)
        #expect(model.verdicts.steps.count == 14)
    }

    @Test("reading a 2,000-step turn is linear")
    func large() {
        let turn = NeuralTurn(id: "t", steps: StepListFixtures.synthetic(2_000), outcome: .settled)
        let clock = ContinuousClock()
        var reading: NeuralVerdict.TurnReading?
        let elapsed = clock.measure { reading = NeuralVerdict.read(turn) }
        #expect(reading?.steps.count == 2_000)
        #expect(reading?.unfixed ?? 0 > 0)
        let parts = elapsed.components
        #expect(Double(parts.seconds) + Double(parts.attoseconds) / 1e18 < 1)
    }
}

@Suite("Neural verdict: no failed language for a turn that got there")
struct NeuralVerdictSweepTests {
    typealias A = AccountFixtures

    private func words(_ text: String) -> Bool { text.lowercased().contains("fail") }

    @Test("a fully fixed turn says fixed everywhere and never failed, in any string or tone of the card, account, list or readout")
    func sweep() throws {
        let messages = AccountFixtures.messages()
        let model = AccountFixtures.model(messages)
        let turn = model.turn
        let reading = NeuralVerdict.read(turn)
        #expect(reading.fixed == 1 && reading.unfixed == 0)
        var strings: [String] = []
        var tones: [NeuralTone] = []

        let card = model.brainCard(now: Date(timeIntervalSince1970: 1_000_100))
        strings += card.headline.pieces.map(\.text) + [card.spoken, card.digest, card.thirdLine(fittingChars: 200)]
        tones += card.headline.pieces.compactMap(\.tone) + [card.edgeTone]
        tones += card.lights.map(\.ringTone).filter { $0 != .quiet }
        #expect(card.edge == .settled && card.ringZones.isEmpty)
        #expect(card.lights.contains { $0.ringStyle == .repairedDashed && $0.ringTone == .attention })
        strings += card.chips.map(\.label)

        let account = model.account(now: Date(timeIntervalSince1970: 1_000_100), tz: A.utc, answer: "Done.", prompt: "Build it")
        strings += [account.header.verdictWord, account.header.fixedWords ?? ""]
        tones.append(account.header.tone)
        let vitals = account.vitals(now: Date(timeIntervalSince1970: 1_000_100))
        strings += [vitals.statusLine, vitals.counts]
        for item in account.items {
            guard case .work(let work) = item else { continue }
            strings += [work.words, work.line] + work.fixedWords + work.retries.map(\.label)
            tones += work.entries.map { $0.verdict.tone }
        }
        if let result = account.result {
            strings += result.checks.compactMap(\.retriesWords) + result.checks.map(\.title)
            tones += result.checks.map { $0.verdict.tone }
            #expect(result.unfixed.isEmpty)
        }

        let list = model.stepList
        for row in list.rows {
            strings += [row.title, row.markWord ?? "", row.related?.label ?? ""]
            if row.markWord != nil { tones.append(row.markTone) }
        }
        strings += list.zoneChips.map(\.label) + [list.countLabel]

        for index in model.steps.indices {
            let readout = model.readout(now: Date(), tz: A.utc)
            _ = readout
            let step = NeuralReadout.make(model: model, subject: .step(model.steps[index].id), tz: A.utc)
            if let shown = step.step {
                strings += [shown.header.chip.plainWord, shown.header.chip.word, shown.subject.title]
                strings += shown.relations.map(\.label)
                tones.append(shown.header.chip.tone)
            }
        }
        let digest = NeuralReadout.make(model: model, subject: .digest, tz: A.utc).digest
        strings += [digest?.failuresTitle ?? "", digest?.headline ?? ""] + (digest?.failures.map(\.verdictWord) ?? []) + (digest?.failures.map(\.label) ?? [])
        for light in model.nodeDrawsForTest() { tones.append(light) }

        for text in strings where words(text) { Issue.record("a fixed turn says \"\(text)\"") }
        #expect(!tones.contains(.danger))
    }

    @Test("the glyph's failed mask is for an unfixed failure only")
    func glyphMask() {
        let fixed = BrainFixtures.model(BrainFixtures.buildFix())
        #expect(fixed.glyphWire.failed == nil)
        #expect(fixed.glyph.dots.allSatisfy { $0.failureRing == nil })
        let broken = BrainFixtures.model(NeuralTurns.partition(messages: [
            NeuralTurnFixtures.user(0),
            NeuralTurnFixtures.message(1, [NeuralTurnFixtures.bash("false", out: ["boom"], status: .error)]),
        ], running: false)[0])
        #expect(broken.glyphWire.failed != nil)
        #expect(broken.glyph.dots.contains { $0.failureRing != nil })
        let files = BrainFixtures.model(VerdictFixtures.turn([[VerdictFixtures.edit("a", ok: false)], [VerdictFixtures.edit("a", ok: true)]]))
        #expect(files.glyphWire.failed == nil)
    }
}

extension NeuralBrainModel {
    /// The tones the nodes wear, for a test that sweeps them.
    func nodeDrawsForTest() -> [NeuralTone] {
        NeuralNodes.draws(model: self, time: 0, reduceMotion: false).compactMap { draw in
            switch draw.tone {
            case .danger: return .danger
            case .attention: return .attention
            case .live: return .live
            case .quiet: return .quiet
            case .zone: return nil
            }
        }
    }
}
