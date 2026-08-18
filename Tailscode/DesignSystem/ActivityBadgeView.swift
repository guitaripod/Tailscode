import TailscodeCore
import UIKit

extension ActivityTone {
    /// What a meaning is worth in this app's palette. `success` is the theme's accent under every
    /// theme and system green under none, which is what keeps a live phone row the same colour as
    /// a live row on the desks.
    var color: UIColor {
        switch self {
        case .live: return Theme.Color.success
        case .attention: return Theme.Color.warning
        case .danger: return Theme.Color.danger
        case .quiet: return Theme.Color.tertiaryLabel
        }
    }
}

/// The one moving thing a busy surface is allowed: the state's own symbol, breathing, knocking or
/// sweeping the way that state means.
///
/// Frames come from `CADisplayLink` — the display's own clock, up to 120Hz — and the phase is read
/// from that clock rather than counted, so every badge on screen swells together and one that
/// scrolls back into view arrives already in time with the rest. Nothing here changes a size that
/// layout depends on: the swell is opacity and a transform, both of which the compositor applies
/// without a pass.
///
/// A badge that leaves the window stops its link. A list of forty rows would otherwise keep forty
/// clocks running for the three the reader can see.
@MainActor
final class ActivityBadgeView: UIView {
    private let imageView = UIImageView()
    private var link: CADisplayLink?
    private var motion: ActivityMotion = .still
    private var pointSize: CGFloat

    /// What the badge is about. Setting nil leaves nothing behind — no glyph, no motion, no
    /// accessibility element — because a surface with no activity should read as silent, not as a
    /// badge that happens to be empty.
    var activity: ActivityKind? {
        didSet {
            guard activity != oldValue else { return }
            show(activity?.icon, spoken: activity?.spoken)
        }
    }

    /// For a surface whose state has no name of its own in the vocabulary — a folded run of steps
    /// that is still open, which is not a phase of the turn but is certainly not idle either.
    func show(_ icon: ActivityIcon?, spoken: String?) {
        self.icon = icon
        self.spoken = spoken
        apply()
    }

    private var icon: ActivityIcon?
    private var spoken: String?

    /// Overrides the tone's colour, for a surface that has already spent its palette — the nav
    /// status, where the whole line is one colour and the badge is part of the sentence.
    var overrideColor: UIColor? {
        didSet { imageView.tintColor = overrideColor ?? icon?.tone.color }
    }

    init(pointSize: CGFloat = 11) {
        self.pointSize = pointSize
        super.init(frame: .zero)
        isUserInteractionEnabled = false
        imageView.contentMode = .center
        imageView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: centerYAnchor),
            imageView.widthAnchor.constraint(equalTo: widthAnchor),
            imageView.heightAnchor.constraint(equalTo: heightAnchor),
        ])
        NotificationCenter.default.addObserver(
            self, selector: #selector(apply),
            name: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: CGSize {
        CGSize(width: pointSize + 6, height: pointSize + 6)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        window == nil ? stop() : start()
    }

    /// A cell being recycled must forget the state it was showing, or the next conversation
    /// inherits the last one's badge for a frame — which is exactly the frame a reader glances at.
    func prepareForReuse() {
        activity = nil
        show(nil, spoken: nil)
    }

    @objc private func apply() {
        guard let icon else {
            imageView.image = nil
            isHidden = true
            isAccessibilityElement = false
            motion = .still
            stop()
            resetTransform()
            return
        }
        isHidden = false
        imageView.image = UIImage(
            systemName: icon.symbol,
            withConfiguration: UIImage.SymbolConfiguration(
                pointSize: pointSize, weight: .semibold))
        imageView.tintColor = overrideColor ?? icon.tone.color
        isAccessibilityElement = true
        accessibilityLabel = spoken
        accessibilityTraits = .updatesFrequently
        motion = icon.motion.honoring(reduceMotion: UIAccessibility.isReduceMotionEnabled)
        resetTransform()
        motion.isAnimated ? start() : stop()
    }

    private func start() {
        guard link == nil, motion.isAnimated, window != nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(step))
        let fps = Float(ActivityTuning.frameRate)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 24, maximum: fps, preferred: fps)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func stop() {
        link?.invalidate()
        link = nil
    }

    private func resetTransform() {
        imageView.alpha = 1
        imageView.transform = .identity
    }

    @objc private func step(_ link: CADisplayLink) {
        let time = link.timestamp
        imageView.alpha = motion.intensity(at: time)
        let scale = motion.scale(at: time)
        let rotation = motion.rotation(at: time)
        imageView.transform = CGAffineTransform(rotationAngle: rotation)
            .scaledBy(x: scale, y: scale)
    }
}
