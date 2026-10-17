import UIKit

#if !NOTICE_EXTENSION
    import TailscodeCore
#endif

/// The head a turn left, drawn in Core Graphics for the notification's face: the app, the
/// notification service and the long look all draw it from the same `NeuralGlyphPlan`, and the
/// Live Activity's SwiftUI view draws the same plan, so the Lock Screen card and the notice about
/// the same turn wear one head.
///
/// The face is a dark rounded tile tinted by the eye, because the head is a dark object on any
/// canvas and a notification's thumbnail is a file with no way to follow the Lock Screen's light
/// or dark. Nothing here animates; a still head says every state, and a state that waits for the
/// person is the heartbeat's still frame.
enum NoticeHead {
    private static let ground = UIColor(red: 0.063, green: 0.071, blue: 0.082, alpha: 1)

    /// The tile at `side` points: the head over a dark ground that carries a little of the eye's
    /// colour, opaque so it reads over a light or a dark lock screen.
    static func image(for plan: NeuralGlyphPlan, side: CGFloat = 256) -> UIImage {
        let size = CGSize(width: side, height: side)
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            let eye = Self.color(NeuralGlyphColors.eye(plan, dark: true))
            let rect = CGRect(origin: .zero, size: size).insetBy(dx: side * 0.02, dy: side * 0.02)
            let tile = UIBezierPath(roundedRect: rect, cornerRadius: side * 0.225)
            cg.saveGState()
            tile.addClip()
            let colors =
                [Self.blend(ground, eye, 0.30).cgColor, Self.blend(ground, eye, 0.12).cgColor]
                as CFArray
            if let gradient = CGGradient(
                colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])
            {
                cg.drawLinearGradient(
                    gradient, start: CGPoint(x: 0, y: rect.minY), end: CGPoint(x: 0, y: rect.maxY),
                    options: [])
            }
            cg.restoreGState()
            let inner = rect.insetBy(dx: side * 0.006, dy: side * 0.006)
            eye.withAlphaComponent(0.34).setStroke()
            let edge = UIBezierPath(roundedRect: inner, cornerRadius: side * 0.22)
            edge.lineWidth = side * 0.012
            edge.stroke()
            let width = side * 0.8
            let origin = CGPoint(
                x: (side - width) / 2,
                y: (side - CGFloat(NeuralGlyphGeometry.height(forWidth: Double(width)))) / 2
                    + side * 0.01)
            draw(plan, at: origin, width: width, dark: true, in: cg)
        }
    }

    /// The head alone, its top-left corner at `origin`, `width` points across.
    static func draw(
        _ plan: NeuralGlyphPlan, at origin: CGPoint, width: CGFloat, dark: Bool, in cg: CGContext
    ) {
        let scale = width / CGFloat(NeuralGlyphGeometry.viewBox.width)
        func point(_ p: NeuralPoint) -> CGPoint {
            CGPoint(
                x: origin.x + CGFloat(p.x - NeuralGlyphGeometry.viewBox.x) * scale,
                y: origin.y + CGFloat(p.y - NeuralGlyphGeometry.viewBox.y) * scale)
        }
        func polygon(_ points: [NeuralPoint]) -> UIBezierPath {
            let path = UIBezierPath()
            guard let first = points.first else { return path }
            path.move(to: point(first))
            for next in points.dropFirst() { path.addLine(to: point(next)) }
            path.close()
            return path
        }
        func circle(_ center: NeuralPoint, _ radius: Double) -> UIBezierPath {
            let c = point(center)
            let r = CGFloat(radius) * scale
            return UIBezierPath(ovalIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
        }
        cg.saveGState()
        let outline = polygon(NeuralGlyphGeometry.outline)
        color(NeuralGlyphColors.panel(dark: dark)).setFill()
        outline.fill()
        color(NeuralGlyphColors.stroke(dark: dark)).setStroke()
        outline.lineWidth = max(1.1, width * 0.034)
        outline.lineJoinStyle = .round
        outline.stroke()
        let eye = color(NeuralGlyphColors.eye(plan, dark: dark))
        for dot in plan.dots {
            color(NeuralGlyphColors.zone(dot.ink, dark: dark))
                .withAlphaComponent(CGFloat(min(dot.opacity, 1))).setFill()
            circle(dot.center, dot.radius).fill()
            if let ring = dot.activeRing {
                eye.setStroke()
                let path = circle(dot.center, ring.radius)
                path.lineWidth = CGFloat(ring.strokeWidth) * scale
                path.stroke()
            }
            if let ring = dot.failureRing {
                color(NeuralGlyphColors.danger(dark: dark)).setStroke()
                let path = circle(dot.center, ring.radius)
                path.lineWidth = CGFloat(ring.strokeWidth) * scale
                path.stroke()
            }
        }
        eye.withAlphaComponent(CGFloat(NeuralGlyphGeometry.eyeHaloOpacity)).setFill()
        circle(NeuralGlyphGeometry.eyeHaloCenter, NeuralGlyphGeometry.eyeHaloRadius).fill()
        eye.setFill()
        polygon(NeuralGlyphGeometry.eyeBar).fill()
        cg.restoreGState()
    }

    private static func color(_ rgba: NeuralGlyphColors.RGBA) -> UIColor {
        UIColor(red: rgba.red, green: rgba.green, blue: rgba.blue, alpha: rgba.alpha)
    }

    private static func blend(_ base: UIColor, _ tint: UIColor, _ amount: CGFloat) -> UIColor {
        var a: (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        var b: (CGFloat, CGFloat, CGFloat, CGFloat) = (0, 0, 0, 0)
        base.getRed(&a.0, green: &a.1, blue: &a.2, alpha: &a.3)
        tint.getRed(&b.0, green: &b.1, blue: &b.2, alpha: &b.3)
        return UIColor(
            red: a.0 * (1 - amount) + b.0 * amount, green: a.1 * (1 - amount) + b.1 * amount,
            blue: a.2 * (1 - amount) + b.2 * amount, alpha: 1)
    }
}
