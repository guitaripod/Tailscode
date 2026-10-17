import Foundation
import Testing

@testable import TailscodeCore

enum NeuralTestWorld {
    static let width = 64
    static let height = 40

    static func layers(width: Int = NeuralTestWorld.width, height: Int = NeuralTestWorld.height)
        -> [NeuralAssetName: NeuralImage]
    {
        func scaled(_ value: Int, _ axis: Int, _ reference: Int) -> Int { value * axis / reference }
        var chassis = NeuralImage(width: width, height: height) { x, y in
            let inside = x >= 6 && x < 58 && y >= 4 && y < 36
            guard inside else { return SIMD4(0, 0, 0, 0) }
            let edge = x == 6 || y == 4
            return SIMD4(70, UInt8(90 + y), UInt8(110 + x), edge ? 128 : 255)
        }
        chassis.setPixel(x: 30, y: 20, SIMD4(250, 240, 230, 255))
        let interior = NeuralImage(width: width, height: height) { x, y in
            guard x >= 10 && x < 54 && y >= 8 && y < 30 else { return SIMD4(0, 0, 0, 0) }
            return SIMD4(UInt8(x * 3), 40, UInt8(y * 4), 200)
        }
        let glass = NeuralImage(width: width / 2, height: height / 2) { x, y in
            x >= 4 && x < 20 && y >= 2 && y < 10 ? SIMD4(200, 220, 255, 60) : SIMD4(0, 0, 0, 0)
        }
        var mask0 = NeuralImage(width: width, height: height)
        var mask1 = NeuralImage(width: width, height: height)
        var mask2 = NeuralImage(width: width, height: height)
        mask0.setPixel(x: 40, y: 12, SIMD4(200, 0, 0, 0))
        mask0.setPixel(x: 41, y: 12, SIMD4(120, 60, 0, 0))
        mask0.setPixel(x: 20, y: 16, SIMD4(0, 255, 0, 0))
        mask0.setPixel(x: 30, y: 10, SIMD4(0, 0, 128, 0))
        mask0.setPixel(x: 15, y: 28, SIMD4(0, 0, 0, 90))
        mask1.setPixel(x: 44, y: 22, SIMD4(180, 0, 0, 0))
        mask1.setPixel(x: 52, y: 30, SIMD4(0, 160, 0, 0))
        mask1.setPixel(x: 25, y: 14, SIMD4(0, 0, 0, 200))
        for x in 12..<30 { mask1.setPixel(x: x, y: 20, SIMD4(0, 0, 255, 0)) }
        mask1.setPixel(x: 12, y: 24, SIMD4(0, 0, 1, 0))
        mask1.setPixel(x: 13, y: 24, SIMD4(0, 0, 2, 0))
        mask1.setPixel(x: 14, y: 24, SIMD4(0, 0, 3, 0))
        mask2.setPixel(x: 10, y: 18, SIMD4(255, 0, 0, 0))
        for x in 55..<61 {
            for y in 18..<22 { mask2.setPixel(x: x, y: y, SIMD4(0, 255, 0, 0)) }
        }
        for y in 36..<39 { mask2.setPixel(x: 31, y: y, SIMD4(0, 0, 255, 0)) }
        mask2.setPixel(x: 50, y: 34, SIMD4(0, 0, 0, 255))
        var bloom0 = NeuralImage(width: width / 8, height: height / 8)
        var bloom1 = NeuralImage(width: width / 8, height: height / 8)
        var bloom2 = NeuralImage(width: width / 8, height: height / 8)
        bloom0.setPixel(x: 5, y: 1, SIMD4(100, 80, 0, 0))
        bloom0.setPixel(x: 2, y: 2, SIMD4(0, 60, 90, 40))
        bloom1.setPixel(x: 5, y: 2, SIMD4(50, 0, 70, 30))
        bloom1.setPixel(x: 3, y: 2, SIMD4(0, 0, 120, 0))
        bloom2.setPixel(x: 7, y: 2, SIMD4(60, 150, 80, 90))
        bloom2.setPixel(x: 1, y: 2, SIMD4(90, 0, 0, 0))
        return [
            .chassis: chassis, .interior: interior, .glass: glass, .mask0: mask0, .mask1: mask1,
            .mask2: mask2, .bloom0: bloom0, .bloom1: bloom1, .bloom2: bloom2,
        ]
    }

