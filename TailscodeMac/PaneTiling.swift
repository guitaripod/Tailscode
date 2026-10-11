import AppKit
import CodingAgentKit
import TailscodeCore

/// What a pane asks of the window it lives in, as one narrow surface instead of a closure per
/// question wired by whoever built the pane. The window conforms; a pane built by a bench or a
/// check answers to nothing and simply goes unheard. The responder-chain reach a few pane paths
/// still take (`view.window?.windowController as? MainWindowController`) keeps working because a
/// pane's view stays in the window's tree for as long as the pane exists.
@MainActor
protocol PaneHost: AnyObject {
    func paneToast(_ text: String)
    func paneDialToast(_ text: String)
    func paneAuraChanged()
    func paneStateChanged(_ pane: TranscriptViewController)
    func paneSlotChanged(_ pane: TranscriptViewController)
    func pane(_ pane: TranscriptViewController, pressedBand action: StatusFacts.Action)
    func pane(_ pane: TranscriptViewController, answeredChooser action: PaneChooserAction)
    func paneQuotas() -> [UsageQuota]
    func paneWatchInBackground(_ entry: SessionEntry, backend: any CodingAgentBackend)
    func paneStopWatching(_ key: LiveKey)
}

extension TranscriptViewController {
    /// Routes every question this pane asks to `host`, held weakly: a pane never keeps its window
    /// alive, and a window gone is a pane talking to nobody.
    func connect(to host: PaneHost) {
        composer.onAuraChanged = { [weak host] in host?.paneAuraChanged() }
        onBackgroundWatch = { [weak host] entry, backend in
            host?.paneWatchInBackground(entry, backend: backend)
        }
        onStopWatch = { [weak host] key in host?.paneStopWatching(key) }
        onState = { [weak host, weak self] _ in
            guard let self else { return }
            host?.paneStateChanged(self)
        }
        onToast = { [weak host] text in host?.paneToast(text) }
        onDialToast = { [weak host] text in host?.paneDialToast(text) }
        onVideoChanged = { [weak host, weak self] in
            guard let self else { return }
            host?.paneSlotChanged(self)
        }
        onBandAction = { [weak host, weak self] action in
            guard let self else { return }
            host?.pane(self, pressedBand: action)
        }
        onChooserAction = { [weak host, weak self] action in
            guard let self else { return }
            host?.pane(self, answeredChooser: action)
        }
        quotasForStatus = { [weak host] in host?.paneQuotas() ?? [] }
    }
}

extension TranscriptViewController {
    /// What this pane is for, as layout and the governor ask: a page, a stream, a conversation (or
    /// one a restore is holding for it), or the chooser.
    func paneKind(held: Bool) -> PaneKind {
        if isDrawing { return .draw }
        if isBrowsing { return .web }
        #if !TAILSCODE_MAS
            if isWatching { return .video }
        #endif
        return currentEntry != nil || held ? .chat : .empty
    }
}

/// The tiling host as the window drives it: the frame-placed canvas (`TileHost`, the default) and
/// the nested split controllers it replaces (`SplitPaneHost`, kept for one release behind
/// `tailscode.legacyTiling`) answer the same verbs, so the window never asks which one it holds.
@MainActor
protocol PaneTiling: NSViewController {
    var layout: SplitLayout { get }
    var panes: [PaneID: TranscriptViewController] { get }
    var active: TranscriptViewController { get }
    var paneCount: Int { get }
    var orderedPanes: [TranscriptViewController] { get }

    var makePane: (() -> TranscriptViewController)? { get set }
    var onPaneOpened: ((TranscriptViewController, String?) -> Void)? { get set }
    var onChatDropped: ((TranscriptViewController, PaneDragPayload, PaneDropZone) -> Bool)? {
        get set
    }
    var chatTitleForDrop: ((PaneDragPayload) -> String?)? { get set }
    var onFocusChanged: (() -> Void)? { get set }
    var onLayoutChanged: (() -> Void)? { get set }
    var heldSessions: (() -> [PaneID: SplitPaneSession])? { get set }
    var onRefused: ((String) -> Void)? { get set }
    /// A paused pane's Resume, pressed.
    var onResume: ((PaneID) -> Void)? { get set }

    func bootstrap()
    func id(of pane: TranscriptViewController) -> PaneID?
    func installOverlay(_ overlay: NSView)
    func pane(showing sessionID: String) -> TranscriptViewController?
    func eachPane(_ body: (TranscriptViewController) -> Void)
    func splitActive(axis: SplitAxis)
    @discardableResult
    func split(_ pane: TranscriptViewController, edge: PaneDropEdge) -> TranscriptViewController?
    func collapse(to keep: TranscriptViewController)
    func closeActive()
    @discardableResult
    func focusNeighbor(_ direction: SplitDirection) -> Bool
    func zoomActive()
    func exchangeActive()
    func equalize()
    func pane(atWindowPoint point: NSPoint) -> TranscriptViewController?
    func focus(_ pane: TranscriptViewController, grabKeyboard: Bool)
    func restore(_ snapshot: SplitSnapshot) -> [PaneID: SplitPaneSession]
    func snapshot() -> SplitSnapshot
    func persist()
    func flushPersistence()
    func applyFocusStyling()
    func setOccluded(_ occluded: Bool)
    func applyGovernor(_ decision: GovernorDecision)

    @discardableResult
    func cycleFocus(forward: Bool) -> Bool
    func promoteActive()
    func rotate(forward: Bool)
    func moveActiveToEdge(_ edge: SplitDirection)
    func arrange(_ arrangement: SplitArrangement?)
    func resizeActive(_ direction: SplitDirection, large: Bool)
    func togglePinActive()
    func toggleParkActive()
    var activeIsPinned: Bool { get }
    var activeIsParked: Bool { get }
    /// Whether this host gives panes densities at all; the legacy host keeps every pane full, so
    /// Keep Live and Pause Pane have nothing to act on there.
    var supportsDensity: Bool { get }

    #if DEBUG
        func driveOrder(_ label: String) -> String
        func driveGeometry() -> String
        func driveDividers() -> String
        func driveDivider(_ index: Int, key: DividerKey) -> Bool
        func drivePaneHover(target: Int, u: Double, v: Double, source: Int) -> String
        func drivePaneDrop(target: Int, u: Double, v: Double, source: Int) -> String
    #endif

    /// Chats a safe restore is holding paused, so the panes that hold them wear the paused face.
    func setHeld(_ held: [PaneID: SplitPaneSession])
    /// What the governor ranks and the recorder counts, asked once a second.
    func seatbeltPanes(held: [PaneID: SplitPaneSession]) -> SeatbeltPanes
}
