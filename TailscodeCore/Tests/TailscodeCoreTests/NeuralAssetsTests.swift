import Foundation
import Testing

@testable import TailscodeCore

private final class LoadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var loads: [String: Int] = [:]

    func note(_ name: String) {
        lock.lock()
        loads[name, default: 0] += 1
        lock.unlock()
    }

    func count(_ name: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return loads[name] ?? 0
    }

    var total: Int {
        lock.lock()
        defer { lock.unlock() }
        return loads.values.reduce(0, +)
    }
}

@Suite("Neural assets")
struct NeuralAssetsTests {
    @Test("an image survives the raw hand-over format")
    func rawRoundTrip() throws {
        let image = NeuralImage(width: 5, height: 3) { x, y in
            SIMD4(UInt8(x * 40), UInt8(y * 80), UInt8(x * y), 255 - UInt8(x))
        }
        let decoded = try #require(NeuralImage(rawData: image.rawData()))
        #expect(decoded == image)
        #expect(Array(image.rawData().prefix(4)) == Array("NTRG".utf8))
    }

    @Test("a raw image that is short, long or mislabelled is nil")
    func rawRejects() {
        let good = NeuralImage(width: 2, height: 2).rawData()
        #expect(NeuralImage(rawData: Data()) == nil)
        #expect(NeuralImage(rawData: good.prefix(good.count - 1)) == nil)
        #expect(NeuralImage(rawData: good + Data([0])) == nil)
        var badMagic = good
        badMagic[0] = 0x58
        #expect(NeuralImage(rawData: badMagic) == nil)
        var zeroWidth = good
        zeroWidth[4] = 0
        #expect(NeuralImage(rawData: zeroWidth) == nil)
        var huge = Data("NTRG".utf8)
        huge.append(contentsOf: [0xff, 0xff, 0xff, 0x7f, 0xff, 0xff, 0xff, 0x7f])
        #expect(NeuralImage(rawData: huge) == nil)
    }

    @Test("the checked initialiser refuses bytes of the wrong length")
    func checkedInit() {
        #expect(NeuralImage(width: 2, height: 2, bytes: [UInt8](repeating: 0, count: 15)) == nil)
        #expect(NeuralImage(width: 2, height: 2, bytes: [UInt8](repeating: 0, count: 16)) != nil)
    }

    @Test("pixel access clamps to the edge")
    func pixelClamps() {
        let image = NeuralImage(width: 2, height: 2) { x, y in SIMD4(UInt8(x), UInt8(y), 7, 255) }
        #expect(image.pixel(x: -4, y: -4) == SIMD4(0, 0, 7, 255))
        #expect(image.pixel(x: 9, y: 9) == SIMD4(1, 1, 7, 255))
        #expect(image.pixel(x: 1, y: 0) == SIMD4(1, 0, 7, 255))
    }

    @Test("the bilinear sampler reads a pixel at its centre and the mean between two")
    func bilinear() {
        let image = NeuralImage(width: 2, height: 1) { x, _ in
            x == 0 ? SIMD4(0, 100, 200, 255) : SIMD4(200, 0, 100, 255)
        }
        let left = image.sample(u: 0.25, t: 0.5)
        #expect(abs(left.x - 0) < 1e-5)
        #expect(abs(left.y - 100.0 / 255) < 1e-5)
        let middle = image.sample(u: 0.5, t: 0.5)
        #expect(abs(middle.x - 100.0 / 255) < 1e-5)
        #expect(abs(middle.z - 150.0 / 255) < 1e-5)
        let outside = image.sample(u: 5, t: -3)
        #expect(abs(outside.x - 200.0 / 255) < 1e-5)
    }

    @Test("shrinking takes the box average of what each pixel covers")
    func boxFilter() {
        let image = NeuralImage(width: 4, height: 2) { x, y in
            SIMD4(UInt8(x * 20 + y * 40), 100, 0, 255)
        }
        let shrunk = image.resized(width: 2, height: 1)
        #expect(shrunk.width == 2 && shrunk.height == 1)
        let left = shrunk.pixel(x: 0, y: 0)
        let right = shrunk.pixel(x: 1, y: 0)
        #expect(left.x == 30)
        #expect(right.x == 70)
        #expect(left.y == 100 && left.w == 255)
    }

    @Test("a fractional shrink weights by coverage and keeps a constant constant")
    func fractionalShrink() {
        let flat = NeuralImage(width: 7, height: 5) { _, _ in SIMD4(90, 40, 200, 255) }
        let shrunk = flat.resized(width: 3, height: 2)
        for y in 0..<2 {
            for x in 0..<3 {
                #expect(shrunk.pixel(x: x, y: y) == SIMD4(90, 40, 200, 255))
            }
        }
    }

    @Test("growing filters bilinearly, so a constant stays constant and a ramp stays a ramp")
    func upscale() {
        let ramp = NeuralImage(width: 2, height: 1) { x, _ in SIMD4(x == 0 ? 0 : 200, 50, 50, 255) }
        let grown = ramp.resized(width: 8, height: 3)
        #expect(grown.width == 8 && grown.height == 3)
        #expect(grown.pixel(x: 0, y: 1).x == 0)
        #expect(grown.pixel(x: 7, y: 1).x == 200)
        var previous: UInt8 = 0
        for x in 0..<8 {
            let value = grown.pixel(x: x, y: 1).x
            #expect(value >= previous)
            previous = value
            #expect(grown.pixel(x: x, y: 1).y == 50)
        }
        #expect(ramp.resized(width: 2, height: 1) == ramp)
    }

