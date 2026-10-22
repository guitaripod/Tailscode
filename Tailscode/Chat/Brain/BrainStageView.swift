import TailscodeCore
import UIKit

/// Where the head rings: the step, the node that draws it (a "+7" node for a member of a ganglion),
/// and the number its callout shows beside the ring.
struct BrainRing: Equatable {
    let stepID: String
    let nodeID: String
    let calloutNumber: Int

    init(_ ring: NeuralBrowse.Ring) {
        stepID = ring.stepID
        nodeID = ring.nodeID
        calloutNumber = ring.calloutNumber
    }

    init(stepID: String, nodeID: String, calloutNumber: Int) {
        self.stepID = stepID
        self.nodeID = nodeID
        self.calloutNumber = calloutNumber
    }
}

/// The head of an open brain, as a map: the picture drawn by the shared Metal renderer and cropped
/// to the head's own bounds, the node field laid between its interior and its glass, the ring on the
/// step under the cursor, the dive into a zone, and the touches and pointer that drive them.
///
/// The model lives in the `BrainStore`; this view only reads it. It says what the person did as
/// `NeuralBrowse` actions through `perform`, and is handed the ring, the dimming and the model back.
/// The head's display link runs only while the model has something that moves, so a settled brain,
/// the common case, draws once and costs nothing; `onTick` is called from that link, which is the
/// only clock replay and the dive have.
@MainActor
final class BrainStageView: UIView {
    private struct Dive {
        let from: CGFloat
        let to: CGFloat
        let start: Double
        let duration: Double
    }

    let head = NeuralHeadView()
    let field: BrainNodeField
    private let pad = UIView()
    private weak var store: BrainStore?
    private(set) var turnID = ""
    private var ink: BrainInk
    private var dive: Dive?
    private var diveScale: CGFloat = 1
    private(set) var divedZone: NeuralZone?
    private var lastTap: (id: String, at: CFTimeInterval)?
    private var elements: [UIAccessibilityElement] = []
    private var elementsKey = ""
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
    private var parked = false
    private var lastDesignScale: CGFloat = 0
    private let backSwipe = UISwipeGestureRecognizer()

    /// What the stage asks of the brain it belongs to.
    var perform: ((NeuralBrowse.Action) -> Void)?
    /// Called after a tick moved a replay or a dive: the footer reads the model again.
    var onChange: ((NeuralBrainModel, Double) -> Void)?
    /// Called for a double tap on a delegate node, with the step's id.
    var onRevealAgent: ((String) -> Void)?
    /// The dive into a zone began or ended.
    var onDive: ((NeuralZone?) -> Void)?
    /// A menu for a node's step was asked for with a long press.
    var menuItems: ((String) -> [UIMenuElement])?
    /// The first picture has been presented.
    var onReady: (() -> Void)?

    override init(frame: CGRect) {
        ink = BrainInk(
            palette: BrainPalette.palette(for: UITraitCollection.current), face: .unknown)
        field = BrainNodeField(ink: ink)
        super.init(frame: frame)
        registerForTraitChanges([UITraitUserInterfaceStyle.self, ThemeIdentityTrait.self]) { (view: BrainStageView, _) in view.traitsChanged() }
        clipsToBounds = true
        addSubview(head)
        head.nodeLayer.addSublayer(field.root)
        head.onTick = { [weak self] time in self?.tick(time) }
        head.onReady = { [weak self] in self?.onReady?() }
        pad.backgroundColor = .clear
        pad.isAccessibilityElement = false
        addSubview(pad)
        installGestures()
        observe()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    deinit {
        for token in observers { NotificationCenter.default.removeObserver(token) }
    }

    /// Points the stage at a turn's brain.
    func configure(store newStore: BrainStore, turnID newID: String) {
        if newID != turnID { resetInteraction() }
        store = newStore
        turnID = newID
        refresh()
    }

    /// Brings the head and the nodes to the model as it stands.
    func refresh(time: Double = CACurrentMediaTime()) {
        guard let model = store?.model(for: turnID) else { return }
        let palette = BrainPalette.palette(for: traitCollection)
        if palette != ink.palette || model.face != ink.face {
            ink = BrainInk(palette: palette, face: model.face)
            field.recolor(ink)
        }
        backgroundColor = Self.canvasColor(palette)
        head.apply(model: model, palette: palette, reduceMotion: reduceMotion, dive: currentDive)
        field.refresh(model: model, time: time, reduceMotion: reduceMotion)
    }

    /// The palette's own canvas, which the head is baked on, so the stage reads as one plate even
    /// where the screen's ground is the platform's.
    private static func canvasColor(_ palette: Palette) -> UIColor {
        guard let channels = Contrast.channels(palette.canvas) else { return .clear }
        return UIColor(red: channels.red, green: channels.green, blue: channels.blue, alpha: 1)
    }

    private var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }

