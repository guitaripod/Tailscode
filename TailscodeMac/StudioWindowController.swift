import AppKit
import TailscodeCore

/// The Studio: one panel, not a sheet, so it can sit beside a conversation. A lane switch leads the
/// toolbar, the machine pill sits in its centre, and the queue and Done are at its trailing edge;
/// below them the lane's stage, a shelf and the brief dock. Closing the panel closes a window and
/// nothing else — the render lives in the studio above it — and opening it again finds the picture
/// exactly where it was.
@MainActor
final class StudioWindowController: NSObject, NSToolbarDelegate, NSWindowDelegate {
    static let shared = StudioWindowController()

    private(set) var panel: StudioPanel?
    private let imageLane = ImageLane(studio: .shared)
    private lazy var videoLane = VideoLane(runner: .shared)
    private(set) var current: StudioLaneID = .image
    private let laneControl = NSSegmentedControl(
        labels: StudioLaneID.allCases.map(\.title), trackingMode: .selectOne, target: nil, action: nil)
    private let pill = StudioMachinePill()
    private let queue = StudioTheme.label(.panelFootnote, color: MacTheme.Color.secondaryLabel)
    private let done = NSButton(title: ImageGenSurface.dismissTitle, target: nil, action: nil)

    private static let laneItem = NSToolbarItem.Identifier("studio.lane")
    private static let machineItem = NSToolbarItem.Identifier("studio.machine")
    private static let queueItem = NSToolbarItem.Identifier("studio.queue")
    private static let doneItem = NSToolbarItem.Identifier("studio.done")

    private override init() {
        super.init()
        imageLane.onAnimate = { [weak self] request in
            guard let self else { return }
            self.videoLane.start(from: request)
            self.show(lane: .video)
        }
    }

    var isKey: Bool { panel?.isKeyWindow == true }

    var activeLane: (any StudioLane)? { lane(current) }

    var image: ImageLane { imageLane }

    var video: VideoLane { videoLane }

    /// The lane a segment of the switch stands for. The Video lane is built the first time somebody
    /// asks for it, so a Studio that only ever paints never watches the renderer.
    private func lane(_ id: StudioLaneID) -> any StudioLane {
        switch id {
        case .image: return imageLane
        case .video: return videoLane
        }
    }

    /// Raises the Studio on a lane. With `brief` the words land in that lane's box as the thing to
    /// make — the composer's Image lane sends them here — and nothing is rendered until a hand says
    /// Generate.
    func show(lane id: StudioLaneID = .image, brief: String? = nil) {
        let panel = self.panel ?? makePanel()
        select(id)
        if panel.isMiniaturized { panel.deminiaturize(nil) }
        panel.makeKeyAndOrderFront(nil)
        let shown = lane(id)
        if let brief, !brief.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            shown.dock.take(brief: brief)
        } else {
            shown.dock.focusWords()
        }
        refreshChrome()
    }

    private func makePanel() -> StudioPanel {
        let panel = StudioPanel(
            contentRect: NSRect(x: 0, y: 0, width: 1180, height: 820),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered, defer: false)
        panel.title = Localized.text("Studio")
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = false
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.contentMinSize = NSSize(width: 880, height: 640)
        panel.delegate = self
        MacTheme.Chrome.adopt(panel)
        let workspace = StudioWorkspaceView(scoped: false)
        workspace.onChange = { [weak self] _ in self?.refreshChrome() }
        workspace.onLaneKey = { [weak self] id in self?.show(lane: id) }
        panel.workspace = workspace
        panel.contentView = workspace
        if !panel.rememberFrame(as: "TailscodeStudio") {
            panel.setContentSize(NSSize(width: 1180, height: 820))
            panel.center()
        }
        let toolbar = NSToolbar(identifier: "studio.toolbar")
        toolbar.delegate = self
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.centeredItemIdentifiers = [Self.machineItem]
        panel.toolbar = toolbar
        panel.toolbarStyle = .unified
        laneControl.segmentStyle = .automatic
        laneControl.target = self
        laneControl.action = #selector(laneChosen)
        laneControl.setAccessibilityLabel(Localized.text("Studio lane"))
        for (index, lane) in StudioLaneID.allCases.enumerated() {
            laneControl.setToolTip(
                lane == .image
                    ? ImageGenEntryPoint.tooltip(configured: true)
                    : ForgeEntryPoint.tooltip(configured: ForgeRunner.shared.endpoint != nil),
                forSegment: index)
        }
        done.bezelStyle = .rounded
        done.target = self
        done.action = #selector(donePressed)
        done.keyEquivalent = ""
        pill.onPress = { [weak self] anchor in self?.activeLane?.presentMachine(from: anchor) }
        self.panel = panel
        workspace.setLane(imageLane)
        return panel
    }

    private func select(_ id: StudioLaneID) {
        current = id
        laneControl.selectedSegment = id.rawValue
        guard let workspace = panel?.workspace else { return }
        let next = lane(id)
        if workspace.lane !== next { workspace.setLane(next) }
    }

    private func refreshChrome() {
        let lane = lane(current)
        let fact = lane.machine
        pill.show(fact)
        let count = lane.queueCount
        queue.stringValue = "\(ImageGenMachineWords.queueLabel) \(count)"
        queue.setAccessibilityLabel(queue.stringValue)
        done.toolTip = lane.dismissNote
    }

    @objc private func laneChosen() {
        let id = StudioLaneID(rawValue: laneControl.selectedSegment) ?? .image
        show(lane: id)
    }

    @objc private func donePressed() {
        panel?.performClose(nil)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        refreshChrome()
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.laneItem, Self.machineItem, Self.queueItem, Self.doneItem, .flexibleSpace, .space]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [Self.laneItem, .flexibleSpace, Self.machineItem, .flexibleSpace, Self.queueItem, Self.doneItem]
    }

    func toolbar(
        _ toolbar: NSToolbar, itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        switch itemIdentifier {
        case Self.laneItem:
            item.view = laneControl
            item.label = Localized.text("Studio lane")
        case Self.machineItem:
            item.view = pill
            item.label = ImageGenMachineWords.title
        case Self.queueItem:
            item.view = queue
            item.label = ImageGenMachineWords.queueLabel
        case Self.doneItem:
            item.view = done
            item.label = ImageGenSurface.dismissTitle
        default:
            return nil
        }
        item.isBordered = false
        return item
    }
}

/// The Studio's window: a titled, resizable panel that is key and main like any other window — it is
/// a place to work, beside a conversation, not a floating utility — and that knows its workspace so
/// the menu bar can act on it.
@MainActor
final class StudioPanel: NSPanel {
    var workspace: StudioWorkspaceView?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
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
        let width = 14 + 8 + 8 + ceil(name.intrinsicContentSize.width) + 8
            + ceil(line.intrinsicContentSize.width) + 8 + 14
        return NSSize(width: min(max(width, 220), 520), height: 28)
    }

    override func layout() {
        super.layout()
        dot.frame = NSRect(x: 14, y: (bounds.height - 8) / 2, width: 8, height: 8)
        let nameWidth = ceil(name.intrinsicContentSize.width)
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
