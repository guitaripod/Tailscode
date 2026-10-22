import Foundation
import Metal
import QuartzCore
import TailscodeCore

#if canImport(UIKit)
    import UIKit

    typealias NeuralPlatformView = UIView
#elseif canImport(AppKit)
    import AppKit

    typealias NeuralPlatformView = NSView
#endif

/// A main-queue callback's body. The Mac's runtime is asked for the main executor by
/// `assumeIsolated`, and that read segfaults on macOS 27.2; the client's own helper trusts the
/// queue it was handed instead. iOS keeps the ordinary check.
@inline(__always)
private func neuralOnMain(_ body: @MainActor () -> Void) {
    #if os(macOS)
        MainThread.call(body)
    #else
        MainActor.assumeIsolated { body() }
    #endif
}

/// Notification tokens that take themselves off their centres when the owner goes, so a view's
/// deinit has nothing to say about them. Only the main thread touches one.
private final class NeuralObservers: @unchecked Sendable {
    private var entries: [(center: NotificationCenter, token: NSObjectProtocol)] = []

    func add(_ token: NSObjectProtocol, in center: NotificationCenter) {
        entries.append((center, token))
    }

    func removeAll() {
        for entry in entries { entry.center.removeObserver(entry.token) }
        entries = []
    }

    deinit { removeAll() }
}

/// The head on screen: an opaque Metal layer for the interior, a transparent layer for the nodes
/// that a client fills, and a transparent Metal layer for the front, stacked in that order at the
/// design's 640 by 420 aspect and centred in the view's bounds.
///
/// The clock is the whole discipline. A display link exists only while the brain has something
/// that moves (`NeuralBrainModel/needsClock`), the view is in a window and showing, and the app is
/// active (on the Mac the window must also be unoccluded); every other moment it is invalidated,
/// and a settled brain is drawn once when it changes and costs nothing after. `apply` redraws
/// when what it was handed changes the picture; `setNeedsRender` redraws for what the view cannot
/// see change (a hover, a theme the client resolved, a size). The textures are held in the
/// process's ``NeuralMetalContext`` only while the view is in a window.
///
/// Every call is on the main thread. A client lays its node layers into ``nodeLayer`` in the
/// layer's own coordinates, converting from the design space with ``layerPoint(forDesign:)`` and
/// back with ``designPoint(forLayerPoint:)`` so the platform's vertical direction never reaches it,
/// and updates them from ``onTick`` so they move in the frame the head draws.
@MainActor
final class NeuralHeadView: NeuralPlatformView {
    /// The design's width over its height.
    static let designAspect: CGFloat = NeuralDesign.width / NeuralDesign.height

    /// Whether this machine can draw the head at all. A client that finds this false keeps the
    /// Lines style and the glyph.
    static var isSupported: Bool { NeuralMetalContext.shared?.isSupported == true }

    /// The height a head of this width wants.
    static func height(forWidth width: CGFloat) -> CGFloat { width / designAspect }

    /// The layer between the two Metal layers, the size of the picture, for the client's node
    /// shapes, wires and cards. Transparent; the view never draws into it.
    let nodeLayer = CALayer()

    /// Called on every tick of the clock, before the frame is drawn, with the clock's time in
    /// seconds, so a client moves its node layers in the same frame.
    var onTick: ((Double) -> Void)?

    /// Called once when the first picture has been presented, which is when a client's glyph
    /// stand-in may go.
    var onReady: (() -> Void)?

    /// True from the first presented picture on.
    private(set) var isReady = false

    /// How many pictures have been presented, and how many of them redrew only the eye, ear and
    /// ribs: what a harness reads to prove a settled head draws once and runs no clock.
    private(set) var framesDrawn = 0
    private(set) var eyeOnlyFrames = 0

    /// Whether the display link exists.
    var isClockRunning: Bool { link != nil }

