import AppKit
import CodingAgentKit
import MidgarCore
import QuartzCore
import TailscodeCore
import TailscodeMetal

/// The ground and the words' view: one view the size of the Agents window's content, which takes the
/// keys the wall answers, the pointer's movement and a press that lands on a tile, and tells the wall
/// when its size or its window changes.
@MainActor
final class WatchWallRootView: NSView {
    var onResize: (() -> Void)?
    var onKey: ((NSEvent) -> Bool)?
    var onActivity: (() -> Void)?
    var onClick: ((CGPoint) -> Void)?
    var onWindow: (() -> Void)?
    private var pressedAt: CGPoint?

    override var isFlipped: Bool { true }

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onResize?()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        onWindow?()
    }

    override func layout() {
        super.layout()
        onResize?()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: self, userInfo: nil))
    }

    override func mouseMoved(with event: NSEvent) {
        onActivity?()
    }

    override func keyDown(with event: NSEvent) {
        onActivity?()
        if onKey?(event) != true { super.keyDown(with: event) }
    }

    override func mouseDown(with event: NSEvent) {
        onActivity?()
        pressedAt = convert(event.locationInWindow, from: nil)
    }

    override func mouseUp(with event: NSEvent) {
        guard let start = pressedAt else { return }
        pressedAt = nil
        let end = convert(event.locationInWindow, from: nil)
        if hypot(end.x - start.x, end.y - start.y) < 6 { onClick?(end) }
    }
}

/// The Agents window's Watch lens: a wall for a screen that is read from across a room and left on.
/// Core reads the board into the wall (once a second and on every board, never per frame), lays it
/// out for this window and says what changed and what each change plays; the Metal view draws the
/// ground, the glass, the marks and the light from the scene Core builds; the words are views placed
/// by frame over it. The wall never opens anything by itself and asks nothing of whoever is looking.
@MainActor
final class WatchWallViewController: NSViewController {
    let root = WatchWallRootView()
    let words = WatchWordsHost()
    let metal: WallMetalView?
    let effects = WatchEffectsDriver()
    let keepAwake = WatchKeepAwake()
    var style = MacWatchStyleStore.current
    private(set) var wall = AgentWall.empty
    private(set) var layout: WallLayout?
    private(set) var ribbon = WallRibbon.empty
    var palette = WallPalette.current(theme: ThemeSelection.theme)
    var board = AgentBoard.empty
    var hour: AgentHour?
    var fixedWall: AgentWall?
    var motes = WallMotes(width: 1180, height: 760, seed: 0x7A11)
    var dimmer = WatchDimmer()
    var hold = WatchHoldGauge()
    var presses: [String: WatchTileWordsView.Press] = [:]
    var isActive = false
    var isLive = false
    var isPeeking = false
    var lastScene: WallScene?
    var tween: (start: TimeInterval, from: WallScene)?
    var slideStart: TimeInterval?
    var lastFrame = CACurrentMediaTime()
    var lastAnimating = false
    var lastActivity = Date()
    var chromeHidden = false
    var hiddenProbe: (() -> Bool)?
    var ticker: Timer?
    var holdTimer: Timer?
    var observers: [NSObjectProtocol] = []
    var hourFetchedAt = Date.distantPast
    var hourFetching = false
    var stylePopover: NSPopover?
    var appliedCap = 0
    var drewCritical = false
    var laidOutKey = ""
    var initialRead = true
    var drift = (x: 0.0, y: 0.0)
    var actions: AgentsActions? {
        didSet { words.actions = actions }
    }
    var fetchHour: (() async -> AgentHour)?
    var onPeek: ((String) -> Void)?
    var onOpenChat: ((String) -> Void)?
    var onWatch: ((String) -> Void)?
    var onClosePeek: (() -> Void)?

