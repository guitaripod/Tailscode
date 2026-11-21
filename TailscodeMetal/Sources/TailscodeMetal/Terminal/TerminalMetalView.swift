import CoreText
import Metal
import MetalKit
import QuartzCore
import TailscodeCore

#if os(macOS)
    import AppKit
#else
    import UIKit
#endif

/// The grid a terminal view can show, in device pixels, so a pointer position and a cell size
/// are always in the same unit.
public struct TerminalGrid: Sendable, Equatable {
    public var cols: Int
    public var rows: Int
    public var cellWidth: Int
    public var cellHeight: Int
    public var padding: Int
    public var width: Int
    public var height: Int
}

/// A terminal's picture on Apple platforms: a session's frames drawn by Metal, only when there
/// is something new to show. It draws and measures; the keyboard and the pointer belong to the
/// client's own subclass, because a Mac and an iPad hear both differently.
///
/// A display link does the drawing and runs only while a frame is owed: asking for a frame
/// starts it, the next refresh draws, and a refresh that finds nothing owed stops it again. So a
/// quiet terminal costs nothing, a busy one is drawn once per refresh however fast its bytes
/// arrive, and no frame that was asked for is ever left undrawn.
///
/// A frame is handed over with the transaction that is open when it is drawn, not queued for the
/// display by itself: a queued frame is shown when the next one arrives, which for a terminal
/// that has gone quiet is never, and a frame that rides the transaction also stays glued to the
/// window's edge while it is dragged.
@MainActor
open class TerminalMetalView: MTKView {
    /// The session whose screen is drawn. Setting it draws that session's whole screen.
    public weak var session: TerminalSession? {
        didSet {
            forceNext = true
            if let grid { apply(grid) }
            requestFrame()
        }
    }

    /// Called when the grid the view can show changes.
    public var onGrid: ((TerminalGrid) -> Void)?

    /// Whether the pane has the keyboard: the cursor is solid and may blink only then.
    public var showsFocus = false {
        didSet {
            guard showsFocus != oldValue else { return }
            blinkOn = true
            syncBlink()
            renderer?.restyle(focused: showsFocus, blinkOn: blinkOn)
            redraw()
        }
    }

    public private(set) var grid: TerminalGrid?
    public static var isSupported: Bool { MTLCreateSystemDefaultDevice() != nil }

    /// The margin around the grid, in points: what lines the text up with whatever sits above it.
    public var inset: CGFloat = 6 {
        didSet {
            guard inset != oldValue else { return }
            grid = nil
            measure()
        }
    }

    private var renderer: TerminalRenderer?
    private var queue: MTLCommandQueue?
    private var points: CGFloat = 12
    private var builtScale: CGFloat = 0
    private var forceNext = true
    private var blinkOn = true
    private var blink: Timer?
    private var draws = 0
    private var skipped = 0
    private var link: CADisplayLink?
    private var owesFrame = false

    /// What the view has done, in a line: whether it has a renderer and a grid, how often it drew
    /// and how many quads the last frame held. For a check that has no eyes.
    public var diagnostics: String {
        let size = "\(Int(drawableSize.width))x\(Int(drawableSize.height))"
        let grid = grid.map { "\($0.cols)x\($0.rows) cell \($0.cellWidth)x\($0.cellHeight)" } ?? "none"
        return "renderer=\(renderer != nil) grid=\(grid) drawable=\(size) draws=\(draws) skipped=\(skipped) "
            + "quads=\(renderer?.lastQuadCount ?? -1) session=\(session != nil) window=\(window != nil)"
    }

    public init(frame: CGRect) {
        let device = MTLCreateSystemDefaultDevice()
        super.init(frame: frame, device: device)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        isPaused = true
        enableSetNeedsDisplay = false
        autoResizeDrawable = true
        queue = device?.makeCommandQueue()
        #if os(macOS)
            (layer as? CAMetalLayer)?.isOpaque = true
        #else
            isOpaque = true
        #endif
        (layer as? CAMetalLayer)?.presentsWithTransaction = true
    }

    @available(*, unavailable)
    public required init(coder: NSCoder) { fatalError("init(coder:) is not available") }

    #if os(macOS)
        open override var isFlipped: Bool { true }

        private var scale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

        private static func face(pixels: CGFloat) -> CTFont {
            NSFont.monospacedSystemFont(ofSize: pixels, weight: .regular) as CTFont
        }