    #if DEBUG
        /// A harness on a Mac whose screen is locked, where no window is ever active or visible,
        /// sets this to run the clock anyway.
        static var forcesActive = false
    #endif

    /// A client that parks the head (a pane that is not live, a row scrolled away) sets this; the
    /// clock stops and nothing is drawn until it is cleared.
    var isSuspended = false {
        didSet {
            guard isSuspended != oldValue else { return }
            reconsider()
        }
    }

    private let interiorLayer = CAMetalLayer()
    private let frontLayer = CAMetalLayer()
    private var renderer: NeuralHeadRenderer?
    private var model: NeuralBrainModel?
    private var palette: Palette?
    private var tableFace: NeuralFace?
    private var table: NeuralToneTable?
    private var reduceMotion = false
    private var dive = NeuralDive.none
    private var budget = TileGovernor.animation(level: .calm, reducedMotion: false)
    private var lastFrame: NeuralFrame?
    private var lastDive: NeuralDive?
    private var needsFullRender = true
    private var renderScheduled = false
    private var holdsContext = false
    private var texturesReady = false
    private var link: CADisplayLink?
    private var linkTempo: NeuralTempo?
    private var lastLayout = CGRect.zero
    private var lastDrawableSize = CGSize.zero
    private let observers = NeuralObservers()
    private let windowObservers = NeuralObservers()

    override init(frame: CGRect) {
        super.init(frame: frame)
        configureHost()
        configureLayers()
        observeEnvironment()
    }

    convenience init() { self.init(frame: .zero) }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    deinit {
        if holdsContext { NeuralMetalContext.shared?.release() }
    }

    /// Brings the view to this brain, palette and policy, and draws when that changes the
    /// picture. `reduceMotion` and `animationBudget` hold the head still: the clock stops after
    /// one last frame drawn with the state's movement taken out. `dive` is the zoom into a node.
    func apply(
        model: NeuralBrainModel, palette: Palette, reduceMotion: Bool = false,
        dive: NeuralDive = .none,
        animationBudget: AnimationBudget = TileGovernor.animation(
            level: .calm, reducedMotion: false)
    ) {
        let face = model.face
        if palette != self.palette || face != tableFace || table == nil {
            self.palette = palette
            tableFace = face
            table = NeuralToneTable(palette: palette, face: face)
            invalidatePicture()
        }
        self.model = model
        self.reduceMotion = reduceMotion
        self.dive = dive
        budget = animationBudget
        reconsider()
    }

    /// Redraws for something the view cannot see change itself: a hover the client resolved into
    /// the model, a theme, a size. The picture is rebuilt in full.
    func setNeedsRender() {
        invalidatePicture()
        reconsider()
    }

    /// The rectangle of the picture in the view's own coordinates: the largest 640 by 420 box
    /// that fits the bounds, centred.
    var contentRect: CGRect {
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return .zero }
        var width = size.width
        var height = width / Self.designAspect
        if height > size.height {
            height = size.height
            width = height * Self.designAspect
        }
        return CGRect(
            x: ((size.width - width) / 2).rounded(), y: ((size.height - height) / 2).rounded(),
            width: width, height: height)
    }

    /// Points of the view per unit of the design.
    var designScale: CGFloat {
        let rect = contentRect
        return rect.width > 0 ? rect.width / CGFloat(NeuralDesign.width) : 0
    }

    /// Where a design point is in ``nodeLayer``'s own coordinates, whichever way the platform's
    /// layers run.
    func layerPoint(forDesign point: NeuralPoint) -> CGPoint {
        let scale = designScale
        let x = CGFloat(point.x) * scale
        let y = CGFloat(point.y) * scale
        return CGPoint(x: x, y: layerRunsUp ? contentRect.height - y : y)
    }

    /// The design point under a point of ``nodeLayer``'s own coordinates.
    func designPoint(forLayerPoint point: CGPoint) -> NeuralPoint {
        let scale = max(designScale, 0.0001)
        let y = layerRunsUp ? contentRect.height - point.y : point.y
        return NeuralPoint(Double(point.x / scale), Double(y / scale))
    }

    /// The design point under a point of the view, for a pointer or a touch.
    func designPoint(forViewPoint point: CGPoint) -> NeuralPoint {
        let rect = contentRect
        let scale = max(designScale, 0.0001)
        let x = point.x - rect.minX
        let y = layerRunsUp ? rect.maxY - point.y : point.y - rect.minY
        return NeuralPoint(Double(x / scale), Double(y / scale))
    }

    #if canImport(UIKit)
        override func layoutSubviews() {
            super.layoutSubviews()
            layoutLayers()
        }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window == nil { stopLink() }
            layoutLayers()
            reconsider()
        }

        override var isHidden: Bool {
            didSet {
                guard isHidden != oldValue else { return }
                reconsider()
            }
        }
    #else
        override func layout() {
            super.layout()
            layoutLayers()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observeWindow(window)
            if window == nil { stopLink() }
            layoutLayers()
            reconsider()
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            layoutLayers()
        }

        override func viewDidHide() {
            super.viewDidHide()
            reconsider()
        }

        override func viewDidUnhide() {
            super.viewDidUnhide()
            reconsider()
        }
    #endif
}

