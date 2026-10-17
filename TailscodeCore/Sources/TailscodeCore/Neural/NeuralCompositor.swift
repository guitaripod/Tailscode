import Dispatch
import Foundation

/// A premultiplied BGRA, 8-bit picture, rows from the top: what a cairo `ARGB32` surface or a
/// `CGImage` with premultiplied-first little-endian takes without a conversion.
public struct NeuralSurface: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public var bytes: [UInt8]

    public init(width: Int, height: Int) {
        self.width = max(0, width)
        self.height = max(0, height)
        self.bytes = [UInt8](repeating: 0, count: self.width * self.height * 4)
    }

    public var bytesPerRow: Int { width * 4 }
}

/// What the two shader passes produce: the interior, opaque, and the front (chassis, glow and
/// glass), premultiplied, laid over it.
public struct NeuralSurfacePair: Sendable, Equatable {
    public var interior: NeuralSurface
    public var front: NeuralSurface

    public init(width: Int, height: Int) {
        interior = NeuralSurface(width: width, height: height)
        front = NeuralSurface(width: width, height: height)
    }
}

/// The dive: the front layers scaled about a centre while they fade. `center` is normalised across
/// the picture with y down, `chassisScale` and `glassScale` are the shader's `uSc` and `uSg`, and
/// `fade` its `uFade`.
public struct NeuralDive: Sendable, Equatable {
    public var center: NeuralPoint
    public var chassisScale: Float
    public var glassScale: Float
    public var fade: Float

    public init(center: NeuralPoint = NeuralPoint(0.5, 0.5), chassisScale: Float = 1, glassScale: Float = 1, fade: Float = 1) {
        self.center = center
        self.chassisScale = chassisScale
        self.glassScale = glassScale
        self.fade = fade
    }

    public static let none = NeuralDive()

    /// Whether the front layers sit where they were drawn, so a delta may rely on their pixels.
    public var isStill: Bool { chassisScale == 1 && glassScale == 1 }
}

/// A rectangle of output pixels, `minX..<maxX` by `minY..<maxY`.
public struct NeuralRegion: Sendable, Equatable {
    public var minX: Int
    public var minY: Int
    public var maxX: Int
    public var maxY: Int

    public init(minX: Int, minY: Int, maxX: Int, maxY: Int) {
        self.minX = minX
        self.minY = minY
        self.maxX = maxX
        self.maxY = maxY
    }

    public static let empty = NeuralRegion(minX: 0, minY: 0, maxX: 0, maxY: 0)

    public var isEmpty: Bool { maxX <= minX || maxY <= minY }
    public var width: Int { max(0, maxX - minX) }
    public var height: Int { max(0, maxY - minY) }
    public var area: Int { width * height }

    public func union(_ other: NeuralRegion) -> NeuralRegion {
        if isEmpty { return other }
        if other.isEmpty { return self }
        return NeuralRegion(
            minX: min(minX, other.minX), minY: min(minY, other.minY), maxX: max(maxX, other.maxX),
            maxY: max(maxY, other.maxY))
    }

    public func clamped(width: Int, height: Int) -> NeuralRegion {
        let clipped = NeuralRegion(
            minX: min(max(minX, 0), width), minY: min(max(minY, 0), height),
            maxX: min(max(maxX, 0), width), maxY: min(max(maxY, 0), height))
        return clipped.isEmpty ? .empty : clipped
    }

    public func contains(x: Int, y: Int) -> Bool {
        x >= minX && x < maxX && y >= minY && y < maxY
    }
}

/// Every colour the compositor blends, in linear light, resolved from a palette once so a frame
/// only names tones and the compositor looks them up.
public struct NeuralToneTable: Sendable, Equatable {
    /// The thirteen channel colours, in `NeuralChannel` order.
    public var channels: [NeuralRGB]
    public var live: NeuralRGB
    public var attention: NeuralRGB
    public var danger: NeuralRGB
    public var quiet: NeuralRGB
    public var identity: NeuralRGB
    /// The page behind the head, in linear light.
    public var background: NeuralRGB
    /// Whether the glow may spill past the chassis: false on a light palette.
    public var spill: Bool

    public init(
        channels: [NeuralRGB], live: NeuralRGB, attention: NeuralRGB, danger: NeuralRGB,
        quiet: NeuralRGB, identity: NeuralRGB, background: NeuralRGB, spill: Bool
    ) {
        var padded = channels
        while padded.count < NeuralChannel.count { padded.append(NeuralRGB(0, 0, 0)) }
        self.channels = Array(padded.prefix(NeuralChannel.count))
        self.live = live
        self.attention = attention
        self.danger = danger
        self.quiet = quiet
        self.identity = identity
        self.background = background
        self.spill = spill
    }

