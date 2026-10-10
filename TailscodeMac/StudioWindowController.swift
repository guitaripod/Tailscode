import AppKit
import TailscodeCore

/// The Studio's presenter: one sheet for the whole app, risen inside the Tailscode window rather than
/// opened beside it. It keeps the two lanes, runs Core's `StudioSheetState` over what the sheet does —
/// rise, change lane, leave — and owns what has to be true around it: the keyboard is the sheet's while
/// it is up, the opener gets focus back, and the conversation's chords are off until it starts to leave.
/// Closing the sheet closes nothing else — the render lives in the studio above it — and opening it
/// again finds the picture exactly where it was.
@MainActor
final class StudioWindowController: NSObject {
    static let shared = StudioWindowController()

    private(set) var state: StudioSheetState = .closed
    private(set) var sheet: StudioSheetView?
    private let imageLane: ImageLane
    private lazy var videoLane = VideoLane(runner: .shared)
    private(set) var current: StudioLaneID = .image
    private weak var opener: NSResponder?
    private var closeObserver: NSObjectProtocol?

    /// Replaces the system's reduced-motion setting, so a check can take both paths.
    var reducedMotionOverride: Bool?

    /// The app has one; a check builds its own over a studio of its own, so nothing it leaves behind
    /// outlives it as a global that a later render's callbacks would find.
    init(studio: MacImageStudio = .shared) {
        imageLane = ImageLane(studio: studio)
        super.init()
        imageLane.onAnimate = { [weak self] request in
            guard let self else { return }
            self.videoLane.start(from: request)
            self.show(lane: .video)
        }
    }

    /// Whether the sheet is up and holds the keyboard: from the first frame of its rise to the moment
    /// it starts to leave.
    var isKey: Bool { state.capturesKeys }

    var activeLane: (any StudioLane)? { lane(current) }

    var image: ImageLane { imageLane }

    var video: VideoLane { videoLane }

    private var reducedMotion: Bool { reducedMotionOverride ?? !StudioTheme.motionAllowed }

    /// The lane a segment of the switch stands for. The Video lane is built the first time somebody
    /// asks for it, so a Studio that only ever paints never watches the renderer.
    private func lane(_ id: StudioLaneID) -> any StudioLane {
        switch id {
        case .image: return imageLane
        case .video: return videoLane
        }
    }

    /// The sheet's workspace when the sheet is up in `window` and holds the keyboard, which is the
    /// workspace every Studio menu verb and key answers for.
    func sheetWorkspace(in window: NSWindow) -> StudioWorkspaceView? {
        sheetOwnsKeys(in: window) ? sheet?.workspace : nil
    }

    func sheetOwnsKeys(in window: NSWindow) -> Bool {
        state.capturesKeys && sheet?.host === window
    }

    /// The window a sheet opened without being told one rises in: the one it is already in, else the
    /// key Tailscode window, else the frontmost.
    private var presentingWindow: NSWindow? {
        if state != .closed, let host = sheet?.host { return host }
        if let key = NSApp.keyWindow, key.windowController is MainWindowController { return key }
        return NSApp.orderedWindows.first { $0.windowController is MainWindowController && $0.isVisible }
    }

    /// Raises the Studio on a lane, in `window` or wherever it already is. With `brief` the words land
    /// in that lane's box as the thing to make — the composer's Image lane sends them here — and
    /// nothing is rendered until a hand says Generate. Opening while it is up changes the lane and
    /// gives the words box the keyboard, with no motion; opening from another window moves it there.
    func show(lane id: StudioLaneID = .image, brief: String? = nil, in window: NSWindow? = nil) {
        guard let target = window ?? presentingWindow, target.contentView != nil else { return }
        let sheet = ensureSheet()
        if state != .closed, let host = sheet.host, host !== target { moveSheet(to: target) }
        let (next, effect) = state.reduced(by: .show(lane: id.kind))
        state = next
        switch effect {
        case .animateIn:
            if !sheet.holds(target.firstResponder as? NSView) { opener = target.firstResponder }
            sheet.install(in: target)
            watchClose(of: target)
            select(id)
            sheet.capture()
            placeBrief(brief, on: id)
            refreshChrome()
            sheet.layoutSubtreeIfNeeded()
            sheet.animate(opening: true, reduced: reducedMotion) { [weak self] in self?.motionFinished() }
        case .changeLane:
            select(id)
            sheet.refreshKeyLoop()
            placeBrief(brief, on: id)
            refreshChrome()
        case .animateOut, .none:
            break
        }
    }

