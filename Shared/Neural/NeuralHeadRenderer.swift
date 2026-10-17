import Foundation
import Metal
import QuartzCore
import TailscodeCore

/// How much of the front a frame redraws.
enum NeuralRenderScope: Sendable {
    /// Both passes: the interior into its drawable, the front into its own.
    case full
    /// Only the eye, the ear and the neck ribs, drawn into the front the last full frame retained.
    /// The interior and the rest of the front are on screen already and are not touched or
    /// presented. The caller promises nothing else changed: no size, palette, dive or other
    /// channel (``NeuralFrameDelta/changesOnlyEyeEarRibs(from:to:)``).
    case eyeOnly
}

/// The colour the shaders blend in. The palette's light is `pow(c, 2.2)` as the CPU compositor and
/// the mock compute it, while an sRGB texture is linearised by the hardware with the sRGB curve
/// and an sRGB target is encoded with its inverse. A constant handed over unconverted would come
/// out of the encode a different colour than the hex it was made from, darkest where the two
/// curves part; converting it once puts every constant on the curve the pixels it is mixed with
/// are on.
enum NeuralColorSpace {
    static func srgbDecode(_ value: Float) -> Float {
        value <= 0.04045 ? value / 12.92 : powf((value + 0.055) / 1.055, 2.4)
    }

    static func gpuLinear(_ color: NeuralRGB) -> NeuralRGB {
        func convert(_ value: Float) -> Float {
            srgbDecode(powf(min(max(value, 0), 1), 1 / 2.2))
        }
        return NeuralRGB(convert(color.r), convert(color.g), convert(color.b))
    }

    static func gpuTable(_ table: NeuralToneTable) -> NeuralToneTable {
        NeuralToneTable(
            channels: table.channels.map(gpuLinear), live: gpuLinear(table.live),
            attention: gpuLinear(table.attention), danger: gpuLinear(table.danger),
            quiet: gpuLinear(table.quiet), identity: gpuLinear(table.identity),
            background: gpuLinear(table.background), spill: table.spill)
    }
}

/// Which changes between two frames the retained front can absorb.
enum NeuralFrameDelta {
    /// The places the eye, the ear and the ribs draw, in the 640 by 420 design space, found from
    /// the third packed mask and its bloom (green, blue and alpha, with the bloom's reach). The
    /// seam is the mask's red channel and is not here: a frame that moves it redraws the whole
    /// front.
    static let quads: [SIMD4<Float>] = [
        SIMD4<Float>(544, 174, 96, 82),
        SIMD4<Float>(301, 301, 81, 81),
        SIMD4<Float>(198, 394, 184, 26),
    ]

    /// Whether going from `previous` to `frame` changes nothing but what ``quads`` redraw: no
    /// interior channel, no sweep, crunch or ripple (they move the whole dome), no seam.
    static func changesOnlyEyeEarRibs(from previous: NeuralFrame, to frame: NeuralFrame) -> Bool {
        guard previous.sweepAmount == 0, frame.sweepAmount == 0, previous.crunch == 0,
            frame.crunch == 0, previous.ripple == 0, frame.ripple == 0
        else { return false }
        for channel in 0..<9 {
            if intensity(previous, channel) != intensity(frame, channel) { return false }
            if tone(previous, channel) != tone(frame, channel) { return false }
        }
        return true
    }

    private static func intensity(_ frame: NeuralFrame, _ channel: Int) -> Float {
        channel < frame.intensity.count ? frame.intensity[channel] : 0
    }

    private static func tone(_ frame: NeuralFrame, _ channel: Int) -> NeuralTone? {
        channel < frame.toneOverride.count ? frame.toneOverride[channel] : nil
    }
}

