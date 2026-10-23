import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// The tiling tree on Linux, drawn as one flat canvas.
///
/// `SplitLayout` decides the arrangement and Core's placement turns it into rectangles for the
/// size the canvas has; the canvas's solver — which is this host's `solve`, called inside its
/// allocation — gives every pane's shell its rectangle, every divider its band over a seam, and the
/// overflow strip the row under the panes the window cannot show. Nothing is nested and nothing is
/// re-parented: a split adds one shell, a close removes one, and every other verb — exchange,
/// rotate, promote, arrange, zoom, a window too small for every pane — is a different answer from
/// the solver, and a pane it does not place is hidden, not moved. The ratio a divider holds is
/// written only when a person drags or nudges it, never read back from what a layout produced.
///
/// Each chat also has a density. The focused chat is whole; the governor's one-second decision says
/// which others stay whole and which become glance tiles, a chat too small to be read whole is a
/// glance whatever the governor says, and a pane out of sight — zoomed away, overflowed — owns no
/// stream and no clock. A pane demoted to a glance lets go of its row widgets twenty seconds
/// later, and coming back refills the tail.
final class TileHost: PaneTiling, @unchecked Sendable {
    let container: UnsafeMutablePointer<GtkWidget> = gtk_overlay_new()!
    var layout = SplitLayout()
    var panes: [PaneID: ChatPane] = [:]
    var shells: [PaneID: TileShell] = [:]
    var dividers: [SplitID: TileDivider] = [:]
    var canvas: TileCanvas!
    let strip = OverflowStrip()
    let dropHighlight = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    let dropCaption = Gtk.label("", css: "drop-caption", selectable: false)
    let ghost = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    var placement: PanePlacement?
    weak var host: MainWindow?

    var dropZone: (pane: PaneID, zone: PaneDropZone)?
    var dropRect: TileRect?
    var ghostRect: TileRect?
    var pinned: Set<PaneID> = []
    var userParked: Set<PaneID> = []
    var held: [PaneID: SplitPaneSession] = [:]
    var decision: GovernorDecision?
    var sizeAllowsFull: [PaneID: Bool] = [:]
    var feeds: [PaneID: GlanceFeed] = [:]
    var releaseTokens: [PaneID: Int] = [:]
    var releaseSerial = 0
    var promotionHold: [PaneID: TimeInterval] = [:]
    var readings: [PaneID: (reading: GlanceReading, at: Date)] = [:]
    var reliefToken: MemoryReliefToken?
    var reconcileScheduled = false
    var lastHidden: [PaneID] = []
    var lastRects: [PaneID: TileRect] = [:]
    var dividersStale = false
    var reconciledKinds: [PaneID: PaneKind] = [:]
    var drag: DividerDrag?
    var persistRequests = 0
    var ratioWrites = 0
    var lastDragMilliseconds = 0.0

    /// How long a demoted pane keeps its rows before letting them go, and how long a glance's last
    /// words are kept for the paused face.
    var demotedKeep: TimeInterval = 20
    static let readingKeep: TimeInterval = 600

    /// What the window listens for: the counts the live chip draws changed.
    var onDensityChanged: (() -> Void)?
    var listFace: ((SplitPaneSession) -> (title: String, activity: ActivityKind?)?)?

    struct DividerDrag {
        let id: SplitID
        let axis: SplitAxis
        let startPosition: Double
        let startPointer: Double
        var ghosting: Bool
        var slowSteps = 0
        var lastTarget: Double
        var moved = false
    }

    /// The harness's way of choosing the drag mode: nil lets the measured relayout decide.
    var forcedGhost: Bool?

    /// The step cost past which a divider drag stops moving the panes under the pointer and moves
    /// a line instead, committing once on release.
    static let liveDragLimit = 8.0

    init(host: MainWindow) {
        self.host = host
        gtk_widget_set_hexpand(container, 1)
        gtk_widget_set_vexpand(container, 1)
        canvas = TileCanvas { [weak self] width, height, sink in
            self?.solve(width: width, height: height, sink: sink)
        }
        gtk_overlay_set_child(op(container), canvas.widget)
        tailscode_set_accessible_label(canvas.widget, Localized.text("Panes"))
        buildOverlays()
        let pane = makePane(layout.focusedPane)
        adopt(pane, as: layout.focusedPane)
        Seatbelts.shared.onDecision = { [weak self] decision in self?.applyGovernor(decision) }
        reliefToken = MemoryRelief.shared.register(name: "glance readings") { [weak self] depth in
            Gtk.onMain { [weak self] in self?.relieve(depth) }
        }
        scheduleReconcile()
    }

    deinit {
        reliefToken?.cancel()
    }