    static func store(_ layers: [NeuralAssetName: NeuralImage] = NeuralTestWorld.layers())
        -> NeuralAssetStore
    {
        let raw = Dictionary(uniqueKeysWithValues: layers.map { ($0.key.fileName, $0.value.rawData()) })
        return NeuralAssetStore { raw[$0] }
    }

    static let tones: [NeuralRGB] = [
        NeuralRGB(0.85, 1.0, 0.9), NeuralRGB(0.25, 0.85, 1.0), NeuralRGB(0.15, 1.0, 0.5),
        NeuralRGB(0.62, 0.45, 1.0), NeuralRGB(0.55, 0.85, 0.7), NeuralRGB(0.3, 1.0, 0.8),
        NeuralRGB(0.5, 1.0, 0.85), NeuralRGB(0.8, 1.0, 0.95), NeuralRGB(0.15, 1.0, 0.5),
        NeuralRGB(0.2, 0.9, 0.4), NeuralRGB(0.3, 0.8, 0.5), NeuralRGB(0.9, 0.3, 0.5),
        NeuralRGB(0.2, 0.4, 0.5),
    ].map { NeuralRGB(powf($0.r, 2.2), powf($0.g, 2.2), powf($0.b, 2.2)) }

    static func table(spill: Bool = true) -> NeuralToneTable {
        NeuralToneTable(tones: tones, spill: spill)
    }

    static func busyFrame() -> NeuralFrame {
        var frame = NeuralFrame()
        frame.intensity = [1.2, 0.3, 0.3, 0.3, 0.3, 0.3, 0.7, 0.6, 0.3, 0.9, 0.62, 0.4, 0.25]
        frame.toneOverride[1] = .attention
        frame.effort = 3
        frame.ribs = 2.5
        frame.sweepTone = .live
        return frame
    }
}

/// An unoptimised Double implementation of the two shader passes, reading the same layers.
private struct ReferenceRenderer {
    let width: Int
    let height: Int
    let table: NeuralToneTable
    let images: [NeuralAssetName: NeuralImage]

    init(width: Int, height: Int, table: NeuralToneTable, layers: [NeuralAssetName: NeuralImage]) {
        self.width = width
        self.height = height
        self.table = table
        images = layers.mapValues { $0.resized(width: width, height: height) }
    }

    func lin(_ byte: UInt8) -> Double { pow(Double(byte) / 255, 2.2) }

    func value(_ name: NeuralAssetName, _ x: Int, _ y: Int, _ component: Int) -> Double {
        let pixel = images[name]!.pixel(x: x, y: y)
        return Double([pixel.x, pixel.y, pixel.z, pixel.w][component]) / 255
    }

    func warped(_ u: Double, _ t: Double, crunch: Double) -> (Double, Double) {
        let aspect = Double(width) / Double(height)
        var best = NeuralZone.think.center
        var nearest = Double.greatestFiniteMagnitude
        for zone in NeuralZone.allCases {
            let cx = zone.center.x / 640
            let cy = zone.center.y / 420
            let d = ((u - cx) * aspect) * ((u - cx) * aspect) + (t - cy) * (t - cy)
            if d < nearest {
                nearest = d
                best = zone.center
            }
        }
        let bx = best.x / 640
        let by = best.y / 420
        return (bx + (u - bx) * (1 + 0.7 * crunch), by + (t - by) * (1 + 0.7 * crunch))
    }

    func sampled(
        _ name: NeuralAssetName, _ x: Int, _ y: Int, _ component: Int, crunch: Double
    ) -> Double {
        guard crunch > 0 else { return value(name, x, y, component) }
        let u = (Double(x) + 0.5) / Double(width)
        let t = (Double(y) + 0.5) / Double(height)
        let point = warped(u, t, crunch: crunch)
        let pixel = images[name]!.sample(u: Float(point.0), t: Float(point.1))
        return Double([pixel.x, pixel.y, pixel.z, pixel.w][component])
    }

