import CAdw
import CGtkShim
import CodingAgentKit
import Foundation
import TailscodeCore

/// The pictures an agent made, as one wrapping row of thumbnails instead of a poster and a caption
/// each. Every thumbnail is at most the metrics' picture height tall and as wide as its aspect
/// gives; the filename is the tooltip and the accessible label rather than a line under it, and a
/// click opens the gallery at that picture.
enum PictureStripView {
    /// What a picture's thumbnail measures: scaled to the strip's height, never past the desk's
    /// width and never enlarged.
    static func thumbnail(
        width: Double, height: Double, maxHeight: Double, maxWidth: Double
    ) -> (width: Int32, height: Int32) {
        let scale = min(maxHeight / max(1, height), maxWidth / max(1, width), 1)
        return (Int32(max(1, (width * scale).rounded())), Int32(max(1, (height * scale).rounded())))
    }

    /// The words an image is known by: its filename, never its path.
    static func filename(of reference: FileReference) -> String {
        reference.filename ?? reference.path.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "file"
    }

    static func make(
        _ pictures: [TranscriptRow.StripPicture], context: TranscriptContext
    ) -> UnsafeMutablePointer<GtkWidget> {
        let metrics = TranscriptGaps.metrics
        let strip = gtk_flow_box_new()!
        Gtk.addClass(strip, "picture-strip")
        gtk_flow_box_set_selection_mode(op(strip), GTK_SELECTION_NONE)
        gtk_flow_box_set_homogeneous(op(strip), 0)
        gtk_flow_box_set_max_children_per_line(op(strip), 64)
        gtk_flow_box_set_column_spacing(op(strip), guint(metrics.imageStripGap))
        gtk_flow_box_set_row_spacing(op(strip), guint(metrics.imageStripGap))
        gtk_widget_set_halign(strip, GTK_ALIGN_START)
        gtk_widget_set_valign(strip, GTK_ALIGN_START)
        for picture in pictures {
            gtk_flow_box_append(op(strip), thumbnail(picture, metrics: metrics, context: context))
        }
        return strip
    }

    private static func thumbnail(
        _ picture: TranscriptRow.StripPicture, metrics: ChatMetrics, context: TranscriptContext
    ) -> UnsafeMutablePointer<GtkWidget> {
        let name = filename(of: picture.reference)
        let opener = gtk_button_new()!
        Gtk.addClass(opener, "flat")
        Gtk.addClass(opener, "picture-thumb")
        gtk_widget_set_halign(opener, GTK_ALIGN_START)
        gtk_widget_set_valign(opener, GTK_ALIGN_START)
        gtk_widget_set_tooltip_text(opener, name)
        tailscode_set_accessible_label(opener, name)
        let frame: UnsafeMutablePointer<GtkWidget>
        if let bits = context.textures[picture.key], bits != 0 {
            let texture = OpaquePointer(bitPattern: Int(bitPattern: bits))
            let width = Double(tailscode_texture_width(texture))
            let height = Double(tailscode_texture_height(texture))
            let size = thumbnail(
                width: width, height: height, maxHeight: metrics.imageMaxHeight,
                maxWidth: ImagePreview.deskWidth)
            let image = tailscode_picture_for_texture_sized(texture, size.width, size.height)!
            gtk_picture_set_content_fit(op(image), GTK_CONTENT_FIT_CONTAIN)
            gtk_widget_set_size_request(image, size.width, size.height)
            Gtk.addClass(image, "image-part")
            frame = image
        } else {
            let box = Gtk.box(GTK_ORIENTATION_VERTICAL, spacing: 0)
            Gtk.addClass(box, "image-part")
            let side = Int32(metrics.imageMaxHeight * 4 / 3)
            gtk_widget_set_size_request(box, side, Int32(metrics.imageMaxHeight))
            let label = Gtk.label(
                Localized.text("🖼 %@ — loading…", name), css: "dim", selectable: false)
            gtk_label_set_ellipsize(op(label), PANGO_ELLIPSIZE_MIDDLE)
            gtk_widget_set_halign(label, GTK_ALIGN_CENTER)
            gtk_widget_set_valign(label, GTK_ALIGN_CENTER)
            gtk_widget_set_vexpand(label, 1)
            gtk_box_append(ptr(box), label)
            frame = box
            context.requestImage?(picture.reference, picture.key)
        }
        gtk_button_set_child(ptr(opener), frame)
        let open = context.openImage
        let key = picture.key
        Gtk.connect(UnsafeMutableRawPointer(opener), "clicked") { open?(key, name) }
        return opener
    }
}
