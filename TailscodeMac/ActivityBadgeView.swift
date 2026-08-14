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
            apply()
        }
    }

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
        guard let activity else {
            imageView.image = nil
            isHidden = true
            holder.frameCenterRotation = 0
            pulse.apply(nil)
            setAccessibilityElement(false)
            return
        }
        let icon = activity.icon
        isHidden = false
        holder.frameCenterRotation = 0
        let configuration = NSImage.SymbolConfiguration(pointSize: pointSize, weight: .semibold)
        imageView.image = NSImage(systemSymbolName: icon.symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration)
        imageView.contentTintColor = icon.tone.color
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
        setAccessibilityLabel(activity.spoken)
        pulse.apply(icon)
    }
}