    func tone(_ index: Int, _ frame: NeuralFrame) -> [Double] {
        let color: NeuralRGB
        if let override = frame.toneOverride[index] {
            color = table.color(for: override)
        } else {
            color = table.channels[index]
        }
        return [Double(color.r), Double(color.g), Double(color.b)]
    }

    func gamma(_ value: Double) -> Double { pow(min(max(value, 0), 1), 1 / 2.2) }

    func level(_ value: Double) -> Int { Int(min(max(value * 255 + 0.5, 0), 255).rounded(.down)) }

    func interior(_ frame: NeuralFrame, time: Double) -> [Int] {
        var out = [Int](repeating: 0, count: width * height * 4)
        let bg = [Double(table.background.r), Double(table.background.g), Double(table.background.b)]
        let sweepTone = table.color(for: frame.sweepTone)
        let aspect = Double(width) / Double(height)
        for y in 0..<height {
            for x in 0..<width {
                let u = (Double(x) + 0.5) / Double(width)
                let t = (Double(y) + 0.5) / Double(height)
                let c = images[.interior]!.pixel(x: x, y: y)
                let a = Double(c.w) / 255
                let cl = [lin(c.x), lin(c.y), lin(c.z)]
                let base = (0..<3).map { bg[$0] * (1 - a) + cl[$0] * a }
                var rip = 1.0
                if frame.ripple != 0 {
                    let point = frame.active ?? NeuralPoint(320, 210)
                    let dx = (u - point.x / 640) * aspect
                    let dy = t - point.y / 420
                    rip = 1 + Double(frame.ripple) * 0.45 * sin((dx * dx + dy * dy).squareRoot() * 38 - time * 3.2)
                }
                var glow = [0.0, 0.0, 0.0]
                for channel in 0..<8 {
                    let mask = channel < 4 ? NeuralAssetName.mask0 : .mask1
                    let bloom = channel < 4 ? NeuralAssetName.bloom0 : .bloom1
                    var weight =
                        sampled(mask, x, y, channel % 4, crunch: Double(frame.crunch)) * 4
                        + sampled(bloom, x, y, channel % 4, crunch: Double(frame.crunch)) * (6.0 / 3.0)
                    if channel == 6 { weight *= rip }
                    let color = tone(channel, frame)
                    for k in 0..<3 { glow[k] += weight * color[k] * Double(frame.intensity[channel]) }
                }
                let luma = glow[0] * 0.3 + glow[1] * 0.5 + glow[2] * 0.2
                let phase = (u * 0.9 + (1 - t) * 0.35 - Double(frame.sweep)) * 7
                let band = exp(-phase * phase)
                let sweepTint = [Double(sweepTone.r), Double(sweepTone.g), Double(sweepTone.b)]
                var rgb = [Double](repeating: 0, count: 3)
                for k in 0..<3 {
                    var add = glow[k]
                    add += sweepTint[k] * band * Double(frame.sweepAmount) * (0.14 * a + min(luma * 1.2, 1))
                    add = add / (1 + 0.2 * add)
                    let col = 1 - (1 - base[k]) * (1 - min(max(add, 0), 1))
                    rgb[k] = gamma(col)
                }
                let offset = (y * width + x) * 4
                out[offset] = level(rgb[2])
                out[offset + 1] = level(rgb[1])
                out[offset + 2] = level(rgb[0])
                out[offset + 3] = 255
            }
        }
        return out
    }

