import CoreGraphics
import Dispatch
import Foundation
@preconcurrency import Metal
import QuartzCore
import TailscodeCore
import os

/// Draws one `WallScene` per frame in a single render pass: the ground, the glass plates and bars, the
/// motes, the glyphs and the added light. Instance data goes straight into buffers allocated once, three
/// frames deep, so a frame allocates nothing.
public final class WallRenderer: @unchecked Sendable {
    static let maxPlates = 128
    static let maxBars = 768
    static let maxGlyphs = 512
    static let maxGlows = 384
    static let maxDots = 2400
    static let maxLights = 8
    static let maxRipples = 12
    static let framesInFlight = 3
    static let instanceFloats = 16
    static let dotFloats = 8

    struct FrameUniforms {
        var canvas: SIMD2<Float>
        var shift: SIMD2<Float>
        var scale: Float
        var unit: Float
        var dim: Float
        var pad: Float = 0
        var text: SIMD4<Float>
        var dimInk: SIMD4<Float>
    }

    struct Slot {
        let quads: MTLBuffer
        let glyphs: MTLBuffer
        let glows: MTLBuffer
        let dots: MTLBuffer
    }

    let device: MTLDevice
    let groundState: MTLRenderPipelineState
    let plateState: MTLRenderPipelineState
    let glyphState: MTLRenderPipelineState
    let glowState: MTLRenderPipelineState
    let pointState: MTLRenderPipelineState
    let slots: [Slot]
    let groundScratch: UnsafeMutablePointer<Float>
    private let inFlight = DispatchSemaphore(value: WallRenderer.framesInFlight)
    private var slotIndex = 0
    private let gpuTime = OSAllocatedUnfairLock<Double>(initialState: 0)

    /// The clock the Aurora field drifts on; nil reads the system's. A snapshot sets it so two renders
    /// of one scene match.
    public var time: TimeInterval?

    /// Seconds the last finished frame spent on the GPU, for a DEBUG overlay.
    public var lastGPUTime: Double { gpuTime.withLock { $0 } }

    public init?(device: MTLDevice, pixelFormat: MTLPixelFormat = .bgra8Unorm) {
        guard let library = WallShaders.library(for: device) else { return nil }
        guard
            let ground = Self.pipeline(device, library, "ground_vs", "ground_fs", pixelFormat, .opaque),
            let plate = Self.pipeline(device, library, "plate_vs", "plate_fs", pixelFormat, .over),
            let glyph = Self.pipeline(device, library, "glyph_vs", "glyph_fs", pixelFormat, .over),
            let glow = Self.pipeline(device, library, "glyph_vs", "glyph_fs", pixelFormat, .add),
            let point = Self.pipeline(device, library, "point_vs", "point_fs", pixelFormat, .add)
        else { return nil }
        var made: [Slot] = []
        let stride = Self.instanceFloats * MemoryLayout<Float>.stride
        for _ in 0..<Self.framesInFlight {
            guard
                let quads = device.makeBuffer(length: (Self.maxPlates + Self.maxBars) * stride, options: .storageModeShared),
                let glyphs = device.makeBuffer(length: Self.maxGlyphs * stride, options: .storageModeShared),
                let glows = device.makeBuffer(length: Self.maxGlows * stride, options: .storageModeShared),
                let dots = device.makeBuffer(
                    length: Self.maxDots * Self.dotFloats * MemoryLayout<Float>.stride, options: .storageModeShared)
            else { return nil }
            made.append(Slot(quads: quads, glyphs: glyphs, glows: glows, dots: dots))
        }
        self.device = device
        groundState = ground
        plateState = plate
        glyphState = glyph
        glowState = glow
        pointState = point
        slots = made
        groundScratch = .allocate(capacity: GroundLayout.floats)
        groundScratch.initialize(repeating: 0, count: GroundLayout.floats)
    }

    deinit { groundScratch.deallocate() }

    enum Blend { case opaque, over, add }