    /// From thirteen channel colours alone: the state tones are the matrix theme's, the identity
    /// is the eye's own colour, and the page is that theme's near-black.
    public init(tones: [NeuralRGB], spill: Bool, background: NeuralRGB? = nil) {
        let eye = tones.count > 9 ? tones[9] : NeuralRGB(0.15, 1.0, 0.5)
        self.init(
            channels: tones, live: Self.linear(hex: 0x39ff88), attention: Self.linear(hex: 0xf2c14e),
            danger: Self.linear(hex: 0xff5c7a), quiet: Self.linear(hex: 0x89be9b), identity: eye,
            background: background ?? Self.linear(hex: 0x030806), spill: spill)
    }

    /// From the app's palette and the model that answered.
    public init(palette: Palette, face: NeuralFace) {
        self.init(
            channels: NeuralPalette.channelTones(palette: palette, face: face),
            live: NeuralPalette.glow(.live, palette: palette, face: face),
            attention: NeuralPalette.glow(.attention, palette: palette, face: face),
            danger: NeuralPalette.glow(.danger, palette: palette, face: face),
            quiet: NeuralPalette.glow(.quiet, palette: palette, face: face),
            identity: NeuralPalette.glow(.identity, palette: palette, face: face),
            background: NeuralPalette.canvas(palette: palette),
            spill: NeuralPalette.spill(palette: palette))
    }

    public func color(for tone: NeuralTone) -> NeuralRGB {
        switch tone {
        case .live: return live
        case .attention: return attention
        case .danger: return danger
        case .quiet: return quiet
        case .identity: return identity
        }
    }

    static func linear(hex: Int) -> NeuralRGB {
        func channel(_ shift: Int) -> Float { powf(Float((hex >> shift) & 0xff) / 255, 2.2) }
        return NeuralRGB(channel(16), channel(8), channel(0))
    }
}

/// The CPU renderer of the head: the reference for the shader, the golden for the tests, the
/// painter for posters and the live renderer on Linux, where an animating GL area leaks. It
/// computes exactly what `FS_INT` and `FS_FRONT` in `hero2.js` compute, in Float, into BGRA
/// premultiplied surfaces.
///
/// Every layer is resampled once to the output size, so a frame at rest reads one pixel from each
/// layer. A frame that changes only the active zone, the eye and the fibres is drawn by
/// ``renderDelta(_:previous:into:region:sparse:dive:time:)`` into the surfaces the last frame left.
///
/// Where the shader's premultiplied output would put a colour above its own alpha (it gamma-encodes
/// premultiplied light), the alpha is raised to the largest colour channel so the surface is a
/// valid premultiplied one for cairo and Core Graphics.
public final class NeuralCompositor: @unchecked Sendable {
    private let lock = NSLock()
    private let assets: NeuralAssetStore
    private var layers: NeuralLayers
    private var table: NeuralToneTable
    private var lastFrame: NeuralFrame?
    private var lastDive: NeuralDive?
    private var lastTime: Float = 0

    /// Holds one retain on `assets` for its lifetime, so the decoded layers stay for a resize.
    public init(assets: NeuralAssetStore, size: (width: Int, height: Int), table: NeuralToneTable) {
        self.assets = assets
        self.table = table
        assets.retain()
        layers = NeuralLayers(
            assets: assets, width: max(1, size.width), height: max(1, size.height),
            background: table.background)
    }

    public convenience init(
        assets: NeuralAssetStore, size: (width: Int, height: Int), tones: [NeuralRGB], spill: Bool
    ) {
        self.init(
            assets: assets, size: size, table: NeuralToneTable(tones: tones, spill: spill))
    }

    public convenience init(
        assets: NeuralAssetStore, size: (width: Int, height: Int), palette: Palette, face: NeuralFace
    ) {
        self.init(assets: assets, size: size, table: NeuralToneTable(palette: palette, face: face))
    }

    deinit { assets.release() }

    public var size: (width: Int, height: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (layers.width, layers.height)
    }

    /// False when a layer the head needs could not be loaded; the missing ones draw as blank.
    public var isComplete: Bool {
        lock.lock()
        defer { lock.unlock() }
        return layers.complete
    }

    /// What the resampled layers, the rest picture and the fibre list hold, in bytes.
    public var memoryFootprint: Int {
        lock.lock()
        defer { lock.unlock() }
        return layers.footprint
    }

