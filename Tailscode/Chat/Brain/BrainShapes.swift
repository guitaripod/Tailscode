import TailscodeCore
import UIKit

/// The shapes a zone's nodes are drawn as, centred on the origin, in design units. Circle, diamond,
/// chipped square, hexagon, octagon and speech bubble, so the kind of work is carried by shape
/// before colour: authored in the mock's `shapeD` and kept to its numbers.
enum BrainShapes {
    static func path(_ shape: NeuralShape, radius r: CGFloat) -> CGPath {
        switch shape {
        case .circle:
            return CGPath(
                ellipseIn: CGRect(x: -r, y: -r, width: 2 * r, height: 2 * r), transform: nil)
        case .diamond:
            let k = r * 1.2
            return polygon([CGPoint(x: 0, y: -k), CGPoint(x: k, y: 0), CGPoint(x: 0, y: k), CGPoint(x: -k, y: 0)])
        case .chip:
            let k = r * 0.9
            let c = r * 0.42
            return polygon([
                CGPoint(x: -k, y: -k), CGPoint(x: k - c, y: -k), CGPoint(x: k, y: -k + c),
                CGPoint(x: k, y: k), CGPoint(x: -k + c, y: k), CGPoint(x: -k, y: k - c),
            ])
        case .hexagon:
            let k = r * 1.12
            return polygon((0..<6).map { index in
                let angle = CGFloat.pi / 3 * CGFloat(index)
                return CGPoint(x: cos(angle) * k, y: sin(angle) * k)
            })
        case .octagon:
            let k = r * 1.12
            return polygon((0..<8).map { index in
                let angle = CGFloat.pi / 4 * CGFloat(index) + CGFloat.pi / 8
                return CGPoint(x: cos(angle) * k, y: sin(angle) * k)
            })
        case .bubble:
            return bubble(radius: r)
        }
    }

    private static func polygon(_ points: [CGPoint]) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: points)
        path.closeSubpath()
        return path
    }

    private static func bubble(radius r: CGFloat) -> CGPath {
        let w = r * 1.3
        let h = r * 0.95
        let c = r * 0.5
        let path = CGMutablePath()
        path.move(to: CGPoint(x: -w + c, y: -h))
        path.addLine(to: CGPoint(x: w - c, y: -h))
        path.addQuadCurve(to: CGPoint(x: w, y: -h + c), control: CGPoint(x: w, y: -h))
        path.addLine(to: CGPoint(x: w, y: h - c))
        path.addQuadCurve(to: CGPoint(x: w - c, y: h), control: CGPoint(x: w, y: h))
        path.addLine(to: CGPoint(x: -w * 0.15, y: h))
        path.addLine(to: CGPoint(x: -w * 0.55, y: h + r * 0.65))
        path.addLine(to: CGPoint(x: -w * 0.5, y: h))
        path.addLine(to: CGPoint(x: -w + c, y: h))
        path.addQuadCurve(to: CGPoint(x: -w, y: h - c), control: CGPoint(x: -w, y: h))
        path.addLine(to: CGPoint(x: -w, y: -h + c))
        path.addQuadCurve(to: CGPoint(x: -w + c, y: -h), control: CGPoint(x: -w, y: -h))
        path.closeSubpath()
        return path
    }

    /// The path of a polyline of design points, the way a wire is stroked.
    static func polyline(_ points: [NeuralPoint]) -> CGPath {
        let path = CGMutablePath()
        guard let first = points.first else { return path }
        path.move(to: CGPoint(x: first.x, y: first.y))
        for point in points.dropFirst() { path.addLine(to: CGPoint(x: point.x, y: point.y)) }
        return path
    }

    /// The arcs of a tie, each a quadratic from one step to the next.
    static func arcs(_ arcs: [NeuralLayout.TieArc]) -> CGPath {
        let path = CGMutablePath()
        for arc in arcs {
            path.move(to: CGPoint(x: arc.from.x, y: arc.from.y))
            path.addQuadCurve(
                to: CGPoint(x: arc.to.x, y: arc.to.y),
                control: CGPoint(x: arc.control.x, y: arc.control.y))
        }
        return path
    }
}
