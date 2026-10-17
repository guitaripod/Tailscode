import Dispatch
import Foundation

/// A pointer that may cross into a concurrent loop. The loops that carry one write disjoint rows.
struct NeuralUnsafe<Pointee>: @unchecked Sendable {
    let pointer: UnsafeMutablePointer<Pointee>

    init(_ pointer: UnsafeMutablePointer<Pointee>) { self.pointer = pointer }
}

/// A read-only pointer that may cross into a concurrent loop.
struct NeuralConst<Pointee>: @unchecked Sendable {
    let pointer: UnsafePointer<Pointee>

    init(_ pointer: UnsafePointer<Pointee>) { self.pointer = pointer }
}

/// Splits a range of rows over the machine's cores. Small ranges run on the calling thread.
/// How widely the compositor spreads a frame. A client that draws small changes often (the Linux
/// stage's delta frames, thirty a second) caps the workers and raises the rows each one must have,
/// because waking every core for a few dozen rows costs more than the rows do. The defaults are
/// every core and four rows, which is right for a poster rendered once.
public enum NeuralParallelism {
    public nonisolated(unsafe) static var maximumWorkers = Int.max
    public nonisolated(unsafe) static var minimumRows = 4
}

enum NeuralParallel {
    static func rows(_ rows: Range<Int>, minimumPerChunk: Int = 4, _ body: @Sendable (Range<Int>) -> Void) {
        let count = rows.count
        guard count > 0 else { return }
        let cores = max(1, min(NeuralParallelism.maximumWorkers, ProcessInfo.processInfo.activeProcessorCount))
        let chunk = max(max(minimumPerChunk, NeuralParallelism.minimumRows), (count + cores * 3) / (cores * 4))
        if cores == 1 || count <= chunk {
            body(rows)
            return
        }
        let iterations = (count + chunk - 1) / chunk
        let first = rows.lowerBound
        let last = rows.upperBound
        DispatchQueue.concurrentPerform(iterations: iterations) { index in
            let lower = first + index * chunk
            body(lower..<min(last, lower + chunk))
        }
    }
}

/// An 8-bit RGBA picture, rows from the top, straight (not premultiplied) alpha. Core holds the
/// head's layers in this shape so it needs no image library: a client decodes its PNGs and hands
/// the bytes over (``NeuralImage/init(rawData:)``).
public struct NeuralImage: Sendable, Equatable {
    public let width: Int
    public let height: Int
    public private(set) var bytes: [UInt8]

    /// A transparent black picture.
    public init(width: Int, height: Int) {
        let w = max(0, width)
        let h = max(0, height)
        self.width = w
        self.height = h
        self.bytes = [UInt8](repeating: 0, count: w * h * 4)
    }

