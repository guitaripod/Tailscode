import Foundation

/// The two shader passes: one pixel at a time, over a rectangle, or over a list of pixels.
enum NeuralKernels {
    @inline(__always)
    static func load(_ pointer: UnsafePointer<UInt8>, _ index: Int) -> SIMD4<Float> {
        SIMD4<Float>(UnsafeRawPointer(pointer).loadUnaligned(fromByteOffset: index * 4, as: SIMD4<UInt8>.self))
            * (1.0 / 255)
    }

    @inline(__always)
    static func word(_ pointer: UnsafePointer<UInt8>, _ index: Int) -> UInt32 {
        UnsafeRawPointer(pointer).loadUnaligned(fromByteOffset: index * 4, as: UInt32.self)
    }

    /// Component-wise `min(max(v, 0), 1)`, written out so it stays inline in the pixel loops.
    @inline(__always)
    static func clamp01(_ value: SIMD3<Float>) -> SIMD3<Float> {
        SIMD3(min(max(value.x, 0), 1), min(max(value.y, 0), 1), min(max(value.z, 0), 1))
    }

    /// The row of a pixel index, from a 32-bit division: a 64-bit one is several times slower on
    /// the cores that are not the newest.
    @inline(__always)
    static func row(of index: Int, _ layers: NeuralLayerPointers) -> Int {
        Int(UInt32(truncatingIfNeeded: index) / UInt32(truncatingIfNeeded: layers.width))
    }

    /// `min(max(floor(value), 0), top)` without a library call, and 0 for NaN.
    @inline(__always)
    static func floorClamped(_ value: Float, _ top: Float) -> Float {
        guard value > 0 else { return 0 }
        return Float(Int32(min(value, top)))
    }

    /// Where a bilinear sample at one point reads: four pixel offsets and two weights, worked out
    /// once and applied to as many layers as are read there.
    struct Tap {
        var i00: Int
        var i10: Int
        var i01: Int
        var i11: Int
        var column: Int
        var row: Int
        var ax: Float
        var ay: Float
    }

    @inline(__always)
    static func tap(_ layers: NeuralLayerPointers, _ u: Float, _ t: Float) -> Tap {
        let width = layers.width
        let height = layers.height
        let fx = min(max(u * Float(width) - 0.5, -1), Float(width))
        let fy = min(max(t * Float(height) - 0.5, -1), Float(height))
        let x0 = NeuralImage.flooredInt(fx)
        let y0 = NeuralImage.flooredInt(fy)
        let xa = min(max(x0, 0), width - 1)
        let xb = min(max(x0 + 1, 0), width - 1)
        let ya = min(max(y0, 0), height - 1)
        let yb = min(max(y0 + 1, 0), height - 1)
        return Tap(
            i00: (ya * width + xa) * 4, i10: (ya * width + xb) * 4, i01: (yb * width + xa) * 4,
            i11: (yb * width + xb) * 4, column: xa, row: ya, ax: fx - Float(x0), ay: fy - Float(y0))
    }

    @inline(__always)
    static func blend(_ pixels: UnsafePointer<UInt8>, _ tap: Tap) -> SIMD4<Float> {
        let raw = UnsafeRawPointer(pixels)
        let p00 = SIMD4<Float>(raw.loadUnaligned(fromByteOffset: tap.i00, as: SIMD4<UInt8>.self))
        let p10 = SIMD4<Float>(raw.loadUnaligned(fromByteOffset: tap.i10, as: SIMD4<UInt8>.self))
        let p01 = SIMD4<Float>(raw.loadUnaligned(fromByteOffset: tap.i01, as: SIMD4<UInt8>.self))
        let p11 = SIMD4<Float>(raw.loadUnaligned(fromByteOffset: tap.i11, as: SIMD4<UInt8>.self))
        let top = p00 + (p10 - p00) * tap.ax
        let bottom = p01 + (p11 - p01) * tap.ax
        return (top + (bottom - top) * tap.ay) * (1.0 / 255.0)
    }