extension NeuralHeadView {
    /// Whether the layers' own coordinates run bottom to top, as an AppKit view's do.
    private var layerRunsUp: Bool {
        #if canImport(UIKit)
            return false
        #else
            return !isFlipped
        #endif
    }

    private var effectiveReduceMotion: Bool {
        reduceMotion || systemReducesMotion || !budget.pulses || budget.tickCap <= 0
            || ProcessInfo.processInfo.isLowPowerModeEnabled
    }

    private func configureLayers() {
        for layer in [interiorLayer, frontLayer] {
            layer.pixelFormat = NeuralHeadRenderer.pixelFormat
            layer.framebufferOnly = true
            layer.maximumDrawableCount = 2
            layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
            layer.isHidden = true
            layer.device = NeuralMetalContext.shared?.device
        }
        interiorLayer.isOpaque = true
        frontLayer.isOpaque = false
        frontLayer.backgroundColor = nil
        interiorLayer.name = "neural interior"
        frontLayer.name = "neural front"
        nodeLayer.name = "neural nodes"
        hostLayer.addSublayer(interiorLayer)
        hostLayer.addSublayer(nodeLayer)
        hostLayer.addSublayer(frontLayer)
    }

    /// Everything that decides whether and how fast to draw, taken again: the clock first, since a
    /// frame drawn for a view whose clock is about to stop must be the held one.
    fileprivate func reconsider() {
        updateContextHold()
        updateClock()
        scheduleRender()
    }

    private func invalidatePicture() {
        needsFullRender = true
        renderer?.discardRetainedFront()
    }

    private var isRunnable: Bool {
        guard window != nil, !isSuspended, !isHiddenInHierarchy else { return false }
        return isAppActive
    }

    private var wantsContext: Bool { window != nil && model != nil && Self.isSupported }

    private func updateContextHold() {
        guard let context = NeuralMetalContext.shared else { return }
        if wantsContext && !holdsContext {
            holdsContext = true
            context.retain()
            context.prepare { [weak self] ready in
                self?.texturesArrived(ready)
            }
        } else if !wantsContext && holdsContext {
            holdsContext = false
            texturesReady = false
            context.release()
        }
    }

    private func texturesArrived(_ ready: Bool) {
        guard holdsContext else { return }
        texturesReady = ready
        if ready {
            if renderer == nil, let context = NeuralMetalContext.shared {
                renderer = NeuralHeadRenderer(context: context)
            }
            invalidatePicture()
            reconsider()
        }
    }

    private var desiredTempo: NeuralTempo {
        model?.tempo(reduceMotion: effectiveReduceMotion) ?? .stopped
    }

