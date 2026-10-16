import AppKit
import TailscodeCore

/// The call's face at call size: the activity badge on an opaque disc, wearing the face's own symbol
/// in its own tone and moving the way that state means. Connecting turns, and listening and the
/// agent working breathe, on the render server's clock like every other mark in the window; speaking
/// is the one face whose light depends on something that changes every frame, the voice's level, so
/// it alone runs the display's clock. Each frame is arithmetic on absolute time through
/// `VoiceCallFace.intensity`, with the level eased by `VoiceCallLevels` so a word is seen when it
/// starts and the light does not flicker between syllables.
///
/// Hearing, a degraded voice and an ended call hold perfectly still and run no clock at all, and so
/// does everything under Reduce Motion. A frame changes light and a transform, never a size layout
/// depends on. The orb was not used: it draws one aggregate of everything the device watches and has
/// no way to say connecting, hearing or speaking-with-a-level without changes to its shader.
@MainActor
final class CallFaceView: NSView {
    private static let side: CGFloat = 30

    var level: () -> Double = { 0 }

    private let badge = ActivityBadgeView(pointSize: 16)
    private var face: VoiceCallFace?
    private var link: CADisplayLink?
    private var eased = 0.0
    private var lastStamp: CFTimeInterval = 0
    private var currentScale = 1.0

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerCurve = .continuous
        addSubview(badge)
        setAccessibilityElement(false)
        NotificationCenter.default.addObserver(
            self, selector: #selector(motionBudgetChanged), name: MotionBudget.didChange, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(motionBudgetChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeChanged), name: MacTheme.Chrome.didRepaint, object: nil)
        paint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    isolated deinit {
        NotificationCenter.default.removeObserver(self)
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        link?.invalidate()
    }

    private var diameter: CGFloat { ceil(Self.side * MacTheme.UIScale.factor) }

    override var intrinsicContentSize: NSSize { NSSize(width: diameter, height: diameter) }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
        badge.frame = bounds
        applyTransform(scale: currentScale)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window == nil ? stopClock() : refreshClock()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        paint()
    }

    /// Puts a face on the disc. The same face again changes nothing; speaking is drawn as a still
    /// badge whose light and size this view moves itself, because its swell is the voice's level
    /// and no pre-sampled animation could carry that.
    func show(_ next: VoiceCallFace) {
        guard next != face else { return }
        face = next
        if case .speaking = next {
            badge.show(
                ActivityIcon(symbol: next.symbol, glyph: next.glyph, tone: next.tone, motion: .still),
                spoken: nil)
        } else {
            badge.show(next.icon, spoken: nil)
        }
        eased = 0
        lastStamp = 0
        drawRest()
        refreshClock()
    }

    /// Whether the display's clock is running, for a harness that proves a still face costs nothing.
    var isTicking: Bool { link != nil }

    /// The disc follows the window's type scale and the theme, both of which are asked for again
    /// rather than remembered.
    func restyle() {
        paint()
        invalidateIntrinsicContentSize()
        needsLayout = true
    }

    @objc private func themeChanged() {
        restyle()
    }

    private func paint() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = MacTheme.Color.canvas.cgColor
        }
    }

    private var speaking: Bool {
        if case .speaking = face { return true }
        return false
    }

    private var animates: Bool { speaking && ActivityPulse.motionAllowed }

    @objc private func motionBudgetChanged() {
        drawRest()
        refreshClock()
    }

    private func refreshClock() {
        guard animates, window != nil else {
            stopClock()
            return
        }
        guard link == nil else { return }
        let fresh = displayLink(target: self, selector: #selector(step(_:)))
        fresh.runAtActivityTempo()
        fresh.add(to: .main, forMode: .common)
        link = fresh
        lastStamp = 0
    }

    private func stopClock() {
        link?.invalidate()
        link = nil
        lastStamp = 0
    }

    private func drawRest() {
        badge.alphaValue = 1
        currentScale = 1
        applyTransform(scale: 1)
    }

    @objc private func step(_ link: CADisplayLink) {
        guard animates, let face else {
            stopClock()
            drawRest()
            return
        }
        let time = link.timestamp
        let elapsed = lastStamp == 0 ? 0 : time - lastStamp
        lastStamp = time
        eased = VoiceCallLevels.smoothed(previous: eased, target: level(), dt: elapsed)
        let intensity = face.intensity(at: time, level: eased)
        badge.alphaValue = intensity
        let floor = ActivityTuning.breathFloor
        currentScale = 1 + ActivityTuning.lift * (intensity - floor) / max(0.0001, 1 - floor)
        applyTransform(scale: currentScale)
    }

    /// A breath is also a size, a small one, anchored at 1 so a still face is exactly its own size.
    /// It is laid on the disc's sublayers about the disc's own centre, because AppKit owns the
    /// transform of a view's own layer and returns its anchor to the corner on every layout.
    private func applyTransform(scale: Double) {
        guard let layer else { return }
        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        var transform = CATransform3DMakeTranslation(centre.x, centre.y, 0)
        transform = CATransform3DScale(transform, CGFloat(scale), CGFloat(scale), 1)
        transform = CATransform3DTranslate(transform, -centre.x, -centre.y, 0)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.sublayerTransform = transform
        CATransaction.commit()
    }
}