    /// Pixel indices (`y * width + x`) of the fibres: where the link channel is at least 2/255.
    /// These are the only pixels a ripple-only frame has to redraw.
    public var fibrePixels: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return layers.fibres
    }

    public func makeSurfacePair() -> NeuralSurfacePair {
        lock.lock()
        defer { lock.unlock() }
        return NeuralSurfacePair(width: layers.width, height: layers.height)
    }

    /// Resamples the layers to a new output size. The next frame must be a full one.
    public func setSize(width: Int, height: Int) {
        lock.lock()
        defer { lock.unlock() }
        guard width != layers.width || height != layers.height else { return }
        layers = NeuralLayers(
            assets: assets, width: max(1, width), height: max(1, height), background: table.background)
        lastFrame = nil
        lastDive = nil
    }

    /// A new palette or face. The next frame must be a full one.
    public func setTable(_ newTable: NeuralToneTable) {
        lock.lock()
        defer { lock.unlock() }
        guard newTable != table else { return }
        if newTable.background != table.background { layers.rebuildBase(background: newTable.background) }
        table = newTable
        lastFrame = nil
        lastDive = nil
    }

    /// Whether drawing `frame` would change anything: not when it is settled and is the frame
    /// already on the surfaces, at the same dive.
    public func needsRender(_ frame: NeuralFrame, dive: NeuralDive = .none) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let lastFrame, let lastDive else { return true }
        return !(frame.settled && frame == lastFrame && dive == lastDive)
    }

    /// The whole picture. `time` is the clock the ripple and the rainbow read, in seconds.
    public func renderFull(_ frame: NeuralFrame, dive: NeuralDive = .none, time: Float = 0)
        -> NeuralSurfacePair
    {
        var pair = makeSurfacePair()
        renderFull(frame, dive: dive, time: time, into: &pair)
        return pair
    }

    /// The whole picture into surfaces made by ``makeSurfacePair()``, with no allocation.
    public func renderFull(
        _ frame: NeuralFrame, dive: NeuralDive = .none, time: Float = 0, into pair: inout NeuralSurfacePair
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard matches(pair) else { return }
        let whole = NeuralRegion(minX: 0, minY: 0, maxX: layers.width, maxY: layers.height)
        draw(frame, dive: dive, time: time, region: whole, sparse: [], into: &pair)
        lastFrame = frame
        lastDive = dive
        lastTime = time
    }

    /// Redraws only what changed since `previous`, into the surfaces that already show it.
    /// `region` defaults to ``dirtyRegion(for:previous:)``; `sparse` defaults to the fibre pixels
    /// when a ripple is or was running. A dive that moves the front layers redraws everything.
    public func renderDelta(
        _ frame: NeuralFrame, previous: NeuralFrame?, into pair: inout NeuralSurfacePair,
        region: NeuralRegion? = nil, sparse: [Int]? = nil, dive: NeuralDive = .none, time: Float = 0
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard matches(pair) else { return }
        var area = region ?? dirtyRegion(locked: frame, previous: previous)
        if lastDive != dive {
            area = NeuralRegion(minX: 0, minY: 0, maxX: layers.width, maxY: layers.height)
        }
        let pixels: [Int]
        if let sparse {
            pixels = sparse
        } else if frame.ripple != 0 || (previous?.ripple ?? 0) != 0 {
            pixels = layers.fibres
        } else {
            pixels = []
        }
        draw(frame, dive: dive, time: time, region: area.clamped(width: layers.width, height: layers.height), sparse: pixels, into: &pair)
        lastFrame = frame
        lastDive = dive
        lastTime = time
    }

    /// What has to be redrawn to go from `previous` to `frame`: the pixels each changed channel
    /// lights (its mask and bloom, measured from the layers, which covers the zone's well and the
    /// bloom's reach), the eye's rectangle and bloom always, and the whole dome while a sweep or a crunch is
    /// running. Nothing for a settled frame that equals its predecessor.
    public func dirtyRegion(for frame: NeuralFrame, previous: NeuralFrame?) -> NeuralRegion {
        lock.lock()
        defer { lock.unlock() }
        return dirtyRegion(locked: frame, previous: previous)
    }

    private func matches(_ pair: NeuralSurfacePair) -> Bool {
        pair.interior.width == layers.width && pair.interior.height == layers.height
            && pair.front.width == layers.width && pair.front.height == layers.height
            && pair.interior.bytes.count == layers.width * layers.height * 4
            && pair.front.bytes.count == layers.width * layers.height * 4
    }

    private func dirtyRegion(locked frame: NeuralFrame, previous: NeuralFrame?) -> NeuralRegion {
        let whole = NeuralRegion(minX: 0, minY: 0, maxX: layers.width, maxY: layers.height)
        guard let previous else { return whole }
        if frame == previous && frame.settled { return .empty }
        var region = layers.eyeRegion.union(layers.bounds[NeuralChannel.eye.rawValue])
        let moving =
            frame.sweepAmount > 0 || previous.sweepAmount > 0 || frame.crunch > 0 || previous.crunch > 0
        if moving { region = region.union(layers.domeRegion) }
        for channel in 0..<NeuralChannel.count where channel != NeuralChannel.eye.rawValue {
            if Self.changed(channel, frame, previous) { region = region.union(layers.bounds[channel]) }
        }
        return region.clamped(width: layers.width, height: layers.height)
    }

    private static func changed(_ channel: Int, _ a: NeuralFrame, _ b: NeuralFrame) -> Bool {
        if value(a.intensity, channel) != value(b.intensity, channel) { return true }
        if tone(a.toneOverride, channel) != tone(b.toneOverride, channel) { return true }
        return channel == NeuralChannel.rib.rawValue && a.ribs != b.ribs
    }

    private static func value(_ values: [Float], _ index: Int) -> Float {
        index < values.count ? values[index] : 0
    }

    private static func tone(_ values: [NeuralTone?], _ index: Int) -> NeuralTone? {
        index < values.count ? values[index] : nil
    }

    private func draw(
        _ frame: NeuralFrame, dive: NeuralDive, time: Float, region: NeuralRegion, sparse: [Int],
        into pair: inout NeuralSurfacePair
    ) {
        guard !region.isEmpty || !sparse.isEmpty else { return }
        let params = NeuralFrameParams(frame: frame, table: table, dive: dive, time: time, width: layers.width, height: layers.height)
        let pointers = layers.pointers
        pair.interior.bytes.withUnsafeMutableBufferPointer { interior in
            pair.front.bytes.withUnsafeMutableBufferPointer { front in
                let interiorOut = NeuralUnsafe(interior.baseAddress!)
                let frontOut = NeuralUnsafe(front.baseAddress!)
                if !region.isEmpty {
                    NeuralParallel.rows(region.minY..<region.maxY) { rows in
                        NeuralKernels.interior(
                            rows: rows, columns: region.minX..<region.maxX, layers: pointers, params: params,
                            out: interiorOut.pointer)
                    }
                    NeuralParallel.rows(region.minY..<region.maxY) { rows in
                        NeuralKernels.front(
                            rows: rows, columns: region.minX..<region.maxX, layers: pointers, params: params,
                            out: frontOut.pointer)
                    }
                }
                if !sparse.isEmpty {
                    let width = pointers.width
                    let inside = region
                    NeuralParallel.rows(0..<sparse.count, minimumPerChunk: 256) { range in
                        for position in range {
                            let index = sparse[position]
                            let x = index % width
                            let y = index / width
                            if inside.contains(x: x, y: y) { continue }
                            NeuralKernels.interiorPixel(
                                x: x, y: y, layers: pointers, params: params, out: interiorOut.pointer)
                        }
                    }
                }
            }
        }
    }
}

