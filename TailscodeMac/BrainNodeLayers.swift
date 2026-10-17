import AppKit
import TailscodeCore

/// The six shapes a zone's steps are drawn as, built once per size so a tint is never the only
/// signal: a circle, a diamond, a chipped square, a hexagon, an octagon with its inner ring and a
/// speech bubble. Every path is centred in a box of `2 * radius`.
enum BrainShapes {
    static func path(_ shape: NeuralShape, radius r: CGFloat) -> CGPath {
        let path = CGMutablePath()
        switch shape {
        case .circle:
            path.addEllipse(in: CGRect(x: 0, y: 0, width: r * 2, height: r * 2))
        case .diamond:
            let reach = r * 1.12
            path.move(to: CGPoint(x: r, y: r - reach))
            path.addLine(to: CGPoint(x: r + reach, y: r))
            path.addLine(to: CGPoint(x: r, y: r + reach))
            path.addLine(to: CGPoint(x: r - reach, y: r))
            path.closeSubpath()
        case .chip:
            let a = r * 0.12
            let b = r * 2 - a
            let cut = r * 0.6
            path.move(to: CGPoint(x: a, y: a))
            path.addLine(to: CGPoint(x: b - cut, y: a))
            path.addLine(to: CGPoint(x: b, y: a + cut))
            path.addLine(to: CGPoint(x: b, y: b))
            path.addLine(to: CGPoint(x: a, y: b))
            path.closeSubpath()
        case .hexagon:
            polygon(into: path, sides: 6, radius: r * 1.08, centre: r, turn: -.pi / 2)
        case .octagon:
            polygon(into: path, sides: 8, radius: r * 1.06, centre: r, turn: -.pi / 2 + .pi / 8)
            path.addEllipse(
                in: CGRect(x: r * 0.42, y: r * 0.42, width: r * 1.16, height: r * 1.16))
        case .bubble:
            path.addRoundedRect(
                in: CGRect(x: 0, y: r * 0.1, width: r * 2, height: r * 1.5),
                cornerWidth: r * 0.5, cornerHeight: r * 0.5)
            path.move(to: CGPoint(x: r * 0.4, y: r * 1.55))
            path.addLine(to: CGPoint(x: r * 0.25, y: r * 2))
            path.addLine(to: CGPoint(x: r * 0.9, y: r * 1.55))
            path.closeSubpath()
        }
        return path
    }

    private static func polygon(
        into path: CGMutablePath, sides: Int, radius: CGFloat, centre: CGFloat, turn: CGFloat
    ) {
        for index in 0..<sides {
            let angle = turn + CGFloat(index) * 2 * .pi / CGFloat(sides)
            let point = CGPoint(x: centre + cos(angle) * radius, y: centre + sin(angle) * radius)
            if index == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
    }
}

/// One node of the head: its shape, its number or mark, a ring that breathes while the step runs
/// and beats while it waits on the person, a second ring when it is pinned and a glow for the
/// moment after it fired in a replay.
///
/// A node is a handful of layers laid between the interior and the glass, and it changes only when
/// its draw changes, so a settled turn is drawn once and nothing here touches the display again.
@MainActor
final class BrainNode {
    let layer = CALayer()
    private let halo = CAShapeLayer()
    private let ring = CAShapeLayer()
    private let body = CAShapeLayer()
    private let label = CATextLayer()
    private(set) var draw: NeuralNodeDraw?
    private var drawn: (draw: NeuralNodeDraw, scale: CGFloat, inks: Int, reduce: Bool, fade: Float)?
    private var radius: CGFloat = 10

    init() {
        layer.isOpaque = false
        halo.fillColor = nil
        ring.fillColor = nil
        body.lineJoin = .round
        label.alignmentMode = .center
        label.isWrapped = false
        label.truncationMode = .none
        layer.addSublayer(halo)
        layer.addSublayer(ring)
        layer.addSublayer(body)
        layer.addSublayer(label)
    }

