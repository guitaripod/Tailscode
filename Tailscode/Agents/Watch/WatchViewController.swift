import MidgarCore
import QuartzCore
import TailscodeCore
import TailscodeMetal
import UIKit

/// The Agents wall on an iPhone or an iPad: every agent as one tile on a dark ground drawn by Metal,
/// the words laid over it in plain UIKit from Core's layout, and nothing to learn. It is a viewer:
/// it holds the tower only while it is on screen in a foreground scene, draws no faster than the
/// frame cap says, and never opens by itself.
@MainActor
final class WatchViewController: UIViewController {
    enum Source {
        case live
        case demo(String)
    }

    enum Reason { case layout, board, tick, hour, style }

    let source: Source
    let standalone: Bool
    let feed: WatchFeed
    let stage: WatchStage
    let metalView: WallMetalView?
    let wordsView = WatchWordsView()
    let controls = WatchControlsView()

    var style: WallStyle
    var actions: [String: WatchAction] = [:]
    var batteryHeld = false
    var gateInFlight = false
    var isForeground = true
    var isWatchingBattery = false
    var drewStill = false
    var controlsPinned = false
    var hasRead = false
    var touch: Touch?
    var holdTask: Task<Void, Never>?
    var armTask: Task<Void, Never>?
    var controlsTask: Task<Void, Never>?
    var peekTask: Task<Void, Never>?
    var lastPeekTouch = Date()
    var lastWordsTarget: CGFloat = 1
    var lastApplied: Applied?
    weak var peek: AgentPeekViewController?
    weak var styleSheet: WatchStyleViewController?

    struct Touch {
        var target: WatchTarget?
        var capsuleTile: String?
        var start: TimeInterval
        var point: CGPoint
        var didHold = false
    }

    struct Applied {
        var wall: AgentWall
        var layout: WallLayout
        var palette: WallPalette
        var style: WallStyle
        var scale: WatchScale
        var actions: [String: WatchAction]
        var batteryHeld: Bool
    }

    #if DEBUG
        var demoTask: Task<Void, Never>?
    #endif

    init(source: Source = .live, standalone: Bool = false) {
        self.source = source
        self.standalone = standalone
        switch source {
        case .live:
            feed = WatchFeed(origin: .live)
        case .demo(let name):
            let now = Date()
            let scenes = AgentDemo.wallScenes(now: now)
            let wall = (scenes.first { $0.name == name } ?? scenes[0]).wall
            feed = WatchFeed(origin: .demo(wall, AgentDemo.hour(now: now)))
        }
        let style = WatchStyleStore.current
        self.style = style
        stage = WatchStage(style: style)
        metalView = WallMetalView.isSupported ? WallMetalView(frame: .zero) : nil
        super.init(nibName: nil, bundle: nil)
        modalPresentationStyle = .fullScreen
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    deinit {
        let id = ObjectIdentifier(self)
        Task { @MainActor in WatchAwake.drop(id) }
    }

    override var prefersStatusBarHidden: Bool { true }

    override var prefersHomeIndicatorAutoHidden: Bool { true }

    override var prefersPointerLocked: Bool { false }

    override var canBecomeFirstResponder: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = stage.palette.deep.color()
        view.isMultipleTouchEnabled = false
        if let metalView {
            metalView.frame = view.bounds
            metalView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
            metalView.sceneProvider = { [weak self] t in self?.stage.scene(at: t) }
            view.addSubview(metalView)
        }
        wordsView.frame = view.bounds
        wordsView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(wordsView)
        controls.alpha = 0
        controls.isHidden = true
        view.addSubview(controls)
        wireStage()
        wireControls()
        configureTouch()
        observeEnvironment()
        registerForTraitChanges([UITraitPreferredContentSizeCategory.self]) {
            (controller: WatchViewController, _) in controller.refresh(.style)
        }
    }

    private func wireStage() {
        stage.effects = { [weak self] in self?.feed.effects.live ?? [] }
        stage.beatShiftedAt = { [weak self] in self?.feed.beatShiftedAt ?? -100 }
        stage.animated = !UIAccessibility.isReduceMotionEnabled
        feed.onBoard = { [weak self] in self?.refresh(.board) }
        feed.onTick = { [weak self] in self?.refresh(.tick) }
        feed.onHour = { [weak self] in self?.refresh(.hour) }
        wordsView.handlers = WatchWordsView.Handlers(
            peek: { [weak self] id in self?.presentPeek(tile: id) },
            approve: { [weak self] id in self?.approve(id) },
            deny: { [weak self] id in self?.deny(id) },
            chat: { [weak self] id in self?.openChat(tile: id) })
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        resume()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
        refresh(.layout)
        #if DEBUG
            startDemoScriptIfAsked()
            startDemoUIIfAsked()
        #endif
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        guard isBeingDismissed || navigationController?.isBeingDismissed == true || standalone else { return }
        suspend()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let geometry = currentGeometry()
        if geometry != stage.geometry { refresh(.layout) }
    }

    func resume() {
        isForeground = true
        beginBattery()
        feed.resume()
        refresh(.tick)
    }

    func suspend() {
        isForeground = false
        feed.suspend()
        WatchAwake.drop(ObjectIdentifier(self))
        endBattery()
        #if DEBUG
            demoTask?.cancel()
            demoTask = nil
        #endif
        updateCadence()
    }

