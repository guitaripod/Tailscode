import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// The pictures an agent made, as one square of small tiles rather than a poster and a caption
/// each: a turn that looked at sixteen screenshots spends one picture's height on them, and the
/// corner counts the ones the square could not draw. The whole square is one press — it opens the
/// conversation's gallery on this group's first picture, where every picture can be paged through,
/// zoomed and saved — and the plate under the pointer says it is pressable.
enum PictureGalleryView {
    /// The words a picture is known by: its filename, never its path.
    static func filename(of reference: FileReference) -> String {
        reference.filename ?? reference.path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "file"
    }

    static func spoken(_ pictures: [TranscriptRow.GalleryPicture]) -> String {
        PictureGalleryReading.spoken(
            count: pictures.count, names: pictures.map { filename(of: $0.reference) })
    }

    /// What the square measures: a two-by-two is the square, and a lone picture keeping its own
    /// shape is that shape's width.
    private static func size(of tiles: [PictureGalleryLayout.Tile]) -> (width: Int32, height: Int32) {
        let width = tiles.map { $0.x + $0.width }.max() ?? 0
        let height = tiles.map { $0.y + $0.height }.max() ?? 0
        return (Int32(width.rounded()), Int32(height.rounded()))
    }

    /// Width over height of a picture whose pixels have landed; nil while it is on its way.
    private static func shape(
        of picture: TranscriptRow.GalleryPicture, context: TranscriptContext
    ) -> Double? {
        guard let size = context.dimensions(forKey: picture.key), size.1 > 0 else { return nil }
        return Double(size.0) / Double(size.1)
    }

    static func make(
        _ pictures: [TranscriptRow.GalleryPicture], context: TranscriptContext
    ) -> UnsafeMutablePointer<GtkWidget> {
        let metrics = TranscriptGaps.metrics
        let side = PictureGalleryLayout.side(metrics: metrics, width: ImagePreview.deskWidth)
        let gap = metrics.imageStripGap
        let shown = Array(pictures.prefix(PictureGalleryLayout.maximumTiles))
        let tiles = PictureGalleryLayout.mosaic(
            count: shown.count, side: side, gap: gap,
            shape: shown.count == 1 ? shape(of: shown[0], context: context) : nil,
            maxWidth: ImagePreview.deskWidth)
        let hidden = PictureGalleryLayout.hidden(count: pictures.count)

        let extent = size(of: tiles)
        let fixed = gtk_fixed_new()!
        gtk_widget_set_size_request(fixed, extent.width, extent.height)
        for tile in tiles {
            let widget = cell(
                pictures[tile.index], metrics: metrics, tile: tile, context: context,
                fitted: tiles.count == 1, more: tile.index == tiles.count - 1 ? hidden : 0)
            gtk_fixed_put(
                ptr(UnsafeMutableRawPointer(fixed)), widget, tile.x.rounded(), tile.y.rounded())
            gtk_widget_set_size_request(
                widget, Int32(tile.width.rounded()), Int32(tile.height.rounded()))
        }


        let opener = gtk_button_new()!
        Gtk.addClass(opener, "flat")
        Gtk.addClass(opener, "picture-gallery")
        gtk_widget_set_size_request(opener, extent.width, extent.height)
        gtk_widget_set_halign(opener, GTK_ALIGN_START)
        gtk_widget_set_valign(opener, GTK_ALIGN_START)
        gtk_widget_set_hexpand(opener, 0)
        gtk_widget_set_vexpand(opener, 0)
        gtk_button_set_child(ptr(opener), fixed)

        let said = spoken(pictures)
        gtk_widget_set_tooltip_text(opener, said)
        tailscode_set_accessible_label(opener, said)

        let squares = TileBox(widgets: gtkWidgetChildren(of: fixed))
        Gtk.onPointer(
            opener,
            move: { _, _ in squares.dim(true) },
            leave: { squares.dim(false) })

        let open = context.openImage
        let first = pictures[0]
        let name = filename(of: first.reference)
        let key = first.key
        Gtk.connect(UnsafeMutableRawPointer(opener), "clicked") { open?(key, name) }
        return opener
    }

    /// One tile: the picture cropped to the square it was given, and the count of what is not
    /// drawn said over the last one.
    private static func cell(
        _ picture: TranscriptRow.GalleryPicture, metrics: ChatMetrics,
        tile: PictureGalleryLayout.Tile, context: TranscriptContext, fitted: Bool, more: Int
    ) -> UnsafeMutablePointer<GtkWidget> {
        let bits = context.texture(forKey: picture.key)
        let frame: UnsafeMutablePointer<GtkWidget>
        if bits != 0,
            let texture = UnsafeMutableRawPointer(bitPattern: bits).map({ OpaquePointer($0) }),
            let drawn = tailscode_picture_for_texture_sized(
                texture, Int32(tile.width.rounded()), Int32(tile.height.rounded()))
        {
            gtk_picture_set_content_fit(
                op(drawn), fitted ? GTK_CONTENT_FIT_CONTAIN : GTK_CONTENT_FIT_COVER)
            gtk_widget_set_size_request(
                drawn, Int32(tile.width.rounded()), Int32(tile.height.rounded()))
            Gtk.addClass(drawn, "picture-gallery-tile")
            frame = drawn
        } else {
            let waiting = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
            Gtk.addClass(waiting, "picture-gallery-tile")
            Gtk.addClass(waiting, "picture-gallery-waiting")
            gtk_box_append(ptr(waiting), Gtk.label("🖼", css: "dim", selectable: false))
            context.requestImage?(picture.reference, picture.key)
            frame = waiting
        }
        guard more > 0 else { return frame }
        let scrim = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        Gtk.addClass(scrim, "picture-gallery-scrim")
        gtk_widget_set_hexpand(scrim, 1)
        gtk_widget_set_vexpand(scrim, 1)
        let count = Gtk.label("+\(more)", css: "picture-gallery-more", selectable: false)
        gtk_widget_set_halign(count, GTK_ALIGN_CENTER)
        gtk_widget_set_valign(count, GTK_ALIGN_CENTER)
        gtk_widget_set_vexpand(count, 1)
        gtk_box_append(ptr(scrim), count)
        let stacked = gtk_overlay_new()!
        gtk_overlay_set_child(op(stacked), frame)
        gtk_overlay_add_overlay(op(stacked), scrim)
        return stacked
    }

    /// Every tile of the square, held where a `@Sendable` pointer closure can dim them: the square
    /// answers the pointer as one control — the tiles step back a little under it — rather than
    /// painting a plate the width of the row behind a picture that is not that wide.
    private final class TileBox: @unchecked Sendable {
        private let widgets: [UnsafeMutablePointer<GtkWidget>]
        private var lit = true

        init(widgets: [UnsafeMutablePointer<GtkWidget>]) { self.widgets = widgets }

        func dim(_ dimmed: Bool) {
            guard dimmed != !lit else { return }
            lit = !dimmed
            for widget in widgets { gtk_widget_set_opacity(widget, dimmed ? 0.84 : 1) }
        }
    }

    /// The fixed's own children, in the order they were put: every tile of the square.
    private static func gtkWidgetChildren(of fixed: UnsafeMutablePointer<GtkWidget>)
        -> [UnsafeMutablePointer<GtkWidget>]
    {
        var found: [UnsafeMutablePointer<GtkWidget>] = []
        var child = gtk_widget_get_first_child(fixed)
        while let one = child {
            found.append(one)
            child = gtk_widget_get_next_sibling(one)
        }
        return found
    }
}
