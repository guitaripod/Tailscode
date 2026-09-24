import AppKit
import ObjectiveC

/// The ground that comes up under something the pointer is over, and deepens while the button is
/// down on it.
///
/// It is the one answer the window gives to a pointer before a press: a click on a thing that did
/// not change under the pointer reads as a click nobody was expecting, and a window where nothing
/// answers until it is pressed feels slower than it is. The fill is the system's own ink at a low
/// opacity rather than a palette colour, because it lands on glass as often as on the canvas and
/// has to flip with whatever the material decides it is, and because a hover is neither motion nor
/// affirmation — the two meanings the accent is kept for.
@MainActor
final class PointerPlate: NSView {
    enum Level { case rest, hover, press }

    private(set) var level: Level = .rest
    var radius: CGFloat = 6 {
        didSet { layer?.cornerRadius = radius }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = radius
        layer?.cornerCurve = .continuous
        alphaValue = 0
        setAccessibilityElement(false)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        layer?.backgroundColor =
            NSColor.labelColor.withAlphaComponent(level == .press ? 0.13 : 0.07).cgColor
    }

    /// A press lands at once, because the press is the answer the hand is waiting for; coming up
    /// and going away are a short fade, so sweeping across a list reads as light passing rather
    /// than as a strobe.
    func show(_ next: Level) {
        guard next != level else { return }
        level = next
        needsDisplay = true
        let target: CGFloat = next == .rest ? 0 : 1
        if let shown = layer?.presentation()?.opacity {
            layer?.removeAllAnimations()
            alphaValue = CGFloat(shown)
        }
        guard next != .press, alphaValue != target else {
            alphaValue = target
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = next == .rest ? 0.18 : 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().alphaValue = target
        }
    }

    /// The reach a plate is given past the edges of what it sits under: a line of text or a glyph
    /// is measured to its ink, and a ground cut to the ink reads as a highlighter rather than as a
    /// place to press.
    nonisolated static let inlineOutset = NSEdgeInsets(top: 3, left: 6, bottom: 3, right: 6)
}

/// Something in the transcript that acts when pressed and is not a control — a thought's header,
/// a tool call's line, an agent's card.
///
/// It answers the pointer before the press with a plate under it, deepens the plate the moment
/// the button goes down, acts when the button comes up over it and not when it comes up somewhere
/// else, and takes the first click on a window that is not in front. Nothing a surface like this
/// does is destructive, and a click spent only on bringing the window forward is a click that did
/// nothing the person could see.
@MainActor
final class PressSurface: NSView {
    var onPress: (() -> Void)?
    private let plate = PointerPlate()
    private let outset: NSEdgeInsets
    private var hovered = false
    private var pressed = false

    init(content: NSView, outset: NSEdgeInsets = PointerPlate.inlineOutset, radius: CGFloat = 6) {
        self.outset = outset
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        plate.radius = radius
        addSubview(plate)
        content.translatesAutoresizingMaskIntoConstraints = false
        addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: topAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self, userInfo: nil))
        setAccessibilityElement(false)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        plate.frame = NSRect(
            x: -outset.left, y: -outset.bottom,
            width: bounds.width + outset.left + outset.right,
            height: bounds.height + outset.top + outset.bottom)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// The whole surface is one press, except for a real control inside it, which keeps its own.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hit = super.hitTest(point) else { return nil }
        if let control = hit as? NSControl, control.isEnabled,
            control is NSButton || control is NSSegmentedControl || control is NSSlider
                || (control as? NSTextField)?.isEditable == true
        {
            return hit
        }
        return self
    }

    /// A row rebuilt under a pointer that is standing still gets no entered event, so a surface
    /// that arrives in a window asks where the pointer already is.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard let window else {
            setHovered(false)
            return
        }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        setHovered(bounds.contains(point))
    }

    override func mouseEntered(with event: NSEvent) { setHovered(true) }

    override func mouseExited(with event: NSEvent) { setHovered(false) }

    override func mouseDown(with event: NSEvent) {
        pressed = true
        refresh()
    }

    override func mouseDragged(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        guard inside != pressed else { return }
        pressed = inside
        refresh()
    }

    override func mouseUp(with event: NSEvent) {
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        pressed = false
        hovered = inside
        refresh()
        if inside { onPress?() }
    }

    private func setHovered(_ next: Bool) {
        guard next != hovered else { return }
        hovered = next
        if !next { pressed = false }
        refresh()
    }

    private func refresh() {
        plate.show(pressed ? .press : hovered ? .hover : .rest)
    }

    /// For a harness that has to prove the plate answers without a pointer to move.
    var plateLevel: PointerPlate.Level { plate.level }
}

