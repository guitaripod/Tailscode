import AppKit
import TailscodeCore

/// A ring round a node, with the step's number in a small tag: the cursor's is solid with a glow,
/// the previewed step's is dashed. At the head's size the numbers inside the nodes cannot be
/// read, so the tag carries it.
@MainActor
final class BrainRingMark {
    let layer = CALayer()
    private let glow = CAShapeLayer()
    private let ring = CAShapeLayer()
    private let tag = CALayer()
    private let text = CATextLayer()

    init() {
        layer.isHidden = true
        for sub in [glow, ring] {
            sub.fillColor = nil
            layer.addSublayer(sub)
        }
        tag.cornerRadius = 4
        tag.borderWidth = 1
        text.alignmentMode = .center
        text.isWrapped = false
        tag.addSublayer(text)
        layer.addSublayer(tag)
    }

    func hide() { layer.isHidden = true }

    func show(
        at center: CGPoint, nodeRadius: CGFloat, number: Int, solid: Bool, inks: BrainInks,
        scale: CGFloat, alpha: Float, backing: CGFloat
    ) {
        let accent = inks.domeAccent
        let radius = nodeRadius + 7 * scale
        layer.isHidden = false
        layer.opacity = alpha
        layer.position = center
        layer.bounds = .zero
        ring.path = CGPath(
            ellipseIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2), transform: nil)
        ring.strokeColor = accent.withAlphaComponent(0.95).cgColor
        ring.lineWidth = 2.2
        ring.lineDashPattern = solid ? nil : [3, 2.4]
        glow.isHidden = !solid
        glow.path = CGPath(
            ellipseIn: CGRect(x: -radius * 1.5, y: -radius * 1.5, width: radius * 3, height: radius * 3), transform: nil)
        glow.fillColor = accent.withAlphaComponent(0.16).cgColor
        let font = NSFont.monospacedSystemFont(ofSize: 9.5, weight: .bold)
        text.contentsScale = backing
        text.font = font
        text.fontSize = 9.5
        text.foregroundColor = accent.cgColor
        text.string = "\(number)"
        let width = max(15, CGFloat("\(number)".count) * 6 + 8)
        let offset = radius * 0.72 + 2
        tag.frame = CGRect(x: offset, y: -offset - 14, width: width, height: 14)
        tag.backgroundColor = inks.panel.withAlphaComponent(0.92).cgColor
        tag.borderColor = accent.withAlphaComponent(0.95).cgColor
        text.frame = CGRect(x: 0, y: 0.5, width: width, height: 13)
    }
}
