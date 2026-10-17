import TailscodeCore
import UIKit

/// The open brain: the head drawn by the shared Metal renderer, the node field laid between its
/// interior and its glass, the card of the node being pointed at, the dive into a zone, and the
/// touches that drive them.
///
/// The model lives in the `BrainStore`; this view only reads it, mutates it through the store and
/// hands what it reads to the head and the field. The head's display link runs only while the
/// model has something that moves, so a settled brain, the common case, draws once and costs
/// nothing; this view's `onTick` is called from that link, which is the only clock replay and the
/// dive have.
@MainActor
final class BrainStageView: UIView {
    private struct Dive {
        let from: CGFloat
        let to: CGFloat
        let start: Double
        let duration: Double
    }

    let head = NeuralHeadView()
    private let field: BrainNodeField
    private let pad = UIView()
    private let card = BrainCardView()
    private let zoneList = BrainZoneList()
    private weak var store: BrainStore?
    private(set) var turnID = ""
    private var ink: BrainInk
    private var dive: Dive?
    private var diveScale: CGFloat = 1
    private var divedZone: NeuralZone?
    private var lastTap: (id: String, at: CFTimeInterval)?
    private var elements: [UIAccessibilityElement] = []
    private var elementsKey = ""
    nonisolated(unsafe) private var observers: [NSObjectProtocol] = []
    private var parked = false

    /// Called after the model changed or a tick moved a replay: the footer reads the model again.
    var onChange: ((NeuralBrainModel, Double) -> Void)?

    /// Called for a double tap on a delegate node, with the step's id: the transcript scrolls to
    /// the subagent's own card.
    var onRevealAgent: ((String) -> Void)?

    override init(frame: CGRect) {
        ink = BrainInk(
            palette: BrainPalette.palette(for: UITraitCollection.current), face: .unknown)
        field = BrainNodeField(ink: ink)
        super.init(frame: frame)
        clipsToBounds = true
        layer.cornerRadius = Theme.Radius.card
        layer.cornerCurve = .continuous
        addSubview(head)
        head.nodeLayer.addSublayer(field.root)
        head.onTick = { [weak self] time in self?.tick(time) }
        pad.backgroundColor = .clear
        pad.isAccessibilityElement = false
        addSubview(pad)
        addSubview(card)
        addSubview(zoneList)
        zoneList.onBack = { [weak self] in self?.leaveDive() }
        zoneList.onPick = { [weak self] id in self?.pick(id) }
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
        head.apply(
            model: model, palette: palette, reduceMotion: reduceMotion, dive: currentDive)
        field.refresh(model: model, time: time, reduceMotion: reduceMotion)
        updateCard(model)
        onChange?(model, time)
    }