    func front(_ frame: NeuralFrame, time: Double) -> [Int] {
        var out = [Int](repeating: 0, count: width * height * 4)
        let spill = table.spill ? 1.0 : 0.0
        for y in 0..<height {
            for x in 0..<width {
                let u = (Double(x) + 0.5) / Double(width)
                let t = (Double(y) + 0.5) / Double(height)
                let ch = images[.chassis]!.pixel(x: x, y: y)
                let ca = Double(ch.w) / 255
                let gl = images[.glass]!.pixel(x: x, y: y)
                let ga = Double(gl.w) / 255
                let seam = value(.mask2, x, y, 0) + value(.bloom2, x, y, 0) * (4.0 / 3.0)
                let eye = value(.mask2, x, y, 1) + value(.bloom2, x, y, 1) * (4.0 / 3.0)
                let rib = value(.mask2, x, y, 2) + value(.bloom2, x, y, 2) * (4.0 / 3.0)
                let ear = value(.mask2, x, y, 3) + value(.bloom2, x, y, 3) * (4.0 / 3.0)
                let xd = u * 640
                let yd = t * 420
                let segment = min(max(floor((xd - 562) / 8.2), 0), 4)
                let lit = segment < Double(frame.effort) ? 1.0 : (frame.hollow ? 0.1 : 0.14)
                var eyeColor = tone(9, frame)
                if frame.rainbow {
                    let rainbow = (0..<3).map {
                        0.5 + 0.5 * cos(2 * Double.pi * (u * 5 - time * 0.3 + [0, 0.33, 0.67][$0]))
                    }
                    eyeColor = rainbow
                }
                let ribIndex = min(max(floor((yd - 381) / 6), 0), 5)
                let ribLit = min(max(Double(frame.ribs) - (5 - ribIndex), 0), 1)
                var glow = [Double](repeating: 0, count: 3)
                let seamColor = tone(8, frame)
                let ribColor = tone(10, frame)
                let earColor = tone(11, frame)
                for k in 0..<3 {
                    glow[k] += seam * seamColor[k] * Double(frame.intensity[8]) * 2
                    glow[k] += eye * eyeColor[k] * Double(frame.intensity[9]) * lit * 4
                    glow[k] += rib * ribColor[k] * Double(frame.intensity[10]) * ribLit * 3
                    glow[k] += ear * earColor[k] * Double(frame.intensity[11]) * 3
                    glow[k] *= ca * (1 - spill) + spill
                    glow[k] = glow[k] / (1 + 0.2 * glow[k])
                }
                let spilled = spill > 0.5 ? min(max(glow.max()!, 0), 1) : 0
                let chassisLinear = [lin(ch.x), lin(ch.y), lin(ch.z)]
                let glassLinear = [lin(gl.x), lin(gl.y), lin(gl.z)]
                var color = (0..<3).map { chassisLinear[$0] * ca + glow[$0] }
                var alpha = min(max(ca + spilled, 0), 1)
                color = (0..<3).map { color[$0] * (1 - ga) + glassLinear[$0] * ga }
                alpha = alpha * (1 - ga) + ga
                let encoded = color.map { gamma($0) }
                let coverage = max(min(max(alpha, 0), 1), encoded.max()!)
                let offset = (y * width + x) * 4
                out[offset] = level(encoded[2])
                out[offset + 1] = level(encoded[1])
                out[offset + 2] = level(encoded[0])
                out[offset + 3] = level(coverage)
            }
        }
        return out
    }
}

private func maxDifference(_ surface: NeuralSurface, _ reference: [Int]) -> Int {
    var worst = 0
    for index in 0..<reference.count {
        worst = max(worst, abs(Int(surface.bytes[index]) - reference[index]))
    }
    return worst
}

private func sum(_ surface: NeuralSurface) -> Int {
    var total = 0
    for y in 0..<surface.height {
        for x in 0..<surface.width {
            let offset = (y * surface.width + x) * 4
            total += Int(surface.bytes[offset]) + Int(surface.bytes[offset + 1]) + Int(surface.bytes[offset + 2])
        }
    }
    return total
}

@Suite("Neural compositor")
struct NeuralCompositorTests {
    private func compositor(
        spill: Bool = true, size: (width: Int, height: Int) = (NeuralTestWorld.width, NeuralTestWorld.height)
    ) -> NeuralCompositor {
        NeuralCompositor(
            assets: NeuralTestWorld.store(), size: size, table: NeuralTestWorld.table(spill: spill))
    }

