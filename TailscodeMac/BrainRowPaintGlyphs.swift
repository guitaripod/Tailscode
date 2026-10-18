import AppKit
import TailscodeCore

/// The small shapes a row and a chip are made of, stroked by hand in the view's own flipped
/// coordinates: a zone's shape, the quote a said row wears, the cross of a failure, the marks of a
/// verdict. None of them keeps state, so a row costs nothing to draw twice.
@MainActor
enum BrainRowGlyphs {
    /// A zone's shape, stroked in `color`, the shape filling about 13 points of an 18 point box.
    static func zone(_ zone: NeuralZone, at centre: CGPoint, color: NSColor, radius: CGFloat = 6.5) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        context.saveGState()
        context.translateBy(x: centre.x - radius, y: centre.y - radius)
        context.addPath(BrainShapes.path(zone.shape, radius: radius))
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(1.5)
        context.setLineJoin(.round)
        context.strokePath()
        context.restoreGState()
    }

    /// The quote a said row and a note wear: two filled commas turned the way an opening double
    /// quote is.
    static func quote(at centre: CGPoint, color: NSColor) {
        color.setFill()
        color.setStroke()
        for offset in [-4.2, 3.2] as [CGFloat] {
            let x = centre.x + offset
            NSBezierPath(
                ovalIn: CGRect(x: x - 2.6, y: centre.y + 2.2 - 2.6, width: 5.2, height: 5.2)
            ).fill()
            let tail = NSBezierPath()
            tail.lineWidth = 2.2
            tail.lineCapStyle = .round
            tail.move(to: CGPoint(x: x - 2.3, y: centre.y + 1.6))
            tail.curve(
                to: CGPoint(x: x + 0.6, y: centre.y - 5.6),
                controlPoint1: CGPoint(x: x - 2.9, y: centre.y - 2.4),
                controlPoint2: CGPoint(x: x - 1.8, y: centre.y - 4.4))
            tail.stroke()
        }
    }

    static func cross(at centre: CGPoint, size: CGFloat, color: NSColor, width: CGFloat = 1.8) {
        let path = NSBezierPath()
        path.lineWidth = width
        path.lineCapStyle = .round
        path.move(to: CGPoint(x: centre.x - size, y: centre.y - size))
        path.line(to: CGPoint(x: centre.x + size, y: centre.y + size))
        path.move(to: CGPoint(x: centre.x + size, y: centre.y - size))
        path.line(to: CGPoint(x: centre.x - size, y: centre.y + size))
        color.setStroke()
        path.stroke()
    }

    static func magnifier(at origin: CGPoint, color: NSColor) {
        let lens = NSBezierPath(
            ovalIn: CGRect(x: origin.x + 1, y: origin.y - 6, width: 9, height: 9))
        lens.lineWidth = 1.5
        let handle = NSBezierPath()
        handle.lineWidth = 1.5
        handle.lineCapStyle = .round
        handle.move(to: CGPoint(x: origin.x + 9, y: origin.y + 2))
        handle.line(to: CGPoint(x: origin.x + 13, y: origin.y + 6))
        color.setStroke()
        lens.stroke()
        handle.stroke()
    }

    static func verdict(_ verdict: NeuralVerdict.Step, at centre: CGPoint, size: CGFloat, color: NSColor) {
        color.setStroke()
        color.setFill()
        switch verdict {
        case .done: check(at: centre, size: size)
        case .fixed: retryArrow(at: centre, size: size)
        case .failed: cross(at: centre, size: size * 0.3, color: color)
        case .tryingAgain: triangle(at: centre, size: size)
        case .running: dot(at: centre, radius: size * 0.3)
        case .waiting: pauseBars(at: centre, size: size)
        case .stalled: dashedClock(at: centre, size: size)
        case .stopped: stopSquare(at: centre, size: size)
        }
    }

    static func check(at centre: CGPoint, size: CGFloat) {
        let unit = size / 12
        let path = NSBezierPath()
        path.lineWidth = 1.7
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.move(to: CGPoint(x: centre.x - 4.2 * unit, y: centre.y + 0.2 * unit))
        path.line(to: CGPoint(x: centre.x - 1.3 * unit, y: centre.y + 3.2 * unit))
        path.line(to: CGPoint(x: centre.x + 4.4 * unit, y: centre.y - 3.4 * unit))
        path.stroke()
    }

    static func retryArrow(at centre: CGPoint, size: CGFloat) {
        let radius = size * 0.38
        let start = -0.15 * CGFloat.pi
        let end = 1.55 * CGFloat.pi
        let arc = NSBezierPath()
        arc.lineWidth = 1.7
        arc.lineCapStyle = .round
        arc.lineJoinStyle = .round
        let steps = 28
        for index in 0...steps {
            let angle = start + (end - start) * CGFloat(index) / CGFloat(steps)
            let point = CGPoint(x: centre.x + radius * cos(angle), y: centre.y + radius * sin(angle))
            if index == 0 { arc.move(to: point) } else { arc.line(to: point) }
        }
        arc.stroke()
        let tip = CGPoint(x: centre.x + radius * cos(end), y: centre.y + radius * sin(end))
        let head = NSBezierPath()
        head.lineWidth = 1.7
        head.lineCapStyle = .round
        head.lineJoinStyle = .round
        head.move(to: CGPoint(x: tip.x - size * 0.28, y: tip.y - size * 0.22))
        head.line(to: CGPoint(x: tip.x + size * 0.06, y: tip.y + size * 0.02))
        head.line(to: CGPoint(x: tip.x - size * 0.26, y: tip.y + size * 0.26))
        head.stroke()
    }

    static func triangle(at centre: CGPoint, size: CGFloat) {
        let reach = size * 0.42
        let path = NSBezierPath()
        path.lineWidth = 1.5
        path.lineJoinStyle = .round
        path.move(to: CGPoint(x: centre.x, y: centre.y - reach))
        path.line(to: CGPoint(x: centre.x + reach * 1.15, y: centre.y + reach * 0.8))
        path.line(to: CGPoint(x: centre.x - reach * 1.15, y: centre.y + reach * 0.8))
        path.close()
        path.stroke()
        let bar = NSBezierPath()
        bar.lineWidth = 1.5
        bar.lineCapStyle = .round
        bar.move(to: CGPoint(x: centre.x, y: centre.y - reach * 0.25))
        bar.line(to: CGPoint(x: centre.x, y: centre.y + reach * 0.2))
        bar.stroke()
        NSBezierPath(
            ovalIn: CGRect(x: centre.x - 0.6, y: centre.y + reach * 0.52 - 0.6, width: 1.2, height: 1.2)
        ).fill()
    }

    static func dot(at centre: CGPoint, radius: CGFloat) {
        NSBezierPath(
            ovalIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)
        ).fill()
    }

    static func pauseBars(at centre: CGPoint, size: CGFloat) {
        let height = size * 0.7
        let width = max(1.8, size * 0.17)
        for offset in [-size * 0.28, size * 0.28] {
            NSBezierPath(
                roundedRect: CGRect(
                    x: centre.x + offset - width / 2, y: centre.y - height / 2, width: width, height: height),
                xRadius: width / 2, yRadius: width / 2
            ).fill()
        }
    }

    static func dashedClock(at centre: CGPoint, size: CGFloat) {
        let ring = NSBezierPath(
            ovalIn: CGRect(
                x: centre.x - size * 0.42, y: centre.y - size * 0.42, width: size * 0.84, height: size * 0.84))
        ring.lineWidth = 1.4
        ring.lineCapStyle = .round
        ring.setLineDash([1.8, 1.8], count: 2, phase: 0)
        ring.stroke()
        let hands = NSBezierPath()
        hands.lineWidth = 1.4
        hands.lineCapStyle = .round
        hands.move(to: CGPoint(x: centre.x, y: centre.y - size * 0.24))
        hands.line(to: centre)
        hands.line(to: CGPoint(x: centre.x + size * 0.18, y: centre.y + size * 0.1))
        hands.stroke()
    }

    static func stopSquare(at centre: CGPoint, size: CGFloat) {
        let side = size * 0.55
        let path = NSBezierPath(
            roundedRect: CGRect(x: centre.x - side / 2, y: centre.y - side / 2, width: side, height: side),
            xRadius: 1.6, yRadius: 1.6)
        path.lineWidth = 1.5
        path.stroke()
    }
}
