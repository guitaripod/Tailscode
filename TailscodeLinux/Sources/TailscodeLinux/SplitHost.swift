import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The tiling tree made visible: `SplitLayout` decides the arrangement, this turns it into
/// nested `GtkPaned` widgets and keeps the two in agreement — divider drags flow back into the
/// model as ratios, structural verbs rebuild the widget skeleton around the surviving panes,
/// and the zoom is nothing but visibility, so unzooming costs no rebuild at all.
final class SplitHost: @unchecked Sendable {
    let container = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
    private(set) var layout: SplitLayout
    private(set) var panes: [PaneID: ChatPane] = [:]
    private var splitWidgets: [SplitID: UInt] = [:]
    private weak var host: MainWindow?

    init(host: MainWindow) {
        self.host = host
        layout = SplitLayout()
        gtk_widget_set_hexpand(container, 1)
        gtk_widget_set_vexpand(container, 1)
        let pane = ChatPane(id: layout.focusedPane, host: host)
        panes[pane.id] = pane
        rebuild()
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

    /// Splits the focused pane; the new pane opens empty and focused, ready for the chat list —
    /// or a subsequent open — to fill it.
    func splitActive(axis: SplitAxis) {
        guard let host else { return }
        guard let freshID = layout.split(layout.focusedPane, axis: axis) else { return }
        let pane = ChatPane(id: freshID, host: host)
        pane.showPlaceholder(Localized.text("Pick a chat, or n for a new one."))
        panes[freshID] = pane
        rebuild()
        host.focusedPaneChanged()
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

    func equalize() {
        layout.equalize()
        applyRatios()
        persist()
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
        }
        Gtk.removeChildren(of: container)
        splitWidgets = [:]
        let treeRoot = build(layout.root)
        gtk_box_append(ptr(container), treeRoot)
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
            if gtk_widget_get_parent(pane.root) != nil {
                gtk_widget_unparent(pane.root)
            }
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
            splitWidgets[id] = UInt(bitPattern: paned)
            return paned
        }
    }

    /// Positions from ratios. A paned that has not been allocated yet reports no extent, which
    /// is why this runs on the next idle and once more shortly after a rebuild.
    func applyRatios() {
        for (id, bits) in splitWidgets {
            guard let raw = UnsafeMutableRawPointer(bitPattern: bits),
                let ratio = layout.ratio(of: id)
            else { continue }
            let paned: UnsafeMutablePointer<GtkWidget> = ptr(raw)
            let horizontal =
                gtk_orientable_get_orientation(op(paned)) == GTK_ORIENTATION_HORIZONTAL
            let extent = horizontal ? gtk_widget_get_width(paned) : gtk_widget_get_height(paned)
            guard extent > 50 else { continue }
            gtk_paned_set_position(op(paned), Int32((Double(extent) * ratio).rounded()))
        }
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
        for (id, pane) in panes {
            guard let entry = pane.entry else { continue }
            sessions[id.raw] = SplitPaneSession(
                profileID: entry.profileID, sessionID: entry.session.id)
        }
        return SplitSnapshot(layout: layout, sessions: sessions)
    }

    /// Rebuilds panes from a persisted arrangement and hands back what each pane was showing.
    /// The sessions themselves resolve later, when the listing arrives — restore never waits on
    /// the network to draw the window's shape.
    func restore(_ snapshot: SplitSnapshot) -> [PaneID: SplitPaneSession] {
        guard let host, snapshot.layout.isValid else { return [:] }
        for pane in panes.values { pane.shutdown() }
        panes = [:]
        layout = snapshot.layout
        var bindings: [PaneID: SplitPaneSession] = [:]
        for id in layout.paneIDs {
            let pane = ChatPane(id: id, host: host)
            if let session = snapshot.session(for: id) {
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

    func persist() {
        guard let encoded = snapshot().encoded else { return }
        SettingsFile.set(paneCount > 1 ? encoded : nil, forKey: SplitSnapshot.defaultsKey)
    }
}
