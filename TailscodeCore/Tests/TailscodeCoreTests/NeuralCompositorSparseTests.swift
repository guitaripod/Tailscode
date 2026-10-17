import Foundation
import Testing

@testable import TailscodeCore

/// A small deterministic generator, so a failing frame can be named by its seed.
struct NeuralLcg {
    var state: UInt64

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state >> 33
    }

    mutating func unit() -> Float { Float(next() % 10_000) / 10_000 }

    mutating func chance(_ probability: Float) -> Bool { unit() < probability }

    mutating func byte() -> UInt8 { UInt8(next() & 255) }

    mutating func pick(_ count: Int) -> Int { Int(next() % UInt64(count)) }
}

/// Layers with the structure of the real set (blobs of bloom around sparse masks, a chassis with
/// soft edges, an interior with holes), made from a seed.
enum NeuralRandomWorld {
    static func layers(width: Int, height: Int, seed: UInt64) -> [NeuralAssetName: NeuralImage] {
        var rng = NeuralLcg(state: seed)
        func blobs(_ image: NeuralImage, density: Float, components: Int) -> NeuralImage {
            var result = image
            for y in 0..<result.height {
                for x in 0..<result.width where rng.chance(density) {
                    var pixel = SIMD4<UInt8>(0, 0, 0, 0)
                    for component in 0..<components where rng.chance(0.55) { pixel[component] = rng.byte() }
                    result.setPixel(x: x, y: y, pixel)
                }
            }
            return result
        }
        let chassis = NeuralImage(width: width, height: height) { x, y in
            let inside = x >= 4 && x < width - 4 && y >= 3 && y < height - 3
            guard inside else { return SIMD4(0, 0, 0, 0) }
            let soft = x == 4 || y == 3 || rng.chance(0.03)
            return SIMD4(rng.byte(), rng.byte(), rng.byte(), soft ? 140 : 255)
        }
        let interior = NeuralImage(width: width, height: height) { x, y in
            let inside = x >= 8 && x < width - 8 && y >= 6 && y < height - 6
            guard inside, !rng.chance(0.1) else { return SIMD4(0, 0, 0, 0) }
            return SIMD4(rng.byte(), rng.byte(), rng.byte(), 120 + UInt8(rng.pick(135)))
        }
        let glass = NeuralImage(width: width / 2, height: height / 2) { x, y in
            x > 3 && y > 2 && rng.chance(0.4) ? SIMD4(rng.byte(), rng.byte(), rng.byte(), 20 + UInt8(rng.pick(80))) : SIMD4(0, 0, 0, 0)
        }
        let blank = NeuralImage(width: width, height: height)
        let small = NeuralImage(width: max(2, width / 8), height: max(2, height / 8))
        var mask1 = blobs(blank, density: 0.05, components: 4)
        for x in 10..<(width - 10) where x % 3 != 0 { mask1.setPixel(x: x, y: height / 2, SIMD4(0, 0, 40 + UInt8(x % 200), 0)) }
        return [
            .chassis: chassis, .interior: interior, .glass: glass,
            .mask0: blobs(blank, density: 0.06, components: 4), .mask1: mask1,
            .mask2: blobs(blank, density: 0.04, components: 4),
            .bloom0: blobs(small, density: 0.35, components: 4), .bloom1: blobs(small, density: 0.35, components: 4),
            .bloom2: blobs(small, density: 0.3, components: 4),
        ]
    }

    static func table(spill: Bool = true) -> NeuralToneTable { NeuralTestWorld.table(spill: spill) }

