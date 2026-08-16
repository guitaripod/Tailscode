import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The tiling tree made visible: `SplitLayout` decides the arrangement, this turns it into
/// nested `GtkPaned` widgets and keeps the two in agreement — divider drags flow back into the
/// model as ratios, structural verbs rebuild the widget skeleton around the surviving panes,
/// and the zoom is nothing but visibility, so unzooming costs no rebuild at all.
final class SplitHost: @unchecked Sendable {
    let container = gtk_overlay_new()!
    private let treeBox = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    private let dropHighlight = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    private let dropCaption = Gtk.label("", css: "drop-caption", selectable: false)
    private var dropZone: (pane: PaneID, zone: PaneDropZone)?
    private(set) var layout: SplitLayout
    private(set) var panes: [PaneID: ChatPane] = [:]
    private var splitWidgets: [SplitID: UInt] = [:]
    private weak var host: MainWindow?

    init(host: MainWindow) {
        self.host = host
        layout = SplitLayout()
        gtk_widget_set_hexpand(container, 1)
        gtk_widget_set_vexpand(container, 1)
        gtk_widget_set_hexpand(treeBox, 1)
        gtk_widget_set_vexpand(treeBox, 1)
        gtk_overlay_set_child(op(container), treeBox)
        buildDropHighlight()
        let pane = makePane(layout.focusedPane)
        panes[pane.id] = pane
        rebuild()
    }