/// A plate for a view that is already a control of its own — a borderless button, a picture, a
/// line of text that copies itself, a bordered pill — for as long as the pointer is over it, laid
/// so that nothing about the view or its layout changes to carry one.
///
/// A view with no ground of its own takes the plate behind it, in its superview, reaching a little
/// past its edges; a bordered button already has a ground, its bezel, so the plate lies over the
/// bezel inside it, shaped to it, under whatever the button draws on top. The watch is a single
/// tracking area on the view's visible rect, owned here rather than by the view, so any view can
/// take one without being subclassed. The press is read the only way a control's own tracking
/// leaves open: the button going down arrives through the window, and the button coming up is
/// known by the time the control has finished tracking it.
@MainActor
final class HoverPlate: NSResponder {
    enum Placement {
        case behind(NSEdgeInsets)
        case over
    }

    private weak var target: NSView?
    private let placement: Placement
    private let radius: CGFloat?
    private var plate: PointerPlate?
    private var pressWatch: Any?

    private init(target: NSView, placement: Placement, radius: CGFloat?) {
        self.target = target
        self.placement = placement
        self.radius = radius
        super.init()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    private static var key: UInt8 = 0

    /// - Parameter radius: the plate's corners; nil rounds it into a capsule, which is the shape a
    ///   bezel is on this system.
    static func attach(
        to view: NSView, placement: Placement = .behind(PointerPlate.inlineOutset),
        radius: CGFloat? = 6
    ) {
        guard objc_getAssociatedObject(view, &key) == nil else { return }
        let hover = HoverPlate(target: view, placement: placement, radius: radius)
        objc_setAssociatedObject(view, &key, hover, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        view.addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: hover, userInfo: nil))
    }

    static func isAttached(to view: NSView) -> Bool {
        objc_getAssociatedObject(view, &key) != nil
    }

    /// Whether the view has a plate up, for a harness that proves the claim without a pointer.
    static func isShowing(on view: NSView) -> Bool {
        (objc_getAssociatedObject(view, &key) as? HoverPlate)?.plate?.level ?? .rest != .rest
    }

    /// The same entry a pointer would make, for that harness.
    static func simulate(_ entered: Bool, on view: NSView) {
        guard let hover = objc_getAssociatedObject(view, &key) as? HoverPlate else { return }
        entered ? hover.enter() : hover.leave()
    }

    override func mouseEntered(with event: NSEvent) { enter() }

    override func mouseExited(with event: NSEvent) { leave() }

    private var targetIsLive: Bool {
        guard let target, target.window != nil, !target.isHiddenOrHasHiddenAncestor else {
            return false
        }
        return (target as? NSControl)?.isEnabled ?? true
    }

    /// Where the plate lives: beside the view in its superview, or inside the view itself.
    private var home: NSView? {
        switch placement {
        case .behind: return target?.superview
        case .over: return target
        }
    }

