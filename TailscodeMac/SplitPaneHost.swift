import AppKit
import TailscodeCore

/// The tiling tree made visible on the Mac: `SplitLayout` decides the arrangement, this renders
/// it as nested `NSSplitViewController`s and keeps the two in agreement — divider drags flow
/// back into the model as ratios, structural verbs rebuild the controller skeleton around the
/// surviving panes, and the zoom is collapse, not structure, so unzooming restores the exact
/// arrangement. Each pane is one `TranscriptViewController`, a complete conversation.
@MainActor
final class SplitPaneHost: NSViewController {
    private(set) var layout = SplitLayout()
    private(set) var panes: [PaneID: TranscriptViewController] = [:]
    private var splitViews: [SplitID: NSSplitView] = [:]
    private var splitItems: [SplitID: (first: NSSplitViewItem, second: NSSplitViewItem)] = [:]
    private var splitLeaves: [SplitID: (first: Set<PaneID>, second: Set<PaneID>)] = [:]
    private var treeRoot: NSViewController?
    private var suppressCapture = false

    /// The hub builds each pane so its closures — toasts, band actions, state observation — are
    /// wired the moment the pane exists, before anything can stream into it.
    var makePane: (() -> TranscriptViewController)?
    var onFocusChanged: (() -> Void)?
    var onLayoutChanged: (() -> Void)?

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        view = NSView()
    }

    /// Creates the first pane once the hub has handed over its factory.
    func bootstrap() {
        guard panes.isEmpty, let makePane else { return }
        panes[layout.focusedPane] = makePane()
        rebuild()
    }

    var active: TranscriptViewController {
        panes[layout.focusedPane] ?? panes.values.first!
    }

    var paneCount: Int { layout.paneCount }

    var orderedPanes: [TranscriptViewController] {
        layout.paneIDs.compactMap { panes[$0] }
    }

    func pane(showing sessionID: String) -> TranscriptViewController? {
        orderedPanes.first { $0.currentEntry?.session.id == sessionID }
    }

    func eachPane(_ body: (TranscriptViewController) -> Void) {
        for pane in orderedPanes { body(pane) }
    }

    /// Splits the focused pane; the new pane opens empty and focused, ready for the chat list —
    /// or a subsequent open — to fill it.
    func splitActive(axis: SplitAxis) {
        guard let makePane, let freshID = layout.split(layout.focusedPane, axis: axis) else {
            return
        }
        panes[freshID] = makePane()
        rebuild()
        onFocusChanged?()
        persist()
    }

    /// Closes the focused pane; its conversation stops streaming and the sibling inherits the
    /// space. The last pane refuses — a window with no conversation surface is not this app.
    func closeActive() {
        let closing = layout.focusedPane
        guard layout.close(closing) != nil else { return }
        if let pane = panes.removeValue(forKey: closing) {
            pane.shutdownPane()
            pane.removeFromParent()
            pane.view.removeFromSuperview()
        }
        rebuild()
        onFocusChanged?()
        persist()
    }

    @discardableResult
    func focusNeighbor(_ direction: SplitDirection) -> Bool {
        let wasZoomed = layout.zoomedPane != nil
        let moved = layout.focusNeighbor(direction)
        if wasZoomed { applyZoom() }
        guard moved || wasZoomed else { return false }
        applyFocusStyling()
        onFocusChanged?()
        persist()
        return moved
    }

    func zoomActive() {
        layout.toggleZoom(layout.focusedPane)
        applyZoom()
        applyFocusStyling()
        persist()
    }

    func exchangeActive() {
        layout.exchange(layout.focusedPane)
        rebuild()
        persist()
    }

    func equalize() {
        layout.equalize()
        applyRatios()
        persist()
    }

    /// Focus by intent: a keyboard move also asks the pane to take the keyboard; a click leaves
    /// AppKit's first responder where the click put it.
    func focus(_ pane: TranscriptViewController, grabKeyboard: Bool) {
        guard let id = panes.first(where: { $0.value === pane })?.key,
            layout.focusedPane != id
        else { return }
        layout.focus(id)
        applyFocusStyling()
        if grabKeyboard { pane.focusComposer() }
        onFocusChanged?()
        persist()
    }

    /// Rebuilds panes from a persisted arrangement and hands back what each pane was showing.
    /// The sessions themselves resolve later, from the cached listing — restore never waits on a
    /// server to draw the window's shape.
    func restore(_ snapshot: SplitSnapshot) -> [PaneID: SplitPaneSession] {
        guard let makePane, snapshot.layout.isValid else { return [:] }
        for pane in panes.values {
            pane.shutdownPane()
            pane.removeFromParent()
            pane.view.removeFromSuperview()
        }
        panes = [:]
        layout = snapshot.layout
        var bindings: [PaneID: SplitPaneSession] = [:]
        for id in layout.paneIDs {
            panes[id] = makePane()
            if let session = snapshot.session(for: id) { bindings[id] = session }
        }
        rebuild()
        return bindings
    }

    func snapshot() -> SplitSnapshot {
        var sessions: [String: SplitPaneSession] = [:]
        for (id, pane) in panes {
            guard let entry = pane.currentEntry else { continue }
            sessions[id.raw] = SplitPaneSession(
                profileID: entry.profileID, sessionID: entry.session.id)
        }
        return SplitSnapshot(layout: layout, sessions: sessions)
    }

    /// The same key and shape the Linux desktop persists, so both restore the same arrangement.
    /// A lone pane clears the record: the plain window needs no layout file.
    func persist() {
        if paneCount > 1, let encoded = snapshot().encoded {
            UserDefaults.standard.set(encoded, forKey: SplitSnapshot.defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: SplitSnapshot.defaultsKey)
        }
        onLayoutChanged?()
    }

    /// Rebuilds the controller skeleton around the surviving panes. Panes detach first so no
    /// `NSSplitViewItem` still claims them when they join the new tree.
    private func rebuild() {
        for pane in panes.values {
            pane.removeFromParent()
            pane.view.removeFromSuperview()
        }
        if let treeRoot {
            treeRoot.removeFromParent()
            treeRoot.view.removeFromSuperview()
        }
        splitViews = [:]
        splitItems = [:]
        splitLeaves = [:]
        let built = build(layout.root)
        addChild(built)
        built.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(built.view)
        NSLayoutConstraint.activate([
            built.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            built.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            built.view.topAnchor.constraint(equalTo: view.topAnchor),
            built.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        treeRoot = built
        applyZoom()
        applyFocusStyling()
        applyIdentity()
        DispatchQueue.main.async { [weak self] in self?.applyRatios() }
    }

    private func build(_ node: SplitNode) -> NSViewController {
        switch node {
        case .pane(let id):
            guard let pane = panes[id] else { return NSViewController() }
            pane.removeFromParent()
            pane.view.removeFromSuperview()
            return pane
        case .split(let id, let axis, _, let first, let second):
            let controller = NSSplitViewController()
            controller.splitView.isVertical = axis == .horizontal
            controller.splitView.dividerStyle = .thin
            let firstItem = NSSplitViewItem(viewController: build(first))
            let secondItem = NSSplitViewItem(viewController: build(second))
            for item in [firstItem, secondItem] {
                item.minimumThickness = axis == .horizontal ? 280 : 160
                item.canCollapse = false
            }
            controller.addSplitViewItem(firstItem)
            controller.addSplitViewItem(secondItem)
            splitViews[id] = controller.splitView
            splitItems[id] = (firstItem, secondItem)
            splitLeaves[id] = (Set(Self.leaves(of: first)), Set(Self.leaves(of: second)))
            NotificationCenter.default.addObserver(
                self, selector: #selector(splitResized(_:)),
                name: NSSplitView.didResizeSubviewsNotification, object: controller.splitView)
            return controller
        }
    }

    private static func leaves(of node: SplitNode) -> [PaneID] {
        switch node {
        case .pane(let id): return [id]
        case .split(_, _, _, let first, let second):
            return leaves(of: first) + leaves(of: second)
        }
    }

    /// Positions from ratios, asserted after layout so the split has an extent to divide.
    func applyRatios() {
        suppressCapture = true
        defer { suppressCapture = false }
        view.layoutSubtreeIfNeeded()
        for (id, splitView) in splitViews {
            guard let ratio = layout.ratio(of: id) else { continue }
            let extent =
                splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
            guard extent > 50 else { continue }
            splitView.setPosition(extent * ratio, ofDividerAt: 0)
        }
    }

    /// A divider drag settles into the model as a ratio, exactly the way the window's own
    /// dividers persist — mid-collapse widths that are nobody's intent are ignored.
    @objc private func splitResized(_ notification: Notification) {
        guard !suppressCapture,
            let splitView = notification.object as? NSSplitView,
            let id = splitViews.first(where: { $0.value === splitView })?.key,
            let firstView = splitView.arrangedSubviews.first
        else { return }
        let extent = splitView.isVertical ? splitView.bounds.width : splitView.bounds.height
        let position = splitView.isVertical ? firstView.frame.width : firstView.frame.height
        guard extent > 150, position > 40, position < extent - 40 else { return }
        layout.setRatio(position / extent, of: id)
        if paneCount > 1, let encoded = snapshot().encoded {
            UserDefaults.standard.set(encoded, forKey: SplitSnapshot.defaultsKey)
        }
    }

    /// The zoom is collapse along the tree: every split hides the side that does not contain the
    /// zoomed pane, so one conversation borrows the whole surface and unzooming shows everything
    /// exactly where it was.
    private func applyZoom() {
        let zoomed = layout.zoomedPane
        for (id, items) in splitItems {
            guard let zoomed, let leaves = splitLeaves[id] else {
                items.first.isCollapsed = false
                items.second.isCollapsed = false
                continue
            }
            items.first.isCollapsed = leaves.second.contains(zoomed)
            items.second.isCollapsed = leaves.first.contains(zoomed)
        }
    }

    /// A hairline accent on the focused pane, only once a second pane exists to be told apart
    /// from — a lone pane stays exactly the window it always was.
    private func applyFocusStyling() {
        let showAccent = layout.paneCount > 1
        for (id, pane) in panes {
            let layer = pane.view.layer
            if showAccent, id == layout.focusedPane {
                layer?.borderColor = MacTheme.Color.accent.withAlphaComponent(0.55).cgColor
                layer?.borderWidth = 1
            } else {
                layer?.borderWidth = 0
            }
        }
    }

    private func applyIdentity() {
        let several = layout.paneCount > 1
        for pane in panes.values { pane.setIdentityVisible(several) }
    }
}
