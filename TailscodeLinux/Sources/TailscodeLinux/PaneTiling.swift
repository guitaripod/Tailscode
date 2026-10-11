import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// What the window asks of whatever draws the tiling tree: the canvas (`TileHost`) or, behind
/// `TAILSCODE_LEGACY_TILING=1`, the nested panes it replaced (`SplitHost`). The window holds the
/// protocol and never learns which one it has; a verb the legacy host cannot do is a default here
/// that does nothing and says so.
protocol PaneTiling: AnyObject {
    var container: UnsafeMutablePointer<GtkWidget> { get }
    var layout: SplitLayout { get }
    var panes: [PaneID: ChatPane] { get }
    var activePane: ChatPane { get }
    var paneCount: Int { get }
    var orderedPanes: [ChatPane] { get }
    var dropSummary: String { get }
    var dropCaptionText: String { get }
    var canvasSummary: String { get }

    func pane(showing sessionID: String) -> ChatPane?
    func eachPane(_ body: (ChatPane) -> Void)
    func splitActive(axis: SplitAxis)
    func collapse(to keep: ChatPane)
    func closeActive()
    @discardableResult func focusNeighbor(_ direction: SplitDirection) -> Bool
    func zoomActive()
    func exchangeActive()
    func equalize()
    @discardableResult func perform(_ action: KeyAction) -> Bool
    func arrange(_ arrangement: SplitArrangement)
    @discardableResult func split(_ pane: ChatPane, edge: PaneDropEdge) -> ChatPane?
    func hover(_ pane: ChatPane, payload: PaneDragPayload, x: Double, y: Double)
    func hover(_ pane: ChatPane, moving dragged: PaneID, x: Double, y: Double)
    func clearDropHighlight()
    @discardableResult func receiveDrop(_ text: String, on id: PaneID, x: Double, y: Double) -> Bool
    @discardableResult func receivePaneDrop(_ text: String, on id: PaneID, x: Double, y: Double)
        -> Bool
    func pane(at x: Double, y: Double, in reference: UnsafeMutablePointer<GtkWidget>) -> ChatPane?
    func focus(_ pane: ChatPane, grabKeyboard: Bool)
    func snapshot() -> SplitSnapshot
    func restore(_ snapshot: SplitSnapshot) -> [PaneID: SplitPaneSession]
    func persist()
    @discardableResult func applyRatios() -> Bool
    func captureRatios()
    func dividerSummary(_ index: Int) -> String
    func driveDivider(_ index: Int, key: DividerKey) -> Bool
    func handleCenters(in reference: UnsafeMutablePointer<GtkWidget>) -> [(SplitID, Double, Double)]

    var supportsDensity: Bool { get }
    func setHeld(_ held: [PaneID: SplitPaneSession])
    func togglePinActive()
    func toggleParkActive()
    func resume(_ pane: PaneID)
}

extension PaneTiling {
    var supportsDensity: Bool { false }
    func setHeld(_ held: [PaneID: SplitPaneSession]) {}
    func togglePinActive() {}
    func toggleParkActive() {}
    func resume(_ pane: PaneID) {}
}

extension SplitHost: PaneTiling {}

/// Which host draws the tree: the canvas, unless the legacy nested panes were asked for.
enum TilingChoice {
    static var isLegacy: Bool {
        ProcessInfo.processInfo.environment["TAILSCODE_LEGACY_TILING"] == "1"
    }
}