    private static func pipeline(
        _ device: MTLDevice, _ library: MTLLibrary, _ vertex: String, _ fragment: String,
        _ format: MTLPixelFormat, _ blend: Blend
    ) -> MTLRenderPipelineState? {
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: vertex)
        descriptor.fragmentFunction = library.makeFunction(name: fragment)
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = format
        if blend != .opaque {
            attachment.isBlendingEnabled = true
            attachment.rgbBlendOperation = .add
            attachment.alphaBlendOperation = .add
            let destination: MTLBlendFactor = blend == .over ? .oneMinusSourceAlpha : .one
            attachment.sourceRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationRGBBlendFactor = destination
            attachment.destinationAlphaBlendFactor = destination
        }
        return try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    /// Draws `scene` into `pass`. The scale to pixels is read from the drawable and the scene's own width,
    /// which is the view's width in points, so the two can never disagree; `pointsPerPixel` is the
    /// fallback for a scene that carries no width.
    public func encode(
        _ scene: WallScene, commandBuffer: MTLCommandBuffer, pass: MTLRenderPassDescriptor,
        drawableSize: CGSize, pointsPerPixel: Double
    ) {
        inFlight.wait()
        let semaphore = inFlight
        commandBuffer.addCompletedHandler { [weak self] buffer in
            if let self, buffer.gpuEndTime > buffer.gpuStartTime {
                self.gpuTime.withLock { $0 = buffer.gpuEndTime - buffer.gpuStartTime }
            }
            semaphore.signal()
        }
        let slot = slots[slotIndex]
        slotIndex = (slotIndex + 1) % Self.framesInFlight
        let pixelsPerPoint = Self.pixelsPerPoint(scene, drawableSize, pointsPerPixel)
        let counts = write(scene, into: slot)
        writeGround(scene, scale: pixelsPerPoint)

        let deep = scene.palette.deep
        pass.colorAttachments[0].clearColor = MTLClearColor(red: deep.red, green: deep.green, blue: deep.blue, alpha: 1)
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var frame = uniforms(scene, drawableSize, pixelsPerPoint)

        encoder.setRenderPipelineState(groundState)
        encoder.setFragmentBytes(groundScratch, length: GroundLayout.floats * 4, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)

        encoder.setVertexBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 0)
        encoder.setFragmentBytes(&frame, length: MemoryLayout<FrameUniforms>.stride, index: 0)
        draw(encoder, plateState, slot.quads, counts.quads)
        draw(encoder, pointState, slot.dots, counts.dots, primitive: .point)
        draw(encoder, glyphState, slot.glyphs, counts.glyphs)
        draw(encoder, glowState, slot.glows, counts.glows)
        encoder.endEncoding()
    }

    private func draw(
        _ encoder: MTLRenderCommandEncoder, _ state: MTLRenderPipelineState, _ buffer: MTLBuffer, _ count: Int,
        primitive: MTLPrimitiveType = .triangleStrip
    ) {
        guard count > 0 else { return }
        encoder.setRenderPipelineState(state)
        encoder.setVertexBuffer(buffer, offset: 0, index: 1)
        if primitive == .point {
            encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: count)
        } else {
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: count)
        }
    }

    private static func pixelsPerPoint(_ scene: WallScene, _ size: CGSize, _ pointsPerPixel: Double) -> Float {
        if scene.width > 0, size.width > 0 { return Float(size.width / scene.width) }
        return pointsPerPixel > 0 ? Float(1 / pointsPerPixel) : 1
    }

    private func uniforms(_ scene: WallScene, _ size: CGSize, _ scale: Float) -> FrameUniforms {
        FrameUniforms(
            canvas: SIMD2(Float(size.width), Float(size.height)),
            shift: SIMD2(Float(scene.driftX), Float(scene.driftY)),
            scale: scale, unit: Float(scene.unit), dim: Float(scene.dim),
            text: Self.vector(scene.palette.text), dimInk: Self.vector(scene.palette.dim))
    }

    static func vector(_ ink: WallInk, _ w: Double = 0) -> SIMD4<Float> {
        SIMD4(Float(ink.red), Float(ink.green), Float(ink.blue), Float(w))
    }
}