/// Draws the head with Metal: the interior, an opaque pass over the dome's mesh, and the front,
/// the chassis with the eye, ear and rib glow and the glass over it, premultiplied over nothing,
/// as the browser mock stacks them and as `NeuralCompositor` computes them on the CPU.
///
/// A frame costs one uniform write into a three-deep ring, one command buffer and no allocation of
/// its own: the render-pass descriptors, the texture bindings and the tone scratch are built once.
/// Two frames may be in flight, the most a layer's two drawables allow, so a renderer that is
/// behind drops the frame it was asked for rather than blocking the main thread in
/// `nextDrawable()`; the ring's third slot is slack that keeps the slot the GPU is reading from
/// being the one the next frame writes.
@MainActor
final class NeuralHeadRenderer {
    /// What both layers and every offscreen target are: the shaders write linear light and the
    /// hardware encodes it.
    nonisolated static let pixelFormat = MTLPixelFormat.bgra8Unorm_srgb

    /// How many frames may be on the GPU at once.
    nonisolated static let framesInFlight = 2

    let context: NeuralMetalContext
    /// Called on a background queue with the GPU seconds each drawn frame took.
    var onGPUTime: (@Sendable (Double) -> Void)?

    /// Whether the last frame `draw` presented redrew only the eye, ear and ribs.
    private(set) var lastDrawWasEyeOnly = false

    private let ring: MTLBuffer
    private let permits = DispatchSemaphore(value: NeuralHeadRenderer.framesInFlight)
    private var ringIndex = 0
    private var tones = [NeuralRGB](repeating: NeuralRGB(0, 0, 0), count: NeuralUniformLayout.channelCount)
    private var sourceTable: NeuralToneTable?
    private var gpuTable: NeuralToneTable?
    private let interiorPass = MTLRenderPassDescriptor()
    private let frontPass = MTLRenderPassDescriptor()
    private let copyPass = MTLRenderPassDescriptor()
    private var retainedFront: MTLTexture?

    var retainedFrontTexture: MTLTexture? { retainedFront }

    init?(context: NeuralMetalContext) {
        guard context.isSupported,
            let ring = context.device.makeBuffer(
                length: NeuralUniformLayout.slotStride * NeuralUniformLayout.ringDepth,
                options: .storageModeShared)
        else { return nil }
        ring.label = "neural uniform ring"
        self.context = context
        self.ring = ring
    }

    /// Whether the front the last full frame retained can take an ``NeuralRenderScope/eyeOnly``
    /// frame at this size.
    func canDrawEyeOnly(width: Int, height: Int) -> Bool {
        guard let retainedFront else { return false }
        return retainedFront.width == width && retainedFront.height == height
    }

    /// Forgets the retained front, which a change of palette, size or dive makes stale.
    func discardRetainedFront() {
        retainedFront = nil
    }

    /// Draws one frame into the two layers and presents both in one command buffer. Returns false
    /// when nothing was drawn: the textures are not resident, two frames are already on the GPU,
    /// or a layer had no drawable. `retainFront` keeps the front in a texture of its own so a
    /// following frame may be ``NeuralRenderScope/eyeOnly``.
    @discardableResult
    func draw(
        frame: NeuralFrame, table: NeuralToneTable, time: Double, dive: NeuralDive = .none,
        scope: NeuralRenderScope = .full, retainFront: Bool = false, interior: CAMetalLayer,
        front: CAMetalLayer
    ) -> Bool {
        let width = Int(front.drawableSize.width)
        let height = Int(front.drawableSize.height)
        guard width > 0, height > 0, let textures = context.currentTextures() else { return false }
        let eyeOnly = scope == .eyeOnly && canDrawEyeOnly(width: width, height: height)
        guard permits.wait(timeout: .now()) == .success else { return false }
        var armed = true
        defer { if armed { permits.signal() } }

        let prepared = writeSlot(
            frame: frame, table: table, time: time, width: width, height: height, dive: dive)
        guard let commands = context.queue.makeCommandBuffer() else { return false }
        commands.label = "neural head"

        if !eyeOnly {
            guard let drawable = interior.nextDrawable(),
                encodeInterior(
                    commands, target: drawable.texture, prepared: prepared, textures: textures)
            else { return false }
            commands.present(drawable)
        }
        guard let frontDrawable = front.nextDrawable() else { return false }
        let ok: Bool
        if eyeOnly, let retained = retainedFront {
            ok =
                encodeFront(
                    commands, target: retained, prepared: prepared, textures: textures,
                    quads: NeuralFrameDelta.quads)
                && encodeCopy(commands, from: retained, to: frontDrawable.texture)
        } else if retainFront {
            let retained = retainedTexture(width: width, height: height)
            ok =
                retained.map {
                    encodeFront(
                        commands, target: $0, prepared: prepared, textures: textures, quads: nil)
                        && encodeCopy(commands, from: $0, to: frontDrawable.texture)
                } ?? false
        } else {
            retainedFront = nil
            ok = encodeFront(
                commands, target: frontDrawable.texture, prepared: prepared, textures: textures,
                quads: nil, blended: true)
        }
        guard ok else { return false }
        commands.present(frontDrawable)
        commit(commands)
        armed = false
        lastDrawWasEyeOnly = eyeOnly
        return true
    }