/// Pointers into the resampled layers, valid while the owning ``NeuralLayers`` is alive.
struct NeuralLayerPointers: @unchecked Sendable {
    let width: Int
    let height: Int
    let invWidth: Float
    let invHeight: Float
    let chassis: UnsafePointer<UInt8>
    let interior: UnsafePointer<UInt8>
    let glass: UnsafePointer<UInt8>
    let mask0: UnsafePointer<UInt8>
    let mask1: UnsafePointer<UInt8>
    let mask2: UnsafePointer<UInt8>
    let bloom0: UnsafePointer<UInt8>
    let bloom1: UnsafePointer<UInt8>
    let bloom2: UnsafePointer<UInt8>
    let base: UnsafePointer<UInt8>
}

/// A block of bytes the kernels read through a raw pointer.
final class NeuralPixelBuffer: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<UInt8>
    let count: Int

    init(count: Int) {
        self.count = count
        pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: max(1, count))
        pointer.initialize(repeating: 0, count: max(1, count))
    }

    convenience init(_ image: NeuralImage) {
        self.init(count: image.byteCount)
        image.bytes.withUnsafeBufferPointer { source in
            if let base = source.baseAddress, count > 0 { pointer.update(from: base, count: count) }
        }
    }

    deinit { pointer.deallocate() }
}

/// The head's layers at the output size, plus what is worked out from them once: the rest picture
/// of the interior, each channel's bounds and the fibre pixels.
final class NeuralLayers: @unchecked Sendable {
    let width: Int
    let height: Int
    let chassis: NeuralPixelBuffer
    let interior: NeuralPixelBuffer
    let glass: NeuralPixelBuffer
    let masks: [NeuralPixelBuffer]
    let blooms: [NeuralPixelBuffer]
    private(set) var base: NeuralPixelBuffer
    private(set) var complete = true
    private(set) var bounds: [NeuralRegion] = []
    private(set) var fibres: [Int] = []
    private(set) var domeRegion = NeuralRegion.empty
    private(set) var eyeRegion = NeuralRegion.empty

    init(assets: NeuralAssetStore, width: Int, height: Int, background: NeuralRGB) {
        self.width = width
        self.height = height
        var missing = false
        func layer(_ name: NeuralAssetName) -> NeuralPixelBuffer {
            guard let image = assets.image(named: name) else {
                missing = true
                return NeuralPixelBuffer(count: width * height * 4)
            }
            return NeuralPixelBuffer(image.resized(width: width, height: height))
        }
        chassis = layer(.chassis)
        interior = layer(.interior)
        glass = layer(.glass)
        masks = [layer(.mask0), layer(.mask1), layer(.mask2)]
        blooms = [layer(.bloom0), layer(.bloom1), layer(.bloom2)]
        complete = !missing
        base = NeuralPixelBuffer(count: width * height * 4)
        rebuildBase(background: background)
        measure()
    }