    @inline(__always)
    static func blockIndex(_ point: Tap, _ layers: NeuralLayerPointers) -> Int {
        (point.row >> NeuralLitIndex.blockShift) * layers.blockColumns + (point.column >> NeuralLitIndex.blockShift)
    }

    /// The four layers the crunch reads, sampled at one point; nil where the lit-block map says
    /// all four are zero there.
    @inline(__always)
    static func sampleFour(
        _ layers: NeuralLayerPointers, _ u: Float, _ t: Float
    ) -> (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)? {
        let point = tap(layers, u, t)
        guard layers.blocks[blockIndex(point, layers)] != 0 else { return nil }
        return (
            blend(layers.mask0, point), blend(layers.mask1, point), blend(layers.bloom0, point),
            blend(layers.bloom1, point)
        )
    }

    @inline(__always)
    static func byte(_ value: Float) -> UInt8 {
        UInt8(min(max(value * 255 + 0.5, 0), 255))
    }

    @inline(__always)
    static func sample(
        _ pointer: UnsafePointer<UInt8>, _ layers: NeuralLayerPointers, _ u: Float, _ t: Float
    ) -> SIMD4<Float> {
        NeuralImage.bilinear(pointer, width: layers.width, height: layers.height, u: u, t: t)
    }

    /// Which of the six zone centres is nearest a point, the first of equals, as the warp reads it.
    @inline(__always)
    static func nearestZone(u: Float, t: Float, aspect: Float, zoneX: SIMD8<Float>, zoneY: SIMD8<Float>) -> Int {
        var best = 0
        var nearest = Float.greatestFiniteMagnitude
        for index in 0..<6 {
            let dx = (u - zoneX[index]) * aspect
            let dy = t - zoneY[index]
            let distance = dx * dx + dy * dy
            if distance < nearest {
                nearest = distance
                best = index
            }
        }
        return best
    }

    @inline(__always)
    static func crunchUV(
        u: Float, t: Float, index: Int, layers: NeuralLayerPointers, params: NeuralFrameParams
    ) -> SIMD2<Float> {
        let zone: Int
        if let plane = layers.zoneOf {
            zone = Int(plane[index])
        } else {
            zone = nearestZone(u: u, t: t, aspect: params.aspect, zoneX: params.zoneX, zoneY: params.zoneY)
        }
        let bx = params.zoneX[zone]
        let by = params.zoneY[zone]
        let scale = 1 + 0.7 * params.crunch
        return SIMD2(bx + (u - bx) * scale, by + (t - by) * scale)
    }

    @_optimize(speed)
    static func interior(
        rows: Range<Int>, columns: Range<Int>, layers: NeuralLayerPointers, params: NeuralFrameParams,
        out: UnsafeMutablePointer<UInt8>
    ) {
        for y in rows {
            for x in columns {
                interiorPixel(index: y * layers.width + x, x: x, y: y, layers: layers, params: params, out: out)
            }
        }
    }

    /// The pixels `indices[positions]`, of which only those inside `columns` when it is given.
    @_optimize(speed)
    static func interior(
        positions: Range<Int>, indices: UnsafePointer<Int32>, columns: Range<Int>?,
        layers: NeuralLayerPointers, params: NeuralFrameParams, out: UnsafeMutablePointer<UInt8>
    ) {
        let width = layers.width
        let needsPosition = params.needsPosition || columns != nil
        for position in positions {
            let index = Int(indices[position])
            var x = 0
            var y = 0
            if needsPosition {
                y = row(of: index, layers)
                x = index - y * width
                if let columns, !columns.contains(x) { continue }
            }
            interiorPixel(index: index, x: x, y: y, layers: layers, params: params, out: out)
        }
    }

