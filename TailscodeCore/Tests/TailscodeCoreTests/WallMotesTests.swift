import Foundation
import Testing

@testable import TailscodeCore

@Suite struct WallMotesTests {
    @Test(arguments: [
        (100.0, 100.0, 18), (320.0, 240.0, 18), (1376.0, 1032.0, 96), (1920.0, 1080.0, 96),
        (951.0, 669.0, 58), (669.0, 951.0, 58), (760.0, 560.0, 39),
    ])
    func theCountFollowsTheAreaWithinBounds(width: Double, height: Double, count: Int) {
        #expect(WallMotes.count(width: width, height: height) == count)
        let motes = WallMotes(width: width, height: height, seed: 7)
        #expect(motes.count == count && motes.x.count == count && motes.y.count == count)
        #expect(motes.trailX.count == count * WallMotes.trailLength)
        #expect(WallMotes.count(width: 0, height: 0) == WallMotes.fewest)
        #expect(WallMotes.count(width: 100_000, height: 100_000) == WallMotes.most)
    }

    @Test func theSameSeedMovesTheSameWay() {
        var a = WallMotes(width: 951, height: 669, seed: 99_173)
        var b = WallMotes(width: 951, height: 669, seed: 99_173)
        let c = WallMotes(width: 951, height: 669, seed: 5)
        #expect(a.x == b.x && a.y == b.y && a.x != c.x)
        for _ in 0..<500 {
            a.step(dt: 1 / 30, mood: .busy, target: nil, slow: 1, aspect: 1.42)
            b.step(dt: 1 / 30, mood: .busy, target: nil, slow: 1, aspect: 1.42)
        }
        #expect(a.x == b.x && a.y == b.y && a.trailX == b.trailX)
    }

    @Test(arguments: [WallMood.calm, .busy, .attention, .alarm])
    func theyStayOnTheScreenForEverAndNeverBecomeNumbers(mood: WallMood) {
        var motes = WallMotes(width: 1376, height: 1032, seed: 3)
        for step in 0..<10_000 {
            let target: (x: Double, y: Double)? = step % 2 == 0 ? (0.5, 0.4) : nil
            motes.step(dt: 1 / 30, mood: mood, target: target, slow: 1, aspect: 1376.0 / 1032)
        }
        for index in 0..<motes.count {
            #expect(motes.x[index] >= -0.02 - 1e-9 && motes.x[index] <= 1.02 + 1e-9)
            #expect(motes.y[index] >= -0.02 - 1e-9 && motes.y[index] <= 1.02 + 1e-9)
            #expect(motes.size[index] >= 0.18 && motes.size[index] < 0.5)
        }
        #expect(motes.x.allSatisfy(\.isFinite) && motes.y.allSatisfy(\.isFinite))
        #expect(motes.trailX.allSatisfy(\.isFinite) && motes.positionSum.isFinite)
    }

    @Test func aBusyFieldDriftsFasterThanACalmOneAndSlowHoldsItStill() {
        func travelled(_ mood: WallMood, slow: Double) -> Double {
            var motes = WallMotes(width: 951, height: 669, seed: 11)
            let before = motes.x
            for _ in 0..<30 { motes.step(dt: 1 / 30, mood: mood, target: nil, slow: slow, aspect: 1.42) }
            return zip(before, motes.x).reduce(0) { $0 + abs($1.0 - $1.1) }
        }
        #expect(travelled(.busy, slow: 1) > travelled(.calm, slow: 1) * 3)
        #expect(travelled(.busy, slow: 0) == 0)
        #expect(WallMotes.speed(.attention) > WallMotes.speed(.busy) && WallMotes.speed(.alarm) < WallMotes.speed(.busy))
    }

    @Test func anAskDrawsTheFieldTowardIt() {
        var motes = WallMotes(width: 951, height: 669, seed: 21)
        func spread() -> Double {
            (0..<motes.count).reduce(0) { $0 + hypot(motes.x[$1] - 0.8, motes.y[$1] - 0.2) } / Double(motes.count)
        }
        let before = spread()
        for _ in 0..<600 {
            motes.step(dt: 1 / 30, mood: .attention, target: (0.8, 0.2), slow: 1, aspect: 1.42)
        }
        #expect(spread() < before)
    }

    @Test func eachMoteKeepsFourPastPositions() {
        var motes = WallMotes(width: 951, height: 669, seed: 4)
        for _ in 0..<5 { motes.step(dt: 0.1, mood: .busy, target: nil, slow: 1, aspect: 1.42) }
        let base = 2 * WallMotes.trailLength
        #expect(motes.trailX[base] != motes.x[2] || motes.trailY[base] != motes.y[2])
        #expect(motes.trailX[base + 1] != motes.trailX[base] || motes.trailY[base + 1] != motes.trailY[base])
    }
}