    var footprint: Int {
        let layerBytes = width * height * 4
        return layerBytes * 11 + fibres.count * MemoryLayout<Int>.stride
    }

    var pointers: NeuralLayerPointers {
        NeuralLayerPointers(
            width: width, height: height, invWidth: 1 / Float(width), invHeight: 1 / Float(height),
            chassis: UnsafePointer(chassis.pointer), interior: UnsafePointer(interior.pointer),
            glass: UnsafePointer(glass.pointer), mask0: UnsafePointer(masks[0].pointer),
            mask1: UnsafePointer(masks[1].pointer), mask2: UnsafePointer(masks[2].pointer),
            bloom0: UnsafePointer(blooms[0].pointer), bloom1: UnsafePointer(blooms[1].pointer),
            bloom2: UnsafePointer(blooms[2].pointer), base: UnsafePointer(base.pointer))
    }

    func rebuildBase(background: NeuralRGB) {
        let bg = SIMD3<Float>(background.r, background.g, background.b)
        let output = NeuralUnsafe(base.pointer)
        let source = NeuralConst(UnsafePointer(interior.pointer))
        let w = width
        NeuralParallel.rows(0..<height) { rows in
            for y in rows {
                for x in 0..<w {
                    let offset = (y * w + x) * 4
                    let a = Float(source.pointer[offset + 3]) * (1.0 / 255)
                    let lin = SIMD3<Float>(
                        NeuralKernels.linearTable[Int(source.pointer[offset])],
                        NeuralKernels.linearTable[Int(source.pointer[offset + 1])],
                        NeuralKernels.linearTable[Int(source.pointer[offset + 2])])
                    let mixed = bg * (1 - a) + lin * a
                    output.pointer[offset] = NeuralKernels.gammaByte(mixed.z)
                    output.pointer[offset + 1] = NeuralKernels.gammaByte(mixed.y)
                    output.pointer[offset + 2] = NeuralKernels.gammaByte(mixed.x)
                    output.pointer[offset + 3] = 255
                }
            }
        }
    }

    private func measure() {
        var minX = [Int](repeating: Int.max, count: NeuralChannel.count)
        var minY = minX
        var maxX = [Int](repeating: -1, count: NeuralChannel.count)
        var maxY = maxX
        var links: [Int] = []
        for set in 0..<3 {
            let mask = masks[set].pointer
            let bloom = blooms[set].pointer
            for y in 0..<height {
                for x in 0..<width {
                    let offset = (y * width + x) * 4
                    for component in 0..<4 {
                        let channel = set * 4 + component
                        if mask[offset + component] != 0 || bloom[offset + component] != 0 {
                            minX[channel] = min(minX[channel], x)
                            maxX[channel] = max(maxX[channel], x)
                            minY[channel] = min(minY[channel], y)
                            maxY[channel] = max(maxY[channel], y)
                        }
                    }
                    if set == 1, mask[offset + 2] >= 2 { links.append(y * width + x) }
                }
            }
        }
        fibres = links
        bounds = (0..<NeuralChannel.count).map { channel in
            guard maxX[channel] >= 0 else { return .empty }
            return NeuralRegion(
                minX: minX[channel], minY: minY[channel], maxX: maxX[channel] + 1, maxY: maxY[channel] + 1)
        }
        let sx = Double(width) / NeuralDesign.width
        let sy = Double(height) / NeuralDesign.height
        func region(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> NeuralRegion {
            NeuralRegion(
                minX: Int((x0 * sx).rounded(.down)) - 2, minY: Int((y0 * sy).rounded(.down)) - 2,
                maxX: Int((x1 * sx).rounded(.up)) + 2, maxY: Int((y1 * sy).rounded(.up)) + 2
            ).clamped(width: width, height: height)
        }
        eyeRegion = region(520, 170, 640, 260)
        let outline = NeuralDome.outline
        let xs = outline.map(\.x)
        let ys = outline.map(\.y)
        var dome = region(xs.min() ?? 0, ys.min() ?? 0, xs.max() ?? 0, ys.max() ?? 0)
        for channel in 0..<NeuralChannel.count { dome = dome.union(bounds[channel]) }
        domeRegion = dome.clamped(width: width, height: height)
    }
}

/// Everything a frame fixes before a pixel is looked at: the tone and intensity products and the
/// scalars the two passes read.
struct NeuralFrameParams: Sendable {
    var t0, t1, t2, t3, t4, t5, t6, t7: SIMD3<Float>
    var seamGain: SIMD3<Float>
    var eyeTone: SIMD3<Float>
    var eyeGain: Float
    var ribGain: SIMD3<Float>
    var earGain: SIMD3<Float>
    var sweepTone: SIMD3<Float>
    var background: SIMD3<Float>
    var sweep: Float
    var sweepAmount: Float
    var crunch: Float
    var ripple: Float
    var actX: Float
    var actY: Float
    var aspect: Float
    var time: Float
    var effort: Float
    var hollow: Bool
    var rainbow: Float
    var ribs: Float
    var spill: Float
    var fade: Float
    var chassisScale: Float
    var glassScale: Float
    var centerX: Float
    var centerY: Float
    var still: Bool
    var zones: [SIMD2<Float>]

