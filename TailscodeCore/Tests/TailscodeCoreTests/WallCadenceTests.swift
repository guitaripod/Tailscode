import Testing

@testable import TailscodeCore

private func cap(
    live: Bool = false, breathing: Bool = false, dimmed: Bool = false, hidden: Bool = false,
    lowPower: Bool = false, thermal: WallCadence.Thermal = .nominal, proMotion: Bool = false
) -> Int {
    WallCadence.cap(
        effectsLive: live, breathing: breathing, dimmedCalm: dimmed, hidden: hidden,
        lowPower: lowPower, thermal: thermal, proMotion: proMotion)
}

@Suite struct WallCadenceTests {
    @Test func hiddenAndCriticalDrawNothing() {
        #expect(cap(live: true, hidden: true, proMotion: true) == 0)
        #expect(cap(live: true, thermal: .critical) == 0)
        #expect(cap(thermal: .critical) == 0)
    }

    @Test func anEventPlaysAtSixtyOnProMotionAndThirtyElsewhere() {
        #expect(cap(live: true, proMotion: true) == 60)
        #expect(cap(live: true) == 30)
        #expect(cap(live: true, breathing: true, proMotion: true) == 60)
    }

    @Test func breathingRunsAtThirtyAndRestAtOne() {
        #expect(cap(breathing: true, proMotion: true) == 30)
        #expect(cap() == 1)
    }

    @Test func aDimmedCalmWallRunsAtOneUnlessAnEventPlays() {
        #expect(cap(breathing: true, dimmed: true) == 1)
        #expect(cap(dimmed: true) == 1)
        #expect(cap(live: true, dimmed: true, proMotion: true) == 60)
    }

    @Test func seriousThermalCapsAtFifteen() {
        #expect(cap(live: true, thermal: .serious, proMotion: true) == 15)
        #expect(cap(breathing: true, thermal: .serious) == 15)
        #expect(cap(thermal: .serious) == 1)
        #expect(cap(live: true, dimmed: true, thermal: .serious) == 15)
        #expect(cap(live: true, thermal: .fair, proMotion: true) == 60)
    }

    @Test func aSmoothWallRunsAtItsDisplaysRateWhileAnythingMoves() {
        func smooth(_ live: Bool, _ breathing: Bool, strained: Bool = false, lowPower: Bool = false, dimmed: Bool = false) -> Int {
            WallCadence.cap(
                effectsLive: live, breathing: breathing, dimmedCalm: dimmed, hidden: false, lowPower: lowPower,
                thermal: .nominal, proMotion: false, smooth: 72, strained: strained)
        }
        #expect(smooth(false, true) == 72)
        #expect(smooth(true, false) == 72)
        #expect(smooth(false, false) == 1)
        #expect(smooth(false, true, strained: true) == 30)
        #expect(smooth(false, true, lowPower: true) == 20)
        #expect(smooth(false, true, dimmed: true) == 1)
        #expect(smooth(true, false, dimmed: true) == 72)
    }

    @Test func aDisplayIsDividedIntoEvenFramesOfAtLeastFifty() {
        #expect(WallCadence.stride(refreshHz: 60) == 1)
        #expect(WallCadence.stride(refreshHz: 90) == 1)
        #expect(WallCadence.stride(refreshHz: 100) == 1)
        #expect(WallCadence.stride(refreshHz: 120) == 2)
        #expect(WallCadence.stride(refreshHz: 144) == 2)
        #expect(WallCadence.stride(refreshHz: 165) == 2)
        #expect(WallCadence.stride(refreshHz: 240) == 3)
        #expect(WallCadence.stride(refreshHz: 0) == 1)
        #expect(WallCadence.smoothRate(refreshHz: 144) == 72)
        #expect(WallCadence.smoothRate(refreshHz: 165) == 83)
        #expect(WallCadence.smoothRate(refreshHz: 59.94) == 60)
        #expect(WallCadence.smoothRate(refreshHz: 240) == 80)
        #expect(WallCadence.smoothRate(refreshHz: .nan) == 60)
        for hz in stride(from: 50.0, through: 500, by: 7.5) {
            let rate = WallCadence.smoothRate(refreshHz: hz)
            #expect(rate >= 50 && rate <= 100, "\(hz) Hz gives \(rate)")
        }
    }

    @Test func lowPowerCapsAtTwenty() {
        #expect(cap(live: true, lowPower: true, proMotion: true) == 20)
        #expect(cap(breathing: true, lowPower: true) == 20)
        #expect(cap(lowPower: true) == 1)
        #expect(cap(live: true, lowPower: true, thermal: .serious) == 15)
    }

    @Test func theFieldStopsInLowPowerUnderThermalPressureWhenStillOrWithNoField() {
        let studio = WallStyle.studio
        #expect(WallCadence.fieldRuns(lowPower: false, thermal: .nominal, style: studio))
        #expect(WallCadence.fieldRuns(lowPower: false, thermal: .fair, style: studio))
        #expect(!WallCadence.fieldRuns(lowPower: true, thermal: .nominal, style: studio))
        #expect(!WallCadence.fieldRuns(lowPower: false, thermal: .serious, style: studio))
        #expect(!WallCadence.fieldRuns(lowPower: false, thermal: .critical, style: studio))
        #expect(!WallCadence.fieldRuns(lowPower: false, thermal: .nominal, style: studio.with { $0.still = true }))
        #expect(!WallCadence.fieldRuns(lowPower: false, thermal: .nominal, style: .nightDesk))
    }
}
