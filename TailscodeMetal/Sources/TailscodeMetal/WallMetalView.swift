import Metal
import MetalKit
import QuartzCore
import TailscodeCore

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// The wall's ground: one `MTKView` that asks `sceneProvider` for a scene once a frame and draws it with
/// a `WallRenderer`. The words sit above it in the client's own views, so it never takes a touch.
@MainActor
public final class WallMetalView: MTKView {
    /// Asked once per frame with `CACurrentMediaTime()`; nil draws nothing.
    public var sceneProvider: ((_ t: TimeInterval) -> WallScene?)?

    /// The frames a second the view runs at; 0 pauses it.
    public var framesPerSecond: Int = 0 {
        didSet { if framesPerSecond != oldValue { applyFrameRate() } }
    }

    public static var isSupported: Bool { MTLCreateSystemDefaultDevice() != nil }

    /// Seconds the last finished frame spent on the GPU.
    public var lastGPUTime: Double { renderer?.lastGPUTime ?? 0 }

    private var renderer: WallRenderer?
    private var queue: MTLCommandQueue?

    #if !os(macOS)
    private var link: CADisplayLink?
    #endif

    public init(frame: CGRect) {
        let device = MTLCreateSystemDefaultDevice()
        super.init(frame: frame, device: device)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        isPaused = true
        enableSetNeedsDisplay = false
        autoResizeDrawable = true
        #if os(macOS)
        (layer as? CAMetalLayer)?.isOpaque = true
        #else
        isOpaque = true
        isUserInteractionEnabled = false
        #endif
        if let device {
            renderer = WallRenderer(device: device, pixelFormat: colorPixelFormat)
            queue = device.makeCommandQueue()
        }
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not available") }

    /// Renders one frame now, even while paused.
    public func drawOnce() { draw() }

    public override func draw(_ rect: CGRect) {
        guard let renderer, let queue, drawableSize.width >= 1, drawableSize.height >= 1,
            let scene = sceneProvider?(CACurrentMediaTime()),
            let pass = currentRenderPassDescriptor, let drawable = currentDrawable,
            let buffer = queue.makeCommandBuffer()
        else { return }
        let pointsPerPixel = bounds.width / drawableSize.width
        renderer.encode(
            scene, commandBuffer: buffer, pass: pass, drawableSize: drawableSize, pointsPerPixel: pointsPerPixel)
        buffer.present(drawable)
        buffer.commit()
    }

    #if os(macOS)
    public override func hitTest(_ point: NSPoint) -> NSView? { nil }
    #else
    public override func didMoveToWindow() {
        super.didMoveToWindow()
        applyFrameRate()
    }
    #endif

    private func applyFrameRate() {
        #if os(macOS)
        guard framesPerSecond > 0 else {
            isPaused = true
            return
        }
        preferredFramesPerSecond = framesPerSecond
        isPaused = false
        #else
        link?.invalidate()
        link = nil
        isPaused = true
        guard framesPerSecond > 0, window != nil else { return }
        let cap = Float(min(max(framesPerSecond, 1), 60))
        let next = CADisplayLink(target: WallLinkTarget(self), selector: #selector(WallLinkTarget.tick))
        next.preferredFrameRateRange = CAFrameRateRange(minimum: 1, maximum: cap, preferred: cap)
        next.add(to: .main, forMode: .common)
        link = next
        #endif
    }
}

#if !os(macOS)
/// What a display link holds instead of the view, so the link never keeps the view alive.
private final class WallLinkTarget: NSObject {
    private weak var view: WallMetalView?

    @MainActor init(_ view: WallMetalView) { self.view = view }

    @MainActor @objc func tick() { view?.drawOnce() }
}
#endif