    /// Brings the node to a draw at this size, in these colours, wherever it is. Nothing happens
    /// when it is already so.
    func apply(
        _ next: NeuralNodeDraw, center: CGPoint, scale: CGFloat, inks: BrainInks, backing: CGFloat,
        reduceMotion: Bool, fade: Float = 1
    ) {
        let key = inkKey(inks)
        if let drawn, drawn.draw == next, drawn.scale == scale, drawn.inks == key,
            drawn.reduce == reduceMotion, drawn.fade == fade, layer.position == center
        {
            return
        }
        let motionChanged = draw?.motion != next.motion || drawn?.reduce != reduceMotion
        let sizeChanged = drawn?.scale != scale || draw?.radius != next.radius
        drawn = (next, scale, key, reduceMotion, fade)
        draw = next
        radius = max(3, CGFloat(next.radius) * scale)
        let outer = radius * 1.9
        layer.contentsScale = backing
        layer.position = center
        layer.bounds = CGRect(x: 0, y: 0, width: outer * 2, height: outer * 2)
        let mid = CGPoint(x: outer, y: outer)
        let tone = inks.dome(next.tone, zone: next.zone)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        if sizeChanged || body.path == nil {
            body.bounds = CGRect(x: 0, y: 0, width: radius * 2, height: radius * 2)
            body.path = BrainShapes.path(next.shape, radius: radius)
            halo.bounds = CGRect(x: 0, y: 0, width: radius * 3.4, height: radius * 3.4)
            halo.path = CGPath(
                ellipseIn: CGRect(origin: .zero, size: halo.bounds.size), transform: nil)
            ring.bounds = halo.bounds
            ring.path = ringPath()
            let fontSize = max(7, radius * 0.95)
            label.font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .semibold)
            label.fontSize = fontSize
            label.bounds = CGRect(x: 0, y: 0, width: radius * 2.6, height: fontSize * 1.3)
        }
        for sub in [body, halo, ring] { sub.position = mid }
        label.position = CGPoint(x: outer, y: outer)
        label.contentsScale = backing

        body.fillColor = NSColor.black.withAlphaComponent(0.66).cgColor
        body.strokeColor =
            (next.isRecovered ? tone.withAlphaComponent(0.6) : tone).cgColor
        body.lineWidth = next.isGanglion ? 1.9 : 1.4
        body.lineDashPattern = dashed(next.status) ? [3, 2.4] : nil
        label.string = next.label
        label.foregroundColor = tone.cgColor

        halo.strokeColor = tone.withAlphaComponent(0.6).cgColor
        halo.lineWidth = 1.2
        halo.isHidden = !(next.motion != .still || next.hot)
        ring.strokeColor = tone.cgColor
        ring.lineWidth = 1.6
        ring.isHidden = !next.pinned

        var alpha = Float(max(0.0, min(1.0, Double(next.lit))))
        if next.dimmed { alpha = min(alpha, 0.22) }
        layer.opacity = alpha * fade
        layer.shadowColor = tone.cgColor
        layer.shadowOpacity = next.flash > 0 ? Float(next.flash) * 0.9 : 0
        layer.shadowRadius = radius * 1.1
        layer.shadowOffset = .zero

        if motionChanged || sizeChanged { lay(next.motion, reduceMotion: reduceMotion) }
    }

    private func ringPath() -> CGPath {
        let size = halo.bounds.size
        let inset = size.width * 0.09
        return CGPath(
            ellipseIn: CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset),
            transform: nil)
    }

    private func dashed(_ status: NeuralStatus) -> Bool {
        switch status {
        case .stalled, .stopped: return true
        default: return false
        }
    }

    private func inkKey(_ inks: BrainInks) -> Int {
        var hasher = Hasher()
        hasher.combine(inks.palette.accent)
        hasher.combine(inks.palette.text)
        hasher.combine(inks.palette.warn)
        hasher.combine(inks.palette.danger)
        hasher.combine(inks.palette.isDark)
        return hasher.finalize()
    }

    /// The ring breathes while the step runs and beats twice while it waits, on the render server
    /// at the activity tempo; a step at rest, and every step under reduced motion, holds still.
    private func lay(_ motion: NeuralMotion, reduceMotion: Bool) {
        BrainMotion.breathe(halo, reduceMotion ? .still : motion)
    }

    /// Whether the node's ring is moving, for the harness.
    var isMoving: Bool { BrainMotion.isBreathing(halo) }
}

/// What a node asks of the pointer: the zone and the step it stands for.
struct BrainNodeTarget: Equatable {
    let id: String
    let center: CGPoint
    let radius: CGFloat
}
