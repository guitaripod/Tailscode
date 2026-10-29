import Foundation
import Testing

@testable import TailscodeCore

private let kinds: [WallEffect.Kind] = [
    .spark, .thread, .dissolve, .exhale, .groundRipple, .knock, .fracture, .pulse, .approved, .drain,
    .gather, .scatter, .fade,
]

private let tile = WallRect(x: 100, y: 80, width: 420, height: 300)

private let anchor: WallAnchor = {
    let metrics = WallTileMetrics.tile(tile, unit: 7.2)
    return WallAnchor(
        tile: tile, glyphX: metrics.glyphX, glyphY: metrics.glyphY, glyphSize: metrics.glyphSize,
        worker: WallRect(x: 340, y: 200, width: 160, height: 80), beat: metrics.beat, width: 951, height: 669)
}()

private func effect(
    _ kind: WallEffect.Kind, seed: UInt32 = 1234, amplitude: Double = 1, ink: WallEffect.Ink = .working
) -> WallEffect {
    WallEffect(
        kind: kind, tile: "a", worker: "a#w", start: 10, duration: 2, ink: ink, amplitude: amplitude, seed: seed,
        from: 0.8, to: 0.2)
}

private func shapes(_ kind: WallEffect.Kind, p: Double, seed: UInt32 = 1234, amplitude: Double = 1, anchor: WallAnchor = anchor) -> [WallShape] {
    WallEffectShapes.shapes(for: effect(kind, seed: seed, amplitude: amplitude), at: 10 + 2 * p, anchor: anchor, unit: 7.2)
}

private func alphas(_ shapes: [WallShape]) -> [Double] {
    shapes.map {
        switch $0 {
        case .ring(_, _, _, _, let alpha), .bloom(_, _, _, let alpha), .dot(_, _, _, let alpha),
            .ripple(_, _, _, _, let alpha):
            return alpha
        }
    }
}

private func points(_ shapes: [WallShape]) -> [(Double, Double)] {
    shapes.compactMap {
        switch $0 {
        case .ring(let x, let y, _, _, _), .bloom(let x, let y, _, _), .dot(let x, let y, _, _): return (x, y)
        case .ripple: return nil
        }
    }
}

