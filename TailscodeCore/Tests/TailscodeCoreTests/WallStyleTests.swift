import Foundation
import Testing

@testable import TailscodeCore

private func calendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
    return calendar
}

private func moment(hour: Int, minute: Int) -> Date {
    let parts = DateComponents(year: 2026, month: 10, day: 29, hour: hour, minute: minute)
    return calendar().date(from: parts) ?? .distantPast
}

@Suite struct WallStyleTests {
    @Test func studioIsTheDefaultSet() {
        let style = WallStyle.studio
        #expect(style.preset == .studio && style.effects == .subtle && style.field == .motes)
        #expect(style.light && style.dimAfter == 600 && style.night == .off)
        #expect(style.keepAwake == .whileCharging && !style.still && style.approvals == .hold)
        #expect(style.showsClock && style.showsHour && style.showsRails && style.showsSquads)
        #expect(style.moves == WallStyle.Moves())
        #expect(WallStyle.preset(.studio) == style)
        #expect(WallStyle.preset(.custom) == style)
    }

    @Test func nightDeskMovesOnlyEndingsAsksAndFailures() {
        let style = WallStyle.preset(.nightDesk)
        #expect(style.preset == .nightDesk && style.effects == .subtle && style.field == .none)
        #expect(!style.light && style.dimAfter == 300 && style.night == .scheduled)
        #expect(!style.showsRails && !style.showsSquads && style.showsClock && style.showsHour)
        #expect(style.keepAwake == .whileCharging && style.approvals == .hold)
        let moving = WallEvent.Kind.allCases.filter { style.moves($0) }
        #expect(
            Set(moving) == [.finished, .stopped, .asked, .answered, .failed])
    }

    @Test func showcaseIsLivelyAuroraAndNeverDims() {
        let style = WallStyle.preset(.showcase)
        #expect(style.preset == .showcase && style.effects == .lively && style.field == .aurora)
        #expect(style.light && style.dimAfter == nil && style.night == .off)
        #expect(WallEvent.Kind.allCases.allSatisfy { style.moves($0) })
    }

    @Test func dimChoicesAreFiveTenThirtyMinutesOrNever() {
        #expect(WallStyle.dimChoices == [300, 600, 1800, nil])
    }

    @Test func amplitudeFollowsEffects() {
        #expect(WallStyle.studio.with { $0.effects = .off }.amplitude == 0)
        #expect(WallStyle.studio.amplitude == 1)
        #expect(WallStyle.showcase.amplitude == 1.6)
    }

    @Test func everyKindMapsToItsSwitch() {
        let groups: [((inout WallStyle.Moves) -> Void, Set<WallEvent.Kind>)] = [
            ({ $0.steps = false }, [.step]),
            ({ $0.agents = false }, [.workerStarted, .workerEnded, .workerQuiet, .workerStuck]),
            ({ $0.endings = false }, [.finished, .stopped]),
            ({ $0.asks = false }, [.asked, .answered]),
            ({ $0.failures = false }, [.failed]),
            ({ $0.retries = false }, [.retried, .resumed, .quiet]),
            ({ $0.compaction = false }, [.compacted]),
            ({ $0.arrivals = false }, [.joined, .left, .away, .back]),
        ]
        #expect(groups.reduce(0) { $0 + $1.1.count } == WallEvent.Kind.allCases.count)
        for (turnOff, kinds) in groups {
            var moves = WallStyle.Moves()
            turnOff(&moves)
            let style = WallStyle.studio.with { $0.moves = moves }
            for kind in WallEvent.Kind.allCases {
                #expect(style.moves(kind) == !kinds.contains(kind))
            }
        }
    }

    @Test func scheduledNightRunsTenToSevenLocal() {
        let style = WallStyle.studio.with { $0.night = .scheduled }
        let cal = calendar()
        #expect(!style.isNight(at: moment(hour: 21, minute: 59), calendar: cal))
        #expect(style.isNight(at: moment(hour: 22, minute: 0), calendar: cal))
        #expect(style.isNight(at: moment(hour: 6, minute: 59), calendar: cal))
        #expect(!style.isNight(at: moment(hour: 7, minute: 0), calendar: cal))
        #expect(style.isNight(at: moment(hour: 0, minute: 0), calendar: cal))
        #expect(!style.isNight(at: moment(hour: 13, minute: 0), calendar: cal))
    }

    @Test func nightOffAndAlwaysIgnoreTheClock() {
        let cal = calendar()
        let noon = moment(hour: 12, minute: 0)
        let midnight = moment(hour: 0, minute: 0)
        let off = WallStyle.studio.with { $0.night = .off }
        let always = WallStyle.studio.with { $0.night = .always }
        #expect(!off.isNight(at: midnight, calendar: cal))
        #expect(always.isNight(at: noon, calendar: cal))
    }

    @Test func everyPresetRoundTripsThroughText() {
        for style in [WallStyle.studio, .nightDesk, .showcase] {
            #expect(WallStyle.decoded(style.encoded()) == style)
        }
        let custom = WallStyle.showcase.with {
            $0.field = .currents
            $0.dimAfter = 1800
            $0.keepAwake = .never
            $0.approvals = .openChat
            $0.moves.retries = false
        }
        #expect(WallStyle.decoded(custom.encoded()) == custom)
        #expect(custom.preset == .custom)
    }

    @Test func aStyleThatNeverDimsKeepsThatAcrossTheRoundTrip() {
        let decoded = WallStyle.decoded(WallStyle.showcase.encoded())
        #expect(decoded.dimAfter == nil)
    }

    @Test func nothingOrGarbageIsStudio() {
        #expect(WallStyle.decoded(nil) == .studio)
        #expect(WallStyle.decoded("") == .studio)
        #expect(WallStyle.decoded("not json") == .studio)
        #expect(WallStyle.decoded("[1,2]") == .studio)
    }

    @Test func decodingKeepsTheStudioValueForWhatIsMissingOrUnknown() {
        #expect(WallStyle.decoded("{}") == .studio)
        let partial = WallStyle.decoded(#"{"effects":"bogus","light":false}"#)
        #expect(partial == WallStyle.studio.with { $0.light = false }.withPreset(.studio))
        #expect(partial.effects == .subtle && !partial.light)
        let nested = WallStyle.decoded(#"{"moves":{"steps":false},"field":7,"dimAfter":"soon"}"#)
        #expect(!nested.moves.steps && nested.moves.agents)
        #expect(nested.field == .motes && nested.dimAfter == 600)
    }

    @Test func withMakesItCustomUnlessTheChangeChoseThePreset() {
        let tweaked = WallStyle.showcase.with { $0.effects = .subtle }
        #expect(tweaked.preset == .custom && tweaked.field == .aurora)
        let chosen = WallStyle.studio.with { $0 = .nightDesk }
        #expect(chosen == .nightDesk)
        let named = WallStyle.studio.with { $0.preset = .showcase }
        #expect(named.preset == .showcase)
        #expect(WallStyle.studio.with { _ in } == .studio)
    }
}

extension WallStyle {
    fileprivate func withPreset(_ preset: Preset) -> WallStyle {
        var copy = self
        copy.preset = preset
        return copy
    }
}
