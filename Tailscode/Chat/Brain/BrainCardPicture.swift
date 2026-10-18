import TailscodeCore
import UIKit

/// The picture on a card: the head at rest, shared by every card in the same look, with the lights
/// this turn lit in it and the rings where it failed. A running turn's card wears the live head
/// instead, two real frames of the swell cross-faded by an animation the render server runs, so
/// the active zone breathes at the app's tempo and costs the app nothing between events.
@MainActor
final class BrainCardPicture: UIView {
    private let clip = CALayer()
    private let base = CALayer()
    private let floorLayer = CALayer()
    private let peakLayer = CALayer()
    private let lights = BrainLightsLayer()
    private var card: NeuralBrainCard?
    private var ink: BrainInk?
    private var hovered = false
    private var liveStrength: CGFloat = 1
    private var swell: NeuralMotion = .still
    private var swelling = false

    private(set) var hasRest = false
    private(set) var hasLive = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        clip.masksToBounds = true
        clip.cornerRadius = 8
        clip.cornerCurve = .continuous
        layer.addSublayer(clip)
        for layer in [base, floorLayer, peakLayer] {
            layer.contentsRect = BrainPicture.cropRect
            layer.contentsGravity = .resize
            layer.minificationFilter = .trilinear
            layer.magnificationFilter = .linear
            layer.opacity = 0
            clip.addSublayer(layer)
        }
        clip.addSublayer(lights)
        isAccessibilityElement = false
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        clip.frame = bounds
        for layer in [base, floorLayer, peakLayer] { layer.frame = bounds }
        lights.layout(in: bounds)
        CATransaction.commit()
    }

    /// The scale the layers' images are drawn at.
    var pixelScale: CGFloat { window?.windowScene?.screen.scale ?? traitCollection.displayScale }

    func setRest(_ picture: BrainPicture?, animated: Bool) {
        hasRest = picture != nil
        guard let picture else {
            base.contents = nil
            base.opacity = 0
            return
        }
        base.contents = picture.image
        if animated, !UIAccessibility.isReduceMotionEnabled, base.opacity == 0 {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 0
            fade.toValue = 1
            fade.duration = 0.16
            base.add(fade, forKey: "arrive")
        }
        base.opacity = Float(restAlpha)
    }

    /// How visible the rest picture is: all of it for a settled card, and the share the live head
    /// has given up while a card settles.
    private var restAlpha: CGFloat = 1 {
        didSet { base.opacity = hasRest ? Float(restAlpha) : 0 }
    }

    func setLive(floor: BrainPicture?, peak: BrainPicture?) {
        hasLive = floor != nil
        floorLayer.contents = floor?.image
        peakLayer.contents = (peak ?? floor)?.image
        applyLive()
    }

    func setSwell(_ motion: NeuralMotion) {
        guard motion != swell || !swelling else { return }
        swell = motion
        applyLive()
    }

    /// The share of the live head still showing: one while the turn runs, falling to nothing as
    /// the card settles, while the rest picture takes its place.
    func setLiveShare(_ share: CGFloat) {
        liveStrength = share
        applyLive()
        restAlpha = hasLive && share > 0.001 ? max(0, 1 - share) : 1
        if !hasLive { restAlpha = 1 }
    }

    private func applyLive() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard hasLive, liveStrength > 0.001 else {
            floorLayer.opacity = 0
            peakLayer.opacity = 0
            peakLayer.removeAnimation(forKey: "swell")
            swelling = false
            return
        }
        floorLayer.opacity = Float(liveStrength)
        let animated = swell.isAnimated && !UIAccessibility.isReduceMotionEnabled
        if animated {
            if !swelling || peakLayer.animation(forKey: "swell") == nil {
                if let animation = BrainSwell.opacity(for: swell) {
                    peakLayer.setRepeatingMotion(
                        animation, forKey: "swell", meaning: swell == .heartbeat ? .attention : .working)
                }
                swelling = true
            }
            peakLayer.opacity = Float(liveStrength)
        } else {
            peakLayer.removeAnimation(forKey: "swell")
            swelling = false
            peakLayer.opacity = 0
        }
    }

    func configure(card new: NeuralBrainCard, ink newInk: BrainInk, hovered isHovered: Bool) {
        card = new
        ink = newInk
        hovered = isHovered
        lights.configure(card: new, ink: newInk, hovered: isHovered)
        lights.layout(in: bounds)
    }

    func setHovered(_ value: Bool) {
        guard hovered != value else { return }
        hovered = value
        lights.setHovered(value)
    }

    /// The lights ease from the strengths a running turn had to the settled ones.
    func setLightsLift(_ lift: CGFloat) {
        lights.opacity = Float(lift)
    }

    /// While the card is a move's starting or landing place: the picture itself is the traveller,
    /// and only the lights stay.
    func setMoving(imageAlpha: CGFloat, lightsAlpha: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        movingAlpha = imageAlpha
        base.opacity = hasRest ? Float(restAlpha * imageAlpha) : 0
        floorLayer.opacity = hasLive ? Float(liveStrength * imageAlpha) : 0
        peakLayer.opacity = hasLive && swelling ? Float(liveStrength * imageAlpha) : 0
        lights.opacity = Float(lightsAlpha)
        CATransaction.commit()
    }

    private var movingAlpha: CGFloat = 1
}

/// The soft lights a turn lit in the head, one per zone it used, and the rings where it failed: the
/// same drawing on the card's picture and, while a card opens, on the head that travels.
@MainActor
final class BrainLightsLayer: CALayer {
    private var lightLayers: [CAGradientLayer] = []
    private var ringLayers: [CAShapeLayer] = []
    private var card: NeuralBrainCard?
    private var hovered = false

