import TailscodeCore
import UIKit

/// The head as the 28 pt mark a collapsed turn wears in place of a status dot: the silhouette, a
/// disc in every zone that did work, grown by how much it did, a ring where a failure stayed
/// unanswered and where the work is now, and the eye, which wears the state's tone or, once a turn
/// has ended well, who answered.
///
/// All of it is `NeuralGlyph`'s data drawn with shape layers, so the Live Activity, the
/// notification and this row cannot draw different heads. The zone that is working breathes by the
/// same animation every badge in the app uses; nothing else moves, and a settled glyph runs no
/// clock at all.
@MainActor
final class BrainGlyphView: UIView {
    static let width: CGFloat = 28

    static var height: CGFloat { CGFloat(NeuralGlyph.height(forWidth: Double(width))) }

    private let canvas = CALayer()
    private let silhouette = CAShapeLayer()
    private let eye = CAShapeLayer()
    private let halo = CAShapeLayer()
    private var dots: [CAShapeLayer] = []
    private var rings: [CAShapeLayer] = []
    private var glyph: NeuralGlyph?
    private var face = NeuralFace.unknown

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        let box = NeuralGlyph.viewBox
        let scale = Self.width / CGFloat(box.width)
        canvas.anchorPoint = .zero
        canvas.position = .zero
        canvas.bounds = CGRect(x: 0, y: 0, width: box.width, height: box.height)
        canvas.sublayerTransform = CATransform3DConcat(
            CATransform3DMakeTranslation(-CGFloat(box.x), -CGFloat(box.y), 0),
            CATransform3DMakeScale(scale, scale, 1))
        silhouette.path = Self.outlinePath()
        silhouette.lineWidth = 1.7 / scale
        silhouette.lineJoin = .round
        canvas.addSublayer(silhouette)
        halo.path = CGPath(
            ellipseIn: CGRect(
                x: -NeuralGlyph.eyeHalo.radius, y: -NeuralGlyph.eyeHalo.radius,
                width: 2 * NeuralGlyph.eyeHalo.radius, height: 2 * NeuralGlyph.eyeHalo.radius),
            transform: nil)
        halo.position = CGPoint(x: NeuralGlyph.eyeHalo.center.x, y: NeuralGlyph.eyeHalo.center.y)
        canvas.addSublayer(halo)
        eye.path = Self.polygon(NeuralGlyph.eyeBar)
        canvas.addSublayer(eye)
        layer.addSublayer(canvas)
        isAccessibilityElement = false
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize { CGSize(width: Self.width, height: Self.height) }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        guard let glyph else { return }
        show(glyph, face: face)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil, let glyph else { return }
        for (index, dot) in glyph.dots.enumerated() where dot.isLive && index < dots.count {
            dots[index].setActivityMotion(.working)
        }
    }

    /// Draws a glyph. Layers are reused when the zones are the same, so a turn that streams a step
    /// per second changes colours and radii and rebuilds nothing.
    func show(_ new: NeuralGlyph, face newFace: NeuralFace) {
        glyph = new
        face = newFace
        let ink = BrainInk(palette: BrainPalette.palette(for: traitCollection), face: newFace)
        let outline = Theme.Color.label.resolvedColor(with: traitCollection)
        silhouette.fillColor =
            Theme.Color.secondaryBackground.resolvedColor(with: traitCollection).cgColor
        silhouette.strokeColor = outline.withAlphaComponent(0.88).cgColor
        let eyeColor = eyeColor(for: new.eyeTone, ink: ink)
        eye.fillColor = eyeColor.cgColor
        halo.fillColor = eyeColor.cgColor
        halo.opacity = Float(NeuralGlyph.eyeHalo.opacity)
        layoutDots(new)
    }

    private func layoutDots(_ new: NeuralGlyph) {
        for layer in dots + rings { layer.removeFromSuperlayer() }
        dots = []
        rings = []
        for dot in new.dots {
            let disc = CAShapeLayer()
            disc.path = Self.circle(radius: dot.radius)
            disc.position = CGPoint(x: dot.center.x, y: dot.center.y)
            disc.fillColor = zoneColor(dot.zone).cgColor
            disc.opacity = Float(dot.opacity)
            canvas.insertSublayer(disc, below: halo)
            dots.append(disc)
            if let ring = dot.activeRing {
                rings.append(addRing(dot, ring, color: Theme.Color.accent))
            }
            if let ring = dot.failureRing {
                rings.append(addRing(dot, ring, color: Theme.Color.danger))
            }
            if dot.isLive, window != nil { disc.setActivityMotion(.working) }
        }
    }

    private func addRing(_ dot: NeuralGlyph.Dot, _ ring: NeuralGlyph.Ring, color: UIColor)
        -> CAShapeLayer
    {
        let layer = CAShapeLayer()
        layer.path = Self.circle(radius: ring.radius)
        layer.position = CGPoint(x: dot.center.x, y: dot.center.y)
        layer.fillColor = nil
        layer.lineWidth = ring.strokeWidth
        layer.strokeColor = color.resolvedColor(with: traitCollection).cgColor
        canvas.insertSublayer(layer, below: halo)
        return layer
    }

    private func zoneColor(_ zone: NeuralZone) -> UIColor {
        let color: UIColor
        switch zone {
        case .think: color = Theme.Color.label
        case .sense: color = Theme.Color.info
        case .act: color = Theme.Color.accent
        case .shell: color = Theme.Color.special
        case .delegate: color = Theme.Color.secondaryLabel
        case .say:
            color = Theme.Color.accent.resolvedColor(with: traitCollection).mixed(
                with: Theme.Color.info.resolvedColor(with: traitCollection), 0.45)
        }
        return color.resolvedColor(with: traitCollection)
    }

    private func eyeColor(for tone: NeuralTone, ink: BrainInk) -> UIColor {
        switch tone {
        case .live: return Theme.Color.success.resolvedColor(with: traitCollection)
        case .attention: return Theme.Color.warning.resolvedColor(with: traitCollection)
        case .danger: return Theme.Color.danger.resolvedColor(with: traitCollection)
        case .quiet: return Theme.Color.tertiaryLabel.resolvedColor(with: traitCollection)
        case .identity: return ink.identity
        }
    }

    private static func circle(radius: Double) -> CGPath {
        CGPath(
            ellipseIn: CGRect(x: -radius, y: -radius, width: 2 * radius, height: 2 * radius),
            transform: nil)
    }

    private static func polygon(_ points: [NeuralPoint]) -> CGPath {
        let path = CGMutablePath()
        path.addLines(between: points.map { CGPoint(x: $0.x, y: $0.y) })
        path.closeSubpath()
        return path
    }

    private static func outlinePath() -> CGPath { polygon(NeuralGlyph.outline) }
}