    private func enter() {
        guard targetIsLive, let target, let home else { return }
        let plate = self.plate ?? PointerPlate()
        if plate.superview !== home {
            plate.removeFromSuperview()
            switch placement {
            case .behind: home.addSubview(plate, positioned: .below, relativeTo: target)
            case .over: home.addSubview(plate, positioned: .below, relativeTo: nil)
            }
        }
        self.plate = plate
        follow()
        target.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(targetMoved), name: NSView.frameDidChangeNotification,
            object: target)
        plate.show(.hover)
        watchPress()
    }

    private func leave() {
        stopWatchingPress()
        if let target {
            NotificationCenter.default.removeObserver(
                self, name: NSView.frameDidChangeNotification, object: target)
        }
        plate?.show(.rest)
    }

    @objc private func targetMoved() {
        follow()
    }

    /// The plate stands where the view stands: `outset` past it behind a view with no ground, or
    /// exactly on the bezel of a bordered one, which is the button's frame less the margins AppKit
    /// keeps around a bezel for its shadow and focus ring.
    private func follow() {
        guard let target, let plate, let home, plate.superview === home else { return }
        let frame: NSRect
        switch placement {
        case .behind(let outset):
            frame = NSRect(
                x: target.frame.minX - outset.left,
                y: target.frame.minY - (home.isFlipped ? outset.top : outset.bottom),
                width: target.frame.width + outset.left + outset.right,
                height: target.frame.height + outset.top + outset.bottom)
        case .over:
            let margins = target.alignmentRectInsets
            frame = NSRect(
                x: margins.left, y: target.isFlipped ? margins.top : margins.bottom,
                width: target.bounds.width - margins.left - margins.right,
                height: target.bounds.height - margins.top - margins.bottom)
        }
        plate.frame = frame
        plate.radius = radius ?? frame.height / 2
    }

    /// Only while the pointer is over the view, so the window carries one watch at most.
    private func watchPress() {
        guard pressWatch == nil else { return }
        pressWatch = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            MainActor.assumeIsolated { self?.pressed(event) }
            return event
        }
    }

    private func stopWatchingPress() {
        if let pressWatch { NSEvent.removeMonitor(pressWatch) }
        pressWatch = nil
    }

    private func pressed(_ event: NSEvent) {
        guard let target, event.window === target.window, targetIsLive else { return }
        let point = target.convert(event.locationInWindow, from: nil)
        guard target.bounds.contains(point) else { return }
        plate?.show(.press)
        DispatchQueue.main.async { [weak self] in self?.released() }
    }

    /// Runs once the control's own tracking has let go of the button, which is the first moment
    /// this side can know it did.
    private func released() {
        guard let target, let window = target.window, NSEvent.pressedMouseButtons == 0 else {
            if NSEvent.pressedMouseButtons != 0 {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                    self?.released()
                }
            }
            return
        }
        let point = target.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        plate?.show(target.bounds.contains(point) && targetIsLive ? .hover : .rest)
    }
}

/// Every button in the app answers the pointer, without each one being told to.
///
/// Buttons are made in dozens of places — the composer's pills, the band's facts, a card's copy
/// link, the list's clear buttons — and a plate that depended on each of them remembering to ask
/// for one would be missing from exactly the one somebody reaches for next. So the window's own
/// mouse-moved stream is read once, app-wide: the first time the pointer rests over a button that
/// has no plate yet, it is given one and the plate comes up at once, and from then on the button's
/// own tracking area carries it, whether or not the app is in front. A bordered button takes the
/// plate over its bezel; a borderless one takes it behind, reaching past its glyph. Checkboxes,
/// radio buttons and pop-up menus keep the look the system gives them.
@MainActor
enum PointerSweep {
    private static var monitor: Any?
    private static let keyWatch = KeyWindowWatch()

    /// A window only hears the pointer move if it asks to, so every window that comes to the front
    /// asks.
    private final class KeyWindowWatch: NSObject {
        @objc func becameKey(_ note: Notification) {
            (note.object as? NSWindow)?.acceptsMouseMovedEvents = true
        }
    }

    static func install() {
        guard monitor == nil else { return }
        NotificationCenter.default.addObserver(
            keyWatch, selector: #selector(KeyWindowWatch.becameKey(_:)),
            name: NSWindow.didBecomeKeyNotification, object: nil)
        for window in NSApp.windows { window.acceptsMouseMovedEvents = true }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { event in
            MainActor.assumeIsolated { answer(event) }
            return event
        }
    }

    private static func answer(_ event: NSEvent) {
        guard let window = event.window, let root = window.contentView else { return }
        let point = root.convert(event.locationInWindow, from: nil)
        var candidate = root.hitTest(point)
        var depth = 0
        while let view = candidate, depth < 4 {
            if let button = view as? NSButton {
                offer(button)
                return
            }
            candidate = view.superview
            depth += 1
        }
    }

    private static func offer(_ button: NSButton) {
        guard wantsPlate(button), !HoverPlate.isAttached(to: button) else { return }
        HoverPlate.attach(
            to: button, placement: button.isBordered ? .over : .behind(PointerPlate.inlineOutset),
            radius: button.isBordered ? nil : 6)
        HoverPlate.simulate(true, on: button)
    }

    /// A checkbox, a radio button and a pop-up menu already tell a pointer what they are, in the
    /// system's own words, and a toolbar item already lights under it.
    private static func wantsPlate(_ button: NSButton) -> Bool {
        guard !(button is NSPopUpButton), button.bezelStyle != .toolbar else { return false }
        guard let cell = button.cell as? NSButtonCell else { return true }
        let stateful = cell.showsStateBy.contains(.contentsCellMask)
            && cell.highlightsBy.contains(.contentsCellMask)
        return !stateful
    }
}
