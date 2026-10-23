import AppKit
import TailscodeCore

/// The tiling tree made visible on the Mac: `SplitLayout` decides the arrangement, this renders
/// it as nested `NSSplitViewController`s and keeps the two in agreement — divider drags flow
/// back into the model as ratios, structural verbs rebuild the controller skeleton around the
/// surviving panes, and the zoom is collapse, not structure, so unzooming restores the exact
/// arrangement. Each pane is one `TranscriptViewController`, a complete conversation.
@MainActor
final class SplitPaneHost: NSViewController, PaneTiling {
    var layout = SplitLayout()
    private(set) var panes: [PaneID: TranscriptViewController] = [:]
    /// A pane born empty, with the server the split came from — the hub answers it with the
    /// chooser.
    var onPaneOpened: ((TranscriptViewController, String?) -> Void)?
    /// A chat let go over a pane — the hub opens it and resolves the zone.
    var onChatDropped: ((TranscriptViewController, PaneDragPayload, PaneDropZone) -> Bool)?
    /// Title for the drop caption while a chat is carried over a pane.
    var chatTitleForDrop: ((PaneDragPayload) -> String?)?
    var splitViews: [SplitID: NSSplitView] = [:]
    var splitItems: [SplitID: (first: NSSplitViewItem, second: NSSplitViewItem)] = [:]
    var splitLeaves: [SplitID: (first: Set<PaneID>, second: Set<PaneID>)] = [:]
    var treeRoot: NSViewController?
    var suppressCapture = false
    let dropHighlight = PaneDropHighlightView(frame: .zero)
    var dropZone: (pane: PaneID, zone: PaneDropZone)?

