import AppKit
import CodingAgentKit
import TailscodeCore

/// The tiling tree on the Mac, drawn as one frame-placed canvas.
///
/// `SplitLayout` decides the arrangement and Core's placement turns it into rectangles for a
/// container of a given size; this lays every pane's shell at its rectangle, a divider over every
/// seam, and the overflow strip under the panes the window cannot show. Nothing is nested and
/// nothing is re-parented: a split adds one shell, a close removes one, and every other verb —
/// exchange, rotate, promote, arrange, zoom, a window too small for every pane — is a change of
/// frames and of `isHidden`. The ratio a divider holds is written only when a person drags or
/// nudges it, never read back from what a layout happened to produce.
///
/// Each pane also has a density. The focused pane is the whole conversation; the governor's one-
/// second decision says which other chats stay whole and which become glance tiles, a pane too
/// small to be read whole is a glance whatever the governor says, and a pane out of sight —
/// zoomed away, overflowed, the window occluded — owns no stream and no clock. A pane demoted to
/// a glance lets go of its row views twenty seconds later; coming back rebuilds the tail.
@MainActor
final class TileHost: NSViewController, PaneTiling {
    var layout = SplitLayout()
    var panes: [PaneID: TranscriptViewController] = [:]
    var shells: [PaneID: TileShellView] = [:]
    var dividers: [SplitID: TileDividerView] = [:]
    private(set) var canvas = TileCanvasView(frame: NSRect(x: 0, y: 0, width: 800, height: 600))
    let strip = OverflowStripView(frame: .zero)
    let dropHighlight = PaneDropHighlightView(frame: .zero)
    var placement: PanePlacement?
    var lastVisible = -1

    var makePane: (() -> TranscriptViewController)?
    /// Who every pane this host builds answers to, when no `makePane` was handed over.
    weak var paneHost: PaneHost?
    var onPaneOpened: ((TranscriptViewController, String?) -> Void)?
    var onChatDropped: ((TranscriptViewController, PaneDragPayload, PaneDropZone) -> Bool)?
    var chatTitleForDrop: ((PaneDragPayload) -> String?)?
    var onFocusChanged: (() -> Void)?
    var onLayoutChanged: (() -> Void)?
    var heldSessions: (() -> [PaneID: SplitPaneSession])?
    var onRefused: ((String) -> Void)?
    var onResume: ((PaneID) -> Void)?
    /// What the chat list last heard about a conversation: its title and its activity face. A
    /// paused pane and a chip in the strip are drawn from this, never from a stream.
    var listFace: ((SplitPaneSession) -> (title: String, activity: ActivityKind?)?)?

    var pinned: Set<PaneID> = []
    var userParked: Set<PaneID> = []
    var held: [PaneID: SplitPaneSession] = [:]
    var occluded = false
    var decision: GovernorDecision?
    var sizeAllowsFull: [PaneID: Bool] = [:]
    var feeds: [PaneID: GlanceFeed] = [:]
    var releases: [PaneID: Timer] = [:]
    var promotionHold: [PaneID: TimeInterval] = [:]
    var readings: [PaneID: (reading: GlanceReading, at: Date)] = [:]
    private var reliefToken: MemoryReliefToken?
    var dropZone: (pane: PaneID, zone: PaneDropZone)?
    var reconcileScheduled = false
    var lastHidden: [PaneID] = []
    var liveResizing = false
    var deferredPeers: [PaneID] = []

    /// How long a demoted pane keeps its rows before letting them go, and how long a glance's
    /// last words are kept for the paused face.
    var demotedKeep: TimeInterval = 20
    static let readingKeep: TimeInterval = 600

