import AppKit
import TailscodeCore

/// The light round the video button's edge: where the render is, drawn as a ring.
///
/// Core decides every frame (`ForgeLight.frame`) as strokes laid along the perimeter, from the top
/// centre and clockwise; this view only paints them. One path runs round the edge from the top
/// centre, a faint track lies under it, and every stroke is a shape layer that shows a stretch of
/// the same path through `strokeStart` and `strokeEnd` — a frame changes colour, alpha and those two
/// numbers and never a size layout depends on. Frames are read from absolute time off the display's
/// own clock, which runs only while the face moves and the view is in a window; a still face is
/// drawn once and costs nothing.
@MainActor
final class ForgeRingView: NSView {
    private let content = CALayer()
    private let track = CAShapeLayer()
    private var pool: [CAShapeLayer] = []
    private var link: CADisplayLink?
    private var lastStep: CFTimeInterval?
    private var displayed: Double?
    private var fadeTicket = 0
    private var isFading = false
    private var drawnSize: CGSize = .zero
    private(set) var light: ForgeLight = .dark

    static let lineWidth: CGFloat = 2
    static let fadeTime: TimeInterval = 0.25

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.addSublayer(content)
        Self.style(track)
        content.addSublayer(track)
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(motionPreferenceChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// Whether the display's clock is running, for a harness that proves a still face costs nothing.
    var isTicking: Bool { link != nil }

    /// The stretches of the path that are lit right now, as the layers hold them.
    var drawnStrokes: [(start: CGFloat, end: CGFloat, alpha: CGFloat)] {
        pool.filter { !$0.isHidden }.map {
            ($0.strokeStart, $0.strokeEnd, $0.strokeColor?.alpha ?? 0)
        }
    }

    /// How visible the faint full-circle track is right now.
    var trackAlpha: CGFloat { track.isHidden ? 0 : (track.strokeColor?.alpha ?? 0) }

    /// Puts a face on the ring. The same face again changes nothing, a new fraction of the same
    /// render only moves where the arc is heading, and a face that goes dark fades out where it
    /// stood rather than vanishing.
    func show(_ next: ForgeLight) {
        guard next != light else { return }
        let before = light
        light = next
        if case .rendering(let fraction) = next {
            displayed = displayed ?? fraction
        } else {
            displayed = nil
        }
        guard next != .dark else {
            stopClock()
            if before.isLit { fadeOut() }
            return
        }
        cancelFade()
        refresh()
    }

    override func layout() {
        super.layout()
        guard bounds.size != drawnSize else { return }
        drawnSize = bounds.size
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.frame = bounds
        track.frame = content.bounds
        track.path = Self.path(in: content.bounds)
        for stroke in pool {
            stroke.frame = content.bounds
            stroke.path = track.path
        }
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refresh()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        guard light.isLit else { return }
        paint(at: CACurrentMediaTime())
    }

    /// The desk changed its mind about movement, or the window shed load: the clock is asked
    /// again, and a ring that was moving is drawn as the still thing it now is.
    @objc private func motionPreferenceChanged() {
        refresh()
    }

    private var reduceMotion: Bool { !ActivityPulse.motionAllowed }

    private var motion: ActivityMotion { light.motion.honoring(reduceMotion: reduceMotion) }

    /// Draws the face as it stands and starts or stops the clock to match what it does.
    private func refresh() {
        guard light.isLit, window != nil else {
            stopClock()
            return
        }
        paint(at: CACurrentMediaTime())
        guard motion.isAnimated else {
            stopClock()
            return
        }
        guard link == nil else { return }
        let fresh = displayLink(target: self, selector: #selector(step(_:)))
        fresh.runAtActivityTempo()
        fresh.add(to: .current, forMode: .common)
        link = fresh
        lastStep = nil
    }

    private func stopClock() {
        link?.invalidate()
        link = nil
        lastStep = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        guard window != nil else {
            stopClock()
            return
        }
        if case .rendering(let target) = light {
            let elapsed = lastStep.map { link.timestamp - $0 } ?? 0
            displayed = ForgeRing.follow(displayed: displayed ?? target, target: target, elapsed: elapsed)
        }
        lastStep = link.timestamp
        paint(at: link.timestamp)
    }

    /// One frame at an instant of absolute time, which is also how a harness draws the ring at a
    /// time of its choosing instead of waiting for the clock to reach it.
    func paint(at time: CFTimeInterval) {
        apply(
            light.frame(
                at: time, displayed: motion.isAnimated ? displayed : nil, reduceMotion: reduceMotion))
    }

    /// One frame onto the layers, exactly: no implicit animation may stand between a frame and the
    /// screen, and a stroke the frame does not use is hidden rather than removed.
    private func apply(_ frame: ForgeRingFrame) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let ink = self.ink(for: frame.tone)
        track.isHidden = frame.track <= 0
        track.strokeColor = ink.copy(alpha: ink.alpha * Self.unit(frame.track))
        while pool.count < frame.strokes.count { pool.append(makeStroke()) }
        for (index, layer) in pool.enumerated() {
            guard index < frame.strokes.count else {
                layer.isHidden = true
                continue
            }
            let stroke = frame.strokes[index]
            let span = Self.span(of: stroke)
            layer.isHidden = false
            layer.strokeStart = span.start
            layer.strokeEnd = span.end
            layer.strokeColor = ink.copy(alpha: ink.alpha * Self.unit(stroke.intensity))
        }
        CATransaction.commit()
    }

    /// The tone's colour resolved in this view's own appearance, because a `CGColor` is no longer
    /// dynamic and one resolved against the wrong side of light and dark would stay that way.
    private func ink(for tone: ActivityTone) -> CGColor {
        var resolved = CGColor(gray: 0, alpha: 0)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = tone.color.cgColor
        }
        return resolved
    }

