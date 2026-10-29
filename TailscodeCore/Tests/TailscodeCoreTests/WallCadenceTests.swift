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