    func configure(card new: NeuralBrainCard, ink: BrainInk, hovered isHovered: Bool) {
        card = new
        hovered = isHovered
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        while lightLayers.count < new.lights.count {
            let made = CAGradientLayer()
            made.type = .radial
            made.startPoint = CGPoint(x: 0.5, y: 0.5)
            made.endPoint = CGPoint(x: 1, y: 1)
            made.locations = [0, 0.55, 1]
            addSublayer(made)
            lightLayers.append(made)
            let ring = CAShapeLayer()
            ring.fillColor = nil
            addSublayer(ring)
            ringLayers.append(ring)
        }
        for index in lightLayers.indices {
            let visible = index < new.lights.count
            lightLayers[index].isHidden = !visible
            ringLayers[index].isHidden = !visible
            guard visible else { continue }
            let light = new.lights[index]
            let tone = ink.zone(light.zone)
            lightLayers[index].colors = [
                tone.withAlphaComponent(1).cgColor, tone.withAlphaComponent(0.45).cgColor,
                tone.withAlphaComponent(0).cgColor,
            ]
            switch light.ringStyle {
            case .none: ringLayers[index].isHidden = true
            case .repairedDashed: ringLayers[index].strokeColor = ink.attention.cgColor
            case .failedSolid: ringLayers[index].strokeColor = ink.danger.cgColor
            }
        }
        applyStrengths()
    }

    func setHovered(_ value: Bool) {
        hovered = value
        applyStrengths()
    }

    /// Places every light for a picture of this rect: the head's trimmed bounds fill it.
    func layout(in rect: CGRect) {
        guard let card, rect.width > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        frame = rect
        let crop = NeuralStageMetrics.designCrop
        let sx = rect.width / CGFloat(crop.width)
        let sy = rect.height / CGFloat(crop.height)
        for (index, light) in card.lights.enumerated() where index < lightLayers.count {
            let center = CGPoint(
                x: (CGFloat(light.center.x) - CGFloat(crop.x)) * sx,
                y: (CGFloat(light.center.y) - CGFloat(crop.y)) * sy)
            let radius = CGFloat(light.radius) * sx
            lightLayers[index].frame = CGRect(
                x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)
            let ring = ringLayers[index]
            guard let spec = light.ring, light.ringStyle != .none else {
                ring.isHidden = true
                continue
            }
            ring.isHidden = false
            let r = CGFloat(spec.radius) * sx
            ring.frame = CGRect(origin: .zero, size: rect.size)
            ring.path = CGPath(
                ellipseIn: CGRect(x: center.x - r, y: center.y - r, width: r * 2, height: r * 2),
                transform: nil)
            ring.lineWidth = max(1.2, CGFloat(spec.strokeWidth) * sx)
            ring.lineDashPattern =
                light.ringStyle == .repairedDashed
                ? [NSNumber(value: Double(26 * sx)), NSNumber(value: Double(18 * sx))] : nil
        }
    }

    private func applyStrengths() {
        guard let card else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        for (index, light) in card.lights.enumerated() where index < lightLayers.count {
            let strength = CGFloat(light.strength(hovered: hovered))
            lightLayers[index].opacity = Float(strength * (card.live != nil ? 0.75 : 1))
            ringLayers[index].opacity = hovered ? 1 : 0.9
        }
    }
}

/// The two swells a mark knows as keyframes the render server runs, sampled from `NeuralMotion`
/// so the card, the nodes and every badge in the app are at the same point of their cycle.
@MainActor
enum BrainSwell {
    private static var cache: [String: CAKeyframeAnimation] = [:]

    /// An opacity animation from nothing to full along the motion's own wave: the share of the
    /// peak head laid over the floor head.
    static func opacity(for motion: NeuralMotion) -> CAKeyframeAnimation? {
        let name: String
        let period: TimeInterval
        let floor: Double
        switch motion {
        case .breath:
            name = "breath"
            period = ActivityTuning.breathPeriod
            floor = ActivityTuning.breathFloor
        case .heartbeat:
            name = "heartbeat"
            period = ActivityTuning.heartbeatPeriod
            floor = ActivityTuning.heartbeatFloor
        case .sweep, .still:
            return nil
        }
        if let held = cache[name], let copy = held.copy() as? CAKeyframeAnimation { return copy }
        let segments = 96
        var values: [NSNumber] = []
        for index in 0...segments {
            let level = motion.level(at: Double(index) / Double(segments) * period)
            values.append(NSNumber(value: max(0, min(1, (level - floor) / max(0.0001, 1 - floor)))))
        }
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = values
        animation.calculationMode = .linear
        animation.duration = period
        animation.repeatCount = .infinity
        cache[name] = animation
        return animation.copy() as? CAKeyframeAnimation
    }

    /// The whole swell as opacity between its floor and one, for an edge or a dot.
    static func level(for motion: NeuralMotion) -> CAKeyframeAnimation? {
        let name: String
        let period: TimeInterval
        switch motion {
        case .breath:
            name = "level-breath"
            period = ActivityTuning.breathPeriod
        case .heartbeat:
            name = "level-heartbeat"
            period = ActivityTuning.heartbeatPeriod
        case .sweep, .still:
            return nil
        }
        if let held = cache[name], let copy = held.copy() as? CAKeyframeAnimation { return copy }
        let segments = 96
        var values: [NSNumber] = []
        for index in 0...segments {
            values.append(
                NSNumber(value: motion.level(at: Double(index) / Double(segments) * period)))
        }
        let animation = CAKeyframeAnimation(keyPath: "opacity")
        animation.values = values
        animation.calculationMode = .linear
        animation.duration = period
        animation.repeatCount = .infinity
        cache[name] = animation
        return animation.copy() as? CAKeyframeAnimation
    }
}
