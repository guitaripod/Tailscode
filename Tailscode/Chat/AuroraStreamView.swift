import Metal
import QuartzCore
import TailscodeCore
import UIKit

/// What one frame of the alpha renderer is: the pacer's own numbers, the theme's own inks, and
/// nothing else. The view resolves colours and hands this over; it decides nothing.
@MainActor
struct AuroraFrame {
    let progress: Double
    let phase: Double
    let time: Double
    let rate: Double
    let edge: UIColor
    let spark: UIColor
    let motion: Bool
}

/// The device, the queue and the two pipelines, once for the whole app.
///
/// A transcript writes into one row at a time, so at most a couple of these overlays exist at
/// once — but each of them building its own command queue and compiling its own pipeline would
/// spend, per row, what the process only ever needs to spend once.
@MainActor
final class AuroraEngine {
    static let shared = AuroraEngine()

    let device: MTLDevice
    let queue: MTLCommandQueue
    let glyphs: MTLRenderPipelineState
    let nib: MTLRenderPipelineState
    let sampler: MTLSamplerState

    private init?() {
        guard let device = MTLCreateSystemDefaultDevice(),
            let queue = device.makeCommandQueue(),
            let library = device.makeDefaultLibrary()
        else { return nil }

        func pipeline(_ vertex: String, _ fragment: String) -> MTLRenderPipelineState? {
            guard let vertexFunction = library.makeFunction(name: vertex),
                let fragmentFunction = library.makeFunction(name: fragment)
            else { return nil }
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = vertexFunction
            descriptor.fragmentFunction = fragmentFunction
            guard let attachment = descriptor.colorAttachments[0] else { return nil }
            attachment.pixelFormat = .bgra8Unorm
            attachment.isBlendingEnabled = true
            attachment.sourceRGBBlendFactor = .one
            attachment.sourceAlphaBlendFactor = .one
            attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
            attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            return try? device.makeRenderPipelineState(descriptor: descriptor)
        }

        guard let glyphs = pipeline("aurora_glyph_vertex", "aurora_glyph_fragment"),
            let nib = pipeline("aurora_nib_vertex", "aurora_nib_fragment")
        else { return nil }

        let sampling = MTLSamplerDescriptor()
        sampling.minFilter = .linear
        sampling.magFilter = .linear
        sampling.mipFilter = .linear
        sampling.sAddressMode = .clampToEdge
        sampling.tAddressMode = .clampToEdge
        guard let sampler = device.makeSamplerState(descriptor: sampling) else { return nil }

        self.device = device
        self.queue = queue
        self.glyphs = glyphs
        self.nib = nib
        self.sampler = sampler
    }
}

/// What the alpha renderer refuses to take on.
///
/// Everything here is a size past which the trade stops being worth making, and every one of them
/// falls the row back to the settled renderer rather than degrading: a band of geometry this large
/// is a paste rather than a stream, and the whole product's floor writes it perfectly well.
enum AuroraLimits {
    /// The most characters one band may carry as geometry.
    static let glyphs = 900
    /// The most pixels the ink may cover.
    ///
    /// This is the one number that bounds how long an arrival can take, because rasterising the
    /// band is the only part of this that scales with anything: a band is wide because the bubble
    /// is, and tall only when a great deal arrived at once. A measured arrival at a quarter of a
    /// million pixels costs a couple of milliseconds, so the ceiling is set where the work still
    /// fits inside a frame with room to spare rather than where the memory would start to hurt —
    /// past it, what arrived was a paste rather than a stream, and the settled renderer writes a
    /// paste perfectly well.
    static let inkPixels = 2_000_000
}

/// The whole of what a text view has to do to be written by the GPU instead of tinted, in one
/// place so the transcript and the screen where the hand is chosen cannot show different things.
///
/// The split is the design. Text arriving is where the work is: the row is laid out once, the
/// band's characters are read out of the text system as rectangles, its glyphs are rasterised once
/// in the colours they settle to, and the range the GPU has taken over is handed to it by being
/// made clear in the storage. A frame that brought no new text does none of that — it writes a
/// uniform buffer and draws — which is why the cost of this does not grow with the length of the
/// answer. Anything that cannot be done honestly returns false, and the caller writes the row with
/// the settled hand, which is the whole product's floor and says the same thing.
@MainActor
final class AuroraTextPainter {
    private unowned let textView: UITextView
    private unowned let host: UIView
    private var overlay: AuroraStreamView?
    private var key: String?
    private var length = 0
    private var width: CGFloat = .nan