    /// The link pixels `indices[positions]` (or, through `ranks`, the ones those positions name),
    /// with the ripple read from `field`. Pixels inside `outside`, or outside `columns`, are left.
    @_optimize(speed)
    static func interiorRipple(
        positions: Range<Int>, indices: UnsafePointer<Int32>, ranks: UnsafePointer<Int32>?,
        outside: NeuralRegion?, columns: Range<Int>?, field: NeuralRippleField,
        layers: NeuralLayerPointers, params: NeuralFrameParams, out: UnsafeMutablePointer<UInt8>
    ) {
        let width = layers.width
        let sine = field.sine
        let cosine = field.cosine
        let needsPosition =
            params.sweepAmount > 0 || params.crunch > 0 || columns != nil || outside != nil
        let amplitude = params.ripple * 0.45
        for position in positions {
            let rank = ranks.map { Int($0[position]) } ?? position
            let index = Int(indices[rank])
            var x = 0
            var y = 0
            if needsPosition {
                y = row(of: index, layers)
                x = index - y * width
                if let columns, !columns.contains(x) { continue }
                if let outside, outside.contains(x: x, y: y) { continue }
            }
            let factor = 1 + amplitude * (sine[rank] * params.rippleCos - cosine[rank] * params.rippleSin)
            interiorPixel(
                index: index, x: x, y: y, layers: layers, params: params, out: out, given: factor)
        }
    }

    /// One interior pixel: only the channels the layers light there are summed, in channel order.
    @_optimize(speed)
    @inline(__always)
    static func interiorPixel(
        index: Int, x: Int, y: Int, layers: NeuralLayerPointers, params: NeuralFrameParams,
        out: UnsafeMutablePointer<UInt8>, given: Float = .nan
    ) {
        if params.crunch > 0 {
            interiorWarped(index: index, x: x, y: y, layers: layers, params: params, out: out)
            return
        }
        let channels = Int(layers.bits[index]) & 0xFF
        let dest = out + index * 4
        if channels == 0 && params.sweepAmount <= 0 {
            UnsafeMutableRawPointer(dest).storeBytes(of: word(layers.base, index), as: UInt32.self)
            return
        }
        var u: Float = 0
        var t: Float = 0
        if params.needsPosition {
            u = (Float(x) + 0.5) * layers.invWidth
            t = (Float(y) + 0.5) * layers.invHeight
        }
        var glow = SIMD3<Float>(repeating: 0)
        var rest = channels
        while rest != 0 {
            let channel = rest.trailingZeroBitCount
            rest &= rest &- 1
            let offset = index * 4 + (channel & 3)
            let masks = channel < 4 ? layers.mask0 : layers.mask1
            let blooms = channel < 4 ? layers.bloom0 : layers.bloom1
            var weight = Float(masks[offset]) * (1.0 / 255) * 4 + Float(blooms[offset]) * (1.0 / 255) * 2
            if channel == 6 && params.ripple != 0 {
                if given.isNaN {
                    let dx = (u - params.actX) * params.aspect
                    let dy = t - params.actY
                    weight *= 1 + params.ripple * 0.45 * sin((dx * dx + dy * dy).squareRoot() * 38 - params.time * 3.2)
                } else {
                    weight *= given
                }
            }
            glow += params.tones[channel] * weight
        }
        finishInterior(index: index, u: u, t: t, glow: glow, layers: layers, params: params, dest: dest)
    }