    @Test("a rest frame matches the float reference to one level on both passes")
    func restMatchesReference() {
        let composite = compositor()
        let frame = NeuralFrame()
        let pair = composite.renderFull(frame)
        let reference = ReferenceRenderer(
            width: 64, height: 40, table: NeuralTestWorld.table(), layers: NeuralTestWorld.layers())
        #expect(maxDifference(pair.interior, reference.interior(frame, time: 0)) <= 1)
        #expect(maxDifference(pair.front, reference.front(frame, time: 0)) <= 1)
    }

    @Test("a busy frame with tone overrides, effort and ribs matches the reference")
    func busyMatchesReference() {
        let composite = compositor()
        let frame = NeuralTestWorld.busyFrame()
        let pair = composite.renderFull(frame)
        let reference = ReferenceRenderer(
            width: 64, height: 40, table: NeuralTestWorld.table(), layers: NeuralTestWorld.layers())
        #expect(maxDifference(pair.interior, reference.interior(frame, time: 0)) <= 1)
        #expect(maxDifference(pair.front, reference.front(frame, time: 0)) <= 1)
    }

    @Test("the sweep, the ripple, the rainbow and the hollow visor match the reference")
    func motionMatchesReference() {
        let composite = compositor()
        var frame = NeuralTestWorld.busyFrame()
        frame.sweep = 0.43
        frame.sweepAmount = 0.9
        frame.sweepTone = .attention
        frame.ripple = 1
        frame.active = NeuralPoint(300, 200)
        frame.rainbow = true
        frame.hollow = true
        frame.effort = 0
        frame.settled = false
        let pair = composite.renderFull(frame, time: 1.7)
        let reference = ReferenceRenderer(
            width: 64, height: 40, table: NeuralTestWorld.table(), layers: NeuralTestWorld.layers())
        #expect(maxDifference(pair.interior, reference.interior(frame, time: 1.7)) <= 1)
        #expect(maxDifference(pair.front, reference.front(frame, time: 1.7)) <= 1)
    }

    @Test("a light table gives the same answer as its reference, with no spill")
    func lightMatchesReference() {
        let composite = compositor(spill: false)
        let frame = NeuralTestWorld.busyFrame()
        let pair = composite.renderFull(frame)
        let reference = ReferenceRenderer(
            width: 64, height: 40, table: NeuralTestWorld.table(spill: false), layers: NeuralTestWorld.layers())
        #expect(maxDifference(pair.interior, reference.interior(frame, time: 0)) <= 1)
        #expect(maxDifference(pair.front, reference.front(frame, time: 0)) <= 1)
    }

    @Test("another output size resamples every layer once and still matches the reference")
    func otherSize() {
        let composite = compositor(size: (32, 20))
        let frame = NeuralTestWorld.busyFrame()
        let pair = composite.renderFull(frame)
        #expect(pair.interior.width == 32 && pair.front.height == 20)
        let reference = ReferenceRenderer(
            width: 32, height: 20, table: NeuralTestWorld.table(), layers: NeuralTestWorld.layers())
        #expect(maxDifference(pair.interior, reference.interior(frame, time: 0)) <= 1)
        #expect(maxDifference(pair.front, reference.front(frame, time: 0)) <= 1)

        composite.setSize(width: 96, height: 60)
        let large = composite.renderFull(frame)
        #expect(large.interior.width == 96 && large.interior.bytes.count == 96 * 60 * 4)
        let big = ReferenceRenderer(
            width: 96, height: 60, table: NeuralTestWorld.table(), layers: NeuralTestWorld.layers())
        #expect(maxDifference(large.interior, big.interior(frame, time: 0)) <= 1)
        #expect(maxDifference(large.front, big.front(frame, time: 0)) <= 1)
    }

    @Test("the interior is opaque and the front is a valid premultiplied surface")
    func surfaceInvariants() {
        let composite = compositor()
        let pair = composite.renderFull(NeuralTestWorld.busyFrame())
        for index in stride(from: 0, to: pair.interior.bytes.count, by: 4) {
            #expect(pair.interior.bytes[index + 3] == 255)
            let alpha = pair.front.bytes[index + 3]
            #expect(pair.front.bytes[index] <= alpha)
            #expect(pair.front.bytes[index + 1] <= alpha)
            #expect(pair.front.bytes[index + 2] <= alpha)
        }
    }

