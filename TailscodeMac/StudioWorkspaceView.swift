import AppKit
import TailscodeCore

/// Where a lane's stage, shelf and dock are put in relation to each other — one arrangement for the
/// sheet and for a pane in the grid, so a pane IS the Studio's lane at pane size rather than a
/// second implementation of it. The stage fills the room with the dock floating over its foot, the
/// shelf is a rail beside it, and when the room is narrow the rail folds into a strip above the dock
/// and the dock's chips fold into one Settings control. Nothing here names a lane: a lane hands over a
/// stage, a dock and a shelf and answers the keys.
@MainActor
final class StudioWorkspaceView: NSView {
    var onChange: ((StudioLaneChange) -> Void)?
    var onLaneKey: ((StudioLaneID) -> Void)?

    private(set) var lane: (any StudioLane)?
    private var shelf: StudioShelfView?
    private let notice = StudioPill()
    private var noticeTimer: Timer?
    private var monitor: Any?
    private let scoped: Bool
    private(set) var folded = false

    /// Room left clear above the stage, for a host that floats something of its own over the top
    /// edge — a pane's identity strip, or the gap under the sheet's toolbar.
    var topPadding: CGFloat = 0 {
        didSet { needsLayout = true }
    }

    /// Height the host carries beside the workspace — the sheet's toolbar — so the folds are measured
    /// against the whole sheet rather than the part of it the workspace fills.
    var hostChromeHeight: CGFloat = 0 {
        didSet { needsLayout = true }
    }

    /// Whether the workspace paints the window's ground under everything it holds. The sheet paints
    /// its own opaque canvas, and a second fill over it would be a second colour.
    var paintsGround = true {
        didSet { restyle() }
    }

    /// Called when Esc is pressed with the keyboard inside the workspace and the host is the sheet,
    /// which owns what Esc means: stop a render that is out, and only then leave.
    var onEscape: (() -> Void)?

    /// How many times `layout()` has run, so a check can show that the sheet's motion never makes the
    /// Studio lay itself out: the motion moves one layer and nothing inside it.
    private(set) var layoutPasses = 0

    /// - Parameter scoped: a workspace inside a pane answers the Studio's keys only while the key
    ///   window's focus is inside it, because the window holds a conversation's keys too; the sheet
    ///   answers them whenever it is up, because it owns the keyboard until it leaves.
    init(scoped: Bool) {
        self.scoped = scoped
        super.init(frame: .zero)
        wantsLayer = true
        notice.isHidden = true
        addSubview(notice)
        setAccessibilityRole(.group)
        restyle()
        NotificationCenter.default.addObserver(
            self, selector: #selector(themeChanged), name: MacTheme.Chrome.didRepaint, object: nil)
    }

    @objc private func themeChanged() { restyle() }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    /// The ground the stage and the shelf sit on: what a window is filled with beneath everything it
    /// holds, so the Studio is the same colour as the window around it under every theme.
    private func restyle() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = paintsGround ? MacTheme.Color.windowGround.cgColor : nil
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isFlipped: Bool { true }

    isolated deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        lane?.unwatch(self)
        noticeTimer?.invalidate()
    }

    /// Puts a lane in the workspace. Its stage and dock replace the last lane's, and the shelf is
    /// rebuilt over its tiles — the toolbar and the machine pill, which are the shell's, stay put.
    func setLane(_ next: any StudioLane) {
        if let lane {
            lane.unwatch(self)
            lane.stage.removeFromSuperview()
            lane.dock.removeFromSuperview()
        }
        shelf?.removeFromSuperview()
        lane = next
        next.onNotice = { [weak self] line in self?.say(line) }
        addSubview(next.stage, positioned: .below, relativeTo: notice)
        let rail = StudioShelfView(lane: next)
        shelf = rail
        addSubview(rail, positioned: .below, relativeTo: notice)
        addSubview(next.dock, positioned: .below, relativeTo: notice)
        next.dock.onHeightChange = { [weak self] in self?.needsLayout = true }
        next.watch(self) { [weak self] change in self?.laneChanged(change) }
        needsLayout = true
        next.prepare()
        rail.reload(animated: false)
    }

