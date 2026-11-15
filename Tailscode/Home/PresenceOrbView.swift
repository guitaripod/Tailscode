import MetalKit
import TailscodeCore
import UIKit

/// The presence orb: the aggregate of everything this phone watches, worn as one small glass bead
/// in Home's bar. The whole behaviour is Core's `PresenceField` — this end only resolves the
/// theme's inks, reads the display's clock, and hands each frame to the shader — and the clock
/// stops the moment a frame reports itself settled, because stillness redrawn twenty times a second
/// is a battery spent on a picture that is finished.
@MainActor
final class PresenceOrbView: UIView {
    private struct Uniforms {
        var size: SIMD2<Float>
        var blobCount: Int32
        var stopCount: Int32
        var color: SIMD4<Float>
        var params: SIMD4<Float>
        var look: SIMD4<Float>
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

    /// How often the bead is redrawn while it moves. Every motion it makes is a slow one at the
    /// size of a bar button — a breath over seconds, satellites a few points a second, a knock
    /// that lasts a quarter of one — so twenty frames draw it as smoothly as thirty would, for a
    /// third fewer wakes of the main thread and the GPU.
    static let tempo = 20

    /// How much of the field's unit space the view shows: less than all of it, so the core reads
    /// at bar size while the outermost satellite and the start of its glow still fit.
    static let zoom: Float = 0.72

    private let metalView = MTKView()
    private var pipeline: MTLRenderPipelineState?
    private var queue: MTLCommandQueue?
    private var field: PresenceField
    private(set) var signal = PresenceSignal()
    private var isHeld = false
    private nonisolated(unsafe) var observers: [NSObjectProtocol] = []

    /// False where Metal cannot draw it, so the button wears a symbol instead of an empty glass.
    var isAvailable: Bool { pipeline != nil }

    init() {
        field = PresenceField(colors: PresenceColors(
            live: PresenceRGB(red: 0.3, green: 0.8, blue: 0.4),
            attention: PresenceRGB(red: 0.9, green: 0.7, blue: 0.2),
            danger: PresenceRGB(red: 0.9, green: 0.3, blue: 0.3),
            quiet: PresenceRGB(red: 0.5, green: 0.5, blue: 0.55)))
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        configureMetal()
        field.set(colors: inks())
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeIdentityTrait.self]) {
            (view: PresenceOrbView, _) in
            view.field.set(colors: view.inks())
            view.wake()
        }
        observeStillness()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    private func configureMetal() {
        guard let context = NeuralMetalContext.shared,
            let pipeline = context.premultipliedPipeline(
                vertex: "orb_vertex", fragment: "orb_fragment", format: .bgra8Unorm)
        else { return }
        queue = context.queue
        self.pipeline = pipeline
        metalView.device = context.device
        metalView.delegate = self
        metalView.isOpaque = false
        metalView.backgroundColor = .clear
        metalView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        metalView.framebufferOnly = true
        metalView.autoResizeDrawable = true
        metalView.preferredFramesPerSecond = Self.tempo
        metalView.isUserInteractionEnabled = false
        metalView.isPaused = true
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
        wake()
    }

    /// Under a sheet that hides it the bead stops drawing, and picks up where its field says it is
    /// the moment it is seen again: the field reads absolute time, so no frame is owed.
    func setHeld(_ held: Bool) {
        isHeld = held
        if held { metalView.isPaused = true } else { wake() }
    }

    private func wake() {
        guard pipeline != nil, window != nil, !isHidden, !isHeld else { return }
        metalView.isPaused = false
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { metalView.isPaused = true } else { wake() }
    }

    /// Reduce Motion, Low Power Mode and a phone running hot all ask for the same thing: each
    /// state's resting arrangement, drawn once, with its colour and its satellites and nothing
    /// that needs a clock.
    private var holdsStill: Bool {
        let info = ProcessInfo.processInfo
        return UIAccessibility.isReduceMotionEnabled || info.isLowPowerModeEnabled
            || info.thermalState == .serious || info.thermalState == .critical
    }

    /// Low Power Mode and the thermal state are posted from whichever thread noticed them, so the
    /// bead hears them on the main queue.
    private func observeStillness() {
        for name in [
            UIAccessibility.reduceMotionStatusDidChangeNotification,
            Notification.Name.NSProcessInfoPowerStateDidChange,
            ProcessInfo.thermalStateDidChangeNotification,
        ] {
            observers.append(
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                    [weak self] _ in
                    MainActor.assumeIsolated { self?.wake() }
                })
        }
    }
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
        let frame = field.frame(at: CACurrentMediaTime(), reduceMotion: holdsStill)
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
            look: SIMD4(zoom, 0, 0, 0),
            blobs: (
                blobs[0], blobs[1], blobs[2], blobs[3], blobs[4], blobs[5], blobs[6], blobs[7]
            ),
            stops: (
                stops[0], stops[1], stops[2], stops[3], stops[4], stops[5], stops[6], stops[7]
            ))
    }
}
