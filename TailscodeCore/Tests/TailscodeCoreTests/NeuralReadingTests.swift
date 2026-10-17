import Foundation
import Testing

@testable import TailscodeCore

enum ReadingFixtures {
    static let start = ISO8601DateFormatter().date(from: "2026-10-17T14:02:11Z")!
    static let utc = TimeZone(identifier: "UTC")!

    static func step(
        _ index: Int, _ zone: NeuralZone, _ title: String, group: Int? = nil,
        status: NeuralStatus = .ok, detail: String = "", text: String = "", added: Int? = nil,
        removed: Int? = nil, tieKey: String? = nil, tieIsCommand: Bool = false,
        recovered: Bool = false, at seconds: TimeInterval? = nil
    ) -> NeuralStep {
        NeuralStep(
            id: "m\(group ?? index):p\(index)", index: index, zone: zone, status: status,
            group: group ?? index, messageID: "m\(group ?? index)",
            at: start.addingTimeInterval(seconds ?? Double(index) * 10),
            title: title, detail: detail, text: text, added: added, removed: removed, tieKey: tieKey,
            tieIsCommand: tieIsCommand, recovered: recovered)
    }

    /// A turn of 29 steps: 25 tools (18 commands, one failed and passed on retry; 3 reads in one
    /// message; 4 edits over 2 files, 5 lines added and 2 removed), 2 thoughts and 2 notes.
    static func buildFix(outcome: NeuralOutcome = .settled) -> NeuralTurn {
        var steps: [NeuralStep] = [step(0, .think, "Thinking", text: "Look at every switch first.")]
        for index in 1...3 {
            steps.append(step(index, .sense, "Read", group: 1, detail: "File\(index).swift", tieKey: "File\(index).swift"))
        }
        steps.append(step(4, .act, "Edit", detail: "A.swift", added: 3, removed: 1, tieKey: "A.swift"))
        steps.append(step(5, .act, "Edit", detail: "A.swift", added: 1, removed: 1, tieKey: "A.swift"))
        steps.append(step(6, .act, "Edit", detail: "B.swift", added: 1, removed: 0, tieKey: "B.swift"))
        steps.append(step(7, .act, "Edit", detail: "B.swift", tieKey: "B.swift"))
        for index in 8...25 {
            let failing = index == 9
            let build = index == 9 || index == 10
            steps.append(
                step(
                    index, .shell, "Bash", status: failing ? .failed : .ok,
                    detail: build ? "swift build" : "ls \(index)", tieKey: build ? "swift build" : nil,
                    tieIsCommand: build, recovered: failing))
        }
        steps.append(step(26, .say, "Said", text: "Fixed the first one."))
        steps.append(step(27, .think, "Thinking", text: "Check the Mac manifest too."))
        steps.append(step(28, .say, "Said", text: "Both answer now."))
        return NeuralTurn(
            id: "m0", steps: steps, outcome: outcome, startedAt: start,
            endedAt: outcome == .running ? nil : start.addingTimeInterval(505))
    }
}

@Suite struct NeuralReadingTests {
    @Test func lineCountsMixDurationAndTally() {
        let line = NeuralReading.line(for: ReadingFixtures.buildFix())
        #expect(line.tools == 25)
        #expect(line.count == "25 tools")
        #expect(line.toolMix == "Read×3 Edit×4 Bash×18")
        #expect(line.duration == "8m 25s")
        #expect(line.thoughts == "2 thoughts")
        #expect(line.notes == "2 notes")
        #expect(line.tally == "+5 −2")
        #expect(line.failure == "1 failed, then passed")
        #expect(line.detail == "8m 25s · 2 thoughts · 2 notes · 1 failed, then passed")
    }

    @Test func aFailureNobodyRetriedIsJustFailed() {
        var turn = ReadingFixtures.buildFix()
        turn.steps[9].recovered = false
        #expect(NeuralReading.line(for: turn).failure == "failed")
    }

    @Test func oneToolHasNoPluralAndNoTally() {
        let turn = NeuralTurn(
            id: "m", steps: [ReadingFixtures.step(0, .sense, "Read", detail: "a")], startedAt: nil,
            endedAt: nil)
        let line = NeuralReading.line(for: turn)
        #expect(line.count == "1 tool")
        #expect(line.tally == nil)
        #expect(line.duration == nil)
        #expect(line.thoughts == nil && line.notes == nil && line.failure == nil)
        #expect(line.toolMix == "Read")
    }

    @Test func aTurnOfOnlyWordsCountsSteps() {
        let turn = NeuralTurn(
            id: "m",
            steps: [
                ReadingFixtures.step(0, .think, "Thinking", text: "a"),
                ReadingFixtures.step(1, .think, "Thinking", text: "b"),
            ])
        #expect(NeuralReading.line(for: turn).count == "2 steps")
        #expect(NeuralReading.line(for: NeuralTurn(id: "m")).count == "No steps")
    }

    @Test func aRunningTurnIsTimedAgainstNow() {
        var turn = ReadingFixtures.buildFix(outcome: .running)
        turn.endedAt = nil
        let now = ReadingFixtures.start.addingTimeInterval(65)
        #expect(NeuralReading.line(for: turn, now: now).duration == "1m 5s")
    }