    init(textView: UITextView, host: UIView) {
        self.textView = textView
        self.host = host
    }

    var isLit: Bool { key != nil || overlay?.isLit == true }

    func paint(_ rendered: NSAttributedString, cascade: CascadeTail, key: String) -> Bool {
        guard let frame = cascade.aurora, let overlay = ensure() else { return false }
        if self.key != key || length != rendered.length {
            textView.attributedText = rendered
            host.layoutIfNeeded()
            let band = max(0, min(cascade.revealed, rendered.length) - cascade.span)
            guard rendered.length > band,
                overlay.adopt(
                    layoutManager: textView.layoutManager, container: textView.textContainer,
                    glyphOrigin: textView.frame.origin, from: band, upTo: rendered.length)
            else { return false }
            textView.textStorage.addAttribute(
                .foregroundColor, value: UIColor.clear,
                range: NSRange(location: band, length: rendered.length - band))
            self.key = key
            length = rendered.length
            width = textView.bounds.width
        }
        overlay.paint(frame)
        return true
    }

    /// The wave has to come off by hand: a turn merely ending changes no row value for a diff to
    /// notice, and a settled paragraph with a nib resting on it is a lie about what is live.
    func release() {
        guard isLit else { return }
        key = nil
        length = 0
        width = .nan
        overlay?.release()
    }

    /// A bubble reaches its width over the first few arrivals of an answer, and glyph rectangles
    /// read against the previous width are ink drawn where the letters no longer are. The band is
    /// therefore given up whenever the column it was measured in changes, and read again on the
    /// next frame — one arrival's work, against a reveal that would otherwise drift off the side
    /// of the text it belongs to.
    func revalidate() {
        guard key != nil, textView.bounds.width != width else { return }
        key = nil
    }

    private func ensure() -> AuroraStreamView? {
        if let overlay { return overlay }
        guard AuroraStreamView.isAvailable else { return nil }
        let view = AuroraStreamView()
        view.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(view)
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: host.topAnchor),
            view.bottomAnchor.constraint(equalTo: host.bottomAnchor),
            view.leadingAnchor.constraint(equalTo: host.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: host.trailingAnchor),
        ])
        overlay = view
        return view
    }
}

/// A text system of one's own, for a row whose glyphs a label draws rather than a text view.
///
/// A label has no layout manager to ask and the wave needs rectangles, so the same string is laid
/// out a second time under the rules the label is drawing it by. For code that is exact rather than
/// approximate: a line of code ends at its newline and nowhere else, which is what `byClipping` in
/// an unbounded container means, so the second layout can only agree with the first.
@MainActor
final class AuroraTextStack {
    let storage = NSTextStorage()
    let layoutManager = NSLayoutManager()
    let container = NSTextContainer(
        size: CGSize(width: CGFloat.greatestFiniteMagnitude, height: .greatestFiniteMagnitude))

    init() {
        container.lineFragmentPadding = 0
        container.maximumNumberOfLines = 0
        container.lineBreakMode = .byClipping
        layoutManager.addTextContainer(container)
        storage.addLayoutManager(layoutManager)
    }

    func adopt(_ text: NSAttributedString) {
        storage.setAttributedString(text)
        layoutManager.ensureLayout(for: container)
    }
}

private struct AuroraQuad {
    var rect: SIMD4<Float>
    var facts: SIMD2<Float>
}

