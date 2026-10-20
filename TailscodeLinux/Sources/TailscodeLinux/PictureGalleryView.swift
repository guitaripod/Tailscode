import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// The pictures an agent made, as one grid of small tiles rather than a poster and a caption each:
/// a turn that looked at sixteen screenshots spends one picture's height on them, spread across
/// whatever width the transcript has, and the last tile's corner counts the ones the grid could
/// not draw. Every tile is its own press — it opens the conversation's gallery on that picture,
/// where every picture can be paged through, zoomed and saved — and a tile under the pointer steps
/// its picture back to say so.
///
/// The grid is `PictureGalleryLayout`'s arithmetic asked again whenever the row's width changes, so
/// a pane widened gives the pictures more room rather than more air, and one narrowed folds them
/// into a second row instead of thinning them to needles.
enum PictureGalleryView {
    /// The words a picture is known by: its filename, never its path.
    static func filename(of reference: FileReference) -> String {
        reference.filename ?? reference.path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "file"
    }

    static func spoken(_ pictures: [TranscriptRow.GalleryPicture]) -> String {
        PictureGalleryReading.spoken(
            count: pictures.count, names: pictures.map { filename(of: $0.reference) })
    }

    static func make(
        _ pictures: [TranscriptRow.GalleryPicture], context: TranscriptContext
    ) -> UnsafeMutablePointer<GtkWidget> {
        let outer = gtk_overlay_new()!
        Gtk.addClass(outer, "picture-gallery")
        gtk_widget_set_hexpand(outer, 1)
        gtk_widget_set_vexpand(outer, 0)

        let fixed = gtk_fixed_new()!
        gtk_widget_set_halign(fixed, GTK_ALIGN_START)
        gtk_widget_set_valign(fixed, GTK_ALIGN_START)
        gtk_overlay_set_child(op(outer), fixed)

        let watch = Gtk.widthWatch()
        gtk_overlay_add_overlay(op(outer), watch)

        let board = Board(pictures: pictures, context: context, fixed: fixed)
        Gtk.onAreaResize(watch) { [board] width, _ in board.reflow(width) }
        board.reflow(Int32(ImagePreview.deskWidth))
        return outer
    }

    /// One gallery, kept alive with its row: the pictures it draws, the tiles it has placed, and
    /// the arrangement it placed them in, so a resize that changes nothing costs nothing.
    private final class Board: @unchecked Sendable {
        private let pictures: [TranscriptRow.GalleryPicture]
        private let context: TranscriptContext
        private let fixed: UnsafeMutablePointer<GtkWidget>
        private var placed: [UnsafeMutablePointer<GtkWidget>] = []
        private var arrangement: PictureGalleryLayout.Arrangement = .empty

        init(
            pictures: [TranscriptRow.GalleryPicture], context: TranscriptContext,
            fixed: UnsafeMutablePointer<GtkWidget>
        ) {
            self.pictures = pictures
            self.context = context
            self.fixed = fixed
        }

        func reflow(_ available: Int32) {
            let room = Double(available)
            guard room > 1 else { return }
            let metrics = TranscriptGaps.metrics
            let side = PictureGalleryLayout.side(metrics: metrics, width: room)
            let next = PictureGalleryLayout.grid(
                count: pictures.count, side: side, gap: metrics.imageStripGap, available: room,
                shape: pictures.count == 1 ? shape(of: pictures[0]) : nil,
                maxWidth: ImagePreview.deskWidth)
            guard next != arrangement || placed.isEmpty else { return }
            arrangement = next
            place(next)
        }

        /// The tiles of one arrangement on the row, left to right: each the picture's crop at the
        /// rectangle the layout gave it, and the last one counting what is not drawn.
        private func place(_ arrangement: PictureGalleryLayout.Arrangement) {
            for widget in placed { gtk_widget_unparent(widget) }
            placed = []
            gtk_widget_set_size_request(
                fixed, Int32(arrangement.width.rounded()), Int32(arrangement.height.rounded()))
            for tile in arrangement.tiles where pictures.indices.contains(tile.index) {
                let button = tileButton(
                    pictures[tile.index], tile: tile,
                    more: tile.index == arrangement.tiles.count - 1 ? arrangement.hidden : 0,
                    fitted: pictures.count == 1, of: pictures.count)
                gtk_fixed_put(
                    ptr(UnsafeMutableRawPointer(fixed)), button, tile.x.rounded(),
                    tile.y.rounded())
                placed.append(button)
            }
        }

        /// One tile: the picture cropped to its rectangle, a press that opens that picture, and the
        /// count of what is not drawn said over the last one.
        private func tileButton(
            _ picture: TranscriptRow.GalleryPicture, tile: PictureGalleryLayout.Tile, more: Int,
            fitted: Bool, of count: Int
        ) -> UnsafeMutablePointer<GtkWidget> {
            let content = cell(picture, tile: tile, fitted: fitted, more: more)
            let opener = gtk_button_new()!
            Gtk.addClass(opener, "flat")
            Gtk.addClass(opener, "picture-gallery-tile")
            gtk_widget_set_size_request(
                opener, Int32(tile.width.rounded()), Int32(tile.height.rounded()))
            gtk_button_set_child(ptr(opener), content)

            let name = PictureGalleryView.filename(of: picture.reference)
            let said = Localized.text("Open %1$@, picture %2$@ of %3$@", name, "\(tile.index + 1)", "\(count)")
            gtk_widget_set_tooltip_text(opener, name)
            tailscode_set_accessible_label(opener, said)

            let open = context.openImage
            let key = picture.key
            Gtk.connect(UnsafeMutableRawPointer(opener), "clicked") { open?(key, name) }
            return opener
        }

        private func cell(
            _ picture: TranscriptRow.GalleryPicture, tile: PictureGalleryLayout.Tile, fitted: Bool,
            more: Int
        ) -> UnsafeMutablePointer<GtkWidget> {
            let bits = context.texture(forKey: picture.key)
            let width = Int32(tile.width.rounded())
            let height = Int32(tile.height.rounded())
            let frame: UnsafeMutablePointer<GtkWidget>
            if bits != 0,
                let texture = UnsafeMutableRawPointer(bitPattern: bits).map({ OpaquePointer($0) }),
                let drawn = tailscode_picture_for_texture_sized(texture, width, height)
            {
                gtk_picture_set_content_fit(
                    op(drawn), fitted ? GTK_CONTENT_FIT_CONTAIN : GTK_CONTENT_FIT_COVER)
                gtk_widget_set_size_request(drawn, width, height)
                frame = drawn
            } else {
                let waiting = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
                Gtk.addClass(waiting, "picture-gallery-waiting")
                gtk_widget_set_size_request(waiting, width, height)
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
            gtk_widget_set_size_request(stacked, width, height)
            gtk_overlay_set_child(op(stacked), frame)
            gtk_overlay_add_overlay(op(stacked), scrim)
            return stacked
        }

        /// Width over height of a picture whose pixels have landed; nil while it is on its way.
        private func shape(of picture: TranscriptRow.GalleryPicture) -> Double? {
            guard let size = context.dimensions(forKey: picture.key), size.1 > 0 else { return nil }
            return Double(size.0) / Double(size.1)
        }
    }
}
