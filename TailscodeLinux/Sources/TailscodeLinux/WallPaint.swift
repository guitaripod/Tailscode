import CAdw
import CGtkShim
import Foundation
import TailscodeCore

/// A widget whose drawing is built for the GPU: pictures painted once and drawn as textures, and
/// shapes the renderer draws itself, placed with opacity and turns. Asked to draw again it builds
/// a handful of nodes and rasterises nothing, so a layer can move on every frame of a fast display
/// for the cost of the nodes.
final class WallLayer: @unchecked Sendable {
    let widget: UnsafeMutablePointer<GtkWidget>
    var draw: ((WallSnapshot, Double, Double) -> Void)?
    /// Set when the widget is finalized: a maker that still holds the layer may ask it to draw
    /// again, and a finalized widget must never be asked for anything.
    private(set) var isGone = false

    /// The widget owns the layer, as a drawing area owned its closure: whoever made the layer may
    /// let go of it once the widget has a parent, and the layer lives exactly as long as the widget
    /// it draws. When the widget is finalized the drawing is dropped first, so a closure that holds
    /// its maker strongly cannot keep the pair alive.
    init() {
        _ = Gtk.releaseInstalled
        widget = tailscode_paint_new(nil, nil, nil)
        let held = Unmanaged.passRetained(self).toOpaque()
        tailscode_paint_set_draw(
            widget,
            { snapshot, width, height, raw in
                guard let snapshot, let raw else { return }
                let layer = Unmanaged<WallLayer>.fromOpaque(raw).takeUnretainedValue()
                guard let draw = layer.draw else { return }
                draw(WallSnapshot(raw: snapshot, widget: layer.widget), width, height)
            }, held,
            { raw in
                guard let raw else { return }
                let layer = Unmanaged<WallLayer>.fromOpaque(raw)
                layer.takeUnretainedValue().isGone = true
                layer.takeUnretainedValue().draw = nil
                layer.release()
            })
    }

    func redraw() {
        guard !isGone else { return }
        gtk_widget_queue_draw(widget)
    }

    /// Every snapshot any layer has taken, for a bench.
    static var snapshotsEverywhere: Int { Int(tailscode_paint_snapshots()) }
}

/// One draw of a layer: what a frame is made of.
struct WallSnapshot {
    let raw: OpaquePointer
    let widget: UnsafeMutablePointer<GtkWidget>?

    var scale: Double { widget.map { tailscode_widget_device_scale($0) } ?? 1 }
    var gpu: Bool { widget.map { tailscode_widget_draws_with_gpu($0) != 0 } ?? false }

    /// Draws what `body` builds into a cairo context, the way the cairo renderer would, for a check
    /// that compares pixels.
    static func render(_ cr: OpaquePointer, _ body: (WallSnapshot) -> Void) {
        guard let snapshot = gtk_snapshot_new() else { return }
        body(WallSnapshot(raw: snapshot, widget: nil))
        guard let node = gtk_snapshot_free_to_node(snapshot) else { return }
        gsk_render_node_draw(node, cr)
        gsk_render_node_unref(node)
    }

    func picture(_ picture: WallPicture, _ rect: WatchRect, opacity: Double = 1, smooth: Bool = false) {
        guard opacity > 0.002, rect.width > 0, rect.height > 0 else { return }
        if opacity < 0.998 { gtk_snapshot_push_opacity(raw, min(1, opacity)) }
        picture.append(raw, rect, smooth: smooth)
        if opacity < 0.998 { gtk_snapshot_pop(raw) }
    }

    func disc(x: Double, y: Double, radius: Double, ink: PartyInk, alpha: Double) {
        tailscode_snap_disc(raw, x, y, radius, ink.red, ink.green, ink.blue, alpha)
    }

    func ring(x: Double, y: Double, radius: Double, line: Double, ink: PartyInk, alpha: Double) {
        tailscode_snap_ring(raw, x, y, radius, line, ink.red, ink.green, ink.blue, alpha)
    }

    func fill(_ rect: WatchRect, radius: Double, ink: PartyInk, alpha: Double) {
        tailscode_snap_rounded_fill(
            raw, rect.x, rect.y, rect.width, rect.height, radius, ink.red, ink.green, ink.blue, alpha)
    }

    func stroke(_ rect: WatchRect, radius: Double, line: Double, ink: PartyInk, alpha: Double) {
        tailscode_snap_rounded_stroke(
            raw, rect.x, rect.y, rect.width, rect.height, radius, line, ink.red, ink.green, ink.blue, alpha)
    }

    func band(_ rect: WatchRect, radius: Double, from inner: Double, to outer: Double, ink: PartyInk, alpha: Double) {
        tailscode_snap_rounded_band(
            raw, rect.x, rect.y, rect.width, rect.height, radius, inner, outer, ink.red, ink.green,
            ink.blue, alpha)
    }

    func radial(x: Double, y: Double, from inner: Double, to outer: Double, stops: [WallStop]) {
        let flat = WallStop.flatten(stops)
        flat.withUnsafeBufferPointer { tailscode_snap_radial(raw, x, y, inner, outer, $0.baseAddress, Int32(stops.count)) }
    }

    func linear(_ rect: WatchRect, from: (Double, Double), to: (Double, Double), stops: [WallStop]) {
        let flat = WallStop.flatten(stops)
        flat.withUnsafeBufferPointer {
            tailscode_snap_linear(
                raw, rect.x, rect.y, rect.width, rect.height, from.0, from.1, to.0, to.1, $0.baseAddress,
                Int32(stops.count))
        }
    }

