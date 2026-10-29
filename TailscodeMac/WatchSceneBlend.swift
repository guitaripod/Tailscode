import Foundation
import TailscodeCore

/// The wall morphing from one layout to the next: the geometry of what stood on the screen a moment
/// ago and what stands there now, mixed. Everything but geometry (colour, light, motion) is the new
/// scene's, so the morph never freezes the wall; and when the two scenes do not hold the same things
/// there is nothing to morph and the new one stands at once.
enum WatchSceneBlend {
    static let duration: TimeInterval = 0.35

    /// Slows at the end, which is how a thing that was moved settles.
    static func easeOut(_ p: Double) -> Double {
        let q = 1 - min(1, max(0, p))
        return 1 - q * q * q
    }

    private static func mix(_ a: Double, _ b: Double, _ p: Double) -> Double { a + (b - a) * p }

    private static func mix(_ a: WallRect, _ b: WallRect, _ p: Double) -> WallRect {
        WallRect(
            x: mix(a.x, b.x, p), y: mix(a.y, b.y, p), width: mix(a.width, b.width, p),
            height: mix(a.height, b.height, p))
    }

    static func isMorphable(_ from: WallScene, _ to: WallScene) -> Bool {
        from.plates.count == to.plates.count && from.glyphs.count == to.glyphs.count
            && from.lights.count == to.lights.count && from.bars.count == to.bars.count
    }

    static func mixed(from: WallScene, to: WallScene, _ progress: Double) -> WallScene {
        guard isMorphable(from, to) else { return to }
        let p = easeOut(progress)
        var out = to
        for index in out.plates.indices {
            out.plates[index].rect = mix(from.plates[index].rect, to.plates[index].rect, p)
            out.plates[index].corner = mix(from.plates[index].corner, to.plates[index].corner, p)
        }
        for index in out.lights.indices {
            out.lights[index].rect = mix(from.lights[index].rect, to.lights[index].rect, p)
        }
        for index in out.bars.indices {
            out.bars[index].rect = mix(from.bars[index].rect, to.bars[index].rect, p)
        }
        for index in out.glyphs.indices {
            out.glyphs[index].x = mix(from.glyphs[index].x, to.glyphs[index].x, p)
            out.glyphs[index].y = mix(from.glyphs[index].y, to.glyphs[index].y, p)
            out.glyphs[index].size = mix(from.glyphs[index].size, to.glyphs[index].size, p)
        }
        return out
    }
}
