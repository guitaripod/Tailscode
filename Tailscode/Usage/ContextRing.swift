import UIKit

/// A ring filled to a share, as an image: the chip wears it small before the words, the sheet
/// wears it large with the share inside. One painter for both so they are the same picture.
enum ContextRing {
    static func image(fraction: Double, ink: UIColor, diameter: CGFloat, stroke: CGFloat) -> UIImage {
        let size = CGSize(width: diameter, height: diameter)
        return UIGraphicsImageRenderer(size: size).image { _ in
            let inset = stroke / 2 + 0.5
            let circle = CGRect(origin: .zero, size: size).insetBy(dx: inset, dy: inset)
            let track = UIBezierPath(ovalIn: circle)
            track.lineWidth = stroke
            ink.withAlphaComponent(0.22).setStroke()
            track.stroke()
            let share = min(max(fraction, 0), 1)
            guard share > 0 else { return }
            let start = -CGFloat.pi / 2
            let fill = UIBezierPath(
                arcCenter: CGPoint(x: circle.midX, y: circle.midY), radius: circle.width / 2,
                startAngle: start, endAngle: start + share * 2 * .pi, clockwise: true)
            fill.lineWidth = stroke
            fill.lineCapStyle = .round
            ink.setStroke()
            fill.stroke()
        }.withRenderingMode(.alwaysOriginal)
    }
}

/// The whole window behind the chip's one ring: how much of it the conversation holds, what kind
/// of tokens hold it, what is left, where the number came from, and the one thing to do about it.
///
/// Every number and word is `ContextFill`'s — the same sections the desks draw, in a sheet, because
/// a phone has no band to hang a popover from. This decides only how round the ring is and how wide