    /// The head drawn offscreen at `width` by `height`, read back as the two premultiplied BGRA
    /// surfaces `NeuralCompositor` produces: the same bytes a layer would show, for tests, posters
    /// and the comparison against the CPU. Blocks until the GPU is done. Nil when the textures
    /// are not resident or the size is empty.
    func snapshot(
        frame: NeuralFrame, table: NeuralToneTable, time: Double, width: Int, height: Int,
        dive: NeuralDive = .none
    ) -> NeuralSurfacePair? {
        guard let targets = makeOffscreen(width: width, height: height),
            let commands = encodeOffscreen(
                frame: frame, table: table, time: time, targets: targets, dive: dive)
        else { return nil }
        commands.commit()
        commands.waitUntilCompleted()
        guard commands.status == .completed else { return nil }
        var pair = NeuralSurfacePair(width: width, height: height)
        read(targets.interior, into: &pair.interior)
        read(targets.front, into: &pair.front)
        return pair
    }

    /// The GPU seconds each of `frames` frames takes at `width` by `height`, drawn one after
    /// another offscreen with `frameAt` naming each one's frame and time. The first is a warm-up
    /// and is left out. Nil when the textures are not resident.
    func measure(
        frames: Int, width: Int, height: Int, table: NeuralToneTable,
        frameAt: (Int) -> (frame: NeuralFrame, time: Double)
    ) -> [Double]? {
        guard let targets = makeOffscreen(width: width, height: height) else { return nil }
        var seconds: [Double] = []
        for index in 0...max(0, frames) {
            let next = frameAt(index)
            guard
                let commands = encodeOffscreen(
                    frame: next.frame, table: table, time: next.time, targets: targets,
                    dive: .none)
            else { return nil }
            commands.commit()
            commands.waitUntilCompleted()
            guard commands.status == .completed else { return nil }
            if index > 0 { seconds.append(commands.gpuEndTime - commands.gpuStartTime) }
        }
        return seconds
    }
}

private struct NeuralPreparedFrame {
    let slotOffset: Int
    let key: NeuralPipelineKey
    let background: NeuralRGB
}

private struct NeuralOffscreen {
    let interior: MTLTexture
    let front: MTLTexture
    let width: Int
    let height: Int
}

extension NeuralHeadRenderer {
    private func gpu(_ table: NeuralToneTable) -> NeuralToneTable {
        if let sourceTable, sourceTable == table, let gpuTable { return gpuTable }
        let converted = NeuralColorSpace.gpuTable(table)
        sourceTable = table
        gpuTable = converted
        return converted
    }