    /// The rectangle of the stage in which the head's trimmed picture sits, and where the whole
    /// design space then lands: the head is laid out whole and the stage crops it.
    override func layoutSubviews() {
        super.layoutSubviews()
        let crop = NeuralStageMetrics.designCrop
        let scale = bounds.width / CGFloat(crop.width)
        head.transform = .identity
        head.frame = CGRect(
            x: -CGFloat(crop.x) * scale, y: 0, width: CGFloat(NeuralDesign.width) * scale,
            height: CGFloat(NeuralDesign.height) * scale)
        head.layoutIfNeeded()
        applyDiveTransform()
        pad.frame = bounds
        let screen = window?.windowScene?.screen.scale ?? traitCollection.displayScale
        field.layout(scale: head.designScale, contentsScale: max(1, screen) * max(1, diveScale))
        if abs(lastDesignScale - head.designScale) > 0.001 {
            lastDesignScale = head.designScale
            if let model = store?.model(for: turnID) {
                field.refresh(model: model, time: CACurrentMediaTime(), reduceMotion: reduceMotion)
                field.setRing(ring, model: model)
            }
        }
    }

    private func traitsChanged() {
        refresh()
    }

    private func observe() {
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(
                forName: UIAccessibility.reduceMotionStatusDidChangeNotification, object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        observers.append(
            center.addObserver(
                forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.park() }
            })
        observers.append(
            center.addObserver(
                forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.unpark() }
            })
    }

    /// The textures are the only memory the head costs, and they are held while the head is in a
    /// window. A backgrounded app lets go of them by taking the head out of its window, and puts
    /// it back on returning.
    private func park() {
        guard !parked, head.superview != nil else { return }
        parked = true
        head.removeFromSuperview()
    }

    private func unpark() {
        guard parked else { return }
        parked = false
        insertSubview(head, at: 0)
        setNeedsLayout()
        refresh()
    }

    /// Lets the head draw and run its clock, or holds it still: a row scrolled out of sight, or a
    /// stage waiting under a move.
    func setSuspended(_ value: Bool) {
        head.isSuspended = value
    }

    /// Drops everything the person did to the last brain: a dive, a ring.
    private func resetInteraction() {
        dive = nil
        diveScale = 1
        divedZone = nil
        backSwipe.isEnabled = false
        head.transform = .identity
        lastTap = nil
        elements = []
        elementsKey = ""
        ring = nil
        field.resetFired()
    }

    private(set) var ring: BrainRing?

    func setRing(_ value: BrainRing?) {
        ring = value
        guard let model = store?.model(for: turnID) else { return }
        field.setRing(value, model: model)
    }

    func setDimmed(_ ids: Set<String>) {
        guard field.dimmed != ids else { return }
        field.dimmed = ids
        guard let model = store?.model(for: turnID) else { return }
        field.refresh(model: model, time: CACurrentMediaTime(), reduceMotion: reduceMotion)
    }

    private func tick(_ time: Double) {
        advanceDive(time)
        guard let store, let model = store.model(for: turnID), model.mode != .live else { return }
        if model.replayDone(now: time) {
            store.mutate(turnID) { $0.stopReplay() }
            refresh(time: time)
            onChange?(store.model(for: turnID) ?? model, time)
            return
        }
        if field.newlyLit(in: model, time: time) > 0 { Theme.Haptics.step() }
        field.refresh(model: model, time: time, reduceMotion: reduceMotion)
        onChange?(model, time)
    }

    private var currentDive: NeuralDive {
        guard diveScale != 1 || dive != nil else { return .none }
        let center = (divedZone ?? .think).center
        let s = diveScale
        return NeuralDive(
            center: NeuralPoint(center.x / NeuralDesign.width, center.y / NeuralDesign.height),
            chassisScale: Float(1 + (s - 1) * 1.7), glassScale: Float(1 + (s - 1) * 1.25),
            fade: Float(min(max(1 - (s - 1.5) / 1.1, 0), 1)))
    }

    var isDived: Bool { divedZone != nil }

    func dive(to zone: NeuralZone) {
        guard store?.model(for: turnID) != nil else { return }
        backSwipe.isEnabled = true
        divedZone = zone
        onDive?(zone)
        animateDive(to: zone == .say ? 3.4 : 2.6)
    }

    func leaveDive() {
        guard divedZone != nil else { return }
        animateDive(to: 1)
        onDive?(nil)
    }

    private func animateDive(to target: CGFloat) {
        let quick = reduceMotion
        dive = Dive(
            from: diveScale, to: target, start: CACurrentMediaTime(),
            duration: quick ? 0.001 : (target == 1 ? 0.42 : 0.52))
        store?.mutate(turnID) { $0.setDiving(true) }
        refresh()
    }

    private func advanceDive(_ time: Double) {
        guard let running = dive else { return }
        let t = min(max((time - running.start) / running.duration, 0), 1)
        let eased = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        diveScale = running.from + (running.to - running.from) * CGFloat(eased)
        applyDiveTransform()
        if let model = store?.model(for: turnID) {
            head.apply(model: model, palette: ink.palette, reduceMotion: reduceMotion, dive: currentDive)
        }
        guard t >= 1 else { return }
        dive = nil
        store?.mutate(turnID) { $0.setDiving(false) }
        finishDive()
    }

    private func finishDive() {
        let screen = window?.windowScene?.screen.scale ?? traitCollection.displayScale
        field.setContentsScale(max(1, screen) * max(1, diveScale))
        if diveScale <= 1.0001 {
            diveScale = 1
            divedZone = nil
            backSwipe.isEnabled = false
            head.transform = .identity
        }
        refresh()
    }

    private func applyDiveTransform() {
        guard let zone = divedZone, diveScale != 1 else {
            head.transform = .identity
            return
        }
        let anchor = head.layerPoint(forDesign: zone.center)
        let origin = head.contentRect.origin
        let target = CGPoint(x: anchor.x + origin.x + head.frame.minX, y: anchor.y + origin.y + head.frame.minY)
        let centre = head.center
        let s = diveScale
        let end: CGFloat = zone == .say ? 3.4 : 2.6
        let progress = min(max((s - 1) / (end - 1), 0), 1)
        let focus = CGPoint(x: bounds.midX, y: bounds.height * 0.42)
        head.transform = CGAffineTransform(
            translationX: (1 - s) * (target.x - centre.x) + progress * (focus.x - target.x),
            y: (1 - s) * (target.y - centre.y) + progress * (focus.y - target.y)
        ).scaledBy(x: s, y: s)
    }

    private func installGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
        backSwipe.addTarget(self, action: #selector(swipedBack))
        backSwipe.direction = .right
        backSwipe.delegate = self
        backSwipe.isEnabled = false
        for recognizer in [tap, hover, backSwipe] { pad.addGestureRecognizer(recognizer) }
        pad.addInteraction(UIContextMenuInteraction(delegate: self))
    }

    private func designPoint(_ location: CGPoint) -> NeuralPoint {
        head.designPoint(forViewPoint: pad.convert(location, to: head))
    }

    private var slop: Double {
        22 / Double(max(head.designScale * max(diveScale, 1), 0.05))
    }

    private func node(at location: CGPoint) -> String? {
        store?.model(for: turnID)?.hit(at: designPoint(location), slop: slop)
    }

    @objc private func tapped(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, let model = store?.model(for: turnID) else { return }
        let location = gesture.location(in: pad)
        let point = designPoint(location)
        let node = model.hit(at: point, slop: slop)
        if node == nil, divedZone == nil,
            let zone = field.labelHit(at: CGPoint(x: point.x, y: point.y)),
            model.steps.contains(where: { $0.zone == zone })
        {
            Theme.Haptics.selection()
            dive(to: zone)
            return
        }
        guard let id = node else {
            if model.pinnedStep != nil { perform?(.key(.escape)) }
            return
        }
        let now = CACurrentMediaTime()
        if let last = lastTap, last.id == id, now - last.at < 0.4,
            model.step(id: id)?.zone == .delegate
        {
            lastTap = nil
            onRevealAgent?(id)
            return
        }
        let double = lastTap.map { $0.id == id && now - $0.at < 0.4 } ?? false
        lastTap = (id, now)
        Theme.Haptics.selection()
        perform?(.clickNode(id, double: double))
    }

    @objc private func hovered(_ gesture: UIHoverGestureRecognizer) {
        switch gesture.state {
        case .began, .changed:
            let id = node(at: gesture.location(in: pad))
            perform?(id.map { .hover($0) } ?? .hoverLeft)
        default:
            perform?(.hoverLeft)
        }
    }

    @objc private func swipedBack() { leaveDive() }

    override var isAccessibilityElement: Bool {
        get { false }
        set {}
    }

    override var accessibilityElements: [Any]? {
        get { accessibilityList() }
        set {}
    }

    override func accessibilityPerformEscape() -> Bool {
        guard divedZone != nil else { return false }
        leaveDive()
        return true
    }

    /// The summary of the turn, one element a step to select, and one a zone to dive into. They
    /// are made again whenever the layout, the size or the zoom they were measured against changes.
    private func accessibilityList() -> [Any] {
        guard let model = store?.model(for: turnID) else { return [] }
        let key = "\(model.revision)|\(Int(bounds.width))|\(Int(bounds.height))|\(diveScale)"
        if key != elementsKey {
            elementsKey = key
            elements = makeElements(model)
        }
        return elements
    }

    private func makeElements(_ model: NeuralBrainModel) -> [UIAccessibilityElement] {
        var out: [UIAccessibilityElement] = []
        let summary = UIAccessibilityElement(accessibilityContainer: self)
        summary.accessibilityLabel = model.spoken
        summary.accessibilityHint = NeuralReading.stageLabel
        summary.accessibilityTraits = .staticText
        summary.accessibilityFrameInContainerSpace = bounds
        out.append(summary)
        let total = model.steps.count
        let radius = max(22, CGFloat(NeuralDesign.nodeRadius) * head.designScale * max(diveScale, 1))
        for step in model.steps {
            guard let point = model.point(of: model.layout.representative(of: step.id)) else { continue }
            let centre = convert(layerCentre(point), from: head)
            let element = BrainStepElement(container: self, stepID: step.id) { [weak self] id in
                self?.perform?(.clickNode(id, double: false))
            }
            element.accessibilityLabel = NeuralReading.announcement(for: step, of: total)
            element.accessibilityTraits = .button
            element.accessibilityFrameInContainerSpace = CGRect(
                x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2)
            out.append(element)
        }
        for zone in NeuralZone.allCases where model.steps.contains(where: { $0.zone == zone }) {
            let element = BrainZoneElement(container: self, zone: zone) { [weak self] zone in
                self?.dive(to: zone)
            }
            element.accessibilityLabel = Localized.text("Dive into %@", zone.displayLabel)
            element.accessibilityTraits = .button
            let rect = field.zoneLabelRects[zone] ?? .zero
            let corner = head.layerPoint(forDesign: NeuralPoint(rect.minX, rect.minY))
            let origin = head.contentRect.origin
            let topLeft = convert(CGPoint(x: corner.x + origin.x, y: corner.y + origin.y), from: head)
            element.accessibilityFrameInContainerSpace = CGRect(
                x: topLeft.x, y: topLeft.y, width: max(44, rect.width * head.designScale),
                height: max(44, rect.height * head.designScale))
            out.append(element)
        }
        return out
    }

    /// The accessibility element of a step's node, for the rotor that walks steps.
    func element(forStep id: String) -> UIAccessibilityElement? {
        (accessibilityList() as? [UIAccessibilityElement])?.first {
            ($0 as? BrainStepElement)?.stepID == id
        }
    }

    /// The step an accessibility element stands for, when it is a node's.
    func stepID(of element: Any?) -> String? { (element as? BrainStepElement)?.stepID }

    private func layerCentre(_ point: NeuralPoint) -> CGPoint {
        let local = head.layerPoint(forDesign: point)
        let origin = head.contentRect.origin
        return CGPoint(x: local.x + origin.x, y: local.y + origin.y)
    }

    /// The point of the stage a step's node is at, for the leader that leaves it.
    func point(of step: String) -> CGPoint? {
        guard let model = store?.model(for: turnID),
            let design = model.point(of: model.layout.representative(of: step))
        else { return nil }
        return convert(layerCentre(design), from: head)
    }

    #if DEBUG
        /// What `TAILSCODE_NEURAL_WALK` does to the stage in place of a finger: dive into the zone
        /// with this name.
        func walk(dive zoneName: String?) {
            if let zoneName, let zone = NeuralZone.allCases.first(where: { String(describing: $0) == zoneName }) {
                dive(to: zone)
            }
        }
    #endif
}

