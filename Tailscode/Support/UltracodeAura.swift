import TailscodeCore
import UIKit

/// The visible half of ultracode: a slowly turning rainbow ring around a
/// composer, on only while the power is — the tier picked, the word in the
/// draft, or a summoned turn still running. One soft ring underneath gives the
/// glow, one crisp ring on top draws the line; both are strokes of the same
/// rounded rect, masked over a shared conic gradient of
/// ``Ultracode/rainbowStops`` so the effect reads as light, not paint.
@MainActor
final class UltracodeAura {
    private weak var host: UIView?
    private let cornerRadius: CGFloat
    private let container = CALayer()
    private let gradient = CAGradientLayer()
    private let ringMask = CAShapeLayer()
    private let glowMask = CAShapeLayer()
    private let maskParent = CALayer()
    private(set) var isActive = false

    init(around host: UIView, cornerRadius: CGFloat) {
        self.host = host
        self.cornerRadius = cornerRadius
        gradient.type = .conic
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        gradient.colors = Ultracode.rainbowStops.map {
            UIColor(
                red: CGFloat($0.red), green: CGFloat($0.green), blue: CGFloat($0.blue), alpha: 1
            ).cgColor
        }
        ringMask.fillColor = nil
        ringMask.strokeColor = UIColor.white.cgColor
        ringMask.lineWidth = 2.5
        glowMask.fillColor = nil
        glowMask.strokeColor = UIColor.white.withAlphaComponent(0.4).cgColor
        glowMask.lineWidth = 7
        maskParent.addSublayer(glowMask)
        maskParent.addSublayer(ringMask)
        container.addSublayer(gradient)
        container.mask = maskParent
        container.opacity = 0
        host.layer.addSublayer(container)
        layout()
    }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        guard let host else { return }
        if active {
            layout()
            spin()
            breathe()
            host.layer.shadowColor = UIColor.systemPurple.cgColor
            host.layer.shadowOpacity = 0.25
            host.layer.shadowRadius = 14
            host.layer.shadowOffset = .zero
        } else {
            gradient.removeAllAnimations()
            container.removeAllAnimations()
            host.layer.shadowOpacity = 0
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = container.presentation()?.opacity ?? container.opacity
        fade.toValue = active ? 1 : 0
        fade.duration = 0.35
        container.opacity = active ? 1 : 0
        container.add(fade, forKey: "fade")
    }

    /// Re-fits the ring to the host; call whenever the host lays out. The
    /// gradient stays a centered square larger than the diagonal so its
    /// rotation never uncovers a corner.
    func layout() {
        guard let host, host.bounds.width > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let bounds = host.bounds
        container.frame = bounds
        maskParent.frame = bounds
        let side = sqrt(bounds.width * bounds.width + bounds.height * bounds.height) + 8
        gradient.bounds = CGRect(x: 0, y: 0, width: side, height: side)
        gradient.position = CGPoint(x: bounds.midX, y: bounds.midY)
        let path = UIBezierPath(
            roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerRadius: cornerRadius - 1
        ).cgPath
        ringMask.frame = bounds
        ringMask.path = path
        glowMask.frame = bounds
        glowMask.path = path
        CATransaction.commit()
    }

    private func spin() {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        turn.toValue = 2 * Double.pi
        turn.duration = 4
        turn.repeatCount = .infinity
        gradient.add(turn, forKey: "spin")
    }

    private func breathe() {
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = 0.72
        pulse.duration = 1.6
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        container.add(pulse, forKey: "breathe")
    }
}