    init(frame: NeuralFrame, table: NeuralToneTable, dive: NeuralDive, time: Float, width: Int, height: Int) {
        func intensity(_ index: Int) -> Float {
            index < frame.intensity.count ? frame.intensity[index] : 0
        }
        func tone(_ index: Int) -> SIMD3<Float> {
            let color: NeuralRGB
            if index < frame.toneOverride.count, let override = frame.toneOverride[index] {
                color = table.color(for: override)
            } else {
                color = table.channels[index]
            }
            return SIMD3(color.r, color.g, color.b)
        }
        func scaled(_ index: Int) -> SIMD3<Float> { tone(index) * intensity(index) }
        t0 = scaled(0)
        t1 = scaled(1)
        t2 = scaled(2)
        t3 = scaled(3)
        t4 = scaled(4)
        t5 = scaled(5)
        t6 = scaled(6)
        t7 = scaled(7)
        seamGain = tone(8) * (intensity(8) * 2)
        eyeTone = tone(9)
        eyeGain = intensity(9) * 4
        ribGain = tone(10) * (intensity(10) * 3)
        earGain = tone(11) * (intensity(11) * 3)
        let sweepColor = table.color(for: frame.sweepTone)
        sweepTone = SIMD3(sweepColor.r, sweepColor.g, sweepColor.b)
        background = SIMD3(table.background.r, table.background.g, table.background.b)
        sweep = frame.sweep
        sweepAmount = frame.sweepAmount
        crunch = frame.crunch
        ripple = frame.ripple
        let point = frame.active ?? NeuralPoint(NeuralDesign.width / 2, NeuralDesign.height / 2)
        actX = Float(point.x / NeuralDesign.width)
        actY = Float(point.y / NeuralDesign.height)
        aspect = Float(width) / Float(height)
        self.time = time
        effort = frame.effort
        hollow = frame.hollow
        rainbow = frame.rainbow ? 1 : 0
        ribs = frame.ribs
        spill = table.spill ? 1 : 0
        fade = dive.fade
        chassisScale = dive.chassisScale
        glassScale = dive.glassScale
        centerX = Float(dive.center.x)
        centerY = Float(dive.center.y)
        still = dive.isStill
        zones = NeuralZone.allCases.map {
            SIMD2(Float($0.center.x / NeuralDesign.width), Float($0.center.y / NeuralDesign.height))
        }
    }
}

/// The two shader passes, one pixel at a time.
enum NeuralKernels {
    static let linearTable: [Float] = (0..<256).map { Float(pow(Double($0) / 255, 2.2)) }

    static let inverseGamma: Float = 1 / 2.2

    @inline(__always)
    static func gammaByte(_ value: Float) -> UInt8 {
        byte(powf(min(max(value, 0), 1), inverseGamma))
    }

    @inline(__always)
    static func byte(_ value: Float) -> UInt8 {
        UInt8(min(max(value * 255 + 0.5, 0), 255))
    }

    @inline(__always)
    static func load(_ pointer: UnsafePointer<UInt8>, _ index: Int) -> SIMD4<Float> {
        SIMD4<Float>(UnsafeRawPointer(pointer).loadUnaligned(fromByteOffset: index * 4, as: SIMD4<UInt8>.self))
            * (1.0 / 255)
    }

    @inline(__always)
    static func word(_ pointer: UnsafePointer<UInt8>, _ index: Int) -> UInt32 {
        UnsafeRawPointer(pointer).loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)
    }

    @inline(__always)
    static func sample(
        _ pointer: UnsafePointer<UInt8>, _ layers: NeuralLayerPointers, _ u: Float, _ t: Float
    ) -> SIMD4<Float> {
        NeuralImage.bilinear(pointer, width: layers.width, height: layers.height, u: u, t: t)
    }

    @inline(__always)
    static func crunchUV(u: Float, t: Float, params: NeuralFrameParams) -> SIMD2<Float> {
        var best = params.zones[0]
        var nearest = Float.greatestFiniteMagnitude
        for zone in params.zones {
            let dx = (u - zone.x) * params.aspect
            let dy = t - zone.y
            let distance = dx * dx + dy * dy
            if distance < nearest {
                nearest = distance
                best = zone
            }
        }
        let scale = 1 + 0.7 * params.crunch
        return SIMD2(best.x + (u - best.x) * scale, best.y + (t - best.y) * scale)
    }