@Suite struct WallEffectShapesTests {
    @Test(arguments: kinds) func everyKindDrawsSensiblyInsideTheWallWhileItPlays(_ kind: WallEffect.Kind) {
        for p in [0.1, 0.5, 0.9] {
            let made = shapes(kind, p: p)
            for alpha in alphas(made) { #expect(alpha >= 0 && alpha <= 1 && alpha.isFinite, "\(kind) \(p)") }
            for (x, y) in points(made) {
                #expect(x >= -50 && x <= 951 + 50 && y >= -50 && y <= 669 + 50, "\(kind) \(p): \(x) \(y)")
            }
            for shape in made {
                switch shape {
                case .ring(_, _, let radius, let width, _):
                    #expect(radius > 0 && radius < 2000 && width > 0 && width < 200)
                case .bloom(_, _, let radius, _): #expect(radius > 0 && radius < 2000)
                case .dot(_, _, let size, _): #expect(size > 0 && size < 100)
                case .ripple(let rect, let corner, let grow, let width, _):
                    #expect(rect == tile && corner > 0 && grow >= 0 && grow < 400 && width > 0 && width < 100)
                }
            }
            #expect(!made.isEmpty, "\(kind) at \(p) drew nothing")
        }
    }

    @Test(arguments: kinds) func nothingDrawsBeforeOrAfterAnEffect(_ kind: WallEffect.Kind) {
        let effect = effect(kind)
        for t in [9.99, 12, 12.0001, 20] {
            #expect(WallEffectShapes.shapes(for: effect, at: t, anchor: anchor, unit: 7.2).isEmpty)
        }
    }

    @Test(arguments: kinds) func theSameSeedDrawsTheSameAndAnotherSeedScattersDifferently(_ kind: WallEffect.Kind) {
        #expect(shapes(kind, p: 0.4, seed: 9) == shapes(kind, p: 0.4, seed: 9))
        let scattered: Set<WallEffect.Kind> = [.dissolve, .fracture, .drain, .gather, .scatter]
        if scattered.contains(kind) { #expect(shapes(kind, p: 0.4, seed: 9) != shapes(kind, p: 0.4, seed: 10)) }
    }

    @Test func aSparkRunsIntoTheHeartbeatsNowEdge() throws {
        let beat = anchor.beat
        guard case .dot(let x, let y, _, _) = try #require(shapes(.spark, p: 0.5).first) else { return }
        #expect(x > beat.x + beat.width * 0.9 && x <= beat.maxX && abs(y - (beat.maxY - 2)) < 0.001)
        guard case .dot(let late, _, _, _) = try #require(shapes(.spark, p: 0.99).first) else { return }
        #expect(late > x - 0.001 && late <= beat.maxX + 0.001)
    }

    @Test func threadsAndDissolvesNeedAWorkerSlot() {
        var bare = anchor
        bare.worker = nil
        #expect(shapes(.thread, p: 0.5, anchor: bare).isEmpty)
        #expect(shapes(.dissolve, p: 0.5, anchor: bare).isEmpty)
        #expect(shapes(.thread, p: 0.5).count > 4)
        #expect(shapes(.dissolve, p: 0.5).count == 20)
    }

    @Test func aKnockAndAGroundRippleSpreadFromThePlate() throws {
        guard case .ripple(_, _, let early, _, let first) = try #require(shapes(.knock, p: 0.1).first),
            case .ripple(_, _, let late, _, let last) = try #require(shapes(.knock, p: 0.9).first)
        else { return }
        #expect(late > early && last < first)
        let red = WallEffect(kind: .groundRipple, tile: "a", start: 10, duration: 2, ink: .failed, seed: 1)
        let plain = WallEffect(kind: .groundRipple, tile: "a", start: 10, duration: 2, ink: .finished, seed: 1)
        let a = WallEffectShapes.shapes(for: red, at: 11, anchor: anchor, unit: 7.2)
        let b = WallEffectShapes.shapes(for: plain, at: 11, anchor: anchor, unit: 7.2)
        #expect(alphas(a)[0] < alphas(b)[0])
    }

    @Test func aFadeIsABloomOfSixTenthsOfTheGlyph() throws {
        guard case .bloom(let x, let y, let radius, let alpha) = try #require(shapes(.fade, p: 0.5).first) else { return }
        #expect(x == anchor.glyphX && y == anchor.glyphY)
        #expect(abs(radius - 0.6 * anchor.glyphSize) < 1e-9 && abs(alpha - 0.25) < 1e-9)
    }

    @Test func amplitudeAddsPiecesAndLightWithinTheCaps() {
        #expect(shapes(.fracture, p: 0.5, amplitude: 1.6).count > shapes(.fracture, p: 0.5, amplitude: 1).count)
        #expect(shapes(.fracture, p: 0.5, amplitude: 1.6).count == 1 + 14)
        #expect(shapes(.gather, p: 0.5, amplitude: 1).count == 36)
        #expect(shapes(.gather, p: 0.5, amplitude: 1.6).count == 50)
        let low = alphas(shapes(.exhale, p: 0.3, amplitude: 1))
        let high = alphas(shapes(.exhale, p: 0.3, amplitude: 1.6))
        #expect(high[0] > low[0] && abs(high[0] / low[0] - 1.3) < 1e-9)
        #expect(shapes(.drain, p: 0.5, amplitude: 0).isEmpty)
    }

    @Test func aDrainReadsItsRingFromSmoothstepAndRestsAtItsEnd() throws {
        let drain = WallEffect(kind: .drain, tile: "a", start: 10, duration: 2.6, ink: .tile, from: 0.8, to: 0.2)
        #expect(WallEffectShapes.drainShare(drain, at: 9) == nil)
        #expect(WallEffectShapes.drainShare(drain, at: 13) == nil)
        #expect(WallEffectShapes.drainShare(effect(.pulse), at: 11) == nil)
        let start = try #require(WallEffectShapes.drainShare(drain, at: 10))
        let middle = try #require(WallEffectShapes.drainShare(drain, at: 11.3))
        let end = try #require(WallEffectShapes.drainShare(drain, at: 12.59))
        #expect(abs(start - 0.8) < 1e-9 && abs(middle - 0.5) < 1e-9 && abs(end - 0.2) < 1e-9)
        var last = 1.0
        for step in 0...25 {
            let share = try #require(WallEffectShapes.drainShare(drain, at: 10 + Double(step) * 0.1))
            #expect(share <= last + 1e-12)
            last = share
        }
    }

    @Test func eachKindHasASharpnessForItsMotes() {
        #expect(WallEffectShapes.core(for: .spark) == 0.25)
        #expect(WallEffectShapes.core(for: .fracture) == 0.4 && WallEffectShapes.core(for: .drain) == 0.4)
        #expect(WallEffectShapes.core(for: .thread) == 0.35)
    }
}