    private func laneChanged(_ change: StudioLaneChange) {
        switch change {
        case .everything:
            shelf?.reload()
            shelf?.refreshSelection()
        case .shelf:
            shelf?.reload()
            shelf?.refreshSelection()
        case .tile(let id):
            shelf?.refreshTile(id)
        case .sketch, .progress:
            shelf?.refreshJob()
        }
        onChange?(change)
    }

    /// One line from the lane that is not part of any state — a picture saved, copied, let go of — in
    /// a pill that rises over the foot of the stage for a moment and goes.
    private func say(_ line: String) {
        notice.text = line
        notice.isHidden = false
        notice.alphaValue = 1
        needsLayout = true
        noticeTimer?.invalidate()
        noticeTimer = Timer.scheduledTimer(withTimeInterval: 2.8, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = StudioTheme.motionAllowed ? 0.25 : 0
                    self.notice.animator().alphaValue = 0
                }, completionHandler: {
                    MainActor.assumeIsolated { self.notice.isHidden = true }
                })
            }
        }
        NSAccessibility.post(
            element: self, notification: .announcementRequested,
            userInfo: [.announcement: line, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        guard window != nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            nonisolated(unsafe) let pressed = event
            let consumed = MainActor.assumeIsolated { self.handle(pressed) }
            return consumed ? nil : event
        }
        needsLayout = true
    }

    override func layout() {
        super.layout()
        layoutPasses += 1
        guard let lane, let shelf else { return }
        let top = max(0, safeAreaInsets.top) + topPadding
        let folds = StudioFolding.foldsShelf(width: Double(bounds.width))
        folded = folds
        shelf.orientation = folds ? .strip : .rail
        lane.dock.foldsChips = StudioFolding.foldsChips(height: Double(bounds.height + hostChromeHeight))

        let inset: CGFloat = scoped ? 8 : 12
        let gap: CGFloat = 10
        let railWidth = StudioTheme.shelfWidth
        let stageX = inset
        let stageY = top
        let stageWidth = folds ? bounds.width - 2 * inset : bounds.width - inset - gap - railWidth - inset
        let stageHeight = bounds.height - stageY - inset
        let stage = lane.stage
        stage.frame = NSRect(x: stageX, y: stageY, width: max(0, stageWidth), height: max(0, stageHeight))

        let dockHeight = lane.dock.preferredHeight(forWidth: stageWidth - 2 * StudioTheme.dockInset)
        let dockWidth = max(0, stageWidth - 2 * StudioTheme.dockInset)
        let dockBottom = stage.frame.maxY - StudioTheme.dockInset
        let dock = lane.dock
        dock.frame = NSRect(
            x: stageX + StudioTheme.dockInset, y: dockBottom - dockHeight, width: dockWidth, height: dockHeight)
        var reserve = lane.dock.baseHeight + StudioTheme.dockInset + 12
        if folds {
            let strip = StudioTheme.stripHeight
            reserve += strip + 8
            shelf.frame = NSRect(
                x: stageX + 8, y: dock.frame.minY - 8 - strip, width: max(0, stageWidth - 16), height: strip)
        } else {
            shelf.frame = NSRect(
                x: stageX + stageWidth + gap, y: stageY, width: railWidth, height: max(0, stageHeight))
        }
        lane.stage.bottomReserve = reserve

        let size = notice.fittingSize
        notice.frame = NSRect(
            x: stage.frame.midX - size.width / 2, y: dock.frame.minY - 14 - size.height, width: size.width,
            height: size.height)
    }

    /// The keys the Studio answers while it is in front. In a pane they are resolved here rather than
    /// by the menu bar, because a pane's window holds a conversation's keys too and three of the
    /// Studio's chords are a conversation's verbs (⌘↩ sends, ⌘E archives, ⌘⇧E lists the archive): while
    /// focus is in the pane they are the Studio's and never fall through to a chat nobody is looking
    /// at. In the sheet the conversation's menu items are disabled while it is up, so the menu bar
    /// answers the Studio's ⌘ chords and only what it cannot is taken here: Esc, the arrows and Space,
    /// and the three chords the conversation's items still hold first — AppKit stops at the first item
    /// that wears a chord even when that item is disabled, so Generate would never be reached.
    /// Arrows and Space are only the Studio's while no text is being edited.
    private func handle(_ event: NSEvent) -> Bool {
        guard let window, event.window === window, let lane else { return false }
        if scoped {
            guard let responder = window.firstResponder as? NSView, responder.isDescendant(of: self) else {
                return false
            }
        } else if !StudioWindowController.shared.sheetOwnsKeys(in: window) {
            return false
        }
        let editing = window.firstResponder is NSText
        guard let key = StudioKeys.match(event, editing: editing) else { return false }
        if !scoped {
            guard !key.chord.command || key.sharesChordWithConversation else { return false }
            if key == .stop {
                onEscape?()
                return true
            }
        }
        switch key {
        case .imageLane:
            onLaneKey?(.image)
            return true
        case .videoLane:
            onLaneKey?(.video)
            return true
        case .generate, .enhance, .editThis, .save, .again:
            if lane.offers(key) { lane.perform(key) }
            return true
        case .stop, .previousTile, .nextTile, .open, .copy:
            guard lane.offers(key) else { return false }
            lane.perform(key)
            return true
        }
    }

    /// Whether the lane answers a menu item for `key` right now, for the menu bar's validation.
    func offers(_ key: StudioKey) -> Bool {
        switch key {
        case .imageLane, .videoLane: return true
        default: return lane?.offers(key) ?? false
        }
    }

    func perform(_ key: StudioKey) {
        switch key {
        case .imageLane: onLaneKey?(.image)
        case .videoLane: onLaneKey?(.video)
        default: lane?.perform(key)
        }
    }

    /// The workspace the key window's focus is in, for a menu bar that has to act on whichever
    /// Studio is in front — the sheet's while it is up, else a pane's. With no key window, which is an
    /// application that is not active, the sheet answers for the window it is in.
    static func current(in window: NSWindow?) -> StudioWorkspaceView? {
        guard let window = window ?? StudioWindowController.shared.sheet?.host else { return nil }
        if let sheet = StudioWindowController.shared.sheetWorkspace(in: window) { return sheet }
        var view = window.firstResponder as? NSView
        while let held = view {
            if let workspace = held as? StudioWorkspaceView { return workspace }
            view = held.superview
        }
        return nil
    }
}

