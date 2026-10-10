import AppKit
import TailscodeCore

/// The Studio's overlay, installed as the topmost subview of a Tailscode window's content: a scrim
/// that takes presses, and above it the sheet — an opaque canvas with its own rounded top corners that
/// rises from the bottom edge. The sheet is content, never material: the scrim is a plain black dim, the
/// canvas is the transcript's own, and the only glass in it is the brief dock's, as in a pane.
///
/// The motion is one timeline over three layer properties — the sheet's translation, the sheet's
/// opacity and the scrim's opacity — computed from Core's `StudioSheetMotion`. The workspace is laid
/// out at the sheet's final size before the motion starts and nothing inside is touched while it runs,
/// so no frame inside the sheet is re-laid-out and the live sketch's layer keeps its contents.
@MainActor
final class StudioSheetView: NSView {
    let workspace = StudioWorkspaceView(scoped: false)
    let toolbar = StudioSheetToolbar()
    var onScrimPress: (() -> Void)?

    private(set) weak var host: NSWindow?
    private(set) var presence: Double = 0
    private let scrim = StudioSheetScrim()
    private let carrier = StudioSheetCarrier()
    private let body = StudioSheetCanvas()
    private let face = StudioSheetCanvas()
    private let edgeShadow = CALayer()
    private let edge = StudioSheetEdge()
    private var token = 0
    private var reduced = false
    private var observers: [NSObjectProtocol] = []
    private var layoutObservation: NSKeyValueObservation?
    private var hiddenBehind: [(view: NSView, wasHidden: Bool)] = []
    private var keyLoopWasAutomatic = true
    private var interactive = true
    private static let gapUnderToolbar: CGFloat = 4

    init() {
        super.init(frame: .zero)
        wantsLayer = true
        scrim.wantsLayer = true
        scrim.onPress = { [weak self] in self?.onScrimPress?() }
        scrim.setAccessibilityLabel(StudioSheetWords.closeLabel)
        scrim.setAccessibilityRole(.button)
        carrier.wantsLayer = true
        body.wantsLayer = true
        face.wantsLayer = true
        face.layer?.masksToBounds = true
        face.layer?.cornerRadius = CGFloat(StudioSheetMetrics.cornerRadius)
        edgeShadow.cornerRadius = CGFloat(StudioSheetMetrics.cornerRadius)
        edgeShadow.shadowRadius = CGFloat(StudioSheetMotion.edgeShadowBlur) / 2
        edgeShadow.shadowOpacity = Float(StudioSheetMotion.edgeShadowAlpha)
        edgeShadow.shadowColor = NSColor.black.cgColor
        workspace.paintsGround = false
        workspace.hostChromeHeight = CGFloat(StudioSheetMetrics.toolbarHeight)
        workspace.topPadding = Self.gapUnderToolbar
        addSubview(scrim)
        addSubview(carrier)
        carrier.addSubview(body)
        body.layer?.insertSublayer(edgeShadow, at: 0)
        body.addSubview(face)
        face.addSubview(toolbar)
        face.addSubview(workspace)
        body.addSubview(edge)
        body.setAccessibilityElement(true)
        body.setAccessibilityRole(.group)
        body.setAccessibilityLabel(StudioSheetWords.dialogName)
        body.setAccessibilityModal(true)
        applyFlipping()
        restyle()
        apply(presence: 0)
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeChanged), name: MacTheme.Chrome.didRepaint, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    @objc private func themeChanged() { restyle() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        interactive ? super.hitTest(point) : nil
    }

    /// Which face of the app the scrim is drawn over, read from the appearance the sheet resolves now so
    /// a change while it is up re-resolves the dim.
    private var appearanceFace: StudioSheetAppearance {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light
    }

    /// Whether the body's own layer is geometry-flipped, which decides which pair of corners is the top
    /// and which way a shadow offset points. AppKit leaves a flipped view's layer unflipped and flips the
    /// position it gives it, so the answer is read rather than assumed.
    private var layerIsFlipped: Bool { body.layer?.isGeometryFlipped ?? false }

