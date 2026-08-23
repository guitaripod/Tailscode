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
final class UltracodeAura: NSObject {
    private weak var host: NSView?
    private let cornerRadius: CGFloat
    private let container = CALayer()
    private let gradient = CAGradientLayer()
    private let ringMask = CAShapeLayer()
    private let glowMask = CAShapeLayer()
    private let maskParent = CALayer()
    private var restoredBorderColor: CGColor?
    private(set) var isActive = false

    /// The two laps this ring keeps while the power is on, for a harness that has to prove they run
    /// at the vocabulary's tempo rather than look at them. Neither ends on its own, and a repeating
    /// animation handed to the render server without a rate is the one kind of motion no picture of
    /// the window can catch running too fast.
    var laps: [CAAnimation] {
        [gradient.animation(forKey: "spin"), container.animation(forKey: "breathe")]
            .compactMap { $0 }
    }

    init(around host: NSView, cornerRadius: CGFloat) {
        self.host = host
        self.cornerRadius = cornerRadius
        super.init()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(motionPreferenceChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
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
            breathe()
            if restoredBorderColor == nil { restoredBorderColor = hostLayer.borderColor }
            hostLayer.borderColor = NSColor.clear.cgColor
            hostLayer.shadowColor = MacTheme.Color.mark.cgColor
            hostLayer.shadowOpacity = 0.3
            hostLayer.shadowRadius = 12
            hostLayer.shadowOffset = .zero
        } else {
            gradient.removeAllAnimations()
            container.removeAnimation(forKey: "breathe")
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

    /// Reads the desk's mind again when it changes while the power is on.
    ///
    /// A tier stays picked for as long as the conversation lasts, so an aura that asked only at the
    /// moment it lit would keep turning for the rest of that conversation under a preference
    /// already changed — and would never start again for a desk that allowed movement back.
    /// Reduced motion keeps the ring lit and stops it moving: a power being on is a fact, and the
    /// fact is the edge rather than the travel around it. An aura whose power is off has no fact to
    /// draw, so it stays dark through the change.
    @objc private func motionPreferenceChanged() {
        guard isActive else { return }
        spin()
        breathe()
    }

    private func spin() {
        let turn = CABasicAnimation(keyPath: "transform.rotation.z")
        turn.fromValue = 0
        turn.toValue = 2 * Double.pi
        turn.duration = Ultracode.auraTurnSeconds
        turn.repeatCount = .infinity
        gradient.setRepeatingMotion(turn, forKey: "spin", meaning: .turning)
    }

    /// The turn says a power is on; the breath says it is still on. Both run on the shared
    /// periods, which are deliberately not multiples of each other — two cycles that divide evenly
    /// lock into a beat, and the aura starts reading as a machine counting rather than light.
    ///
    /// Neither ever ends on its own, which is why both are laid on through `setRepeatingMotion`
    /// rather than by hand. That is the one road in this client where a never-ending lap is pinned
    /// to the vocabulary's tempo — a lap measured in seconds handed to the render server
    /// unqualified is redrawn at whatever the panel offers, which around a pane already breathing
    /// at thirty is a second tempo for the same fact — and it is also where the desk is asked,
    /// every time, whether it wants the movement at all.
    private func breathe() {
        let pulse = CABasicAnimation(keyPath: "opacity")
        pulse.fromValue = 1.0
        pulse.toValue = Ultracode.auraBreathFloor
        pulse.duration = Ultracode.auraBreathSeconds
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        container.setRepeatingMotion(pulse, forKey: "breathe")
    }
}