    @Test func stepTimesStandInWhenTheTurnHasNoClock() {
        var turn = ReadingFixtures.buildFix()
        turn.startedAt = nil
        turn.endedAt = nil
        #expect(NeuralReading.line(for: turn).duration == "4m 40s")
    }

    @Test func tallyIsOnlyForWhatWasWritten() {
        #expect(NeuralReading.tally(0, 0) == nil)
        #expect(NeuralReading.tally(5, 0) == "+5 −0")
    }

    @Test func spokenSentenceCountsWhatHappened() {
        #expect(
            NeuralReading.spoken(ReadingFixtures.buildFix())
                == "25 tools in 8 minutes 25 seconds. Ran 18 commands, one failed and then passed. Read 3 files. Edited 2 files, 5 lines added and 2 removed."
        )
    }

    @Test func spokenNamesAnEndingTheTranscriptCannotHide() {
        let stopped = NeuralReading.spoken(ReadingFixtures.buildFix(outcome: .stopped))
        #expect(stopped.hasSuffix("You stopped it."))
        let failed = NeuralReading.spoken(ReadingFixtures.buildFix(outcome: .failed))
        #expect(failed.hasSuffix("It ended with an error."))
    }

    @Test func noticeSentenceIsTheLongLooksOwn() {
        #expect(
            NeuralReading.notice(for: ReadingFixtures.buildFix())
                == "25 tools in 8m 25s: ran 18 commands, read 3 files, edited 2 files (+5 −2)")
    }

    @Test func noticeOfATurnWithNothingToCountIsJustTheHead() {
        let turn = NeuralTurn(id: "m", steps: [ReadingFixtures.step(0, .think, "Thinking", text: "a")])
        #expect(NeuralReading.notice(for: turn) == "1 step")
    }

    @Test func durationsRead() {
        #expect(NeuralReading.duration(42) == "42s")
        #expect(NeuralReading.duration(505) == "8m 25s")
        #expect(NeuralReading.duration(3_900) == "1h 5m")
        #expect(NeuralReading.spokenDuration(61) == "1 minute 1 second")
        #expect(NeuralReading.spokenDuration(3_725) == "1 hour 2 minutes 5 seconds")
        #expect(NeuralReading.spokenDuration(0) == "0 seconds")
    }

    @Test func cardCarriesPlaceMessageClockAndTie() {
        let turn = ReadingFixtures.buildFix()
        let edit = NeuralReading.card(for: turn.steps[4], in: turn.steps, timeZone: ReadingFixtures.utc)
        #expect(edit.title == "Edit")
        #expect(edit.statusWord == "done")
        #expect(edit.body == "A.swift")
        #expect(edit.tally == "+3 −1")
        #expect(edit.footer == "step 5 of 29 · message 3 · 14:02:51 · same file as 6")
    }

    @Test func cardNamesCallsMadeTogetherAndASharedCommand() {
        let turn = ReadingFixtures.buildFix()
        let read = NeuralReading.card(for: turn.steps[2], in: turn.steps, timeZone: ReadingFixtures.utc)
        #expect(read.facts.first == "3 calls in one message")
        let build = NeuralReading.card(for: turn.steps[9], in: turn.steps, timeZone: ReadingFixtures.utc)
        #expect(build.statusWord == "failed")
        #expect(build.facts.last == "same command as 11")
    }

    @Test func cardOfAThoughtShowsItsWords() {
        let turn = ReadingFixtures.buildFix()
        let card = NeuralReading.card(for: turn.steps[0], in: turn.steps, timeZone: ReadingFixtures.utc)
        #expect(card.body == "Look at every switch first.")
        #expect(card.tally == nil)
    }

    @Test func everyStatusHasItsWord() {
        let words = [
            NeuralStatus.ok: "done", .failed: "failed", .running: "running", .stopped: "stopped",
            .waitingApproval: "waiting for you", .waitingAnswer: "waiting for you",
            .stalled: "stalled",
        ]
        for (status, word) in words { #expect(NeuralReading.statusWord(status) == word) }
    }

    @Test func ganglionSaysHowManyGatheredAndWhy() {
        let turn = ReadingFixtures.buildFix()
        let members = Array(turn.steps[8...12])
        let card = NeuralReading.ganglion(zone: .shell, members: members)
        #expect(card.title == "SHELL ganglion")
        #expect(card.statusWord == "5 steps gathered here")
        #expect(card.status == .ok)
        #expect(card.facts.first == "steps 9 to 13")
        #expect(card.body == "Bash×5")
    }

    @Test func announcementIsStepOfTotalThenWhatItIs() {
        let turn = ReadingFixtures.buildFix()
        #expect(
            NeuralReading.announcement(for: turn.steps[9], of: turn.steps.count)
                == "Step 10 of 29, Bash, failed, swift build")
        #expect(
            NeuralReading.announcement(for: turn.steps[27], of: turn.steps.count)
                == "Step 28 of 29, Thinking, done, Check the Mac manifest too.")
    }

    @Test func labelsAreTheMocksOwn() {
        #expect(NeuralReading.replayLabel == "Replay")
        #expect(NeuralReading.rowsLabel == "Rows")
        #expect(NeuralReading.noNotification == "No notification while it works")
        #expect(NeuralZone.allCases.map(\.label) == ["PLAN", "SENSE", "ACT", "SHELL", "DELEGATE", "SAY"])
    }
}