    private func updateClock() {
        let tempo = desiredTempo
        guard tempo != .stopped, isRunnable, texturesReady else {
            stopLink()
            return
        }
        if link == nil {
            let made = makeLink()
            made.add(to: .main, forMode: .common)
            link = made
            linkTempo = nil
        }
        if linkTempo != tempo, let link {
            link.preferredFrameRateRange = Self.frameRateRange(tempo: tempo, budget: budget)
            linkTempo = tempo
        }
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
        linkTempo = nil
    }

    /// The activity tempo, held under the budget's cap, or the display's own rate for a dive and a
    /// scrub.
    private static func frameRateRange(tempo: NeuralTempo, budget: AnimationBudget) -> CAFrameRateRange {
        guard tempo == .activity else { return .default }
        let cap = Float(min(ActivityTuning.frameRate, budget.tickCap))
        return CAFrameRateRange(
            minimum: min(Float(ActivityTuning.minimumFrameRate), cap), maximum: cap, preferred: cap)
    }

    @objc private func step(_ link: CADisplayLink) {
        guard isRunnable else {
            stopLink()
            return
        }
        let time = link.timestamp
        onTick?(time)
        render(time: time)
        updateClock()
    }

    /// A render is coalesced into the next turn of the run loop, because a client applies a model
    /// and then resizes and then restyles in one pass and the head should be drawn once; while the
    /// clock runs its next tick draws anyway.
    private func scheduleRender() {
        guard link == nil, !renderScheduled else { return }
        renderScheduled = true
        DispatchQueue.main.async { [weak self] in
            neuralOnMain {
                guard let self else { return }
                self.renderScheduled = false
                self.render(time: CACurrentMediaTime())
            }
        }
    }

    private func render(time: Double) {
        guard isRunnable, texturesReady, let renderer, let table, let model else {
            if !isRunnable { needsFullRender = true }
            return
        }
        let next = model.frame(time: time, reduceMotion: effectiveReduceMotion)
        let sameDive = lastDive == dive
        if !needsFullRender, sameDive, let lastFrame, next == lastFrame, next.settled { return }
        var scope = NeuralRenderScope.full
        if !needsFullRender, sameDive, let lastFrame,
            NeuralFrameDelta.changesOnlyEyeEarRibs(from: lastFrame, to: next)
        {
            scope = .eyeOnly
        }
        let drawn = renderer.draw(
            frame: next, table: table, time: time, dive: dive, scope: scope,
            retainFront: retainsFront(model), interior: interiorLayer, front: frontLayer)
        guard drawn else { return }
        framesDrawn += 1
        if renderer.lastDrawWasEyeOnly { eyeOnlyFrames += 1 }
        lastFrame = next
        lastDive = dive
        needsFullRender = false
        showLayers()
    }

    /// Whether the front is worth keeping in a texture of its own: the head is at rest and only a
    /// call's ear moves, so the frames that follow redraw the ear alone.
    private func retainsFront(_ model: NeuralBrainModel) -> Bool {
        guard !effectiveReduceMotion, model.mode == .live, !model.isDiving else { return false }
        let animatedState = model.shownState(now: 0).isAnimated(reduceMotion: false)
        return !animatedState && (model.meters.call?.motion.isAnimated ?? false)
    }

    private func showLayers() {
        guard interiorLayer.isHidden || frontLayer.isHidden else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        interiorLayer.isHidden = false
        frontLayer.isHidden = false
        CATransaction.commit()
        guard !isReady else { return }
        isReady = true
        onReady?()
    }

    fileprivate func layoutLayers() {
        let rect = contentRect
        guard rect.width > 0, rect.height > 0 else { return }
        let scale = backingScale
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for layer in [interiorLayer, frontLayer, nodeLayer] {
            layer.frame = rect
            layer.contentsScale = scale
        }
        let size = CGSize(
            width: max(1, (rect.width * scale).rounded()),
            height: max(1, (rect.height * scale).rounded()))
        if size != lastDrawableSize {
            interiorLayer.drawableSize = size
            frontLayer.drawableSize = size
        }
        CATransaction.commit()
        guard rect != lastLayout || size != lastDrawableSize else { return }
        lastLayout = rect
        lastDrawableSize = size
        invalidatePicture()
        reconsider()
    }