    @Test("resizing an image to the same size is the identity and a zero size is empty")
    func resizeEdges() {
        let image = NeuralImage(width: 3, height: 3) { x, y in SIMD4(UInt8(x), UInt8(y), 0, 255) }
        #expect(image.resized(width: 3, height: 3) == image)
        #expect(image.resized(width: 0, height: 4).byteCount == 0)
    }

    @Test("the packing table puts twelve channels in three masks and leaves the visor out")
    func packing() {
        var seen = Set<NeuralChannel>()
        for channel in NeuralChannel.allCases {
            guard let slot = NeuralChannelPacking.slot(for: channel) else {
                #expect(channel == .visor)
                continue
            }
            #expect(NeuralChannelPacking.channel(mask: slot.mask, component: slot.component) == channel)
            seen.insert(channel)
        }
        #expect(seen.count == 12)
        #expect(NeuralChannelPacking.slot(for: .think) == .init(mask: 0, component: 0))
        #expect(NeuralChannelPacking.slot(for: .shell) == .init(mask: 0, component: 3))
        #expect(NeuralChannelPacking.slot(for: .delegate) == .init(mask: 1, component: 0))
        #expect(NeuralChannelPacking.slot(for: .link) == .init(mask: 1, component: 2))
        #expect(NeuralChannelPacking.slot(for: .seam) == .init(mask: 2, component: 0))
        #expect(NeuralChannelPacking.slot(for: .ear) == .init(mask: 2, component: 3))
        #expect(NeuralChannelPacking.channel(mask: 3, component: 0) == nil)
    }

    @Test("the nine layers have the sizes and formats the packing script writes")
    func names() {
        #expect(NeuralAssetName.allCases.count == 9)
        #expect(NeuralAssetName.chassis.width == 1536 && NeuralAssetName.chassis.height == 1008)
        #expect(NeuralAssetName.interior.width == 1536)
        #expect(NeuralAssetName.glass.width == 768 && NeuralAssetName.glass.height == 504)
        #expect(NeuralAssetName.bloom1.width == 192 && NeuralAssetName.bloom1.height == 126)
        #expect(NeuralAssetName.mask2.width == 1536)
        #expect(NeuralAssetName.chassis.pixelFormat == .astc4x4)
        #expect(NeuralAssetName.glass.pixelFormat == .astc6x6)
        #expect(NeuralAssetName.mask0.decodedFormat == .rgba8)
        #expect(NeuralAssetName.mask(1) == .mask1 && NeuralAssetName.bloom(2) == .bloom2)
    }

    @Test("a store decodes once while held and drops everything on the last release")
    func retainAndRelease() throws {
        let counter = LoadCounter()
        let raw = NeuralImage(width: 4, height: 4).rawData()
        let store = NeuralAssetStore { name in
            counter.note(name)
            return name == "missing" ? nil : raw
        }
        store.retain()
        store.retain()
        #expect(store.retainCount == 2)
        let first = try #require(store.image(named: .chassis))
        _ = store.image(named: .chassis)
        #expect(counter.count("chassis") == 1)
        #expect(first.width == 4)
        #expect(store.isResident)
        #expect(store.residentBytes == 64)
        store.release()
        #expect(store.isResident)
        store.release()
        #expect(store.retainCount == 0)
        #expect(!store.isResident)
        #expect(store.residentBytes == 0)
        _ = store.image(named: .chassis)
        #expect(counter.count("chassis") == 2)
        #expect(!store.isResident)
        store.release()
        #expect(store.retainCount == 0)
    }

    @Test("a store with nothing to load says so rather than inventing a layer")
    func unavailable() {
        let store = NeuralAssetStore { _ in nil }
        #expect(store.image(named: .glass) == nil)
        let garbage = NeuralAssetStore { _ in Data([1, 2, 3]) }
        #expect(garbage.image(named: .glass) == nil)
        #expect(NeuralAssetStore.shared.image(named: .chassis) == nil)
    }

    @Test("prepare decodes every layer off the caller's thread and reports completeness")
    func prepare() async {
        let counter = LoadCounter()
        let raw = NeuralImage(width: 2, height: 2).rawData()
        let store = NeuralAssetStore { name in
            counter.note(name)
            return raw
        }
        store.retain()
        let complete = await store.prepare()
        #expect(complete)
        #expect(counter.total == 9)
        #expect(store.residentBytes == 9 * 16)
        _ = await store.prepare()
        #expect(counter.total == 9)
        store.release()
        #expect(!store.isResident)

        let partial = NeuralAssetStore { name in name == "glass" ? nil : raw }
        partial.retain()
        #expect(await partial.prepare() == false)
        partial.release()
    }

    @Test("configuring a store replaces its loader and drops what the old one decoded")
    func configure() throws {
        let store = NeuralAssetStore { _ in NeuralImage(width: 2, height: 2).rawData() }
        store.retain()
        #expect(try #require(store.image(named: .interior)).width == 2)
        store.configure { _ in NeuralImage(width: 3, height: 3).rawData() }
        #expect(!store.isResident)
        #expect(try #require(store.image(named: .interior)).width == 3)
        store.release()
    }
}
