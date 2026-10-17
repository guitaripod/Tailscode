import Metal
import TailscodeCore
import simd

typealias NeuralToneBlock = (
    SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
    SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
    SIMD4<Float>
)

typealias NeuralIntensityTable = (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)

typealias NeuralZoneTable = (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>)

/// Sizes and offsets shared with `NeuralShaders.metal`. A ring slot holds one interior block and
/// one front block, each on the 256-byte boundary a Mac requires of a buffer offset.
enum NeuralUniformLayout {
    static let channelCount = 13
    static let interiorStride = 384
    static let frontStride = 320
    static let vertexStride = 48
    static let interiorOffset = 0
    static let frontOffset = 512
    static let slotStride = 1024
    static let ringDepth = 3
    static let designWidth: Float = 640
    static let designHeight: Float = 420
}

/// The zoom into the head: the front reads the chassis and the glass from a point scaled about
/// `centre`, the interior ignores it. `centre` is in texture space (0 to 1, y down).
struct NeuralDiveUniform: Sendable, Equatable {
    var centre: SIMD2<Float>
    var chassisScale: Float
    var glassScale: Float
    var fade: Float

    static let none = NeuralDiveUniform(
        centre: SIMD2<Float>(0.5, 0.5), chassisScale: 1, glassScale: 1, fade: 1)
}

/// What the interior pass reads. Field order, offsets and size match the MSL struct of the same
/// name; colours are linear RGB in `xyz`.
struct NeuralInteriorUniforms: Sendable {
    var tone: NeuralToneBlock
    var intensity: NeuralIntensityTable
    var background: SIMD4<Float>
    var sweepTone: SIMD4<Float>
    var crunchZones: NeuralZoneTable
    var act: SIMD2<Float>
    var time: Float
    var ripple: Float
    var aspect: Float
    var sweep: Float
    var sweepAmount: Float
    var crunch: Float
}

/// What the front pass reads. The three trailing floats are padding to the 16-byte boundary.
struct NeuralFrontUniforms: Sendable {
    var tone: NeuralToneBlock
    var intensity: NeuralIntensityTable
    var center: SIMD2<Float>
    var chassisScale: Float
    var glassScale: Float
    var fade: Float
    var time: Float
    var effort: Float
    var hollow: Float
    var ribs: Float
    var pad0: Float
    var pad1: Float
    var pad2: Float
}

/// What both vertex stages read. A design-space point becomes `point * clipScale + clipOffset`;
/// `rect` is the quad's x, y, width and height in design space.
struct NeuralVertexUniforms: Sendable {
    var rect: SIMD4<Float>
    var clipScale: SIMD2<Float>
    var clipOffset: SIMD2<Float>
    var designSize: SIMD2<Float>
    var pad: SIMD2<Float>

    /// The whole 640 by 420 design drawn across the whole target.
    static let full = NeuralVertexUniforms(
        rect: SIMD4<Float>(0, 0, NeuralUniformLayout.designWidth, NeuralUniformLayout.designHeight)
    )

    /// A quad over `rect` in design space, the target being the whole design.
    init(rect: SIMD4<Float>) {
        self.rect = rect
        clipScale = SIMD2<Float>(
            2 / NeuralUniformLayout.designWidth, -2 / NeuralUniformLayout.designHeight)
        clipOffset = SIMD2<Float>(-1, 1)
        designSize = SIMD2<Float>(
            NeuralUniformLayout.designWidth, NeuralUniformLayout.designHeight)
        pad = SIMD2<Float>(0, 0)
    }
}

/// The specialisations of the two fragment functions, one bit per function constant: the bit
/// number is the constant's index in `NeuralShaders.metal`.
struct NeuralPipelineKey: OptionSet, Hashable, Sendable {
    let rawValue: UInt8

    init(rawValue: UInt8) { self.rawValue = rawValue }

    static let spill = NeuralPipelineKey(rawValue: 1 << 0)
    static let ripple = NeuralPipelineKey(rawValue: 1 << 1)
    static let sweep = NeuralPipelineKey(rawValue: 1 << 2)
    static let crunch = NeuralPipelineKey(rawValue: 1 << 3)
    static let rainbow = NeuralPipelineKey(rawValue: 1 << 4)

    static let all: NeuralPipelineKey = [.spill, .ripple, .sweep, .crunch, .rainbow]

    /// The terms this frame needs: the ripple, the sweep and the compaction's pull only while
    /// they are in play, the rainbow for ultracode, the spill over a dark page.
    init(frame: NeuralFrame, spill: Bool) {
        var key: NeuralPipelineKey = []
        if spill { key.insert(.spill) }
        if frame.ripple > 0 { key.insert(.ripple) }
        if frame.sweepAmount > 0 { key.insert(.sweep) }
        if frame.crunch > 0 { key.insert(.crunch) }
        if frame.rainbow { key.insert(.rainbow) }
        self = key
    }

