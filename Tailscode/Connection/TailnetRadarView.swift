import TailscodeCore
import UIKit

/// The dial a tailnet scan draws while it runs.
///
/// Looking for a machine is a wait with nothing to read, and a spinner says only that something is
/// happening. `TailnetRadar` decides where the arm is and how bright every machine is at an
/// absolute time; this view only rasterises those numbers, so the phone, the Mac and the Linux
/// desktop draw the same scan at the same speed with the same constellation.
@MainActor
final class TailnetRadarView: UIView {
    private var link: CADisplayLink?
    private var blips: [RadarBlip] = []
    private var scanning = false
    private var current = TailnetRadar.frame(at: 0, blips: [], scanning: false)

    static var now: TimeInterval { CACurrentMediaTime() }

    static var motionAllowed: Bool { !UIAccessibility.isReduceMotionEnabled }

    override init(frame: CGRect) {
        super.init(frame: frame)
        translatesAutoresizingMaskIntoConstraints = false
        backgroundColor = .clear
        isAccessibilityElement = false
        contentMode = .redraw
        NotificationCenter.default.addObserver(
            self, selector: #selector(motionPreferenceChanged),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
        registerForTraitChanges([UITraitUserInterfaceStyle.self]) { (view: TailnetRadarView, _) in
            view.setNeedsDisplay()
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize { CGSize(width: 168, height: 168) }

    /// What the dial knows. Called as each machine answers, so the picture is the progress rather
    /// than a bar that fills beside it.
    func show(blips: [RadarBlip], scanning: Bool) {
        self.blips = blips
        self.scanning = scanning
        if scanning, Self.motionAllowed {
            start()
        } else {
            stop()
        }
        render(at: Self.now)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard scanning, Self.motionAllowed else { return }
        window == nil ? stop() : start()
    }

    /// A phone that asks for less motion mid-scan is honoured at once: the same dial is drawn at
    /// rest with everything it has already found on it, and nothing is hidden by taking the
    /// movement away.
    @objc private func motionPreferenceChanged() {
        show(blips: blips, scanning: scanning)
    }

    private func start() {
        guard link == nil, window != nil else { return }
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
        render(at: link.timestamp)
    }

    private func render(at time: TimeInterval) {
        current = TailnetRadar.frame(
            at: time, blips: blips, scanning: scanning, reducedMotion: !Self.motionAllowed)
        setNeedsDisplay()
        if current.settled { stop() }
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let reach = min(bounds.width, bounds.height) / 2 - 3
        guard reach > 4 else { return }
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        drawGrid(in: context, center: center, reach: reach)
        drawSweep(in: context, center: center, reach: reach)
        drawPing(in: context, center: center, reach: reach)
        drawSparks(in: context, center: center, reach: reach)
    }

    /// Rings at the distances Core named, and a faint cross, so an empty tailnet still looks like
    /// an instrument rather than a blank circle.
    private func drawGrid(in context: CGContext, center: CGPoint, reach: CGFloat) {
        let ink = Theme.Color.tertiaryLabel
        context.setLineWidth(1)
        context.setStrokeColor(ink.withAlphaComponent(0.22).cgColor)
        for ring in TailnetRadar.rings {
            let radius = reach * CGFloat(ring)
            guard radius > 0.5 else { continue }
            context.strokeEllipse(in: Self.square(around: center, radius: radius))
        }
        context.setStrokeColor(ink.withAlphaComponent(0.13).cgColor)
        for spoke in 0..<4 {
            context.move(to: center)
            context.addLine(to: place(center, reach, Double(spoke) * .pi / 2, 0.98))
        }
        context.strokePath()
    }

    /// The arm and the light it drags behind it. A gradient cannot run along an arc, so the wake is
    /// laid down as narrow wedges whose alpha falls off the way Core's blip light does — the same
    /// curve, so the arm and the machines it crosses agree about where it has been.
    private func drawSweep(in context: CGContext, center: CGPoint, reach: CGFloat) {
        guard current.sweepLight > 0 else { return }
        let ink = Theme.Color.accent
        let span = TailnetRadar.wake
        let wedges = 48
        for wedge in 0..<wedges {
            let from = Double(wedge) / Double(wedges) * span
            let to = Double(wedge + 1) / Double(wedges) * span
            let alpha = exp(-from / 0.62) * 0.20 * current.sweepLight
            guard alpha >= 0.002 else { break }
            context.beginPath()
            context.move(to: center)
            context.addArc(
                center: center, radius: reach * 0.98,
                startAngle: Self.screenAngle(current.sweep - to),
                endAngle: Self.screenAngle(current.sweep - from), clockwise: false)
            context.closePath()
            context.setFillColor(ink.withAlphaComponent(CGFloat(alpha)).cgColor)
            context.fillPath()
        }
        context.setLineWidth(1.4)
        context.setLineCap(.round)
        context.setStrokeColor(ink.withAlphaComponent(CGFloat(0.85 * current.sweepLight)).cgColor)
        context.move(to: center)
        context.addLine(to: place(center, reach, current.sweep, 0.98))
        context.strokePath()
    }

    private func drawPing(in context: CGContext, center: CGPoint, reach: CGFloat) {
        guard current.pingLight > 0 else { return }
        let radius = reach * CGFloat(current.ping)
        guard radius > 0.5 else { return }
        context.setLineWidth(1.2)
        context.setStrokeColor(
            Theme.Color.accent.withAlphaComponent(CGFloat(current.pingLight)).cgColor)
        context.strokeEllipse(in: Self.square(around: center, radius: radius))
    }

    /// One machine: a filled dot inside its own soft halo, in the ink its state earns.
    private func drawSparks(in context: CGContext, center: CGPoint, reach: CGFloat) {
        for spark in current.sparks {
            let ink = Self.ink(for: spark.tone)
            let size = CGFloat(3.2 * spark.scale)
            let at = place(center, reach, spark.angle, spark.radius)
            context.setFillColor(ink.withAlphaComponent(CGFloat(0.18 * spark.light)).cgColor)
            context.fillEllipse(in: Self.square(around: at, radius: size * 2.8))
            context.setFillColor(ink.withAlphaComponent(CGFloat(spark.light)).cgColor)
            context.fillEllipse(in: Self.square(around: at, radius: size))
        }
    }

    /// The three tones in this app's palette: a machine that will do the job wears affirmation, one
    /// that wants a password wears attention, and a machine still being asked keeps identity.
    private static func ink(for tone: RadarTone) -> UIColor {
        switch tone {
        case .ready: return Theme.Color.success
        case .locked: return Theme.Color.warning
        case .pending: return Theme.Color.info
        }
    }

    private func place(_ center: CGPoint, _ reach: CGFloat, _ angle: Double, _ radius: Double)
        -> CGPoint
    {
        CGPoint(
            x: center.x + CGFloat(sin(angle)) * reach * CGFloat(radius),
            y: center.y - CGFloat(cos(angle)) * reach * CGFloat(radius))
    }

    /// The dial's own angle in the one Core Graphics measures. The dial runs clockwise from due
    /// north; a UIKit context runs clockwise from due east, so the two are a quarter turn apart.
    private static func screenAngle(_ angle: Double) -> CGFloat {
        CGFloat(angle - Double.pi / 2)
    }

    private static func square(around center: CGPoint, radius: CGFloat) -> CGRect {
        CGRect(
            x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
    }
}