    /// The compaction's crunch: the four layers are sampled where the pixel is pulled to, so every
    /// pixel may be lit.
    @_optimize(speed)
    static func interiorWarped(
        index: Int, x: Int, y: Int, layers: NeuralLayerPointers, params: NeuralFrameParams,
        out: UnsafeMutablePointer<UInt8>
    ) {
        let u = (Float(x) + 0.5) * layers.invWidth
        let t = (Float(y) + 0.5) * layers.invHeight
        let warped = crunchUV(u: u, t: t, index: index, layers: layers, params: params)
        var glow = SIMD3<Float>(repeating: 0)
        if let (m0, m1, b0, b1) = sampleFour(layers, warped.x, warped.y) {
            var ripple: Float = 1
            if params.ripple != 0 && (m1.z != 0 || b1.z != 0) {
                let dx = (u - params.actX) * params.aspect
                let dy = t - params.actY
                ripple = 1 + params.ripple * 0.45 * sin((dx * dx + dy * dy).squareRoot() * 38 - params.time * 3.2)
            }
            let w0 = m0 * 4 + b0 * 2
            var w1 = m1 * 4 + b1 * 2
            w1.z *= ripple
            let tones = params.tones
            glow = tones[0] * w0.x + tones[1] * w0.y + tones[2] * w0.z + tones[3] * w0.w
            glow += tones[4] * w1.x + tones[5] * w1.y + tones[6] * w1.z + tones[7] * w1.w
        } else if params.sweepAmount <= 0 || layers.interior[index * 4 + 3] == 0 {
            UnsafeMutableRawPointer(out + index * 4).storeBytes(of: word(layers.base, index), as: UInt32.self)
            return
        }
        finishInterior(index: index, u: u, t: t, glow: glow, layers: layers, params: params, dest: out + index * 4)
    }