    @_optimize(speed)
    static func interior(
        rows: Range<Int>, columns: Range<Int>, layers: NeuralLayerPointers, params: NeuralFrameParams,
        out: UnsafeMutablePointer<UInt8>
    ) {
        for y in rows {
            for x in columns {
                interiorPixel(x: x, y: y, layers: layers, params: params, out: out)
            }
        }
    }

    @_optimize(speed)
    @inline(__always)
    static func interiorPixel(
        x: Int, y: Int, layers: NeuralLayerPointers, params: NeuralFrameParams,
        out: UnsafeMutablePointer<UInt8>
    ) {
        let index = y * layers.width + x
        let u = (Float(x) + 0.5) * layers.invWidth
        let t = (Float(y) + 0.5) * layers.invHeight
        var m0 = SIMD4<Float>(repeating: 0)
        var m1 = m0
        var b0 = m0
        var b1 = m0
        var lit = false
        if params.crunch > 0 {
            let warped = crunchUV(u: u, t: t, params: params)
            m0 = sample(layers.mask0, layers, warped.x, warped.y)
            m1 = sample(layers.mask1, layers, warped.x, warped.y)
            b0 = sample(layers.bloom0, layers, warped.x, warped.y)
            b1 = sample(layers.bloom1, layers, warped.x, warped.y)
            lit = true
        } else {
            let any =
                word(layers.mask0, index) | word(layers.mask1, index) | word(layers.bloom0, index)
                | word(layers.bloom1, index)
            if any != 0 {
                lit = true
                m0 = load(layers.mask0, index)
                m1 = load(layers.mask1, index)
                b0 = load(layers.bloom0, index)
                b1 = load(layers.bloom1, index)
            }
        }
        let dest = out + index * 4
        if !lit && params.sweepAmount <= 0 {
            UnsafeMutableRawPointer(dest).storeBytes(of: word(layers.base, index), as: UInt32.self)
            return
        }
        let rgba = UnsafeRawPointer(layers.interior).loadUnaligned(fromByteOffset: index * 4, as: SIMD4<UInt8>.self)
        let alpha = Float(rgba.w) * (1.0 / 255)
        let linear = SIMD3<Float>(
            linearTable[Int(rgba.x)], linearTable[Int(rgba.y)], linearTable[Int(rgba.z)])
        let base = params.background * (1 - alpha) + linear * alpha
        var ripple: Float = 1
        if params.ripple != 0 && (m1.z != 0 || b1.z != 0) {
            let dx = (u - params.actX) * params.aspect
            let dy = t - params.actY
            ripple = 1 + params.ripple * 0.45 * sin((dx * dx + dy * dy).squareRoot() * 38 - params.time * 3.2)
        }
        let w0 = m0 * 4 + b0 * 2
        var w1 = m1 * 4 + b1 * 2
        w1.z *= ripple
        var glow = params.t0 * w0.x + params.t1 * w0.y + params.t2 * w0.z + params.t3 * w0.w
        glow += params.t4 * w1.x + params.t5 * w1.y + params.t6 * w1.z + params.t7 * w1.w
        var added = glow
        if params.sweepAmount > 0 {
            let luma = glow.x * 0.3 + glow.y * 0.5 + glow.z * 0.2
            let phase = (u * 0.9 + (1 - t) * 0.35 - params.sweep) * 7
            let band = exp(-(phase * phase))
            added += params.sweepTone * (band * params.sweepAmount * (0.14 * alpha + min(luma * 1.2, 1)))
        }
        added = added / (SIMD3<Float>(repeating: 1) + added * 0.2)
        let lifted = added.clamped(lowerBound: SIMD3(repeating: 0), upperBound: SIMD3(repeating: 1))
        let color = SIMD3<Float>(repeating: 1) - (SIMD3<Float>(repeating: 1) - base) * (SIMD3<Float>(repeating: 1) - lifted)
        dest[0] = gammaByte(color.z)
        dest[1] = gammaByte(color.y)
        dest[2] = gammaByte(color.x)
        dest[3] = 255
    }

    @_optimize(speed)
    static func front(
        rows: Range<Int>, columns: Range<Int>, layers: NeuralLayerPointers, params: NeuralFrameParams,
        out: UnsafeMutablePointer<UInt8>
    ) {
        for y in rows {
            for x in columns {
                frontPixel(x: x, y: y, layers: layers, params: params, out: out)
            }
        }
    }