/// The keys of the Studio, matched from an event. Kept apart from the view so `--selftest` can prove
/// the table without a window.
enum StudioKeys {
    static func match(_ event: NSEvent, editing: Bool) -> StudioKey? {
        let flags = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let character = event.charactersIgnoringModifiers?.lowercased() ?? ""
        return match(
            keyCode: event.keyCode, character: character, command: flags.contains(.command),
            shift: flags.contains(.shift), other: flags.contains(.option) || flags.contains(.control),
            editing: editing)
    }

    static func match(
        keyCode: UInt16, character: String, command: Bool, shift: Bool, other: Bool, editing: Bool
    ) -> StudioKey? {
        guard !other else { return nil }
        let isReturn = keyCode == 36 || keyCode == 76
        if command {
            if isReturn { return shift ? nil : .generate }
            switch (character, shift) {
            case ("e", false): return .enhance
            case ("e", true): return .editThis
            case ("r", true): return .again
            case ("1", false): return .imageLane
            case ("2", false): return .videoLane
            case ("s", false): return .save
            default: return nil
            }
        }
        if shift { return nil }
        switch keyCode {
        case 53: return .stop
        case 123: return editing ? nil : .previousTile
        case 124: return editing ? nil : .nextTile
        case 49: return editing ? nil : .open
        default: return nil
        }
    }
}