    /// The function constants for building this specialisation, every one set explicitly.
    func constantValues() -> MTLFunctionConstantValues {
        let values = MTLFunctionConstantValues()
        for index in 0..<5 {
            var on = contains(NeuralPipelineKey(rawValue: 1 << UInt8(index)))
            values.setConstantValue(&on, type: .bool, index: index)
        }
        return values
    }
}

/// What the interior pass draws as the vertex buffer: a triangle list of float2 in design space,
/// stride 8, attribute 0 of buffer 0. Two triangles per row band of `NeuralLitBands`, which cover
/// everything the interior layer and its glow light and nothing of the dark corners. The dome's
/// outline alone is too small: the galaxies' halos, the jaw and the bloom reach past it.
enum NeuralDomeMesh {
    static let stride = MemoryLayout<SIMD2<Float>>.stride

    static func vertices() -> [SIMD2<Float>] {
        var out: [SIMD2<Float>] = []
        out.reserveCapacity(NeuralLitBands.rows.count * 6)
        for band in NeuralLitBands.rows {
            let topLeft = SIMD2<Float>(band.x0, band.y0)
            let topRight = SIMD2<Float>(band.x1, band.y0)
            let bottomLeft = SIMD2<Float>(band.x0, band.y1)
            let bottomRight = SIMD2<Float>(band.x1, band.y1)
            out += [topLeft, topRight, bottomLeft, topRight, bottomRight, bottomLeft]
        }
        return out
    }
}

enum NeuralUniforms {
    private static let zoneCentres: NeuralZoneTable = {
        let points = NeuralZone.allCases.map {
            SIMD2<Float>(
                Float($0.center.x) / NeuralUniformLayout.designWidth,
                Float($0.center.y) / NeuralUniformLayout.designHeight)
        }
        return (
            SIMD4<Float>(points[0].x, points[0].y, points[1].x, points[1].y),
            SIMD4<Float>(points[2].x, points[2].y, points[3].x, points[3].y),
            SIMD4<Float>(points[4].x, points[4].y, points[5].x, points[5].y)
        )
    }()

    /// Each place where the Swift layout and the shader's disagree, empty when they match. A
    /// test on the Mac calls it.
    static func layoutMismatches() -> [String] {
        var problems: [String] = []
        func expect(_ name: String, _ actual: Int?, _ wanted: Int) {
            if actual != wanted { problems.append("\(name) \(actual.map(String.init) ?? "nil") != \(wanted)") }
        }
        expect("interior stride", MemoryLayout<NeuralInteriorUniforms>.stride, NeuralUniformLayout.interiorStride)
        expect("front stride", MemoryLayout<NeuralFrontUniforms>.stride, NeuralUniformLayout.frontStride)
        expect("vertex stride", MemoryLayout<NeuralVertexUniforms>.stride, NeuralUniformLayout.vertexStride)
        expect("tone table", MemoryLayout<NeuralToneBlock>.stride, 208)
        expect("intensity table", MemoryLayout<NeuralIntensityTable>.stride, 64)
        expect("interior intensity", MemoryLayout<NeuralInteriorUniforms>.offset(of: \.intensity), 208)
        expect("interior background", MemoryLayout<NeuralInteriorUniforms>.offset(of: \.background), 272)
        expect("interior sweepTone", MemoryLayout<NeuralInteriorUniforms>.offset(of: \.sweepTone), 288)
        expect("interior crunchZones", MemoryLayout<NeuralInteriorUniforms>.offset(of: \.crunchZones), 304)
        expect("interior act", MemoryLayout<NeuralInteriorUniforms>.offset(of: \.act), 352)
        expect("interior time", MemoryLayout<NeuralInteriorUniforms>.offset(of: \.time), 360)
        expect("interior ripple", MemoryLayout<NeuralInteriorUniforms>.offset(of: \.ripple), 364)
        expect("interior aspect", MemoryLayout<NeuralInteriorUniforms>.offset(of: \.aspect), 368)
        expect("interior sweep", MemoryLayout<NeuralInteriorUniforms>.offset(of: \.sweep), 372)
        expect("interior sweepAmount", MemoryLayout<NeuralInteriorUniforms>.offset(of: \.sweepAmount), 376)
        expect("interior crunch", MemoryLayout<NeuralInteriorUniforms>.offset(of: \.crunch), 380)
        expect("front intensity", MemoryLayout<NeuralFrontUniforms>.offset(of: \.intensity), 208)
        expect("front center", MemoryLayout<NeuralFrontUniforms>.offset(of: \.center), 272)
        expect("front chassisScale", MemoryLayout<NeuralFrontUniforms>.offset(of: \.chassisScale), 280)
        expect("front glassScale", MemoryLayout<NeuralFrontUniforms>.offset(of: \.glassScale), 284)
        expect("front fade", MemoryLayout<NeuralFrontUniforms>.offset(of: \.fade), 288)
        expect("front time", MemoryLayout<NeuralFrontUniforms>.offset(of: \.time), 292)
        expect("front effort", MemoryLayout<NeuralFrontUniforms>.offset(of: \.effort), 296)
        expect("front hollow", MemoryLayout<NeuralFrontUniforms>.offset(of: \.hollow), 300)
        expect("front ribs", MemoryLayout<NeuralFrontUniforms>.offset(of: \.ribs), 304)
        expect("vertex clipScale", MemoryLayout<NeuralVertexUniforms>.offset(of: \.clipScale), 16)
        expect("vertex clipOffset", MemoryLayout<NeuralVertexUniforms>.offset(of: \.clipOffset), 24)
        expect("vertex designSize", MemoryLayout<NeuralVertexUniforms>.offset(of: \.designSize), 32)
        if NeuralUniformLayout.interiorOffset + NeuralUniformLayout.interiorStride > NeuralUniformLayout.frontOffset
            || NeuralUniformLayout.frontOffset + NeuralUniformLayout.frontStride > NeuralUniformLayout.slotStride
        {
            problems.append("a block overruns its place in the ring slot")
        }
        if NeuralUniformLayout.frontOffset % 256 != 0 || NeuralUniformLayout.slotStride % 256 != 0 {
            problems.append("ring slot is not 256-byte aligned")
        }
        return problems
    }

