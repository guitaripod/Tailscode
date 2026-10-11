import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// The chrome one pane wears whatever it holds: a clamped container that is the pane's only child
/// of the canvas, a place for each face a chat can wear, and the focus ring.
///
/// The conversation itself is the full face, built once and kept for the life of the pane. A
/// glance and a paused face are made the first time they are asked for and kept; wearing a face is
/// showing one body and hiding the others, never moving one. The container has no minimum size,
/// so the canvas can hand it any rectangle the layout allows and the face inside simply stands in
/// it, clipped, until the density that suits the rectangle has been settled.
final class TileShell: @unchecked Sendable {
    enum Face {
        case full
        case glance
        case paused
    }

    let id: PaneID
    let widget: UnsafeMutablePointer<GtkWidget>
    let lifetime = PaneLifetime()
    private let body: UnsafeMutablePointer<GtkWidget>
    private(set) var glance: GlanceTile?
    private(set) var parked: ParkedFace?
    private(set) var face: Face = .full
    private var onResume: (@Sendable () -> Void)?

    init(id: PaneID, body: UnsafeMutablePointer<GtkWidget>) {
        self.id = id
        self.body = body
        widget = tailscode_tile_clamp_new()
        g_object_ref_sink(UnsafeMutableRawPointer(widget))
        Gtk.addClass(widget, "tile-shell")
        tailscode_tile_clamp_add(widget, body)
    }

    deinit {
        g_object_unref(UnsafeMutableRawPointer(widget))
    }

    func setResume(_ action: @escaping @Sendable () -> Void) {
        onResume = action
    }

    var hasGlance: Bool { glance != nil }

    /// The glance tile, made on first use.
    func ensureGlance() -> GlanceTile {
        if let glance { return glance }
        let tile = GlanceTile(paneID: id)
        tailscode_tile_clamp_add(widget, tile.widget)
        gtk_widget_set_visible(tile.widget, 0)
        glance = tile
        lifetime.add { [weak tile] in tile?.stopClock() }
        return tile
    }

    /// The paused face, made on first use.
    func ensureParked() -> ParkedFace {
        if let parked { return parked }
        let resume = onResume ?? {}
        let face = ParkedFace(paneID: id) { resume() }
        tailscode_tile_clamp_add(widget, face.widget)
        gtk_widget_set_visible(face.widget, 0)
        parked = face
        return face
    }

    /// Shows one body and hides the others.
    func show(_ next: Face) {
        face = next
        switch next {
        case .full:
            gtk_widget_set_visible(body, 1)
            if let glance { gtk_widget_set_visible(glance.widget, 0) }
            if let parked { gtk_widget_set_visible(parked.widget, 0) }
        case .glance:
            let tile = ensureGlance()
            gtk_widget_set_visible(body, 0)
            gtk_widget_set_visible(tile.widget, 1)
            if let parked { gtk_widget_set_visible(parked.widget, 0) }
        case .paused:
            let faceWidget = ensureParked()
            gtk_widget_set_visible(body, 0)
            gtk_widget_set_visible(faceWidget.widget, 1)
            if let glance { gtk_widget_set_visible(glance.widget, 0) }
        }
    }

    /// The accent hairline of the focused pane, on whichever face is showing; every face keeps a
    /// transparent border of the same width, so focus never moves a pixel of content.
    func setFocusRing(focused: Bool, shown: Bool) {
        let on = focused && shown
        for target in [body, glance?.widget, parked?.widget].compactMap({ $0 }) {
            if on { gtk_widget_add_css_class(target, "pane-focused") } else {
                gtk_widget_remove_css_class(target, "pane-focused")
            }
        }
    }

    func setAccessibleLabel(_ label: String) {
        tailscode_set_accessible_label(widget, label)
    }

    func shutdown() {
        lifetime.cancelAll()
        glance?.stopClock()
    }
}
