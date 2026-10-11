import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// One divider of the canvas: a nine-point band over the seam between two panes, an accessible
/// separator that carries its position as a value, answers the arrow keys, Home and End, and
/// drags through Core's clamp.
///
/// The widget reports the pointer in the canvas's coordinates, so a divider that moves under a live
/// drag never feeds its own movement back into the next step. Everything it does is a call back
/// into the host; it keeps no state of the tree.
final class TileDivider: @unchecked Sendable {
    let id: SplitID
    let axis: SplitAxis
    let widget: UnsafeMutablePointer<GtkWidget>

    struct Handlers {
        var began: (Double, Double) -> Void
        var moved: (Double, Double) -> Void
        var ended: (Double?, Double?) -> Void
        var equalize: () -> Void
        var key: (DividerKey) -> Bool
    }

    private struct Described: Equatable {
        let position: Double
        let lowest: Double
        let highest: Double
        let label: String
    }

    private var described: Described?

    private final class HandlerBox: @unchecked Sendable {
        let handlers: Handlers

        init(_ handlers: Handlers) {
            self.handlers = handlers
        }
    }

    init(id: SplitID, axis: SplitAxis, handlers: Handlers) {
        _ = Gtk.releaseInstalled
        self.id = id
        self.axis = axis
        let box = Unmanaged.passRetained(HandlerBox(handlers)).toOpaque()
        let began: @convention(c) (Double, Double, UnsafeMutableRawPointer?) -> Void = {
            x, y, raw in
            guard let raw else { return }
            Unmanaged<HandlerBox>.fromOpaque(raw).takeUnretainedValue().handlers.began(x, y)
        }
        let moved: @convention(c) (Double, Double, UnsafeMutableRawPointer?) -> Void = {
            x, y, raw in
            guard let raw else { return }
            Unmanaged<HandlerBox>.fromOpaque(raw).takeUnretainedValue().handlers.moved(x, y)
        }
        let ended: @convention(c) (Double, Double, UnsafeMutableRawPointer?) -> Void = {
            x, y, raw in
            guard let raw else { return }
            Unmanaged<HandlerBox>.fromOpaque(raw).takeUnretainedValue().handlers
                .ended(x.isNaN ? nil : x, y.isNaN ? nil : y)
        }
        let equalize: @convention(c) (UnsafeMutableRawPointer?) -> Void = { raw in
            guard let raw else { return }
            Unmanaged<HandlerBox>.fromOpaque(raw).takeUnretainedValue().handlers.equalize()
        }
        let key: @convention(c) (Int32, Int32, UnsafeMutableRawPointer?) -> gboolean = {
            key, large, raw in
            guard let raw, let divider = Gtk.dividerKey(key, large: large != 0) else { return 0 }
            return Unmanaged<HandlerBox>.fromOpaque(raw).takeUnretainedValue().handlers
                .key(divider) ? 1 : 0
        }
        let table = TailscodeTileDividerHandlers(
            began: began, moved: moved, ended: ended, equalize: equalize, key: key)
        widget = tailscode_tile_divider_new(axis == .horizontal ? 1 : 0, table, box)
        g_object_ref_sink(UnsafeMutableRawPointer(widget))
        Gtk.addClass(widget, "tile-divider")
    }

    deinit {
        g_object_unref(UnsafeMutableRawPointer(widget))
    }

    /// The divider introduces itself: which two panes it divides, and where it stands between its
    /// extremes, in the words both desktops use.
    func describe(_ divider: DividerPlacement, label: String) {
        let stamp = Described(
            position: divider.position, lowest: divider.lowest, highest: divider.highest,
            label: label)
        guard stamp != described else { return }
        described = stamp
        tailscode_tile_divider_describe(
            widget, label, divider.lowest, divider.highest, divider.position,
            DividerReading.value(divider))
    }

    /// What the toolkit's accessibility layer holds for this divider, against what was meant.
    func reading(_ divider: DividerPlacement, label: String) -> String {
        guard
            let raw = tailscode_tile_divider_reading(
                widget, label, divider.lowest, divider.highest, divider.position)
        else { return "-" }
        defer { g_free(raw) }
        return String(cString: raw)
    }

    @discardableResult
    func focus() -> Bool {
        tailscode_tile_divider_focus(widget) != 0
    }

    var hasFocus: Bool {
        guard let root = gtk_widget_get_root(widget) else { return false }
        return gtk_root_get_focus(root) == widget
    }
}