    /// The arrangement a drop would make, drawn over the panes rather than inside one: it has to
    /// be able to cover half a pane exactly, and it must never take the pointer events the drop
    /// target underneath it is still reading.
    private func buildDropHighlight() {
        Gtk.addClass(dropHighlight, "drop-zone")
        gtk_widget_set_can_target(dropHighlight, 0)
        gtk_widget_set_halign(dropHighlight, GTK_ALIGN_START)
        gtk_widget_set_valign(dropHighlight, GTK_ALIGN_START)
        gtk_widget_set_visible(dropHighlight, 0)
        gtk_label_set_max_width_chars(op(dropCaption), 18)
        gtk_label_set_xalign(op(dropCaption), 0.5)
        gtk_widget_set_halign(dropCaption, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(dropCaption, GTK_ALIGN_CENTER)
        gtk_widget_set_vexpand(dropCaption, 1)
        gtk_box_append(ptr(dropHighlight), dropCaption)
        gtk_overlay_add_overlay(op(container), dropHighlight)
    }

    /// Every pane is a place a dragged chat can land, so a pane is never built without its drop
    /// target — including the ones a restore or a drop itself mints.
    private func makePane(_ id: PaneID) -> ChatPane {
        let pane = ChatPane(id: id, host: host!)
        Gtk.acceptChatDrops(
            on: pane.root,
            motion: { [weak self] payload, x, y in
                self?.dragMoved(over: id, payload: payload, x: x, y: y)
            },
            leave: { [weak self] in self?.clearDropHighlight() },
            drop: { [weak self] payload, x, y in
                self?.receiveDrop(payload, on: id, x: x, y: y) ?? false
            })
        return pane
    }

    var activePane: ChatPane {
        panes[layout.focusedPane] ?? panes.values.first!
    }

    var paneCount: Int { layout.paneCount }

    /// Panes in the tree's reading order — the order the driver and the keyboard walk them.
    var orderedPanes: [ChatPane] {
        layout.paneIDs.compactMap { panes[$0] }
    }

    func pane(showing sessionID: String) -> ChatPane? {
        orderedPanes.first { $0.sessionID == sessionID }
    }

    func eachPane(_ body: (ChatPane) -> Void) {
        for pane in orderedPanes { body(pane) }
    }

    /// Splits the focused pane; the new pane opens focused and asking which server, so the split
    /// itself is the moment the second machine gets chosen — the chat list, or a subsequent open,
    /// can still fill it instead.
    func splitActive(axis: SplitAxis) {
        guard let host else { return }
        let source = activePane.entry?.profileID
        guard let freshID = layout.split(layout.focusedPane, axis: axis) else { return }
        let pane = makePane(freshID)
        panes[freshID] = pane
        rebuild()
        host.presentChooser(in: pane, preferring: source)
        pane.focusTranscript()
        host.focusedPaneChanged()
        persist()
    }

    /// The whole tree collapsed onto one pane: every other pane closes, the kept one inherits
    /// the window and the focus. This is the unsplit gesture — one press, not a close per pane.
    func collapse(to keep: ChatPane) {
        guard layout.contains(keep.id) else { return }
        for id in layout.paneIDs where id != keep.id {
            guard layout.close(id) != nil else { continue }
            if let pane = panes.removeValue(forKey: id) { pane.shutdown() }
        }
        layout.focus(keep.id)
        rebuild()
        host?.focusedPaneChanged()
        persist()
    }

    /// Closes the focused pane; its conversation stops streaming and the sibling inherits the
    /// space. The last pane refuses — a window with no conversation surface is not this app.
    func closeActive() {
        let closing = layout.focusedPane
        guard layout.close(closing) != nil else { return }
        if let pane = panes.removeValue(forKey: closing) {
            pane.shutdown()
        }
        rebuild()
        host?.focusedPaneChanged()
        persist()
    }

    @discardableResult
    func focusNeighbor(_ direction: SplitDirection) -> Bool {
        let wasZoomed = layout.zoomedPane != nil
        let moved = layout.focusNeighbor(direction)
        if wasZoomed { applyZoomVisibility() }
        guard moved || wasZoomed else { return false }
        applyFocusStyling()
        if moved { activePane.focusTranscript() }
        host?.focusedPaneChanged()
        persist()
        return moved
    }

    func zoomActive() {
        layout.toggleZoom(layout.focusedPane)
        applyZoomVisibility()
        applyFocusStyling()
        persist()
    }

    func exchangeActive() {
        layout.exchange(layout.focusedPane)
        rebuild()
        persist()
    }

    /// Every pane its fair share, from the keyboard verb or a double click on any divider.
    func equalize() {
        layout.equalize()
        applyRatios()
        persist()
    }

    /// Splits `pane` and hands back the fresh pane on the side a drop was aimed at — the highlight
    /// promised that half, so the tree has to put it there rather than always second.
    @discardableResult
    func split(_ pane: ChatPane, edge: PaneDropEdge) -> ChatPane? {
        guard
            let freshID = layout.split(
                pane.id, axis: edge.axis, placingNewFirst: edge.placesArrivalFirst)
        else { return nil }
        let fresh = makePane(freshID)
        panes[freshID] = fresh
        rebuild()
        host?.focusedPaneChanged()
        persist()
        return fresh
    }

    /// The same drag the pointer makes, without a pointer — what the headless driver aims with.
    func hover(_ pane: ChatPane, payload: PaneDragPayload, x: Double, y: Double) {
        dragMoved(over: pane.id, payload: payload.encoded, x: x, y: y)
    }

    /// A chat dragged over a pane, followed live: the region it would take is drawn where it would
    /// be, captioned with what letting go means.
    private func dragMoved(over id: PaneID, payload: String?, x: Double, y: Double) {
        guard let pane = panes[id] else { return }
        let width = Double(gtk_widget_get_width(pane.root))
        let height = Double(gtk_widget_get_height(pane.root))
        let zone = PaneDropTarget.zone(x: x, y: y, width: width, height: height)
        let title = payload.flatMap(PaneDragPayload.decode).flatMap { host?.chatTitle(for: $0) }
        showDropHighlight(zone, on: pane, caption: zone.caption(title))
    }

    private func showDropHighlight(_ zone: PaneDropZone, on pane: ChatPane, caption: String) {
        guard let bounds = Gtk.bounds(of: pane.root, in: container) else { return }
        let rect = PaneDropTarget.highlight(
            for: zone, width: bounds.width, height: bounds.height)
        dropZone = (pane.id, zone)
        gtk_label_set_text(op(dropCaption), caption)
        Gtk.margins(
            dropHighlight, top: Int32((bounds.y + rect.y).rounded()),
            leading: Int32((bounds.x + rect.x).rounded()))
        gtk_widget_set_size_request(
            dropHighlight, Int32(rect.width.rounded()), Int32(rect.height.rounded()))
        gtk_widget_set_visible(dropHighlight, 1)
    }

    func clearDropHighlight() {
        dropZone = nil
        gtk_widget_set_visible(dropHighlight, 0)
    }

    /// A chat let go over a pane. The zone is read again at the drop rather than trusted from the
    /// last motion, so what lands is what the pointer was over when the button came up.
    @discardableResult
    func receiveDrop(_ text: String, on id: PaneID, x: Double, y: Double) -> Bool {
        clearDropHighlight()
        guard let pane = panes[id], let payload = PaneDragPayload.decode(text) else { return false }
        let zone = PaneDropTarget.zone(
            x: x, y: y, width: Double(gtk_widget_get_width(pane.root)),
            height: Double(gtk_widget_get_height(pane.root)))
        return host?.pane(pane, received: payload, zone: zone) ?? false
    }

    /// What the headless driver reads: which pane a drag is over and what letting go would do.
    var dropSummary: String {
        guard let dropZone, let index = layout.paneIDs.firstIndex(of: dropZone.pane) else {
            return "-"
        }
        return "\(index) \(dropZone.zone)"
    }

    /// The pane a point in `reference`'s coordinates lands in. A press on a divider, on a pane the
    /// zoom has hidden, or on the chrome beside the tree belongs to no pane and changes nothing —
    /// which is why this asks the pane widgets where they are rather than carving up the window.
    func pane(at x: Double, y: Double, in reference: UnsafeMutablePointer<GtkWidget>) -> ChatPane? {
        orderedPanes.first { Gtk.contains($0.root, x: x, y: y, in: reference) }
    }

    /// Focus by intent: a keyboard move also moves the keyboard into the pane; a click leaves
    /// GTK's own focus where the click put it.
    func focus(_ pane: ChatPane, grabKeyboard: Bool) {
        guard layout.focusedPane != pane.id else { return }
        layout.focus(pane.id)
        applyFocusStyling()
        if grabKeyboard { pane.focusTranscript() }
        host?.focusedPaneChanged()
        persist()
    }

    /// Rebuilds the paned skeleton around the surviving pane widgets. Every pane root is
    /// referenced across the teardown so the old tree's death cannot take a live conversation's
    /// widgets with it.
    private func rebuild() {
        for pane in panes.values {
            g_object_ref(UnsafeMutableRawPointer(pane.root))
            Gtk.detachFromParent(pane.root)
        }
        clearDropHighlight()
        Gtk.removeChildren(of: treeBox)
        splitWidgets = [:]
        let treeRoot = build(layout.root)
        gtk_box_append(ptr(treeBox), treeRoot)
        for pane in panes.values {
            g_object_unref(UnsafeMutableRawPointer(pane.root))
        }
        applyZoomVisibility()
        applyFocusStyling()
        applyIdentityStrips()
        Gtk.onMain { [weak self] in self?.applyRatios() }
        Gtk.after(120) { [weak self] in self?.applyRatios() }
    }

    private func build(_ node: SplitNode) -> UnsafeMutablePointer<GtkWidget> {
        switch node {
        case .pane(let id):
            guard let pane = panes[id] else {
                return Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
            }
            Gtk.detachFromParent(pane.root)
            return pane.root
        case .split(let id, let axis, _, let first, let second):
            let paned = gtk_paned_new(
                axis == .horizontal ? GTK_ORIENTATION_HORIZONTAL : GTK_ORIENTATION_VERTICAL)!
            gtk_paned_set_start_child(op(paned), build(first))
            gtk_paned_set_end_child(op(paned), build(second))
            gtk_paned_set_resize_start_child(op(paned), 1)
            gtk_paned_set_resize_end_child(op(paned), 1)
            gtk_paned_set_shrink_start_child(op(paned), 1)
            gtk_paned_set_shrink_end_child(op(paned), 1)
            gtk_widget_set_hexpand(paned, 1)
            gtk_widget_set_vexpand(paned, 1)
            Gtk.onPanedHandleDoubleClick(paned) { [weak self] in
                self?.equalize()
            }
            splitWidgets[id] = UInt(bitPattern: paned)
            return paned
        }
    }

    /// Positions from ratios, walked top-down with each child's extent computed from the position
    /// its parent was just given — a nested paned only learns its new allocation at the next
    /// layout pass, so reading extents back mid-walk would apply an inner ratio to an arrangement
    /// the outer divider is about to stop having. The tree that has not been allocated yet
    /// reports no extent, which is why this runs on the next idle and once more shortly after a
    /// rebuild.
    func applyRatios() {
        let width = Double(gtk_widget_get_width(treeBox))
        let height = Double(gtk_widget_get_height(treeBox))
        guard width > 50, height > 50 else { return }
        applyRatios(layout.root, width: width, height: height)
    }

    private func applyRatios(_ node: SplitNode, width: Double, height: Double) {
        guard case .split(let id, let axis, let ratio, let first, let second) = node,
            let bits = splitWidgets[id],
            let raw = UnsafeMutableRawPointer(bitPattern: bits)
        else { return }
        let paned: UnsafeMutablePointer<GtkWidget> = ptr(raw)
        let horizontal = axis == .horizontal
        let extent = horizontal ? width : height
        let handle = handleThickness(of: paned, horizontal: horizontal)
        let position = ((extent - handle) * ratio).rounded()
        gtk_paned_set_position(op(paned), Int32(position))
        let remainder = extent - handle - position
        if horizontal {
            applyRatios(first, width: position, height: height)
            applyRatios(second, width: remainder, height: height)
        } else {
            applyRatios(first, width: width, height: position)
            applyRatios(second, width: width, height: remainder)
        }
    }

    /// The separator's share of a paned's extent, measured from what the children were actually
    /// given rather than assumed from CSS. Clamped because a paned mid-rebuild or mid-zoom has
    /// children whose stale allocations would otherwise read as a handle the size of the gap.
    private func handleThickness(
        of paned: UnsafeMutablePointer<GtkWidget>, horizontal: Bool
    ) -> Double {
        guard let start = gtk_paned_get_start_child(op(paned)),
            let end = gtk_paned_get_end_child(op(paned))
        else { return 0 }
        let total = horizontal ? gtk_widget_get_width(paned) : gtk_widget_get_height(paned)
        let first = horizontal ? gtk_widget_get_width(start) : gtk_widget_get_height(start)
        let second = horizontal ? gtk_widget_get_width(end) : gtk_widget_get_height(end)
        guard first > 0, second > 0 else { return 0 }
        return Double(min(8, max(0, total - first - second)))
    }

    /// Ratios from positions, on the same slow tick the window's own dividers use —
    /// `notify::position` carries arguments the shim's trampoline cannot marshal, and a ratio
    /// captured a few seconds after the drag is indistinguishable from one captured during it.
    func captureRatios() {
        for (id, bits) in splitWidgets {
            guard let raw = UnsafeMutableRawPointer(bitPattern: bits) else { continue }
            let paned: UnsafeMutablePointer<GtkWidget> = ptr(raw)
            let horizontal =
                gtk_orientable_get_orientation(op(paned)) == GTK_ORIENTATION_HORIZONTAL
            let extent = horizontal ? gtk_widget_get_width(paned) : gtk_widget_get_height(paned)
            guard extent > 150 else { continue }
            let position = gtk_paned_get_position(op(paned))
            layout.setRatio(Double(position) / Double(extent), of: id)
        }
    }

    /// Where each divider sits in `reference`'s coordinates, so the driver can aim a real pointer
    /// at a handle instead of guessing where the gap fell.
    func handleCenters(in reference: UnsafeMutablePointer<GtkWidget>) -> [(SplitID, Double, Double)]
    {
        var centers: [(SplitID, Double, Double)] = []
        for (id, bits) in splitWidgets {
            guard let raw = UnsafeMutableRawPointer(bitPattern: bits) else { continue }
            let paned: UnsafeMutablePointer<GtkWidget> = ptr(raw)
            var x: Double = 0
            var y: Double = 0
            guard tailscode_paned_handle_center(paned, &x, &y) != 0 else { continue }
            var local = graphene_point_t(x: Float(x), y: Float(y))
            var mapped = graphene_point_t()
            guard gtk_widget_compute_point(paned, reference, &local, &mapped) != 0 else { continue }
            centers.append((id, Double(mapped.x), Double(mapped.y)))
        }
        return centers
    }

    /// The zoom is visibility, not structure: every other pane hides, each paned collapses onto
    /// the subtree that is still visible, and unzooming shows everything exactly where it was.
    private func applyZoomVisibility() {
        let zoomed = layout.zoomedPane
        for (id, pane) in panes {
            gtk_widget_set_visible(pane.root, zoomed == nil || zoomed == id ? 1 : 0)
        }
    }

    private func applyFocusStyling() {
        let showAccent = layout.paneCount > 1
        for (id, pane) in panes {
            if showAccent, id == layout.focusedPane {
                Gtk.addClass(pane.root, "pane-focused")
            } else {
                gtk_widget_remove_css_class(pane.root, "pane-focused")
            }
        }
    }

    private func applyIdentityStrips() {
        let several = layout.paneCount > 1
        for pane in panes.values {
            pane.setIdentityVisible(several)
        }
    }

    func snapshot() -> SplitSnapshot {
        var sessions: [String: SplitPaneSession] = [:]
        var videos: [String: String] = [:]
        var pages: [String: String] = [:]
        for (id, pane) in panes {
            if let target = pane.webTarget {
                pages[id.raw] = target.address
                continue
            }
            if let target = pane.videoTarget {
                videos[id.raw] = target.address
                continue
            }
            guard let entry = pane.entry else { continue }
            sessions[id.raw] = SplitPaneSession(
                profileID: entry.profileID, sessionID: entry.session.id)
        }
        return SplitSnapshot(layout: layout, sessions: sessions, videos: videos, pages: pages)
    }

    /// Rebuilds panes from a persisted arrangement and hands back what each pane was showing.
    /// The sessions themselves resolve later, when the listing arrives — restore never waits on
    /// the network to draw the window's shape.
    func restore(_ snapshot: SplitSnapshot) -> [PaneID: SplitPaneSession] {
        guard host != nil, snapshot.layout.isValid else { return [:] }
        for pane in panes.values { pane.shutdown() }
        panes = [:]
        layout = snapshot.layout
        var bindings: [PaneID: SplitPaneSession] = [:]
        for id in layout.paneIDs {
            let pane = makePane(id)
            if let target = snapshot.page(for: id) {
                pane.showWeb(target)
            } else if let target = snapshot.video(for: id) {
                pane.showVideo(target)
            } else if let session = snapshot.session(for: id) {
                bindings[id] = session
                pane.showPlaceholder(Localized.text("Connecting…"))
            } else {
                pane.showPlaceholder(Localized.text("Pick a chat, or n for a new one."))
            }
            panes[id] = pane
        }
        rebuild()
        return bindings
    }

    /// A lone pane needs no layout written — except when it is a slot, which is the one thing a
    /// single pane can hold that the chat list cannot restore on its own.
    func persist() {
        let snapshot = snapshot()
        guard let encoded = snapshot.encoded else { return }
        let worthKeeping = paneCount > 1 || !snapshot.videos.isEmpty || !snapshot.pages.isEmpty
        SettingsFile.set(worthKeeping ? encoded : nil, forKey: SplitSnapshot.defaultsKey)
    }
}