    private func applyFlipping() {
        let top: CACornerMask =
            layerIsFlipped
            ? [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            : [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
        face.layer?.maskedCorners = top
        edgeShadow.maskedCorners = top
        edgeShadow.shadowOffset = CGSize(width: 0, height: layerIsFlipped ? -6 : 6)
    }

    private func restyle() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            face.layer?.backgroundColor = MacTheme.Color.canvas.cgColor
            edgeShadow.backgroundColor = MacTheme.Color.canvas.cgColor
            scrim.layer?.backgroundColor = NSColor.black.cgColor
        }
        if !isMoving { apply(presence: presence) }
    }

    /// The window's title-bar clearance in this content's own coordinates: how far from the top the
    /// window's usable area starts, which a toolbar, a unified title bar or none at all each change.
    static func titlebarClearance(in window: NSWindow) -> Double {
        guard let content = window.contentView else { return 0 }
        let layout = content.convert(window.contentLayoutRect, from: nil)
        let clearance = content.isFlipped ? layout.minY - content.bounds.minY : content.bounds.maxY - layout.maxY
        return Double(max(0, clearance))
    }

    /// The frame Core gives the sheet in a window of this content size.
    var expectedFrame: StudioSheetFrame {
        StudioSheetGeometry.frame(
            windowWidth: Double(bounds.width), windowHeight: Double(bounds.height),
            titlebar: host.map(Self.titlebarClearance(in:)) ?? 0)
    }

    /// Where the sheet rests, in this view's coordinates.
    var sheetFrame: NSRect { body.frame }

    override func layout() {
        super.layout()
        let frame = expectedFrame
        scrim.frame = bounds
        carrier.frame = bounds
        body.frame = NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
        face.frame = body.bounds
        edgeShadow.frame = body.bounds
        edge.frame = body.bounds
        let bar = CGFloat(StudioSheetMetrics.toolbarHeight)
        toolbar.frame = NSRect(x: 0, y: 0, width: body.bounds.width, height: bar)
        workspace.frame = NSRect(
            x: 0, y: bar, width: body.bounds.width, height: max(0, body.bounds.height - bar))
        if !isMoving { apply(presence: presence) }
    }

