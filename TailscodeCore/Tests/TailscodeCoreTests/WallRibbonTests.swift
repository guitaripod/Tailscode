import Foundation
import Testing

@testable import TailscodeCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func at(_ minutesAgo: Double) -> Date { now.addingTimeInterval(-minutesAgo * 60) }

private func hour() -> AgentHour {
    func lane(_ id: String, parent: String?, spans: [AgentHourSpan], marks: [AgentHourMark] = []) -> AgentHourLane {
        AgentHourLane(
            id: id, parentID: parent, profileID: "p", sessionID: id, title: id, machine: "studio", spans: spans,
            marks: marks)
    }
    return AgentHour(
        start: at(60), end: now,
        lanes: [
            lane(
                "a", parent: nil,
                spans: [
                    AgentHourSpan(start: at(60), end: at(45), phase: .working),
                    AgentHourSpan(start: at(45), end: at(30), phase: .needsYou),
                    AgentHourSpan(start: at(20), end: now, phase: .background),
                ], marks: [AgentHourMark(at: at(15), outcome: .failed), AgentHourMark(at: now, outcome: .done)]),
            lane(
                "child", parent: "a", spans: [AgentHourSpan(start: at(50), end: at(40), phase: .working)],
                marks: [AgentHourMark(at: at(40), outcome: .done)]),
        ],
        unseen: [DateInterval(start: at(30), end: at(20)), DateInterval(start: at(70), end: at(65))])
}

@Suite struct WallRibbonTests {
    @Test func positionsAreFractionsOfTheLastHourWithNowAtOne() {
        let ribbon = WallRibbon.read(hour(), now: now)
        #expect(ribbon.spans.count == 3)
        #expect(ribbon.spans[0].from == 0 && abs(ribbon.spans[0].to - 0.25) < 1e-9 && ribbon.spans[0].phase == .working)
        #expect(abs(ribbon.spans[1].from - 0.25) < 1e-9 && abs(ribbon.spans[1].to - 0.5) < 1e-9)
        #expect(ribbon.spans[1].phase == .needsYou)
        #expect(abs(ribbon.spans[2].from - 2.0 / 3) < 1e-9 && ribbon.spans[2].to == 1)
        #expect(ribbon.spans[2].phase == .background)
    }

    @Test func onlyTopLevelLanesCount() {
        let ribbon = WallRibbon.read(hour(), now: now)
        #expect(ribbon.marks.count == 2)
        #expect(ribbon.spans.allSatisfy { $0.from != 10.0 / 60 })
    }

    @Test func marksCarryTheirOutcomeAndPlace() {
        let ribbon = WallRibbon.read(hour(), now: now)
        #expect(abs(ribbon.marks[0].at - 0.75) < 1e-9 && ribbon.marks[0].outcome == .failed)
        #expect(ribbon.marks[1].at == 1 && ribbon.marks[1].outcome == .done)
    }

    @Test func theBlindStretchesAreHatchedAndClampedToTheHour() {
        let ribbon = WallRibbon.read(hour(), now: now)
        #expect(ribbon.unseen.count == 1)
        #expect(abs(ribbon.unseen[0].lowerBound - 0.5) < 1e-9 && abs(ribbon.unseen[0].upperBound - 2.0 / 3) < 1e-9)
    }

    @Test func noHourIsAnEmptyRibbon() {
        #expect(WallRibbon.read(nil, now: now) == .empty)
        #expect(WallRibbon.empty.spans.isEmpty && WallRibbon.empty.marks.isEmpty && WallRibbon.empty.unseen.isEmpty)
    }

    @Test func theTrackSitsUnderTheCaptionAndIsTallerWhenCalm() {
        let rect = WallRect(x: 10, y: 100, width: 800, height: 95)
        let busy = WallRibbon.track(in: rect, unit: 10.8, calm: false)
        let calm = WallRibbon.track(in: rect, unit: 10.8, calm: true)
        #expect(busy.x == 10 && busy.width == 800 && busy.y > rect.y)
        #expect(calm.height > busy.height && calm.y == busy.y)
        #expect(abs(busy.height - 2 * 10.8) < 1e-9)
    }
}