    let writer = TrailingWriter<String?>(label: "tailscode.layout-writer") { encoded in
        if let encoded {
            UserDefaults.standard.set(encoded, forKey: SplitSnapshot.defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: SplitSnapshot.defaultsKey)
        }
    }
    var persistRequests = 0
    var ratioCaptures = 0
    /// Main-thread milliseconds the last canvas layout took, and the last divider step from the
    /// pointer to rectangles settled, for the bench and the recorder.
    var lastLayoutCost: TimeInterval = 0
    var lastDragCost: TimeInterval = 0

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        canvas.onLayout = { [weak self] bounds in self?.place(in: bounds) }
        canvas.onLiveResize = { [weak self] live in self?.liveResize(live) }
        canvas.onAppearance = { [weak self] in self?.applyFocusStyling() }
        canvas.readingOrder = { [weak self] in
            guard let self else { return [] }
            return self.layout.paneIDs.compactMap { self.shells[$0] }.filter { !$0.isHidden }
        }
        strip.isHidden = true
        strip.translatesAutoresizingMaskIntoConstraints = true
        strip.autoresizingMask = []
        strip.onPress = { [weak self] id in self?.reveal(id) }
        canvas.addOverlay(strip)
        dropHighlight.autoresizingMask = []
        canvas.addOverlay(dropHighlight)
        view = canvas
        reliefToken = MemoryRelief.shared.register(name: "glance readings") { [weak self] depth in
            DispatchQueue.main.async {
                MainThread.call { self?.relieve(depth) }
            }
        }
    }

    /// Paused faces keep a glance's last words for ten minutes; under memory pressure they go
    /// sooner — half the age at strained, all but the live glances' at critical.
    private func relieve(_ depth: ReliefDepth) {
        if depth == .all {
            readings = readings.filter { feeds[$0.key] != nil }
        } else {
            let cutoff = Date().addingTimeInterval(-Self.readingKeep / 2)
            readings = readings.filter { $0.value.at > cutoff }
        }
    }

    func bootstrap() {
        guard panes.isEmpty else { return }
        adopt(buildPane(), as: layout.focusedPane)
        relayout()
    }

    var active: TranscriptViewController {
        panes[layout.focusedPane] ?? panes.values.first!
    }

    var paneCount: Int { layout.paneCount }

    var orderedPanes: [TranscriptViewController] {
        layout.paneIDs.compactMap { panes[$0] }
    }

    func id(of pane: TranscriptViewController) -> PaneID? {
        panes.first { $0.value === pane }?.key
    }

    func pane(showing sessionID: String) -> TranscriptViewController? {
        orderedPanes.first { $0.currentEntry?.session.id == sessionID }
    }

    func eachPane(_ body: (TranscriptViewController) -> Void) {
        for pane in orderedPanes { body(pane) }
    }

    var activeIsPinned: Bool { pinned.contains(layout.focusedPane) }
    var activeIsParked: Bool { userParked.contains(layout.focusedPane) }
    var supportsDensity: Bool { true }

    /// The pane a point lands in. A divider's band reaches four points into each neighbour, and a
    /// press there is a press on the divider, which activates no pane; so is a press on the strip.
    func pane(atWindowPoint point: NSPoint) -> TranscriptViewController? {
        for divider in dividers.values where !divider.isHiddenOrHasHiddenAncestor {
            if divider.bounds.contains(divider.convert(point, from: nil)) { return nil }
        }
        if !strip.isHidden, strip.bounds.contains(strip.convert(point, from: nil)) { return nil }
        for id in layout.paneIDs {
            guard let shell = shells[id], shell.window != nil,
                !shell.isHiddenOrHasHiddenAncestor
            else { continue }
            let local = shell.convert(point, from: nil)
            if NSMouseInRect(local, shell.bounds, shell.isFlipped) { return panes[id] }
        }
        return nil
    }

    /// Focus by intent. A press on a glance tile holds it a glance for one double-click interval
    /// so the second click of a double click lands on the tile it meant.
    func focus(_ pane: TranscriptViewController, grabKeyboard: Bool) {
        guard let id = id(of: pane), layout.focusedPane != id else { return }
        if let shell = shells[id], shell.face == .glance, let event = NSApp.currentEvent,
            event.type == .leftMouseDown, event.window != nil,
            shell.bounds.contains(shell.convert(event.locationInWindow, from: nil))
        {
            promotionHold[id] = CACurrentMediaTime() + NSEvent.doubleClickInterval
            DispatchQueue.main.asyncAfter(deadline: .now() + NSEvent.doubleClickInterval + 0.02) {
                [weak self] in
                MainThread.call {
                    self?.promotionHold[id] = nil
                    self?.reconcile()
                }
            }
        }
        layout.focus(id)
        reconcile()
        applyFocusStyling()
        if grabKeyboard { pane.focusComposer() }
        onFocusChanged?()
        persist()
    }

    /// A chip in the strip pressed: out of the zoom onto that pane, or, when the window had no room
    /// for it, swapped in for the placed pane focused longest ago.
    func reveal(_ id: PaneID) {
        guard layout.contains(id), let placement = currentPlacement() else { return }
        if layout.zoomedPane != nil {
            layout.toggleZoom(layout.zoomedPane!)
            layout.focus(id)
        } else if !placement.isPlaced(id),
            let stale = layout.recentlyFocused.reversed().first(where: { placement.isPlaced($0) })
        {
            layout.swap(id, stale)
            layout.focus(id)
        } else {
            layout.focus(id)
        }
        relayout()
        onFocusChanged?()
        persist()
    }

    var reconciledKinds: [PaneID: PaneKind] = [:]

    var dragHolding = false

    func attention(_ id: PaneID) -> PaneAttention {
        let activity: ActivityKind?
        if let shell = shells[id], shell.face != .full, let reading = readings[id] {
            activity = reading.reading.activity
        } else if let state = panes[id]?.currentState {
            activity = ActivityKind.inFlight(in: state)
        } else {
            activity = nil
        }
        switch activity {
        case .needsApproval, .needsAnswer: return .needsYou
        case .failed: return .failed
        case nil, .offline, .queued: return .quiet
        default: return .running
        }
    }

    /// What the live chip says: how many chats are whole out of how many there are.
    var liveCounts: (live: Int, chats: Int) {
        var live = 0
        var chats = 0
        for id in layout.paneIDs {
            guard let pane = panes[id], pane.paneKind(held: held[id] != nil) == .chat else {
                continue
            }
            chats += 1
            if let shell = shells[id], !shell.isHidden, shell.face == .full { live += 1 }
        }
        return (live, chats)
    }

    /// Checks and the bench read these.
    var dividerViews: [SplitID: TileDividerView] { dividers }
    var stripView: OverflowStripView { strip }
    func face(of id: PaneID) -> TileShellView.Face? { shells[id]?.face }
    func feedCount() -> Int { feeds.count }
}