    /// Puts the overlay on top of a window's content and starts following the window: its size, its
    /// full-screen transitions and its title-bar clearance all re-frame the sheet. Already there is a
    /// no-op, so opening again while it is up changes nothing about where it sits.
    func install(in window: NSWindow) {
        guard host !== window || superview == nil, let content = window.contentView else { return }
        uninstall()
        host = window
        frame = content.bounds
        autoresizingMask = [.width, .height]
        content.addSubview(self)
        observers = [
            NSWindow.didEnterFullScreenNotification, NSWindow.didExitFullScreenNotification,
            NSWindow.didResizeNotification,
        ].map { name in
            NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.needsLayout = true }
            }
        }
        layoutObservation = window.observe(\.contentLayoutRect, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.needsLayout = true }
        }
        applyFlipping()
        needsLayout = true
        layoutSubtreeIfNeeded()
    }

    /// Takes the overlay out of its window and gives back everything it held.
    func uninstall() {
        release()
        removeFromSuperview()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers = []
        layoutObservation?.invalidate()
        layoutObservation = nil
        host = nil
        cancelMotion(settingPresence: 0)
    }

    /// The sheet takes the keyboard and the assistive technologies' attention: everything behind it is
    /// hidden from them, and Tab walks a ring that has nothing outside the sheet in it.
    func capture() {
        interactive = true
        guard let window = host, let content = window.contentView, hiddenBehind.isEmpty else {
            refreshKeyLoop()
            return
        }
        hiddenBehind = content.subviews.filter { $0 !== self }.map { ($0, $0.isAccessibilityHidden()) }
        for entry in hiddenBehind { entry.view.setAccessibilityHidden(true) }
        keyLoopWasAutomatic = window.autorecalculatesKeyViewLoop
        window.autorecalculatesKeyViewLoop = false
        refreshKeyLoop()
        NSAccessibility.post(element: body, notification: .layoutChanged)
        NSAccessibility.post(
            element: body, notification: .announcementRequested,
            userInfo: [.announcement: StudioSheetWords.dialogName, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// The sheet lets go of the keyboard and of the content it hid, the moment it starts to leave: the
    /// conversation's chords and its accessibility tree are back while the motion is still running.
    func release() {
        interactive = false
        guard !hiddenBehind.isEmpty else { return }
        for entry in hiddenBehind { entry.view.setAccessibilityHidden(entry.wasHidden) }
        hiddenBehind = []
        if let window = host {
            window.autorecalculatesKeyViewLoop = keyLoopWasAutomatic
            window.recalculateKeyViewLoop()
        }
    }

    /// Re-links the views that can take the keyboard into one ring, so Tab and Shift-Tab cycle inside
    /// the sheet. Run when the sheet comes up and whenever a lane changes what it holds.
    func refreshKeyLoop() {
        guard host != nil, !hiddenBehind.isEmpty else { return }
        var ring: [NSView] = []
        func collect(_ view: NSView) {
            if view.acceptsFirstResponder, view.canBecomeKeyView, !view.isHiddenOrHasHiddenAncestor {
                ring.append(view)
            }
            for child in view.subviews { collect(child) }
        }
        collect(body)
        for (index, view) in ring.enumerated() { view.nextKeyView = ring[(index + 1) % ring.count] }
    }

    /// Whether `view` is inside the sheet, for deciding where focus stands.
    func holds(_ view: NSView?) -> Bool {
        view?.isDescendant(of: body) == true
    }

    var isMoving: Bool { carrier.layer?.animation(forKey: Self.motionKey) != nil }

    private static let motionKey = "studio.sheet.motion"

    /// What the motion under way is: how long it takes, how far it travels, and whether the sheet fades,
    /// which only reduced motion does. Nil when nothing is moving.
    var motionSummary: (duration: Double, travel: Double, fades: Bool)? {
        guard let travel = carrier.layer?.animation(forKey: Self.motionKey) as? CABasicAnimation,
            let from = travel.fromValue as? CGFloat, let to = travel.toValue as? CGFloat
        else { return nil }
        return (travel.duration, Double(abs(to - from)), carrier.layer?.animation(forKey: "studio.sheet.fade") != nil)
    }

    /// How present the sheet is right now, read off the layer that is being drawn when a motion is
    /// under way, so a motion that starts mid-way starts from what is on screen and never jumps.
    var currentPresence: Double {
        guard isMoving, let live = scrim.layer?.presentation() else { return presence }
        let alpha = StudioSheetMotion.scrimAlpha(for: appearanceFace)
        guard alpha > 0 else { return presence }
        return min(1, max(0, Double(live.opacity) / alpha))
    }

    /// Sets how present the sheet is with no animation: 0 is away below the window, 1 is at rest.
    func apply(presence value: Double) {
        presence = min(1, max(0, value))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scrim.layer?.opacity = Float(StudioSheetMotion.scrimOpacity(progress: presence, appearance: appearanceFace))
        carrier.layer?.sublayerTransform = CATransform3DMakeTranslation(0, slide(at: presence), 0)
        carrier.layer?.opacity = Float(StudioSheetMotion.sheetOpacity(progress: presence, reduced: reduced))
        CATransaction.commit()
    }

    /// How far below its rest position the sheet is at this presence. The carrier's space runs top-down,
    /// as the overlay it sits in does, so below is positive.
    private func slide(at progress: Double) -> CGFloat {
        let distance = StudioSheetMotion.translation(
            progress: progress, sheetHeight: Double(body.bounds.height), reduced: reduced)
        return CGFloat(distance)
    }

    /// The curve a motion is drawn with. The sheet takes ease-out-quad over a spring: a spring settles
    /// when it settles rather than in `openDuration`, and a frame frozen at a given progress could not
    /// be read from it. Both quadratics are exact cubic Béziers.
    private static func timing(for curve: StudioSheetCurve) -> CAMediaTimingFunction {
        switch curve {
        case .springCriticallyDamped, .easeOutQuad:
            return CAMediaTimingFunction(controlPoints: 1 / 3, 2 / 3, 2 / 3, 1)
        case .easeInQuad:
            return CAMediaTimingFunction(controlPoints: 1 / 3, 0, 2 / 3, 1 / 3)
        }
    }

    /// Runs the one motion from where the sheet is now to rest (`opening`) or to away, then calls
    /// `completion` once, unless another motion or a cancel superseded it first.
    func animate(opening: Bool, reduced reducedMotion: Bool, completion: @escaping () -> Void) {
        let from = currentPresence
        let to = opening ? 1.0 : 0.0
        reduced = reducedMotion
        token += 1
        let mine = token
        let span = max(0.05, abs(to - from))
        let duration = StudioSheetMotion.duration(opening: opening, reduced: reducedMotion) * span
        let curve = StudioSheetMotion.curve(opening: opening, hasSpring: false)
        let timing = Self.timing(for: curve)

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.token == mine else { return }
                completion()
            }
        }
        presence = to
        let face = appearanceFace
        let scrimTo = StudioSheetMotion.scrimOpacity(progress: to, appearance: face)
        let scrimFrom = StudioSheetMotion.scrimOpacity(progress: from, appearance: face)
        let slideFrom = slide(at: from)
        let slideTo = slide(at: to)
        let opacityFrom = StudioSheetMotion.sheetOpacity(progress: from, reduced: reducedMotion)
        let opacityTo = StudioSheetMotion.sheetOpacity(progress: to, reduced: reducedMotion)
        scrim.layer?.opacity = Float(scrimTo)
        carrier.layer?.sublayerTransform = CATransform3DMakeTranslation(0, slideTo, 0)
        carrier.layer?.opacity = Float(opacityTo)
        let shared: (CABasicAnimation) -> Void = {
            $0.duration = duration
            $0.timingFunction = timing
        }
        let scrimMotion = CABasicAnimation(keyPath: "opacity")
        scrimMotion.fromValue = scrimFrom
        scrimMotion.toValue = scrimTo
        shared(scrimMotion)
        scrim.layer?.add(scrimMotion, forKey: Self.motionKey)
        let travel = CABasicAnimation(keyPath: "sublayerTransform.translation.y")
        travel.fromValue = slideFrom
        travel.toValue = slideTo
        shared(travel)
        carrier.layer?.add(travel, forKey: Self.motionKey)
        if reducedMotion {
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = opacityFrom
            fade.toValue = opacityTo
            shared(fade)
            carrier.layer?.add(fade, forKey: "studio.sheet.fade")
        }
        CATransaction.commit()
    }

    /// Stops a motion where it stands and settles the sheet at `presence`, so a held frame is exactly
    /// the arithmetic's value for it.
    func cancelMotion(settingPresence value: Double) {
        token += 1
        scrim.layer?.removeAnimation(forKey: Self.motionKey)
        carrier.layer?.removeAnimation(forKey: Self.motionKey)
        carrier.layer?.removeAnimation(forKey: "studio.sheet.fade")
        apply(presence: value)
    }

    /// A window-space point where a press lands on the scrim and on neither the sheet nor the title
    /// bar, which keeps its own presses: the gutter beside the sheet, else the seam above it. A window
    /// too narrow and too short for either has no scrim to press.
    var scrimPointInWindow: NSPoint? {
        guard let host else { return nil }
        if sheetFrame.minX >= 4 {
            return convert(NSPoint(x: sheetFrame.minX / 2, y: bounds.midY), to: nil)
        }
        let clearance = CGFloat(Self.titlebarClearance(in: host))
        guard sheetFrame.minY - clearance >= 4 else { return nil }
        return convert(NSPoint(x: bounds.midX, y: clearance + (sheetFrame.minY - clearance) / 2), to: nil)
    }
}

