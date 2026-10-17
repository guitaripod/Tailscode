import Foundation

/// The two lookups that stand in for `pow` in the shader's gamma: the decode of an 8-bit value to
/// linear light, and the encode of a linear value back to the byte `powf(x, 1/2.2)` would round to.
/// The encode is exact up to a float's last bit: it finds the cell of a log-spaced table the value
/// falls in, which holds at most one rounding threshold, and compares against it.
final class NeuralCodec: @unchecked Sendable {
    static let shared = NeuralCodec()

    /// Values below 2^-20 encode to zero: the first threshold, (0.5/255)^2.2, is above it.
    static let lowest: Float = 1.0 / 1_048_576

    private static let exponentBase = UInt32(107 << 7)
    private static let cells = 20 * 128 + 1

    let linear: UnsafeMutablePointer<Float>
    let thresholds: UnsafeMutablePointer<Float>
    let steps: UnsafeMutablePointer<UInt8>

    private init() {
        linear = UnsafeMutablePointer<Float>.allocate(capacity: 256)
        for value in 0..<256 { linear[value] = Float(pow(Double(value) / 255, 2.2)) }
        thresholds = UnsafeMutablePointer<Float>.allocate(capacity: 258)
        thresholds[0] = 0
        for level in 1...255 { thresholds[level] = Float(pow((Double(level) - 0.5) / 255, 2.2)) }
        thresholds[256] = .infinity
        thresholds[257] = .infinity
        steps = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
        for cell in 0..<4096 {
            guard cell < Self.cells else {
                steps[cell] = 255
                continue
            }
            let start = Float(bitPattern: (UInt32(cell) &+ Self.exponentBase) << 16)
            var level = 0
            while level < 255 && thresholds[level + 1] <= start { level += 1 }
            steps[cell] = UInt8(level)
        }
    }

    /// The byte for a linear value in 0...1, as `byte(powf(value, 1 / 2.2))` computes it.
    @inline(__always)
    func encode(_ value: Float) -> UInt8 {
        let clamped = min(max(value, 0), 1)
        guard clamped >= Self.lowest else { return 0 }
        let cell = Int(truncatingIfNeeded: (clamped.bitPattern >> 16) &- Self.exponentBase) & 4095
        let level = Int(steps[cell])
        return UInt8(truncatingIfNeeded: level + (clamped >= thresholds[level + 1] ? 1 : 0))
    }
}

/// An ascending list of pixel indices (`y * width + x`).
final class NeuralPixelList: @unchecked Sendable {
    let indices: UnsafeMutablePointer<Int32>
    let count: Int

    init(_ source: [Int32]) {
        count = source.count
        indices = UnsafeMutablePointer<Int32>.allocate(capacity: max(1, count))
        source.withUnsafeBufferPointer { buffer in
            if let base = buffer.baseAddress, count > 0 { indices.update(from: base, count: count) }
        }
    }

    deinit { indices.deallocate() }

    var byteCount: Int { count * MemoryLayout<Int32>.stride }

    /// The first position whose pixel is at or after `value`.
    func lowerBound(_ value: Int) -> Int {
        var low = 0
        var high = count
        while low < high {
            let middle = (low + high) >> 1
            if Int(indices[middle]) < value { low = middle + 1 } else { high = middle }
        }
        return low
    }

    /// The positions whose pixels lie on rows `rows`.
    func positions(rows: Range<Int>, width: Int) -> Range<Int> {
        lowerBound(rows.lowerBound * width)..<lowerBound(rows.upperBound * width)
    }
}

/// Which channels light each pixel, worked out once per size from the layers. Bits 0 to 7 are the
/// interior's eight zone channels (a mask or a bloom of that channel is not zero there), bits 8 to
/// 11 the front's seam, eye, rib and ear, and bit 12 an interior pixel with any alpha. A frame
/// that changes a few channels then redraws only the pixels those channels light.
final class NeuralLitIndex: @unchecked Sendable {
    static let interiorChannels: UInt16 = 0x00FF
    static let frontChannels: UInt16 = 0x0F00
    static let interiorActive: UInt16 = 0x10FF
    static let linkChannel: UInt16 = 0x0040
    static let alphaBit: UInt16 = 0x1000
    static let maxCached = 16

    static let blockShift = 3

    let width: Int
    let height: Int
    let bits: UnsafeMutablePointer<UInt16>
    let blockColumns: Int
    let blockRows: Int
    let blocks: UnsafeMutablePointer<UInt8>
    private var whole: [UInt16: NeuralPixelList] = [:]
    private var cache: [UInt32: NeuralPixelList] = [:]

    /// Every pixel any of the eight zone channels lights.
    var interiorLit: NeuralPixelList { wholeList(Self.interiorChannels) }
    /// Those and every opaque interior pixel: what a sweep reaches.
    var interiorActive: NeuralPixelList { wholeList(Self.interiorActive) }
    var frontLit: NeuralPixelList { wholeList(Self.frontChannels) }
    /// The link channel's pixels, the ones a ripple moves.
    var link: NeuralPixelList { wholeList(Self.linkChannel) }