    func buildOverlays() {
        strip.onPress = { [weak self] id in self?.reveal(id) }
        canvas.add(strip.widget, layer: .overlays)
        Gtk.addClass(dropHighlight, "drop-zone")
        gtk_widget_set_can_target(dropHighlight, 0)
        gtk_label_set_max_width_chars(op(dropCaption), 18)
        gtk_label_set_xalign(op(dropCaption), 0.5)
        gtk_widget_set_halign(dropCaption, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(dropCaption, GTK_ALIGN_CENTER)
        gtk_widget_set_vexpand(dropCaption, 1)
        gtk_box_append(ptr(dropHighlight), dropCaption)
        canvas.add(dropHighlight, layer: .overlays)
        Gtk.addClass(ghost, "tile-ghost")
        gtk_widget_set_can_target(ghost, 0)
        canvas.add(ghost, layer: .overlays)
    }

    func relieve(_ depth: ReliefDepth) {
        if depth == .all {
            readings = readings.filter { feeds[$0.key] != nil }
        } else {
            let cutoff = Date().addingTimeInterval(-Self.readingKeep / 2)
            readings = readings.filter { $0.value.at > cutoff }
        }
    }

    var activePane: ChatPane { panes[layout.focusedPane] ?? panes.values.first! }
    var paneCount: Int { layout.paneCount }
    var orderedPanes: [ChatPane] { layout.paneIDs.compactMap { panes[$0] } }

    func pane(showing sessionID: String) -> ChatPane? {
        orderedPanes.first { $0.sessionID == sessionID }
    }

    func eachPane(_ body: (ChatPane) -> Void) {
        for pane in orderedPanes { body(pane) }
    }

    func makePane(_ id: PaneID) -> ChatPane {
        Trace.mark("makePane begin")
        defer { Trace.mark("makePane end") }
        return ChatPane(id: id, host: host!)
    }

    /// A pane joins the canvas: its shell is made and added once, and the conversation goes in it
    /// for good. Every pane is a place a dragged chat or pane can land, so it is never built
    /// without its drop targets — including the ones a restore or a drop itself mints.
    func adopt(_ pane: ChatPane, as id: PaneID) {
        panes[id] = pane
        let shell = TileShell(id: id, body: pane.root)
        shell.setResume { [weak self] in Gtk.onMain { [weak self] in self?.resume(id) } }
        shells[id] = shell
        pane.outer = shell.widget
        Gtk.acceptChatDrops(
            on: shell.widget,
            motion: { [weak self] payload, x, y in
                self?.dragMoved(over: id, payload: payload, x: x, y: y)
            },
            leave: { [weak self] in self?.clearDropHighlight() },
            drop: { [weak self] payload, x, y in
                self?.receiveDrop(payload, on: id, x: x, y: y) ?? false
            })
        Gtk.acceptPaneDrops(
            on: shell.widget,
            motion: { [weak self] payload, x, y in
                self?.paneDragMoved(over: id, payload: payload, x: x, y: y)
            },
            leave: { [weak self] in self?.clearDropHighlight() },
            drop: { [weak self] payload, x, y in
                self?.receivePaneDrop(payload, on: id, x: x, y: y) ?? false
            })
        canvas.add(shell.widget, layer: .panes)
    }

    /// A pane leaves the canvas: its stream and clocks first, then its glance and timers, then the
    /// shell. The only removal a pane ever sees.
    func retire(_ id: PaneID) {
        feeds.removeValue(forKey: id)?.cancel()
        releaseTokens[id] = nil
        promotionHold[id] = nil
        readings[id] = nil
        sizeAllowsFull[id] = nil
        lastRects[id] = nil
        pinned.remove(id)
        userParked.remove(id)
        if let pane = panes.removeValue(forKey: id) {
            pane.shutdown()
            pane.outer = nil
        }
        if let shell = shells.removeValue(forKey: id) {
            shell.shutdown()
            canvas.remove(shell.widget)
        }
    }
}

/// A glance tile's hold on a chat: a `.glance` lease on the hub's one conversation and a slot in
/// the window's drain at the shed level's glance rate, so a peer that changes every token is drawn
/// a few times a second at most and a frozen level draws nothing until it is asked.
final class GlanceFeed: @unchecked Sendable {
    let key: LiveKey
    private let live: LiveRuntime
    private let lease: LiveLease
    private var token: DrainToken?
    private let slotID = PaneID()
    private var interval: TimeInterval
    private let onFrame: (ConversationState) -> Void
    private(set) var applied = 0

    init(
        entry: SessionEntry, live: LiveRuntime, interval: TimeInterval,
        onFrame: @escaping (ConversationState) -> Void
    ) {
        key = LiveKey(entry)
        self.live = live
        let drain = live.drain
        lease = live.hub.lease(key, interest: .glance) { drain.wake() }
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
            hasWork: { lease.hasFrame }, apply: { [weak self] in self?.applyNewest() })
    }

    private func applyNewest() {
        guard let frame = lease.take() else { return }
        applied += 1
        onFrame(frame.state)
    }

    func setInterval(_ next: TimeInterval) {
        guard next != interval else { return }
        interval = next
        if let token { live.drain.update(token, to: slot()) }
    }

    /// The newest state the hub holds for the chat, whatever the rate.
    var latest: ConversationState? { live.hub.latest(key)?.state }

    func cancel() {
        token?.cancel()
        token = nil
        lease.cancel()
    }
}