    /// Nil when the bytes are not exactly `width * height * 4`.
    public init?(width: Int, height: Int, bytes: [UInt8]) {
        guard width >= 0, height >= 0, width <= NeuralImage.maxDimension, height <= NeuralImage.maxDimension,
            bytes.count == width * height * 4
        else { return nil }
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    /// A picture filled by asking `pixel` for every position.
    public init(width: Int, height: Int, pixel: (Int, Int) -> SIMD4<UInt8>) {
        self.init(width: width, height: height)
        for y in 0..<self.height {
            for x in 0..<self.width {
                setPixel(x: x, y: y, pixel(x, y))
            }
        }
    }

    public static let maxDimension = 16384

    public var byteCount: Int { bytes.count }

    /// The pixel at a position, clamped to the picture's edge.
    public func pixel(x: Int, y: Int) -> SIMD4<UInt8> {
        guard width > 0, height > 0 else { return SIMD4(0, 0, 0, 0) }
        let cx = min(max(x, 0), width - 1)
        let cy = min(max(y, 0), height - 1)
        let offset = (cy * width + cx) * 4
        return SIMD4(bytes[offset], bytes[offset + 1], bytes[offset + 2], bytes[offset + 3])
    }

    public mutating func setPixel(x: Int, y: Int, _ value: SIMD4<UInt8>) {
        guard x >= 0, y >= 0, x < width, y < height else { return }
        let offset = (y * width + x) * 4
        bytes[offset] = value.x
        bytes[offset + 1] = value.y
        bytes[offset + 2] = value.z
        bytes[offset + 3] = value.w
    }

    /// Bilinear sample as a GPU's linear filter with clamp-to-edge does: `u` runs left to right and
    /// `t` top to bottom, both 0 to 1 across the picture, and a pixel's value sits at its centre.
    /// Components come back 0 to 1.
    public func sample(u: Float, t: Float) -> SIMD4<Float> {
        guard width > 0, height > 0 else { return SIMD4(repeating: 0) }
        return bytes.withUnsafeBufferPointer {
            NeuralImage.bilinear($0.baseAddress!, width: width, height: height, u: u, t: t)
        }
    }

    @inline(__always)
    static func bilinear(
        _ pixels: UnsafePointer<UInt8>, width: Int, height: Int, u: Float, t: Float
    ) -> SIMD4<Float> {
        let fx = min(max(u * Float(width) - 0.5, -1), Float(width))
        let fy = min(max(t * Float(height) - 0.5, -1), Float(height))
        let x0f = fx.rounded(.down)
        let y0f = fy.rounded(.down)
        let ax = fx - x0f
        let ay = fy - y0f
        let xa = min(max(Int(x0f), 0), width - 1)
        let xb = min(max(Int(x0f) + 1, 0), width - 1)
        let ya = min(max(Int(y0f), 0), height - 1)
        let yb = min(max(Int(y0f) + 1, 0), height - 1)
        let raw = UnsafeRawPointer(pixels)
        let p00 = SIMD4<Float>(raw.loadUnaligned(fromByteOffset: (ya * width + xa) * 4, as: SIMD4<UInt8>.self))
        let p10 = SIMD4<Float>(raw.loadUnaligned(fromByteOffset: (ya * width + xb) * 4, as: SIMD4<UInt8>.self))
        let p01 = SIMD4<Float>(raw.loadUnaligned(fromByteOffset: (yb * width + xa) * 4, as: SIMD4<UInt8>.self))
        let p11 = SIMD4<Float>(raw.loadUnaligned(fromByteOffset: (yb * width + xb) * 4, as: SIMD4<UInt8>.self))
        let top = p00 + (p10 - p00) * ax
        let bottom = p01 + (p11 - p01) * ax
        return (top + (bottom - top) * ay) * (1.0 / 255.0)
    }

    /// The picture at another size. Shrinking an axis takes the box average of the source pixels
    /// each new pixel covers; growing one filters bilinearly, which is what sampling the original
    /// at the new pixel's centre gives. Alpha is filtered like colour: masks carry data in it.
    public func resized(width newWidth: Int, height newHeight: Int) -> NeuralImage {
        guard newWidth > 0, newHeight > 0, width > 0, height > 0 else {
            return NeuralImage(width: max(0, newWidth), height: max(0, newHeight))
        }
        if newWidth == width && newHeight == height { return self }
        let columns = NeuralAxisFilter(source: width, target: newWidth)
        let rows = NeuralAxisFilter(source: height, target: newHeight)
        var across = [SIMD4<Float>](repeating: SIMD4(repeating: 0), count: newWidth * height)
        var result = [UInt8](repeating: 0, count: newWidth * newHeight * 4)
        let sourceWidth = width
        let sourceHeight = height
        bytes.withUnsafeBufferPointer { source in
            across.withUnsafeMutableBufferPointer { tmp in
                let tmpOut = NeuralUnsafe(tmp.baseAddress!)
                let src = NeuralConst(source.baseAddress!)
                NeuralParallel.rows(0..<sourceHeight) { range in
                    let raw = UnsafeRawPointer(src.pointer)
                    for y in range {
                        for x in 0..<newWidth {
                            var sum = SIMD4<Float>(repeating: 0)
                            let start = columns.starts[x]
                            let base = columns.offsets[x]
                            for tap in 0..<columns.counts[x] {
                                let pixel = SIMD4<Float>(
                                    raw.loadUnaligned(
                                        fromByteOffset: (y * sourceWidth + start + tap) * 4,
                                        as: SIMD4<UInt8>.self))
                                sum += pixel * columns.weights[base + tap]
                            }
                            tmpOut.pointer[y * newWidth + x] = sum
                        }
                    }
                }
            }
            across.withUnsafeBufferPointer { tmp in
                result.withUnsafeMutableBufferPointer { out in
                    let outPointer = NeuralUnsafe(out.baseAddress!)
                    let tmpPointer = NeuralConst(tmp.baseAddress!)
                    NeuralParallel.rows(0..<newHeight) { range in
                        for y in range {
                            let start = rows.starts[y]
                            let base = rows.offsets[y]
                            for x in 0..<newWidth {
                                var sum = SIMD4<Float>(repeating: 0)
                                for tap in 0..<rows.counts[y] {
                                    sum += tmpPointer.pointer[(start + tap) * newWidth + x] * rows.weights[base + tap]
                                }
                                let clamped = (sum + SIMD4(repeating: 0.5)).clamped(
                                    lowerBound: SIMD4(repeating: 0), upperBound: SIMD4(repeating: 255))
                                let packed = SIMD4<UInt8>(clamped)
                                let offset = (y * newWidth + x) * 4
                                outPointer.pointer[offset] = packed.x
                                outPointer.pointer[offset + 1] = packed.y
                                outPointer.pointer[offset + 2] = packed.z
                                outPointer.pointer[offset + 3] = packed.w
                            }
                        }
                    }
                }
            }
        }
        return NeuralImage(unchecked: newWidth, newHeight, result)
    }

    init(unchecked width: Int, _ height: Int, _ bytes: [UInt8]) {
        self.width = width
        self.height = height
        self.bytes = bytes
    }

    static let rawMagic: [UInt8] = Array("NTRG".utf8)

    /// The raw hand-over format a client's loader returns: the magic `NTRG`, width and height as
    /// little-endian 32-bit integers, then `width * height * 4` bytes of RGBA, rows from the top.
    public func rawData() -> Data {
        var data = Data(NeuralImage.rawMagic)
        for value in [UInt32(width), UInt32(height)] {
            withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
        }
        data.append(contentsOf: bytes)
        return data
    }

    /// Nil for anything that is not exactly a header and its pixels.
    public init?(rawData data: Data) {
        let all = [UInt8](data)
        guard all.count >= 12, Array(all[0..<4]) == NeuralImage.rawMagic else { return nil }
        func word(_ offset: Int) -> Int {
            Int(all[offset]) | Int(all[offset + 1]) << 8 | Int(all[offset + 2]) << 16
                | Int(all[offset + 3]) << 24
        }
        let w = word(4)
        let h = word(8)
        guard w > 0, h > 0, w <= NeuralImage.maxDimension, h <= NeuralImage.maxDimension,
            all.count == 12 + w * h * 4
        else { return nil }
        self.init(unchecked: w, h, Array(all[12...]))
    }
}

/// For each target index along one axis, which source pixels feed it and with what weights.
struct NeuralAxisFilter {
    var starts: [Int] = []
    var counts: [Int] = []
    var offsets: [Int] = []
    var weights: [Float] = []

