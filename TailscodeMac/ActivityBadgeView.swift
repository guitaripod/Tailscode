import AppKit
import TailscodeCore

extension ActivityTone {
    /// The same four meanings the phone and the GTK desk resolve, in this window's palette.
    var color: NSColor {
        switch self {
        case .live: return MacTheme.Color.success
        case .attention: return MacTheme.Color.warning
        case .danger: return MacTheme.Color.danger
        case .quiet: return MacTheme.Color.tertiaryLabel
        }
    }
}

extension CAFrameRateRange {
    /// The one range everything in this window that keeps moving asks its display for.
    ///
    /// Both the rate and the floor come from `ActivityTuning`, because a client that names its own
    /// is a client that can disagree with the other two desks about how fast a live thing looks
    /// live. It is written once here rather than built at each clock, so a link this app steps by
    /// hand and an animation the render server steps for it cannot end up keeping two tempos — and
    /// a harness can read the same numbers a clock is given without a window to watch them in.
    static var activityTempo: CAFrameRateRange {
        let rate = Float(ActivityTuning.frameRate)
        return CAFrameRateRange(
            minimum: Float(ActivityTuning.minimumFrameRate), maximum: rate, preferred: rate)
    }
}

extension CADisplayLink {
    /// Pins a clock this client drives by hand to the one tempo every mark in the app moves at.
    ///
    /// A mark's arithmetic reads absolute time, so the compositor is free to hand it fewer frames
    /// under load and it stays in phase — but a link left at the panel's own rate redraws a swell
    /// measured in seconds up to a hundred and twenty times a second for light no eye can tell
    /// apart, and two marks in one window would keep two different tempos.
    func runAtActivityTempo() {
        preferredFrameRateRange = .activityTempo
    }
}

extension CAAnimation {
    /// Pins motion the render server keeps on this client's behalf to that same tempo.
    ///
    /// A repeating layer animation is handed over once and then drawn at whatever the panel offers
    /// for as long as it lasts, which on a display this desk drives is up to a hundred and twenty
    /// frames a second of a swell measured in seconds — beside marks that are drawing thirty. Only
    /// motion that never ends on its own asks for this: a transition is over before an eye could
    /// read a rate off it, and holding one back would cost it its smoothness and buy nothing.
    func runAtActivityTempo() {
        preferredFrameRateRange = .activityTempo
    }
}

/// A hand on any view: it holds the state's motion and applies it to whatever the view shows.
///
/// The clock is `CADisplayLink` on the view's own display, and the phase is read from that clock
/// rather than counted from a start, so a segment that appears mid-turn arrives already in time
/// with the row that has been breathing since the turn began. What a frame may change is the
/// alpha and — only for a state that sweeps — the one leading glyph, whose four frames are the
/// same width; nothing here re-measures, because a status band that reflows every frame is worse
/// than one that does not move.
@MainActor
final class ActivityPulse {
    private weak var view: NSView?
    private var link: CADisplayLink?
    private var motion: ActivityMotion = .still
    private var cycle: [String] = []
    private var lastFrame = ""
    private var icon: ActivityIcon?
    private let onFrame: ((String) -> Void)?
    /// For a view that can turn rather than swap glyphs: degrees, once a frame, only while the
    /// state sweeps. A symbol turning is what a cycle of quarter-filled circles means in a client
    /// that draws pictures instead of text.
    var onTurn: ((CGFloat) -> Void)?

