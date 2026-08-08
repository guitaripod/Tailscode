import Foundation
import Testing

@testable import TailscodeCore

@Suite struct TailnetRadarTests {
    @Test("A machine keeps its place, so a rescan does not shuffle the sky")
    func placesAreStable() {
        let first = TailnetRadar.angle(for: "macbook|claudeCode")
        let again = TailnetRadar.angle(for: "macbook|claudeCode")
        #expect(first == again)
        #expect(first >= 0 && first < 2 * Double.pi)
        let radius = TailnetRadar.radius(for: "macbook|claudeCode")
        #expect(radius >= TailnetRadar.innerRadius && radius <= TailnetRadar.outerRadius)
        #expect(TailnetRadar.angle(for: "arch|openCode") != first)
    }

    @Test("The sweep laps at one speed and crosses the seam without a step")
    func sweepWraps() {
        let start = TailnetRadar.frame(at: 0, blips: [], scanning: true)
        let lap = TailnetRadar.frame(at: TailnetRadar.sweepPeriod, blips: [], scanning: true)
        #expect(abs(start.sweep - lap.sweep) < 0.0001)
        let half = TailnetRadar.frame(at: TailnetRadar.sweepPeriod / 2, blips: [], scanning: true)
        #expect(abs(half.sweep - Double.pi) < 0.0001)
    }

    @Test("A blip is brightest as the arm crosses it and never goes dark behind it")
    func blipsLightUnderTheSweep() {
        let key = "macbook|claudeCode"
        let angle = TailnetRadar.angle(for: key)
        let blip = RadarBlip(key: key, tone: .ready, bornAt: -10)
        let under = TailnetRadar.frame(
            at: angle / (2 * Double.pi) * TailnetRadar.sweepPeriod, blips: [blip], scanning: true)
        let behind = TailnetRadar.frame(
            at: (angle / (2 * Double.pi) + 0.45) * TailnetRadar.sweepPeriod, blips: [blip],
            scanning: true)
        #expect(under.sparks[0].light > behind.sparks[0].light)
        #expect(behind.sparks[0].light >= TailnetRadar.rest - 0.0001)
        #expect(under.sparks[0].light <= 1)
    }

    @Test("A machine that just answered grows into its place rather than appearing")
    func newBlipsSettle() {
        let blip = RadarBlip(key: "arch|openCode", tone: .locked, bornAt: 100)
        let arriving = TailnetRadar.frame(at: 100, blips: [blip], scanning: true)
        let settled = TailnetRadar.frame(
            at: 100 + TailnetRadar.entry, blips: [blip], scanning: true)
        #expect(arriving.sparks[0].light == 0)
        #expect(abs(settled.sparks[0].scale - 1) < 0.0001)
        #expect(settled.sparks[0].tone == .locked)
    }

    @Test("A finished scan and a desk that wants no motion both draw a still dial")
    func stillnessIsSettled() {
        let blip = RadarBlip(key: "arch|openCode", tone: .ready, bornAt: 0)
        let done = TailnetRadar.frame(at: 12, blips: [blip], scanning: false)
        #expect(done.settled)
        #expect(done.sweepLight == 0)
        #expect(done.pingLight == 0)
        #expect(done.sparks[0].light == 1)
        let calm = TailnetRadar.frame(at: 12, blips: [blip], scanning: true, reducedMotion: true)
        #expect(calm.settled)
        #expect(calm.sparks[0].light == 1)
    }

    @Test("A running scan is never settled, so the clock keeps its frames")
    func scanningKeepsMoving() {
        let frame = TailnetRadar.frame(at: 3, blips: [], scanning: true)
        #expect(!frame.settled)
        #expect(frame.sweepLight == 1)
        #expect(frame.ping >= 0 && frame.ping <= 1)
    }
}