    @_optimize(speed)
    @inline(__always)
    static func frontPixel(
        x: Int, y: Int, layers: NeuralLayerPointers, params: NeuralFrameParams,
        out: UnsafeMutablePointer<UInt8>
    ) {
        let index = y * layers.width + x
        let dest = out + index * 4
        var chassis: SIMD4<Float>
        var glass: SIMD4<Float>
        var packed: SIMD4<Float>
        var u1 = (Float(x) + 0.5) * layers.invWidth
        var t1 = (Float(y) + 0.5) * layers.invHeight
        let chassisLinear: SIMD3<Float>
        let glassLinear: SIMD3<Float>
        if params.still {
            let chassisWord = word(layers.chassis, index)
            let glassWord = word(layers.glass, index)
            let maskWord = word(layers.mask2, index)
            let bloomWord = word(layers.bloom2, index)
            if (chassisWord >> 24) == 0 && (glassWord >> 24) == 0 && maskWord == 0 && bloomWord == 0 {
                UnsafeMutableRawPointer(dest).storeBytes(of: 0, as: UInt32.self)
                return
            }
            let c = UnsafeRawPointer(layers.chassis).loadUnaligned(fromByteOffset: index * 4, as: SIMD4<UInt8>.self)
            let g = UnsafeRawPointer(layers.glass).loadUnaligned(fromByteOffset: index * 4, as: SIMD4<UInt8>.self)
            chassis = SIMD4<Float>(c) * (1.0 / 255)
            glass = SIMD4<Float>(g) * (1.0 / 255)
            chassisLinear = SIMD3(linearTable[Int(c.x)], linearTable[Int(c.y)], linearTable[Int(c.z)])
            glassLinear = SIMD3(linearTable[Int(g.x)], linearTable[Int(g.y)], linearTable[Int(g.z)])
            packed = load(layers.mask2, index) + load(layers.bloom2, index) * (4.0 / 3.0)
        } else {
            let u = u1
            let t = t1
            u1 = (u - params.centerX) / params.chassisScale + params.centerX
            t1 = (t - params.centerY) / params.chassisScale + params.centerY
            let u2 = (u - params.centerX) / params.glassScale + params.centerX
            let t2 = (t - params.centerY) / params.glassScale + params.centerY
            chassis = sample(layers.chassis, layers, u1, t1)
            glass = sample(layers.glass, layers, u2, t2)
            chassisLinear = SIMD3(
                powf(chassis.x, 2.2), powf(chassis.y, 2.2), powf(chassis.z, 2.2))
            glassLinear = SIMD3(powf(glass.x, 2.2), powf(glass.y, 2.2), powf(glass.z, 2.2))
            packed = sample(layers.mask2, layers, u1, t1) + sample(layers.bloom2, layers, u1, t1) * (4.0 / 3.0)
        }
        var glow = SIMD3<Float>(repeating: 0)
        if packed.x > 0 { glow += params.seamGain * packed.x }
        if packed.y > 0 {
            let xd = u1 * 640
            let segment = min(max(((xd - 562) / 8.2).rounded(.down), 0), 4)
            let lit: Float = segment < params.effort ? 1 : (params.hollow ? 0.1 : 0.14)
            var eye = params.eyeTone
            if params.rainbow > 0 {
                let phase = (u1 * 5 - params.time * 0.3) * 6.2831853
                let rainbow = SIMD3<Float>(
                    0.5 + 0.5 * cos(phase), 0.5 + 0.5 * cos(phase + 0.33 * 6.2831853),
                    0.5 + 0.5 * cos(phase + 0.67 * 6.2831853))
                eye = eye + (rainbow - eye) * params.rainbow
            }
            glow += eye * (params.eyeGain * lit * packed.y)
        }
        if packed.z > 0 {
            let yd = t1 * 420
            let rib = min(max(((yd - 381) / 6).rounded(.down), 0), 5)
            let lit = min(max(params.ribs - (5 - rib), 0), 1)
            glow += params.ribGain * (lit * packed.z)
        }
        if packed.w > 0 { glow += params.earGain * packed.w }
        glow *= chassis.w * (1 - params.spill) + params.spill
        glow = glow / (SIMD3<Float>(repeating: 1) + glow * 0.2)
        var spilled: Float = 0
        if params.spill > 0.5 {
            spilled = min(max(max(glow.x, max(glow.y, glow.z)), 0), 1)
        }
        var color = (chassisLinear * chassis.w + glow) * params.fade
        var alpha = min(max(chassis.w + spilled, 0), 1) * params.fade
        let glassAlpha = glass.w * (1 - 0.8 * (1 - params.fade))
        color = color * (1 - glassAlpha) + glassLinear * glassAlpha
        alpha = alpha * (1 - glassAlpha) + glassAlpha
        let clamped = color.clamped(lowerBound: SIMD3(repeating: 0), upperBound: SIMD3(repeating: 1))
        let encoded = SIMD3<Float>(
            powf(clamped.x, inverseGamma), powf(clamped.y, inverseGamma), powf(clamped.z, inverseGamma))
        let coverage = max(min(max(alpha, 0), 1), max(encoded.x, max(encoded.y, encoded.z)))
        dest[0] = byte(encoded.z)
        dest[1] = byte(encoded.y)
        dest[2] = byte(encoded.x)
        dest[3] = byte(coverage)
    }
}