        open override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            rebuildIfScaleChanged()
        }

        open override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            link?.invalidate()
            link = nil
            if window != nil {
                let made = displayLink(target: LinkTarget(self), selector: #selector(LinkTarget.tick))
                made.isPaused = true
                made.add(to: .main, forMode: .common)
                link = made
            }
            rebuildIfScaleChanged()
            syncBlink()
            requestFrame()
        }

        open override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            measure()
        }

    #else
        private var scale: CGFloat { window?.screen.scale ?? traitCollection.displayScale }

        private static func face(pixels: CGFloat) -> CTFont {
            UIFont.monospacedSystemFont(ofSize: pixels, weight: .regular) as CTFont
        }

        open override func didMoveToWindow() {
            super.didMoveToWindow()
            link?.invalidate()
            link = nil
            if window != nil {
                let made = CADisplayLink(target: LinkTarget(self), selector: #selector(LinkTarget.tick))
                made.isPaused = true
                made.add(to: .main, forMode: .common)
                link = made
            }
            rebuildIfScaleChanged()
            syncBlink()
            requestFrame()
        }

        open override func layoutSubviews() {
            super.layoutSubviews()
            measure()
        }

    #endif

    /// What the display link holds instead of the view, so the link never keeps the view alive.
    private final class LinkTarget: NSObject {
        private weak var view: TerminalMetalView?

        @MainActor init(_ view: TerminalMetalView) { self.view = view }

        @MainActor @objc func tick() { view?.refresh() }
    }

    private func redraw() {
        owesFrame = true
        link?.isPaused = false
    }

    /// One refresh of the display: the frame that is owed is drawn, and a refresh that owes
    /// nothing puts the link back to sleep.
    private func refresh() {
        guard owesFrame else {
            link?.isPaused = true
            return
        }
        owesFrame = false
        draw()
    }

    /// The colour behind the grid before there is a frame to say: 0xRRGGBB. A view with no shell
    /// yet wears the theme like everything around it.
    public var canvas: UInt32 = 0 {
        didSet {
            renderer?.setCanvas(canvas)
            requestFrame()
        }
    }

    /// The size the terminal is set in, in points.
    public func setFontSize(_ points: CGFloat) {
        guard abs(points - self.points) > 0.01 || renderer == nil else { return }
        self.points = points
        builtScale = 0
        rebuildIfScaleChanged()
    }

    /// The atlas holds glyphs rasterised for one pixel size, so a window that moves to a display
    /// of another density starts a new one.
    private func rebuildIfScaleChanged() {
        guard let device, scale > 0, scale != builtScale || renderer == nil else { return }
        builtScale = scale
        renderer = TerminalRenderer(
            device: device, pixelFormat: colorPixelFormat, font: Self.face(pixels: (points * scale).rounded()))
        renderer?.setCanvas(canvas)
        forceNext = true
        grid = nil
        measure()
        requestFrame()
    }

    private func measure() {
        guard let renderer else { return }
        let width = Int((bounds.width * scale).rounded())
        let height = Int((bounds.height * scale).rounded())
        guard width > 0, height > 0 else { return }
        let padding = Int((inset * scale).rounded())
        let metrics = renderer.metrics
        let next = TerminalGrid(
            cols: max((width - padding * 2) / metrics.width, 2), rows: max((height - padding * 2) / metrics.height, 1),
            cellWidth: metrics.width, cellHeight: metrics.height, padding: padding, width: width, height: height)
        guard next != grid else { return }
        grid = next
        apply(next)
        onGrid?(next)
        forceNext = true
        requestFrame()
    }

    private func apply(_ grid: TerminalGrid) {
        session?.resize(cols: grid.cols, rows: grid.rows, cellWidth: grid.cellWidth, cellHeight: grid.cellHeight)
        session?.screen?.setGeometry(
            cellWidth: grid.cellWidth, cellHeight: grid.cellHeight, paddingLeft: grid.padding,
            paddingTop: grid.padding, width: grid.width, height: grid.height)
    }

    /// A point in the view as the terminal counts it: device pixels from the top left.
    public func pixel(_ point: CGPoint) -> (x: Double, y: Double) {
        (Double(point.x * scale), Double(point.y * scale))
    }

    /// The height of a row, in points: what a wheel's distance is divided by.
    public var rowHeight: CGFloat {
        guard let grid, scale > 0 else { return 16 }
        return CGFloat(grid.cellHeight) / scale
    }

    /// Asks for a draw: the session has something new, or the view lost its picture.
    public func requestFrame() {
        guard window != nil else { return }
        redraw()
    }

    private func syncBlink() {
        let wanted = showsFocus && window != nil && (renderer?.cursorBlinks ?? false)
        if wanted, blink == nil {
            blinkOn = true
            blink = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.blinkOn.toggle()
                    self.renderer?.restyle(focused: self.showsFocus, blinkOn: self.blinkOn)
                    self.redraw()
                }
            }
        } else if !wanted, blink != nil {
            blink?.invalidate()
            blink = nil
            blinkOn = true
        }
    }

    open override func draw(_ rect: CGRect) {
        guard let renderer, let queue, drawableSize.width >= 1, drawableSize.height >= 1 else { return }
        if let frame = session?.frame(force: forceNext) {
            forceNext = false
            if renderer.update(frame, focused: showsFocus, blinkOn: blinkOn) { blinkOn = true }
            syncBlink()
        }
        guard let pass = currentRenderPassDescriptor, let drawable = currentDrawable,
            let buffer = queue.makeCommandBuffer()
        else {
            skipped += 1
            redraw()
            return
        }
        draws += 1
        renderer.encode(
            commandBuffer: buffer, pass: pass, drawableSize: drawableSize,
            padding: Float((inset * scale).rounded()))
        buffer.commit()
        buffer.waitUntilScheduled()
        drawable.present()
    }
}