private struct AuroraUniforms {
    var edge: SIMD4<Float>
    var spark: SIMD4<Float>
    var nib: SIMD4<Float>
    var regionSize: SIMD2<Float>
    var inkSize: SIMD2<Float>
    var progress: Float
    var span: Float
    var phase: Float
    var time: Float
    var entry: Float
    var entryFloor: Float
    var shimmerWidth: Float
    var shimmerReach: Float
    var shimmerPeak: Float
    var landing: Float
    var riseHeight: Float
    var contraction: Float
    var tilt: Float
    var dispersionReach: Float
    var dispersionDepth: Float
    var bloomLevel: Float
    var bloomRadius: Float
    var bloomPeak: Float
    var emberReach: Float
    var emberDensity: Float
    var emberLife: Float
    var emberDrift: Float
    var nibGlow: Float
    var margin: Float
    var intensity: Float
    var motion: Float
}

/// The answer written by the GPU: the same wave the settled renderer paints, rasterised over
/// per-glyph geometry instead of over an attributed string.
///
/// The whole design is in the split between what happens when text *arrives* and what happens on a
/// *frame*. On an arrival — ten times a second at most, and the row is being re-rendered anyway —
/// the band's characters are read out of the text system as rectangles, the glyphs are rasterised
/// once into a small texture, and both go to the GPU. On a frame, which is up to a hundred and
/// twenty times a second, nothing is read, nothing is measured and nothing is allocated: one
/// buffer of uniforms is written and two draw calls are made, and the reveal, the band, the
/// arrivals, the light and the embers all move inside the vertex and fragment stages. That is why
/// this can afford to move a letterform at all, and it is why the cost does not grow with the
/// length of the answer.
///
/// The view never participates in layout. Its own bounds track the host's, and the drawable is a
/// sublayer sized to the band alone — a frame changes light, never a size the transcript depends
/// on, and the paragraph under it was measured when it arrived and is never measured again.
@MainActor
final class AuroraStreamView: UIView {
    private let metalLayer = CAMetalLayer()
    private let engine: AuroraEngine?
    private var quads: [AuroraQuad] = []
    private var quadBuffer: MTLBuffer?
    private var ink: MTLTexture?
    private var context: CGContext?
    private var capacity = CGSize.zero
    private var region = CGRect.zero
    private var inkScale = SIMD2<Float>(1, 1)
    private var scale: CGFloat = 1
    private var firstIndex = 0

    /// Whether this device can write with this hand at all. A phone with no Metal device, or a
    /// library whose functions did not compile, falls back rather than shows nothing.
    static var isAvailable: Bool { AuroraEngine.shared != nil }

