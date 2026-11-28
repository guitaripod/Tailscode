import CodingAgentKit
import Foundation
import Testing

@testable import TailscodeCore

@Suite struct NeuralTimelineTests {
    private func steps(at offsets: [TimeInterval?], groups: [Int]? = nil) -> [NeuralStep] {
        offsets.enumerated().map { index, offset in
            NeuralStep(
                id: "m:\(index)", index: index, zone: .shell, group: groups?[index] ?? index,
                messageID: "m\(groups?[index] ?? index)",
                at: offset.map { ReadingFixtures.start.addingTimeInterval($0) }, title: "Bash")
        }
    }

    private func nineMinutes() -> [NeuralStep] {
        var offsets: [TimeInterval] = [0, 4, 9, 20, 150]
        while offsets.last! < 540 { offsets.append(offsets.last! + 15) }
        return steps(at: offsets)
    }

    @Test func aNineMinuteTurnReplaysInAboutTwelveSeconds() {
        let timeline = NeuralTimeline.make(steps: nineMinutes())
        #expect(timeline.isTimed)
        #expect(abs(timeline.duration - 12) < 1, "duration \(timeline.duration)")
    }

    @Test func aLongWaitBecomesOneBeat() {
        let timeline = NeuralTimeline.make(steps: nineMinutes())
        let wait = timeline.fireTimes[4] - timeline.fireTimes[3]
        #expect(abs(wait - NeuralTimeline.compressedGap) < 0.001, "wait \(wait)")
    }

    @Test func orderIsThatOfTheMessages() {
        let timeline = NeuralTimeline.make(steps: nineMinutes())
        for pair in zip(timeline.fireTimes, timeline.fireTimes.dropFirst()) {
            #expect(pair.0 < pair.1)
        }
        #expect(timeline.fireTimes.first == 0)
    }

    @Test func aBurstIsNeverFasterThanTheMinimumBeat() {
        let timeline = NeuralTimeline.make(steps: nineMinutes())
        for pair in zip(timeline.fireTimes, timeline.fireTimes.dropFirst()) {
            #expect(pair.1 - pair.0 >= NeuralTimeline.minimumGap - 0.0001)
        }
    }

