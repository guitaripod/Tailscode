import AppKit
import TailscodeCore

/// The ball a party card wears: a glass sphere in the model's house colour, lit from the upper
/// left, with a rim and a glowing button at its centre. A hollow slot wears the same size of
/// circle as an outline with a plus, so the grid keeps its shape whether or not a model is in it.
///
/// It is a stack of layers rather than a drawing so the glow can be a real shadow and so the whole
/// ball can be lifted and carried by its card without a redraw.
@MainActor
final class PartyBallView: NSView {
    private let body = CAGradientLayer()
    private let rim = CAShapeLayer()
    private let buttonRing = CAShapeLayer()
    private let buttonGlow = CAShapeLayer()
    private let hollowRing = CAShapeLayer()
    private let plus = CAShapeLayer()
    private var hue: NSColor?
    private var isHollow = false
    private var isAway = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.masksToBounds = false
        body.type = .radial
        body.startPoint = CGPoint(x: 0.34, y: 0.7)
        body.endPoint = CGPoint(x: 1.0, y: -0.05)
        body.locations = [0, 0.5, 1]
        rim.fillColor = nil
        rim.lineWidth = 1.5
        buttonRing.fillColor = nil
        buttonRing.lineWidth = 2
        buttonGlow.shadowOffset = .zero
        buttonGlow.shadowOpacity = 0.9
        buttonGlow.shadowRadius = 4
        hollowRing.fillColor = nil
        hollowRing.lineWidth = 1.5
        plus.fillColor = nil
        plus.lineWidth = 1.8
        plus.lineCap = .round
        for sublayer in [body, rim, buttonGlow, buttonRing, hollowRing, plus] {
            layer?.addSublayer(sublayer)
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var isOpaque: Bool { false }

    /// A ball takes the house colour of the model, dimmed when the machine behind it does not
    /// answer. Passing nil draws the hollow slot.
    func show(hue: NSColor?, away: Bool = false) {
        self.hue = hue
        isHollow = hue == nil
        isAway = away
        restyle()
    }

    /// Whether a press at `point` (in this view) lands on the centre button, which steps the level
    /// in edit mode. The target is a little wider than the ring so it is not a pixel hunt.
    func buttonContains(_ point: NSPoint) -> Bool {
        guard !isHollow else { return false }
        let centre = NSPoint(x: bounds.midX, y: bounds.midY)
        let reach = max(buttonDiameter / 2 + 5, bounds.width * 0.3)
        return hypot(point.x - centre.x, point.y - centre.y) <= reach
    }

    private var buttonDiameter: CGFloat { bounds.width * 0.35 }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    override func layout() {
        super.layout()
        let box = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body.frame = box
        body.cornerRadius = box.width / 2
        let rimInset = rim.lineWidth / 2
        rim.path = CGPath(ellipseIn: box.insetBy(dx: rimInset, dy: rimInset), transform: nil)
        let button = CGRect(
            x: box.midX - buttonDiameter / 2, y: box.midY - buttonDiameter / 2,
            width: buttonDiameter, height: buttonDiameter)
        buttonRing.path = CGPath(ellipseIn: button, transform: nil)
        buttonGlow.path = CGPath(ellipseIn: button, transform: nil)
        let hollowInset = hollowRing.lineWidth / 2
        hollowRing.path = CGPath(
            ellipseIn: box.insetBy(dx: hollowInset, dy: hollowInset), transform: nil)
        let arm = box.width * 0.18
        let cross = CGMutablePath()
        cross.move(to: CGPoint(x: box.midX - arm, y: box.midY))
        cross.addLine(to: CGPoint(x: box.midX + arm, y: box.midY))
        cross.move(to: CGPoint(x: box.midX, y: box.midY - arm))
        cross.addLine(to: CGPoint(x: box.midX, y: box.midY + arm))
        plus.path = cross
        CATransaction.commit()
    }

    private func restyle() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body.isHidden = isHollow
        rim.isHidden = isHollow
        buttonRing.isHidden = isHollow
        buttonGlow.isHidden = isHollow
        hollowRing.isHidden = !isHollow
        plus.isHidden = !isHollow
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if let hue {
                let lit = hue.blended(withFraction: 0.55, of: .white) ?? hue
                let deep = hue.blended(withFraction: 0.4, of: .black) ?? hue
                body.colors = [lit.cgColor, hue.cgColor, deep.cgColor]
                body.shadowColor = hue.cgColor
                body.shadowOpacity = isAway ? 0 : 0.32
                body.shadowRadius = 9
                body.shadowOffset = .zero
            }
            rim.strokeColor = NSColor.white.withAlphaComponent(0.5).cgColor
            buttonRing.strokeColor = NSColor.white.withAlphaComponent(0.8).cgColor
            buttonGlow.fillColor = NSColor.white.withAlphaComponent(0.18).cgColor
            buttonGlow.shadowColor = NSColor.white.cgColor
            let hollowInk = MacTheme.Color.tertiaryLabel.cgColor
            hollowRing.strokeColor = hollowInk
            plus.strokeColor = MacTheme.Color.secondaryLabel.cgColor
        }
        CATransaction.commit()
        needsLayout = true
    }
}