    override init(frame: CGRect) {
        engine = AuroraEngine.shared
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        layer.addSublayer(metalLayer)
        metalLayer.device = engine?.device
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.isOpaque = false
        metalLayer.framebufferOnly = true
        metalLayer.maximumDrawableCount = 2
        metalLayer.presentsWithTransaction = false
        metalLayer.allowsNextDrawableTimeout = true
        metalLayer.isHidden = true
        metalLayer.actions = [
            "position": NSNull(), "bounds": NSNull(), "contents": NSNull(),
            "hidden": NSNull(),
        ]
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    var isLit: Bool { !metalLayer.isHidden }

    /// Lets the row go. A finished paragraph with a nib resting on it is a lie about what is live,
    /// and the wave has to come off by hand — a turn merely ending changes no row value for a diff
    /// to notice.
    func release() {
        guard !quads.isEmpty || !metalLayer.isHidden else { return }
        quads = []
        region = .zero
        firstIndex = 0
        metalLayer.isHidden = true
    }

    /// Takes the band this arrival left behind: which characters the GPU now owns, where the text
    /// system put them, and what they look like settled.
    ///
    /// Returns false when the row should be written by the settled renderer instead — no GPU, a
    /// band past the limits, a layout that has not happened yet, or a host with no size. Every one
    /// of those is a fallback rather than a failure, and the caller paints the classic wave.
    func adopt(
        layoutManager: NSLayoutManager, container: NSTextContainer, glyphOrigin: CGPoint,
        from first: Int, upTo end: Int
    ) -> Bool {
        guard engine != nil, bounds.width > 1, bounds.height > 1 else { return false }
        let start = max(0, first)
        guard end > start, end - start <= AuroraLimits.glyphs else { return false }

        layoutManager.ensureLayout(for: container)
        let characters = NSRange(location: start, length: end - start)
        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: characters, actualCharacterRange: nil)
        guard glyphRange.length > 0 else { return false }

        var built: [AuroraQuad] = []
        built.reserveCapacity(glyphRange.length)
        var span = CGRect.null
        var tallest: CGFloat = 0

        layoutManager.enumerateLineFragments(forGlyphRange: glyphRange) {
            fragment, used, _, line, _ in
            let height = fragment.height > 0 ? fragment.height : used.height
            guard height > 0 else { return }
            tallest = max(tallest, height)
            let lower = max(line.location, glyphRange.location)
            let upper = min(line.location + line.length, glyphRange.location + glyphRange.length)
            guard upper > lower else { return }
            let edge = used.maxX > used.minX ? used.maxX : fragment.maxX
            for glyph in lower..<upper {
                guard !layoutManager.notShownAttribute(forGlyphAt: glyph) else { continue }
                let index = layoutManager.characterIndexForGlyph(at: glyph)
                guard index >= start, index < end else { continue }
                let here = layoutManager.location(forGlyphAt: glyph).x
                let next =
                    glyph + 1 < line.location + line.length
                    ? layoutManager.location(forGlyphAt: glyph + 1).x
                    : max(edge - fragment.minX, here)
                let x = fragment.minX + here + glyphOrigin.x
                let width = max(next - here, 0.5)
                let rect = CGRect(
                    x: x, y: fragment.minY + glyphOrigin.y, width: width, height: height)
                guard rect.width > 0, rect.height > 0 else { continue }
                span = span.union(rect)
                built.append(
                    AuroraQuad(
                        rect: SIMD4(
                            Float(rect.minX), Float(rect.minY), Float(rect.width),
                            Float(rect.height)),
                        facts: SIMD2(Float(index), Float(height))))
            }
        }

        guard !built.isEmpty, !span.isNull, tallest > 0 else { return false }

        let margin = CGFloat(AuroraField.quadMargin) * tallest
        let padded = span.insetBy(dx: -margin, dy: -margin)
        scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 2
        guard
            padded.width * scale * padded.height * scale <= CGFloat(AuroraLimits.inkPixels),
            let ink = rasterise(
                layoutManager: layoutManager, glyphRange: glyphRange, region: padded,
                glyphOrigin: glyphOrigin)
        else { return false }

        for index in built.indices {
            built[index].rect.x -= Float(padded.minX)
            built[index].rect.y -= Float(padded.minY)
        }

        quads = built
        region = padded
        firstIndex = start
        self.ink = ink
        upload(built)
        place(padded)
        return true
    }

    /// One frame. The only work here is the uniform buffer: everything that moves is a function of
    /// the numbers in it, computed by the stages that were going to run anyway.
    func paint(_ frame: AuroraFrame) {
        guard let engine, !quads.isEmpty, let ink, let quadBuffer,
            let drawable = metalLayer.nextDrawable(),
            let descriptor = renderPass(for: drawable)
        else { return }

        var uniforms = self.uniforms(frame, ink: ink)
        guard let commands = engine.queue.makeCommandBuffer(),
            let encoder = commands.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }
        let length = MemoryLayout<AuroraUniforms>.stride
        encoder.setRenderPipelineState(engine.glyphs)
        encoder.setVertexBuffer(quadBuffer, offset: 0, index: 0)
        encoder.setVertexBytes(&uniforms, length: length, index: 1)
        encoder.setFragmentBytes(&uniforms, length: length, index: 1)
        encoder.setFragmentTexture(ink, index: 0)
        encoder.setFragmentSamplerState(engine.sampler, index: 0)
        encoder.drawPrimitives(
            type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: quads.count)
        if uniforms.nib.w > 0.003, frame.motion {
            encoder.setRenderPipelineState(engine.nib)
            encoder.setVertexBytes(&uniforms, length: length, index: 1)
            encoder.setFragmentBytes(&uniforms, length: length, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        }
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
        if metalLayer.isHidden { metalLayer.isHidden = false }
    }