    init(width: Int, height: Int, bits: UnsafeMutablePointer<UInt16>) {
        self.width = width
        self.height = height
        self.bits = bits
        blockColumns = (width + (1 << Self.blockShift) - 1) >> Self.blockShift
        blockRows = (height + (1 << Self.blockShift) - 1) >> Self.blockShift
        blocks = UnsafeMutablePointer<UInt8>.allocate(capacity: max(1, blockColumns * blockRows))
        blocks.initialize(repeating: 0, count: max(1, blockColumns * blockRows))
    }

    /// Forgets every list and builds the block flags, once `bits` is filled in. Lists are built
    /// when a frame first asks for them, so a state that never sweeps never holds the sweep's.
    func rebuild() {
        cache.removeAll()
        whole.removeAll()
        buildBlocks()
    }

    private func wholeList(_ mask: UInt16) -> NeuralPixelList {
        if let hit = whole[mask] { return hit }
        let made = build(mask)
        whole[mask] = made
        return made
    }

    deinit {
        bits.deallocate()
        blocks.deallocate()
    }

    var byteCount: Int {
        width * height * MemoryLayout<UInt16>.stride + blockColumns * blockRows
            + whole.values.reduce(0) { $0 + $1.byteCount } + cache.values.reduce(0) { $0 + $1.byteCount }
    }

    /// The pixels any channel in `mask` lights, ascending. Built on first ask and kept for the
    /// handful of combinations a live turn moves between.
    func list(mask: UInt16, excluding: UInt16 = 0) -> NeuralPixelList {
        if excluding == 0 {
            switch mask {
            case Self.interiorChannels: return interiorLit
            case Self.interiorActive: return interiorActive
            case Self.frontChannels: return frontLit
            case Self.linkChannel: return link
            default: break
            }
        }
        let key = UInt32(mask) | UInt32(excluding) << 16
        if let hit = cache[key] { return hit }
        if cache.count >= Self.maxCached { cache.removeAll() }
        let made = build(mask, excluding: excluding)
        cache[key] = made
        return made
    }

    /// One flag per 8 by 8 pixels: set when any interior channel is lit in the block or one next
    /// to it, so a sample taken anywhere in a clear block, bilinear reach included, reads zeros.
    private func buildBlocks() {
        let shift = Self.blockShift
        var raw = [UInt8](repeating: 0, count: max(1, blockColumns * blockRows))
        for y in 0..<height {
            for x in 0..<width where bits[y * width + x] & Self.interiorChannels != 0 {
                raw[(y >> shift) * blockColumns + (x >> shift)] = 1
            }
        }
        for row in 0..<blockRows {
            for column in 0..<blockColumns {
                var any: UInt8 = 0
                for dy in -1...1 {
                    for dx in -1...1 {
                        let r = row + dy
                        let c = column + dx
                        if r >= 0 && r < blockRows && c >= 0 && c < blockColumns { any |= raw[r * blockColumns + c] }
                    }
                }
                blocks[row * blockColumns + column] = any
            }
        }
    }

    private func build(_ mask: UInt16, excluding: UInt16 = 0) -> NeuralPixelList {
        var found: [Int32] = []
        let total = width * height
        found.reserveCapacity(total / 8)
        for index in 0..<total {
            let value = bits[index]
            if value & mask != 0 && value & excluding == 0 { found.append(Int32(truncatingIfNeeded: index)) }
        }
        return NeuralPixelList(found)
    }
}

/// What one frame has to touch: which surfaces start as a copy of their rest picture, which
/// rectangles are drawn pixel by pixel, and which lists of lit pixels are drawn, clipped to the
/// frame's region.
struct NeuralDrawPlan: @unchecked Sendable {
    var copyInterior = false
    var copyFront = false
    var interiorRectangle: NeuralRegion?
    var interiorList: NeuralPixelList?
    var interiorClip: NeuralRegion?
    var interiorMask: UInt16 = 0
    var interiorByRectangle = false
    var link = false
    var interiorCovered: NeuralRegion
    var frontRectangle: NeuralRegion?
    var frontList: NeuralPixelList?
    var frontClip: NeuralRegion?
    let bits: UnsafeMutablePointer<UInt16>

    /// `whole` draws everything from the rest pictures and the lit lists; otherwise `previous`
    /// says which channels moved and only the pixels they light are drawn. `dense` asks for every
    /// pixel of `region` instead, which is what the shader would do.
    init(
        frame: NeuralFrame, previous: NeuralFrame?, params: NeuralFrameParams, region: NeuralRegion,
        whole: Bool, dense: Bool, index: NeuralLitIndex, crunch: NeuralRegion
    ) {
        bits = index.bits
        let size = NeuralRegion(minX: 0, minY: 0, maxX: index.width, maxY: index.height)
        interiorCovered = whole ? size : region
        if dense || (!whole && previous == nil) {
            let area = whole ? size : region
            interiorRectangle = area
            frontRectangle = area
            interiorByRectangle = true
            return
        }
        if whole {
            planWholeInterior(params: params, index: index, crunch: crunch)
            if params.still && params.fade == 1 {
                copyFront = true
                frontList = index.list(mask: NeuralLitIndex.frontChannels)
            } else {
                frontRectangle = size
            }
            return
        }
        guard let previous else { return }
        planInterior(frame: frame, previous: previous, params: params, region: region, index: index)
        planFront(frame: frame, previous: previous, params: params, region: region, index: index)
    }

