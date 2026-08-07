import MetalKit
import TailscodeCore
import UIKit

/// The presence orb: the aggregate of everything this phone watches, worn as one small creature
/// floating over Home. The whole behaviour is Core's `PresenceField` — this end only resolves the
/// theme's inks, reads the display's clock, and hands each frame to the shader — and the link
/// pauses the moment a frame reports itself settled, because stillness rendered a hundred times a
/// second is a battery spent on a picture that is finished.
@MainActor
final class PresenceOrbView: UIView {
    private struct Uniforms {
        var size: SIMD2<Float>
        var blobCount: Int32
        var stopCount: Int32
        var color: SIMD4<Float>
        var params: SIMD4<Float>
        var blobs:
            (
                SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
                SIMD4<Float>, SIMD4<Float>, SIMD4<Float>
            )
        var stops:
            (
                SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>,
                SIMD4<Float>, SIMD4<Float>, SIMD4<Float>
            )
    }

    private let metalView = MTKView()
    private var device: MTLDevice?
    private var queue: MTLCommandQueue?
    private var pipeline: MTLRenderPipelineState?
    private var field: PresenceField
    private(set) var signal = PresenceSignal()
    var onTap: (() -> Void)?

    init() {
        field = PresenceField(colors: PresenceColors(
            live: PresenceRGB(red: 0.3, green: 0.8, blue: 0.4),
            attention: PresenceRGB(red: 0.9, green: 0.7, blue: 0.2),
            danger: PresenceRGB(red: 0.9, green: 0.3, blue: 0.3),
            quiet: PresenceRGB(red: 0.5, green: 0.5, blue: 0.55)))
        super.init(frame: .zero)
        configureMetal()
        field.set(colors: inks())
        isAccessibilityElement = true
        accessibilityTraits = .button
        accessibilityLabel = signal.spoken
        addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(tapped)))
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeIdentityTrait.self]) {
            (view: PresenceOrbView, _) in
            view.field.set(colors: view.inks())
            view.wake()
        }
        NotificationCenter.default.addObserver(
            self, selector: #selector(motionPreferenceChanged),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private func configureMetal() {
        guard let device = MTLCreateSystemDefaultDevice(),
            let library = device.makeDefaultLibrary(),
            let vertex = library.makeFunction(name: "orb_vertex"),
            let fragment = library.makeFunction(name: "orb_fragment")
        else {
            isHidden = true
            return
        }
        self.device = device
        queue = device.makeCommandQueue()
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertex
        descriptor.fragmentFunction = fragment
        let attachment = descriptor.colorAttachments[0]!
        attachment.pixelFormat = .bgra8Unorm
        attachment.isBlendingEnabled = true
        attachment.sourceRGBBlendFactor = .one
        attachment.sourceAlphaBlendFactor = .one
        attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
        attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
        pipeline = try? device.makeRenderPipelineState(descriptor: descriptor)
        guard pipeline != nil else {
            isHidden = true
            return
        }
        metalView.device = device
        metalView.delegate = self
        metalView.isOpaque = false
        metalView.backgroundColor = .clear
        metalView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        metalView.framebufferOnly = true
        metalView.preferredFramesPerSecond = 60
        metalView.isUserInteractionEnabled = false
        metalView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(metalView)
        NSLayoutConstraint.activate([
            metalView.topAnchor.constraint(equalTo: topAnchor),
            metalView.bottomAnchor.constraint(equalTo: bottomAnchor),
            metalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            metalView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    /// The palette's own tone slots, and nothing private — under System, the platform's colours,
    /// resolved against this view's own traits so the orb flips with the appearance it sits in.
    private func inks() -> PresenceColors {
        func rgb(_ color: UIColor) -> PresenceRGB {
            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
            var alpha: CGFloat = 0
            color.resolvedColor(with: traitCollection).getRed(
                &red, green: &green, blue: &blue, alpha: &alpha)
            return PresenceRGB(red: red, green: green, blue: blue)
        }
        return PresenceColors(
            live: rgb(ActivityTone.live.color), attention: rgb(ActivityTone.attention.color),
            danger: rgb(ActivityTone.danger.color), quiet: rgb(ActivityTone.quiet.color))
    }

    func update(signal: PresenceSignal) {
        guard signal != self.signal else { return }
        self.signal = signal
        field.set(signal: signal)
        accessibilityLabel = signal.spoken
        wake()
    }

    /// Disabling must stop the clock, not just the pixels: a hidden view's display link runs on,
    /// and an animated signal never settles, so hiding alone would spend the battery the setting
    /// exists to protect.
    func setEnabled(_ enabled: Bool) {
        isHidden = !enabled
        if enabled { wake() } else { metalView.isPaused = true }
    }

    private func wake() {
        guard window != nil, !isHidden else { return }
        metalView.isPaused = false
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { metalView.isPaused = true } else { wake() }
    }

    @objc private func tapped() { onTap?() }

    @objc private func motionPreferenceChanged() { wake() }
}

extension PresenceOrbView: MTKViewDelegate {
    nonisolated func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    nonisolated func draw(in view: MTKView) {
        MainActor.assumeIsolated { render(in: view) }
    }

    private func render(in view: MTKView) {
        guard let pipeline, let queue, let descriptor = view.currentRenderPassDescriptor,
            let drawable = view.currentDrawable
        else { return }
        let frame = field.frame(
            at: CACurrentMediaTime(), reduceMotion: UIAccessibility.isReduceMotionEnabled)
        if frame.settled { view.isPaused = true }
        var uniforms = Self.uniforms(for: frame, size: view.drawableSize)
        guard let commands = queue.makeCommandBuffer(),
            let encoder = commands.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }
        encoder.setRenderPipelineState(pipeline)
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.setFragmentBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }

    private static func uniforms(for frame: PresenceFrame, size: CGSize) -> Uniforms {
        var blobs = Array(repeating: SIMD4<Float>(), count: 8)
        for (index, blob) in frame.blobs.prefix(8).enumerated() {
            blobs[index] = SIMD4(
                Float(blob.x), Float(blob.y), Float(blob.radius), Float(blob.weight))
        }
        var stops = Array(repeating: SIMD4<Float>(), count: 8)
        for (index, stop) in Ultracode.rainbowStops.prefix(8).enumerated() {
            stops[index] = SIMD4(Float(stop.red), Float(stop.green), Float(stop.blue), 1)
        }
        return Uniforms(
            size: SIMD2(Float(size.width), Float(size.height)),
            blobCount: Int32(min(frame.blobs.count, 8)),
            stopCount: Int32(min(Ultracode.rainbowStops.count, 8)),
            color: SIMD4(
                Float(frame.color.red), Float(frame.color.green), Float(frame.color.blue),
                Float(frame.rainbowGlow)),
            params: SIMD4(
                Float(frame.energy), Float(frame.intensity), Float(frame.rainbow),
                Float(frame.rainbowPhase)),
            blobs: (
                blobs[0], blobs[1], blobs[2], blobs[3], blobs[4], blobs[5], blobs[6], blobs[7]
            ),
            stops: (
                stops[0], stops[1], stops[2], stops[3], stops[4], stops[5], stops[6], stops[7]
            ))
    }
}