    /// The next frame of a run: a few channels move, and now and then a whole mode starts or stops.
    static func advance(_ frame: NeuralFrame, _ rng: inout NeuralLcg) -> NeuralFrame {
        var next = frame
        next.settled = false
        for _ in 0..<rng.pick(4) {
            let channel = rng.pick(NeuralChannel.count)
            switch rng.pick(3) {
            case 0: next.intensity[channel] = rng.unit() * 1.3
            case 1: next.toneOverride[channel] = [NeuralTone.live, .attention, .danger, .quiet, .identity, nil][rng.pick(6)]
            default: break
            }
        }
        if rng.chance(0.2) { next.effort = Float(rng.pick(6)) }
        if rng.chance(0.1) { next.hollow.toggle() }
        if rng.chance(0.1) { next.rainbow.toggle() }
        if rng.chance(0.2) { next.ribs = rng.unit() * 6 }
        if rng.chance(0.2) {
            next.ripple = next.ripple == 0 ? 1 : 0
            next.active = NeuralPoint(Double(60 + rng.pick(500)), Double(40 + rng.pick(300)))
        } else if next.ripple != 0, rng.chance(0.3) {
            next.active = NeuralPoint(Double(60 + rng.pick(500)), Double(40 + rng.pick(300)))
        }
        if rng.chance(0.2) {
            next.sweepAmount = next.sweepAmount == 0 ? 0.9 : 0
            next.sweepTone = [NeuralTone.live, .attention, .quiet][rng.pick(3)]
        }
        if next.sweepAmount > 0 { next.sweep = rng.unit() }
        if rng.chance(0.08) { next.crunch = next.crunch == 0 ? rng.unit() * 0.9 + 0.05 : 0 }
        return next
    }
}

private func bytesDiffering(_ a: NeuralSurface, _ b: NeuralSurface) -> (count: Int, worst: Int) {
    var count = 0
    var worst = 0
    for index in 0..<a.bytes.count where a.bytes[index] != b.bytes[index] {
        count += 1
        worst = max(worst, abs(Int(a.bytes[index]) - Int(b.bytes[index])))
    }
    return (count, worst)
}

@Suite("Neural compositor sparse paths")
struct NeuralCompositorSparseTests {
    private static let width = 96
    private static let height = 60

    private func pair(seed: UInt64, spill: Bool = true) -> (fast: NeuralCompositor, dense: NeuralCompositor) {
        let layers = NeuralRandomWorld.layers(width: Self.width, height: Self.height, seed: seed)
        let table = NeuralRandomWorld.table(spill: spill)
        let fast = NeuralCompositor(
            assets: NeuralTestWorld.store(layers), size: (Self.width, Self.height), table: table)
        let dense = NeuralCompositor(
            assets: NeuralTestWorld.store(layers), size: (Self.width, Self.height), table: table)
        dense.denseOnly = true
        return (fast, dense)
    }

    private func expectEqual(
        _ a: NeuralSurfacePair, _ b: NeuralSurfacePair, exact: Bool, _ note: @autoclosure () -> String
    ) {
        let interior = bytesDiffering(a.interior, b.interior)
        let front = bytesDiffering(a.front, b.front)
        if exact {
            #expect(interior.count == 0 && front.count == 0, "\(note()): \(interior) \(front)")
        } else {
            #expect(interior.worst <= 1 && front.worst <= 1, "\(note()): \(interior) \(front)")
            #expect(interior.count + front.count <= 4, "\(note()): \(interior) \(front)")
        }
    }

    @Test("the encode lookup gives the byte powf would, within a tie, over the whole range")
    func encodeMatchesPow() {
        let codec = NeuralCodec.shared
        func reference(_ value: Float) -> Int {
            let clamped = min(max(value, 0), 1)
            return Int(min(max(powf(clamped, 1 / 2.2) * 255 + 0.5, 0), 255))
        }
        var mismatches = 0
        var worst = 0
        var samples = 0
        func check(_ value: Float) {
            samples += 1
            let got = Int(codec.encode(value))
            let want = reference(value)
            if got != want {
                mismatches += 1
                worst = max(worst, abs(got - want))
            }
        }
        for step in 0...400_000 { check(Float(step) / 400_000) }
        var value: Float = 1e-8
        while value < 1.2 {
            check(value)
            value *= 1.0003
        }
        for level in 1...255 {
            let edge = Float(pow((Double(level) - 0.5) / 255, 2.2))
            #expect(codec.encode(edge.nextDown) == UInt8(level - 1))
            #expect(codec.encode(edge.nextUp) == UInt8(level))
        }
        #expect(worst <= 1)
        #expect(Double(mismatches) / Double(samples) < 0.0005, "\(mismatches) of \(samples)")
        #expect(codec.encode(0) == 0 && codec.encode(1) == 255 && codec.encode(7) == 255)
        #expect(codec.encode(-3) == 0 && codec.encode(1e-30) == 0)
        _ = codec.encode(.nan)
        _ = codec.encode(.infinity)
    }