    @Test func aTurnOfHundredsOfAnswersStillReplaysInTwelveSeconds() {
        let many = steps(at: (0..<378).map { _ in 0 })
        let timeline = NeuralTimeline.make(steps: many)
        #expect(abs(timeline.duration - 12) < 0.01, "duration \(timeline.duration)")
        for pair in zip(timeline.fireTimes, timeline.fireTimes.dropFirst()) { #expect(pair.0 < pair.1) }
    }

    @Test func fractionsRoundTrip() {
        let timeline = NeuralTimeline.make(steps: nineMinutes())
        for fraction in [0.0, 0.1, 0.25, 0.5, 0.9, 1.0] {
            let time = timeline.time(forFraction: fraction)
            #expect(abs(timeline.fraction(forTime: time) - fraction) < 1e-9)
        }
        #expect(timeline.fraction(forTime: -3) == 0)
        #expect(timeline.fraction(forTime: 10_000) == 1)
        #expect(timeline.time(forFraction: 2) == timeline.duration)
    }

    @Test func callsOfOneMessageFireTogetherInOrder() {
        let timeline = NeuralTimeline.make(
            steps: steps(at: [0, 30, 30, 30, 90], groups: [0, 1, 1, 1, 2]))
        let burst = Array(timeline.fireTimes[1...3])
        #expect(burst[0] < burst[1] && burst[1] < burst[2])
        #expect(burst[2] - burst[0] <= NeuralTimeline.staggerBudget + 0.0001)
        #expect(timeline.fireTimes[4] > burst[2])
    }

    @Test func theTargetSetsTheLength() {
        let timeline = NeuralTimeline.make(steps: nineMinutes(), target: 6)
        #expect(abs(timeline.duration - 6) < 1, "duration \(timeline.duration)")
    }

    @Test func aQuickTurnIsSlowedByNoMoreThanTheCap() {
        let timeline = NeuralTimeline.make(steps: steps(at: [0, 1, 2]))
        #expect(timeline.fireTimes[2] <= 2 * NeuralTimeline.maximumStretch + 0.0001)
        #expect(timeline.duration < NeuralTimeline.defaultTarget)
    }

    @Test func stepsWithoutTimesPlayAtTheFixedPace() {
        let timeline = NeuralTimeline.make(steps: steps(at: [nil, nil, nil, nil], groups: [0, 0, 1, 2]))
        #expect(!timeline.isTimed)
        #expect(timeline.fireTimes[2] == NeuralTimeline.fallbackGroupStep)
        #expect(timeline.fireTimes[3] == NeuralTimeline.fallbackGroupStep * 2)
        #expect(timeline.clockLabel(at: 1) == nil)
    }

    @Test func activeStepIsTheLatestThatHasFired() {
        let timeline = NeuralTimeline.make(steps: nineMinutes())
        #expect(timeline.activeStep(at: -1) == nil)
        #expect(timeline.activeStep(at: 0) == 0)
        #expect(timeline.activeStep(at: timeline.fireTimes[3] + 0.01) == 3)
        #expect(timeline.activeStep(at: timeline.duration) == timeline.fireTimes.count - 1)
        #expect(timeline.litCount(at: timeline.fireTimes[2]) == 3)
    }

    @Test func clockLabelIsTheMessagesOwnWallClock() {
        let timeline = NeuralTimeline.make(steps: nineMinutes())
        let label = timeline.clockLabel(at: timeline.fireTimes[1] + 0.01, timeZone: ReadingFixtures.utc)
        #expect(label == "14:02:15")
    }

    @Test func aTurnWithNoStepsIsEmptyAndSafe() {
        let timeline = NeuralTimeline.make(steps: [])
        #expect(timeline.duration == 0)
        #expect(timeline.activeStep(at: 1) == nil)
        #expect(timeline.fraction(forTime: 0) == 1)
        #expect(timeline.time(forFraction: 0.5) == 0)
    }

    @Test func someMissingTimesInheritTheLastKnownOne() {
        let timeline = NeuralTimeline.make(steps: steps(at: [0, nil, 40]))
        #expect(timeline.isTimed)
        #expect(timeline.fireTimes[1] > timeline.fireTimes[0])
        #expect(timeline.fireTimes[2] > timeline.fireTimes[1])
    }
}

@Suite("A turn a bridge hands over as one message") struct NeuralFoldedTurnTests {
    typealias NF = NeuralTurnFixtures

    private func folded() -> NeuralTurn {
        var parts: [MessagePart.Kind] = [
            .text("Looking at the tree first."), NF.bash("ls", out: ["a"]), NF.bash("pwd", out: ["b"]),
            .text("Now the long part of the work."),
        ]
        for index in 0..<10 { parts.append(NF.bash("step \(index)", out: ["ok"])) }
        parts.append(.text("All of it is done."))
        return NeuralTurns.partition(messages: [NF.user(0), NF.message(1, parts, model: "fable")], running: false)[0]
    }

    @Test func wordsBeginAGroupAndALongRunIsOneCallAfterAnother() {
        let groups = folded().steps.map(\.group)
        #expect(groups == [0, 0, 0, 1] + Array(2...11))
    }

    @Test func onlyCallsMadeTogetherShareABracket() {
        let list = NeuralStepList(steps: folded().steps)
        let brackets = list.rows(in: 0..<list.visibleCount).map(\.bracket)
        #expect(brackets[1] != .none && brackets[2] != .none)
        #expect(brackets[4...].allSatisfy { $0 == .none })
    }

    @Test func itsReplayIsSeen() {
        let timeline = NeuralTimeline.make(steps: folded().steps)
        #expect(timeline.duration > 2)
    }

    @Test func anAnswerThatIsOneMessageKeepsItsCallsTogether() {
        let parts: [MessagePart.Kind] = [.text("Reading both."), NF.read("a", out: ["1"]), NF.read("b", out: ["2"])]
        let turn = NeuralTurns.partition(
            messages: [NF.user(0), NF.message(1, parts, model: "fable"), NF.message(2, [.text("Read.")], model: "fable")],
            running: false)[0]
        #expect(Set(turn.steps.map(\.group)).count == 1)
    }
}