/// What the sheet's motion is applied to. AppKit owns the `transform` of a view's own layer — it resets
/// it from the view's frame rotation whenever the frame changes — so the sheet is moved by this
/// carrier's `sublayerTransform`, which nothing else writes. It passes every press through to whatever
/// is under it where it has nothing of its own.
@MainActor
final class StudioSheetCarrier: NSView {
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// A plain top-down view: the sheet's body and its clipped face lay their children out from the top,
/// as the rest of the Studio does.
@MainActor
final class StudioSheetCanvas: NSView {
    override var isFlipped: Bool { true }
}

/// The hairline in the rule token along the sheet's top and sides, open at the bottom where the sheet is
/// flush with the window and a line would only sit on its edge. It is drawn rather than a shape layer
/// so that it is part of every picture the window gives of itself.
@MainActor
final class StudioSheetEdge: NSView {
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let width = CGFloat(StudioSheetMotion.edgeHairlineWidth)
        let radius = CGFloat(StudioSheetMetrics.cornerRadius)
        let rect = bounds.insetBy(dx: width / 2, dy: width / 2)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: rect.minX, y: bounds.maxY))
        path.line(to: NSPoint(x: rect.minX, y: rect.minY + radius))
        path.appendArc(
            withCenter: NSPoint(x: rect.minX + radius, y: rect.minY + radius), radius: radius,
            startAngle: 180, endAngle: 270)
        path.line(to: NSPoint(x: rect.maxX - radius, y: rect.minY))
        path.appendArc(
            withCenter: NSPoint(x: rect.maxX - radius, y: rect.minY + radius), radius: radius,
            startAngle: 270, endAngle: 360)
        path.line(to: NSPoint(x: rect.maxX, y: bounds.maxY))
        path.lineWidth = width
        MacTheme.Color.separator.setStroke()
        path.stroke()
    }
}

