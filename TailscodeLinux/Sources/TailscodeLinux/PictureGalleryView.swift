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

        let fixed = gtk_fixed_new()!
        gtk_widget_set_size_request(fixed, Int32(side.rounded()), Int32(side.rounded()))
        for tile in tiles {
            let widget = cell(
                pictures[tile.index], metrics: metrics, tile: tile, context: context,
                fitted: tiles.count == 1, more: tile.index == tiles.count - 1 ? hidden : 0)
            gtk_fixed_put(
                ptr(UnsafeMutableRawPointer(fixed)), widget, tile.x.rounded(), tile.y.rounded())
            gtk_widget_set_size_request(
                widget, Int32(tile.width.rounded()), Int32(tile.height.rounded()))
        }

        let plate = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
        Gtk.addClass(plate, "picture-gallery-plate")
        gtk_widget_set_hexpand(plate, 1)
        gtk_widget_set_vexpand(plate, 1)
        gtk_widget_set_opacity(plate, 0)

        let stage = gtk_overlay_new()!
        gtk_overlay_set_child(op(stage), fixed)
        gtk_overlay_add_overlay(op(stage), plate)

        let opener = gtk_button_new()!
        Gtk.addClass(opener, "flat")
        Gtk.addClass(opener, "picture-gallery")
        gtk_widget_set_size_request(opener, Int32(side.rounded()), Int32(side.rounded()))
        gtk_widget_set_halign(opener, GTK_ALIGN_START)
        gtk_widget_set_valign(opener, GTK_ALIGN_START)
        gtk_button_set_child(ptr(opener), stage)

        let said = spoken(pictures)
        gtk_widget_set_tooltip_text(opener, said)
        tailscode_set_accessible_label(opener, said)

        let box = PlateBox(widget: plate)
        Gtk.onPointer(
            opener,
            move: { _, _ in gtk_widget_set_opacity(box.widget, 1) },
            leave: { gtk_widget_set_opacity(box.widget, 0) })

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
            let drawn = Gtk.studioPicture(
                bits: bits, fit: fitted ? GTK_CONTENT_FIT_CONTAIN : GTK_CONTENT_FIT_COVER)
        {
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

    private final class PlateBox: @unchecked Sendable {
        let widget: UnsafeMutablePointer<GtkWidget>
        init(widget: UnsafeMutablePointer<GtkWidget>) { self.widget = widget }
    }
}