    @Test("an offline frame is darker than a rest frame")
    func offlineIsDark() {
        let composite = compositor()
        var offline = NeuralFrame()
        offline.intensity = [Float](repeating: 0.05, count: 13)
        offline.intensity[9] = 0
        offline.intensity[8] = 0.06
        let rest = composite.renderFull(NeuralFrame())
        let dark = composite.renderFull(offline)
        #expect(sum(dark.interior) < sum(rest.interior))
        #expect(sum(dark.front) < sum(rest.front))
    }

    @Test("a light palette leaves nothing outside the chassis and a dark one lets the glow spill")
    func spillRule() {
        let frame = NeuralTestWorld.busyFrame()
        let outside = (x: 59, y: 20)
        let offset = (outside.y * 64 + outside.x) * 4
        let dark = compositor(spill: true).renderFull(frame)
        let light = compositor(spill: false).renderFull(frame)
        #expect(dark.front.bytes[offset + 3] > 0)
        #expect(light.front.bytes[offset + 3] == 0)
        #expect(light.front.bytes[offset] == 0 && light.front.bytes[offset + 1] == 0)
        let lightTable = NeuralToneTable(palette: AppTheme.fallback.palette(dark: false), face: .unknown)
        let darkTable = NeuralToneTable(palette: AppTheme.fallback.palette(dark: true), face: .unknown)
        #expect(lightTable.spill == false)
        #expect(darkTable.spill == true)
        let paletteLight = NeuralCompositor(
            assets: NeuralTestWorld.store(), size: (64, 40), palette: AppTheme.fallback.palette(dark: false),
            face: .unknown)
        let rendered = paletteLight.renderFull(frame)
        #expect(rendered.front.bytes[offset + 3] == 0)
    }

    @Test("a delta over the dirty region equals a full render of the same frame")
    func deltaEqualsFull() {
        let composite = compositor()
        let first = NeuralFrame()
        var second = NeuralFrame()
        second.intensity[0] = 1.1
        second.effort = 2
        second.settled = false
        var pair = composite.renderFull(first)
        let region = composite.dirtyRegion(for: second, previous: first)
        #expect(!region.isEmpty)
        #expect(region.area < 64 * 40)
        composite.renderDelta(second, previous: first, into: &pair)
        let expected = compositor().renderFull(second)
        #expect(pair == expected)

        var third = second
        third.intensity[0] = 0.4
        third.toneOverride[0] = .danger
        third.ribs = 3
        composite.renderDelta(third, previous: second, into: &pair)
        #expect(pair == compositor().renderFull(third))
    }

    @Test("a delta that changes only the ripple redraws the fibre pixels and matches a full render there")
    func rippleDelta() {
        let composite = compositor()
        var first = NeuralFrame()
        first.ripple = 1
        first.active = NeuralPoint(200, 160)
        first.settled = false
        var second = first
        second.active = NeuralPoint(260, 180)
        var pair = composite.renderFull(first, time: 0.5)
        composite.renderDelta(second, previous: first, into: &pair, time: 0.9)
        let full = composite.renderFull(second, time: 0.9)
        for index in composite.fibrePixels {
            let offset = index * 4
            #expect(Array(pair.interior.bytes[offset..<(offset + 4)]) == Array(full.interior.bytes[offset..<(offset + 4)]))
        }
        #expect(pair.front == full.front)
    }