    init(source: Int, target: Int) {
        starts.reserveCapacity(target)
        counts.reserveCapacity(target)
        offsets.reserveCapacity(target)
        if target < source {
            let scale = Double(source) / Double(target)
            for index in 0..<target {
                let low = Double(index) * scale
                let high = Double(index + 1) * scale
                let first = Int(low.rounded(.down))
                let last = min(source - 1, Int(high.rounded(.up)) - 1)
                var tapWeights: [Float] = []
                var total = 0.0
                for pixel in first...max(first, last) {
                    let overlap = min(high, Double(pixel + 1)) - max(low, Double(pixel))
                    let weight = max(0, overlap)
                    tapWeights.append(Float(weight))
                    total += weight
                }
                let norm = total > 0 ? Float(1 / total) : 1
                starts.append(first)
                counts.append(tapWeights.count)
                offsets.append(weights.count)
                weights.append(contentsOf: tapWeights.map { $0 * norm })
            }
        } else {
            let ratio = Double(source) / Double(target)
            for index in 0..<target {
                let position = (Double(index) + 0.5) * ratio - 0.5
                let floorIndex = Int(position.rounded(.down))
                let fraction = Float(position - Double(floorIndex))
                starts.append(min(max(floorIndex, 0), source - 1))
                offsets.append(weights.count)
                if floorIndex < 0 || floorIndex + 1 > source - 1 || fraction == 0 {
                    counts.append(1)
                    weights.append(1)
                    if floorIndex < 0 {
                        starts[starts.count - 1] = 0
                    } else if floorIndex + 1 > source - 1 {
                        starts[starts.count - 1] = source - 1
                    }
                } else {
                    counts.append(2)
                    weights.append(1 - fraction)
                    weights.append(fraction)
                }
            }
        }
    }
}

/// The nine layers the head is built from, as the packing script writes them.
public enum NeuralAssetName: String, CaseIterable, Sendable {
    case chassis
    case interior
    case glass
    case mask0
    case mask1
    case mask2
    case bloom0
    case bloom1
    case bloom2

    public static let fullWidth = 1536
    public static let fullHeight = 1008

    /// The key a client's loader is asked for.
    public var fileName: String { rawValue }

    public var isMask: Bool { self == .mask0 || self == .mask1 || self == .mask2 }
    public var isBloom: Bool { self == .bloom0 || self == .bloom1 || self == .bloom2 }

    /// The layer's size at full resolution: the glass is half, the bloom an eighth.
    public var width: Int {
        switch self {
        case .glass: return NeuralAssetName.fullWidth / 2
        case .bloom0, .bloom1, .bloom2: return NeuralAssetName.fullWidth / 8
        default: return NeuralAssetName.fullWidth
        }
    }

