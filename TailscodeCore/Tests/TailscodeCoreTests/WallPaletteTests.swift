import Foundation
import Testing

@testable import TailscodeCore

private let byte = 1.0 / 255

private func close(_ ink: WallInk, _ red: Double, _ green: Double, _ blue: Double) -> Bool {
    abs(ink.red - red) <= byte && abs(ink.green - green) <= byte && abs(ink.blue - blue) <= byte
}

private func channels(_ hex: String) -> (Double, Double, Double) {
    let value = Int(hex.dropFirst(), radix: 16) ?? 0
    return (Double((value >> 16) & 255) / 255, Double((value >> 8) & 255) / 255, Double(value & 255) / 255)
}

private func mix(_ a: (Double, Double, Double), _ b: (Double, Double, Double), _ t: Double) -> (Double, Double, Double) {
    (a.0 + (b.0 - a.0) * t, a.1 + (b.1 - a.1) * t, a.2 + (b.2 - a.2) * t)
}

private func lift(_ c: (Double, Double, Double), _ t: Double) -> (Double, Double, Double) { mix(c, (1, 1, 1), t) }

private func sink(_ c: (Double, Double, Double), _ t: Double) -> (Double, Double, Double) { mix(c, (0, 0, 0), t) }

@Suite struct WallPaletteTests {
    private let rose = WallPalette.current(theme: .rosePine)