    init(view: NSView, onFrame: ((String) -> Void)? = nil) {
        self.view = view
        self.onFrame = onFrame
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(motionPreferenceChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    /// A mark already breathing has no reason to re-apply the state it is already wearing, so a
    /// desk that asks for less motion mid-turn would otherwise be honoured only by marks built
    /// after the switch. The icon is dropped and handed straight back, which is the one way past
    /// that guard and retakes the still-or-animated decision with the new answer.
    @objc private func motionPreferenceChanged() {
        let held = icon
        icon = nil
        apply(held)
    }

    /// Whether the desk wants motion. Read per state rather than per frame; a Mac that has asked
    /// for less motion still gets the symbol, the word and the colour.
    static var motionAllowed: Bool {
        !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// Re-applying the state a view is already wearing is a no-op: the band re-renders every
    /// second while a turn runs, and tearing the clock down and building it again each time is how
    /// a swell turns into a stutter.
    func apply(_ icon: ActivityIcon?) {
        guard icon != self.icon else { return }
        self.icon = icon
        guard let icon else {
            stop()
            motion = .still
            cycle = []
            view?.alphaValue = 1
            return
        }
        motion = icon.motion.honoring(reduceMotion: !Self.motionAllowed)
        cycle = icon.cycle
        lastFrame = ""
        guard motion.isAnimated else {
            stop()
            view?.alphaValue = 1
            return
        }
        start()
    }

    func stop() {
        link?.invalidate()
        link = nil
        view?.alphaValue = 1
    }

    private func start() {
        guard link == nil, let view, view.window != nil else { return }
        let link = view.displayLink(target: self, selector: #selector(step))
        link.runAtActivityTempo()
        link.add(to: .current, forMode: .common)
        self.link = link
    }

    /// Called when the view lands in or leaves a window: a badge on a scrolled-away row keeps no
    /// clock running, and one scrolled back into view picks the swell up where everything else is.
    func windowChanged() {
        guard motion.isAnimated else { return }
        view?.window == nil ? stop() : start()
    }

    @objc private func step(_ link: CADisplayLink) {
        guard let view, view.window != nil else {
            stop()
            return
        }
        let time = link.timestamp
        view.alphaValue = motion.intensity(at: time)
        if let onTurn {
            onTurn(CGFloat(-motion.rotation(at: time) * 180 / .pi))
        }
        guard let frame = motion.frame(at: time, of: cycle), frame != lastFrame else { return }
        lastFrame = frame
        onFrame?(frame)
    }
}

/// A transcript row's one-glyph mark, which starts its own clock when it lands in a window.
///
/// Rows are built before they are added to anything, so a mark that only started at build time
/// would never move; and a row removed from the transcript takes its clock with it, because the
/// pulse stops the moment it finds itself outside a window.
@MainActor
final class ActivityMarkLabel: NSTextField {
    private lazy var pulse = ActivityPulse(view: self) { [weak self] frame in
        self?.stringValue = frame
    }
    /// The state this mark is wearing, for a harness that has to prove a claim about it rather than
    /// watch it: whether a settled state is actually still is the one thing no screenshot can tell
    /// from a sweep caught mid-frame, and it is exactly what a card that never stopped got wrong.
    private(set) var icon: ActivityIcon?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isEditable = false
        isSelectable = false
        isBordered = false
        drawsBackground = false
        lineBreakMode = .byTruncatingTail
        translatesAutoresizingMaskIntoConstraints = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func mark(_ icon: ActivityIcon?) {
        self.icon = icon
        pulse.apply(icon)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        pulse.windowChanged()
    }
}

/// The state's own symbol, moving the way that state means: a terminal while a shell runs, a
/// raised hand while the turn waits on you, an unmoving triangle when it failed.
@MainActor
final class ActivityBadgeView: NSView {
    /// The symbol lives in a frame-positioned holder rather than a constrained one, because a
    /// sweeping state turns it with `frameCenterRotation` — which is about the view's centre, and
    /// which autolayout would undo on its next pass.
    private let holder = NSView()
    private let imageView = NSImageView()
    private lazy var pulse = ActivityPulse(view: holder)
    /// The symbol's size, settable because a badge lives in a recycled cell: the only chance it
    /// gets to follow a step of the type scale is the row configuring it again.
    var pointSize: CGFloat {
        didSet {
            guard pointSize != oldValue else { return }
            invalidateIntrinsicContentSize()
            apply()
        }
    }

    var activity: ActivityKind? {
        didSet {
            guard activity != oldValue else { return }
            show(activity?.icon, spoken: activity?.spoken)
        }
    }

    /// For a surface whose state is an icon rather than a named kind — a workflow agent, which
    /// turns while it is out and ticks when it is done.
    func show(_ icon: ActivityIcon?, spoken: String?) {
        guard icon != self.icon else { return }
        self.icon = icon
        self.spoken = spoken
        apply()
    }

    /// The state this badge is wearing, readable for the same reason ``ActivityMarkLabel``'s is:
    /// whether a mark moves, and at whose tempo, is the one thing a picture of the window cannot
    /// carry, so a harness proves it off the badge rather than by watching it.
    private(set) var icon: ActivityIcon?
    private var spoken: String?

    init(pointSize: CGFloat = 11) {
        self.pointSize = pointSize
        super.init(frame: .zero)
        wantsLayer = true
        imageView.imageScaling = .scaleProportionallyDown
        holder.addSubview(imageView)
        addSubview(holder)
        pulse.onTurn = { [weak self] degrees in self?.holder.frameCenterRotation = degrees }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: pointSize + 5, height: pointSize + 5)
    }

    override func layout() {
        super.layout()
        let rotation = holder.frameCenterRotation
        holder.frameCenterRotation = 0
        holder.frame = bounds
        imageView.frame = holder.bounds
        holder.frameCenterRotation = rotation
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        pulse.windowChanged()
    }

    private func apply() {
        guard let icon else {
            imageView.image = nil
            isHidden = true
            holder.frameCenterRotation = 0
            pulse.apply(nil)
            setAccessibilityElement(false)
            return
        }
        isHidden = false
        holder.frameCenterRotation = 0
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        imageView.image = NSImage(systemSymbolName: icon.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        imageView.contentTintColor = icon.tone.color
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(spoken)
        pulse.apply(icon)
    }
}

/// The one bar a transcript is allowed: a step with no progress to report, sweeping at the tempo
/// every other mark in the window keeps.
///
/// AppKit's own indeterminate `NSProgressIndicator` is drawn by the system at a rate this app has
/// no say in — one more tempo in a transcript that already has one, two rows from a badge counting
/// thirty. The sweep is therefore this client's: a fill travelling the track on a repeating layer
/// animation pinned to `ActivityTuning.frameRate`, so a compaction that runs for two minutes moves
/// at the speed the mark beside it breathes at. Nothing here changes a size layout depends on; the
/// travel is a transform, which the compositor applies without a pass.
///
/// Reduced motion drops the travel and fills the track instead, because the bar's whole job is to
/// say the step is still running and an empty track would read as a step that never started.
@MainActor
final class ActivitySweepBar: NSView {
    private let fill = CALayer()
    private let tint: NSColor
    private var laidOutWidth: CGFloat = 0

    /// The travel this bar was handed, for a harness that has to prove the claim rather than watch
    /// it: whether it is moving at all, and at what tempo. A screenshot cannot tell thirty frames a
    /// second from sixty, and the rate a repeating animation was given is exactly the fact that
    /// went missing everywhere a client drew motion the vocabulary had not set.
    var travel: CAAnimation? { fill.animation(forKey: Self.key) }

    private static let key = "sweep"
    private static let thickness: CGFloat = 4
    private static let lap: TimeInterval = 1.4
    /// How much of the track the fill covers. Wide enough to read as a body moving rather than a
    /// dot, narrow enough that the track it leaves behind still says the length is unknown.
    private static let share: CGFloat = 0.3

    init(tint: NSColor) {
        self.tint = tint
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        fill.cornerRadius = Self.thickness / 2
        layer?.addSublayer(fill)
        ink()
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(motionPreferenceChanged),
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: Self.thickness)
    }

    override func layout() {
        super.layout()
        layer?.cornerRadius = min(bounds.height, Self.thickness) / 2
        guard needsTravel else { return }
        laidOutWidth = bounds.width
        apply()
    }

    /// Whether this layout pass has to lay the travel on again: an animation is measured against
    /// the width it was written for, and one that went missing while the card was off screen would
    /// leave the bar sitting still over a step that is still running.
    private var needsTravel: Bool {
        bounds.width != laidOutWidth || (travel == nil && ActivityPulse.motionAllowed)
    }

    /// A card scrolled out of the transcript takes its clock with it, and one built before it is
    /// added to anything picks the travel up when it lands.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        ink()
        apply()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        ink()
    }

    /// Retakes the still-or-travelling decision when the desk changes its mind mid-step, because
    /// dropping the movement is the whole of what reduced motion asks for and a bar that read the
    /// setting once would keep sweeping until the card it sits on was rebuilt.
    @objc private func motionPreferenceChanged() {
        apply()
    }

    /// A `CGColor` is a resolved colour rather than a dynamic one, so both inks are taken inside
    /// this view's own drawing appearance and taken again whenever that changes — a track mixed
    /// against the wrong side of light and dark would otherwise sit there until the card was built
    /// again.
    private func ink() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = MacTheme.Color.separator.cgColor
            fill.backgroundColor = tint.cgColor
        }
    }

    private func apply() {
        fill.removeAnimation(forKey: Self.key)
        guard window != nil, bounds.width > 0 else { return }
        let travelling = ActivityPulse.motionAllowed
        let width = travelling ? max(bounds.width * Self.share, 1) : bounds.width
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        CATransaction.commit()
        guard travelling else { return }
        let slide = CABasicAnimation(keyPath: "transform.translation.x")
        slide.fromValue = -width
        slide.toValue = bounds.width
        slide.duration = Self.lap
        slide.repeatCount = .infinity
        slide.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        slide.runAtActivityTempo()
        fill.add(slide, forKey: Self.key)
    }
}