    public var height: Int {
        switch self {
        case .glass: return NeuralAssetName.fullHeight / 2
        case .bloom0, .bloom1, .bloom2: return NeuralAssetName.fullHeight / 8
        default: return NeuralAssetName.fullHeight
        }
    }

    /// What the Apple GPU container holds: the chassis keeps its edges at 4 by 4, the rest is 6 by 6.
    public var pixelFormat: NeuralPixelFormat { self == .chassis ? .astc4x4 : .astc6x6 }

    /// What the CPU compositor decodes every layer to.
    public var decodedFormat: NeuralPixelFormat { .rgba8 }

    /// Bloom values are stored times this, so the faint tail fits eight bits.
    public static let bloomGain: Float = 3

    public static func mask(_ index: Int) -> NeuralAssetName {
        [NeuralAssetName.mask0, .mask1, .mask2][min(max(index, 0), 2)]
    }

    public static func bloom(_ index: Int) -> NeuralAssetName {
        [NeuralAssetName.bloom0, .bloom1, .bloom2][min(max(index, 0), 2)]
    }
}

/// Which channel of which packed mask holds which of the head's channels. Twelve channels pack
/// into three RGBA textures in the order the shader reads them; the visor's backing is not packed.
public enum NeuralChannelPacking {
    public struct Slot: Sendable, Hashable {
        /// 0, 1 or 2: mask0, mask1 or mask2 (and the bloom of the same index).
        public let mask: Int
        /// 0 to 3: red, green, blue, alpha.
        public let component: Int
    }

    public static let masks: [[NeuralChannel]] = [
        [.think, .sense, .act, .shell],
        [.delegate, .say, .link, .star],
        [.seam, .eye, .rib, .ear],
    ]

    public static let packedCount = 12

    public static func slot(for channel: NeuralChannel) -> Slot? {
        guard channel.rawValue < packedCount else { return nil }
        return Slot(mask: channel.rawValue / 4, component: channel.rawValue % 4)
    }

    public static func channel(mask: Int, component: Int) -> NeuralChannel? {
        guard mask >= 0, mask < 3, component >= 0, component < 4 else { return nil }
        return masks[mask][component]
    }
}

public typealias NeuralAssetLoader = @Sendable (String) -> Data?

/// The head's decoded layers, resident only while a brain is open. A client supplies the loader
/// (a bundle lookup, a file read) and returns each layer in the raw hand-over format; every
/// brain that opens calls `retain()` and every one that closes calls `release()`, and the
/// decoded pictures are dropped when the count returns to zero.
public final class NeuralAssetStore: @unchecked Sendable {
    /// One store per process. Its loader is set by the client at launch (``configure(loader:)``).
    public static let shared = NeuralAssetStore(loader: { _ in nil })

    private let lock = NSLock()
    private var loader: NeuralAssetLoader
    private var cache: [NeuralAssetName: NeuralImage] = [:]
    private var holds = 0

    public init(loader: @escaping NeuralAssetLoader) {
        self.loader = loader
    }

    /// Replaces the loader and drops what was decoded with the old one.
    public func configure(loader: @escaping NeuralAssetLoader) {
        lock.lock()
        self.loader = loader
        cache.removeAll()
        lock.unlock()
    }

    public func retain() {
        lock.lock()
        holds += 1
        lock.unlock()
    }

    /// Dropping the last hold frees every decoded layer.
    public func release() {
        lock.lock()
        holds = max(0, holds - 1)
        if holds == 0 { cache.removeAll() }
        lock.unlock()
    }

    public var retainCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return holds
    }

    public var isResident: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !cache.isEmpty
    }

    public var residentBytes: Int {
        lock.lock()
        defer { lock.unlock() }
        return cache.values.reduce(0) { $0 + $1.byteCount }
    }

    /// A decoded layer, from the cache while the store is held, else decoded afresh and not kept.
    /// Nil when the loader has nothing by that name or the bytes are not a layer.
    public func image(named name: NeuralAssetName) -> NeuralImage? {
        lock.lock()
        if let hit = cache[name] {
            lock.unlock()
            return hit
        }
        let load = loader
        lock.unlock()
        guard let data = load(name.fileName), let decoded = NeuralImage(rawData: data) else { return nil }
        lock.lock()
        defer { lock.unlock() }
        if holds > 0 {
            if let raced = cache[name] { return raced }
            cache[name] = decoded
        }
        return decoded
    }

    /// Decodes all nine layers on a background queue so the first brain opens without a hitch.
    /// Returns whether every layer was available. Call it while holding the store.
    @discardableResult
    public func prepare() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                var complete = true
                for name in NeuralAssetName.allCases where self.image(named: name) == nil {
                    complete = false
                }
                continuation.resume(returning: complete)
            }
        }
    }
}