    private func renderPass(for drawable: CAMetalDrawable) -> MTLRenderPassDescriptor? {
        let descriptor = MTLRenderPassDescriptor()
        guard let attachment = descriptor.colorAttachments[0] else { return nil }
        attachment.texture = drawable.texture
        attachment.loadAction = .clear
        attachment.storeAction = .store
        attachment.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        return descriptor
    }

    /// The reveal is counted from the start of the whole answer and so is every quad's index, and
    /// the two must be counted from the same place. A band that began part way in tempts a
    /// renderer to rebase one of them; rebasing either would put the wave that many characters
    /// behind the edge and cull the newest ones outright — and rebasing the index would also
    /// reseed every glyph's tilt each time the band moved, so a character that had already landed
    /// would land again differently.
    private func uniforms(_ frame: AuroraFrame, ink: MTLTexture) -> AuroraUniforms {
        let motion: Float = frame.motion ? 1 : 0
        return AuroraUniforms(
            edge: Self.channels(frame.edge, traits: traitCollection),
            spark: Self.channels(frame.spark, traits: traitCollection),
            nib: nibPlacement(progress: frame.progress, rate: frame.rate, motion: frame.motion),
            regionSize: SIMD2(Float(region.width), Float(region.height)),
            inkSize: inkScale,
            progress: Float(frame.progress),
            span: Float(StreamCascade.span),
            phase: Float(frame.phase),
            time: Float(frame.time.truncatingRemainder(dividingBy: 3600)),
            entry: Float(StreamCascade.entry),
            entryFloor: Float(StreamCascade.entryFloor),
            shimmerWidth: Float(StreamCascade.shimmerWidth),
            shimmerReach: Float(StreamCascade.shimmerReach),
            shimmerPeak: Float(StreamCascade.shimmerPeak),
            landing: Float(AuroraField.landing),
            riseHeight: Float(AuroraField.riseHeight),
            contraction: Float(AuroraField.contractionDepth),
            tilt: Float(AuroraField.tiltDepth),
            dispersionReach: Float(AuroraField.dispersionReach),
            dispersionDepth: Float(AuroraField.dispersionDepth),
            bloomLevel: Float(bloomLevel(of: ink)),
            bloomRadius: Float(AuroraField.bloomRadius),
            bloomPeak: Float(AuroraField.bloomPeak),
            emberReach: Float(AuroraField.emberReach),
            emberDensity: Float(AuroraField.emberDensity),
            emberLife: Float(AuroraField.emberLife),
            emberDrift: Float(AuroraField.emberDrift),
            nibGlow: Float(AuroraField.nibGlow),
            margin: Float(AuroraField.quadMargin),
            intensity: motion,
            motion: motion)
    }

    /// The nib rides the character it has just written, so its place is that character's own box
    /// rather than an offset guessed from the font. A reveal that has run past the band the GPU
    /// holds — the pacer caught up with everything that arrived — rests on the last glyph there is.
    private func nibPlacement(progress: Double, rate: Double, motion: Bool) -> SIMD4<Float> {
        guard motion, !quads.isEmpty else { return SIMD4(0, 0, 0, 0) }
        let position = AuroraField.nibPosition(progress: progress)
        let wanted = Int(position.rounded(.down)) - firstIndex
        guard wanted >= 0 else { return SIMD4(0, 0, 0, 0) }
        let quad = quads[min(wanted, quads.count - 1)]
        let strength = AuroraField.nibStrength(rate: rate)
        return SIMD4(quad.rect.x + quad.rect.z, quad.rect.y, quad.rect.w, Float(strength))
    }

    /// Which level of the ink's own pyramid the light is read from.
    ///
    /// A mip level is the cheapest blur there is — one sample, already built — but the level has to
    /// be chosen against the *letterform*, not against how far the light should reach. Read a level
    /// coarse enough that a whole character fits in a texel and the sample stops describing the
    /// letter at all: it becomes one flat value per cell, and light shaped by distance from the
    /// glyph's box then paints the box. So the pyramid supplies a halo a stroke or two wide and
    /// `aurora_falloff` carries it outward, which is the division that keeps a glow attached to the
    /// shape of what is glowing.
    private static let bloomBlur = 2.0