    /// The sweep, the tone map and the screen blend over the pixel's own colour, into BGRA.
    @_optimize(speed)
    @inline(__always)
    static func finishInterior(
        index: Int, u: Float, t: Float, glow: SIMD3<Float>, layers: NeuralLayerPointers,
        params: NeuralFrameParams, dest: UnsafeMutablePointer<UInt8>
    ) {
        let rgba = UnsafeRawPointer(layers.interior).loadUnaligned(fromByteOffset: index * 4, as: SIMD4<UInt8>.self)
        let alpha = Float(rgba.w) * (1.0 / 255)
        let linear = SIMD3<Float>(
            layers.linear[Int(rgba.x)], layers.linear[Int(rgba.y)], layers.linear[Int(rgba.z)])
        let base = params.background * (1 - alpha) + linear * alpha
        var added = glow
        if params.sweepAmount > 0 {
            let luma = glow.x * 0.3 + glow.y * 0.5 + glow.z * 0.2
            let phase = (u * 0.9 + (1 - t) * 0.35 - params.sweep) * 7
            let band = exp(-(phase * phase))
            added += params.sweepTone * (band * params.sweepAmount * (0.14 * alpha + min(luma * 1.2, 1)))
        }
        added = added / (SIMD3<Float>(repeating: 1) + added * 0.2)
        let lifted = clamp01(added)
        let color = SIMD3<Float>(repeating: 1) - (SIMD3<Float>(repeating: 1) - base) * (SIMD3<Float>(repeating: 1) - lifted)
        dest[0] = layers.encode(color.z)
        dest[1] = layers.encode(color.y)
        dest[2] = layers.encode(color.x)
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

    /// The pixels `indices[positions]`, of which only those inside `columns` when it is given.
    /// Only for a front whose layers sit where they were drawn (`params.still`).
    @_optimize(speed)
    static func front(
        positions: Range<Int>, indices: UnsafePointer<Int32>, columns: Range<Int>?,
        layers: NeuralLayerPointers, params: NeuralFrameParams, out: UnsafeMutablePointer<UInt8>
    ) {
        let width = layers.width
        for position in positions {
            let index = Int(indices[position])
            var x = 0
            var y = 0
            if let columns {
                y = row(of: index, layers)
                x = index - y * width
                if !columns.contains(x) { continue }
            }
            frontLit(index: index, layers: layers, params: params, out: out)
        }
    }

    /// A front pixel no channel lights: the chassis and the glass over it, nothing glowing.
    @_optimize(speed)
    static func frontRestPixel(
        index: Int, layers: NeuralLayerPointers, out: UnsafeMutablePointer<UInt8>
    ) {
        let c = UnsafeRawPointer(layers.chassis).loadUnaligned(fromByteOffset: index * 4, as: SIMD4<UInt8>.self)
        let g = UnsafeRawPointer(layers.glass).loadUnaligned(fromByteOffset: index * 4, as: SIMD4<UInt8>.self)
        compose(
            chassis: SIMD4<Float>(c) * (1.0 / 255), glass: SIMD4<Float>(g) * (1.0 / 255),
            chassisLinear: SIMD3(layers.linear[Int(c.x)], layers.linear[Int(c.y)], layers.linear[Int(c.z)]),
            glassLinear: SIMD3(layers.linear[Int(g.x)], layers.linear[Int(g.y)], layers.linear[Int(g.z)]),
            glow: SIMD3(repeating: 0), spill: 0, fade: 1, layers: layers, dest: out + index * 4)
    }

    /// One front pixel of a still front, summing only the channels the layers light there.
    @_optimize(speed)
    @inline(__always)
    static func frontLit(
        index: Int, layers: NeuralLayerPointers, params: NeuralFrameParams,
        out: UnsafeMutablePointer<UInt8>
    ) {
        let c = UnsafeRawPointer(layers.chassis).loadUnaligned(fromByteOffset: index * 4, as: SIMD4<UInt8>.self)
        let g = UnsafeRawPointer(layers.glass).loadUnaligned(fromByteOffset: index * 4, as: SIMD4<UInt8>.self)
        var channels = (Int(layers.bits[index]) >> 8) & 0xF
        var glow = SIMD3<Float>(repeating: 0)
        if channels != 0 {
            var u1: Float = 0
            var t1: Float = 0
            if channels & 0b0110 != 0 {
                let y = row(of: index, layers)
                u1 = (Float(index - y * layers.width) + 0.5) * layers.invWidth
                t1 = (Float(y) + 0.5) * layers.invHeight
            }
            while channels != 0 {
                let component = channels.trailingZeroBitCount
                channels &= channels &- 1
                let offset = index * 4 + component
                let packed =
                    Float(layers.mask2[offset]) * (1.0 / 255)
                    + Float(layers.bloom2[offset]) * (1.0 / 255) * (4.0 / 3.0)
                switch component {
                case 0: glow += seam(packed, params)
                case 1: glow += eye(packed, u1, params)
                case 2: glow += rib(packed, t1, params)
                default: glow += ear(packed, params)
                }
            }
        }
        compose(
            chassis: SIMD4<Float>(c) * (1.0 / 255), glass: SIMD4<Float>(g) * (1.0 / 255),
            chassisLinear: SIMD3(layers.linear[Int(c.x)], layers.linear[Int(c.y)], layers.linear[Int(c.z)]),
            glassLinear: SIMD3(layers.linear[Int(g.x)], layers.linear[Int(g.y)], layers.linear[Int(g.z)]),
            glow: glow, spill: params.spill, fade: params.fade, layers: layers, dest: out + index * 4)
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
            chassisLinear = SIMD3(layers.linear[Int(c.x)], layers.linear[Int(c.y)], layers.linear[Int(c.z)])
            glassLinear = SIMD3(layers.linear[Int(g.x)], layers.linear[Int(g.y)], layers.linear[Int(g.z)])
            packed = load(layers.mask2, index) + load(layers.bloom2, index) * (4.0 / 3.0)
        } else {
            let u = u1
            let t = t1
            u1 = (u - params.centerX) / params.chassisScale + params.centerX
            t1 = (t - params.centerY) / params.chassisScale + params.centerY
            let u2 = (u - params.centerX) / params.glassScale + params.centerX
            let t2 = (t - params.centerY) / params.glassScale + params.centerY
            let chassisTap = tap(layers, u1, t1)
            let glassTap = tap(layers, u2, t2)
            chassis = blend(layers.chassis, chassisTap)
            glass = blend(layers.glass, glassTap)
            chassisLinear =
                chassis.w == 0
                ? SIMD3(repeating: 0) : SIMD3(powf(chassis.x, 2.2), powf(chassis.y, 2.2), powf(chassis.z, 2.2))
            glassLinear =
                glass.w == 0 ? SIMD3(repeating: 0) : SIMD3(powf(glass.x, 2.2), powf(glass.y, 2.2), powf(glass.z, 2.2))
            packed = blend(layers.mask2, chassisTap) + blend(layers.bloom2, chassisTap) * (4.0 / 3.0)
        }
        compose(
            chassis: chassis, glass: glass, chassisLinear: chassisLinear, glassLinear: glassLinear,
            glow: glow(packed: packed, u1: u1, t1: t1, params: params), spill: params.spill, fade: params.fade,
            layers: layers, dest: dest)
    }