    private func makeStroke() -> CAShapeLayer {
        let layer = CAShapeLayer()
        Self.style(layer)
        layer.frame = content.bounds
        layer.path = track.path
        content.addSublayer(layer)
        return layer
    }

    /// The last frame, faded out where it stood, then taken off. A face that arrives while it fades
    /// takes the layers back, and a fade nobody is there to see is no fade at all.
    private func fadeOut() {
        guard window != nil, !reduceMotion else {
            clear()
            return
        }
        isFading = true
        fadeTicket += 1
        let ticket = fadeTicket
        CATransaction.begin()
        CATransaction.setAnimationDuration(Self.fadeTime)
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isFading, self.fadeTicket == ticket else { return }
                self.clear()
            }
        }
        content.opacity = 0
        CATransaction.commit()
    }

    private func cancelFade() {
        guard isFading else { return }
        isFading = false
        restoreContent()
    }

    private func clear() {
        isFading = false
        restoreContent()
        apply(ForgeRingFrame(tone: .quiet, track: 0, strokes: []))
    }

    private func restoreContent() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        content.removeAllAnimations()
        content.opacity = 1
        CATransaction.commit()
    }

    private static func style(_ layer: CAShapeLayer) {
        layer.fillColor = nil
        layer.lineWidth = lineWidth
        layer.lineCap = .round
        layer.strokeStart = 0
        layer.strokeEnd = 1
    }

    private static func unit(_ value: Double) -> CGFloat {
        CGFloat(min(max(value, 0), 1))
    }

    /// A stroke's stretch of the path, held to the path's own `0...1`: nothing handed to a layer
    /// may lie outside it, whatever a frame says.
    static func span(of stroke: ForgeRingFrame.Stroke) -> (start: CGFloat, end: CGFloat) {
        let start = min(max(stroke.start, 0), 1)
        let end = min(max(stroke.end, start), 1)
        return (CGFloat(start), CGFloat(end))
    }

    /// How round the button's corners are: the whole of its short side on the glass toolbar, where a
    /// button is a capsule, and a small curve on the bordered one before it.
    static func cornerRadius(for size: CGSize) -> CGFloat {
        if #available(macOS 26, *) { return min(size.width, size.height) / 2 }
        return 6
    }

    /// The ring's path: the button's edge inset by half the line, beginning at the top centre and
    /// running clockwise as it is seen. The layers are not flipped, so up is `maxY`.
    static func path(in bounds: CGRect) -> CGPath {
        let rect = bounds.insetBy(dx: lineWidth / 2, dy: lineWidth / 2)
        let radius = max(0, min(cornerRadius(for: bounds.size) - lineWidth / 2, rect.width / 2, rect.height / 2))
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.maxY))
        path.addArc(
            center: CGPoint(x: rect.maxX - radius, y: rect.maxY - radius), radius: radius,
            startAngle: .pi / 2, endAngle: 0, clockwise: true)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + radius))
        path.addArc(
            center: CGPoint(x: rect.maxX - radius, y: rect.minY + radius), radius: radius,
            startAngle: 0, endAngle: -.pi / 2, clockwise: true)
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        path.addArc(
            center: CGPoint(x: rect.minX + radius, y: rect.minY + radius), radius: radius,
            startAngle: -.pi / 2, endAngle: -.pi, clockwise: true)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - radius))
        path.addArc(
            center: CGPoint(x: rect.minX + radius, y: rect.maxY - radius), radius: radius,
            startAngle: .pi, endAngle: .pi / 2, clockwise: true)
        path.closeSubpath()
        return path
    }
}