    private func observeEnvironment() {
        observe(.NSProcessInfoPowerStateDidChange)
        observePlatformEnvironment()
    }

    /// Takes a notification on the main queue and answers it on the main actor, whichever thread
    /// the system posted it from.
    fileprivate func observe(_ name: Notification.Name, center: NotificationCenter = .default) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
            neuralOnMain { self?.environmentChanged() }
        }
        observers.add(token, in: center)
    }

    fileprivate func environmentChanged() {
        invalidatePicture()
        reconsider()
    }
}

#if canImport(UIKit)
    extension NeuralHeadView {
        fileprivate var hostLayer: CALayer { layer }

        fileprivate var backingScale: CGFloat {
            let scale = window?.windowScene?.screen.scale ?? traitCollection.displayScale
            return scale > 0 ? scale : 2
        }

        fileprivate var systemReducesMotion: Bool { UIAccessibility.isReduceMotionEnabled }

        fileprivate var isAppActive: Bool {
            if let scene = window?.windowScene { return scene.activationState == .foregroundActive }
            return UIApplication.shared.applicationState == .active
        }

        fileprivate var isHiddenInHierarchy: Bool {
            var view: UIView? = self
            while let current = view {
                if current.isHidden || current.alpha < 0.01 { return true }
                view = current.superview
            }
            return false
        }

        fileprivate func configureHost() {
            isOpaque = false
            backgroundColor = .clear
            isUserInteractionEnabled = false
            clipsToBounds = false
        }

        fileprivate func makeLink() -> CADisplayLink {
            CADisplayLink(target: self, selector: #selector(step(_:)))
        }

        fileprivate func observePlatformEnvironment() {
            for name in [
                UIScene.didActivateNotification, UIScene.willDeactivateNotification,
                UIApplication.didBecomeActiveNotification,
                UIApplication.willResignActiveNotification,
                UIAccessibility.reduceMotionStatusDidChangeNotification,
            ] {
                observe(name)
            }
        }
    }
#else
    extension NeuralHeadView {
        fileprivate var hostLayer: CALayer {
            wantsLayer = true
            return layer ?? CALayer()
        }

        fileprivate var backingScale: CGFloat {
            window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        }

        fileprivate var systemReducesMotion: Bool {
            NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        }

        fileprivate var isAppActive: Bool {
            guard let window else { return false }
            #if DEBUG
                if Self.forcesActive { return true }
            #endif
            return NSApplication.shared.isActive && window.occlusionState.contains(.visible)
                && !window.isMiniaturized
        }

        fileprivate var isHiddenInHierarchy: Bool { isHiddenOrHasHiddenAncestor }

        fileprivate func configureHost() {
            wantsLayer = true
            layerContentsRedrawPolicy = .never
        }

        fileprivate func makeLink() -> CADisplayLink {
            displayLink(target: self, selector: #selector(step(_:)))
        }

        fileprivate func observePlatformEnvironment() {
            observe(NSApplication.didBecomeActiveNotification)
            observe(NSApplication.didResignActiveNotification)
            observe(
                NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                center: NSWorkspace.shared.notificationCenter)
        }

        fileprivate func observeWindow(_ window: NSWindow?) {
            windowObservers.removeAll()
            guard let window else { return }
            for name in [
                NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                NSWindow.didDeminiaturizeNotification,
            ] {
                let token = NotificationCenter.default.addObserver(
                    forName: name, object: window, queue: .main
                ) { [weak self] _ in
                    neuralOnMain { self?.environmentChanged() }
                }
                windowObservers.add(token, in: .default)
            }
        }
    }
#endif