    private var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }

    #if DEBUG
        /// What `TAILSCODE_NEURAL_WALK` does to the stage in place of a finger: pin the step with
        /// this one-based number, hover it, or dive into the zone with this name.
        func walk(pin number: Int?, hover: Int?, dive zoneName: String?) {
            guard let model = store?.model(for: turnID) else { return }
            if let number, model.steps.indices.contains(number - 1) {
                store?.mutate(turnID) { $0.togglePin(model.steps[number - 1].id) }
                refresh()
            }
            if let hover, model.steps.indices.contains(hover - 1) {
                store?.mutate(turnID) { $0.setHover(model.steps[hover - 1].id) }
                refresh()
            }
            if let zoneName, let zone = NeuralZone.allCases.first(where: { String(describing: $0) == zoneName }) {
                self.dive(to: zone)
            }
        }
    #endif

    override func layoutSubviews() {
        super.layoutSubviews()
        head.bounds = CGRect(origin: .zero, size: bounds.size)
        head.center = CGPoint(x: bounds.midX, y: bounds.midY)
        head.layoutIfNeeded()
        pad.frame = bounds
        let screen = window?.windowScene?.screen.scale ?? traitCollection.displayScale
        field.layout(
            scale: head.designScale, contentsScale: max(1, screen) * max(1, diveScale))
        let height = min(bounds.height * 0.56, 190)
        zoneList.frame = CGRect(
            x: 0, y: bounds.height - height, width: bounds.width, height: height)
        if let model = store?.model(for: turnID) { updateCard(model) }
    }

    override func traitCollectionDidChange(_ previous: UITraitCollection?) {
        super.traitCollectionDidChange(previous)
        guard previous?.userInterfaceStyle != traitCollection.userInterfaceStyle
            || previous?.themeID != traitCollection.themeID
        else { return }
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

    /// Drops everything the person did to the last brain: a pin, a dive, a card.
    private func resetInteraction() {
        dive = nil
        diveScale = 1
        divedZone = nil
        head.transform = .identity
        zoneList.dismiss()
        card.isHidden = true
        lastTap = nil
        elements = []
        elementsKey = ""
        field.resetFired()
    }


    private func tick(_ time: Double) {
        advanceDive(time)
        guard let store, let model = store.model(for: turnID), model.mode != .live else { return }
        if model.replayDone(now: time) {
            store.mutate(turnID) { $0.stopReplay() }
            refresh(time: time)
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
        divedZone = zone
        zoneList.dismiss()
        animateDive(to: zone == .say ? 3.4 : 2.6)
    }

    func leaveDive() {
        guard divedZone != nil else { return }
        zoneList.dismiss()
        animateDive(to: 1)
    }

    private func animateDive(to target: CGFloat) {
        let quick = reduceMotion
        dive = Dive(
            from: diveScale, to: target, start: CACurrentMediaTime(),
            duration: quick ? 0.001 : (target == 1 ? 0.42 : 0.52))
        store?.mutate(turnID) { $0.setDiving(true) }
        card.isHidden = true
        refresh()
    }

    private func advanceDive(_ time: Double) {
        guard let running = dive else { return }
        let t = min(max((time - running.start) / running.duration, 0), 1)
        let eased = t < 0.5 ? 4 * t * t * t : 1 - pow(-2 * t + 2, 3) / 2
        diveScale = running.from + (running.to - running.from) * CGFloat(eased)
        applyDiveTransform()
        if let model = store?.model(for: turnID) {
            head.apply(
                model: model, palette: ink.palette, reduceMotion: reduceMotion,
                dive: currentDive)
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
            head.transform = .identity
        } else if let zone = divedZone, let model = store?.model(for: turnID) {
            zoneList.show(
                zone: zone, steps: model.steps.filter { $0.zone == zone }, ink: ink)
            UIAccessibility.post(notification: .layoutChanged, argument: zoneList)
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
        let target = CGPoint(x: anchor.x + origin.x, y: anchor.y + origin.y)
        let centre = CGPoint(x: head.bounds.midX, y: head.bounds.midY)
        let s = diveScale
        let end: CGFloat = zone == .say ? 3.4 : 2.6
        let progress = min(max((s - 1) / (end - 1), 0), 1)
        let focus = CGPoint(x: bounds.midX, y: bounds.height * 0.32)
        head.transform = CGAffineTransform(
            translationX: (1 - s) * (target.x - centre.x) + progress * (focus.x - target.x),
            y: (1 - s) * (target.y - centre.y) + progress * (focus.y - target.y)
        ).scaledBy(x: s, y: s)
    }


    private func installGestures() {
        let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
        let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
        hold.minimumPressDuration = 0.28
        hold.allowableMovement = 12
        let hover = UIHoverGestureRecognizer(target: self, action: #selector(hovered(_:)))
        let back = UISwipeGestureRecognizer(target: self, action: #selector(swipedBack))
        back.direction = .right
        for recognizer in [tap, hold, hover, back] { pad.addGestureRecognizer(recognizer) }
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
        if divedZone == nil, let zone = field.labelHit(at: CGPoint(x: point.x, y: point.y)),
            model.steps.contains(where: { $0.zone == zone })
        {
            Theme.Haptics.selection()
            dive(to: zone)
            return
        }
        guard let id = model.hit(at: point, slop: slop) else {
            if model.hasSelection {
                store?.mutate(turnID) { $0.clearSelection() }
                refresh()
            }
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
        lastTap = (id, now)
        pick(id)
    }

    private func pick(_ id: String) {
        Theme.Haptics.selection()
        store?.mutate(turnID) { $0.togglePin(id) }
        refresh()
    }

    @objc private func held(_ gesture: UILongPressGestureRecognizer) {
        switch gesture.state {
        case .began, .changed:
            hover(node(at: gesture.location(in: pad)))
        default:
            hover(nil)
        }
    }

    @objc private func hovered(_ gesture: UIHoverGestureRecognizer) {
        switch gesture.state {
        case .began, .changed:
            hover(node(at: gesture.location(in: pad)))
        default:
            hover(nil)
        }
    }

    private func hover(_ id: String?) {
        guard let store, let model = store.model(for: turnID), model.hovered != id else { return }
        store.mutate(turnID) { $0.setHover(id) }
        refresh()
    }

    @objc private func swipedBack() { leaveDive() }


    private func updateCard(_ model: NeuralBrainModel) {
        guard dive == nil, let id = model.selected, let words = model.card,
            let point = model.point(of: id)
        else {
            card.isHidden = true
            return
        }
        card.show(words, ink: ink)
        let local = head.layerPoint(forDesign: point)
        let origin = head.contentRect.origin
        let anchor = head.convert(CGPoint(x: local.x + origin.x, y: local.y + origin.y), to: self)
        card.isHidden = false
        card.place(
            pointingAt: anchor, in: bounds,
            nodeRadius: CGFloat(NeuralDesign.nodeRadius) * head.designScale * max(diveScale, 1))
    }


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

    /// The summary of the turn, one element a step to pin, and one a zone to dive into. They are
    /// made again whenever the layout, the size or the zoom they were measured against changes.
    private func accessibilityList() -> [Any] {
        guard let model = store?.model(for: turnID) else { return [] }
        let key = "\(model.revision)|\(Int(bounds.width))|\(Int(bounds.height))|\(diveScale)"
        if key != elementsKey {
            elementsKey = key
            elements = makeElements(model)
        }
        return elements + (zoneList.isHidden ? [] : [zoneList, card])
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
            let local = head.layerPoint(forDesign: point)
            let origin = head.contentRect.origin
            let centre = head.convert(
                CGPoint(x: local.x + origin.x, y: local.y + origin.y), to: self)
            let element = BrainStepElement(container: self, stepID: step.id) { [weak self] id in
                self?.pick(id)
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
            element.accessibilityLabel = Localized.text("Dive into %@", zone.label)
            element.accessibilityTraits = .button
            let rect = field.zoneLabelRects[zone] ?? .zero
            let corner = head.layerPoint(forDesign: NeuralPoint(rect.minX, rect.minY))
            let origin = head.contentRect.origin
            let topLeft = head.convert(
                CGPoint(x: corner.x + origin.x, y: corner.y + origin.y), to: self)
            element.accessibilityFrameInContainerSpace = CGRect(
                x: topLeft.x, y: topLeft.y, width: max(44, rect.width * head.designScale),
                height: max(44, rect.height * head.designScale))
            out.append(element)
        }
        return out
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
