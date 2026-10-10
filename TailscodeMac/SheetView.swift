import AppKit
import TailscodeCore

/// A sheet's overlay, installed as the topmost subview of a Tailscode window's content: a scrim that
/// takes presses, and above it the sheet — an opaque canvas with its own rounded top corners that rises
/// from the bottom edge. The sheet is content, never material: the scrim is a plain black dim and the
/// canvas is either the transcript's own or, for a viewer, the lights-down neutral a picture is judged
/// on. It knows nothing of what it holds: a content view and a 44-point toolbar row are handed to it, and
/// the Studio and the media viewer are two instances of the same host.
///
/// The motion is one timeline over three layer properties — the sheet's translation, the sheet's
/// opacity and the scrim's opacity — computed from Core's `StudioSheetMotion`. The content is laid out
/// at the sheet's final size before the motion starts and nothing inside is touched while it runs, so no
/// frame inside the sheet is re-laid-out and a live layer keeps its contents.
@MainActor
class SheetView: NSView {
    var onScrimPress: (() -> Void)?

    private(set) weak var host: NSWindow?
    private(set) var presence: Double = 0
    private(set) var sheetContent: NSView
    private(set) var sheetToolbar: NSView

    /// How many sheets stand beneath this one. The stack sets it; the frame, which sits
    /// `StudioSheetMetrics.stackInset` further in for each level, and the part of the window the scrim
    /// darkens both follow it.
    var depth = 0 {
        didSet {
            guard depth != oldValue else { return }
            needsLayout = true
        }
    }

    private let lightsDown: Bool
    private let scrim = SheetScrim()
    private let carrier = SheetCarrier()
    private let body = SheetCanvas()
    private let face = SheetCanvas()
    private let edgeShadow = CALayer()
    private let edge = SheetEdge()
    private var token = 0
    private var reduced = false
    private var observers: [NSObjectProtocol] = []
    private var layoutObservation: NSKeyValueObservation?
    private var hiddenBehind: [(view: NSView, wasHidden: Bool)] = []
    private var keyLoopWasAutomatic = true
    private var interactive = true
    private let dialogName: String

