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

    /// The one range everything in this app that *writes* asks its display for, and the one clock
    /// here that is deliberately not the vocabulary's tempo.
    ///
    /// A mark states a fact and thirty frames a second is plenty to state it with. A cascade is a
    /// renderer, putting an answer on screen glyph by glyph under the reader's eye, and text
    /// revealed at thirty reads as a hand that stutters rather than one that writes — so it asks
    /// the panel for everything it has. `ActivityTuning` governs marks, not the cascade. It is
    /// named once here for the same reason the tempo is: the transcript's own reveal and the
    /// preview a reader picks a hand by are the same hand, and a rate typed out at each clock is a
    /// rate each surface chose for itself.
    static var cascadeTempo: CAFrameRateRange {
        CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
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

extension CALayer {
    /// Lays a repeating animation on this layer, or leaves the layer perfectly still when the
    /// reader has asked for less movement. Every motion in this client that never ends on its own
    /// takes this road, and nothing else may add one.
    ///
    /// Motion that never ends is up for exactly as long as the thing it stands for — a wait, a
    /// summarize that runs for minutes, a power that is switched on — which makes it the thing on
    /// the screen a reader ends up watching longest, and so the last place movement may go on
    /// running under a setting that asks for none. A guard read once where the animation is
    /// handed over cannot answer that: nothing takes the movement off again, and a reader who
    /// changes their mind is left watching the thing they turned off. So the decision is one
    /// call, made every time the motion is laid on and again whenever the preference changes.
    ///
    /// What it means is the vocabulary's to say rather than this client's: `meaning` is the
    /// `ActivityMotion` the movement stands for — a wait breathes, something being turned over
    /// sweeps — and `honoring(reduceMotion:)` is where reduced motion is already decided for
    /// every mark in the app, so nothing here can end up disagreeing with the badge in the row
    /// beside it. Reduced motion drops the movement and nothing else: the shape stays exactly
    /// where it is, fully lit, still saying what it was saying.
    ///
    /// The old animation always comes off first, so a cell that returns to the window or a reader
    /// who changes their mind mid-wait lays one swell on rather than a second on top of it.
    @MainActor func setRepeatingMotion(
        _ animation: CAAnimation, forKey key: String, meaning: ActivityMotion = .working
    ) {
        removeAnimation(forKey: key)
        guard meaning.honoring(reduceMotion: UIAccessibility.isReduceMotionEnabled).isAnimated
        else { return }
        animation.runAtActivityTempo()
        add(animation, forKey: key)
    }
}

extension ActivityMotion {
    /// The seconds one cycle of this motion lasts, read from the motion itself so no client ever
    /// types a period of its own; nil for stillness, which has none.
    var period: TimeInterval? {
        switch self {
        case .still: return nil
        case .breath(let pulse), .heartbeat(let pulse): return pulse.period
        case .sweep(let period): return max(0.05, period)
        }
    }

    /// How many keyframes a cycle is sampled at for every frame of the tempo it spans.
    ///
    /// Twice the tempo is enough that the narrowest thing the vocabulary draws, one of a
    /// heartbeat's two knocks, is carried by a dozen keyframes rather than being cut by the
    /// sampling.
    private static let keyframesPerTempoFrame = 2.0

    /// The fewest keyframes a cycle may be sampled at, however short it is.
    private static let minimumKeyframes = 48

    /// How many segments one cycle is cut into.
    private func segments(over period: TimeInterval) -> Int {
        max(Self.minimumKeyframes, Int((ActivityTuning.frameRate * period * Self.keyframesPerTempoFrame).rounded(.up)))
    }

    /// The motion as animation the render server runs, built from exactly the arithmetic the
    /// display-link version stepped by hand: `intensity(at:)` as opacity, `scale(at:)` as
    /// `transform.scale`, `rotation(at:)` as `transform.rotation.z`.
    ///
    /// One group, one cycle long, repeating for ever. A swell is sampled over its own period at
    /// evenly spaced keyframes and joined linearly, with the seam closed on the first sample so
    /// the repeat cannot tick; a sweep is a plain linear turn through a full circle. `lag` is how
    /// far this mark runs behind the common clock, for a row of marks that pass one swell along
    /// (the three dots of a wait): sample `n` reads `time - lag`, the same shift the stepped
    /// version applied to its timestamp.
    ///
    /// The group carries no phase of its own. Laid on a layer through `CALayer.setActivityMotion`
    /// it is begun at media time zero, which is what keeps every mark on screen in step. Nil for
    /// `.still`, which runs nothing.
    func activityAnimation(lag: TimeInterval = 0) -> CAAnimationGroup? {
        guard let period else { return nil }
        let count = segments(over: period)
        var animations: [CAAnimation] = []
        switch self {
        case .still:
            return nil
        case .breath:
            animations.append(
                keyframes("opacity", period: period, count: count, lag: lag) { intensity(at: $0) })
            animations.append(
                keyframes("transform.scale", period: period, count: count, lag: lag) { scale(at: $0) })
        case .heartbeat:
            animations.append(
                keyframes("opacity", period: period, count: count, lag: lag) { intensity(at: $0) })
        case .sweep:
            let from = rotation(at: -lag)
            let turn = CABasicAnimation(keyPath: "transform.rotation.z")
            turn.fromValue = from
            turn.toValue = from + 2 * Double.pi
            turn.duration = period
            turn.timingFunction = CAMediaTimingFunction(name: .linear)
            animations.append(turn)
        }
        let group = CAAnimationGroup()
        group.animations = animations
        group.duration = period
        group.repeatCount = .infinity
        return group
    }

    private func keyframes(
        _ keyPath: String, period: TimeInterval, count: Int, lag: TimeInterval,
        value: (TimeInterval) -> Double
    ) -> CAKeyframeAnimation {
        var values = (0..<count).map {
            NSNumber(value: value(Double($0) / Double(count) * period - lag))
        }
        values.append(values[0])
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.calculationMode = .linear
        animation.duration = period
        return animation
    }
}

extension CALayer {
    /// Lays an activity motion on this layer as render-server animation, begun at media time zero
    /// so its phase is absolute: every layer given the same motion swells together, and one that
    /// scrolls back into view arrives already in time, exactly as the display-link version did by
    /// reading `link.timestamp`.
    ///
    /// Goes through `setRepeatingMotion`, so the old animation under `key` always comes off first,
    /// reduced motion lays nothing, and the tempo is pinned. Handing it a motion that does not
    /// move takes the animation off and leaves the layer exactly as it is. A layer that leaves the
    /// window loses its animations, so a view calls this again when it returns.
    @MainActor func setActivityMotion(
        _ motion: ActivityMotion, lag: TimeInterval = 0, forKey key: String = "activity"
    ) {
        guard let animation = motion.activityAnimation(lag: lag) else {
            removeAnimation(forKey: key)
            return
        }
        animation.beginTime = convertTime(0, from: nil)
        setRepeatingMotion(animation, forKey: key, meaning: motion)
    }
}

/// The one moving thing a busy surface is allowed: the state's own symbol, breathing, knocking or
/// sweeping the way that state means.
///
/// The motion is animation the render server runs (`ActivityMotion.activityAnimation`), sampled from
/// the vocabulary's own arithmetic over one period and begun at media time zero, so the phase is
/// absolute: every badge on screen swells together and one that scrolls back into view arrives
/// already in time with the rest. The main thread writes nothing per frame; it lays the animation
/// once, at the vocabulary's tempo rather than the panel's. Nothing here changes a size that
/// layout depends on: the swell is opacity and a transform, both of which the compositor applies
/// without a pass.
///
/// A badge that leaves the window loses its animation, because the render server drops a layer's
/// animations with it, and lays it again on return.
@MainActor
final class ActivityBadgeView: UIView {
    private let imageView = UIImageView()
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
    ///
    /// Being told the same thing again is not news, and a card that is restated once a second says
    /// exactly that: `apply` builds the symbol, re-reads the reduce-motion setting and puts the
    /// image back at nought degrees, so a badge that was mid-sweep would snap to the top of its
    /// turn every second and only find its place again on the next frame. Tearing the clock down
    /// and building it again each time is how a swell turns into a stutter, so a mark that has not
    /// changed is left alone — the same guard the two desks keep.
    func show(_ icon: ActivityIcon?, spoken: String?) {
        guard icon != self.icon || spoken != self.spoken else { return }
        self.icon = icon
        self.spoken = spoken
        apply()
    }

    /// Says the app is working on the reader's behalf, in the one mark the vocabulary gives that
    /// state — the swap every `UIActivityIndicatorView` in this client made.
    ///
    /// UIKit draws its indeterminate indicator itself, at a rate this app has no say in and cannot
    /// read, so any screen carrying one kept two tempos: the system's, and the thirty frames every
    /// badge, dot and gear mark here is stepped at. It is also the mark a reader looks at longest,
    /// since one is only ever up while something is taking its time — a probe, a rebuild, an
    /// account being signed in on another machine. Handing it back to the vocabulary costs nothing
    /// and settles the last rate this client did not set. What is left is deliberate and says so
    /// where it stands: the answer cascade and the shader preview, which are renderers rather than
    /// marks, and `UIRefreshControl`, whose indicator is a scroll view drawing a drag rather than
    /// a client reporting a state.
    ///
    /// Not working takes the mark down rather than freezing it: a settled open-work mark over a
    /// finished job reads as one more thing left to happen. A nil `spoken` is for the surfaces
    /// where a label beside the badge already says it, because a mark that repeats the sentence
    /// next to it is one more stop on the way through with nothing of its own to add.
    func working(_ working: Bool, spoken: String? = nil) {
        show(working ? .openWork : nil, spoken: working ? spoken : nil)
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
        isHidden = true
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
        guard motion.isAnimated, window != nil else { return }
        imageView.layer.setActivityMotion(motion, forKey: Self.motionKey)
    }

    private func stop() {
        imageView.layer.removeAnimation(forKey: Self.motionKey)
    }

    private static let motionKey = "activity"

    private func resetTransform() {
        imageView.alpha = 1
        imageView.transform = .identity
    }
}

extension UICellAccessory {
    /// The mark a list row wears while the machine it names is being worked on, in the trailing
    /// slot a system indicator used to sweep in.
    ///
    /// Written once rather than in each screen that has update rows, because two lists spelling
    /// "this one is busy" two ways is exactly what the vocabulary exists to stop — and a row's own
    /// headline already says what is happening in words, so the mark carries no sentence of its
    /// own unless the caller has one the row does not.
    @MainActor static func working(spoken: String? = nil) -> UICellAccessory {
        let badge = ActivityBadgeView(pointSize: 13)
        badge.working(true, spoken: spoken)
        return .customView(configuration: .init(customView: badge, placement: .trailing()))
    }
}

/// The mark a button wears while the press it took is still out, in the place the system's own
/// indeterminate indicator used to sit.
///
/// `UIButton.Configuration.showsActivityIndicator` is a `UIActivityIndicatorView` in a
/// configuration's clothing — the system drawing an indeterminate sweep at a rate this app has no
/// say in and cannot read, on the one control a person is watching hardest, which is the one they
/// just pressed. The vocabulary's own open-work mark stands there instead, on the pulse every
/// other mark in this client is stepped by.
///
/// The button's words stay where they are and are only inked out: a title removed for the wait
/// takes the button's own height with it, and a press whose acknowledgement is the control under
/// the finger changing size is a press that reads as a mistake. The mark is laid over the words
/// rather than beside them, so nothing moves between the press and the answer.
@MainActor
final class ButtonWorkMark {
    private let mark: ActivityBadgeView

    init(on button: UIButton, pointSize: CGFloat = 15, tint: UIColor) {
        mark = ActivityBadgeView(pointSize: pointSize)
        mark.overrideColor = tint
        mark.translatesAutoresizingMaskIntoConstraints = false
        button.addSubview(mark)
        NSLayoutConstraint.activate([
            mark.centerXAnchor.constraint(equalTo: button.centerXAnchor),
            mark.centerYAnchor.constraint(equalTo: button.centerYAnchor),
        ])
    }

    /// Whether the button's press is still out. Enabling and disabling stays the caller's, because
    /// only the surface knows whether a button that is working is a button with nothing left to
    /// offer or one that could still be pressed again.
    func show(_ working: Bool, on button: UIButton) {
        button.configuration?.titleTextAttributesTransformer = working ? Self.inkedOut : nil
        mark.working(working)
    }

    private static let inkedOut = UIConfigurationTextAttributesTransformer { attributes in
        var attributes = attributes
        attributes.foregroundColor = UIColor.clear
        return attributes
    }
}
