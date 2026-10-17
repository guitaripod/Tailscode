import SwiftUI
import TailscodeCore

/// The head the turn has drawn, small enough for a Lock Screen card and the expanded island: the
/// silhouette, a dot for every zone the turn touched sized by how much it did there, a ring where
/// the work is or where it stopped, a second ring where something failed and was never put right,
/// and an eye wearing the card's tone.
///
/// A widget cannot run a clock, so this is one still picture per state, which is also what the
/// activity vocabulary asks of everything settled. The geometry is Core's `NeuralGlyphPlan`, the
/// same plan the notification face draws in UIKit, so the two cannot disagree about a radius; this
/// adds only colour, in the system's own because no theme reaches the Lock Screen.
struct NeuralGlyphView: View {
    let plan: NeuralGlyphPlan
    let width: CGFloat
    var dimmed = false

    @Environment(\.colorScheme) private var scheme

    private var dark: Bool { scheme == .dark }
    private var scale: CGFloat { width / NeuralGlyphGeometry.viewBox.width }
    private var height: CGFloat { CGFloat(NeuralGlyphGeometry.height(forWidth: Double(width))) }

    var body: some View {
        Canvas { context, _ in draw(&context) }
            .frame(width: width, height: height)
            .opacity(dimmed ? 0.4 : 1)
            .accessibilityHidden(true)
    }

    private func point(_ p: NeuralPoint) -> CGPoint {
        CGPoint(
            x: (p.x - NeuralGlyphGeometry.viewBox.x) * scale,
            y: (p.y - NeuralGlyphGeometry.viewBox.y) * scale)
    }

    private func polygon(_ points: [NeuralPoint]) -> Path {
        var path = Path()
        guard let first = points.first else { return path }
        path.move(to: point(first))
        for next in points.dropFirst() { path.addLine(to: point(next)) }
        path.closeSubpath()
        return path
    }

    private func circle(_ center: NeuralPoint, radius: Double) -> Path {
        let c = point(center)
        let r = CGFloat(radius) * scale
        return Path(ellipseIn: CGRect(x: c.x - r, y: c.y - r, width: r * 2, height: r * 2))
    }

    private func draw(_ context: inout GraphicsContext) {
        let outline = polygon(NeuralGlyphGeometry.outline)
        context.fill(outline, with: .color(Color(NeuralGlyphColors.panel(dark: dark))))
        context.stroke(
            outline, with: .color(Color(NeuralGlyphColors.stroke(dark: dark))),
            style: StrokeStyle(lineWidth: max(1.1, width * 0.034), lineJoin: .round))
        let eye = Color(NeuralGlyphColors.eye(plan, dark: dark))
        for dot in plan.dots {
            context.fill(
                circle(dot.center, radius: dot.radius),
                with: .color(Color(NeuralGlyphColors.zone(dot.ink, dark: dark)).opacity(min(dot.opacity, 1))))
            if let ring = dot.activeRing {
                context.stroke(
                    circle(dot.center, radius: ring.radius), with: .color(eye),
                    lineWidth: CGFloat(ring.strokeWidth) * scale)
            }
            if let ring = dot.failureRing {
                context.stroke(
                    circle(dot.center, radius: ring.radius),
                    with: .color(Color(NeuralGlyphColors.danger(dark: dark))),
                    lineWidth: CGFloat(ring.strokeWidth) * scale)
            }
        }
        context.fill(
            circle(NeuralGlyphGeometry.eyeHaloCenter, radius: NeuralGlyphGeometry.eyeHaloRadius),
            with: .color(eye.opacity(NeuralGlyphGeometry.eyeHaloOpacity)))
        context.fill(polygon(NeuralGlyphGeometry.eyeBar), with: .color(eye))
    }
}

private extension Color {
    init(_ rgba: NeuralGlyphColors.RGBA) {
        self.init(.sRGB, red: rgba.red, green: rgba.green, blue: rgba.blue, opacity: rgba.alpha)
    }
}