    /// Fills the next ring slot with this frame and says where it is and which specialisation the
    /// frame wants. Nothing here allocates: the tone scratch is overwritten in place.
    fileprivate func writeSlot(
        frame: NeuralFrame, table: NeuralToneTable, time: Double, width: Int, height: Int,
        dive: NeuralDive
    ) -> NeuralPreparedFrame {
        let colours = gpu(table)
        for index in 0..<NeuralUniformLayout.channelCount {
            if index < frame.toneOverride.count, let override = frame.toneOverride[index] {
                tones[index] = colours.color(for: override)
            } else {
                tones[index] = colours.channels[index]
            }
        }
        ringIndex = (ringIndex + 1) % NeuralUniformLayout.ringDepth
        let offset = ringIndex * NeuralUniformLayout.slotStride
        NeuralUniforms.fill(
            into: ring.contents().advanced(by: offset), frame: frame, tones: tones,
            background: colours.background, sweepTone: colours.color(for: frame.sweepTone),
            time: Float(time.truncatingRemainder(dividingBy: 3600)),
            aspect: Float(width) / Float(height),
            dive: NeuralDiveUniform(
                centre: SIMD2<Float>(Float(dive.center.x), Float(dive.center.y)),
                chassisScale: dive.chassisScale, glassScale: dive.glassScale, fade: dive.fade))
        return NeuralPreparedFrame(
            slotOffset: offset, key: NeuralPipelineKey(frame: frame, spill: colours.spill),
            background: colours.background)
    }

