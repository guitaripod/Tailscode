import TailscodeCore
import UIKit

/// The light round the video button's edge, which says where the render is.
///
/// Core decides every face (`ForgeLight`) and every frame of it (`ForgeRingFrame`): a colour slot,
/// a faint track, and strokes measured in fractions of the way round from the top centre,
/// clockwise. This view only paints them, as one shape layer for the track and a small pool for the
/// strokes, all stroking the same path, which is built by hand because a rounded rect's own path
/// starts somewhere else. A frame changes colour, alpha, `strokeStart` and `strokeEnd` and nothing
/// layout reads.
///
/// Frames come from `CADisplayLink` at the vocabulary's tempo, read as absolute time, and only
/// while the light moves and the view is on screen; a still light is drawn once and costs nothing.
/// Reduced motion is told to Core, which drops the movement and keeps the meaning.
@MainActor
final class ForgeRingView: UIView {
    private static let lineWidth: CGFloat = 2
    private static let fadeDuration: TimeInterval = 0.25

    private let track = CAShapeLayer()
    private var strokes: [CAShapeLayer] = []
    private var link: CADisplayLink?
    private var light = ForgeLight.dark
    private var displayed: Double?
    private var lastStep: CFTimeInterval = 0
    private var shown = ForgeRingFrame(tone: .quiet, track: 0, strokes: [])

    init() {
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        isAccessibilityElement = false
        style(track)
        track.strokeEnd = 1
        layer.addSublayer(track)
        NotificationCenter.default.addObserver(
            self, selector: #selector(motionPreferenceChanged),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeIdentityTrait.self]) {
            (ring: ForgeRingView, _) in
            ring.paint(ring.shown)
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    /// Takes the light the render is in. The same light again is left alone, so a clock that is
    /// mid-comet is never restarted by a board that restated itself.
    func show(_ next: ForgeLight) {
        guard next != light else { return }
        let previous = light
        light = next
        if next == .dark, previous != .dark {
            fadeOut()
            return
        }
        layer.removeAllAnimations()
        alpha = 1
        refresh()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let path = Self.edge(in: bounds.insetBy(dx: Self.lineWidth / 2, dy: Self.lineWidth / 2)).cgPath
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for shape in [track] + strokes {
            shape.frame = bounds
            shape.path = path
        }
        CATransaction.commit()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        window == nil ? stop() : refresh()
    }

    @objc private func motionPreferenceChanged() {
        refresh()
    }

    private var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }

    private func style(_ shape: CAShapeLayer) {
        shape.fillColor = nil
        shape.lineWidth = Self.lineWidth
        shape.lineCap = .round
        shape.path = Self.edge(in: bounds.insetBy(dx: Self.lineWidth / 2, dy: Self.lineWidth / 2)).cgPath
        shape.frame = bounds
    }

    /// The control's edge as a capsule that begins at the top centre and runs clockwise, so a
    /// fraction of the path's length is the fraction of the way round that Core means.
    private static func edge(in rect: CGRect) -> UIBezierPath {
        let radius = min(rect.width, rect.height) / 2
        let path = UIBezierPath()
        path.move(to: CGPoint(x: rect.midX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addArc(
            withCenter: CGPoint(x: rect.maxX - radius, y: rect.minY + radius), radius: radius,
            startAngle: -.pi / 2, endAngle: 0, clockwise: true)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addArc(
            withCenter: CGPoint(x: rect.maxX - radius, y: rect.maxY - radius), radius: radius,
            startAngle: 0, endAngle: .pi / 2, clockwise: true)
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addArc(
            withCenter: CGPoint(x: rect.minX + radius, y: rect.maxY - radius), radius: radius,
            startAngle: .pi / 2, endAngle: .pi, clockwise: true)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addArc(
            withCenter: CGPoint(x: rect.minX + radius, y: rect.minY + radius), radius: radius,
            startAngle: .pi, endAngle: 3 * .pi / 2, clockwise: true)
        path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
        return path
    }

    /// Reads the light again — a new face, a window, a changed preference — and starts or stops
    /// the clock to match. The arc is held at the machine's word under reduced motion, because
    /// easing toward it is movement.
    private func refresh() {
        if case .rendering(let target) = light {
            displayed = reduceMotion ? target : (displayed ?? target)
        } else {
            displayed = nil
        }
        draw(at: CACurrentMediaTime())
        light.motion.honoring(reduceMotion: reduceMotion).isAnimated && window != nil ? start() : stop()
    }

    /// A light that has been read leaves the way it came: the last frame fades rather than
    /// vanishing, and the next face starts from a clean ring.
    private func fadeOut() {
        stop()
        displayed = nil
        UIView.animate(
            withDuration: reduceMotion ? 0 : Self.fadeDuration,
            animations: { self.alpha = 0 },
            completion: { [weak self] _ in
                guard let self, self.light == .dark else { return }
                self.draw(at: CACurrentMediaTime())
                self.alpha = 1
            })
    }

    private func start() {
        guard link == nil else { return }
        lastStep = CACurrentMediaTime()
        let made = CADisplayLink(target: self, selector: #selector(step))
        made.runAtActivityTempo()
        made.add(to: .main, forMode: .common)
        link = made
    }

    private func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func step(_ link: CADisplayLink) {
        let now = link.timestamp
        if case .rendering(let target) = light, let current = displayed {
            displayed = ForgeRing.follow(displayed: current, target: target, elapsed: now - lastStep)
        }
        lastStep = now
        draw(at: now)
    }

    private func draw(at time: CFTimeInterval) {
        let frame = light.frame(at: time, displayed: displayed, reduceMotion: reduceMotion)
        shown = frame
        paint(frame)
    }

    private func paint(_ frame: ForgeRingFrame) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let ink = frame.tone.color.resolvedColor(with: traitCollection).cgColor
        track.isHidden = frame.track <= 0
        track.strokeColor = ink.copy(alpha: ink.alpha * frame.track)
        while strokes.count < frame.strokes.count { strokes.append(makeStroke()) }
        for (index, shape) in strokes.enumerated() {
            guard index < frame.strokes.count, frame.strokes[index].length > 0 else {
                shape.isHidden = true
                continue
            }
            let stroke = frame.strokes[index]
            shape.isHidden = false
            shape.strokeStart = stroke.start
            shape.strokeEnd = min(stroke.end, 1)
            shape.strokeColor = ink.copy(alpha: ink.alpha * stroke.intensity)
        }
        CATransaction.commit()
    }

    private func makeStroke() -> CAShapeLayer {
        let shape = CAShapeLayer()
        style(shape)
        shape.isHidden = true
        layer.addSublayer(shape)
        return shape
    }
}