    @Test("the sweep and the crunch redraw the whole dome")
    func movingRedrawsDome() {
        let composite = compositor()
        let rest = NeuralFrame()
        var sweeping = rest
        sweeping.sweepAmount = 0.9
        sweeping.sweep = 0.3
        sweeping.settled = false
        let sweepRegion = composite.dirtyRegion(for: sweeping, previous: rest)
        var tweak = rest
        tweak.effort = 2
        tweak.settled = false
        let eye = composite.dirtyRegion(for: tweak, previous: rest)
        #expect(!eye.isEmpty)
        #expect(sweepRegion.area > eye.area * 2)
        var pair = composite.renderFull(rest)
        composite.renderDelta(sweeping, previous: rest, into: &pair)
        #expect(pair == compositor().renderFull(sweeping))

        var crunching = sweeping
        crunching.crunch = 0.6
        let crunched = composite.renderFull(crunching)
        let reference = ReferenceRenderer(
            width: 64, height: 40, table: NeuralTestWorld.table(), layers: NeuralTestWorld.layers())
        #expect(maxDifference(crunched.interior, reference.interior(crunching, time: 0)) <= 1)
        #expect(crunched.interior != compositor().renderFull(sweeping).interior)
    }

    @Test("a settled frame equal to the last needs no render")
    func settledNeedsNothing() {
        let composite = compositor()
        let frame = NeuralFrame()
        #expect(composite.needsRender(frame))
        _ = composite.renderFull(frame)
        #expect(!composite.needsRender(frame))
        #expect(composite.dirtyRegion(for: frame, previous: frame).isEmpty)
        var moving = frame
        moving.settled = false
        _ = composite.renderFull(moving)
        #expect(composite.needsRender(moving))
        #expect(composite.needsRender(frame))
        _ = composite.renderFull(frame)
        #expect(composite.needsRender(frame, dive: NeuralDive(chassisScale: 1.2)))
        composite.setTable(NeuralTestWorld.table(spill: false))
        #expect(composite.needsRender(frame))
    }

    @Test("a first delta with nothing before it redraws everything")
    func firstDeltaIsWhole() {
        let composite = compositor()
        var pair = composite.makeSurfacePair()
        composite.renderDelta(NeuralFrame(), previous: nil, into: &pair)
        #expect(pair == compositor().renderFull(NeuralFrame()))
    }

    @Test("the sparse fibre list is exactly the pixels where the link channel is at least 2/255")
    func fibreList() {
        let composite = compositor()
        let expected = Set(
            (12..<30).map { 20 * 64 + $0 } + [24 * 64 + 13, 24 * 64 + 14])
        #expect(Set(composite.fibrePixels) == expected)
        #expect(composite.fibrePixels.count == expected.count)
        #expect(!composite.fibrePixels.contains(24 * 64 + 12))
    }

    @Test("a dive scales the front layers about its centre and fades them")
    func dive() {
        let composite = compositor()
        let frame = NeuralFrame()
        let still = composite.renderFull(frame)
        let dived = composite.renderFull(
            frame, dive: NeuralDive(center: NeuralPoint(0.5, 0.5), chassisScale: 1.6, glassScale: 2, fade: 0.5))
        #expect(dived.interior == still.interior)
        #expect(dived.front != still.front)
        let same = composite.renderFull(frame, dive: NeuralDive(center: NeuralPoint(0.3, 0.7)))
        #expect(same == still)
        let faded = composite.renderFull(frame, dive: NeuralDive(fade: 0))
        let probe = (30 * 64 + 45) * 4 + 3
        #expect(still.front.bytes[probe] == 255)
        #expect(faded.front.bytes[probe] == 0)
        var pair = composite.renderFull(frame)
        composite.renderDelta(frame, previous: frame, into: &pair, dive: NeuralDive(chassisScale: 1.6, glassScale: 2))
        #expect(pair == composite.renderFull(frame, dive: NeuralDive(chassisScale: 1.6, glassScale: 2)))
    }

    @Test("missing layers draw blank rather than failing, and say so")
    func missingLayers() {
        var layers = NeuralTestWorld.layers()
        layers[.glass] = nil
        let composite = NeuralCompositor(
            assets: NeuralTestWorld.store(layers), size: (64, 40), table: NeuralTestWorld.table())
        #expect(!composite.isComplete)
        let pair = composite.renderFull(NeuralFrame())
        #expect(pair.interior.bytes.count == 64 * 40 * 4)
        #expect(compositor().isComplete)
    }

