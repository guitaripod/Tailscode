import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// A rectangle for a child of the canvas, in whole logical points.
struct TileRect: Equatable {
    var x: Int32
    var y: Int32
    var width: Int32
    var height: Int32

    init(x: Int32, y: Int32, width: Int32, height: Int32) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(_ rect: SplitRect) {
        self.init(
            x: Int32(rect.x.rounded()), y: Int32(rect.y.rounded()),
            width: Int32(rect.width.rounded()), height: Int32(rect.height.rounded()))
    }
}

/// Where the canvas's children go, asked of the host inside every allocation of the canvas.
final class TileSink {
    fileprivate let raw: OpaquePointer

    fileprivate init(_ raw: OpaquePointer) {
        self.raw = raw
    }

    func place(_ child: UnsafeMutablePointer<GtkWidget>, _ rect: TileRect) {
        tailscode_tile_sink_place(raw, child, rect.x, rect.y, rect.width, rect.height)
    }
}

/// The flat container every pane shell, divider and overlay is a child of. It owns no policy:
/// the host's solver says where each child goes, and a child it does not place is hidden rather
/// than moved out. Children go in once and come out once; the reparent counter proves it.
final class TileCanvas: @unchecked Sendable {
    let widget: UnsafeMutablePointer<GtkWidget>

    enum Layer: Int32 {
        case panes = 0
        case dividers = 1
        case overlays = 2
    }

    private final class SolveBox: @unchecked Sendable {
        let solve: (Int32, Int32, TileSink) -> Void

        init(_ solve: @escaping (Int32, Int32, TileSink) -> Void) {
            self.solve = solve
        }
    }

    init(solve: @escaping (Int32, Int32, TileSink) -> Void) {
        _ = Gtk.releaseInstalled
        widget = tailscode_tile_canvas_new()
        g_object_ref_sink(UnsafeMutableRawPointer(widget))
        let box = Unmanaged.passRetained(SolveBox(solve)).toOpaque()
        let callback:
            @convention(c) (Int32, Int32, OpaquePointer?, UnsafeMutableRawPointer?) -> Void = {
                width, height, sink, raw in
                guard let raw, let sink else { return }
                Unmanaged<SolveBox>.fromOpaque(raw).takeUnretainedValue()
                    .solve(width, height, TileSink(sink))
            }
        tailscode_tile_canvas_set_solver(widget, callback, box)
    }

    deinit {
        g_object_unref(UnsafeMutableRawPointer(widget))
    }

    func add(_ child: UnsafeMutablePointer<GtkWidget>, layer: Layer) {
        tailscode_tile_canvas_add(widget, child, layer.rawValue)
    }

    func remove(_ child: UnsafeMutablePointer<GtkWidget>) {
        tailscode_tile_canvas_remove(widget, child)
    }

    func invalidate() {
        tailscode_tile_canvas_invalidate(widget)
    }

    var size: SplitSize {
        SplitSize(
            width: Double(gtk_widget_get_width(widget)),
            height: Double(gtk_widget_get_height(widget)))
    }

    var childCount: Int { Int(tailscode_tile_canvas_child_count(widget)) }
    var allocations: Int { Int(tailscode_tile_canvas_allocations(widget)) }

    /// How long the last allocation took, in milliseconds: the solver, and every child's measure
    /// and allocate under it, so a transcript's relayout is counted.
    var lastAllocateMilliseconds: Double {
        Double(tailscode_tile_canvas_allocate_us(widget)) / 1000
    }

    static var reparents: Int { Int(tailscode_tile_canvas_reparents()) }
}

extension Gtk {
    /// A double press on a widget that nothing inside it claimed.
    static func onDoubleClick(
        _ widget: UnsafeMutablePointer<GtkWidget>, _ handler: @escaping @Sendable () -> Void
    ) {
        _ = releaseInstalled
        let box = Unmanaged.passRetained(Box(handler)).toOpaque()
        let callback: @convention(c) (UnsafeMutableRawPointer?) -> Void = { raw in
            guard let raw else { return }
            Unmanaged<Box>.fromOpaque(raw).takeUnretainedValue().work()
        }
        tailscode_tile_on_double_click(widget, callback, box)
    }
}
