import CAdw
import CGtkShim
import Foundation
import TailscodeCore

extension Gtk {
    /// A picture widget over a decoded texture, held as cairo's own surface rather than as the
    /// texture: under the cairo renderer a texture node is downloaded again on every render pass,
    /// so a stage that wore one would cost a full copy of the picture for every frame of every
    /// animation in the window. The widget lays the picture out to fit what it is given and never
    /// asks for the room its pixels would take.
    static func studioPicture(bits: UInt, fit: GtkContentFit = GTK_CONTENT_FIT_CONTAIN)
        -> UnsafeMutablePointer<GtkWidget>?
    {
        guard let raw = UnsafeMutableRawPointer(bitPattern: bits),
            let widget = tailscode_picture_for_texture(OpaquePointer(raw))
        else { return nil }
        gtk_picture_set_content_fit(op(widget), fit)
        gtk_widget_set_hexpand(widget, 1)
        gtk_widget_set_vexpand(widget, 1)
        return widget
    }

    /// Swaps the picture a widget shows for a new decoded texture, through the same surface
    /// paintable ``studioPicture(bits:fit:)`` builds — a sketch frame changes one paintable and
    /// nothing around it, and never hands the renderer a raw texture.
    static func replacePicture(of picture: UnsafeMutablePointer<GtkWidget>, bits: UInt) {
        guard let donor = studioPicture(bits: bits) else { return }
        g_object_ref_sink(donor)
        if let paintable = gtk_picture_get_paintable(op(donor)) {
            gtk_picture_set_paintable(op(picture), paintable)
        }
        g_object_unref(donor)
    }

    /// The pixel size of a decoded texture, for the shape a stage reserves for it.
    static func textureSize(bits: UInt) -> (width: Int, height: Int)? {
        guard let raw = UnsafeMutableRawPointer(bitPattern: bits) else { return nil }
        let texture = OpaquePointer(raw)
        let width = Int(tailscode_texture_width(texture))
        let height = Int(tailscode_texture_height(texture))
        guard width > 0, height > 0 else { return nil }
        return (width, height)
    }

    /// A widget that is exactly `side` square, whatever its picture asks for: a picture asks for
    /// the width its paintable has and a box grants it, so a wide render took twice the room of a
    /// tall one and the tiles never lined up. A scrolled window with no scrolling allocates exactly
    /// its own size and clips the rest.
    static func squareFrame(
        holding picture: UnsafeMutablePointer<GtkWidget>?, side: Int32
    ) -> UnsafeMutablePointer<GtkWidget> {
        let frame = gtk_scrolled_window_new()!
        gtk_scrolled_window_set_policy(op(frame), GTK_POLICY_EXTERNAL, GTK_POLICY_EXTERNAL)
        gtk_widget_set_size_request(frame, side, side)
        gtk_widget_set_hexpand(frame, 0)
        gtk_widget_set_vexpand(frame, 0)
        gtk_widget_set_overflow(frame, GTK_OVERFLOW_HIDDEN)
        if let picture { gtk_scrolled_window_set_child(op(frame), picture) }
        return frame
    }

    /// Whether a button has the keyboard — a shelf tile, a chip, a verb — so that Return means what
    /// a button's Return means, and does not also send the words.
    static func focusIsButton(in root: UnsafeMutablePointer<GtkWidget>) -> Bool {
        guard let focused = tailscode_focused_widget(root) else { return false }
        let instance = UnsafeMutableRawPointer(focused).assumingMemoryBound(to: GTypeInstance.self)
        return g_type_check_instance_is_a(instance, gtk_button_get_type()) != 0
    }

    static func setHidden(_ widget: UnsafeMutablePointer<GtkWidget>, _ hidden: Bool) {
        tailscode_set_accessible_hidden(widget, hidden ? 1 : 0)
    }

    /// Makes `widget` a file the pointer can carry to a file manager or another app. The path is
    /// asked for when the press becomes a drag; nil means the bytes are not on this device yet and
    /// the press stays a click.
    static func makeFileDragSource(
        _ widget: UnsafeMutablePointer<GtkWidget>, path: @escaping @Sendable () -> String?
    ) {
        _ = releaseInstalled
        let box = Unmanaged.passRetained(FilePathProvider(path)).toOpaque()
        let resolve: @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutablePointer<CChar>? = {
            raw in
            guard let raw, let found = Unmanaged<FilePathProvider>.fromOpaque(raw).takeUnretainedValue().path()
            else { return nil }
            return g_strdup(found)
        }
        tailscode_make_file_drag_source(widget, resolve, box)
    }

    final class FilePathProvider: @unchecked Sendable {
        let path: @Sendable () -> String?
        init(_ path: @escaping @Sendable () -> String?) { self.path = path }
    }

    /// Whether the desk wants the stage's one crossfade: GTK's own animation switch, the one
    /// every desktop's "reduce animation" setting writes.
    static var animationsAllowed: Bool { RepeatingMotion.allowed }
}