    /// The hub builds each pane so its closures — toasts, band actions, state observation — are
    /// wired the moment the pane exists, before anything can stream into it.
    var makePane: (() -> TranscriptViewController)?
    var onFocusChanged: (() -> Void)?
    var onLayoutChanged: (() -> Void)?
    /// Sessions panes hold without showing them yet — parked by a safe restore, waiting their turn
    /// in a staggered one, or waiting for their server — so a layout saved meanwhile keeps them
    /// rather than writing those panes down as empty.
    var heldSessions: (() -> [PaneID: SplitPaneSession])?
    /// A verb refused with a reason — a split with no room for another pane.
    var onRefused: ((String) -> Void)?
    var onResume: ((PaneID) -> Void)?
    /// Panes the governor parks on top of what zoom and occlusion already hide.
    var governorParked: Set<PaneID> = []
    var occluded = false
    /// The layout written a moment after the last change rather than on every focus move and every
    /// divider notification; nil clears the record. Flushed on every exit path.
    let writer = TrailingWriter<String?>(label: "tailscode.layout-writer") { encoded in
        if let encoded {
            UserDefaults.standard.set(encoded, forKey: SplitSnapshot.defaultsKey)
        } else {
            UserDefaults.standard.removeObject(forKey: SplitSnapshot.defaultsKey)
        }
    }
    /// Layout writes asked for, and divider notifications that moved a ratio — counted for the
    /// selftest that proves a burst of changes is one write and a programmatic resize is none.
    var persistRequests = 0
    var ratioCaptures = 0

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let root = NSView()
        dropHighlight.autoresizingMask = []
        root.addSubview(dropHighlight)
        view = root
    }

    /// Creates the first pane once the hub has handed over its factory.
    func bootstrap() {
        guard panes.isEmpty, let makePane else { return }
        let pane = makePane()
        panes[layout.focusedPane] = pane
        installDropTarget(on: pane)
        rebuild()
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

    /// Lays a strip across the top of the pane area, above every pane and under the toolbar. The
    /// tree is always rebuilt beneath what is already here, so an overlay stays on top without
    /// ever being moved.
    func installOverlay(_ overlay: NSView) {
        overlay.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(overlay, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
        ])
    }

    func pane(showing sessionID: String) -> TranscriptViewController? {
        orderedPanes.first { $0.currentEntry?.session.id == sessionID }
    }

    func eachPane(_ body: (TranscriptViewController) -> Void) {
        for pane in orderedPanes { body(pane) }
    }

    /// Splits the focused pane; the new pane opens focused and asking which server, so the split
    /// itself is the moment the second machine gets chosen — the chat list, or a subsequent open,
    /// can still fill it instead.
    func splitActive(axis: SplitAxis) {
        let source = active.currentEntry?.profileID
        guard hasRoom(layout.focusedPane, axis: axis) else { return }
        guard let makePane, let freshID = layout.split(layout.focusedPane, axis: axis) else {
            return
        }
        let pane = makePane()
        panes[freshID] = pane
        installDropTarget(on: pane)
        rebuild()
        onPaneOpened?(pane, source)
        onFocusChanged?()
        persist()
    }

    /// Splits `pane` and hands back the fresh pane on the side a drop was aimed at.
    @discardableResult
    func split(_ pane: TranscriptViewController, edge: PaneDropEdge) -> TranscriptViewController? {
        guard let makePane,
            let id = panes.first(where: { $0.value === pane })?.key,
            hasRoom(id, axis: edge.axis),
            let freshID = layout.split(id, axis: edge.axis, placingNewFirst: edge.placesArrivalFirst)
        else { return nil }
        let fresh = makePane()
        panes[freshID] = fresh
        installDropTarget(on: fresh)
        rebuild()
        onFocusChanged?()
        persist()
        return fresh
    }

    /// Whether a pane can halve along `axis` in the room the tree really has, asked of Core's
    /// placement at the container's size; a refusal is said rather than swallowed.
    func canSplit(_ id: PaneID, axis: SplitAxis) -> Bool {
        let size = view.bounds.size
        guard size.width > 0, size.height > 0 else { return true }
        let placement = layout.placement(
            in: SplitSize(width: Double(size.width), height: Double(size.height)),
            scale: Double(view.window?.backingScaleFactor ?? 2))
        return layout.canSplit(id, axis: axis, in: placement)
    }

    private func hasRoom(_ id: PaneID, axis: SplitAxis) -> Bool {
        guard canSplit(id, axis: axis) else {
            onRefused?(Localized.text("No room for another split here"))
            return false
        }
        return true
    }

    /// The whole tree collapsed onto one pane: every other pane closes, the kept one inherits
    /// the window and the focus. This is the unsplit gesture — one press, not a close per pane.
    func collapse(to keep: TranscriptViewController) {
        guard let keepID = panes.first(where: { $0.value === keep })?.key,
            layout.contains(keepID)
        else { return }
        for id in layout.paneIDs where id != keepID {
            guard layout.close(id) != nil else { continue }
            if let pane = panes.removeValue(forKey: id) {
                pane.shutdownPane()
                pane.removeFromParent()
                pane.view.removeFromSuperview()
            }
        }
        layout.focus(keepID)
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

    /// The tree laid out in the area the panes actually have, which is what the resize verbs and a
    /// divider's own range are read from. Every pane is held to the floor this host gives the split
    /// items — the same one AppKit enforces on a pointer drag, so a key and a drag stop at the same
    /// line, and one that never outgrows the room, so no pane is ever left out of the solve.
    func currentPlacement() -> PanePlacement {
        let size = view.bounds.size
        return layout.placement(
            in: SplitSize(width: Double(size.width), height: Double(size.height)),
            scale: Double(view.window?.backingScaleFactor ?? 2), stripHeight: 0
        ) { [self] id in
            panes[id] == nil
                ? .zero
                : PaneMinimum(
                    width: Double(paneFloor(.horizontal)), height: Double(paneFloor(.vertical)))
        }
    }

    /// The registered pane chords that act on the tree itself — arrange, promote, rotate, move to
    /// an edge, resize, cycle — through Core's one dispatcher, so this desktop and the Linux one
    /// cannot mean different things by the same key. A chord with nothing to do (one pane has
    /// nothing to rotate) is still the tree's, and is spent rather than handed on.
    @discardableResult
    func perform(_ action: KeyAction) -> Bool {
        guard let effect = layout.perform(action, placement: currentPlacement()) else {
            return true
        }
        applyEffect(effect)
        return true
    }

    /// Rebuilds the tree as the arrangement a menu item named.
    func arrange(_ arrangement: SplitArrangement) {
        guard let effect = layout.choose(arrangement) else { return }
        applyEffect(effect)
    }

    /// Redoes only as much of the window as the verb undid and writes the tree down. A verb that
    /// only moves panes about leaves the keyboard where it is, so the chord can be pressed again.
    private func applyEffect(_ effect: SplitVerbEffect) {
        switch effect {
        case .restructured:
            rebuild()
        case .resized:
            settleRatios()
        case .refocused:
            applyZoom()
            applyFocusStyling()
        }
        onFocusChanged?()
        persist()
    }

    /// A key on a focused divider, or VoiceOver stepping an adjustable one: the same clamped move
    /// the pointer makes.
    func moveDivider(_ split: SplitID, by key: DividerKey) -> Bool {
        guard layout.move(split, by: key, in: currentPlacement()) else { return true }
        settleRatios()
        schedulePersist()
        return true
    }

    /// What a divider tells assistive technology: which two panes it divides, and its position
    /// between the extremes it can travel, in Core's words.
    func dividerReading(_ split: SplitID) -> DividerAccessibilityReading? {
        let placement = currentPlacement()
        guard let divider = placement.divider(split), let sides = layout.sides(of: split) else {
            return nil
        }
        func names(_ ids: [PaneID]) -> [String] {
            ids.map { id in
                let name = panes[id]?.paneName ?? ""
                return name.isEmpty ? Localized.text("Pane") : name
            }
        }
        var standing = divider
        if let first = (splitViews[split])?.arrangedSubviews.first {
            let held = Double(splitViews[split]?.isVertical == true ? first.frame.width : first.frame.height)
            standing.position = min(max(held, divider.lowest), divider.highest)
        }
        return DividerAccessibilityReading(
            label: DividerReading.label(first: names(sides.first), second: names(sides.second)),
            value: DividerReading.value(standing), position: standing.position,
            minimum: divider.lowest, maximum: divider.highest)
    }

    /// Every pane its fair share, from the menu verb or a double click on any divider.
    func equalize() {
        layout.equalize()
        settleRatios()
        persist()
    }

    /// The pane a point in window coordinates lands in. A press on a divider, on a collapsed
    /// pane's ghost, or on the chrome beside the tree belongs to no pane and changes nothing —
    /// which is why this hit tests the pane views themselves rather than the tree's bounds.
    func pane(atWindowPoint point: NSPoint) -> TranscriptViewController? {
        Self.hitTest(orderedPanes, at: point)
    }

    /// The geometry rule on its own, so the selftest can assert it over plain controllers: the
    /// first one whose view is loaded, in a window, on screen, and actually under the point.
    static func hitTest<Controller: NSViewController>(
        _ controllers: [Controller], at point: NSPoint
    ) -> Controller? {
        controllers.first { controller in
            guard controller.isViewLoaded, controller.view.window != nil,
                !controller.view.isHiddenOrHasHiddenAncestor
            else { return false }
            let local = controller.view.convert(point, from: nil)
            return NSMouseInRect(local, controller.view.bounds, controller.view.isFlipped)
        }
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
            let pane = makePane()
            panes[id] = pane
            installDropTarget(on: pane)
            if let address = snapshot.draw(for: id) {
                pane.showDraw(ImageGenEndpoint(address: address))
                continue
            }
            #if !TAILSCODE_MAS
                if let target = snapshot.page(for: id) {
                    pane.showWeb(target)
                    continue
                }
            #endif
            #if !TAILSCODE_MAS
                if let target = snapshot.video(for: id) {
                    pane.showVideo(target)
                    continue
                }
            #endif
            if let session = snapshot.session(for: id) { bindings[id] = session }
        }
        rebuild()
        return bindings
    }

    func rotate(forward: Bool) {
        guard layout.rotate(forward: forward) else { return }
        rebuild()
        persist()
    }

    func moveActiveToEdge(_ edge: SplitDirection) {
        guard layout.moveToEdge(layout.focusedPane, edge: edge) else { return }
        rebuild()
        persist()
    }

    func arrange(_ arrangement: SplitArrangement?) {
        let next = arrangement ?? SplitEven.shape(of: layout).nextInCycle
        guard layout.arrange(next) else { return }
        rebuild()
        persist()
    }

    func resizeActive(_ direction: SplitDirection, large: Bool) {
        let size = view.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let placement = layout.placement(
            in: SplitSize(width: Double(size.width), height: Double(size.height)),
            scale: Double(view.window?.backingScaleFactor ?? 2))
        let step = large ? PaneSizing.keyboardStepLarge : PaneSizing.keyboardStep
        guard layout.resize(layout.focusedPane, direction, step: step, in: placement) else { return }
        applyRatios()
        schedulePersist()
    }

    /// The bench's divider step: the outermost divider moved by `delta` points, as a drag does.
    func benchNudgeFirstDivider(by delta: CGFloat) {
        guard case .split(let id, _, _, _, _) = layout.root, let splitView = splitViews[id],
            let first = splitView.arrangedSubviews.first
        else { return }
        let position = splitView.isVertical ? first.frame.width : first.frame.height
        splitView.setPosition(position + delta, ofDividerAt: 0)
    }

    func togglePinActive() {}
    func toggleParkActive() {}
    var activeIsPinned: Bool { false }
    var activeIsParked: Bool { false }
    var supportsDensity: Bool { false }
    func setHeld(_ held: [PaneID: SplitPaneSession]) {}

    /// Today's panes as the governor ranks them, and the counts the flight recorder keeps.
    func seatbeltPanes(held: [PaneID: SplitPaneSession]) -> SeatbeltPanes {
        var seen = SeatbeltPanes()
        for paneID in layout.paneIDs {
            guard let pane = panes[paneID] else { continue }
            let placed = layout.zoomedPane == nil || layout.zoomedPane == paneID
            let size = pane.isViewLoaded ? pane.view.bounds.size : .zero
            let running = pane.currentState?.status == .running
            seen.facts.append(
                PaneFacts(
                    id: paneID, kind: pane.paneKind(held: held[paneID] != nil),
                    focused: paneID == layout.focusedPane, placed: placed,
                    width: Double(size.width), height: Double(size.height),
                    attention: running ? .running : .quiet))
            if !placed {
                seen.hidden += 1
            } else if held[paneID] != nil {
                seen.parked += 1
            } else {
                seen.live += 1
                if running {
                    seen.streaming += 1
                    if paneID == layout.focusedPane { seen.focusedStreaming = true }
                }
            }
        }
        seen.occluded = occluded
        return seen
    }

    /// A hairline accent on the focused pane, only once a second pane exists to be told apart
    /// from — a lone pane stays exactly the window it always was. The border is a `CGColor` and so
    /// keeps the accent it was born with, which is why the window asks for this again whenever the
    /// palette changes, beside the pane colours it repaints in the same moment.
    func applyFocusStyling() {
        let showAccent = layout.paneCount > 1
        for (id, pane) in panes {
            pane.setFocusedPane(id == layout.focusedPane)
            let layer = pane.view.layer
            if showAccent, id == layout.focusedPane {
                layer?.borderColor = MacTheme.Color.accent.withAlphaComponent(0.55).cgColor
                layer?.borderWidth = 1
            } else {
                layer?.borderWidth = 0
            }
        }
    }

    func applyIdentity() {
        let several = layout.paneCount > 1 && layout.zoomedPane == nil
        for pane in panes.values { pane.setIdentityVisible(several) }
    }
}