    func currentGeometry() -> WatchGeometry {
        let insets = view.safeAreaInsets
        let safe = WallInsets(
            top: insets.top, leading: insets.left, bottom: insets.bottom, trailing: insets.right)
        var fold: WallFold?
        if let reading = FoldReading.read(in: view), reading.isActive {
            fold = reading.axis == .vertical
                ? WallFold(axis: .vertical, from: reading.frame.minX, to: reading.frame.maxX)
                : WallFold(axis: .horizontal, from: reading.frame.minY, to: reading.frame.maxY)
        }
        return WatchGeometry(size: view.bounds.size, safe: safe, fold: fold)
    }

    func wordsContext(now: Date) -> WatchWordsContext {
        WatchWordsContext(
            wall: stage.wall, layout: stage.layout, palette: stage.palette, style: style,
            scale: WatchScale(unit: stage.layout.unit, traits: traitCollection), now: now,
            batteryHeld: batteryHeld, actions: actions)
    }

    /// One pass: read the wall for the screen as it is now, let the stage lay it out, and bring the
    /// words, the controls, the frame cap and the idle timer up to date. It runs when the screen
    /// changes, when a board arrives and once a second; the words are only rebuilt when what they
    /// say or where they sit has changed.
    func refresh(_ reason: Reason) {
        guard isViewLoaded, view.window != nil || reason == .layout else { return }
        let geometry = currentGeometry()
        guard geometry.isUsable else { return }
        let now = Date()
        let t = CACurrentMediaTime()
        if reason != .board { stage.refreshPalette(now: now) }
        stage.apply(hour: feed.hour, now: now)
        let read = feed.read(shape: stage.shape(for: geometry), style: style, now: now)
        let morphing = stage.adopt(read, geometry: geometry, now: now, at: t)
        announce(read)
        updateAwake()
        updateWords(now: now, morphing: morphing)
        updateControls(now: now)
        peek?.update(board: feed.board)
        syncWordsAlpha()
        feed.prune()
        updateCadence()
        hasRead = true
    }

    private func updateWords(now: Date, morphing: Bool) {
        let context = wordsContext(now: now)
        let next = Applied(
            wall: context.wall, layout: context.layout, palette: context.palette, style: style,
            scale: context.scale, actions: actions, batteryHeld: batteryHeld)
        defer { lastApplied = next }
        wordsView.frame = view.bounds
        if let last = lastApplied, last.wall.sameShown(as: next.wall), last.layout == next.layout,
            last.palette == next.palette, last.style == next.style, last.scale == next.scale,
            last.actions == next.actions, last.batteryHeld == next.batteryHeld
        {
            wordsView.tick(context)
            return
        }
        wordsView.apply(context, animated: morphing)
    }

    func applyWordsNow() {
        lastApplied = nil
        refresh(.tick)
    }

    func syncWordsAlpha() {
        let target = stage.wordsTarget
        guard abs(target - lastWordsTarget) > 0.001 else { return }
        let rising = target > lastWordsTarget
        lastWordsTarget = target
        let lasts = stage.peeking || peek != nil ? 0.3 : (rising ? WatchStage.wakeLasts : stage.dimLasts)
        UIView.animate(
            withDuration: lasts, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseInOut]
        ) { self.wordsView.alpha = target }
    }

    private func announce(_ read: WatchRead) {
        guard hasRead else { return }
        for event in read.events where event.kind == .asked {
            guard let tile = read.wall.tiles.first(where: { $0.id == event.tile }) else { continue }
            Theme.Haptics.needsYou()
            UIAccessibility.post(
                notification: .announcement, argument: String(localized: "\(tile.title) needs you"))
        }
    }

    func updateCadence() {
        guard let metalView else { return }
        let t = CACurrentMediaTime()
        let info = ProcessInfo.processInfo
        let thermal = WatchPower.thermal(info.thermalState)
        let visible = isForeground && view.window != nil
        let fastest = view.window?.windowScene?.screen.maximumFramesPerSecond ?? 60
        let live = feed.effects.isActive(at: t) || stage.held != nil || stage.isMorphing(at: t)
            || stage.isDimming(at: t)
        let cap = WallCadence.cap(
            effectsLive: live, breathing: stage.breathes && stage.animated && !style.still,
            dimmedCalm: stage.isDimmedCalm(at: t), hidden: !visible, lowPower: info.isLowPowerModeEnabled,
            thermal: thermal, proMotion: fastest > 60)
        metalView.framesPerSecond = cap
        if thermal == .critical, visible, !drewStill {
            drewStill = true
            metalView.drawOnce()
        } else if thermal != .critical {
            drewStill = false
        }
    }

    func updateAwake() {
        let state = WatchPower.keepsAwake(style.keepAwake)
        batteryHeld = state.heldByBattery
        WatchAwake.set(self, wants: state.awake && isForeground && view.window != nil)
    }

    private func beginBattery() {
        guard !isWatchingBattery else { return }
        isWatchingBattery = true
        WatchAwake.beginWatchingBattery()
    }

    private func endBattery() {
        guard isWatchingBattery else { return }
        isWatchingBattery = false
        WatchAwake.endWatchingBattery()
    }
}