    init(content: NSView, toolbar: NSView, dialogName: String, closeLabel: String, lightsDown: Bool = false) {
        sheetContent = content
        sheetToolbar = toolbar
        self.dialogName = dialogName
        self.lightsDown = lightsDown
        super.init(frame: .zero)
        wantsLayer = true
        scrim.wantsLayer = true
        scrim.onPress = { [weak self] in self?.onScrimPress?() }
        scrim.setAccessibilityLabel(closeLabel)
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
        if lightsDown { body.appearance = NSAppearance(named: .darkAqua) }
        addSubview(scrim)
        addSubview(carrier)
        carrier.addSubview(body)
        body.layer?.insertSublayer(edgeShadow, at: 0)
        body.addSubview(face)
        face.addSubview(toolbar)
        face.addSubview(content)
        body.addSubview(edge)
        body.setAccessibilityElement(true)
        body.setAccessibilityRole(.group)
        body.setAccessibilityLabel(dialogName)
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

    /// Puts another content and toolbar in the sheet, in place, with no motion: the viewer retargets
    /// from a gallery to a clip, or to another gallery, while it stands.
    func setContent(_ content: NSView, toolbar: NSView) {
        guard content !== sheetContent || toolbar !== sheetToolbar else { return }
        sheetContent.removeFromSuperview()
        sheetToolbar.removeFromSuperview()
        sheetContent = content
        sheetToolbar = toolbar
        face.addSubview(toolbar)
        face.addSubview(content)
        needsLayout = true
        layoutSubtreeIfNeeded()
        refreshKeyLoop()
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

    private var topCorners: CACornerMask {
        layerIsFlipped
            ? [.layerMinXMinYCorner, .layerMaxXMinYCorner]
            : [.layerMinXMaxYCorner, .layerMaxXMaxYCorner]
    }

    private func applyFlipping() {
        face.layer?.maskedCorners = topCorners
        edgeShadow.maskedCorners = topCorners
        edgeShadow.shadowOffset = CGSize(width: 0, height: layerIsFlipped ? -6 : 6)
        scrim.dim.layer?.maskedCorners = topCorners
    }

    private func restyle() {
        let ground = lightsDown ? MacTheme.Color.viewerGround : MacTheme.Color.canvas
        (lightsDown ? body : self).effectiveAppearance.performAsCurrentDrawingAppearance {
            face.layer?.backgroundColor = ground.cgColor
            edgeShadow.backgroundColor = ground.cgColor
        }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            scrim.dim.layer?.backgroundColor = NSColor.black.cgColor
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

    /// The frame Core gives the sheet in a window of this content size, at this sheet's depth.
    var expectedFrame: StudioSheetFrame { frame(atDepth: depth) }

    private func frame(atDepth level: Int) -> StudioSheetFrame {
        StudioSheetGeometry.frame(
            windowWidth: Double(bounds.width), windowHeight: Double(bounds.height),
            titlebar: host.map(Self.titlebarClearance(in:)) ?? 0, depth: level)
    }

    /// Where the sheet rests, in this view's coordinates.
    var sheetFrame: NSRect { body.frame }

    /// The part of the window the scrim darkens: all of it for a sheet over the conversation, and only
    /// the sheet beneath for one stacked on another, whose own scrim already dimmed the conversation.
    var dimFrame: NSRect { scrim.dim.frame }

    override func layout() {
        super.layout()
        let frame = expectedFrame
        scrim.frame = bounds
        if depth > 0 {
            let beneath = self.frame(atDepth: depth - 1)
            scrim.dim.frame = NSRect(x: beneath.x, y: beneath.y, width: beneath.width, height: beneath.height)
            scrim.dim.layer?.cornerRadius = CGFloat(StudioSheetMetrics.cornerRadius)
        } else {
            scrim.dim.frame = bounds
            scrim.dim.layer?.cornerRadius = 0
        }
        carrier.frame = bounds
        body.frame = NSRect(x: frame.x, y: frame.y, width: frame.width, height: frame.height)
        face.frame = body.bounds
        edgeShadow.frame = body.bounds
        edge.frame = body.bounds
        let bar = CGFloat(StudioSheetMetrics.toolbarHeight)
        sheetToolbar.frame = NSRect(x: 0, y: 0, width: body.bounds.width, height: bar)
        sheetContent.frame = NSRect(
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

    /// The sheet takes the keyboard and the assistive technologies' attention: everything behind it —
    /// the conversation, and a sheet beneath this one — is hidden from them, and Tab walks a ring that
    /// has nothing outside the sheet in it.
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
            userInfo: [.announcement: dialogName, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    /// The sheet lets go of the keyboard and of the content it hid, the moment it starts to leave: the
    /// conversation's chords and its accessibility tree are back while the motion is still running. A
    /// window whose key loop was a sheet's own stays that way: the sheet beneath relinks it.
    func release() {
        interactive = false
        guard !hiddenBehind.isEmpty else { return }
        for entry in hiddenBehind { entry.view.setAccessibilityHidden(entry.wasHidden) }
        hiddenBehind = []
        if let window = host {
            window.autorecalculatesKeyViewLoop = keyLoopWasAutomatic
            if keyLoopWasAutomatic { window.recalculateKeyViewLoop() }
        }
    }

    /// Re-links the views that can take the keyboard into one ring, so Tab and Shift-Tab cycle inside
    /// the sheet. Run when the sheet comes up and whenever what it holds changes.
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
        guard isMoving, let live = scrim.dim.layer?.presentation() else { return presence }
        let alpha = StudioSheetMotion.scrimAlpha(for: appearanceFace)
        guard alpha > 0 else { return presence }
        return min(1, max(0, Double(live.opacity) / alpha))
    }

    /// Sets how present the sheet is with no animation: 0 is away below the window, 1 is at rest.
    func apply(presence value: Double) {
        presence = min(1, max(0, value))
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        scrim.dim.layer?.opacity = Float(StudioSheetMotion.scrimOpacity(progress: presence, appearance: appearanceFace))
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
        scrim.dim.layer?.opacity = Float(scrimTo)
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
        scrim.dim.layer?.add(scrimMotion, forKey: Self.motionKey)
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
        scrim.dim.layer?.removeAnimation(forKey: Self.motionKey)
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
final class SheetCarrier: NSView {
    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }
}

/// A plain top-down view: the sheet's body and its clipped face lay their children out from the top,
/// as the rest of the Studio does.
@MainActor
final class SheetCanvas: NSView {
    override var isFlipped: Bool { true }
}

/// The hairline in the rule token along the sheet's top and sides, open at the bottom where the sheet is
/// flush with the window and a line would only sit on its edge. It is drawn rather than a shape layer
/// so that it is part of every picture the window gives of itself.
@MainActor
final class SheetEdge: NSView {
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

/// What takes the press behind the sheet and answers it with a dismissal — nothing is lost by a stray
/// click, since a draft and a render survive the sheet. It fills the window so that every press the
/// sheet does not hold is the sheet's to answer; the plain black dim it wears is its own child, because
/// a sheet stacked on another dims only the one beneath while still owning every press.
@MainActor
final class SheetScrim: NSView {
    var onPress: (() -> Void)?
    let dim = SheetDim()

    override var isFlipped: Bool { true }

    init() {
        super.init(frame: .zero)
        dim.wantsLayer = true
        dim.layer?.masksToBounds = true
        addSubview(dim)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(convert(point, from: superview)) ? self : nil
    }

    override func mouseDown(with event: NSEvent) {
        onPress?()
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}

/// The dim itself: a plain black layer whose opacity is the sheet's presence.
@MainActor
final class SheetDim: NSView {
    override var isFlipped: Bool { true }
}

/// The row a viewer's sheet carries in place of a title bar: controls leading, the title in the middle
/// and controls trailing, placed by frame on the sheet's canvas. The Studio's own row is a different
/// arrangement of the same idea.
@MainActor
final class SheetToolbarView: NSView {
    var leading: [NSView] = [] {
        didSet { replace(oldValue, with: leading) }
    }
    var title: NSView? {
        didSet {
            oldValue?.removeFromSuperview()
            if let title { addSubview(title) }
            needsLayout = true
        }
    }
    var trailing: [NSView] = [] {
        didSet { replace(oldValue, with: trailing) }
    }

    private static let edge: CGFloat = 12
    private static let spacing: CGFloat = 8

    override var isFlipped: Bool { true }

    private func replace(_ old: [NSView], with new: [NSView]) {
        old.forEach { $0.removeFromSuperview() }
        new.forEach { addSubview($0) }
        needsLayout = true
    }

    private func size(of view: NSView) -> NSSize {
        let intrinsic = view.intrinsicContentSize
        let natural =
            intrinsic.width >= 0 && intrinsic.height >= 0 ? intrinsic : view.fittingSize
        return NSSize(width: ceil(natural.width), height: ceil(natural.height))
    }

    override func layout() {
        super.layout()
        let midY = bounds.height / 2
        var left = Self.edge
        for view in leading where !view.isHidden {
            let size = size(of: view)
            view.frame = NSRect(x: left, y: midY - size.height / 2, width: size.width, height: size.height)
            left = view.frame.maxX + Self.spacing
        }
        var right = bounds.width - Self.edge
        for view in trailing.reversed() where !view.isHidden {
            let size = size(of: view)
            view.frame = NSRect(
                x: right - size.width, y: midY - size.height / 2, width: size.width, height: size.height)
            right = view.frame.minX - Self.spacing
        }
        guard let title else { return }
        let room = max(0, right - left - Self.spacing)
        let natural = size(of: title)
        let width = min(natural.width, room)
        let centred = (bounds.width - width) / 2
        let x = min(max(centred, left + Self.spacing), right - width)
        title.frame = NSRect(x: x, y: midY - natural.height / 2, width: width, height: natural.height)
    }
}

/// Every sheet that is up in this app, in the order they were raised: the one the keyboard belongs to,
/// whether the conversation's chords are on, and how many may stand on one another
/// (`StudioSheetMetrics.maximumDepth`). Esc, ⌘W, Done and a press on the scrim reach only the top one,
/// because a sheet beneath is by construction not what anyone is looking at.
@MainActor
final class SheetStack {
    static let shared = SheetStack()

    private(set) var presenters: [SheetPresenter] = []

    /// The conversation's chords are on only when no sheet holds the keyboard: a sheet that has started
    /// to leave has already given it back.
    var conversationChordsEnabled: Bool {
        presenters.allSatisfy { $0.state.conversationChordsEnabled }
    }

    /// The sheet that owns the keyboard: the topmost one that has not started to leave.
    var keyOwner: SheetPresenter? {
        presenters.last { $0.state.capturesKeys }
    }

    /// The sheets that are standing or rising, which are the ones the limit counts.
    var live: [SheetPresenter] {
        presenters.filter { $0.state.capturesKeys }
    }

    func canRaise(_ presenter: SheetPresenter) -> Bool {
        presenters.contains { $0 === presenter } || live.count < StudioSheetMetrics.maximumDepth
    }

    func raise(_ presenter: SheetPresenter) {
        if !presenters.contains(where: { $0 === presenter }) { presenters.append(presenter) }
        renumber()
    }

    func remove(_ presenter: SheetPresenter) {
        presenters.removeAll { $0 === presenter }
        renumber()
        keyOwner?.sheet.refreshKeyLoop()
    }

    /// Takes every sheet but `presenter` away with no motion, for the moment something is raised that
    /// would otherwise end up under a sheet it has nothing to do with.
    func teardownOthers(than presenter: SheetPresenter) {
        for other in presenters where other !== presenter { other.teardown() }
    }

    /// Closes the top sheet when `chord` is ⌘W (or Ctrl+W where `command` is false) and the key window
    /// is the one the sheet is in. The sheet beneath, the window and every other window are not
    /// touched: the next press is theirs.
    func closesTop(chord: KeyChord, command: Bool, keyWindow: NSWindow?) -> Bool {
        guard let top = keyOwner, StudioSheetKeys.closes(chord, command: command),
            keyWindow == nil || keyWindow === top.sheet.host
        else { return false }
        top.dismiss()
        return true
    }

    private func renumber() {
        for (index, presenter) in presenters.enumerated() { presenter.sheet.depth = index }
    }
}

/// One sheet's life in a window: Core's `StudioSheetState` run over what the host does — rise, change
/// content, leave — and everything that has to be true around it. The keyboard is the sheet's while it
/// is up, the opener gets focus back the moment it starts to leave, and the conversation's chords are
/// off until then. Closing a sheet closes nothing else: what it showed lives above it.
@MainActor
final class SheetPresenter {
    let sheet: SheetView
    let stack: SheetStack
    private(set) var state: StudioSheetState = .closed
    var reducedMotion: () -> Bool = { !StudioTheme.motionAllowed }
    var onDismissed: (() -> Void)?
    var onClosed: (() -> Void)?

    private weak var opener: NSResponder?
    private var closeObserver: NSObjectProtocol?

    init(sheet: SheetView, stack: SheetStack = .shared) {
        self.sheet = sheet
        self.stack = stack
        sheet.onScrimPress = { [weak self] in self?.dismiss() }
    }

    /// Whether this sheet is up and holds the keyboard.
    var ownsKeys: Bool { state.capturesKeys && stack.keyOwner === self }

    /// Raises the sheet in `target`, or, when it is already up, tells the caller so it can change what
    /// it holds. `prepare` runs once the sheet is in the window and before it takes the keyboard, `ready`
    /// once it holds it. Raising over a stack that is already full does nothing and says so.
    @discardableResult
    func show(in target: NSWindow, lane: StudioLaneKind = .image, prepare: () -> Void = {}, ready: () -> Void = {})
        -> StudioSheetEffect
    {
        guard target.contentView != nil else { return .none }
        if state != .closed, let host = sheet.host, host !== target { move(to: target) }
        guard state != .closed || stack.canRaise(self) else { return .none }
        let (next, effect) = state.reduced(by: .show(lane: lane))
        state = next
        guard case .animateIn = effect else { return effect }
        stack.raise(self)
        if !sheet.holds(target.firstResponder as? NSView) { opener = target.firstResponder }
        sheet.install(in: target)
        watchClose(of: target)
        prepare()
        sheet.capture()
        ready()
        sheet.layoutSubtreeIfNeeded()
        sheet.animate(opening: true, reduced: reducedMotion()) { [weak self] in self?.motionFinished() }
        return effect
    }

    /// Starts the sheet leaving. The conversation's chords, its accessibility tree and the opener's
    /// focus are back at once — the motion is a courtesy, not a state anything waits on.
    func dismiss() {
        let (next, effect) = state.reduced(by: .dismiss)
        state = next
        guard effect == .animateOut else { return }
        sheet.release()
        restoreOpenerFocus()
        stack.keyOwner?.sheet.refreshKeyLoop()
        onDismissed?()
        sheet.animate(opening: false, reduced: reducedMotion()) { [weak self] in self?.motionFinished() }
    }

    /// The motion ended: a rising sheet is at rest, a leaving one is gone and its overlay with it.
    func motionFinished() {
        let (next, _) = state.reduced(by: .finished)
        state = next
        guard next == .closed else { return }
        sheet.uninstall()
        stack.remove(self)
        onClosed?()
    }

    /// Takes the sheet away at once, with no motion to wait for: its window is closing, or something
    /// else has to stand where it was.
    func teardown() {
        let wasUp = state != .closed
        state = .closed
        opener = nil
        sheet.uninstall()
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
        stack.remove(self)
        if wasUp { onClosed?() }
    }

    #if DEBUG
        /// Stops the motion where it stands and holds the sheet at `progress` of it, rising or leaving,
        /// so a frame in the middle of the move can be photographed. The state is the one the motion
        /// was in, so the keys and the menu answer as they would at that moment.
        func hold(at progress: Double, closing: Bool) {
            if closing {
                if state.capturesKeys {
                    sheet.release()
                    restoreOpenerFocus()
                }
                state = .closing
            } else {
                state = .opening
            }
            sheet.cancelMotion(settingPresence: progress)
        }
    #endif

    /// Opening from another window takes the sheet out of the first one, with everything it held, and
    /// puts it in the second at rest.
    private func move(to window: NSWindow) {
        sheet.uninstall()
        sheet.install(in: window)
        sheet.apply(presence: 1)
        sheet.capture()
        opener = window.firstResponder
        if state == .opening { state = state.reduced(by: .finished).state }
        watchClose(of: window)
    }

    /// A window that closes with the sheet in it takes the sheet with it, with no motion to wait for.
    private func watchClose(of window: NSWindow) {
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.teardown() }
        }
    }

    /// Focus goes back to whatever held it when the sheet opened, or to nothing when that is gone.
    private func restoreOpenerFocus() {
        guard let window = sheet.host else { return }
        if let opener, window.makeFirstResponder(opener) { return }
        window.makeFirstResponder(nil)
    }
}