    @Test func rosePineMatchesTheLinuxFormulas() {
        let canvas = channels("#191724")
        let expected: [(WallInk, (Double, Double, Double))] = [
            (rose.ground, sink(canvas, 0.12)),
            (rose.deep, sink(canvas, 0.62)),
            (rose.text, lift(channels("#e0def4"), 0.3)),
            (rose.dim, lift(channels("#908caa"), 0.12)),
            (rose.rule, channels("#26233a")),
            (rose.working, channels("#9ccfd8")),
            (rose.needs, channels("#f6c177")),
            (rose.failed, channels("#eb6f92")),
            (rose.finished, channels("#c4a7e7")),
            (rose.overdue, lift(mix(channels("#f6c177"), channels("#eb6f92"), 0.62), 0.08)),
            (rose.quiet, sink(mix(channels("#908caa"), channels("#c4a7e7"), 0.22), 0.12)),
        ]
        for (ink, want) in expected { #expect(close(ink, want.0, want.1, want.2)) }
    }

    @Test func thinkingIsVioletOnEveryTheme() {
        for theme in AppTheme.all {
            let palette = WallPalette.current(theme: theme)
            let special = WallInk(hex: theme.dark.special)
            let hue = special.hue
            if hue >= 215 && hue <= 320 {
                #expect(palette.thinking == special)
            } else {
                let info = WallInk(hex: theme.dark.info)
                let violet = WallInk(red: 0.68, green: 0.56, blue: 1).mixed(with: info, 0.12)
                #expect(palette.thinking == violet)
                #expect(palette.thinking.hue >= 215 && palette.thinking.hue <= 320)
            }
        }
    }

    @Test func theWallAlwaysWearsTheDarkSideOfATheme() {
        for theme in AppTheme.all {
            #expect(WallPalette.current(theme: theme) == WallPalette(palette: theme.dark))
        }
        #expect(WallPalette(palette: AppTheme.rosePine.light) != rose)
    }

    @Test func nightWarmsAndDimsEveryInk() {
        let night = rose.night()
        let warm = (1.0, 0.64, 0.4)
        let working = sink(mix(channels("#9ccfd8"), warm, 0.22), 0.2)
        #expect(close(night.working, working.0, working.1, working.2))
        let ground = sink(mix(sink(channels("#191724"), 0.12), warm, 0.06), 0.25)
        #expect(close(night.ground, ground.0, ground.1, ground.2))
        let deep = sink(mix(sink(channels("#191724"), 0.62), warm, 0.06), 0.25)
        #expect(close(night.deep, deep.0, deep.1, deep.2))
        func luminance(_ ink: WallInk) -> Double { 0.2126 * ink.red + 0.7152 * ink.green + 0.0722 * ink.blue }
        #expect(luminance(night.text) < luminance(rose.text))
        #expect(night.needs.red > night.needs.blue)
        #expect(night != rose && night.night() != night)
    }

    @Test func eachStateHasItsOwnInk() {
        let now = Date(timeIntervalSince1970: 0)
        func inkOf(_ state: WallState) -> WallInk { rose.ink(for: state) }
        #expect(inkOf(.working) == rose.working)
        #expect(inkOf(.thinking) == rose.thinking)
        #expect(inkOf(.needsYou(.fresh)) == rose.needs)
        #expect(inkOf(.needsYou(.waiting)) == rose.needs)
        #expect(inkOf(.needsYou(.overdue)) == rose.overdue)
        #expect(inkOf(.retrying(attempt: 2)) == rose.needs)
        #expect(inkOf(.quiet(since: now)) == rose.quiet)
        #expect(inkOf(.background(stuck: false)) == rose.working)
        #expect(inkOf(.background(stuck: true)) == rose.needs)
        #expect(inkOf(.finished(.done)) == rose.finished)
        #expect(inkOf(.finished(.failed)) == rose.failed)
        #expect(inkOf(.finished(.stopped)) == rose.dim)
        #expect(inkOf(.finished(.unknown)) == rose.dim)
        #expect(inkOf(.away(lastSeen: now)) == rose.dim)
    }

    @Test func aRoleNamesAnInkAndTileFollowsTheState() {
        #expect(rose.ink(.working, state: nil) == rose.working)
        #expect(rose.ink(.thinking, state: nil) == rose.thinking)
        #expect(rose.ink(.needs, state: nil) == rose.needs)
        #expect(rose.ink(.overdue, state: nil) == rose.overdue)
        #expect(rose.ink(.failed, state: nil) == rose.failed)
        #expect(rose.ink(.finished, state: nil) == rose.finished)
        #expect(rose.ink(.quiet, state: nil) == rose.quiet)
        #expect(rose.ink(.dim, state: nil) == rose.dim)
        #expect(rose.ink(.tile, state: nil) == rose.text)
        #expect(rose.ink(.tile, state: .finished(.failed)) == rose.failed)
    }

    @Test func aWorkerWearsItsOwnInk() {
        #expect(rose.ink(for: WorkerState.working) == rose.working)
        #expect(rose.ink(for: WorkerState.quiet(since: Date(timeIntervalSince1970: 0))) == rose.quiet)
        #expect(rose.ink(for: WorkerState.background(stuck: true)) == rose.needs)
        #expect(rose.ink(for: WorkerState.background(stuck: false)) == rose.working)
        #expect(rose.ink(for: WorkerState.finished) == rose.dim)
    }

    @Test func theMoodsInk() {
        #expect(rose.mood(.calm, hasFailure: false) == rose.text.mixed(with: rose.dim, 0.35))
        #expect(rose.mood(.busy, hasFailure: true) == rose.working)
        #expect(rose.mood(.attention, hasFailure: false) == rose.needs)
        #expect(rose.mood(.alarm, hasFailure: true) == rose.failed)
        #expect(rose.mood(.alarm, hasFailure: false) == rose.overdue)
    }

    @Test func inksMixLiftAndSink() {
        let ink = WallInk(red: 0.2, green: 0.4, blue: 0.6)
        #expect(ink.mixed(with: .white, 0) == ink)
        #expect(ink.lifted(1) == .white && ink.sunk(1) == .black)
        #expect(WallInk(hex: "#ff8000") == WallInk(red: 1, green: 128.0 / 255, blue: 0))
        #expect(WallInk(hex: "nonsense") == WallInk(red: 0.5, green: 0.5, blue: 0.5))
    }
}