    /// Starts the sheet leaving. The conversation's chords, its accessibility tree and the opener's
    /// focus are back at once — the motion is a courtesy, not a state anything waits on.
    func dismiss() {
        let (next, effect) = state.reduced(by: .dismiss)
        state = next
        guard effect == .animateOut, let sheet else { return }
        sheet.release()
        restoreOpenerFocus()
        sheet.animate(opening: false, reduced: reducedMotion) { [weak self] in self?.motionFinished() }
    }

    /// The motion ended: a rising sheet is at rest, a leaving one is gone and its overlay with it.
    func motionFinished() {
        let (next, _) = state.reduced(by: .finished)
        state = next
        if next == .closed { sheet?.uninstall() }
    }

    #if DEBUG
        /// Stops the motion where it stands and holds the sheet at `progress` of it, rising or leaving,
        /// so a frame in the middle of the move can be photographed. The state is the one the motion
        /// was in, so the keys and the menu answer as they would at that moment.
        func hold(at progress: Double, closing: Bool) {
            guard let sheet else { return }
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

    /// ⌘W with the sheet up closes the sheet; the window is closed by the next one, or by its own
    /// close button. Only the chord Core names counts, and only in the window the sheet is in.
    func closesSheet(chord: KeyChord, command: Bool, keyWindow: NSWindow?) -> Bool {
        guard state.capturesKeys, StudioSheetKeys.closes(chord, command: command),
            keyWindow == nil || keyWindow === sheet?.host
        else { return false }
        dismiss()
        return true
    }

    /// What Esc does with the sheet up: stop a render that is out, and only then close.
    func escapePressed() {
        guard state.capturesKeys else { return }
        let renderIsOut = activeLane?.offers(.stop) == true
        switch StudioSheetKeys.escape(renderIsOut: renderIsOut) {
        case .stopRender: activeLane?.perform(.stop)
        case .closeSheet: dismiss()
        }
    }

    private func ensureSheet() -> StudioSheetView {
        if let sheet { return sheet }
        let sheet = StudioSheetView()
        sheet.workspace.onChange = { [weak self] _ in self?.refreshChrome() }
        sheet.workspace.onLaneKey = { [weak self] id in self?.show(lane: id) }
        sheet.workspace.onEscape = { [weak self] in self?.escapePressed() }
        sheet.onScrimPress = { [weak self] in self?.dismiss() }
        let toolbar = sheet.toolbar
        toolbar.lanes.target = self
        toolbar.lanes.action = #selector(laneChosen)
        for (index, lane) in StudioLaneID.allCases.enumerated() {
            toolbar.lanes.setToolTip(
                lane == .image
                    ? ImageGenEntryPoint.tooltip(configured: true)
                    : ForgeEntryPoint.tooltip(configured: ForgeRunner.shared.endpoint != nil),
                forSegment: index)
        }
        toolbar.done.target = self
        toolbar.done.action = #selector(donePressed)
        toolbar.pill.onPress = { [weak self] anchor in self?.activeLane?.presentMachine(from: anchor) }
        sheet.workspace.setLane(imageLane)
        self.sheet = sheet
        return sheet
    }

    /// Opening from another window takes the sheet out of the first one, with everything it held, and
    /// puts it in the second at rest.
    private func moveSheet(to window: NSWindow) {
        guard let sheet else { return }
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

    private func teardown() {
        state = .closed
        opener = nil
        sheet?.uninstall()
        if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
        closeObserver = nil
    }

    private func placeBrief(_ brief: String?, on id: StudioLaneID) {
        let shown = lane(id)
        if let brief, !brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            shown.dock.take(brief: brief)
        } else {
            shown.dock.focusWords()
        }
    }

    /// Focus goes back to whatever held it when the sheet opened, or to nothing when that is gone.
    private func restoreOpenerFocus() {
        guard let window = sheet?.host else { return }
        if let opener, window.makeFirstResponder(opener) { return }
        window.makeFirstResponder(nil)
    }

    private func select(_ id: StudioLaneID) {
        current = id
        guard let sheet else { return }
        sheet.toolbar.lanes.selectedSegment = id.rawValue
        let next = lane(id)
        if sheet.workspace.lane !== next { sheet.workspace.setLane(next) }
    }

    func refreshChrome() {
        guard let sheet else { return }
        let lane = lane(current)
        sheet.toolbar.pill.show(lane.machine)
        let hint = lane.offers(.stop) ? StudioSheetWords.escapeHint : lane.dismissNote
        sheet.toolbar.refresh(queue: lane.queueCount, hint: hint)
    }

    @objc private func laneChosen() {
        let id = StudioLaneID(rawValue: sheet?.toolbar.lanes.selectedSegment ?? 0) ?? .image
        show(lane: id)
    }

    @objc private func donePressed() {
        dismiss()
    }
}

extension StudioLaneID {
    /// The lane as Core's sheet state machine names it.
    var kind: StudioLaneKind {
        switch self {
        case .image: return .image
        case .video: return .video
        }
    }
}

/// The toolbar's pill: a status dot that breathes only while the machine is working and is still
/// otherwise, the machine's short name, the one most useful fact about it, and a disclosure to the
/// sheet that says the rest. Danger when it cannot paint.
@MainActor
final class StudioMachinePill: NSView {
    var onPress: ((NSView) -> Void)?
    private let dot = NSView()
    private lazy var pulse = ActivityPulse(view: dot)
    private let name = StudioTheme.label(.panelLabel, color: MacTheme.Color.label)
    private let line = StudioTheme.label(.panelFootnote, color: MacTheme.Color.secondaryLabel)
    private var fact: StudioMachineFact?
    private var hovering = false
    private var tracking: NSTrackingArea?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 360, height: 28))
        wantsLayer = true
        dot.wantsLayer = true
        dot.layer?.cornerRadius = 4
        addSubview(dot)
        addSubview(name)
        addSubview(line)
        setAccessibilityRole(.button)
        toolTip = ImageGenMachineWords.title
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeChanged), name: MacTheme.Chrome.didRepaint, object: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    @objc private func themeChanged() { restyle() }

    func show(_ next: StudioMachineFact) {
        guard next != fact else { return }
        fact = next
        name.stringValue = next.name
        line.stringValue = next.line
        name.font = MacTheme.Ramp.font(.rowTitleStrong)
        setAccessibilityLabel(next.spoken)
        pulse.apply(next.isWorking ? ActivityKind.working.icon : nil)
        restyle()
        invalidateIntrinsicContentSize()
        needsLayout = true
        needsDisplay = true
    }

    private func restyle() {
        let tone = fact?.tone ?? .quiet
        effectiveAppearance.performAsCurrentDrawingAppearance {
            dot.layer?.backgroundColor = tone.color.cgColor
        }
        line.textColor = fact?.canPaint == false ? MacTheme.Color.danger : MacTheme.Color.secondaryLabel
        needsDisplay = true
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        pulse.windowChanged()
    }

    override var intrinsicContentSize: NSSize {
        guard fact != nil else { return NSSize(width: 220, height: 28) }
        let width = 14 + 8 + 8 + ceil(name.intrinsicContentSize.width) + 2 + 8
            + ceil(line.intrinsicContentSize.width) + 4 + 8 + 14
        return NSSize(width: min(max(width, 220), 520), height: 28)
    }

    override func layout() {
        super.layout()
        dot.frame = NSRect(x: 14, y: (bounds.height - 8) / 2, width: 8, height: 8)
        let nameWidth = ceil(name.intrinsicContentSize.width) + 2
        let lineHeight = StudioTheme.height(of: .panelFootnote)
        let nameHeight = StudioTheme.height(of: .rowTitleStrong)
        name.frame = NSRect(x: 30, y: (bounds.height - nameHeight) / 2, width: nameWidth, height: nameHeight)
        let lineX = 30 + nameWidth + 8
        line.frame = NSRect(
            x: lineX, y: (bounds.height - lineHeight) / 2, width: max(0, bounds.width - lineX - 26),
            height: lineHeight)
    }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: bounds.height / 2, yRadius: bounds.height / 2)
        MacTheme.Color.label.withAlphaComponent(hovering ? 0.1 : 0.06).setFill()
        shape.fill()
        (fact?.canPaint == false ? MacTheme.Color.danger.withAlphaComponent(0.7) : MacTheme.Color.separator).setStroke()
        shape.lineWidth = 1
        shape.stroke()
        let chevron = NSBezierPath()
        let x = bounds.width - 16
        let y = bounds.height / 2
        chevron.move(to: NSPoint(x: x - 3, y: y - 1.5))
        chevron.line(to: NSPoint(x: x, y: y + 1.5))
        chevron.line(to: NSPoint(x: x + 3, y: y - 1.5))
        MacTheme.Color.secondaryLabel.setStroke()
        chevron.lineWidth = 1.2
        chevron.lineCapStyle = .round
        chevron.stroke()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(
            rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return }
        onPress?(self)
    }

    override func accessibilityPerformPress() -> Bool {
        onPress?(self)
        return true
    }
}