    /// Writes one frame's interior and front blocks into a ring slot, in place and without
    /// allocating. `tones` are the thirteen linear channel colours with the frame's overrides
    /// already applied (`NeuralPalette.channelTones`); `background` and `sweepTone` are linear
    /// too. The slot must be `NeuralUniformLayout.slotStride` bytes.
    static func fill(
        into slot: UnsafeMutableRawPointer, frame: NeuralFrame, tones: [NeuralRGB],
        background: NeuralRGB, sweepTone: NeuralRGB, time: Float, aspect: Float,
        dive: NeuralDiveUniform = .none
    ) {
        let interior = slot.advanced(by: NeuralUniformLayout.interiorOffset)
            .bindMemory(to: NeuralInteriorUniforms.self, capacity: 1)
        let front = slot.advanced(by: NeuralUniformLayout.frontOffset)
            .bindMemory(to: NeuralFrontUniforms.self, capacity: 1)
        writeTones(tones, into: &interior.pointee.tone)
        writeTones(tones, into: &front.pointee.tone)
        writeIntensity(frame.intensity, into: &interior.pointee.intensity)
        writeIntensity(frame.intensity, into: &front.pointee.intensity)
        interior.pointee.background = SIMD4<Float>(background.r, background.g, background.b, 0)
        interior.pointee.sweepTone = SIMD4<Float>(sweepTone.r, sweepTone.g, sweepTone.b, 0)
        interior.pointee.crunchZones = zoneCentres
        if let active = frame.active {
            interior.pointee.act = SIMD2<Float>(
                Float(active.x) / NeuralUniformLayout.designWidth,
                Float(active.y) / NeuralUniformLayout.designHeight)
        } else {
            interior.pointee.act = SIMD2<Float>(0.5, 0.5)
        }
        interior.pointee.time = time
        interior.pointee.ripple = frame.ripple
        interior.pointee.aspect = aspect
        interior.pointee.sweep = frame.sweep
        interior.pointee.sweepAmount = frame.sweepAmount
        interior.pointee.crunch = frame.crunch
        front.pointee.center = dive.centre
        front.pointee.chassisScale = dive.chassisScale
        front.pointee.glassScale = dive.glassScale
        front.pointee.fade = dive.fade
        front.pointee.time = time
        front.pointee.effort = frame.effort
        front.pointee.hollow = frame.hollow ? 1 : 0
        front.pointee.ribs = frame.ribs
        front.pointee.pad0 = 0
        front.pointee.pad1 = 0
        front.pointee.pad2 = 0
    }

    private static func writeTones(_ tones: [NeuralRGB], into table: inout NeuralToneBlock) {
        withUnsafeMutablePointer(to: &table) { pointer in
            pointer.withMemoryRebound(
                to: SIMD4<Float>.self, capacity: NeuralUniformLayout.channelCount
            ) { rows in
                for index in 0..<NeuralUniformLayout.channelCount {
                    if index < tones.count {
                        let tone = tones[index]
                        rows[index] = SIMD4<Float>(tone.r, tone.g, tone.b, 0)
                    } else {
                        rows[index] = SIMD4<Float>(0, 0, 0, 0)
                    }
                }
            }
        }
    }

    private static func writeIntensity(_ values: [Float], into table: inout NeuralIntensityTable) {
        withUnsafeMutablePointer(to: &table) { pointer in
            pointer.withMemoryRebound(to: Float.self, capacity: 16) { lanes in
                for index in 0..<16 {
                    lanes[index] = index < values.count && index < NeuralUniformLayout.channelCount
                        ? values[index] : 0
                }
            }
        }
    }
}
