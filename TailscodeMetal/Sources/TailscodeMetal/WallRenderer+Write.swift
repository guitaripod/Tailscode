import Foundation
@preconcurrency import Metal
import QuartzCore
import TailscodeCore

/// Float offsets into the ground's uniform block, which is `GroundU` in the shader.
enum GroundLayout {
    static let size = 0
    static let ground = 4
    static let deep = 8
    static let text = 12
    static let tint = 16
    static let vignette = 20
    static let misc = 24
    static let counts = 28
    static let lightRects = 32
    static let lightInks = 64
    static let rippleRects = 96
    static let rippleInks = 144
    static let rippleParams = 192
    static let floats = 240
}

extension WallRenderer {
    struct Counts {
        var quads = 0
        var glyphs = 0
        var glows = 0
        var dots = 0
    }

    func write(_ scene: WallScene, into slot: Slot) -> Counts {
        var counts = Counts()
        let quads = slot.quads.contents().assumingMemoryBound(to: Float.self)
        let plates = min(scene.plates.count, Self.maxPlates)
        for index in 0..<plates {
            Self.put(scene.plates[index], at: quads + index * Self.instanceFloats)
        }
        let bars = min(scene.bars.count, Self.maxBars)
        for index in 0..<bars {
            Self.put(scene.bars[index], at: quads + (plates + index) * Self.instanceFloats)
        }
        counts.quads = plates + bars

        let glyphs = slot.glyphs.contents().assumingMemoryBound(to: Float.self)
        counts.glyphs = min(scene.glyphs.count, Self.maxGlyphs)
        for index in 0..<counts.glyphs {
            Self.put(scene.glyphs[index], at: glyphs + index * Self.instanceFloats)
        }
        let glows = slot.glows.contents().assumingMemoryBound(to: Float.self)
        counts.glows = min(scene.glows.count, Self.maxGlows)
        for index in 0..<counts.glows {
            Self.put(scene.glows[index], at: glows + index * Self.instanceFloats)
        }
        let dots = slot.dots.contents().assumingMemoryBound(to: Float.self)
        counts.dots = min(scene.dots.count, Self.maxDots)
        for index in 0..<counts.dots {
            Self.put(scene.dots[index], at: dots + index * Self.dotFloats)
        }
        return counts
    }

    func writeGround(_ scene: WallScene, scale: Float) {
        let g = groundScratch
        let palette = scene.palette
        Self.set(g + GroundLayout.size, Float(scene.width), Float(scene.height), scale, Float(scene.unit))
        Self.set(g + GroundLayout.ground, palette.ground, Float(scene.tintAlpha))
        Self.set(g + GroundLayout.deep, palette.deep, Float(scene.vignette))
        Self.set(g + GroundLayout.text, palette.text, Float(scene.dim))
        let time = scene.aurora > 0 ? Float((self.time ?? CACurrentMediaTime()).truncatingRemainder(dividingBy: 86_400)) : 0
        Self.set(g + GroundLayout.tint, scene.tint, time)
        Self.set(g + GroundLayout.vignette, scene.vignetteInk, Float(scene.aurora))
        Self.set(g + GroundLayout.misc, Float(scene.driftX), Float(scene.driftY), Float(scene.gridAlpha), 0)

        let lights = min(scene.lights.count, Self.maxLights)
        for index in 0..<lights {
            let light = scene.lights[index]
            Self.set(g + GroundLayout.lightRects + index * 4, light.rect)
            Self.set(g + GroundLayout.lightInks + index * 4, light.ink, Float(light.strength))
        }
        let ripples = min(scene.ripples.count, Self.maxRipples)
        for index in 0..<ripples {
            let ripple = scene.ripples[index]
            Self.set(g + GroundLayout.rippleRects + index * 4, ripple.rect)
            Self.set(g + GroundLayout.rippleInks + index * 4, ripple.ink, Float(ripple.alpha))
            Self.set(
                g + GroundLayout.rippleParams + index * 4, Float(ripple.grow), Float(ripple.width),
                Float(ripple.corner), 0)
        }
        let counts = UnsafeMutableRawPointer(g + GroundLayout.counts).assumingMemoryBound(to: Int32.self)
        counts[0] = Int32(lights)
        counts[1] = Int32(ripples)
        counts[2] = 0
        counts[3] = 0
    }

    private static func set(_ p: UnsafeMutablePointer<Float>, _ x: Float, _ y: Float, _ z: Float, _ w: Float) {
        p[0] = x
        p[1] = y
        p[2] = z
        p[3] = w
    }

    private static func set(_ p: UnsafeMutablePointer<Float>, _ ink: WallInk, _ w: Float) {
        set(p, Float(ink.red), Float(ink.green), Float(ink.blue), w)
    }

    private static func set(_ p: UnsafeMutablePointer<Float>, _ rect: WallRect) {
        set(p, Float(rect.x), Float(rect.y), Float(rect.width), Float(rect.height))
    }

    static func put(_ plate: WallPlate, at p: UnsafeMutablePointer<Float>) {
        set(p, plate.rect)
        set(p + 4, plate.ink, Float(plate.opacity))
        set(p + 8, Float(plate.corner), Float(plate.wash), Float(plate.borderAlpha), Float(plate.borderWidth))
        set(p + 12, plate.hatch ? 1 : 0, Float(plate.flat), Float(plate.sheen), 0)
    }

    static func put(_ bar: WallBar, at p: UnsafeMutablePointer<Float>) {
        set(p, bar.rect)
        set(p + 4, bar.ink, Float(bar.alpha))
        set(p + 8, Float(bar.corner), 0, 0, 1)
        set(p + 12, 0, 0, 0, 1)
    }

    static func put(_ glyph: WallGlyph, at p: UnsafeMutablePointer<Float>) {
        set(p, Float(glyph.x), Float(glyph.y), Float(glyph.size), Float(glyph.extent))
        set(p + 4, glyph.ink, Float(glyph.alpha))
        set(p + 8, Float(glyph.kind.rawValue), Float(glyph.p1), Float(glyph.p2), Float(glyph.p3))
        set(p + 12, Float(glyph.p4), 0, 0, 0)
    }

    static func put(_ dot: WallDot, at p: UnsafeMutablePointer<Float>) {
        set(p, Float(dot.x), Float(dot.y), Float(dot.size), Float(dot.core))
        set(p + 4, dot.ink, Float(dot.alpha))
    }
}