/// A glance tile's hold on a chat: a `.glance` lease on the hub's one conversation and a slot in
/// the frame's drain at the shed level's glance rate, so a peer that changes every token is drawn
/// a few times a second at most and a frozen level draws nothing until it is asked.
@MainActor
final class GlanceFeed {
    let key: LiveKey
    private let lease: LiveLease
    private var token: DrainToken?
    private let slotID = PaneID()
    private var interval: TimeInterval
    private let onFrame: (ConversationState) -> Void
    private(set) var applied = 0

    init(
        entry: SessionEntry, backend: any CodingAgentBackend, interval: TimeInterval,
        onFrame: @escaping (ConversationState) -> Void
    ) {
        key = TileRuntime.key(entry)
        let runtime = TileRuntime.shared
        let drain = runtime.drain
        lease = runtime.lease(entry, backend: backend, interest: .glance) { drain.wake() }.0
        self.interval = interval
        self.onFrame = onFrame
        token = drain.register(slot())
    }

    /// A frozen level has no rate at all; the drain is given an hour rather than infinity, and the
    /// one-second governor pass wakes a frozen tile itself when its turn starts waiting on someone.
    private static func drainInterval(_ interval: TimeInterval) -> TimeInterval {
        interval.isFinite ? interval : 3600
    }

    private func slot() -> DrainSlot {
        let lease = self.lease
        return DrainSlot(
            pane: slotID, priority: .glance, minInterval: Self.drainInterval(interval),
            hasWork: { lease.hasFrame },
            apply: { [weak self] in MainThread.call { self?.applyNewest() } })
    }

    private func applyNewest() {
        guard let frame = lease.take() else { return }
        applied += 1
        onFrame(frame.state)
    }

    func setInterval(_ next: TimeInterval) {
        guard next != interval else { return }
        interval = next
        if let token { TileRuntime.shared.drain.update(token, to: slot()) }
    }

    /// The newest state the hub holds for the chat, whatever the rate.
    var latest: ConversationState? { TileRuntime.shared.hub.latest(key)?.state }

    func cancel() {
        token?.cancel()
        token = nil
        lease.cancel()
    }
}

