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
    private let toneBlock = NeuralToneBuffer(pointer: .allocate(capacity: 8))
    var denseOnly = false

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

    deinit {
        assets.release()
        toneBlock.pointer.deallocate()
    }

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

    var sparseIndex: NeuralLitIndex {
        lock.lock()
        defer { lock.unlock() }
        return layers.litIndex
    }

    var fibreRanksForTesting: NeuralPixelList {
        lock.lock()
        defer { lock.unlock() }
        return layers.fibreRanks
    }

    func rippleFieldForTesting(actX: Float, actY: Float) -> NeuralRippleField {
        lock.lock()
        defer { lock.unlock() }
        return layers.rippleField(actX: actX, actY: actY)
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
        draw(
            frame, previous: nil, dive: dive, time: time, region: whole, sparse: [], fibres: false, whole: true,
            into: &pair)
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
        var pixels: [Int] = sparse ?? []
        let fibres = sparse == nil && (frame.ripple != 0 || (previous?.ripple ?? 0) != 0)
        let clamped = area.clamped(width: layers.width, height: layers.height)
        let covers = clamped.width == layers.width && clamped.height == layers.height
        let everything = lastDive != dive || (previous == nil && covers)
        draw(
            frame, previous: previous, dive: dive, time: time, region: clamped, sparse: pixels, fibres: fibres,
            whole: everything, into: &pair)
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

    static func changed(_ channel: Int, _ a: NeuralFrame, _ b: NeuralFrame) -> Bool {
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
        _ frame: NeuralFrame, previous: NeuralFrame?, dive: NeuralDive, time: Float, region: NeuralRegion,
        sparse: [Int], fibres: Bool, whole: Bool, into pair: inout NeuralSurfacePair
    ) {
        guard whole || !region.isEmpty || !sparse.isEmpty || fibres else { return }
        let params = NeuralFrameParams(frame: frame, table: table, dive: dive, time: time, width: layers.width, height: layers.height, tones: toneBlock)
        if frame.crunch > 0 || (previous?.crunch ?? 0) > 0 { layers.prepareZones() }
        let pointers = layers.pointers
        let plan = NeuralDrawPlan(
            frame: frame, previous: previous, params: params, region: region, whole: whole && !denseOnly,
            dense: denseOnly, index: layers.litIndex, crunch: layers.crunchRegion)
        let field = plan.link ? layers.rippleField(actX: params.actX, actY: params.actY) : nil
        let explicit = fibres && field == nil ? layers.fibres : sparse
        let fibreRanks = fibres && field != nil ? layers.fibreRanks : nil
        let total = layers.width * layers.height * 4
        pair.interior.bytes.withUnsafeMutableBufferPointer { interior in
            pair.front.bytes.withUnsafeMutableBufferPointer { front in
                let interiorOut = NeuralUnsafe(interior.baseAddress!)
                let frontOut = NeuralUnsafe(front.baseAddress!)
                if plan.copyInterior { interiorOut.pointer.update(from: pointers.base, count: total) }
                if plan.copyFront { frontOut.pointer.update(from: pointers.frontRest, count: total) }
                Self.drawInterior(
                    plan, sparse: explicit, field: field, fibreRanks: fibreRanks, link: layers.litIndex.link,
                    pointers: pointers, params: params, out: interiorOut)
                Self.drawFront(plan, pointers: pointers, params: params, out: frontOut)
            }
        }
    }

    private static func drawInterior(
        _ plan: NeuralDrawPlan, sparse: [Int], field: NeuralRippleField?, fibreRanks: NeuralPixelList?,
        link: NeuralPixelList, pointers: NeuralLayerPointers, params: NeuralFrameParams,
        out: NeuralUnsafe<UInt8>
    ) {
        if let rectangle = plan.interiorRectangle, !rectangle.isEmpty {
            NeuralParallel.rows(rectangle.minY..<rectangle.maxY) { rows in
                NeuralKernels.interior(
                    rows: rows, columns: rectangle.minX..<rectangle.maxX, layers: pointers, params: params,
                    out: out.pointer)
            }
        }
        if let list = plan.interiorList {
            let (span, columns) = plan.clip(list, to: plan.interiorClip, width: pointers.width)
            NeuralParallel.rows(span, minimumPerChunk: 1024, minimumPerWorker: 100_000) { range in
                NeuralKernels.interior(
                    positions: range, indices: list.indices, columns: columns, layers: pointers, params: params,
                    out: out.pointer)
            }
        }
        if let field {
            let (span, columns) = plan.clip(link, to: plan.interiorClip, width: pointers.width)
            NeuralParallel.rows(span, minimumPerChunk: 1024, minimumPerWorker: 100_000) { range in
                NeuralKernels.interiorRipple(
                    positions: range, indices: link.indices, ranks: nil, outside: nil, columns: columns,
                    field: field, layers: pointers, params: params, out: out.pointer)
            }
            if let fibreRanks, fibreRanks.count > 0 {
                NeuralKernels.interiorRipple(
                    positions: 0..<fibreRanks.count, indices: link.indices, ranks: fibreRanks.indices,
                    outside: plan.interiorCovered, columns: nil, field: field, layers: pointers, params: params,
                    out: out.pointer)
            }
        }
        guard !sparse.isEmpty else { return }
        let covered = plan.interiorCovered
        let byRectangle = plan.interiorByRectangle
        let mask = plan.interiorMask
        let lit = NeuralConst(UnsafePointer(plan.bits))
        let width = pointers.width
        NeuralParallel.rows(0..<sparse.count, minimumPerChunk: 256) { range in
            for position in range {
                let index = sparse[position]
                let x = index % width
                let y = index / width
                if covered.contains(x: x, y: y) && (byRectangle || lit.pointer[index] & mask != 0) { continue }
                NeuralKernels.interiorPixel(
                    index: index, x: x, y: y, layers: pointers, params: params, out: out.pointer)
            }
        }
    }

    private static func drawFront(
        _ plan: NeuralDrawPlan, pointers: NeuralLayerPointers,
        params: NeuralFrameParams, out: NeuralUnsafe<UInt8>
    ) {
        if let rectangle = plan.frontRectangle, !rectangle.isEmpty {
            NeuralParallel.rows(rectangle.minY..<rectangle.maxY) { rows in
                NeuralKernels.front(
                    rows: rows, columns: rectangle.minX..<rectangle.maxX, layers: pointers, params: params,
                    out: out.pointer)
            }
        }
        if let list = plan.frontList {
            let (span, columns) = plan.clip(list, to: plan.frontClip, width: pointers.width)
            NeuralParallel.rows(span, minimumPerChunk: 1024) { range in
                NeuralKernels.front(
                    positions: range, indices: list.indices, columns: columns, layers: pointers, params: params,
                    out: out.pointer)
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
    let frontRest: UnsafePointer<UInt8>
    let bits: UnsafePointer<UInt16>
    let blocks: UnsafePointer<UInt8>
    let blockColumns: Int
    let zoneOf: UnsafePointer<UInt8>?
    let linear: UnsafePointer<Float>
    let thresholds: UnsafePointer<Float>
    let steps: UnsafePointer<UInt8>

    @inline(__always)
    func encode(_ value: Float) -> UInt8 {
        let clamped = min(max(value, 0), 1)
        guard clamped >= NeuralCodec.lowest else { return 0 }
        let cell = Int(truncatingIfNeeded: (clamped.bitPattern >> 16) &- UInt32(107 << 7)) & 4095
        let level = Int(steps[cell])
        return UInt8(truncatingIfNeeded: level + (clamped >= thresholds[level + 1] ? 1 : 0))
    }
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
    let frontRest: NeuralPixelBuffer
    private(set) var litIndex: NeuralLitIndex
    private var zonePlane: NeuralPixelBuffer?
    private var rankedFibres: NeuralPixelList?
    var fibreRanks: NeuralPixelList {
        if let rankedFibres { return rankedFibres }
        let made = Self.ranks(of: fibres, in: litIndex.link)
        rankedFibres = made
        return made
    }
    private var fields: [NeuralRippleField] = []
    private(set) var complete = true
    private(set) var bounds: [NeuralRegion] = []
    private(set) var fibres: [Int] = []
    private(set) var domeRegion = NeuralRegion.empty
    private(set) var crunchRegion = NeuralRegion.empty
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
        frontRest = NeuralPixelBuffer(count: width * height * 4)
        litIndex = NeuralLitIndex(
            width: width, height: height,
            bits: UnsafeMutablePointer<UInt16>.allocate(capacity: max(1, width * height)))
        rebuildBase(background: background)
        measure()
        buildFrontRest()
    }

    var footprint: Int {
        let layerBytes = width * height * 4
        return layerBytes * 12 + fibres.count * MemoryLayout<Int>.stride + litIndex.byteCount
            + (rankedFibres?.byteCount ?? 0) + (zonePlane?.count ?? 0) + fields.reduce(0) { $0 + $1.byteCount }
    }

    /// Which zone centre each pixel is nearest, for the crunch: made when a compaction first needs it.
    func prepareZones() {
        guard zonePlane == nil else { return }
        let plane = NeuralPixelBuffer(count: width * height)
        let output = NeuralUnsafe(plane.pointer)
        var xs = SIMD8<Float>(repeating: 0)
        var ys = SIMD8<Float>(repeating: 0)
        for (position, zone) in NeuralZone.allCases.prefix(6).enumerated() {
            xs[position] = Float(zone.center.x / NeuralDesign.width)
            ys[position] = Float(zone.center.y / NeuralDesign.height)
        }
        let zoneX = xs
        let zoneY = ys
        let aspect = Float(width) / Float(height)
        let invWidth = 1 / Float(width)
        let invHeight = 1 / Float(height)
        let w = width
        NeuralParallel.rows(0..<height, minimumPerWorker: 256) { rows in
            for y in rows {
                let t = (Float(y) + 0.5) * invHeight
                for x in 0..<w {
                    let u = (Float(x) + 0.5) * invWidth
                    output.pointer[y * w + x] = UInt8(
                        NeuralKernels.nearestZone(u: u, t: t, aspect: aspect, zoneX: zoneX, zoneY: zoneY))
                }
            }
        }
        zonePlane = plane
    }

    /// The ripple's phase table for a centre, kept for the last two centres a turn has used.
    func rippleField(actX: Float, actY: Float) -> NeuralRippleField {
        if let hit = fields.firstIndex(where: { $0.actX == actX && $0.actY == actY }) {
            return fields[hit]
        }
        let made = NeuralRippleField(
            list: litIndex.link, width: width, height: height, actX: actX, actY: actY)
        fields.insert(made, at: 0)
        if fields.count > 2 { fields.removeLast() }
        return made
    }

    var pointers: NeuralLayerPointers {
        NeuralLayerPointers(
            width: width, height: height, invWidth: 1 / Float(width), invHeight: 1 / Float(height),
            chassis: UnsafePointer(chassis.pointer), interior: UnsafePointer(interior.pointer),
            glass: UnsafePointer(glass.pointer), mask0: UnsafePointer(masks[0].pointer),
            mask1: UnsafePointer(masks[1].pointer), mask2: UnsafePointer(masks[2].pointer),
            bloom0: UnsafePointer(blooms[0].pointer), bloom1: UnsafePointer(blooms[1].pointer),
            bloom2: UnsafePointer(blooms[2].pointer), base: UnsafePointer(base.pointer),
            frontRest: UnsafePointer(frontRest.pointer), bits: UnsafePointer(litIndex.bits),
            blocks: UnsafePointer(litIndex.blocks), blockColumns: litIndex.blockColumns,
            zoneOf: zonePlane.map { UnsafePointer($0.pointer) },
            linear: UnsafePointer(NeuralCodec.shared.linear),
            thresholds: UnsafePointer(NeuralCodec.shared.thresholds),
            steps: UnsafePointer(NeuralCodec.shared.steps))
    }

    func rebuildBase(background: NeuralRGB) {
        let bg = SIMD3<Float>(background.r, background.g, background.b)
        let output = NeuralUnsafe(base.pointer)
        let source = NeuralConst(UnsafePointer(interior.pointer))
        let codec = pointers
        let w = width
        NeuralParallel.rows(0..<height) { rows in
            for y in rows {
                for x in 0..<w {
                    let offset = (y * w + x) * 4
                    let a = Float(source.pointer[offset + 3]) * (1.0 / 255)
                    let lin = SIMD3<Float>(
                        codec.linear[Int(source.pointer[offset])],
                        codec.linear[Int(source.pointer[offset + 1])],
                        codec.linear[Int(source.pointer[offset + 2])])
                    let mixed = bg * (1 - a) + lin * a
                    output.pointer[offset] = codec.encode(mixed.z)
                    output.pointer[offset + 1] = codec.encode(mixed.y)
                    output.pointer[offset + 2] = codec.encode(mixed.x)
                    output.pointer[offset + 3] = 255
                }
            }
        }
    }

    private func buildFrontRest() {
        let output = NeuralUnsafe(frontRest.pointer)
        let layers = pointers
        NeuralParallel.rows(0..<height) { rows in
            for y in rows {
                for x in 0..<layers.width {
                    NeuralKernels.frontRestPixel(index: y * layers.width + x, layers: layers, out: output.pointer)
                }
            }
        }
    }

    /// Where each of `pixels` (ascending, all in `list`) sits in `list`.
    private static func ranks(of pixels: [Int], in list: NeuralPixelList) -> NeuralPixelList {
        var found: [Int32] = []
        found.reserveCapacity(pixels.count)
        var position = 0
        for pixel in pixels {
            while position < list.count && Int(list.indices[position]) < pixel { position += 1 }
            if position < list.count && Int(list.indices[position]) == pixel {
                found.append(Int32(truncatingIfNeeded: position))
            }
        }
        return NeuralPixelList(found)
    }

    private func measure() {
        var minX = [Int](repeating: Int.max, count: NeuralChannel.count)
        var minY = minX
        var maxX = [Int](repeating: -1, count: NeuralChannel.count)
        var maxY = maxX
        var links: [Int] = []
        let lit = litIndex.bits
        lit.initialize(repeating: 0, count: max(1, width * height))
        let alpha = interior.pointer
        for index in 0..<(width * height) where alpha[index * 4 + 3] != 0 {
            lit[index] = NeuralLitIndex.alphaBit
        }
        for set in 0..<3 {
            let mask = masks[set].pointer
            let bloom = blooms[set].pointer
            for y in 0..<height {
                for x in 0..<width {
                    let offset = (y * width + x) * 4
                    for component in 0..<4 {
                        let channel = set * 4 + component
                        if mask[offset + component] != 0 || bloom[offset + component] != 0 {
                            lit[y * width + x] |= UInt16(1) << UInt16(channel)
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
        litIndex.rebuild()
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
        crunchRegion = measureCrunch(sx: sx, sy: sy)
    }

    /// Where a crunched pixel can read anything: the box around every lit or opaque interior pixel
    /// and the six zone centres the warp pulls towards, two pixels out. A pixel outside it samples
    /// further out along the ray from its zone's centre, so it reads nothing.
    private func measureCrunch(sx: Double, sy: Double) -> NeuralRegion {
        var minX = width
        var minY = height
        var maxX = -1
        var maxY = -1
        let lit = litIndex.bits
        for y in 0..<height {
            for x in 0..<width where lit[y * width + x] & NeuralLitIndex.interiorActive != 0 {
                minX = min(minX, x)
                maxX = max(maxX, x)
                minY = min(minY, y)
                maxY = max(maxY, y)
            }
        }
        for zone in NeuralZone.allCases {
            let x = Int((zone.center.x * sx).rounded(.down))
            let y = Int((zone.center.y * sy).rounded(.down))
            minX = min(minX, x)
            maxX = max(maxX, x)
            minY = min(minY, y)
            maxY = max(maxY, y)
        }
        return NeuralRegion(minX: minX - 2, minY: minY - 2, maxX: maxX + 3, maxY: maxY + 3)
            .clamped(width: width, height: height)
    }
}

/// The eight zone channels' tones times their intensities, in a block the compositor owns so a
/// frame's parameters stay plain values the pixel loops copy freely.
struct NeuralToneBuffer: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<SIMD3<Float>>

    subscript(channel: Int) -> SIMD3<Float> { pointer[channel] }
}

/// Everything a frame fixes before a pixel is looked at: the tone and intensity products and the
/// scalars the two passes read.
struct NeuralFrameParams: Sendable {
    var tones: NeuralToneBuffer
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
    var rippleSin: Float
    var rippleCos: Float
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
    var needsPosition: Bool
    var zoneX: SIMD8<Float>
    var zoneY: SIMD8<Float>

    init(
        frame: NeuralFrame, table: NeuralToneTable, dive: NeuralDive, time: Float, width: Int, height: Int,
        tones buffer: NeuralToneBuffer
    ) {
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
        tones = buffer
        for channel in 0..<8 { buffer.pointer[channel] = scaled(channel) }
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
        let rippleAngle = Double(time) * 3.2
        rippleSin = Float(sin(rippleAngle))
        rippleCos = Float(cos(rippleAngle))
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
        needsPosition = frame.ripple != 0 || frame.sweepAmount > 0 || frame.crunch > 0
        var xs = SIMD8<Float>(repeating: 0)
        var ys = SIMD8<Float>(repeating: 0)
        for (position, zone) in NeuralZone.allCases.prefix(6).enumerated() {
            xs[position] = Float(zone.center.x / NeuralDesign.width)
            ys[position] = Float(zone.center.y / NeuralDesign.height)
        }
        zoneX = xs
        zoneY = ys
    }
}