    fileprivate func retainedTexture(width: Int, height: Int) -> MTLTexture? {
        if let retainedFront, retainedFront.width == width, retainedFront.height == height {
            return retainedFront
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.pixelFormat, width: width, height: height, mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .private
        let made = context.device.makeTexture(descriptor: descriptor)
        made?.label = "neural retained front"
        retainedFront = made
        return made
    }

    fileprivate func encodeInterior(
        _ commands: MTLCommandBuffer, target: MTLTexture, prepared: NeuralPreparedFrame,
        textures: NeuralTextureSet
    ) -> Bool {
        guard let pipeline = context.pipeline(.interior, key: prepared.key, format: target.pixelFormat),
            let vertices = context.domeVertices, let attachment = interiorPass.colorAttachments[0]
        else { return false }
        attachment.texture = target
        attachment.loadAction = .clear
        attachment.storeAction = .store
        attachment.clearColor = MTLClearColor(
            red: Double(prepared.background.r), green: Double(prepared.background.g),
            blue: Double(prepared.background.b), alpha: 1)
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: interiorPass) else {
            return false
        }
        attachment.texture = nil
        encoder.label = "neural interior"
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBuffer(vertices, offset: 0, index: 0)
        var uniforms = NeuralVertexUniforms.full
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<NeuralVertexUniforms>.stride, index: 1)
        encoder.setFragmentBuffer(
            ring, offset: prepared.slotOffset + NeuralUniformLayout.interiorOffset, index: 0)
        encoder.setFragmentTextures(textures.interiorBinding, range: 0..<textures.interiorBinding.count)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: context.domeVertexCount)
        encoder.endEncoding()
        return true
    }

    /// The front into `target`: the whole quad over a transparent clear, or, for `quads`, only
    /// those rectangles over what the texture holds. A texture that is a drawable takes the
    /// blended pipeline the doc asks for; a retained one is written over, which over a clear is
    /// the same pixel.
    fileprivate func encodeFront(
        _ commands: MTLCommandBuffer, target: MTLTexture, prepared: NeuralPreparedFrame,
        textures: NeuralTextureSet, quads: [SIMD4<Float>]?, blended: Bool = false
    ) -> Bool {
        let pass: NeuralPass = blended ? .front : .frontReplace
        guard let pipeline = context.pipeline(pass, key: prepared.key, format: target.pixelFormat),
            let attachment = frontPass.colorAttachments[0]
        else { return false }
        attachment.texture = target
        attachment.loadAction = quads == nil ? .clear : .load
        attachment.storeAction = .store
        attachment.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: frontPass) else {
            return false
        }
        attachment.texture = nil
        encoder.label = quads == nil ? "neural front" : "neural front eye"
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBuffer(
            ring, offset: prepared.slotOffset + NeuralUniformLayout.frontOffset, index: 0)
        encoder.setFragmentTextures(textures.frontBinding, range: 0..<textures.frontBinding.count)
        if let quads {
            for rect in quads { drawQuad(encoder, rect: rect) }
        } else {
            drawQuad(encoder, rect: NeuralVertexUniforms.full.rect)
        }
        encoder.endEncoding()
        return true
    }

    private func drawQuad(_ encoder: MTLRenderCommandEncoder, rect: SIMD4<Float>) {
        var uniforms = NeuralVertexUniforms(rect: rect)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<NeuralVertexUniforms>.stride, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    fileprivate func encodeCopy(
        _ commands: MTLCommandBuffer, from source: MTLTexture, to target: MTLTexture
    ) -> Bool {
        guard let pipeline = context.pipeline(.copy, key: [], format: target.pixelFormat),
            let attachment = copyPass.colorAttachments[0]
        else { return false }
        attachment.texture = target
        attachment.loadAction = .dontCare
        attachment.storeAction = .store
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: copyPass) else {
            return false
        }
        attachment.texture = nil
        encoder.label = "neural front copy"
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(source, index: 0)
        drawQuad(encoder, rect: NeuralVertexUniforms.full.rect)
        encoder.endEncoding()
        return true
    }

    fileprivate func commit(_ commands: MTLCommandBuffer) {
        let permits = permits
        let report = onGPUTime
        commands.addCompletedHandler { buffer in
            permits.signal()
            if buffer.status == .error {
                AppLogger.performance.error(
                    "neural frame failed: \(buffer.error?.localizedDescription ?? "unknown")")
            }
            let seconds = buffer.gpuEndTime - buffer.gpuStartTime
            if let report, seconds > 0 { report(seconds) }
        }
        commands.commit()
    }

    fileprivate func makeOffscreen(width: Int, height: Int) -> NeuralOffscreen? {
        guard width > 0, height > 0 else { return nil }
        func target() -> MTLTexture? {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: Self.pixelFormat, width: width, height: height, mipmapped: false)
            descriptor.usage = [.renderTarget, .shaderRead]
            descriptor.storageMode = .shared
            return context.device.makeTexture(descriptor: descriptor)
        }
        guard let interior = target(), let front = target() else { return nil }
        interior.label = "neural offscreen interior"
        front.label = "neural offscreen front"
        return NeuralOffscreen(interior: interior, front: front, width: width, height: height)
    }

    fileprivate func encodeOffscreen(
        frame: NeuralFrame, table: NeuralToneTable, time: Double, targets: NeuralOffscreen,
        dive: NeuralDive
    ) -> MTLCommandBuffer? {
        guard let textures = context.currentTextures(), let commands = context.queue.makeCommandBuffer()
        else { return nil }
        permits.wait()
        let prepared = writeSlot(
            frame: frame, table: table, time: time, width: targets.width, height: targets.height,
            dive: dive)
        guard encodeInterior(commands, target: targets.interior, prepared: prepared, textures: textures),
            encodeFront(
                commands, target: targets.front, prepared: prepared, textures: textures, quads: nil,
                blended: true)
        else {
            permits.signal()
            return nil
        }
        let permits = permits
        commands.addCompletedHandler { _ in permits.signal() }
        return commands
    }

    func read(_ texture: MTLTexture, into surface: inout NeuralSurface) {
        let rowBytes = texture.width * 4
        surface.bytes.withUnsafeMutableBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            texture.getBytes(
                base, bytesPerRow: rowBytes,
                from: MTLRegionMake2D(0, 0, texture.width, texture.height), mipmapLevel: 0)
        }
    }
}

#if DEBUG
    extension NeuralHeadRenderer {
        /// The retained front as the same premultiplied BGRA surface a snapshot gives, for a harness
        /// that proves an eye-only frame leaves the front exactly as a full one would. Nil when no
        /// front is retained.
        func debugReadRetainedFront() -> NeuralSurface? {
            guard let retained = retainedFrontTexture else { return nil }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: retained.pixelFormat, width: retained.width, height: retained.height,
                mipmapped: false)
            descriptor.storageMode = .shared
            descriptor.usage = .shaderRead
            guard let copy = context.device.makeTexture(descriptor: descriptor),
                let commands = context.queue.makeCommandBuffer(),
                let blit = commands.makeBlitCommandEncoder()
            else { return nil }
            blit.copy(from: retained, to: copy)
            blit.endEncoding()
            commands.commit()
            commands.waitUntilCompleted()
            var surface = NeuralSurface(width: retained.width, height: retained.height)
            read(copy, into: &surface)
            return surface
        }
    }
#endif