#if DEBUG
    extension TileHost {
        /// The tree as the driver reads it: how many panes, what shape, which holds the focus and
        /// in what reading order, by the first characters of each pane's id.
        func driveOrder(_ label: String) -> String {
            let order = layout.paneIDs.map { String($0.raw.prefix(4)) }.joined(separator: ",")
            let focus = layout.paneIDs.firstIndex(of: layout.focusedPane) ?? -1
            return
                "\(label) panes=\(layout.paneCount) shape=\(SplitEven.shape(of: layout)) "
                + "focus=\(focus) zoom=\(layout.zoomedPane != nil) order=\(order)"
        }

        /// Every pane's frame in the canvas's own coordinates, top-left origin, in reading order.
        func driveGeometry() -> String {
            canvas.layoutSubtreeIfNeeded()
            let frames = layout.paneIDs.enumerated().compactMap { index, id -> String? in
                guard let shell = shells[id] else { return nil }
                let rect = shell.frame
                return String(
                    format: "%d(%.0f,%.0f %.0fx%.0f)", index, rect.minX, rect.minY, rect.width,
                    rect.height)
            }
            return
                "GEOM \(frames.joined(separator: " ")) canvas=\(Int(canvas.bounds.width))x\(Int(canvas.bounds.height))"
        }

        /// What VoiceOver would be told about each divider, in reading order, and whether it holds
        /// the keyboard.
        func driveDividers() -> String {
            let lines = layout.splitIDs.enumerated().compactMap { index, id -> String? in
                guard let divider = dividers[id] else { return nil }
                let value = (divider.accessibilityValue() as? NSNumber)?.doubleValue ?? -1
                let low = (divider.accessibilityMinValue() as? NSNumber)?.doubleValue ?? -1
                let high = (divider.accessibilityMaxValue() as? NSNumber)?.doubleValue ?? -1
                return String(
                    format: "%d role=%@ pos=%.3f range=%.0f...%.0f focused=%d \"%@\"", index,
                    divider.accessibilityRole()?.rawValue ?? "-", value, low, high,
                    divider.window?.firstResponder === divider ? 1 : 0,
                    divider.accessibilityLabel() ?? "-")
            }
            return "DIVIDERS \(lines.count) " + lines.joined(separator: " | ")
        }

        /// A key on divider `index` without a keyboard: it takes focus and moves as a key would.
        func driveDivider(_ index: Int, key: DividerKey) -> Bool {
            let ids = layout.splitIDs
            guard ids.indices.contains(index), let divider = dividers[ids[index]] else {
                return false
            }
            view.window?.makeFirstResponder(divider)
            return moveDivider(ids[index], by: key)
        }

        private func driveZone(_ shell: TileShellView, u: Double, v: Double) -> PaneDropZone {
            PaneDropTarget.zone(
                x: u * Double(shell.bounds.width), y: v * Double(shell.bounds.height),
                width: Double(shell.bounds.width), height: Double(shell.bounds.height))
        }

        /// A strip carried over another pane without a pointer: the highlight is drawn where
        /// letting go would put the pane, captioned with the move it would make.
        func drivePaneHover(target: Int, u: Double, v: Double, source: Int) -> String {
            let ids = layout.paneIDs
            guard ids.indices.contains(target), ids.indices.contains(source),
                let shell = shells[ids[target]]
            else { return "PDRAG no-target" }
            guard target != source else {
                clearDropHighlight()
                return "PDRAG - caption=-"
            }
            let zone = driveZone(shell, u: u, v: v)
            let rect = PaneDropTarget.highlight(
                for: zone, width: Double(shell.frame.width), height: Double(shell.frame.height))
            dropHighlight.show(
                frame: NSRect(
                    x: shell.frame.minX + rect.x, y: shell.frame.minY + rect.y, width: rect.width,
                    height: rect.height),
                caption: zone.moveVerb)
            return "PDRAG \(target) \(zone) caption=\(zone.moveVerb)"
        }

        /// A strip dropped on another pane: `target` and `source` are reading-order indexes and
        /// `u`, `v` where in the target the pointer is, as fractions from its top-left.
        func drivePaneDrop(target: Int, u: Double, v: Double, source: Int) -> String {
            let ids = layout.paneIDs
            guard ids.indices.contains(target), ids.indices.contains(source),
                let shell = shells[ids[target]]
            else { return "PDROP no-target" }
            let zone = driveZone(shell, u: u, v: v)
            let took = receivePaneDrop(PaneMovePayload(pane: ids[source]), on: ids[target], zone: zone)
            return "PDROP took=\(took) zone=\(zone) panes=\(paneCount)"
        }
    }
#endif