    private func bloomLevel(of ink: MTLTexture) -> Double {
        guard !quads.isEmpty else { return 0 }
        let height = Double(quads[0].facts.y) * Double(scale)
        let radius = max(height * AuroraField.bloomRadius, 1)
        return min(Double(ink.mipmapLevelCount - 1), max(0, log2(radius) - Self.bloomBlur))
    }

    private func upload(_ built: [AuroraQuad]) {
        guard let engine else { return }
        let length = built.count * MemoryLayout<AuroraQuad>.stride
        if quadBuffer == nil || quadBuffer!.length < length {
            quadBuffer = engine.device.makeBuffer(
                length: max(length, MemoryLayout<AuroraQuad>.stride * 256),
                options: .storageModeShared)
        }
        guard let quadBuffer else { return }
        built.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            quadBuffer.contents().copyMemory(from: base, byteCount: length)
        }
    }

    /// The drawable covers the band and nothing else, and it is moved as a layer rather than as a
    /// view: a constraint changed ten times a second would ask the transcript to re-measure a row
    /// that did not change size, which is the one thing the streaming doctrine forbids.
    private func place(_ rect: CGRect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        metalLayer.frame = rect
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(
            width: max(1, (rect.width * scale).rounded()),
            height: max(1, (rect.height * scale).rounded()))
        CATransaction.commit()
    }

    /// The band's glyphs, once, in the colours they settle to — syntax highlighting, links and
    /// inline code included, because the wave tints what is already there rather than replacing it.
    /// Drawn through the text system's own painter, so what the GPU holds is pixel for pixel what
    /// the row would have shown.
    private func rasterise(
        layoutManager: NSLayoutManager, glyphRange: NSRange, region: CGRect, glyphOrigin: CGPoint
    ) -> MTLTexture? {
        guard let engine else { return nil }
        let wanted = CGSize(
            width: max(1, (region.width * scale).rounded(.up)),
            height: max(1, (region.height * scale).rounded(.up)))
        if context == nil || capacity.width < wanted.width || capacity.height < wanted.height {
            capacity = CGSize(
                width: max(capacity.width, wanted.width), height: max(capacity.height, wanted.height)
            )
            let width = Int(capacity.width)
            let height = Int(capacity.height)
            guard width > 0, height > 0,
                let made = CGContext(
                    data: nil, width: width, height: height, bitsPerComponent: 8,
                    bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                        | CGBitmapInfo.byteOrder32Little.rawValue)
            else { return nil }
            context = made
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: true)
            descriptor.usage = [.shaderRead, .renderTarget]
            descriptor.storageMode = .shared
            ink = engine.device.makeTexture(descriptor: descriptor)
        }
        guard let context, let ink else { return nil }

        context.clear(CGRect(x: 0, y: 0, width: capacity.width, height: capacity.height))
        context.saveGState()
        context.translateBy(x: 0, y: capacity.height)
        context.scaleBy(x: scale, y: -scale)
        UIGraphicsPushContext(context)
        layoutManager.drawGlyphs(
            forGlyphRange: glyphRange,
            at: CGPoint(x: glyphOrigin.x - region.minX, y: glyphOrigin.y - region.minY))
        UIGraphicsPopContext()
        context.restoreGState()

        guard let data = context.data else { return nil }
        ink.replace(
            region: MTLRegionMake2D(0, 0, ink.width, ink.height), mipmapLevel: 0, withBytes: data,
            bytesPerRow: context.bytesPerRow)
        if ink.mipmapLevelCount > 1,
            let commands = engine.queue.makeCommandBuffer(),
            let blit = commands.makeBlitCommandEncoder()
        {
            blit.generateMipmaps(for: ink)
            blit.endEncoding()
            commands.commit()
        }
        inkScale = SIMD2(
            Float(region.width * scale / capacity.width),
            Float(region.height * scale / capacity.height))
        return ink
    }

    private static func channels(_ colour: UIColor, traits: UITraitCollection) -> SIMD4<Float> {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        colour.resolvedColor(with: traits).getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        func clamp(_ value: CGFloat) -> Float { Float(min(max(value, 0), 1)) }
        return SIMD4(clamp(red), clamp(green), clamp(blue), 1)
    }
}