extension BrainStageView: UIGestureRecognizerDelegate {
    /// The swipe that leaves a dive is the stage's only while a dive is open, and never within a
    /// thumb of either screen edge: that strip belongs to the navigation controller's interactive
    /// pop, which a recogniser of ours must neither delay nor win against.
    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === backSwipe, divedZone != nil else { return false }
        guard let window else { return true }
        return Self.swipeMayStart(atX: touch.location(in: window).x, windowWidth: window.bounds.width)
    }

    private static let systemEdge: CGFloat = 40

    /// Whether a swipe starting at `x` of a window `windowWidth` wide is the stage's to take.
    static func swipeMayStart(atX x: CGFloat, windowWidth: CGFloat) -> Bool {
        min(x, windowWidth - x) > systemEdge
    }

    /// Whether the stage holds a swipe recogniser at all right now: only while a dive is open.
    var holdsSwipe: Bool { backSwipe.isEnabled }
}

extension BrainStageView: UIContextMenuInteractionDelegate {
    func contextMenuInteraction(
        _ interaction: UIContextMenuInteraction, configurationForMenuAtLocation location: CGPoint
    ) -> UIContextMenuConfiguration? {
        guard let id = node(at: location), let menuItems else { return nil }
        let items = menuItems(id)
        guard !items.isEmpty else { return nil }
        return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in
            UIMenu(children: items)
        }
    }
}

private final class BrainStepElement: UIAccessibilityElement {
    let stepID: String
    private let activate: (String) -> Void

    init(container: Any, stepID: String, activate: @escaping (String) -> Void) {
        self.stepID = stepID
        self.activate = activate
        super.init(accessibilityContainer: container)
    }

    override func accessibilityActivate() -> Bool {
        activate(stepID)
        return true
    }
}

private final class BrainZoneElement: UIAccessibilityElement {
    let zone: NeuralZone
    private let activate: (NeuralZone) -> Void

    init(container: Any, zone: NeuralZone, activate: @escaping (NeuralZone) -> Void) {
        self.zone = zone
        self.activate = activate
        super.init(accessibilityContainer: container)
    }

    override func accessibilityActivate() -> Bool {
        activate(zone)
        return true
    }
}