    init() {
        metal = WallMetalView.isSupported ? WallMetalView(frame: CGRect(x: 0, y: 0, width: 1180, height: 760)) : nil
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    isolated deinit {
        for token in observers { NotificationCenter.default.removeObserver(token) }
        ticker?.invalidate()
        holdTimer?.invalidate()
    }

    override func loadView() {
        root.frame = NSRect(x: 0, y: 0, width: 1180, height: 760)
        root.wantsLayer = true
        if let metal {
            metal.frame = root.bounds
            metal.autoresizingMask = [.width, .height]
            metal.sceneProvider = { [weak self] t in MainThread.call { self?.provideScene(at: t) } }
            root.addSubview(metal)
        }
        words.frame = root.bounds
        words.autoresizingMask = [.width, .height]
        words.autoresizesSubviews = false
        root.addSubview(words)
        root.setAccessibilityLabel(Localized.text("Agents wall"))
        wire()
        view = root
    }

    private func wire() {
        root.onResize = { [weak self] in MainThread.call { self?.sizeChanged() } }
        root.onWindow = { [weak self] in MainThread.call { self?.windowChanged() } }
        root.onKey = { [weak self] event in MainThread.call { self?.handleKey(event) ?? false } }
        root.onActivity = { [weak self] in MainThread.call { self?.noteActivity() } }
        root.onClick = { [weak self] point in MainThread.call { self?.clicked(at: point) } }
        words.onHoldBegan = { [weak self] view, event in self?.beginHold(view, event) }
        words.onHoldEnded = { [weak self] view, inside in self?.endHold(view, inside: inside) }
        words.onDeny = { [weak self] key in self?.deny(key) }
        words.onChat = { [weak self] key in self?.onOpenChat?(key) }
        words.onOpenChat = { [weak self] key in self?.onOpenChat?(key) }
        words.onWatch = { [weak self] key in self?.onWatch?(key) }
    }

    var face: WatchFace {
        WatchFace(
            palette: palette, type: WatchType(unit: layout?.unit ?? WallLayout.unit(width: 1180, height: 760)),
            style: style)
    }

    var size: CGSize { root.bounds.size }

    var animated: Bool {
        !style.still && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// The style the wall is drawn and played with: the person's, and Still while the system asks for
    /// less motion, so a gesture becomes a crossfade and the field stands still.
    var effectiveStyle: WallStyle {
        guard !style.still, NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return style }
        var still = style
        still.still = true
        return still
    }

    var safeInsets: WallInsets {
        guard let window = root.window, !window.styleMask.contains(.fullScreen) else { return .zero }
        let safe = root.safeAreaRect
        return WallInsets(top: Double(max(0, safe.minY - root.bounds.minY)))
    }

    func apply(board next: AgentBoard) {
        board = next
        guard fixedWall == nil, isActive else { return }
        reread(now: Date())
    }

    func apply(hour next: AgentHour) {
        hour = next
        hourFetchedAt = Date()
        guard fixedWall == nil, isActive else { return }
        reread(now: Date())
    }

    /// Shows one wall from `AgentDemo` instead of the board: for a screenshot, a tour and a self-test.
    func show(demo scene: AgentWall?) {
        fixedWall = scene
        initialRead = true
        reread(now: Date())
    }

    /// What a verb has come to changed, so the answers on an ask say it.
    func actionsChanged() {
        guard isActive else { return }
        reread(now: Date())
    }

    /// Where a tile stands in this view, for a peek to open beside it.
    func rect(forTile id: String) -> CGRect? {
        guard let index = wall.tiles.firstIndex(where: { $0.id == id }), let layout, layout.tiles.indices.contains(index)
        else { return nil }
        return layout.tiles[index].watchFrame
    }

    func sizeChanged() {
        let target = size
        guard target.width > 80, target.height > 80 else { return }
        let key = "\(target.width)x\(target.height)/\(safeInsets.top)"
        guard key != laidOutKey else { return }
        laidOutKey = key
        if WallMotes.count(width: target.width, height: target.height) != motes.count {
            motes = WallMotes(width: target.width, height: target.height, seed: 0x7A11)
        }
        reread(now: Date())
    }

    func reread(now: Date) {
        let target = size
        guard target.width > 80, target.height > 80, isActive || fixedWall != nil else { return }
        let width = Double(target.width)
        let height = Double(target.height)
        let safe = safeInsets
        let reading = WallLayout.reading(width: width, height: height, safe: safe, fold: nil, style: style)
        let next: AgentWall
        if let fixedWall {
            next = fixedWall.reflowed(aspect: reading.aspect, gridAspect: reading.gridAspect, pages: reading.pages)
        } else {
            next = AgentWall.read(
                board: board, hour: hour, now: now, aspect: reading.aspect, gridAspect: reading.gridAspect,
                pages: reading.pages, previous: initialRead ? nil : wall)
        }
        let made = WallLayout.make(
            width: width, height: height, safe: safe, fold: nil, wall: next, style: style, drift: drift)
        adopt(next, made, now: now)
    }

    private func adopt(_ next: AgentWall, _ made: WallLayout, now: Date) {
        let t = CACurrentMediaTime()
        let before = initialRead ? nil : wall
        let events = effects.observe(from: before, to: next, previousLayout: layout, style: effectiveStyle, at: t)
        if let before, Self.beatShifted(before, next) { slideStart = t }
        dimmer.observe(next.mood, at: now)
        if !events.isEmpty { dimmer.wake(at: now, clearingManual: true) }
        var morphs = false
        if let old = layout, let before { morphs = Self.moves(old, made) && Self.sameTiles(before, next) }
        wall = next
        layout = made
        initialRead = false
        palette = Self.palette(for: style, at: now)
        ribbon = WallRibbon.read(hour, now: now)
        words.lastFace = face
        let frames = words.prepare(wall: next, layout: made, face: face, now: now, presses: presses)
        let canGlide = animated && isLive && !isHiddenNow()
        if morphs, canGlide, let lastScene {
            tween = (t, lastScene)
            settleAfterGlide(startedAt: t)
        } else if !canGlide || before.map({ !Self.sameTiles($0, next) }) == true {
            tween = nil
        }
        words.begin(frames, gliding: tween != nil)
        applyCadence()
        if appliedCap <= 1 { metal?.drawOnce() }
    }

    /// A glide ends when the renderer's frames say so, and also on the clock, so the words are where
    /// they belong even when nothing is drawing (a window that was covered while the wall moved).
    private func settleAfterGlide(startedAt start: TimeInterval) {
        DispatchQueue.main.asyncAfter(deadline: .now() + WatchSceneBlend.duration + 0.15) { [weak self] in
            MainThread.call {
                guard let self, let moving = self.tween, moving.start == start else { return }
                self.tween = nil
                self.words.settle()
                self.applyCadence()
            }
        }
    }

    static func palette(for style: WallStyle, at now: Date) -> WallPalette {
        let base = WallPalette.current(theme: ThemeSelection.theme)
        return style.isNight(at: now) ? base.night() : base
    }

    static func sameTiles(_ a: AgentWall, _ b: AgentWall) -> Bool {
        a.tiles.map(\.id) == b.tiles.map(\.id)
    }

    /// Whether any tile's place changed by more than a few points, which is when it glides.
    static func moves(_ a: WallLayout, _ b: WallLayout) -> Bool {
        guard a.tiles.count == b.tiles.count else { return false }
        for (old, new) in zip(a.tiles, b.tiles) {
            if abs(old.x - new.x) > 3 || abs(old.y - new.y) > 3 || abs(old.width - new.width) > 3
                || abs(old.height - new.height) > 3
            {
                return true
            }
        }
        return false
    }

    /// Whether a heartbeat moved one slot, so its bars slide in rather than jump.
    static func beatShifted(_ a: AgentWall, _ b: AgentWall) -> Bool {
        let before = Dictionary(a.tiles.map { ($0.id, $0.beat) }, uniquingKeysWith: { first, _ in first })
        for tile in b.tiles {
            guard let old = before[tile.id] ?? nil, let new = tile.beat, old.count == new.count, old.count > 1,
                old != new
            else { continue }
            if Array(old.dropFirst()) == Array(new.dropLast()) { return true }
        }
        return false
    }
}
