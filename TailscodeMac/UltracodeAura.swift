import AppKit
import TailscodeCore

/// The visible half of ultracode: a slowly turning rainbow ring around the
/// prompt field, on only while the power is — the tier picked, the word in the
/// draft, or a summoned turn still running. A soft ring underneath gives the
/// glow, a crisp ring on top draws the line; both are strokes of the same
/// rounded rect masked over one conic gradient of ``Ultracode/rainbowStops``,
/// so the effect reads as light, not paint. The host's own border is dimmed
/// while the aura owns the edge and restored when it lets go.
@MainActor
final class UltracodeAura {
    private weak var host: NSView?
    private let cornerRadius: CGFloat
    private let container = CALayer()
    private let gradient = CAGradientLayer()
    private let ringMask = CAShapeLayer()
    private let glowMask = CAShapeLayer()
    private let maskParent = CALayer()
    private var restoredBorderColor: CGColor?
    private(set) var isActive = false

    init(around host: NSView, cornerRadius: CGFloat) {
        self.host = host
        self.cornerRadius = cornerRadius
        host.wantsLayer = true
        gradient.type = .conic
        gradient.startPoint = CGPoint(x: 0.5, y: 0.5)
        gradient.endPoint = CGPoint(x: 0.5, y: 0)
        gradient.colors = Ultracode.rainbowStops.map {
            NSColor(
                red: CGFloat($0.red), green: CGFloat($0.green), blue: CGFloat($0.blue), alpha: 1
            ).cgColor
        }
        ringMask.fillColor = nil
        ringMask.strokeColor = NSColor.white.cgColor
        ringMask.lineWidth = 2
        glowMask.fillColor = nil
        glowMask.strokeColor = NSColor.white.withAlphaComponent(0.4).cgColor
        glowMask.lineWidth = 6
        maskParent.addSublayer(glowMask)
        maskParent.addSublayer(ringMask)
        container.addSublayer(gradient)
        container.mask = maskParent
        container.opacity = 0
        host.layer?.addSublayer(container)
        layout()
    }

    func setActive(_ active: Bool) {
        guard active != isActive else { return }
        isActive = active
        guard let host, let hostLayer = host.layer else { return }
        if active {
            layout()
            spin()
            if restoredBorderColor == nil { restoredBorderColor = hostLayer.borderColor }
            hostLayer.borderColor = NSColor.clear.cgColor
            hostLayer.shadowColor = NSColor.systemPurple.cgColor
            hostLayer.shadowOpacity = 0.3
            hostLayer.shadowRadius = 12
            hostLayer.shadowOffset = .zero
        } else {
            gradient.removeAllAnimations()
            if let restoredBorderColor { hostLayer.borderColor = restoredBorderColor }
            restoredBorderColor = nil
            hostLayer.shadowOpacity = 0
        }
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = container.presentation()?.opacity ?? container.opacity
        fade.toValue = active ? 1 : 0
        fade.duration = 0.35
        container.opacity = active ? 1 : 0
        container.add(fade, forKey: "fade")
    }

    /// Re-fits the ring to the host; call from the host's `layout()`. The
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
        let path = CGPath(
            roundedRect: bounds.insetBy(dx: 1, dy: 1), cornerWidth: cornerRadius - 1,
            cornerHeight: cornerRadius - 1, transform: nil)
        ringMask.frame = bounds
        ringMask.path = path
        glowMask.frame = bounds
        glowMask.path = path
        CATransaction.commit()
    }

    private func spin() {
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        turn.toValue = 2 * Double.pi
        turn.duration = 4
        turn.repeatCount = .infinity
        gradient.add(turn, forKey: "spin")
    }
}