    @Test("the footprint counts the resampled layers and the compositor holds the store while it lives")
    func footprintAndRetain() {
        let store = NeuralTestWorld.store()
        var composite: NeuralCompositor? = NeuralCompositor(
            assets: store, size: (64, 40), table: NeuralTestWorld.table())
        #expect(store.retainCount == 1)
        #expect(composite!.memoryFootprint >= 64 * 40 * 4 * 11)
        composite!.setSize(width: 32, height: 20)
        #expect(composite!.memoryFootprint < 64 * 40 * 4 * 11)
        composite = nil
        #expect(store.retainCount == 0)
        #expect(!store.isResident)
    }

    @Test("the tone overload and the palette initialiser agree on the colours they derive")
    func toneTable() {
        let table = NeuralTestWorld.table()
        #expect(table.channels.count == 13)
        #expect(table.color(for: .identity) == table.channels[9])
        let palette = AppTheme.fallback.palette(dark: true)
        let derived = NeuralToneTable(palette: palette, face: .unknown)
        #expect(derived.channels == NeuralPalette.channelTones(palette: palette, face: .unknown))
        #expect(derived.background == NeuralPalette.canvas(palette: palette))
        let short = NeuralToneTable(tones: [NeuralRGB(1, 1, 1)], spill: true)
        #expect(short.channels.count == 13)
    }

    @Test("render times are recorded at the design size")
    func performance() {
        let width = NeuralAssetName.fullWidth
        let height = NeuralAssetName.fullHeight
        func sized(_ name: NeuralAssetName, _ w: Int, _ h: Int) -> NeuralImage {
            NeuralImage(width: w, height: h) { x, y in
                let dome = (x - w / 2) * (x - w / 2) * 4 + (y - h / 2) * (y - h / 2) * 9 < w * h * 2
                switch name {
                case .chassis: return dome ? SIMD4(60, 80, 100, 255) : SIMD4(0, 0, 0, 0)
                case .interior: return dome ? SIMD4(UInt8(x % 64), 50, UInt8(y % 64), 220) : SIMD4(0, 0, 0, 0)
                case .glass: return dome ? SIMD4(200, 220, 255, 20) : SIMD4(0, 0, 0, 0)
                default:
                    let scale = name.isBloom ? 8 : 1
                    let wx = x * scale
                    let wy = y * scale
                    let window: (Int, Int, Int, Int)
                    switch name {
                    case .mask0, .bloom0: window = (640, 200, 900, 420)
                    case .mask1, .bloom1: window = (1000, 300, 1200, 500)
                    default: window = (1250, 350, 1500, 650)
                    }
                    let slack = name.isBloom ? 8 : 0
                    let inside =
                        wx >= window.0 - slack && wx < window.2 + slack && wy >= window.1 - slack
                        && wy < window.3 + slack
                    let hot = dome && inside && (name.isBloom || (x * 7 + y * 13) % 5 == 0)
                    return hot ? SIMD4(200, 150, 100, 90) : SIMD4(0, 0, 0, 0)
                }
            }
        }
        var layers: [NeuralAssetName: NeuralImage] = [:]
        for name in NeuralAssetName.allCases {
            layers[name] = sized(name, name.width, name.height)
        }
        let composite = NeuralCompositor(
            assets: NeuralTestWorld.store(layers), size: (width, height), table: NeuralTestWorld.table())
        var first = NeuralFrame()
        first.settled = false
        var second = first
        second.intensity[0] = 0.9
        second.effort = 2
        var pair = composite.makeSurfacePair()
        let clock = ContinuousClock()
        let full = clock.measure { composite.renderFull(first, into: &pair) }
        let region = composite.dirtyRegion(for: second, previous: first)
        let delta = clock.measure { composite.renderDelta(second, previous: first, into: &pair) }
        var ripple = second
        ripple.ripple = 1
        let sparse = clock.measure { composite.renderDelta(ripple, previous: second, into: &pair) }
        print(
            "NEURAL-PERF \(width)x\(height) renderFull \(full) renderDelta \(delta) (region \(region.width)x\(region.height)) rippleDelta \(sparse) fibres \(composite.fibrePixels.count) footprint \(composite.memoryFootprint / 1_000_000) MB"
        )
        #expect(region.area < width * height)
    }
}