    @inline(__always)
    static func seam(_ packed: Float, _ params: NeuralFrameParams) -> SIMD3<Float> {
        params.seamGain * packed
    }

    @inline(__always)
    static func eye(_ packed: Float, _ u1: Float, _ params: NeuralFrameParams) -> SIMD3<Float> {
        let xd = u1 * 640
        let segment = floorClamped((xd - 562) / 8.2, 4)
        let lit: Float = segment < params.effort ? 1 : (params.hollow ? 0.1 : 0.14)
        var tone = params.eyeTone
        if params.rainbow > 0 {
            let phase = (u1 * 5 - params.time * 0.3) * 6.2831853
            let rainbow = SIMD3<Float>(
                0.5 + 0.5 * cos(phase), 0.5 + 0.5 * cos(phase + 0.33 * 6.2831853),
                0.5 + 0.5 * cos(phase + 0.67 * 6.2831853))
            tone = tone + (rainbow - tone) * params.rainbow
        }
        return tone * (params.eyeGain * lit * packed)
    }

    @inline(__always)
    static func rib(_ packed: Float, _ t1: Float, _ params: NeuralFrameParams) -> SIMD3<Float> {
        let yd = t1 * 420
        let index = floorClamped((yd - 381) / 6, 5)
        let lit = min(max(params.ribs - (5 - index), 0), 1)
        return params.ribGain * (lit * packed)
    }

    @inline(__always)
    static func ear(_ packed: Float, _ params: NeuralFrameParams) -> SIMD3<Float> {
        params.earGain * packed
    }

    /// What the four front channels add at a pixel, before the chassis gates it.
    @inline(__always)
    static func glow(packed: SIMD4<Float>, u1: Float, t1: Float, params: NeuralFrameParams) -> SIMD3<Float> {
        var glow = SIMD3<Float>(repeating: 0)
        if packed.x > 0 { glow += seam(packed.x, params) }
        if packed.y > 0 { glow += eye(packed.y, u1, params) }
        if packed.z > 0 { glow += rib(packed.z, t1, params) }
        if packed.w > 0 { glow += ear(packed.w, params) }
        return glow
    }

    /// The chassis, the glow, the fade and the glass laid over each other into one premultiplied
    /// BGRA pixel; the alpha is raised to the largest colour channel so cairo takes it.
    @inline(__always)
    static func compose(
        chassis: SIMD4<Float>, glass: SIMD4<Float>, chassisLinear: SIMD3<Float>, glassLinear: SIMD3<Float>,
        glow raw: SIMD3<Float>, spill: Float, fade: Float, layers: NeuralLayerPointers,
        dest: UnsafeMutablePointer<UInt8>
    ) {
        var glow = raw * (chassis.w * (1 - spill) + spill)
        glow = glow / (SIMD3<Float>(repeating: 1) + glow * 0.2)
        var spilled: Float = 0
        if spill > 0.5 {
            spilled = min(max(max(glow.x, max(glow.y, glow.z)), 0), 1)
        }
        var color = (chassisLinear * chassis.w + glow) * fade
        var alpha = min(max(chassis.w + spilled, 0), 1) * fade
        let glassAlpha = glass.w * (1 - 0.8 * (1 - fade))
        color = color * (1 - glassAlpha) + glassLinear * glassAlpha
        alpha = alpha * (1 - glassAlpha) + glassAlpha
        let clamped = clamp01(color)
        let blue = layers.encode(clamped.z)
        let green = layers.encode(clamped.y)
        let red = layers.encode(clamped.x)
        dest[0] = blue
        dest[1] = green
        dest[2] = red
        dest[3] = max(byte(min(max(alpha, 0), 1)), max(red, max(green, blue)))
    }
}
