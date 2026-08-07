import TailscodeCore
import UIKit

/// The control that decides how hard the phone hits. It is a slider you feel rather than read:
/// every step you drag through plays at the strength under your thumb, so the setting is chosen
/// by sensation and the number is only there to confirm it.
///
/// The glass is not decoration here — the track swells and the thumb lenses under the finger, so
/// the control answers a drag physically as well as haptically.
@MainActor
final class HapticStrengthSlider: UIControl {
    private enum Metrics {
        static let restingTrack: CGFloat = 40
        static let activeTrack: CGFloat = 52
        static let thumb: CGFloat = 34
        static let height: CGFloat = 56
        static let fillInset: CGFloat = 4
    }

    private let container: UIView
    private let track = Theme.Glass.view(interactive: true)
    private let fill = UIView()
    private let gradient = CAGradientLayer()
    private let thumb = Theme.Glass.view(interactive: true)

    private var trackHeight = Metrics.restingTrack
    private var lastPreviewStep: Int?

    /// Fired continuously while dragging; `.primaryActionTriggered` marks the end of a drag,
    /// which is when a preference is worth writing.
    private(set) var isDragging = false

    /// Called with the strength each time the control actually plays something, so the screen
    /// can show the same beat the hand is feeling.
    var onPreview: ((Double) -> Void)?

    var value: Double = HapticStrength.standard {
        didSet {
            value = HapticStrength.clamped(value)
            setNeedsLayout()
            updateAccessibility()
        }
    }

    override init(frame: CGRect) {
        if #available(iOS 26.0, *) {
            container = UIVisualEffectView(effect: UIGlassContainerEffect())
        } else {
            container = UIView()
        }
        super.init(frame: frame)
        build()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Metrics.height)
    }

    private func build() {
        container.translatesAutoresizingMaskIntoConstraints = false
        addSubview(container)
        NSLayoutConstraint.activate([
            container.topAnchor.constraint(equalTo: topAnchor),
            container.bottomAnchor.constraint(equalTo: bottomAnchor),
            container.leadingAnchor.constraint(equalTo: leadingAnchor),
            container.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])

        track.clipsToBounds = true
        track.layer.cornerCurve = .continuous
        track.isUserInteractionEnabled = false
        glassHost.addSubview(track)

        gradient.colors = [
            Theme.Color.accent.cgColor, Theme.Color.special.cgColor,
        ]
        gradient.startPoint = CGPoint(x: 0, y: 0.5)
        gradient.endPoint = CGPoint(x: 1, y: 0.5)
        fill.layer.addSublayer(gradient)
        fill.layer.cornerCurve = .continuous
        fill.clipsToBounds = true
        fill.isUserInteractionEnabled = false
        track.contentView.addSubview(fill)

        thumb.clipsToBounds = false
        thumb.layer.cornerCurve = .continuous
        thumb.layer.borderColor = Theme.Color.background.withAlphaComponent(0.9).cgColor
        thumb.layer.borderWidth = 2
        thumb.layer.shadowColor = UIColor.black.cgColor
        thumb.layer.shadowOpacity = 0.28
        thumb.layer.shadowRadius = 9
        thumb.layer.shadowOffset = CGSize(width: 0, height: 3)
        thumb.isUserInteractionEnabled = false
        glassHost.addSubview(thumb)

        isAccessibilityElement = true
        accessibilityTraits = .adjustable
        accessibilityLabel = String(localized: "Haptic strength")
        updateAccessibility()
        applyColors()
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeIdentityTrait.self]) {
            (view: HapticStrengthSlider, _) in view.applyColors()
        }
    }

    /// A `CGColor` is resolved once and stays that colour, so the layers that carry them have to
    /// be repainted by hand when the appearance flips.
    private func applyColors() {
        gradient.colors = [
            Theme.Color.accent.resolvedColor(with: traitCollection).cgColor,
            Theme.Color.special.resolvedColor(with: traitCollection).cgColor,
        ]
        thumb.layer.borderColor =
            Theme.Color.background.resolvedColor(with: traitCollection)
            .withAlphaComponent(0.9).cgColor
    }

    /// Glass merges only between siblings inside a glass container, so the thumb has to live in
    /// the container's own content view to lens into the track instead of floating over it.
    private var glassHost: UIView {
        (container as? UIVisualEffectView)?.contentView ?? container
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let trackFrame = CGRect(
            x: 0, y: (bounds.height - trackHeight) / 2, width: bounds.width, height: trackHeight)
        track.frame = trackFrame
        track.layer.cornerRadius = trackHeight / 2

        let thumbSize = Metrics.thumb + (trackHeight - Metrics.restingTrack) * 0.6
        let travel = bounds.width - thumbSize - Metrics.fillInset * 2
        let centerX = Metrics.fillInset + thumbSize / 2 + travel * CGFloat(value)
        thumb.frame = CGRect(
            x: centerX - thumbSize / 2, y: bounds.midY - thumbSize / 2,
            width: thumbSize, height: thumbSize)
        thumb.layer.cornerRadius = thumbSize / 2
        thumb.layer.shadowPath = UIBezierPath(ovalIn: thumb.bounds).cgPath

        let fillHeight = trackHeight - Metrics.fillInset * 2
        fill.frame = CGRect(
            x: Metrics.fillInset, y: Metrics.fillInset,
            width: max(fillHeight, centerX - Metrics.fillInset), height: fillHeight)
        fill.layer.cornerRadius = fillHeight / 2
        gradient.frame = CGRect(
            x: 0, y: 0, width: max(bounds.width, fill.bounds.width), height: fillHeight)
        fill.alpha = value <= HapticStrength.silence ? 0 : 1
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        isDragging = true
        lastPreviewStep = nil
        swell(to: Metrics.activeTrack)
        apply(touch.location(in: self))
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        apply(touch.location(in: self))
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        if let touch { apply(touch.location(in: self)) }
        finishDrag()
    }

    override func cancelTracking(with event: UIEvent?) {
        finishDrag()
    }

    private func finishDrag() {
        isDragging = false
        swell(to: Metrics.restingTrack)
        HapticEngine.shared.play(.send, strength: value)
        onPreview?(value)
        sendActions(for: .primaryActionTriggered)
    }

    private func apply(_ point: CGPoint) {
        let thumbSize = Metrics.thumb + (trackHeight - Metrics.restingTrack) * 0.6
        let travel = max(1, bounds.width - thumbSize - Metrics.fillInset * 2)
        let fraction = (point.x - Metrics.fillInset - thumbSize / 2) / travel
        let next = HapticStrength.clamped(Double(fraction))
        guard next != value else { return }
        value = next
        previewIfStepped()
        sendActions(for: .valueChanged)
    }

    /// A cue per pixel would be a buzz, not feedback. Twenty stops across the travel is close
    /// enough to feel continuous while still letting each step land as its own tick.
    private func previewIfStepped() {
        let step = Int((value / HapticStrength.step).rounded())
        guard step != lastPreviewStep else { return }
        lastPreviewStep = step
        HapticEngine.shared.play(.step, strength: value)
        onPreview?(value)
    }

    private func swell(to height: CGFloat) {
        trackHeight = height
        setNeedsLayout()
        UIView.animate(
            withDuration: 0.28, delay: 0, usingSpringWithDamping: 0.72, initialSpringVelocity: 0.6
        ) {
            self.layoutIfNeeded()
        }
    }

    private func updateAccessibility() {
        accessibilityValue =
            "\(HapticStrength.percent(value))% · \(HapticStrength.label(value))"
    }

    override func accessibilityIncrement() {
        value = value + HapticStrength.step
        HapticEngine.shared.play(.step, strength: value)
        sendActions(for: .valueChanged)
        sendActions(for: .primaryActionTriggered)
    }

    override func accessibilityDecrement() {
        value = value - HapticStrength.step
        HapticEngine.shared.play(.step, strength: value)
        sendActions(for: .valueChanged)
        sendActions(for: .primaryActionTriggered)
    }
}

