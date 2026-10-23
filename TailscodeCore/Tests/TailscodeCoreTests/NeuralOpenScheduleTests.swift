import Foundation
import Testing

@testable import TailscodeCore

@Suite("Neural open schedule")
struct NeuralOpenScheduleTests {
    @Test("the press builds nothing and each frame builds the next part, in the order they are needed")
    func oneToAFrame() {
        var schedule = NeuralOpenSchedule()
        #expect(schedule.due(frame: 1, progress: 0.02).isEmpty)
        #expect(schedule.due(frame: 2, progress: 0.05) == [.head])
        #expect(schedule.due(frame: 3, progress: 0.08) == [.steps])
        #expect(schedule.due(frame: 4, progress: 0.10) == [.nodes])
        #expect(schedule.due(frame: 5, progress: 0.12) == [.account])
        #expect(schedule.due(frame: 6, progress: 0.14) == [.story])
        #expect(schedule.due(frame: 7, progress: 0.16) == [.footer])
        #expect(schedule.isComplete)
        #expect(schedule.due(frame: 8, progress: 0.18).isEmpty)
    }

    @Test("a frame that did not come builds one part, not the ones it missed, while there is time")
    func slowClockStillOneAtATime() {
        var schedule = NeuralOpenSchedule()
        #expect(schedule.due(frame: 2, progress: 0.0) == [.head])
        #expect(schedule.due(frame: 5, progress: 0.05) == [.steps])
        #expect(schedule.due(frame: 6, progress: 0.06) == [.nodes])
    }

    @Test("a part about to show is built on the frame that reaches it, with whatever was owed before it")
    func deadlineCatchesUp() {
        var schedule = NeuralOpenSchedule()
        #expect(schedule.due(frame: 2, progress: 0.0) == [.head])
        let owed = schedule.due(frame: 3, progress: 0.9)
        #expect(owed == [.steps, .nodes, .account, .story, .footer])
        #expect(schedule.isComplete)
    }

    @Test("a part is built before the instant it starts to show")
    func buildsBeforeItShows() {
        var schedule = NeuralOpenSchedule()
        _ = schedule.due(frame: 2, progress: 0)
        let early = NeuralOpenPart.steps.showsAt - NeuralOpenSchedule.lead - 0.001
        #expect(schedule.due(frame: 1, progress: early).isEmpty)
        let reached = NeuralOpenPart.steps.showsAt - NeuralOpenSchedule.lead + 1e-9
        #expect(schedule.due(frame: 1, progress: reached) == [.steps])
    }

    @Test("remaining hands over every part not built and completes the schedule")
    func remainingFinishes() {
        var schedule = NeuralOpenSchedule()
        _ = schedule.due(frame: 2, progress: 0)
        #expect(schedule.remaining() == [.steps, .nodes, .account, .story, .footer])
        #expect(schedule.isComplete)
        #expect(schedule.remaining().isEmpty)
    }

    @Test("every part shows after the move begins and in the order they are built")
    func orderMatchesTransition() {
        let shows = NeuralOpenPart.allCases.map(\.showsAt)
        #expect(shows == shows.sorted())
        #expect(shows.allSatisfy { $0 > 0 && $0 < 1 })
    }
}
