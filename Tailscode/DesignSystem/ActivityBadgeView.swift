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

extension CAFrameRateRange {
    /// The one range everything in this app that keeps moving asks its display for.
    ///
    /// Both the rate and the floor come from `ActivityTuning`, because a client that names its own
    /// is a client that can disagree with the other two desks about how fast a live thing looks
    /// live. It is written once here rather than built at each clock, so a link the app steps by
    /// hand and an animation the render server steps for it cannot end up keeping two tempos.
    static var activityTempo: CAFrameRateRange {
        let rate = Float(ActivityTuning.frameRate)
        return CAFrameRateRange(
            minimum: Float(ActivityTuning.minimumFrameRate), maximum: rate, preferred: rate)
    }
}

extension CADisplayLink {
    /// Pins a clock this client runs by hand to the one tempo every mark in the app moves at.
    ///
    /// A mark's arithmetic reads absolute time, so the compositor is free to hand it fewer frames
    /// under load and it stays in phase — but a link left at the panel's own rate redraws a swell
    /// measured in seconds up to a hundred and twenty times a second for light no eye can tell
    /// apart, and two marks on one screen would keep two different tempos.
    func runAtActivityTempo() {
        preferredFrameRateRange = .activityTempo
    }
}

extension CAAnimation {
    /// Pins motion the render server keeps on this client's behalf to that same tempo.
    ///
    /// A repeating layer animation is handed over once and then drawn at whatever the panel
    /// offers for as long as it lasts, which on this phone is a hundred and twenty frames a second
    /// of a swell measured in seconds — beside marks that are drawing thirty. Only motion that
    /// never ends on its own asks for this: a transition is over before an eye could read a rate
    /// off it, and holding one back would cost it its smoothness and buy nothing.
    func runAtActivityTempo() {
        preferredFrameRateRange = .activityTempo
    }
}

/// The one moving thing a busy surface is allowed: the state's own symbol, breathing, knocking or
/// sweeping the way that state means.
///
/// Frames come from `CADisplayLink`, asked for the vocabulary's own tempo rather than the panel's,
/// and the phase is read from that clock rather than counted, so every badge on screen swells
/// together and one that scrolls back into view arrives already in time with the rest — and a
/// badge that is handed fewer frames under load loses frames, never its place in the swell. It
/// draws at the rate the desks draw at, not the rate this screen could. Nothing here changes a
/// size that layout depends on: the swell is opacity and a transform, both of which the
/// compositor applies without a pass.
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
    ///
    /// A nil `spoken` is a badge the reader's ear never meets, because the row around it already
    /// says the same thing in words: a mark with no sentence would be one more stop on the way
    /// through the card with nothing for VoiceOver to read out there.
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
        isAccessibilityElement = spoken != nil
        accessibilityLabel = spoken
        accessibilityTraits = .updatesFrequently
        motion = icon.motion.honoring(reduceMotion: UIAccessibility.isReduceMotionEnabled)
        resetTransform()
        motion.isAnimated ? start() : stop()
    }

    private func start() {
        guard link == nil, motion.isAnimated, window != nil else { return }
        let link = CADisplayLink(target: self, selector: #selector(step))
        link.runAtActivityTempo()
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
