import AppKit
import TailscodeCore

/// The Studio's presenter: one sheet for the whole app, risen inside the Tailscode window rather than
/// opened beside it. It keeps the two lanes and what is the Studio's about the sheet — which lane it
/// shows, the words a composer handed it, Esc's stop before close — while `SheetPresenter` runs Core's
/// `StudioSheetState` over rise, change and leave, and owns what has to be true around it: the keyboard
/// is the sheet's while it is up, the opener gets focus back, and the conversation's chords are off
/// until it starts to leave. Closing the sheet closes nothing else — the render lives in the studio
/// above it — and opening it again finds the picture exactly where it was.
@MainActor
final class StudioWindowController: NSObject {
    static let shared = StudioWindowController()

    private(set) var presenter: SheetPresenter?
    private let stack: SheetStack
    private let imageLane: ImageLane
    private lazy var videoLane = VideoLane(runner: .shared)
    private(set) var current: StudioLaneID = .image

    /// Replaces the system's reduced-motion setting, so a check can take both paths.
    var reducedMotionOverride: Bool?

    /// The app has one; a check builds its own over a studio of its own, so nothing it leaves behind
    /// outlives it as a global that a later render's callbacks would find.
    init(studio: MacImageStudio = .shared, stack: SheetStack = .shared) {
        self.stack = stack
        imageLane = ImageLane(studio: studio)
        super.init()
        imageLane.onAnimate = { [weak self] request in
            guard let self else { return }
            self.videoLane.start(from: request)
            self.show(lane: .video)
        }
    }

    var state: StudioSheetState { presenter?.state ?? .closed }

    var sheet: StudioSheetView? { presenter?.sheet as? StudioSheetView }

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

    /// Whether the keyboard is the Studio's in `window`: it is, from the first frame of its rise, unless
    /// a viewer has been raised on it, which owns the keys and leaves the Studio's chords locked — they
    /// would act on a surface nobody sees focus in.
    func sheetOwnsKeys(in window: NSWindow) -> Bool {
        presenter?.ownsKeys == true && sheet?.host === window
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
    /// A viewer raised on the Studio is closed by it: the lane the person asked for is what they look at.
    func show(lane id: StudioLaneID = .image, brief: String? = nil, in window: NSWindow? = nil) {
        guard let target = window ?? presentingWindow, target.contentView != nil else { return }
        let presenter = ensurePresenter()
        closeWhatStandsOnTheStudio(presenter)
        let effect = presenter.show(
            in: target, lane: id.kind,
            prepare: { select(id) },
            ready: {
                placeBrief(brief, on: id)
                refreshChrome()
            })
        if case .changeLane = effect {
            select(id)
            sheet?.refreshKeyLoop()
            placeBrief(brief, on: id)
            refreshChrome()
        }
    }

    /// A sheet already standing when the Studio is asked for either ends first, with no motion, or is
    /// above it and asked to leave, so the Studio never ends up beneath a sheet that has nothing to do with it.
    private func closeWhatStandsOnTheStudio(_ presenter: SheetPresenter) {
        if state == .closed {
            stack.teardownOthers(than: presenter)
        } else {
            for above in stack.presenters.drop(while: { $0 !== presenter }).dropFirst() { above.dismiss() }
        }
    }

    /// Starts the sheet leaving.
    func dismiss() {
        presenter?.dismiss()
    }

    /// The motion ended: a rising sheet is at rest, a leaving one is gone and its overlay with it.
    func motionFinished() {
        presenter?.motionFinished()
    }

    #if DEBUG
        /// Stops the motion where it stands and holds the sheet at `progress` of it, rising or leaving,
        /// so a frame in the middle of the move can be photographed.
        func hold(at progress: Double, closing: Bool) {
            presenter?.hold(at: progress, closing: closing)
        }
    #endif

    /// ⌘W with the sheet up closes the sheet; the window is closed by the next one, or by its own
    /// close button. Only the chord Core names counts, and only in the window the sheet is in; with a
    /// viewer on the Studio, the viewer's ⌘W is the one that is answered.
    func closesSheet(chord: KeyChord, command: Bool, keyWindow: NSWindow?) -> Bool {
        stack.closesTop(chord: chord, command: command, keyWindow: keyWindow)
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

    private func ensurePresenter() -> SheetPresenter {
        if let presenter { return presenter }
        let sheet = StudioSheetView()
        let presenter = SheetPresenter(sheet: sheet, stack: stack)
        presenter.reducedMotion = { [weak self] in self?.reducedMotion ?? false }
        sheet.workspace.onChange = { [weak self] _ in self?.refreshChrome() }
        sheet.workspace.onLaneKey = { [weak self] id in self?.show(lane: id) }
        sheet.workspace.onEscape = { [weak self] in self?.escapePressed() }
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
        self.presenter = presenter
        return presenter
    }

    private func placeBrief(_ brief: String?, on id: StudioLaneID) {
        let shown = lane(id)
        if let brief, !brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            shown.dock.take(brief: brief)
        } else {
            shown.dock.focusWords()
        }
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
        superview?.needsLayout = true
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
        let width = Self.nameX + nameWidth + Self.gap + lineWidth + Self.trailing
        return NSSize(width: min(max(width, 220), 520), height: 28)
    }

    private static let nameX: CGFloat = 30
    private static let gap: CGFloat = 8
    private static let trailing: CGFloat = 26

    /// The name's width as the ramp's font draws it. A text field's own intrinsic size came back a few
    /// points short of what the bold face needs, so the frame this view handed the label truncated
    /// "arch" to "ar…" in the window itself, not only in a picture of it.
    private var nameWidth: CGFloat { StudioTheme.width(of: name.stringValue, role: .rowTitleStrong) + 4 }

    private var lineWidth: CGFloat { StudioTheme.width(of: line.stringValue, role: .panelFootnote) + 4 }

    override func layout() {
        super.layout()
        dot.frame = NSRect(x: 14, y: (bounds.height - 8) / 2, width: 8, height: 8)
        let lineHeight = StudioTheme.height(of: .panelFootnote)
        let nameHeight = StudioTheme.height(of: .rowTitleStrong)
        name.frame = NSRect(x: Self.nameX, y: (bounds.height - nameHeight) / 2, width: nameWidth, height: nameHeight)
        let lineX = Self.nameX + nameWidth + Self.gap
        line.frame = NSRect(
            x: lineX, y: (bounds.height - lineHeight) / 2, width: max(0, bounds.width - lineX - Self.trailing),
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