    func segments(_ points: [Double], line: Double, ink: PartyInk, alpha: Double) {
        guard points.count >= 4 else { return }
        points.withUnsafeBufferPointer {
            tailscode_snap_segments(raw, $0.baseAddress, Int32(points.count / 4), line, ink.red, ink.green, ink.blue, alpha)
        }
    }

    /// Soft points: `motes` is runs of x, y, radius, alpha.
    func motes(_ motes: [Double], halo: Double, haloShare: Double, ink: PartyInk) {
        guard motes.count >= 4 else { return }
        motes.withUnsafeBufferPointer {
            tailscode_snap_motes(raw, $0.baseAddress, Int32(motes.count / 4), halo, haloShare, ink.red, ink.green, ink.blue)
        }
    }

    func roundedClip(_ rect: WatchRect, radius: Double, _ body: () -> Void) {
        tailscode_snap_push_rounded_clip(raw, rect.x, rect.y, rect.width, rect.height, radius)
        body()
        gtk_snapshot_pop(raw)
    }

    /// A band `band` wide just inside the rounded rectangle's edge, coloured by `stops` (RGB runs,
    /// evenly spaced) swept about its centre and turned `degrees` clockwise from the top.
    func sweepBand(_ rect: WatchRect, radius: Double, band: Double, degrees: Double, alpha: Double, stops: [Double]) {
        stops.withUnsafeBufferPointer {
            tailscode_snap_sweep_band(
                raw, rect.x, rect.y, rect.width, rect.height, radius, band, degrees, alpha, $0.baseAddress,
                Int32(stops.count / 3))
        }
    }

    /// Draws `body` turned `degrees` clockwise and scaled by `scale` about (`x`, `y`), then moved.
    func turned(
        about x: Double, _ y: Double, degrees: Double = 0, scale: Double = 1, by dx: Double = 0,
        _ dy: Double = 0, _ body: () -> Void
    ) {
        guard degrees != 0 || scale != 1 || dx != 0 || dy != 0 else {
            body()
            return
        }
        tailscode_snap_push_turn(raw, x, y, degrees, scale, dx, dy)
        body()
        gtk_snapshot_restore(raw)
    }

    func clipped(_ rect: WatchRect, _ body: () -> Void) {
        tailscode_snap_push_clip(raw, rect.x, rect.y, rect.width, rect.height)
        body()
        gtk_snapshot_pop(raw)
    }
}

/// One stop of a gradient the GPU draws.
struct WallStop {
    var offset: Double
    var ink: PartyInk
    var alpha: Double

    static func flatten(_ stops: [WallStop]) -> [Double] {
        stops.flatMap { [$0.offset, $0.ink.red, $0.ink.green, $0.ink.blue, $0.alpha] }
    }
}

/// A picture painted once with cairo and drawn as often as asked. It is painted again only when
/// what it shows changes, which its key says: anything a caller folds into the key — a colour, a
/// state, a size — repaints it when it differs, and nothing else does. Its pixels are a texture
/// under a GPU renderer, uploaded once, and a surface the cairo renderer copies otherwise.
final class WallPicture: @unchecked Sendable {
    private(set) var pixels: OpaquePointer?
    private var key: String?
    private var paintedSize = (width: 0.0, height: 0.0, scale: 0.0)
    private var paintedForGPU = false
    private(set) var paints = 0

    /// Every picture painted anywhere and the logical pixels it covered, for a bench.
    nonisolated(unsafe) static var paintsEverywhere = 0
    nonisolated(unsafe) static var pixelsEverywhere = 0.0

    init() {
        pixels = tailscode_picture_new()
    }

    deinit {
        tailscode_picture_free(pixels)
    }

    var hasPixels: Bool { tailscode_picture_has_pixels(pixels) != 0 }

    /// Makes sure the picture shows `key` at `width` by `height` for the snapshot's screen, painting
    /// it with `paint` only when one of them changed. `detail` below one paints a soft picture at
    /// that share of the screen's pixels and lets the GPU stretch it.
    func ensure(
        _ key: String, width: Double, height: Double, in snapshot: WallSnapshot, detail: Double = 1,
        paint: (OpaquePointer, Double, Double) -> Void
    ) {
        let scale = snapshot.scale * detail
        let gpu = snapshot.gpu
        guard key != self.key || width != paintedSize.width || height != paintedSize.height
            || scale != paintedSize.scale || gpu != paintedForGPU || !hasPixels
        else { return }
        self.key = key
        paintedSize = (width, height, scale)
        paintedForGPU = gpu
        paints += 1
        Self.paintsEverywhere += 1
        Self.pixelsEverywhere += width * height
        withoutActuallyEscaping(paint) { paint in
            let box = PaintBox(paint)
            withExtendedLifetime(box) {
                tailscode_picture_paint(
                    pixels, width, height, scale, gpu ? 1 : 0,
                    { cr, width, height, raw in
                        guard let cr, let raw else { return }
                        Unmanaged<PaintBox>.fromOpaque(raw).takeUnretainedValue().paint(cr, width, height)
                    }, Unmanaged.passUnretained(box).toOpaque())
            }
        }
    }

    fileprivate func append(_ snapshot: OpaquePointer, _ rect: WatchRect, smooth: Bool) {
        tailscode_picture_append(pixels, snapshot, rect.x, rect.y, rect.width, rect.height, smooth ? 1 : 0)
    }

    private final class PaintBox {
        let paint: (OpaquePointer, Double, Double) -> Void
        init(_ paint: @escaping (OpaquePointer, Double, Double) -> Void) { self.paint = paint }
    }
}