/// The hero's answer to a cue: rings that leave the phone's outline at the strength that was
/// just played. It exists so the screen shows what it is doing to someone holding the device
/// where they cannot feel it — a table, a case, an accessibility setting.
@MainActor
final class HapticPulseView: UIView {
    private let icon = UIImageView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        icon.image = UIImage(
            systemName: "iphone.gen3.radiowaves.left.and.right",
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 30, weight: .regular))
        icon.tintColor = Theme.Color.accent
        icon.contentMode = .center
        icon.translatesAutoresizingMaskIntoConstraints = false
        addSubview(icon)
        NSLayoutConstraint.activate([
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        isUserInteractionEnabled = false
        isAccessibilityElement = false
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize { CGSize(width: 96, height: 72) }

    func pulse(strength: Double) {
        guard strength > HapticStrength.silence else {
            icon.tintColor = Theme.Color.secondaryLabel
            return
        }
        icon.tintColor = Theme.Color.accent
        let scale = 1 + 0.16 * CGFloat(strength)
        UIView.animate(withDuration: 0.09, delay: 0, options: [.curveEaseOut]) {
            self.icon.transform = CGAffineTransform(scaleX: scale, y: scale)
        } completion: { _ in
            UIView.animate(withDuration: 0.3, delay: 0, usingSpringWithDamping: 0.5, initialSpringVelocity: 0.8) {
                self.icon.transform = .identity
            }
        }
        for index in 0..<(strength > 0.6 ? 3 : 2) {
            ring(delay: Double(index) * 0.07, strength: strength)
        }
    }

    private func ring(delay: Double, strength: Double) {
        let layer = CAShapeLayer()
        layer.frame = bounds
        layer.path = UIBezierPath(
            ovalIn: CGRect(x: bounds.midX - 17, y: bounds.midY - 17, width: 34, height: 34)
        ).cgPath
        layer.fillColor = UIColor.clear.cgColor
        layer.strokeColor = Theme.Color.accent.withAlphaComponent(0.55).cgColor
        layer.lineWidth = 2
        layer.opacity = 0
        self.layer.addSublayer(layer)

        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 1
        grow.toValue = 1.4 + 1.6 * strength
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.75
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 0.55
        group.beginTime = CACurrentMediaTime() + delay
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.isRemovedOnCompletion = true
        layer.add(group, forKey: "pulse")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.6) { layer.removeFromSuperlayer() }
    }
}