    @Test("the row of an index is the integer division's, at every width in use")
    func rowOfIndex() {
        for (width, height) in [(64, 40), (760, 499), (1536, 1008), (3072, 2016), (4096, 2700), (1, 5), (7, 9)] {
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: 1)
            let bitsStorage = UnsafeMutablePointer<UInt16>.allocate(capacity: 1)
            defer {
                pointer.deallocate()
                bitsStorage.deallocate()
            }
            let source = UnsafePointer(pointer)
            let codec = NeuralCodec.shared
            let layers = NeuralLayerPointers(
                width: width, height: height, invWidth: 1 / Float(width), invHeight: 1 / Float(height),
                chassis: source, interior: source, glass: source, mask0: source, mask1: source, mask2: source,
                bloom0: source, bloom1: source, bloom2: source, base: source, frontRest: source,
                bits: UnsafePointer(bitsStorage), blocks: source,
                blockColumns: 1, zoneOf: nil, linear: UnsafePointer(codec.linear), thresholds: UnsafePointer(codec.thresholds),
                steps: UnsafePointer(codec.steps))
            var step = max(1, width * height / 400_000)
            var index = 0
            while index < width * height {
                #expect(NeuralKernels.row(of: index, layers) == index / width)
                index += step
                step = 1 + (step % 3)
            }
            for edge in stride(from: 0, to: width * height, by: width) {
                #expect(NeuralKernels.row(of: edge, layers) == edge / width)
                #expect(NeuralKernels.row(of: edge + width - 1, layers) == edge / width)
            }
        }
    }

    @Test("the lit index names exactly the channels each pixel's mask or bloom is not zero in")
    func litIndexMatchesLayers() {
        let layers = NeuralRandomWorld.layers(width: Self.width, height: Self.height, seed: 11)
        let composite = NeuralCompositor(
            assets: NeuralTestWorld.store(layers), size: (Self.width, Self.height), table: NeuralRandomWorld.table())
        let index = composite.sparseIndex
        func resized(_ name: NeuralAssetName) -> NeuralImage {
            layers[name]!.resized(width: Self.width, height: Self.height)
        }
        let masks = [resized(.mask0), resized(.mask1), resized(.mask2)]
        let blooms = [resized(.bloom0), resized(.bloom1), resized(.bloom2)]
        let interior = resized(.interior)
        var interiorLit = 0
        var frontLit = 0
        for y in 0..<Self.height {
            for x in 0..<Self.width {
                var expected: UInt16 = 0
                for set in 0..<3 {
                    let mask = masks[set].pixel(x: x, y: y)
                    let bloom = blooms[set].pixel(x: x, y: y)
                    for component in 0..<4 where mask[component] != 0 || bloom[component] != 0 {
                        expected |= UInt16(1) << UInt16(set * 4 + component)
                    }
                }
                if interior.pixel(x: x, y: y).w != 0 { expected |= NeuralLitIndex.alphaBit }
                #expect(index.bits[y * Self.width + x] == expected)
                if expected & NeuralLitIndex.interiorChannels != 0 { interiorLit += 1 }
                if expected & NeuralLitIndex.frontChannels != 0 { frontLit += 1 }
            }
        }
        #expect(index.interiorLit.count == interiorLit && interiorLit > 0)
        #expect(index.frontLit.count == frontLit && frontLit > 0)
        for mask: UInt16 in [0x0008, 0x0208, 0x0048, 0x10FF, 0x0F00] {
            let list = index.list(mask: mask)
            var previous = -1
            for position in 0..<list.count {
                let pixel = Int(list.indices[position])
                #expect(pixel > previous)
                previous = pixel
                #expect(index.bits[pixel] & mask != 0)
            }
            var expected = 0
            for pixel in 0..<(Self.width * Self.height) where index.bits[pixel] & mask != 0 { expected += 1 }
            #expect(list.count == expected)
        }
        let without = index.list(mask: 0x00FF, excluding: NeuralLitIndex.linkChannel)
        for position in 0..<without.count {
            #expect(index.bits[Int(without.indices[position])] & NeuralLitIndex.linkChannel == 0)
        }
        #expect(without.count + index.link.count >= index.interiorLit.count)
        let ranks = composite.fibreRanksForTesting
        #expect(ranks.count == composite.fibrePixels.count && ranks.count > 0)
        for position in 0..<ranks.count {
            #expect(Int(index.link.indices[Int(ranks.indices[position])]) == composite.fibrePixels[position])
        }
    }

    @Test("a full render from the rest pictures and lit lists equals the shader's every-pixel answer")
    func fullFastEqualsDense() {
        var rng = NeuralLcg(state: 5)
        for seed in 1...4 {
            let (fast, dense) = pair(seed: UInt64(seed), spill: seed != 3)
            var frame = NeuralFrame()
            for step in 0..<14 {
                frame = NeuralRandomWorld.advance(frame, &rng)
                if step == 0 { frame = NeuralFrame() }
                let time = Float(step) * 0.37
                let exact = frame.sweepAmount == 0
                expectEqual(
                    fast.renderFull(frame, time: time), dense.renderFull(frame, time: time), exact: exact,
                    "seed \(seed) step \(step)")
            }
        }
    }

    @Test("a compaction's crunch, alone and with the sweep, draws what the every-pixel path draws")
    func crunchFastEqualsDense() {
        for seed in 1...3 {
            let (fast, dense) = pair(seed: UInt64(seed) + 50, spill: seed != 2)
            var fastPair = fast.makeSurfacePair()
            var densePair = dense.makeSurfacePair()
            var previous: NeuralFrame?
            for step in 0..<24 {
                var frame = NeuralFrame()
                frame.settled = false
                frame.crunch = step < 3 ? 0 : Float(0.5 - 0.5 * cos(Double(step) * 0.5))
                frame.intensity[NeuralChannel.seam.rawValue] = 0.3 + 0.7 * frame.crunch
                if step % 2 == 0 {
                    frame.sweepAmount = 0.9
                    frame.sweep = Float(step) / 24
                    frame.sweepTone = .attention
                }
                if step % 5 == 4 { frame.ripple = 1; frame.active = NeuralPoint(300, 180) }
                let time = Float(step) * 0.2
                if previous == nil || step % 9 == 0 {
                    fast.renderFull(frame, time: time, into: &fastPair)
                    dense.renderFull(frame, time: time, into: &densePair)
                } else {
                    fast.renderDelta(frame, previous: previous, into: &fastPair, time: time)
                    dense.renderDelta(frame, previous: previous, into: &densePair, time: time)
                }
                expectEqual(fastPair, densePair, exact: false, "seed \(seed) step \(step) crunch \(frame.crunch)")
                previous = frame
            }
        }
    }

    @Test("a dive's full frames and a delta that holds the dive equal the every-pixel answer")
    func diveFastEqualsDense() {
        var rng = NeuralLcg(state: 9)
        let (fast, dense) = pair(seed: 21)
        var frame = NeuralFrame()
        var fastPair = fast.makeSurfacePair()
        var densePair = dense.makeSurfacePair()
        let dives = [
            NeuralDive(), NeuralDive(fade: 0.6), NeuralDive(chassisScale: 1.4, glassScale: 1.7, fade: 0.8),
            NeuralDive(chassisScale: 1.4, glassScale: 1.7, fade: 0.8), NeuralDive(center: NeuralPoint(0.3, 0.6), chassisScale: 2, glassScale: 2.5, fade: 0.3),
            NeuralDive(), NeuralDive(),
        ]
        var previous: NeuralFrame?
        for (step, dive) in dives.enumerated() {
            frame = NeuralRandomWorld.advance(frame, &rng)
            frame.sweepAmount = 0
            frame.crunch = 0
            let time = Float(step) * 0.2
            fast.renderDelta(frame, previous: previous, into: &fastPair, dive: dive, time: time)
            dense.renderDelta(frame, previous: previous, into: &densePair, dive: dive, time: time)
            expectEqual(fastPair, densePair, exact: frame.ripple == 0, "dive step \(step)")
            previous = frame
        }
    }

    @Test("a run of deltas leaves the same surfaces as redrawing every pixel of each dirty region")
    func deltaFastEqualsDense() {
        for seed in 1...6 {
            var rng = NeuralLcg(state: UInt64(seed) * 77)
            let (fast, dense) = pair(seed: UInt64(seed) + 30, spill: seed % 2 == 0)
            var frame = NeuralRandomWorld.advance(NeuralFrame(), &rng)
            frame.crunch = 0
            var fastPair = fast.makeSurfacePair()
            var densePair = dense.makeSurfacePair()
            fast.renderFull(frame, into: &fastPair)
            dense.renderFull(frame, into: &densePair)
            for step in 1...40 {
                let next = NeuralRandomWorld.advance(frame, &rng)
                let time = Float(step) * 0.11
                let before = fastPair
                let region = fast.dirtyRegion(for: next, previous: frame)
                fast.renderDelta(next, previous: frame, into: &fastPair, time: time)
                dense.renderDelta(next, previous: frame, into: &densePair, time: time)
                let exact = next.ripple == 0 && frame.ripple == 0 && next.sweepAmount == 0 && frame.sweepAmount == 0
                expectEqual(fastPair, densePair, exact: exact, "seed \(seed) step \(step)")
                assertOnlyInside(region: region, ripple: next.ripple != 0 || frame.ripple != 0, fast: fast, before: before, after: fastPair, "seed \(seed) step \(step)")
                frame = next
                if step % 13 == 0 {
                    fast.renderFull(frame, time: time, into: &fastPair)
                    dense.renderFull(frame, time: time, into: &densePair)
                }
            }
        }
    }

    private func assertOnlyInside(
        region: NeuralRegion, ripple: Bool, fast: NeuralCompositor, before: NeuralSurfacePair,
        after: NeuralSurfacePair, _ note: String
    ) {
        let fibres = Set(fast.fibrePixels)
        for y in 0..<Self.height {
            for x in 0..<Self.width {
                let offset = (y * Self.width + x) * 4
                let moved =
                    before.interior.bytes[offset..<(offset + 4)] != after.interior.bytes[offset..<(offset + 4)]
                    || before.front.bytes[offset..<(offset + 4)] != after.front.bytes[offset..<(offset + 4)]
                if moved {
                    #expect(
                        region.contains(x: x, y: y) || (ripple && fibres.contains(y * Self.width + x)),
                        "\(note): pixel \(x),\(y) moved outside the region")
                }
            }
        }
    }

    @Test("a delta that changes nothing a channel lights leaves the surfaces alone")
    func quietDeltaTouchesNothing() {
        let (fast, _) = pair(seed: 3)
        var first = NeuralFrame()
        first.settled = false
        var pair = fast.renderFull(first)
        let snapshot = pair
        var second = first
        second.effort = first.effort
        fast.renderDelta(second, previous: first, into: &pair)
        #expect(pair == snapshot)
        var moved = first
        moved.intensity[3] = 0.9
        fast.renderDelta(moved, previous: first, into: &pair)
        #expect(pair != snapshot)
        #expect(pair.front == snapshot.front)
    }

    @Test("an explicit region and sparse list draw what they name, and a smaller region than the change draws less")
    func explicitRegionAndSparse() {
        let (fast, dense) = pair(seed: 8)
        var first = NeuralFrame()
        first.settled = false
        var second = first
        second.intensity[0] = 1.1
        second.intensity[5] = 0.1
        second.ribs = 3
        var fastPair = fast.renderFull(first)
        var densePair = dense.renderFull(first)
        let region = NeuralRegion(minX: 10, minY: 8, maxX: 60, maxY: 40)
        let sparse = Array(fast.fibrePixels.prefix(9)) + [3, 77]
        fast.renderDelta(second, previous: first, into: &fastPair, region: region, sparse: sparse)
        dense.renderDelta(second, previous: first, into: &densePair, region: region, sparse: sparse)
        expectEqual(fastPair, densePair, exact: true, "explicit")
        var empty = fast.renderFull(first)
        fast.renderDelta(second, previous: first, into: &empty, region: .empty, sparse: [])
        #expect(empty == fast.renderFull(first))
    }

    @Test("a ripple's phase table gives the sine the shader's formula does")
    func rippleFieldPhases() {
        let (fast, _) = pair(seed: 14)
        var frame = NeuralFrame()
        frame.settled = false
        frame.ripple = 1
        frame.active = NeuralPoint(250, 130)
        _ = fast.renderFull(frame, time: 2.5)
        let field = fast.rippleFieldForTesting(actX: Float(250.0 / NeuralDesign.width), actY: Float(130.0 / NeuralDesign.height))
        let link = fast.sparseIndex.link
        #expect(field.count == link.count && link.count > 0)
        let aspect = Float(Self.width) / Float(Self.height)
        for position in stride(from: 0, to: link.count, by: 7) {
            let index = Int(link.indices[position])
            let x = index % Self.width
            let y = index / Self.width
            let dx = ((Float(x) + 0.5) / Float(Self.width) - Float(250.0 / NeuralDesign.width)) * aspect
            let dy = (Float(y) + 0.5) / Float(Self.height) - Float(130.0 / NeuralDesign.height)
            let phase = (dx * dx + dy * dy).squareRoot() * 38
            #expect(abs(field.sine[position] - sinf(phase)) < 3e-5)
            #expect(abs(field.cosine[position] - cosf(phase)) < 3e-5)
            let angle = Double(2.5) * 3.2
            let combined = field.sine[position] * Float(cos(angle)) - field.cosine[position] * Float(sin(angle))
            #expect(abs(combined - sinf(phase - 2.5 * 3.2)) < 1e-4)
        }
    }

    @Test("a pass over a few thousand pixels runs on the calling thread whatever the worker cap says")
    func smallPassesStayOnOneThread() {
        let saved = (NeuralParallelism.maximumWorkers, NeuralParallelism.minimumRows)
        defer { (NeuralParallelism.maximumWorkers, NeuralParallelism.minimumRows) = saved }
        NeuralParallelism.maximumWorkers = 8
        NeuralParallelism.minimumRows = 4
        let lock = NSLock()
        nonisolated(unsafe) var ranges: [Range<Int>] = []
        NeuralParallel.rows(0..<50_000, minimumPerChunk: 64, minimumPerWorker: 100_000) { range in
            lock.lock()
            ranges.append(range)
            lock.unlock()
        }
        #expect(ranges == [0..<50_000])
        ranges.removeAll()
        NeuralParallel.rows(0..<1_000_000, minimumPerChunk: 64, minimumPerWorker: 100_000) { range in
            lock.lock()
            ranges.append(range)
            lock.unlock()
        }
        #expect(ranges.count > 1)
        #expect(ranges.reduce(0) { $0 + $1.count } == 1_000_000)
    }

    @Test("the footprint counts the rest picture, the index and the ripple tables")
    func footprintGrows() {
        let (fast, _) = pair(seed: 4)
        let before = fast.memoryFootprint
        var frame = NeuralFrame()
        frame.settled = false
        frame.ripple = 1
        frame.active = NeuralPoint(100, 100)
        _ = fast.renderFull(frame)
        #expect(fast.memoryFootprint > before)
        #expect(before >= Self.width * Self.height * 4 * 12)
    }
}
