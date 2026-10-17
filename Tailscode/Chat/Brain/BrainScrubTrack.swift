import TailscodeCore
import UIKit

/// The scrubber's track: a thin line in the quiet ink, the elapsed part in the accent, a small
/// tick wherever a step fires and a round thumb with a finger-sized target. It is drawn from the
/// app's tokens rather than by the system slider, whose thumb at the end of the track was wider
/// than everything else in the footer.
///
/// A drag takes the playhead and gives a haptic detent on every tick it passes. For VoiceOver it
/// is adjustable: increment and decrement move to the next and the previous step, and the value
/// reads "step N of M".
@MainActor
final class BrainScrubTrack: UIControl {
    static let trackHeight: CGFloat = 4
    static let thumbDiameter: CGFloat = 14
    static let touchHeight: CGFloat = 44

    var onBegan: (() -> Void)?
    var onMoved: ((Double) -> Void)?
    var onEnded: (() -> Void)?

    private let track = CALayer()
    private let elapsed = CALayer()
    private let ticks = CAShapeLayer()
    private let thumb = CALayer()
    private var fractions: [Double] = []
    private var spoken: ((Double) -> String)?
    private(set) var value: Double = 1
    private var isDragging = false
    private var lastDetent = 1.0

    /// The most ticks drawn; a longer turn is thinned evenly.
    static let tickLimit = 60

    override init(frame: CGRect) {
        super.init(frame: frame)
        track.cornerRadius = Self.trackHeight / 2
        elapsed.cornerRadius = Self.trackHeight / 2
        thumb.cornerRadius = Self.thumbDiameter / 2
        thumb.shadowColor = UIColor.black.cgColor
        thumb.shadowOpacity = 0.25
        thumb.shadowRadius = 2
        thumb.shadowOffset = CGSize(width: 0, height: 1)
        ticks.lineWidth = 1
        [track, elapsed, ticks, thumb].forEach { layer.addSublayer($0) }
        addGestureRecognizer(UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:))))
        isAccessibilityElement = true
        accessibilityTraits = .adjustable
        accessibilityLabel = NeuralReading.scrubLabel
        recolor()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: Self.touchHeight)
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        recolor()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        placeLayers()
    }

    /// Sets the ticks, as fractions along the turn, and how a position is read aloud.
    func configure(ticks new: [Double], spoken read: @escaping (Double) -> String) {
        let thinned: [Double]
        if new.count > Self.tickLimit {
            let stride = Double(new.count) / Double(Self.tickLimit)
            thinned = (0..<Self.tickLimit).map { new[min(new.count - 1, Int(Double($0) * stride))] }
        } else {
            thinned = new
        }
        let changed = thinned != fractions
        fractions = thinned
        spoken = read
        if changed { placeLayers() }
        accessibilityValue = read(value)
    }

    /// Moves the thumb to a position, unless a finger is holding it.
    func set(value new: Double) {
        guard !isDragging else { return }
        value = min(max(new, 0), 1)
        placeLayers()
        accessibilityValue = spoken?(value)
    }

    private var inset: CGFloat { Self.thumbDiameter / 2 + 2 }

    private func recolor() {
        let quiet = Theme.Color.tertiaryLabel.resolvedColor(with: traitCollection)
        track.backgroundColor = quiet.withAlphaComponent(0.35).cgColor
        elapsed.backgroundColor = Theme.Color.accent.resolvedColor(with: traitCollection).cgColor
        thumb.backgroundColor = Theme.Color.accent.resolvedColor(with: traitCollection).cgColor
        ticks.strokeColor = quiet.withAlphaComponent(0.8).cgColor
    }

    private func x(for fraction: Double) -> CGFloat {
        inset + CGFloat(fraction) * max(0, bounds.width - 2 * inset)
    }

    private func placeLayers() {
        guard bounds.width > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let midY = bounds.midY
        let line = CGRect(
            x: inset, y: midY - Self.trackHeight / 2, width: max(0, bounds.width - 2 * inset),
            height: Self.trackHeight)
        track.frame = line
        let reach = x(for: value)
        elapsed.frame = CGRect(x: line.minX, y: line.minY, width: max(0, reach - line.minX), height: line.height)
        let marks = CGMutablePath()
        for fraction in fractions {
            let at = x(for: fraction)
            marks.move(to: CGPoint(x: at, y: midY - 6))
            marks.addLine(to: CGPoint(x: at, y: midY - 3))
        }
        ticks.path = marks
        ticks.frame = bounds
        thumb.bounds = CGRect(x: 0, y: 0, width: Self.thumbDiameter, height: Self.thumbDiameter)
        thumb.position = CGPoint(x: reach, y: midY)
        CATransaction.commit()
    }

    private func fraction(at location: CGPoint) -> Double {
        let width = max(1, bounds.width - 2 * inset)
        return Double(min(max((location.x - inset) / width, 0), 1))
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        isDragging = true
        lastDetent = value
        scaleThumb(1.35)
        onBegan?()
        move(to: fraction(at: touch.location(in: self)))
        return true
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        move(to: fraction(at: touch.location(in: self)))
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        finish()
    }

    override func cancelTracking(with event: UIEvent?) {
        finish()
    }

    private func finish() {
        isDragging = false
        scaleThumb(1)
        onEnded?()
    }

    private func move(to fraction: Double) {
        let passed = fractions.contains { tick in
            (tick > min(lastDetent, fraction) && tick <= max(lastDetent, fraction))
        }
        if passed { Theme.Haptics.step() }
        lastDetent = fraction
        value = fraction
        placeLayers()
        accessibilityValue = spoken?(value)
        onMoved?(value)
    }

    private func scaleThumb(_ scale: CGFloat) {
        let animation = CABasicAnimation(keyPath: "transform.scale")
        animation.fromValue = thumb.presentation()?.value(forKeyPath: "transform.scale") ?? 1
        animation.toValue = scale
        animation.duration = 0.12
        thumb.add(animation, forKey: "scale")
        thumb.transform = CATransform3DMakeScale(scale, scale, 1)
    }

    @objc private func hovered(_ gesture: UIHoverGestureRecognizer) {
        guard !isDragging else { return }
        switch gesture.state {
        case .began, .changed: scaleThumb(1.35)
        default: scaleThumb(1)
        }
    }

    override func accessibilityIncrement() {
        step(by: 1)
    }

    override func accessibilityDecrement() {
        step(by: -1)
    }

    private func step(by direction: Int) {
        let target: Double?
        if direction > 0 {
            target = fractions.first { $0 > value + 0.0005 } ?? 1
        } else {
            target = fractions.last { $0 < value - 0.0005 } ?? 0
        }
        guard let target else { return }
        onBegan?()
        value = target
        placeLayers()
        accessibilityValue = spoken?(value)
        onMoved?(value)
        onEnded?()
    }
}