/// The dim behind the sheet: plain black at the scrim's alpha, which takes presses and answers them
/// with a dismissal — nothing is lost by a stray click, since a draft and a render survive the sheet.
@MainActor
final class StudioSheetScrim: NSView {
    var onPress: (() -> Void)?

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        onPress?()
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}

/// The controls that lived in the panel's title bar, in the sheet's own row: the lane switch leading,
/// the machine pill in the middle, the queue count and Done trailing. A sheet has no title bar to lend
/// them one, so they are placed by frame on the sheet's canvas.
@MainActor
final class StudioSheetToolbar: NSView {
    let lanes = NSSegmentedControl(
        labels: StudioLaneID.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    let pill = StudioMachinePill()
    let queue = StudioTheme.label(.panelFootnote, color: MacTheme.Color.secondaryLabel)
    let done = NSButton(title: ImageGenSurface.dismissTitle, target: nil, action: nil)

    private static let edge: CGFloat = 12
    private static let spacing: CGFloat = 12

    init() {
        super.init(frame: .zero)
        lanes.segmentStyle = .automatic
        lanes.setAccessibilityLabel(Localized.text("Studio lane"))
        done.bezelStyle = .rounded
        done.keyEquivalent = ""
        for view in [lanes, pill, queue, done] { addSubview(view) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        let lanesSize = lanes.intrinsicContentSize
        let doneSize = done.intrinsicContentSize
        queue.sizeToFit()
        let queueSize = queue.frame.size
        let midY = bounds.height / 2
        lanes.frame = NSRect(
            x: Self.edge, y: midY - lanesSize.height / 2, width: lanesSize.width, height: lanesSize.height)
        done.frame = NSRect(
            x: bounds.width - Self.edge - doneSize.width, y: midY - doneSize.height / 2,
            width: doneSize.width, height: doneSize.height)
        queue.frame = NSRect(
            x: done.frame.minX - Self.spacing - queueSize.width, y: midY - queueSize.height / 2,
            width: queueSize.width, height: queueSize.height)
        let room = queue.frame.minX - lanes.frame.maxX - 2 * Self.spacing
        let pillSize = pill.intrinsicContentSize
        let width = min(pillSize.width, max(0, room))
        let centred = (bounds.width - width) / 2
        let x = min(max(centred, lanes.frame.maxX + Self.spacing), queue.frame.minX - Self.spacing - width)
        pill.frame = NSRect(x: x, y: midY - pillSize.height / 2, width: width, height: pillSize.height)
    }

    /// The count and the lane's hint, redrawn when the lane says something changed.
    func refresh(queue count: Int, hint: String?) {
        queue.stringValue = "\(ImageGenMachineWords.queueLabel) \(count)"
        queue.setAccessibilityLabel(queue.stringValue)
        done.toolTip = hint
        done.setAccessibilityHelp(hint)
        needsLayout = true
    }
}