    private mutating func planWholeInterior(params: NeuralFrameParams, index: NeuralLitIndex, crunch: NeuralRegion) {
        if params.crunch > 0 {
            copyInterior = true
            interiorRectangle = crunch
            interiorByRectangle = true
            return
        }
        copyInterior = true
        link = params.ripple != 0
        let mask = params.sweepAmount > 0 ? NeuralLitIndex.interiorActive : NeuralLitIndex.interiorChannels
        interiorMask = mask | (link ? NeuralLitIndex.linkChannel : 0)
        interiorList = index.list(mask: mask, excluding: link ? NeuralLitIndex.linkChannel : 0)
    }

    private mutating func planInterior(
        frame: NeuralFrame, previous: NeuralFrame, params: NeuralFrameParams, region: NeuralRegion,
        index: NeuralLitIndex
    ) {
        if frame.crunch > 0 || previous.crunch > 0 {
            interiorRectangle = region
            interiorByRectangle = true
            return
        }
        var mask: UInt16 = 0
        if frame.sweepAmount > 0 || previous.sweepAmount > 0 {
            mask = NeuralLitIndex.interiorActive
        } else {
            for channel in 0..<8 where NeuralCompositor.changed(channel, frame, previous) {
                mask |= UInt16(1) << UInt16(channel)
            }
            if frame.ripple != 0 || previous.ripple != 0 { mask |= UInt16(1) << 6 }
        }
        link = frame.ripple != 0
        if link { mask &= ~NeuralLitIndex.linkChannel }
        interiorMask = mask | (link ? NeuralLitIndex.linkChannel : 0)
        interiorClip = region
        if mask != 0 { interiorList = index.list(mask: mask, excluding: link ? NeuralLitIndex.linkChannel : 0) }
    }

    private mutating func planFront(
        frame: NeuralFrame, previous: NeuralFrame, params: NeuralFrameParams, region: NeuralRegion,
        index: NeuralLitIndex
    ) {
        guard params.still else {
            frontRectangle = region
            return
        }
        var mask: UInt16 = 0
        for channel in 8..<12 where NeuralCompositor.changed(channel, frame, previous) {
            mask |= UInt16(1) << UInt16(channel)
        }
        if frame.effort != previous.effort || frame.hollow != previous.hollow || frame.rainbow
            || previous.rainbow
        {
            mask |= UInt16(1) << 9
        }
        frontClip = region
        if mask != 0 { frontList = index.list(mask: mask) }
    }

    /// The positions of `list` that lie on the rows of `region`, and the columns to test when the
    /// region does not span the picture.
    func clip(_ list: NeuralPixelList, to region: NeuralRegion?, width: Int) -> (Range<Int>, Range<Int>?) {
        guard let region else { return (0..<list.count, nil) }
        let span = list.positions(rows: region.minY..<region.maxY, width: width)
        let columns: Range<Int>? = region.minX > 0 || region.maxX < width ? region.minX..<region.maxX : nil
        return (span, columns)
    }
}

/// The ripple's phase at every link pixel for one centre: the sine and cosine of the distance to
/// it times 38, so a frame finds the ripple at a pixel as `sin(a - b)` from two products and no
/// square root or sine per pixel. The arrays run in step with the link list.
final class NeuralRippleField: @unchecked Sendable {
    let actX: Float
    let actY: Float
    let count: Int
    let sine: UnsafeMutablePointer<Float>
    let cosine: UnsafeMutablePointer<Float>

    init(list: NeuralPixelList, width: Int, height: Int, actX: Float, actY: Float) {
        self.actX = actX
        self.actY = actY
        count = list.count
        sine = UnsafeMutablePointer<Float>.allocate(capacity: max(1, count))
        cosine = UnsafeMutablePointer<Float>.allocate(capacity: max(1, count))
        let aspect = Float(width) / Float(height)
        let invWidth = 1 / Float(width)
        let invHeight = 1 / Float(height)
        let sines = NeuralUnsafe(sine)
        let cosines = NeuralUnsafe(cosine)
        let indices = NeuralConst(UnsafePointer(list.indices))
        NeuralParallel.rows(0..<count, minimumPerChunk: 4096, minimumPerWorker: 65536) { range in
            for position in range {
                let index = Int(indices.pointer[position])
                let y = index / width
                let x = index - y * width
                let dx = ((Float(x) + 0.5) * invWidth - actX) * aspect
                let dy = (Float(y) + 0.5) * invHeight - actY
                let phase = (dx * dx + dy * dy).squareRoot() * 38
                sines.pointer[position] = sinf(phase)
                cosines.pointer[position] = cosf(phase)
            }
        }
    }

    deinit {
        sine.deallocate()
        cosine.deallocate()
    }

    var byteCount: Int { count * 2 * MemoryLayout<Float>.stride }
}
